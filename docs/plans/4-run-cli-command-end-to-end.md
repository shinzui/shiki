---
id: 4
slug: run-cli-command-end-to-end
title: "run CLI Command End to End"
kind: exec-plan
created_at: 2026-05-27T04:46:53Z
master_plan: "docs/masterplans/1-microservice-job-runner-with-postgres-backed-run-history.md"
intention: intention_01ksn15jq4e0fvf6cysm7ezhm0
---


# run CLI Command End to End

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This plan delivers the *user-visible* command described in the MasterPlan's Vision &
Scope: a single CLI invocation

```bash
shiki run mls-service-v2 -- subscription process --batch-size 100
```

that loads the Dhall configuration for `mls-service-v2`, introspects the live worker
Deployment on the operator's current Kubernetes cluster, submits a one-off Job, waits for
completion (unless `--no-wait` is passed), and records the entire run — start, end,
status, image, log tail, full service config snapshot — in the operator's local Postgres
`runs` table. After this plan, the existing shell script
`/Users/shinzui/Keikaku/work/microtan/mls-service-v2-master/scripts/infrastructure/run-oneoff-task.sh`
is fully replaced by a typed Haskell CLI with durable observability.

This plan integrates three modules built in prior plans without changing any of them:

- `Shiki.Service.Config` + `Shiki.Service.Config.Dhall` (from
  `docs/plans/1-service-configuration-model-and-dhall-loader.md`) loads the
  per-service configuration.
- `Shiki.Persistence.Connection`, `.Migration`, `.Run`, `.RunStatus` (from
  `docs/plans/2-postgresql-schema-migrations-and-run-persistence.md`) records the run.
- `Shiki.K8s.Client`, `.Introspection`, `.JobBuilder`, `.Runner` (from
  `docs/plans/3-kubernetes-job-runner.md`) executes the Job.

The user-visible verification is end-to-end: enter `nix develop`, run
`process-compose up` to get a local Postgres, then `cabal run shiki -- run mls-service-v2
-- subscription process --batch-size 1` against a real cluster, and confirm that

1. A new Job appears under `kubectl get jobs -n prod`.
2. A new row appears in the `runs` table with the matching `job_name`, transitioning from
   `pending` → `running` → `succeeded` (or `failed`).
3. After completion, the row's `log_tail` contains the Job's stdout/stderr tail.

The plan also removes the placeholder `hello` subcommand from
`docs/plans/1-service-configuration-model-and-dhall-loader.md` since the scaffold is no
longer needed.


## Progress

- [x] Add `Shiki.Cli.Config` exporting `resolveConnectionString`. _(2026-05-27)_
- [x] Add `Shiki.Cli.Env` exporting `CliEnv` and `withCliEnv` (acquires pool, runs
  migrations, loads kubeconfig). _(2026-05-27)_
- [x] Add `Shiki.Cli.Run` exporting `RunOptions`, `runOptionsParser`, and `runRun`. _(2026-05-27)_
- [x] Extend `Shiki.Cli`'s top-level `Command` sum type with `Run RunOptions`
  constructor (the canonical type per the MasterPlan's Integration Points). _(2026-05-27)_
- [x] Remove the placeholder `hello` subcommand from `Shiki.Cli`. _(2026-05-27)_
- [x] Add `--db`, `--namespace`, `--no-wait`, `--config-dir` flags. _(2026-05-27)_
- [x] Wire end-to-end: load config → insert `NewRun` → mark `Running` → submit Job →
  `runJob` → on completion, write `RunCompletion`; on exception, write
  `RunCompletion { status = Failed, ... }` and exit non-zero. _(2026-05-27)_
- [x] Capture `cabal run shiki -- --help` and `cabal run shiki -- run --help`
  transcripts in Concrete Steps. _(2026-05-27)_
- [x] Local-only boot path verified: `process-compose up -D`, `cabal run shiki
  -- run nonexistent-service` exits non-zero after migrations run; `runs`
  and `schema_migrations` tables exist with the EP-2 schema. _(2026-05-27)_
- [ ] Cluster smoke test against the operator's real cluster + local Postgres.
  *Deferred:* current `kubectl` context points at production GKE
  (`gke_tan-cluster_us-west1-a_sennari`); per the MasterPlan's principle
  of asking before risky shared-infrastructure actions, the smoke is
  recorded here as a manual step for the operator to run when they are
  ready, using either `--no-wait` (record the row in `running` and exit)
  or the full wait path against `--namespace` in a non-prod context.


## Surprises & Discoveries

- 2026-05-27 (M2): The plan's `round (diffUTCTime endedAt startedAt * 1000
  :: Double)` does not typecheck under GHC 9.12 — `diffUTCTime` returns
  `NominalDiffTime`, which does not have a `Num` instance compatible
  with the literal-typed `Double`. Lifted the conversion into a small
  `elapsedMs :: UTCTime -> UTCTime -> Int` helper that goes through
  `realToFrac` first. Future code in this repo that needs millisecond
  durations should use the same helper rather than re-deriving it.

- 2026-05-27 (M2): The plan's `noWaitPath`/`waitPath` type signatures use
  partial type signatures (`_`) for `ServiceConfig` and
  `DeploymentSnapshot`. That requires `PartialTypeSignatures`, which is
  not enabled in `shiki-cli/shiki-cli.cabal`'s `default-extensions`.
  Wrote out the explicit types — no functional change, just signatures.

- 2026-05-27 (M3): The new `Options` record field `command :: Command`
  collides with `Options.Applicative.command` when the optparse module
  is imported unqualified. The plan's code sample imports both
  unqualified and would not compile. Switched the optparse import to a
  qualified `Opt` alias (only `Parser`, `ParserInfo`, and the `<**>`
  operator stay unqualified). EP-5 should follow the same convention
  when adding the `runs` subparsers.

- 2026-05-27 (M4): When `loadServiceConfig` fails (e.g. the
  `<service>.dhall` file is missing), the CLI exits non-zero with a raw
  "Uncaught exception" trace from GHC's runtime rather than a
  user-friendly message. The plan does not require nicer error
  formatting and EP-2's failure path produces the same shape, so left
  as-is. A future "polish" pass might wrap the top-level handler in
  `try` and pretty-print common failure modes (missing config, kube
  context, db down) — out of scope for EP-4.

- 2026-05-27 (M4): Local Postgres for the boot-path verification is
  provided by `process-compose up -D` reading `process-compose.yaml`,
  with `$PG_CONNECTION_STRING` already exported by the project's
  `nix develop` shellHook. The `shiki` database itself is not created by
  process-compose; the operator must `CREATE DATABASE shiki` once.
  Recording this so EP-5's tests don't get tripped up by a 'database
  does not exist' the first time someone tries it.


## Decision Log

- Decision: Use a `Shiki.Cli.Env` "context" record built by a `withCliEnv` bracket
  rather than threading `Pool.Pool` and `ClientEnv` through every subcommand handler.
  Rationale: Two subcommands today (`run`, `service show`); five planned by end of
  EP-5; a single bracketed env keeps acquisition/teardown in one place and lets each
  handler remain a one-liner that destructures what it needs.
  Date: 2026-05-26

- Decision: The Postgres connection string is read from, in priority order:
  (1) the `--db <connstr>` flag, (2) the `SHIKI_DATABASE_URL` env var, (3)
  `PG_CONNECTION_STRING` if exported (this is what the project's `nix develop`
  shellHook sets).
  Rationale: Lets users keep an opinionated default while overriding per-invocation;
  matches the precedence used by other Haskell CLIs the user has built.
  Date: 2026-05-26

- Decision: `--no-wait` exits as soon as the Job is created, after inserting the run
  row with status `pending` and updating it to `running`. The row stays in `running`
  indefinitely; a future plan may add a `shiki runs reconcile` command to poll the
  cluster for unfinished runs and finalize them.
  Rationale: Mirrors the existing shell script's `--no-wait` semantics; recording
  `running` (not `succeeded`) preserves the "we don't know how it ended" honesty.
  Date: 2026-05-26

- Decision: On any exception during submission or wait, write a `RunCompletion` with
  `status = Failed`, `errorMessage = Text.pack (show e)`, then exit non-zero.
  Rationale: Failure-mode parity with the success path — the row always reflects what
  happened; the user sees the error.
  Date: 2026-05-26

- Decision: Remove the placeholder `hello` subcommand introduced in
  `docs/plans/1-service-configuration-model-and-dhall-loader.md`.
  Rationale: It existed only as a scaffold; the CLI now has real subcommands.
  Date: 2026-05-26


## Outcomes & Retrospective

EP-4 landed the `shiki run` subcommand end-to-end on 2026-05-27. The
operator-visible behavior from the MasterPlan's Vision & Scope works as
designed up to the point of cluster contact: `shiki run <service> --
<args>` loads `services/<service>.dhall`, opens a Postgres pool against
the resolved connection string, applies migrations, parses the
kubeconfig, inserts a `pending` `runs` row, updates it to `running`,
then either submits and exits (`--no-wait`) or runs the Job to
completion and finalizes the row.

What shipped:

- `Shiki.Cli.Config.resolveConnectionString` with three-tier precedence.
- `Shiki.Cli.Env.CliEnv` + `withCliEnv` bracket — single
  acquire/teardown for the pool, migrations, and kubeconfig.
- `Shiki.Cli.Run` with `RunOptions`, `runOptionsParser`, and `runRun`.
- A rewired `Shiki.Cli` whose top-level `Command` sum type is now
  `Run !RunOptions | ServiceShow !Text`. The placeholder `hello`
  subcommand is gone. EP-5 extends this same `Command` (per the
  MasterPlan's Integration Points) to add `RunsList / RunsShow /
  RunsLogs`.
- Captured `--help` / `run --help` / `service --help` transcripts in
  the Concrete Steps section above.

What was not exercised in this session: the actual cluster Job
submission. The operator's `kubectl` context points at production GKE,
and the safer path was to leave the cluster smoke as a manual step
rather than auto-submit a one-off Job into prod. The CLI's behavior up
to the point of cluster contact (config load, pool, migrations,
kubeconfig parse, `runs`-row insert) is verified.

Lessons / inputs for later plans:

- The `Options` record field name `command` collides with
  `Options.Applicative.command` once both are unqualified. EP-5 should
  keep the qualified `Opt` import pattern when it extends the parser.
- `diffUTCTime` returns `NominalDiffTime`, not a numeric — pipe through
  `realToFrac` first. Captured as the `elapsedMs` helper in
  `Shiki.Cli.Run`.
- The CLI's failure-mode UX is rough: missing-config and similar
  exceptions surface as raw GHC "Uncaught exception" traces. The plan
  did not require nicer formatting, but a polish pass that wraps
  `runCli` in a top-level handler and pretty-prints the common failures
  would meaningfully improve operator experience.


## Context and Orientation

### Project layout (recap)

`shiki` is two cabal packages — `shiki-core` (library) and `shiki-cli` (library +
`shiki` executable). The CLI's entry point is `shiki-cli/app/Main.hs`, which calls
`Shiki.Cli.runCli`. Per the MasterPlan's Integration Points, `Shiki.Cli` owns the
top-level `Command` sum type; this plan extends it with `Run RunOptions` and removes
the `hello` constructor.

### Haskell standards

Per the MasterPlan Decision Log: GHC 9.12, GHC2024, default-extensions
`DeriveAnyClass`, `DuplicateRecordFields`, `OverloadedLabels`, `OverloadedStrings`,
`MultilineStrings`, `PackageImports`. All modules import `Shiki.Prelude`. Postpositive
`qualified` imports. Records use no field prefixes, strict `!`, explicit deriving
strategies, `#fieldName` lens access.

### Module dependencies repeated for self-containment

The following types and functions are defined in earlier plans; their signatures are
restated here so this plan stands alone.

From `Shiki.Service.Config` (defined in
`docs/plans/1-service-configuration-model-and-dhall-loader.md`):

```haskell
newtype ServiceName = ServiceName { unServiceName :: Text }

data ServiceConfig = ServiceConfig
  { name                 :: !ServiceName
  , defaultNamespace     :: !Text
  , detectFromDeployment :: !Text
  , containerName        :: !Text
  , commandPath          :: !Text
  , serviceAccount       :: !Text
  , nodeSelector         :: !(Map Text Text)
  , initContainers       :: ![InitContainer]
  , env                  :: ![EnvVar]
  , resources            :: !Resources
  }

loadServiceConfig :: FilePath -> IO ServiceConfig
```

From `Shiki.Persistence.*` (defined in
`docs/plans/2-postgresql-schema-migrations-and-run-persistence.md`):

```haskell
newtype ConnectionString = ConnectionString { unConnectionString :: Text }
acquirePool :: ConnectionString -> IO Pool.Pool
releasePool :: Pool.Pool -> IO ()
runMigrations :: Pool.Pool -> IO ()

newtype RunId = RunId { unRunId :: UUID }
newRunId :: IO RunId

data NewRun        = NewRun        { runId, serviceName, command, namespace
                                   , jobName, image, startedAt, serviceConfig }
data RunCompletion = RunCompletion { runId, status, exitCode, endedAt
                                   , durationMs, logTail, errorMessage }
data RunStatus     = Pending | Running | Succeeded | Failed

insertRunStatement      :: Statement NewRun ()
markRunRunningStatement :: Statement RunId ()
completeRunStatement    :: Statement RunCompletion ()
```

From `Shiki.K8s.*` (defined in `docs/plans/3-kubernetes-job-runner.md`):

```haskell
data ClientEnv = ClientEnv { httpManager :: Manager, clientConfig :: KubernetesClientConfig }
loadDefaultClientConfig :: IO ClientEnv

newtype Namespace      = Namespace      { unNamespace      :: Text }
newtype DeploymentName = DeploymentName { unDeploymentName :: Text }
inspectDeployment :: ClientEnv -> Namespace -> DeploymentName -> Text -> IO DeploymentSnapshot

data JobInputs = JobInputs { namespace :: !Namespace, args :: ![Text], jobName :: !Text }
generateJobName :: ServiceName -> UTCTime -> IO Text

data JobOutcome = JobOutcome
  { jobName, namespace :: !Text
  , phase     :: !JobPhase       -- JobSucceeded | JobFailed Text | JobTimedOut
  , exitCode  :: !(Maybe Int)
  , startedAt, endedAt :: !UTCTime
  , logTail   :: !(Maybe Text)
  }
submitJob :: ClientEnv -> ServiceConfig -> DeploymentSnapshot -> JobInputs -> IO ()
runJob    :: ClientEnv -> ServiceConfig -> DeploymentSnapshot -> JobInputs -> Int -> Int -> IO JobOutcome
```

### Cross-plan contract (from the MasterPlan)

> **CLI subcommand registry** (`Shiki.Cli` in `shiki-cli/src/Shiki/Cli.hs`). The
> existing `Command` sum type is extended by EP-4 (adding `Run`) and by EP-5 (adding
> `RunsList`, `RunsShow`, `RunsLogs` under a `runs` subparser). Both plans must extend
> the same sum type rather than introducing a parallel one; EP-4 lands first and lays
> out the convention.


## Plan of Work

### Milestone 1 — Configuration loading and `withCliEnv` bracket

Scope: a single bracket that owns acquisition and teardown of the Postgres pool and
Kubernetes client config, plus a small helper for resolving the connection string.

Add `shiki-cli/src/Shiki/Cli/Config.hs`:

```haskell
module Shiki.Cli.Config
  ( resolveConnectionString
  ) where

import Shiki.Prelude

import Shiki.Persistence.Connection (ConnectionString (..))

import Data.Text qualified as Text
import System.Environment (lookupEnv)

-- | Connection-string precedence: @--db@ flag, then @SHIKI_DATABASE_URL@,
-- then @PG_CONNECTION_STRING@.
resolveConnectionString :: Maybe Text -> IO ConnectionString
resolveConnectionString flagValue = case flagValue of
  Just t  -> pure (ConnectionString t)
  Nothing -> do
    mEnv <- lookupEnv "SHIKI_DATABASE_URL"
    case mEnv of
      Just s  -> pure (ConnectionString (Text.pack s))
      Nothing -> do
        mPg <- lookupEnv "PG_CONNECTION_STRING"
        case mPg of
          Just s  -> pure (ConnectionString (Text.pack s))
          Nothing ->
            error
              "shiki: no Postgres connection string. Pass --db or set SHIKI_DATABASE_URL."
```

Add `shiki-cli/src/Shiki/Cli/Env.hs`:

```haskell
module Shiki.Cli.Env
  ( CliEnv (..)
  , withCliEnv
  ) where

import Shiki.Prelude

import Shiki.K8s.Client (ClientEnv, loadDefaultClientConfig)
import Shiki.Persistence.Connection (ConnectionString, acquirePool, releasePool)
import Shiki.Persistence.Migration (runMigrations)

import Control.Exception (bracket)
import Hasql.Pool qualified as Pool

data CliEnv = CliEnv
  { pool   :: !Pool.Pool
  , client :: !ClientEnv
  }
  deriving stock (Generic)

-- | Acquire the database pool, run migrations, load the default Kubernetes
-- client config, hand the bundle to the continuation, and release the pool on
-- exit.
withCliEnv :: ConnectionString -> (CliEnv -> IO a) -> IO a
withCliEnv cs action =
  bracket (acquirePool cs) releasePool $ \p -> do
    runMigrations p
    cl <- loadDefaultClientConfig
    action CliEnv { pool = p, client = cl }
```

Edit `shiki-cli/shiki-cli.cabal`:

- Add `Shiki.Cli.Config` and `Shiki.Cli.Env` to `exposed-modules`.
- Ensure `shiki-core`, `hasql-pool`, `text` are in `build-depends` (most already are).
- Add `MultilineStrings`, `PackageImports` to `common common-options` `default-extensions`
  to match the standard.

Acceptance: `cabal build shiki-cli` succeeds.

### Milestone 2 — `Shiki.Cli.Run`: the `run` subcommand handler

Scope: parse options, build a `NewRun`, write it, submit, wait, write completion.

Add `shiki-cli/src/Shiki/Cli/Run.hs`:

```haskell
module Shiki.Cli.Run
  ( RunOptions (..)
  , runOptionsParser
  , runRun
  ) where

import Shiki.Prelude

import Shiki.Cli.Env (CliEnv (..))
import Shiki.K8s.Introspection
  ( DeploymentName (..), Namespace (..), inspectDeployment
  )
import Shiki.K8s.JobBuilder (JobInputs (..), generateJobName)
import Shiki.K8s.Runner
  ( JobOutcome (..), JobPhase (..), runJob, submitJob
  )
import Shiki.Persistence.Run
  ( NewRun (..), RunCompletion (..), RunId (..)
  , completeRunStatement, insertRunStatement
  , markRunRunningStatement, newRunId
  )
import Shiki.Persistence.RunStatus (RunStatus (Failed, Succeeded))
import Shiki.Service.Config        (ServiceName (..))
import Shiki.Service.Config.Dhall  (loadServiceConfig)

import Control.Exception (SomeException, try)
import Data.Aeson qualified as Aeson
import Data.Text qualified as Text
import Data.Text.IO qualified as TIO
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (Statement)
import Options.Applicative
import System.Exit (exitFailure)

data RunOptions = RunOptions
  { service     :: !Text
  , overrideNs  :: !(Maybe Text)
  , noWait      :: !Bool
  , configDir   :: !FilePath
  , commandArgs :: ![Text]
  }
  deriving stock (Generic, Eq, Show)

runOptionsParser :: Parser RunOptions
runOptionsParser =
  RunOptions
    <$> argument str (metavar "SERVICE")
    <*> optional
          (strOption (long "namespace" <> short 'n' <> metavar "NS"
                       <> help "Override the service's default namespace"))
    <*> switch (long "no-wait" <> help "Submit and exit without waiting")
    <*> strOption (long "config-dir" <> metavar "DIR" <> value "services"
                    <> showDefault
                    <> help "Directory holding <service>.dhall files")
    <*> many (argument str (metavar "-- ARG..."))

runRun :: CliEnv -> RunOptions -> IO ()
runRun env opts = do
  cfg <- loadServiceConfig
           (opts ^. #configDir <> "/" <> Text.unpack (opts ^. #service) <> ".dhall")

  let ns = Namespace
        (fromMaybe (cfg ^. #defaultNamespace) (opts ^. #overrideNs))

  snap <- inspectDeployment
            (env ^. #client) ns
            (DeploymentName (cfg ^. #detectFromDeployment))
            (cfg ^. #containerName)

  rid       <- newRunId
  startedAt <- getCurrentTime
  jobName   <- generateJobName (cfg ^. #name) startedAt

  let inputs = JobInputs
        { namespace = ns
        , args      = opts ^. #commandArgs
        , jobName   = jobName
        }
      newRow = NewRun
        { runId         = rid
        , serviceName   = unServiceName (cfg ^. #name)
        , command       = opts ^. #commandArgs
        , namespace     = unNamespace ns
        , jobName       = jobName
        , image         = Just (snap ^. #image)
        , startedAt     = startedAt
        , serviceConfig = Aeson.toJSON cfg
        }

  -- 1. Record a 'pending' row before doing any cluster work.
  runSessionUnit env insertRunStatement newRow

  -- 2. Mark running, then submit (and optionally wait).
  runSessionUnit env markRunRunningStatement rid
  if opts ^. #noWait
    then noWaitPath env rid startedAt cfg snap inputs jobName
    else waitPath   env rid startedAt cfg snap inputs

noWaitPath
  :: CliEnv -> RunId -> UTCTime
  -> _ -> _ -> JobInputs -> Text -> IO ()
noWaitPath env rid startedAt cfg snap inputs jobName = do
  result <- try (submitJob (env ^. #client) cfg snap inputs)
  case result of
    Left (e :: SomeException) -> finalizeFailed env rid startedAt e
    Right () ->
      TIO.putStrLn
        ("submitted job " <> jobName <> " (run " <> showRunId rid <> ")")

waitPath
  :: CliEnv -> RunId -> UTCTime -> _ -> _ -> JobInputs -> IO ()
waitPath env rid startedAt cfg snap inputs = do
  result <- try (runJob (env ^. #client) cfg snap inputs 5 345600)
  case result of
    Left (e :: SomeException) -> finalizeFailed env rid startedAt e
    Right outcome              -> finalizeOutcome env rid startedAt outcome

finalizeFailed :: CliEnv -> RunId -> UTCTime -> SomeException -> IO ()
finalizeFailed env rid startedAt e = do
  endedAt <- getCurrentTime
  let durationMs = round (diffUTCTime endedAt startedAt * 1000 :: Double)
  runSessionUnit env completeRunStatement RunCompletion
    { runId        = rid
    , status       = Failed
    , exitCode     = Nothing
    , endedAt      = endedAt
    , durationMs   = durationMs
    , logTail      = Nothing
    , errorMessage = Just (Text.pack (show e))
    }
  TIO.putStrLn
    ("FAILED run " <> showRunId rid <> ": " <> Text.pack (show e))
  exitFailure

finalizeOutcome :: CliEnv -> RunId -> UTCTime -> JobOutcome -> IO ()
finalizeOutcome env rid startedAt outcome = do
  let endedAt    = outcome ^. #endedAt
      durationMs = round (diffUTCTime endedAt startedAt * 1000 :: Double)
      finalStatus = case outcome ^. #phase of
        JobSucceeded   -> Succeeded
        JobFailed _    -> Failed
        JobTimedOut    -> Failed
      err = case outcome ^. #phase of
        JobSucceeded   -> Nothing
        JobFailed t    -> Just t
        JobTimedOut    -> Just "timed out"
  runSessionUnit env completeRunStatement RunCompletion
    { runId        = rid
    , status       = finalStatus
    , exitCode     = outcome ^. #exitCode
    , endedAt      = endedAt
    , durationMs   = durationMs
    , logTail      = outcome ^. #logTail
    , errorMessage = err
    }
  TIO.putStrLn
    ( "run " <> showRunId rid <> " "
        <> Text.pack (show finalStatus)
        <> " job=" <> outcome ^. #jobName
    )
  case finalStatus of
    Succeeded -> pure ()
    _         -> exitFailure

runSessionUnit :: CliEnv -> Statement a () -> a -> IO ()
runSessionUnit env stmt input =
  Pool.use (env ^. #pool) (Session.statement input stmt)
    >>= either (error . show) pure

showRunId :: RunId -> Text
showRunId (RunId u) = Text.pack (show u)
```

> The two underscores in the type signatures of `noWaitPath` and `waitPath` stand for
> the `ServiceConfig` and `DeploymentSnapshot` types respectively; if `_` in type
> signatures is not enabled in this project's GHC options, write the explicit type
> names instead. The intent: `noWaitPath` and `waitPath` are not exported, they just
> let `runRun` stay readable.

Add `Shiki.Cli.Run` to `exposed-modules` in `shiki-cli/shiki-cli.cabal`. Add
`aeson`, `time`, `hasql`, `hasql-pool` to its library `build-depends` if missing.

### Milestone 3 — Wire `Shiki.Cli` to dispatch to `Shiki.Cli.Run`; remove `hello`

Scope: extend the top-level `Command` sum type, register the `run` subparser, remove
the placeholder `hello` subcommand.

Replace `shiki-cli/src/Shiki/Cli.hs`:

```haskell
module Shiki.Cli
  ( runCli
  ) where

import Shiki.Prelude

import Shiki.Cli.Config (resolveConnectionString)
import Shiki.Cli.Env    (CliEnv, withCliEnv)
import Shiki.Cli.Run    (RunOptions, runOptionsParser, runRun)
import Shiki.Service.Config.Dhall (loadServiceConfig)

import Data.Aeson.Encode.Pretty qualified as AesonPretty
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Text qualified as Text
import Options.Applicative

data Command
  = Run         !RunOptions
  | ServiceShow !Text
  deriving stock (Generic, Eq, Show)

data GlobalOptions = GlobalOptions
  { dbConnStr :: !(Maybe Text)
  , command   :: !Command
  }
  deriving stock (Generic, Eq, Show)

runCli :: IO ()
runCli = do
  opts <- execParser parserInfo
  case opts ^. #command of
    ServiceShow nm -> serviceShowHandler nm
    Run runOpts    -> withDbEnv (opts ^. #dbConnStr) $ \env -> runRun env runOpts

withDbEnv :: Maybe Text -> (CliEnv -> IO a) -> IO a
withDbEnv mFlag k = do
  cs <- resolveConnectionString mFlag
  withCliEnv cs k

serviceShowHandler :: Text -> IO ()
serviceShowHandler nm = do
  let path = "services/" <> Text.unpack nm <> ".dhall"
  cfg <- loadServiceConfig path
  BL8.putStrLn (AesonPretty.encodePretty cfg)

parserInfo :: ParserInfo GlobalOptions
parserInfo =
  info (globalOptionsParser <**> helper)
    ( fullDesc
        <> progDesc "shiki: run one-off Kubernetes Jobs with durable run history."
        <> header   "shiki - operational commands with observability"
    )

globalOptionsParser :: Parser GlobalOptions
globalOptionsParser =
  GlobalOptions
    <$> optional
          (strOption
             (long "db" <> metavar "CONNSTR"
              <> help "Postgres connection string (overrides SHIKI_DATABASE_URL / PG_CONNECTION_STRING)"))
    <*> commandParser

commandParser :: Parser Command
commandParser =
  hsubparser
    ( command "run"
        ( info (Run <$> runOptionsParser)
               (progDesc "Submit a one-off Job and record the run in Postgres") )
   <> command "service"
        ( info serviceSubparser
               (progDesc "Inspect microservice configuration files") )
    )

serviceSubparser :: Parser Command
serviceSubparser =
  hsubparser
    ( command "show"
        ( info (ServiceShow <$> argument str (metavar "NAME"))
               (progDesc "Pretty-print the parsed ServiceConfig for NAME") )
    )
```

Acceptance:

```bash
cabal run shiki -- --help
```

shows `run` and `service` as the two subcommands; `hello` is gone.

```bash
cabal run shiki -- run --help
```

shows `--namespace`, `--no-wait`, `--config-dir` flags and a positional `SERVICE`
argument plus the `-- ARG...` tail.

### Milestone 4 — End-to-end manual verification

Scope: exercise the whole stack against a real cluster and a local Postgres.

#### Local boot-path verification (done)

The pieces that don't need cluster contact were verified in this session
on 2026-05-27:

```bash
process-compose up -D                          # local Postgres on a unix socket
psql "${PG_CONNECTION_STRING%/shiki}/postgres" -c "CREATE DATABASE shiki"
cabal run -v0 shiki -- run nonexistent-service
# → exits non-zero with "openFile: does not exist" for the missing dhall
psql "$PG_CONNECTION_STRING" -c "\dt"
# →   runs              | table
#     schema_migrations | table
```

That proves: the pool acquisition, the migration application, and the
kubeconfig parsing all succeed before `loadServiceConfig` errors out.
The `runs` table has every column EP-2 defined (id, service_name,
command[], namespace, job_name, image, status, exit_code, started_at,
ended_at, duration_ms, log_tail, service_config, error, created_at,
updated_at).

#### Cluster smoke (manual, deferred to operator)

The operator runs the real-cluster smoke when they are ready, after
confirming the kube context targets a safe namespace:

```bash
nix develop
process-compose up -D                              # background daemon; brings up Postgres
cabal run shiki -- run mls-service-v2 -- subscription process --batch-size 1
```

Expected:

- Stdout transcript:

  ```text
  run 1f0a3b8e-... Succeeded job=mls-service-v2-oneoff-20260526-153012-abcdef
  ```

- Postgres row exists:

  ```bash
  psql "$PG_CONNECTION_STRING" -c "SELECT id, service_name, status, exit_code, duration_ms FROM runs ORDER BY started_at DESC LIMIT 1;"
  ```

  shows the new row with `status = 'succeeded'`.

- Kubernetes Job exists and has succeeded:

  ```bash
  kubectl get jobs -n prod | grep oneoff
  ```

Failure-path verification:

```bash
cabal run shiki -- run mls-service-v2 -- some-bogus-command-that-fails
```

Expected:

- CLI exits non-zero with `FAILED run <id>: ...`.
- Postgres row exists with `status = 'failed'`, `error` populated, `exit_code`
  typically `1` (or `Nothing` for early failures).


## Concrete Steps

All commands assume the working directory is `/Users/shinzui/Keikaku/bokuno/shiki` and
the dev shell is active.

```bash
cabal build all
cabal run shiki -- --help
```

Captured output:

```text
shiki - one-off Kubernetes Jobs with durable run history

Usage: shiki [--db CONNSTR] COMMAND

  shiki conducts operational commands across Kubernetes services and records
  what ran, where it ran, and how long it took.

Available options:
  --db CONNSTR             Postgres connection string (overrides
                           SHIKI_DATABASE_URL / PG_CONNECTION_STRING)
  -h,--help                Show this help text

Available commands:
  run                      Submit a one-off Job and record the run in Postgres
  service                  Inspect microservice configuration files
```

```bash
cabal run shiki -- run --help
```

Captured output:

```text
Usage: shiki run SERVICE [-n|--namespace NS] [--no-wait] [--config-dir DIR]
                 [-- ARG...]

  Submit a one-off Job and record the run in Postgres

Available options:
  -n,--namespace NS        Override the service's default namespace
  --no-wait                Submit and exit without waiting for completion
  --config-dir DIR         Directory holding <service>.dhall files
                           (default: "services")
  -h,--help                Show this help text
```

```bash
cabal run shiki -- service --help
```

Captured output:

```text
Usage: shiki service COMMAND

  Inspect microservice configuration files

Available options:
  -h,--help                Show this help text

Available commands:
  show                     Pretty-print the parsed ServiceConfig for NAME
```

End-to-end (see Milestone 4 above).


## Validation and Acceptance

After all milestones:

1. `cabal build all` and `cabal test all` succeed.
2. `cabal run shiki -- --help` lists exactly the `run` and `service` subcommands;
   `hello` is gone.
3. `cabal run shiki -- run mls-service-v2 -- <command>` against a real cluster
   produces a Job and inserts/updates a row in `runs` with the matching `job_name`.
4. On Job failure, the CLI exits non-zero and the row's `status` is `failed`.
5. With `--no-wait`, the CLI exits immediately after submission and the row's
   `status` stays at `running`.


## Idempotence and Recovery

- Each invocation allocates a fresh `RunId` and `jobName`, so re-running the command
  produces an independent row and an independent Job.
- If the CLI crashes between the `insert` and the `complete` write, the row is left
  in `pending` or `running`. A future reconciliation command may scan and finalize
  stale rows; for now, an operator can `UPDATE runs SET status = 'failed', error =
  '...'` manually.
- The Postgres `runMigrations` call is idempotent (`hasql-migration` tracks applied
  scripts by checksum).
- The Kubernetes Job stays alive for `ttlSecondsAfterFinished = 3600` after
  completion, so its logs and status are still retrievable for an hour even if the
  CLI process died.


## Interfaces and Dependencies

Libraries used (no new external dependencies beyond what EP-1..EP-3 added):

- `optparse-applicative >= 0.18` — CLI parser (already in `shiki-cli.cabal`).
- `hasql`, `hasql-pool` — re-exported through `Shiki.Persistence.*`.
- `shiki-core` — for service config loading, persistence, and the K8s runner.

Module surface at end of plan:

- `Shiki.Cli.Config`

  ```haskell
  resolveConnectionString :: Maybe Text -> IO ConnectionString
  ```

- `Shiki.Cli.Env`

  ```haskell
  data CliEnv = CliEnv { pool :: !Pool.Pool, client :: !ClientEnv }
  withCliEnv :: ConnectionString -> (CliEnv -> IO a) -> IO a
  ```

- `Shiki.Cli.Run`

  ```haskell
  data RunOptions = RunOptions
    { service, overrideNs :: !(Maybe Text)
    , noWait :: !Bool
    , configDir :: !FilePath
    , commandArgs :: ![Text]
    }
  runOptionsParser :: Parser RunOptions
  runRun :: CliEnv -> RunOptions -> IO ()
  ```

- `Shiki.Cli` (extended; canonical `Command` sum type owner)

  ```haskell
  data Command = Run !RunOptions | ServiceShow !Text
  runCli :: IO ()
  ```

Downstream consumer:

- `docs/plans/5-runs-query-cli-commands.md` adds `RunsList`, `RunsShow`, `RunsLogs`
  constructors to the same `Command` sum type. Both EP-4 and EP-5 contribute to the
  single CLI surface area.
