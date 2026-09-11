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
  )
where

import Control.Exception (SomeException, try)
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Data.Text.IO qualified as TIO
import Data.Time.Clock (diffUTCTime)
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (Statement)
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
import Shiki.Cli.Env (CliEnv (..))
import Shiki.K8s.Introspection
  ( DeploymentName (..),
    DeploymentSnapshot,
    Namespace (..),
    inspectDeployment,
  )
import Shiki.K8s.JobBuilder (JobInputs (..), generateJobName)
import Shiki.K8s.Runner
  ( JobOutcome (..),
    JobPhase (..),
    runJob,
    submitJob,
  )
import Shiki.Persistence.Run
  ( NewRun (..),
    RunCompletion (..),
    RunId (..),
    completeRunStatement,
    insertRunStatement,
    markRunRunningStatement,
    newRunId,
  )
import Shiki.Persistence.RunStatus (RunStatus (Failed, Succeeded))
import Shiki.Prelude hiding (Strict, argument)
import Shiki.Service.Config (ServiceConfig, ServiceName (..))
import Shiki.Service.Config.Dhall (loadServiceConfig)
import System.Exit (exitFailure)

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
runRun :: CliEnv -> RunOptions -> IO ()
runRun env opts = do
  cfg <-
    loadServiceConfig
      (opts ^. #configDir <> "/" <> Text.unpack (opts ^. #service) <> ".dhall")

  let ns =
        Namespace
          (fromMaybe (cfg ^. #defaultNamespace) (opts ^. #overrideNs))

  snap <-
    inspectDeployment
      (env ^. #client)
      ns
      (DeploymentName (cfg ^. #detectFromDeployment))
      (cfg ^. #containerName)

  rid <- newRunId
  startedAt <- getCurrentTime
  jobNm <- generateJobName (cfg ^. #name) startedAt

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

  runSessionUnit env insertRunStatement newRow
  runSessionUnit env markRunRunningStatement rid

  if opts ^. #noWait
    then noWaitPath env rid startedAt cfg snap inputs
    else waitPath env rid startedAt cfg snap inputs

noWaitPath ::
  CliEnv ->
  RunId ->
  UTCTime ->
  ServiceConfig ->
  DeploymentSnapshot ->
  JobInputs ->
  IO ()
noWaitPath env rid startedAt cfg snap inputs = do
  result <- try (submitJob (env ^. #client) cfg snap inputs)
  case result of
    Left (e :: SomeException) -> finalizeFailed env rid startedAt e
    Right () ->
      TIO.putStrLn
        ( "submitted job "
            <> (inputs ^. #jobName)
            <> " (run "
            <> showRunId rid
            <> ")"
        )

waitPath ::
  CliEnv ->
  RunId ->
  UTCTime ->
  ServiceConfig ->
  DeploymentSnapshot ->
  JobInputs ->
  IO ()
waitPath env rid startedAt cfg snap inputs = do
  result <- try (runJob (env ^. #client) cfg snap inputs 5 345600)
  case result of
    Left (e :: SomeException) -> finalizeFailed env rid startedAt e
    Right outcome -> finalizeOutcome env rid startedAt outcome

finalizeFailed :: CliEnv -> RunId -> UTCTime -> SomeException -> IO ()
finalizeFailed env rid startedAt e = do
  endedAt <- getCurrentTime
  let durationMs = elapsedMs startedAt endedAt
  runSessionUnit
    env
    completeRunStatement
    RunCompletion
      { runId = rid,
        status = Failed,
        exitCode = Nothing,
        endedAt = endedAt,
        durationMs = durationMs,
        logTail = Nothing,
        errorMessage = Just (Text.pack (show e)),
        errorSummary = Nothing,
        errorSummarySource = "heuristic"
      }
  TIO.putStrLn
    ("FAILED run " <> showRunId rid <> ": " <> Text.pack (show e))
  exitFailure

finalizeOutcome :: CliEnv -> RunId -> UTCTime -> JobOutcome -> IO ()
finalizeOutcome env rid startedAt outcome = do
  let endedAt = outcome ^. #endedAt
      durationMs = elapsedMs startedAt endedAt
      finalStatus = case outcome ^. #phase of
        JobSucceeded -> Succeeded
        JobFailed _ -> Failed
        JobTimedOut -> Failed
      errMsg = case outcome ^. #phase of
        JobSucceeded -> Nothing
        JobFailed t -> Just t
        JobTimedOut -> Just "timed out"
  runSessionUnit
    env
    completeRunStatement
    RunCompletion
      { runId = rid,
        status = finalStatus,
        exitCode = outcome ^. #exitCode,
        endedAt = endedAt,
        durationMs = durationMs,
        logTail = outcome ^. #logTail,
        errorMessage = errMsg,
        errorSummary = outcome ^. #errorSummary,
        errorSummarySource = outcome ^. #errorSummarySource
      }
  TIO.putStrLn
    ( "run "
        <> showRunId rid
        <> " "
        <> Text.pack (show finalStatus)
        <> " job="
        <> outcome ^. #jobName
    )
  case finalStatus of
    Succeeded -> pure ()
    _ -> exitFailure

elapsedMs :: UTCTime -> UTCTime -> Int
elapsedMs startedAt endedAt =
  round ((realToFrac (diffUTCTime endedAt startedAt) :: Double) * 1000)

runSessionUnit :: CliEnv -> Statement a () -> a -> IO ()
runSessionUnit env stmt input =
  Pool.use (env ^. #pool) (Session.statement input stmt)
    >>= either (error . ("shiki: persistence error: " <>) . show) pure

showRunId :: RunId -> Text
showRunId (RunId u) = Text.pack (show u)
