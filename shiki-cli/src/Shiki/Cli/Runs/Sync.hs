-- | @shiki runs sync@: reconcile recorded runs against the cluster.
--
--   A run row is finalized by the @shiki run@ process that follows its Job.
--   When that process dies first (the terminal closes, the laptop sleeps, the
--   OS kills it for memory), the row stays @running@ forever while the Job
--   runs on to its own end. @sync@ reads each unfinished run's Job and writes
--   the outcome the cluster reports, so run history matches what happened.
module Shiki.Cli.Runs.Sync
  ( SyncAction (..),
    SyncFailure (..),
    decideSync,
    lostJobMessage,
    renderSyncFailure,
    renderStillRunning,
    syncRuns,
    syncRun,
  )
where

import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Data.Text.IO qualified as TIO
import Data.Time.Clock (NominalDiffTime, diffUTCTime)
import Effectful (Eff, IOE, type (:>))
import Effectful.Error.Static (Error, runErrorNoCallStack, throwError)
import Effectful.Exception qualified as Exc
import Shiki.Cli.Env (CliEnv (..))
import Shiki.Cli.Error (CliError (..))
import Shiki.Cli.Run (completionForOutcome, elapsedMs)
import Shiki.Cli.Runs.Format (isUnwatched)
import Shiki.Effect.RunStore
  ( RunStore,
    completeUnfinishedRun,
    databaseNow,
    listUnfinishedRuns,
  )
import Shiki.Error (ShikiError, shikiErrorMessage)
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
  )
import Shiki.Persistence.RunStatus (RunStatus (..), runStatusToText)
import Shiki.Prelude
import Shiki.Service.Config (ServiceConfig)
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

-- | Why one run could not be reconciled, beyond the store and cluster
--   failures 'ShikiError' already covers. Reported per run, so one bad run
--   does not stop the rest.
data SyncFailure
  = -- | aeson's message for an unreadable @serviceConfig@ snapshot
    ServiceConfigSnapshotUnreadable !Text
  | -- | deployment name, namespace: the Job is gone and so is the Deployment
    DeploymentMissingToo !Text !Text
  deriving stock (Generic, Eq, Show)

renderSyncFailure :: SyncFailure -> Text
renderSyncFailure = \case
  ServiceConfigSnapshotUnreadable message ->
    "cannot read the run's service config snapshot: " <> message
  DeploymentMissingToo deployment namespace ->
    "job not found, and neither is deployment "
      <> deployment
      <> " in namespace "
      <> namespace
      <> "; is the kube context pointed at the cluster this run used? left unchanged"

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
syncRuns ::
  (RunStore :> es, IOE :> es, Error CliError :> es) =>
  CliEnv ->
  Eff es ()
syncRuns env = do
  observedAt <- databaseNow
  rows <- listUnfinishedRuns
  if null rows
    then liftIO (TIO.putStrLn "(no unfinished runs)")
    else do
      results <- traverse (trySyncOne env observedAt) rows
      when (or results) (throwError CommandFailed)

-- | Reconcile one run, exiting non-zero if it errored.
syncRun ::
  (RunStore :> es, IOE :> es, Error CliError :> es) =>
  CliEnv ->
  UTCTime ->
  RunRecord ->
  Eff es ()
syncRun env observedAt r =
  trySyncOne env observedAt r >>= \errored -> when errored (throwError CommandFailed)

-- | Sync one run; report any failure on stderr and return whether one
--   happened. Three shapes are caught, and all three read the same to an
--   operator: a typed 'ShikiError' from the store or the cluster, a typed
--   'SyncFailure' from this module, and an exception from the Kubernetes
--   client. Asynchronous exceptions (Ctrl-C) still propagate, because
--   'Exc.trySync' does not catch them.
trySyncOne ::
  (RunStore :> es, IOE :> es) =>
  CliEnv ->
  UTCTime ->
  RunRecord ->
  Eff es Bool
trySyncOne env observedAt r = do
  outcome <-
    Exc.trySync
      . runErrorNoCallStack @ShikiError
      . runErrorNoCallStack @SyncFailure
      $ syncOne env observedAt r
  case outcome of
    Right (Right (Right ())) -> pure False
    Right (Right (Left syncFailure)) -> reportFailure (renderSyncFailure syncFailure)
    Right (Left shikiError) -> reportFailure (shikiErrorMessage shikiError)
    Left e -> reportFailure (Text.pack (Exc.displayException e))
  where
    reportFailure message = do
      liftIO . TIO.hPutStrLn stderr $
        "run " <> shortId r <> ": sync failed: " <> message
      pure True

syncOne ::
  (RunStore :> es, IOE :> es, Error SyncFailure :> es) =>
  CliEnv ->
  UTCTime ->
  RunRecord ->
  Eff es ()
syncOne env observedAt r
  | r ^. #status `notElem` [Pending, Running] =
      report ("already " <> runStatusToText (r ^. #status))
  | otherwise = do
      obs <- liftIO (observeJob (env ^. #client) ns (r ^. #jobName))
      now <- liftIO getCurrentTime
      case decideSync now r obs of
        SkipFinished st -> report ("already " <> runStatusToText st)
        LeaveRunning -> report (renderStillRunning observedAt r)
        SkipRecentlySubmitted -> report "no job yet; submitted too recently to reconcile"
        FinalizeFinished phase endedAt -> do
          outcome <-
            liftIO $
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

    report msg = liftIO (TIO.putStrLn ("run " <> shortId r <> ": " <> msg))

    write completion = do
      updated <- completeUnfinishedRun completion
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
          throwError (ServiceConfigSnapshotUnreadable (Text.pack e))
      let dep = cfg ^. #detectFromDeployment
      present <- liftIO (deploymentExists (env ^. #client) ns (DeploymentName dep))
      unless present $
        throwError (DeploymentMissingToo dep (r ^. #namespace))

-- | Explain an active Job whose row has no recent watcher heartbeat.
renderStillRunning :: UTCTime -> RunRecord -> Text
renderStillRunning observedAt r
  | isUnwatched observedAt r =
      "still running (job "
        <> r ^. #jobName
        <> "); no shiki process has recently reported watching it, so sync again later"
  | otherwise = "still running (job " <> r ^. #jobName <> ")"

shortId :: RunRecord -> Text
shortId r = Text.take 8 (Text.pack (show (unRunId (r ^. #runId))))
