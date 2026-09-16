-- | The @shiki run@ subcommand: load a 'ServiceConfig', introspect the
--   live worker Deployment, submit a one-off Kubernetes Job, record the
--   run in PostgreSQL, and (unless @--no-wait@) follow it to completion.
--   This module is the integration point named in the MasterPlan's
--   Vision & Scope; it composes 'Shiki.Service.Config.Dhall',
--   'Shiki.Persistence.Run', and 'Shiki.K8s.Runner' without changing any
--   of them.
module Shiki.Cli.Run
  ( RunOptions (..),
    runOptionsParser,
    runRun,
    completionForOutcome,
    elapsedMs,
  )
where

import Control.Exception (AsyncException (..))
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Data.Text.IO qualified as TIO
import Data.Time.Clock (diffUTCTime)
import Effectful (Eff, IOE, type (:>))
import Effectful.Concurrent (Concurrent)
import Effectful.Error.Static (Error, catchError, throwError)
import Effectful.Exception qualified as Exc
import Options.Applicative
  ( Parser,
    argument,
    help,
    long,
    many,
    metavar,
    optional,
    short,
    showDefault,
    str,
    strOption,
    switch,
    value,
  )
import Shiki.Cli.Error (CliError (..))
import Shiki.Cli.Heartbeat (withHeartbeat)
import Shiki.Effect.ConfigLoader (ConfigLoader, loadServiceConfig)
import Shiki.Effect.Kube (Kube, awaitJob, inspectDeployment, submitJob)
import Shiki.Effect.RunStore
  ( RunStore,
    completeRun,
    insertRun,
    markRunRunning,
    touchRunWatched,
  )
import Shiki.Error (ShikiError, shikiErrorMessage)
import Shiki.K8s.Introspection
  ( DeploymentName (..),
    DeploymentSnapshot,
    Namespace (..),
  )
import Shiki.K8s.JobBuilder (JobInputs (..), generateJobName)
import Shiki.K8s.Runner (JobOutcome (..), JobPhase (..))
import Shiki.Persistence.Run
  ( NewRun (..),
    RunCompletion (..),
    RunId (..),
    newRunId,
  )
import Shiki.Persistence.RunStatus (RunStatus (Failed, Succeeded))
import Shiki.Prelude hiding (Strict, argument)
import Shiki.Service.Config (ServiceConfig, ServiceName (..))
import System.IO (stderr)

data RunOptions = RunOptions
  { service :: !Text,
    overrideNs :: !(Maybe Text),
    noWait :: !Bool,
    configDir :: !FilePath,
    commandArgs :: ![Text]
  }
  deriving stock (Generic, Eq, Show)

-- | optparse-applicative parser for 'RunOptions'. The trailing
--   @commandArgs@ list collects every remaining positional after
--   @SERVICE@; an operator typically separates them with @--@ so flags
--   in their subcommand (e.g. @--batch-size 100@) survive optparse's
--   parsing.
runOptionsParser :: Parser RunOptions
runOptionsParser =
  RunOptions
    <$> argument str (metavar "SERVICE")
    <*> optional
      ( strOption
          ( long "namespace"
              <> short 'n'
              <> metavar "NS"
              <> help "Override the service's default namespace"
          )
      )
    <*> switch
      ( long "no-wait"
          <> help "Submit and exit without waiting for completion"
      )
    <*> strOption
      ( long "config-dir"
          <> metavar "DIR"
          <> value "services"
          <> showDefault
          <> help "Directory holding <service>.dhall files"
      )
    <*> many (argument str (metavar "-- ARG..."))

-- | End-to-end handler: load config, write a @pending@ row, mark it
--   @running@, submit the Job, then either exit (no-wait) or wait and
--   finalize. Any exception is captured into a @failed@ row before
--   re-exiting non-zero.
--   Every store write goes through the 'RunStore' effect and every cluster
--   call through 'Kube', so this handler's type lists exactly what the command
--   touches.
runRun ::
  ( RunStore :> es,
    Kube :> es,
    ConfigLoader :> es,
    Concurrent :> es,
    IOE :> es,
    Error ShikiError :> es,
    Error CliError :> es
  ) =>
  RunOptions ->
  Eff es ()
runRun opts = do
  cfg <-
    loadServiceConfig
      (opts ^. #configDir <> "/" <> Text.unpack (opts ^. #service) <> ".dhall")

  let ns =
        Namespace
          (fromMaybe (cfg ^. #defaultNamespace) (opts ^. #overrideNs))

  snap <-
    inspectDeployment
      ns
      (DeploymentName (cfg ^. #detectFromDeployment))
      (cfg ^. #containerName)

  rid <- liftIO newRunId
  startedAt <- liftIO getCurrentTime
  jobNm <- liftIO (generateJobName (cfg ^. #name) startedAt)

  let inputs =
        JobInputs
          { namespace = ns,
            args = opts ^. #commandArgs,
            jobName = jobNm
          }
      newRow =
        NewRun
          { runId = rid,
            serviceName = unServiceName (cfg ^. #name),
            command = opts ^. #commandArgs,
            namespace = unNamespace ns,
            jobName = jobNm,
            image = Just (snap ^. #image),
            startedAt = startedAt,
            serviceConfig = toJSON cfg
          }

  insertRun newRow
  markRunRunning rid

  if opts ^. #noWait
    then noWaitPath rid startedAt cfg snap inputs
    else waitPath rid startedAt cfg snap inputs

noWaitPath ::
  (RunStore :> es, Kube :> es, IOE :> es, Error ShikiError :> es, Error CliError :> es) =>
  RunId ->
  UTCTime ->
  ServiceConfig ->
  DeploymentSnapshot ->
  JobInputs ->
  Eff es ()
noWaitPath rid startedAt cfg snap inputs =
  guarded rid inputs (submitJob cfg snap inputs) >>= \case
    Left message -> finalizeFailed rid startedAt message
    Right () ->
      liftIO . TIO.putStrLn $
        "submitted job "
          <> (inputs ^. #jobName)
          <> " (run "
          <> showRunId rid
          <> ")"

waitPath ::
  ( RunStore :> es,
    Kube :> es,
    Concurrent :> es,
    IOE :> es,
    Error ShikiError :> es,
    Error CliError :> es
  ) =>
  RunId ->
  UTCTime ->
  ServiceConfig ->
  DeploymentSnapshot ->
  JobInputs ->
  Eff es ()
waitPath rid startedAt cfg snap inputs =
  guarded
    rid
    inputs
    (withHeartbeat heartbeatInterval (touchRunWatched rid) (awaitJob cfg snap inputs))
    >>= \case
      Left message -> finalizeFailed rid startedAt message
      Right outcome -> finalizeOutcome rid startedAt outcome

-- | Run a cluster action, turning both shapes of /synchronous/ failure into a
--   message the caller records on the run row: an exception from the client,
--   and a typed 'ShikiError' from the 'Kube' interpreter.
--
--   Asynchronous exceptions deliberately pass straight through. Pressing
--   Ctrl-C while @shiki run@ waits used to be caught here and written to the
--   row as @failed@ with the message @user interrupt@, which was simply false:
--   the Job keeps running in the cluster. Now the interrupt propagates, shiki
--   exits with the shell's interrupt status, and the row stays @running@ —
--   which is the situation ADR 3's @unwatched@ display and @shiki runs sync@
--   exist for. 'Exc.withException' runs the hint only while an
--   'AsyncException' is propagating, and re-throws it untouched.
guarded ::
  (IOE :> es, Error ShikiError :> es) =>
  RunId ->
  JobInputs ->
  Eff es a ->
  Eff es (Either Text a)
guarded rid inputs act =
  Exc.withException
    ( Exc.trySync
        ((Right <$> act) `catchError` \_ e -> pure (Left (shikiErrorMessage e)))
    )
    (interruptedHint inputs rid)
    >>= \case
      Left e -> pure (Left (Text.pack (Exc.displayException e)))
      Right outcome -> pure outcome

-- | Tell the operator their Job outlived the process, and how to catch up
--   with it later.
interruptedHint :: (IOE :> es) => JobInputs -> RunId -> AsyncException -> Eff es ()
interruptedHint inputs rid = \case
  UserInterrupt ->
    liftIO . TIO.hPutStrLn stderr $
      "shiki: interrupted; job "
        <> (inputs ^. #jobName)
        <> " keeps running; record its outcome later with 'shiki runs sync "
        <> Text.take 8 (showRunId rid)
        <> "'"
  _ -> pure ()

-- One write a minute keeps watcher liveness visible without coupling it to
-- the five-second Kubernetes polling interval. The display allows five
-- missed beats before classifying the run as unwatched.
heartbeatInterval :: Int
heartbeatInterval = 60_000_000

-- | Record the run as failed, say so on stdout as before, and end the command
--   with 'CommandFailed' — the message is already printed, so the top-level
--   handler prints nothing more and exits 1.
finalizeFailed ::
  (RunStore :> es, IOE :> es, Error CliError :> es) =>
  RunId ->
  UTCTime ->
  Text ->
  Eff es ()
finalizeFailed rid startedAt message = do
  endedAt <- liftIO getCurrentTime
  let durationMs = elapsedMs startedAt endedAt
  completeRun
    RunCompletion
      { runId = rid,
        status = Failed,
        exitCode = Nothing,
        endedAt = endedAt,
        durationMs = durationMs,
        logTail = Nothing,
        errorMessage = Just message,
        errorSummary = Nothing,
        errorSummarySource = "heuristic"
      }
  liftIO (TIO.putStrLn ("FAILED run " <> showRunId rid <> ": " <> message))
  throwError CommandFailed

finalizeOutcome ::
  (RunStore :> es, IOE :> es, Error CliError :> es) =>
  RunId ->
  UTCTime ->
  JobOutcome ->
  Eff es ()
finalizeOutcome rid startedAt outcome = do
  let completion = completionForOutcome rid startedAt outcome
      finalStatus = completion ^. #status
  completeRun completion
  liftIO . TIO.putStrLn $
    "run "
      <> showRunId rid
      <> " "
      <> Text.pack (show finalStatus)
      <> " job="
      <> outcome ^. #jobName
  case finalStatus of
    Succeeded -> pure ()
    _ -> throwError CommandFailed

-- | The row update for a Job that reached a terminal phase. Shared with
--   @shiki runs sync@ so a reconciled run is recorded exactly as a followed
--   one would have been.
completionForOutcome :: RunId -> UTCTime -> JobOutcome -> RunCompletion
completionForOutcome rid startedAt outcome =
  RunCompletion
    { runId = rid,
      status = case outcome ^. #phase of
        JobSucceeded -> Succeeded
        JobFailed _ -> Failed
        JobTimedOut -> Failed,
      exitCode = outcome ^. #exitCode,
      endedAt = outcome ^. #endedAt,
      durationMs = elapsedMs startedAt (outcome ^. #endedAt),
      logTail = outcome ^. #logTail,
      errorMessage = case outcome ^. #phase of
        JobSucceeded -> Nothing
        JobFailed t -> Just t
        JobTimedOut -> Just "timed out",
      errorSummary = outcome ^. #errorSummary,
      errorSummarySource = outcome ^. #errorSummarySource
    }

elapsedMs :: UTCTime -> UTCTime -> Int
elapsedMs startedAt endedAt =
  round ((realToFrac (diffUTCTime endedAt startedAt) :: Double) * 1000)

showRunId :: RunId -> Text
showRunId (RunId u) = Text.pack (show u)
