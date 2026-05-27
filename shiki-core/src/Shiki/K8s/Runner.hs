-- | End-to-end one-off Job lifecycle: build the Job, submit it, poll
--   the cluster until it completes (or times out), fetch a tail of the
--   pod logs, and return a 'JobOutcome' that downstream callers (the
--   @shiki run@ command and the persistence layer) can record.
module Shiki.K8s.Runner
  ( JobOutcome (..)
  , JobPhase (..)
  , JobInputs (..)
  , submitJob
  , runJob
  ) where

import Shiki.Prelude

import Shiki.K8s.Client (ClientEnv (..))
import Shiki.K8s.Introspection (DeploymentSnapshot, Namespace (..))
import Shiki.K8s.JobBuilder (JobInputs (..), buildJob)
import Shiki.K8s.Logs (fetchJobPodLogs)
import Shiki.Service.Config (ServiceConfig)

import "base" Control.Concurrent (threadDelay)
import "base" Control.Exception (Exception, throwIO)
import "time" Data.Time.Clock (diffUTCTime)
import "kubernetes-api" Kubernetes.OpenAPI qualified as K8s
import "kubernetes-api" Kubernetes.OpenAPI.API.BatchV1 qualified as BatchV1
import "kubernetes-api" Kubernetes.OpenAPI.ModelLens qualified as K8sLens

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
  { jobName   :: !Text
  , namespace :: !Text
  , phase     :: !JobPhase
  , exitCode  :: !(Maybe Int)
  , startedAt :: !UTCTime
  , endedAt   :: !UTCTime
  , logTail   :: !(Maybe Text)
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
submitJob
  :: ClientEnv
  -> ServiceConfig
  -> DeploymentSnapshot
  -> JobInputs
  -> IO ()
submitJob env svc snap inputs = do
  let job = buildJob svc snap inputs
      req = BatchV1.createNamespacedJob
              (K8s.ContentType K8s.MimeJSON)
              (K8s.Accept K8s.MimeJSON)
              job
              (K8s.Namespace (unNamespace (inputs ^. #namespace)))
  resp <- K8s.dispatchMime (env ^. #httpManager) (env ^. #clientConfig) req
  case K8s.mimeResult resp of
    Left err -> throwIO (JobSubmitFailed (show err))
    Right _  -> pure ()

-- | Submit and wait for completion. Polls the Job status every
--   @pollSec@ seconds, gives up after @timeoutSec@ seconds, fetches the
--   pod log tail at the end (or after a timeout), and returns a
--   'JobOutcome'.
runJob
  :: ClientEnv
  -> ServiceConfig
  -> DeploymentSnapshot
  -> JobInputs
  -> Int             -- ^ poll interval, seconds
  -> Int             -- ^ overall timeout, seconds
  -> IO JobOutcome
runJob env svc snap inputs pollSec timeoutSec = do
  startedAt <- liftIO getCurrentTime
  submitJob env svc snap inputs
  phase     <- waitForCompletion env inputs startedAt pollSec timeoutSec
  endedAt   <- liftIO getCurrentTime
  logsE     <- fetchJobPodLogs env (inputs ^. #namespace) (inputs ^. #jobName)
  let logTailNow = either (const Nothing) (Just . (^. #persistedTail)) logsE
  pure JobOutcome
    { jobName   = inputs ^. #jobName
    , namespace = unNamespace (inputs ^. #namespace)
    , phase     = phase
    , exitCode  = exitCodeForPhase phase
    , startedAt = startedAt
    , endedAt   = endedAt
    , logTail   = logTailNow
    }

exitCodeForPhase :: JobPhase -> Maybe Int
exitCodeForPhase = \case
  JobSucceeded -> Just 0
  JobFailed _  -> Just 1
  JobTimedOut  -> Nothing

waitForCompletion
  :: ClientEnv -> JobInputs -> UTCTime -> Int -> Int -> IO JobPhase
waitForCompletion env inputs startedAt pollSec timeoutSec = go
  where
    go = do
      now <- getCurrentTime
      if realToFrac (diffUTCTime now startedAt) > (fromIntegral timeoutSec :: Double)
        then pure JobTimedOut
        else do
          status <- readJobStatus env inputs
          case interpret status of
            Nothing  -> threadDelay (pollSec * 1_000_000) >> go
            Just phs -> pure phs

    interpret :: K8s.V1JobStatus -> Maybe JobPhase
    interpret s = case (s ^. K8sLens.v1JobStatusSucceededL, s ^. K8sLens.v1JobStatusFailedL) of
      (Just n, _) | n > 0 -> Just JobSucceeded
      (_, Just n) | n > 0 -> Just (JobFailed (firstFailureReason s))
      _                   -> Nothing

    firstFailureReason :: K8s.V1JobStatus -> Text
    firstFailureReason s = case s ^. K8sLens.v1JobStatusConditionsL of
      Just (c : _) -> fromMaybe "Failed" (c ^. K8sLens.v1JobConditionReasonL)
      _            -> "Failed"

readJobStatus :: ClientEnv -> JobInputs -> IO K8s.V1JobStatus
readJobStatus env inputs = do
  let req = BatchV1.readNamespacedJobStatus
              (K8s.Accept K8s.MimeJSON)
              (K8s.Name      (inputs ^. #jobName))
              (K8s.Namespace (unNamespace (inputs ^. #namespace)))
  resp <- K8s.dispatchMime (env ^. #httpManager) (env ^. #clientConfig) req
  job <- case K8s.mimeResult resp of
    Left err -> throwIO (JobStatusReadFailed (inputs ^. #jobName) (show err))
    Right j  -> pure j
  pure (fromMaybe K8s.mkV1JobStatus (job ^. K8sLens.v1JobStatusL))
