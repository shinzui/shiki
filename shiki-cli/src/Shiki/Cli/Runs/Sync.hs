-- | @shiki runs sync@: reconcile recorded runs against the cluster.
--
--   A run row is finalized by the @shiki run@ process that follows its Job.
--   When that process dies first (the terminal closes, the laptop sleeps, the
--   OS kills it for memory), the row stays @running@ forever while the Job
--   runs on to its own end. @sync@ reads each unfinished run's Job and writes
--   the outcome the cluster reports, so run history matches what happened.
module Shiki.Cli.Runs.Sync
  ( SyncAction (..),
    decideSync,
    lostJobMessage,
    syncRuns,
    syncRun,
  )
where

import Control.Exception (SomeAsyncException, SomeException, fromException, throwIO, try)
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Data.Text.IO qualified as TIO
import Data.Time.Clock (NominalDiffTime, diffUTCTime)
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (Statement)
import Shiki.Cli.Env (CliEnv (..))
import Shiki.Cli.Run (completionForOutcome, elapsedMs)
import Shiki.K8s.Introspection (DeploymentName (..), Namespace (..), deploymentExists)
import Shiki.K8s.Runner
  ( JobObservation (..),
    JobPhase (..),
    collectOutcome,
    observeJob,
  )
import Shiki.Persistence.Run
  ( RunCompletion (..),
    RunId (..),
    RunRecord,
    completeUnfinishedRunStatement,
    listUnfinishedRunsStatement,
  )
import Shiki.Persistence.RunStatus (RunStatus (..), runStatusToText)
import Shiki.Prelude
import Shiki.Service.Config (ServiceConfig)
import System.Exit (exitFailure)
import System.IO (stderr)

-- | What to do with one run, given the Job the cluster reports for it.
data SyncAction
  = -- | the row is already terminal; leave it alone
    SkipFinished !RunStatus
  | -- | the Job is still active; leave the row @running@
    LeaveRunning
  | -- | the Job finished; record this phase, ended at this time
    FinalizeFinished !JobPhase !UTCTime
  | -- | no Job yet, but the run is too new to call it lost
    SkipRecentlySubmitted
  | -- | no Job, and the run is old enough that its Job is gone
    MarkLost
  deriving stock (Generic, Eq, Show)

-- | How long a run may exist without a Job before @sync@ treats the Job as
--   gone. Covers the gap between inserting the row and the API accepting
--   the create request.
submitGrace :: NominalDiffTime
submitGrace = 120

-- | Decide a run's reconciliation. Pure, so the policy is testable without
--   a cluster. @now@ stands in for a missing end time.
decideSync :: UTCTime -> RunRecord -> JobObservation -> SyncAction
decideSync now r obs
  | status `notElem` [Pending, Running] = SkipFinished status
  | otherwise = case obs of
      JobActive -> LeaveRunning
      JobFinished phase mEnd -> FinalizeFinished phase (fromMaybe now mEnd)
      JobNotFound
        | diffUTCTime now (r ^. #startedAt) < submitGrace -> SkipRecentlySubmitted
        | otherwise -> MarkLost
  where
    status = r ^. #status

-- | The @error@ recorded on a run whose Job no longer exists.
lostJobMessage :: RunRecord -> Text
lostJobMessage r =
  "job "
    <> (r ^. #jobName)
    <> " no longer exists in namespace "
    <> (r ^. #namespace)
    <> "; no shiki process was following it when it ended, so its outcome is unknown"

-- | Reconcile every unfinished run. One run's error is reported and the
--   rest still sync; the command exits non-zero if any run errored.
syncRuns :: CliEnv -> IO ()
syncRuns env = do
  rows <- runStmt env listUnfinishedRunsStatement ()
  if null rows
    then TIO.putStrLn "(no unfinished runs)"
    else do
      results <- traverse (trySync env) rows
      when (or results) exitFailure

-- | Reconcile one run, exiting non-zero if it errored.
syncRun :: CliEnv -> RunRecord -> IO ()
syncRun env r = trySync env r >>= \errored -> when errored exitFailure

-- | Sync one run; report an exception on stderr and return whether one
--   happened. Asynchronous exceptions (Ctrl-C) still propagate.
trySync :: CliEnv -> RunRecord -> IO Bool
trySync env r =
  try @SomeException (syncOne env r) >>= \case
    Right () -> pure False
    Left e
      | Just asyncErr <- fromException @SomeAsyncException e -> throwIO asyncErr
      | otherwise -> do
          TIO.hPutStrLn stderr ("run " <> shortId r <> ": sync failed: " <> Text.pack (show e))
          pure True

syncOne :: CliEnv -> RunRecord -> IO ()
syncOne env r
  | r ^. #status `notElem` [Pending, Running] =
      report ("already " <> runStatusToText (r ^. #status))
  | otherwise = do
      obs <- observeJob (env ^. #client) ns (r ^. #jobName)
      now <- getCurrentTime
      case decideSync now r obs of
        SkipFinished st -> report ("already " <> runStatusToText st)
        LeaveRunning -> report ("still running (job " <> r ^. #jobName <> ")")
        SkipRecentlySubmitted -> report "no job yet; submitted too recently to reconcile"
        FinalizeFinished phase endedAt -> do
          outcome <-
            collectOutcome (env ^. #client) ns (r ^. #jobName) (r ^. #startedAt) endedAt phase
          write (completionForOutcome (r ^. #runId) (r ^. #startedAt) outcome)
        MarkLost -> do
          confirmSameCluster
          write
            RunCompletion
              { runId = r ^. #runId,
                status = Failed,
                exitCode = Nothing,
                endedAt = now,
                durationMs = elapsedMs (r ^. #startedAt) now,
                logTail = Nothing,
                errorMessage = Just (lostJobMessage r),
                errorSummary = Nothing,
                errorSummarySource = "heuristic"
              }
  where
    ns = Namespace (r ^. #namespace)

    report msg = TIO.putStrLn ("run " <> shortId r <> ": " <> msg)

    write completion = do
      updated <- runStmt env completeUnfinishedRunStatement completion
      report $
        if updated
          then
            runStatusToText (completion ^. #status)
              <> maybe "" (" - " <>) (completion ^. #errorMessage)
          else "already finalized by another shiki process; left unchanged"

    -- A missing Job only means "gone" if we are talking to the cluster the
    -- run was submitted to. Require the service's Deployment to be there, so
    -- a kube context pointed elsewhere cannot mark live runs as failed.
    confirmSameCluster = do
      cfg <- case Aeson.fromJSON @ServiceConfig (r ^. #serviceConfig) of
        Aeson.Success c -> pure c
        Aeson.Error e ->
          throwIO (userError ("cannot read the run's service config snapshot: " <> e))
      let dep = cfg ^. #detectFromDeployment
      present <- deploymentExists (env ^. #client) ns (DeploymentName dep)
      unless present $
        throwIO
          ( userError
              ( Text.unpack
                  ( "job not found, and neither is deployment "
                      <> dep
                      <> " in namespace "
                      <> r ^. #namespace
                      <> "; is the kube context pointed at the cluster this run used? left unchanged"
                  )
              )
          )

shortId :: RunRecord -> Text
shortId r = Text.take 8 (Text.pack (show (unRunId (r ^. #runId))))

runStmt :: CliEnv -> Statement a b -> a -> IO b
runStmt env stmt input =
  Pool.use (env ^. #pool) (Session.statement input stmt)
    >>= either (error . ("shiki: persistence error: " <>) . show) pure
