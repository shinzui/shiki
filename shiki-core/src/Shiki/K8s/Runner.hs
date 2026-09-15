-- | End-to-end one-off Job lifecycle: build the Job, submit it, poll
--   the cluster until it completes (or times out), fetch a tail of the
--   pod logs, and return a 'JobOutcome' that downstream callers (the
--   @shiki run@ command and the persistence layer) can record.
module Shiki.K8s.Runner
  ( JobOutcome (..),
    JobPhase (..),
    JobInputs (..),
    JobObservation (..),
    submitJob,
    runJob,
    observeJob,
    classifyJob,
    jobPhaseFromStatus,
    collectOutcome,
    waitForCompletionWith,
    maxConsecutiveStatusFailures,
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception
  ( Exception,
    SomeAsyncException,
    SomeException,
    fromException,
    throwIO,
    try,
  )
import Data.Generics.Labels ()
import Data.Maybe (listToMaybe)
import Data.Time.Clock (diffUTCTime)
import Kubernetes.OpenAPI qualified as K8s
import Kubernetes.OpenAPI.API.BatchV1 qualified as BatchV1
import Kubernetes.OpenAPI.ModelLens qualified as K8sLens
import Network.HTTP.Client (responseStatus)
import Network.HTTP.Types.Status (statusCode)
import Shiki.Analysis.Backend (AnalyzerKind (..), runAnalyzer)
import Shiki.Analysis.Backend qualified as Analyzer
import Shiki.K8s.Client (ClientEnv (..), dispatchK8s)
import Shiki.K8s.Introspection (DeploymentSnapshot, Namespace (..))
import Shiki.K8s.JobBuilder (JobInputs (..), buildJob)
import Shiki.K8s.Logs (FetchedLogs, fetchJobPodLogs)
import Shiki.Prelude
import Shiki.Service.Config (ServiceConfig)

-- | Final state observed for a Job. 'JobFailed' carries the
--   first failure reason from the Job conditions if one was published.
data JobPhase
  = JobSucceeded
  | JobFailed !Text
  | JobTimedOut
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

-- | Cluster-side observations the persistence layer needs to finalize
--   a run row: which job ran, where, how it ended, when it ran, and a
--   truncated log tail (200 lines, capped at 64 KiB) suitable for the
--   @runs.log_tail@ column defined in EP-2.
data JobOutcome = JobOutcome
  { jobName :: !Text,
    namespace :: !Text,
    phase :: !JobPhase,
    exitCode :: !(Maybe Int),
    startedAt :: !UTCTime,
    endedAt :: !UTCTime,
    logTail :: !(Maybe Text),
    errorSummary :: !(Maybe Text),
    errorSummarySource :: !Text
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data RunnerError
  = JobSubmitFailed !String
  | JobStatusReadFailed !Text !String
  deriving stock (Generic, Eq, Show)
  deriving anyclass (Exception)

-- | Build the Job and submit it. Returns immediately after the API
--   accepts the create request; used for @--no-wait@.
submitJob ::
  ClientEnv ->
  ServiceConfig ->
  DeploymentSnapshot ->
  JobInputs ->
  IO ()
submitJob env svc snap inputs = do
  let job = buildJob svc snap inputs
      req =
        BatchV1.createNamespacedJob
          (K8s.ContentType K8s.MimeJSON)
          (K8s.Accept K8s.MimeJSON)
          job
          (K8s.Namespace (unNamespace (inputs ^. #namespace)))
  resp <- dispatchK8s env req
  case K8s.mimeResult resp of
    Left err -> throwIO (JobSubmitFailed (show err))
    Right _ -> pure ()

-- | Submit and wait for completion. Polls the Job status every
--   @pollSec@ seconds, gives up after @timeoutSec@ seconds, fetches the
--   pod log tail at the end (or after a timeout), and returns a
--   'JobOutcome'.
runJob ::
  ClientEnv ->
  ServiceConfig ->
  DeploymentSnapshot ->
  JobInputs ->
  -- | poll interval, seconds
  Int ->
  -- | overall timeout, seconds
  Int ->
  IO JobOutcome
runJob env svc snap inputs pollSec timeoutSec = do
  startedAt <- liftIO getCurrentTime
  submitJob env svc snap inputs
  phase <- waitForCompletion env inputs startedAt pollSec timeoutSec
  endedAt <- liftIO getCurrentTime
  collectOutcome env (inputs ^. #namespace) (inputs ^. #jobName) startedAt endedAt phase

-- | Turn a terminal 'JobPhase' into a 'JobOutcome': fetch the pod log tail
--   (while the pod still exists) and summarize it when the Job failed.
--   Shared by the waiting path of @shiki run@ and by @shiki runs sync@,
--   which reconciles a run whose waiting process is gone.
collectOutcome ::
  ClientEnv ->
  Namespace ->
  -- | job name
  Text ->
  -- | started at
  UTCTime ->
  -- | ended at
  UTCTime ->
  JobPhase ->
  IO JobOutcome
collectOutcome env ns jobNm startedAt endedAt phase = do
  logsE <- fetchJobPodLogs env ns jobNm
  let logTailNow = either (const Nothing) (Just . (^. #persistedTail)) logsE
  (errSummary, errSource) <- summarizeOnFailure phase logsE
  pure
    JobOutcome
      { jobName = jobNm,
        namespace = unNamespace ns,
        phase = phase,
        exitCode = exitCodeForPhase phase,
        startedAt = startedAt,
        endedAt = endedAt,
        logTail = logTailNow,
        errorSummary = errSummary,
        errorSummarySource = errSource
      }

-- | Run the inline 'Heuristic' analyzer over the wider analysis buffer
--   when (and only when) the Job ended in failure. On success the column
--   contract is \"NULL unless the run died\", so the summary stays
--   'Nothing'. The default source is @\"heuristic\"@ regardless so the
--   downstream NOT-NULL column always has a value.
summarizeOnFailure ::
  JobPhase ->
  Either e FetchedLogs ->
  IO (Maybe Text, Text)
summarizeOnFailure phase logsE = case phase of
  JobSucceeded -> pure (Nothing, "heuristic")
  _ -> case logsE of
    Left _ -> pure (Nothing, "heuristic")
    Right fl -> do
      r <- runAnalyzer Heuristic (fl ^. #analysisBuffer)
      case r of
        Right res -> pure (Analyzer.summary res, Analyzer.source res)
        Left _ -> pure (Nothing, "heuristic")

exitCodeForPhase :: JobPhase -> Maybe Int
exitCodeForPhase = \case
  JobSucceeded -> Just 0
  JobFailed _ -> Just 1
  JobTimedOut -> Nothing

-- | How many status reads may fail in a row before the wait gives up.
--
--   A read that fails is not a Job that failed: a credential can expire
--   mid-wait, or the API server can blip, while the Job runs on untouched.
--   Treating the first such error as a failed run mislabels a healthy import
--   and abandons the wait, so tolerate a few and keep polling.
maxConsecutiveStatusFailures :: Int
maxConsecutiveStatusFailures = 5

waitForCompletion ::
  ClientEnv -> JobInputs -> UTCTime -> Int -> Int -> IO JobPhase
waitForCompletion env inputs =
  waitForCompletionWith (readJobStatus env inputs)

-- | The polling loop, with the status read injected so it can be driven
--   from a test.
waitForCompletionWith ::
  -- | Read the Job status; may throw.
  IO K8s.V1JobStatus ->
  UTCTime ->
  -- | poll interval, seconds
  Int ->
  -- | overall timeout, seconds
  Int ->
  IO JobPhase
waitForCompletionWith readStatus startedAt pollSec timeoutSec = go 0
  where
    go failures = do
      now <- getCurrentTime
      if realToFrac (diffUTCTime now startedAt) > (fromIntegral timeoutSec :: Double)
        then pure JobTimedOut
        else
          try @SomeException readStatus >>= \case
            Left err
              | Just asyncErr <- fromException @SomeAsyncException err -> throwIO asyncErr
              | failures + 1 >= maxConsecutiveStatusFailures -> throwIO err
              | otherwise -> wait >> go (failures + 1)
            Right status -> case jobPhaseFromStatus status of
              Nothing -> wait >> go 0
              Just phs -> pure phs

    wait = threadDelay (pollSec * 1_000_000)

-- | The terminal phase a Job status reports, or 'Nothing' while it is
--   still active. 'JobFailed' carries the first condition's reason.
jobPhaseFromStatus :: K8s.V1JobStatus -> Maybe JobPhase
jobPhaseFromStatus s = case (s ^. K8sLens.v1JobStatusSucceededL, s ^. K8sLens.v1JobStatusFailedL) of
  (Just n, _) | n > 0 -> Just JobSucceeded
  (_, Just n) | n > 0 -> Just (JobFailed firstFailureReason)
  _ -> Nothing
  where
    firstFailureReason = case s ^. K8sLens.v1JobStatusConditionsL of
      Just (c : _) -> fromMaybe "Failed" (c ^. K8sLens.v1JobConditionReasonL)
      _ -> "Failed"

-- | What the cluster reports for a Job right now.
data JobObservation
  = -- | the Job exists and has not finished
    JobActive
  | -- | the Job finished; carries when, if the cluster recorded it
    JobFinished !JobPhase !(Maybe UTCTime)
  | -- | no Job by that name exists in the namespace (never created, or
    --   removed by @ttlSecondsAfterFinished@ or by hand)
    JobNotFound
  deriving stock (Generic, Eq, Show)

-- | Read a Job and classify it. A 404 is 'JobNotFound'; any other API
--   error throws, so an unreachable cluster is never mistaken for a
--   missing Job.
observeJob :: ClientEnv -> Namespace -> Text -> IO JobObservation
observeJob env ns jobNm = do
  let req =
        BatchV1.readNamespacedJobStatus
          (K8s.Accept K8s.MimeJSON)
          (K8s.Name jobNm)
          (K8s.Namespace (unNamespace ns))
  resp <- dispatchK8s env req
  case K8s.mimeResult resp of
    Right job -> pure (classifyJob job)
    Left err
      | statusCode (responseStatus (K8s.mimeResultResponse resp)) == 404 -> pure JobNotFound
      | otherwise -> throwIO (JobStatusReadFailed jobNm (show err))

-- | Classify an existing Job. The end time is @completionTime@ for a Job
--   that succeeded and the @Failed@ condition's transition time for one
--   that failed.
classifyJob :: K8s.V1Job -> JobObservation
classifyJob job = case jobPhaseFromStatus status of
  Nothing -> JobActive
  Just phase@JobSucceeded ->
    JobFinished phase (K8s.unDateTime <$> status ^. K8sLens.v1JobStatusCompletionTimeL)
  Just phase -> JobFinished phase failedAt
  where
    status = fromMaybe K8s.mkV1JobStatus (job ^. K8sLens.v1JobStatusL)
    failedAt =
      listToMaybe
        [ K8s.unDateTime t
        | c <- fromMaybe [] (status ^. K8sLens.v1JobStatusConditionsL),
          c ^. K8sLens.v1JobConditionTypeL == "Failed",
          Just t <- [c ^. K8sLens.v1JobConditionLastTransitionTimeL]
        ]

readJobStatus :: ClientEnv -> JobInputs -> IO K8s.V1JobStatus
readJobStatus env inputs = do
  let req =
        BatchV1.readNamespacedJobStatus
          (K8s.Accept K8s.MimeJSON)
          (K8s.Name (inputs ^. #jobName))
          (K8s.Namespace (unNamespace (inputs ^. #namespace)))
  resp <- dispatchK8s env req
  job <- case K8s.mimeResult resp of
    Left err -> throwIO (JobStatusReadFailed (inputs ^. #jobName) (show err))
    Right j -> pure j
  pure (fromMaybe K8s.mkV1JobStatus (job ^. K8sLens.v1JobStatusL))
