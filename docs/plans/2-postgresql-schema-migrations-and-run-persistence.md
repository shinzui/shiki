---
id: 2
slug: postgresql-schema-migrations-and-run-persistence
title: "PostgreSQL Schema Migrations and Run Persistence"
kind: exec-plan
created_at: 2026-05-27T04:46:52Z
master_plan: "docs/masterplans/1-microservice-job-runner-with-postgres-backed-run-history.md"
---


# PostgreSQL Schema Migrations and Run Persistence

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

`shiki` records every one-off Kubernetes Job it submits into a local PostgreSQL database so
operators can later answer "what ran in prod last Tuesday, by whom, with what arguments, and
how did it end?" Today no such recording exists; the existing shell script at
`/Users/shinzui/Keikaku/work/microtan/mls-service-v2-master/scripts/infrastructure/run-oneoff-task.sh`
prints a job name to stdout and forgets it.

This plan delivers the persistence layer in isolation: a `runs` PostgreSQL table, a
migration system that creates it from versioned SQL files, and a Haskell module
`Shiki.Persistence.Run` that exposes typed insert/update/query statements over that table.
At the end of this plan, a reader can start the bundled local Postgres (via
`process-compose up`), run `cabal test shiki-core` and watch a tasty test create an
ephemeral database, run the migrations, insert a synthetic `RunRecord`, update it to
`Succeeded`, and read it back — all without any Kubernetes contact.

The `runs` table and `RunRecord` type defined here are the canonical shared vocabulary for
runs across the rest of the MasterPlan:

- `docs/plans/4-run-cli-command-end-to-end.md` writes one row per `shiki run` invocation
  (insert at submit, update on completion) using the statements exported here.
- `docs/plans/5-runs-query-cli-commands.md` reads rows back using the statements exported
  here for the `runs list`, `runs show`, and `runs logs` subcommands.

Both consumers must use these statements verbatim; if a new column is needed, add a new
migration in this plan and extend `RunRecord` here, never write ad-hoc SQL from the
consumer side.


## Progress

- [ ] Create `shiki-core/sql/migrations/` with the initial migration file
  `001-create-runs.sql`.
- [ ] Add `Shiki.Persistence.RunStatus` exporting the `RunStatus` ADT with text codec.
- [ ] Add `Shiki.Persistence.Run` exporting `RunRecord`, `NewRun`, `RunCompletion`, and
  hasql `Statement` values for insert, update-on-completion, and queries.
- [ ] Add `Shiki.Persistence.Connection` exporting a thin wrapper around `Hasql.Pool` for
  acquiring a pool from a connection string.
- [ ] Add `Shiki.Persistence.Migration` exporting
  `runMigrations :: Hasql.Pool.Pool -> IO ()` that loads every script from
  `shiki-core/sql/migrations/` and applies it.
- [ ] Wire `data-files: sql/migrations/*.sql` (so `Paths_shiki_core` can locate them at
  runtime).
- [ ] Add a tasty test that spins up an ephemeral Postgres, runs migrations, inserts a
  `RunRecord`, completes it, lists it, and asserts on the persisted shape.
- [ ] `cabal test shiki-core` clean; capture transcript in Concrete Steps.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Use `hasql` + `hasql-pool` + `shinzui/hasql-migration` (mori name) rather than
  postgresql-simple, persistent, or beam.
  Rationale: Matches the user's existing Haskell projects; `hasql-migration` already lives
  in the user's mori registry at `/Users/shinzui/Keikaku/hub/haskell/hasql-migration`; the
  typed `Statement` API is low-ceremony for a CLI.
  Date: 2026-05-26

- Decision: `RunStatus` is a four-element ADT — `Pending | Running | Succeeded | Failed` —
  stored as a `text` column with a `CHECK` constraint rather than a Postgres `enum`.
  Rationale: `text` is trivial to migrate when we add states (e.g., `Cancelled`); we
  validate at the Haskell boundary; the canonical `RunStatus` codec is the single source of
  truth.
  Date: 2026-05-26

- Decision: Use `ephemeral-pg` (mori name `shinzui/ephemeral-pg`) for the test harness
  rather than requiring `process-compose` to be running.
  Rationale: Tests must be runnable from a fresh checkout under `nix develop` without
  manual setup; `ephemeral-pg` provisions a throwaway Postgres per test run with
  initdb caching.
  Date: 2026-05-26

- Decision: Migrations live as plain SQL files under `shiki-core/sql/migrations/` and are
  applied by `hasql-migration`'s `loadMigrationsFromDirectory`.
  Rationale: Plain SQL is reviewable and editable; `hasql-migration` already tracks
  filename + MD5 checksum so accidental in-place edits to applied migrations fail loudly.
  Date: 2026-05-26

- Decision: Logs are stored on the `runs` row as a single `log_tail` `text` column,
  truncated to the last 64 KiB at write time by the Haskell writer.
  Rationale: From the MasterPlan: keep the v1 schema simple; long-form logs remain in the
  cluster via `kubectl logs` until the Job is GC'd; 64 KiB is a sane default that fits
  Postgres TOAST comfortably and is large enough for typical operational tails.
  Date: 2026-05-26


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

`shiki` is a two-package cabal project (`shiki-core`, `shiki-cli`) targeting GHC 9.12.4
under a Nix flake at `/Users/shinzui/Keikaku/bokuno/shiki/flake.nix`. The flake's dev shell
provides PostgreSQL and `process-compose`. The shell hook configures a per-checkout Postgres
at `$PWD/db`, exposes `PGHOST`, `PGDATABASE=shiki`, and `PG_CONNECTION_STRING` for ad-hoc
manual testing. The `process-compose.yaml` at the repo root starts that Postgres on demand.

This plan does not depend on the existing process-compose setup at runtime; tests provision
their own Postgres via `ephemeral-pg`. The process-compose setup is documented here only for
operators who want to point the CLI at a long-running local database in EP-4.

### Haskell Standards

This plan follows the standards laid down by EP-1 and the MasterPlan's Decision Log:

- GHC 9.12, GHC2024, default-extensions `DeriveAnyClass`, `DuplicateRecordFields`,
  `OverloadedLabels`, `OverloadedStrings`, `MultilineStrings`, `PackageImports`.
- Postpositive `qualified` imports
  (`import Hasql.Session qualified as Session`).
- All modules import `Shiki.Prelude`. That prelude is extended by EP-1 to re-export
  `Generic`, `Text`, `UTCTime`, `MonadIO`, `FromJSON`/`ToJSON`, `Control.Lens`, and the
  generic-lens labels. **EP-1 must be complete before this plan can be implemented**, even
  though the schema design here is independent enough to write down without it.
- Records: no field prefixes, strict `!` fields, `deriving stock (...)` and
  `deriving anyclass (FromJSON, ToJSON)` (or `deriving newtype` for newtype wrappers).
- Lens access (`r ^. #field`) and lens updates (`r & #field .~ v`); avoid record syntax.
- `MultilineStrings` `"""..."""` for SQL literals embedded in Haskell.

### Term Definitions

- **`hasql`** — typed PostgreSQL driver. Programs build `Session.Session` values from
  `Statement` values, then run them against a `Connection`. A `Statement` is the
  combination of a SQL string, a parameter encoder, a row decoder, and a "prepared?" flag.
- **`hasql-pool`** — connection pool. The CLI acquires a `Hasql.Pool.Pool` once at startup
  and runs sessions through `Hasql.Pool.use`.
- **`hasql-migration`** — versioned migration runner; reads SQL files from a directory and
  applies any that have not already been applied, tracked in a `schema_migrations` table.
- **`ephemeral-pg`** — test helper that provisions a temporary PostgreSQL cluster per test
  run (with cached `initdb` for speed) and returns a `hasql` connection string. Lives at
  `/Users/shinzui/Keikaku/bokuno/ephemeral-pg-project/ephemeral-pg`. **Read its `src/`
  before writing the test harness** to confirm the exact module names; the example below
  uses placeholder imports that you must reconcile with reality.
- **Run** — one invocation of `shiki run <service> -- <command...>` against a Kubernetes
  cluster. Each run gets one row in the `runs` table.

### Cross-Plan Contract

From the MasterPlan's Integration Points:

> **`runs` PostgreSQL table** (schema). Defined by EP-2 in `shiki-core/sql/migrations/`.
> Written to by EP-4 (one row per `shiki run` invocation: insert at submit, update on
> completion). Read by EP-5 (`runs list`, `runs show`, `runs logs`). Column names, types,
> and the `run_status` enum are the canonical shared vocabulary; all three plans must
> agree on them.

> **`Shiki.Persistence.Run.RunRecord` / `RunStatus`** (Haskell types, module
> `Shiki.Persistence.Run` in `shiki-core/src/Shiki/Persistence/Run.hs`). Defined by EP-2
> to mirror the `runs` table. Consumed by EP-4 (constructs and updates rows) and EP-5
> (decodes rows into `RunRecord` for display). The hasql `Statement` values exported from
> this module are the shared API.


## Plan of Work

### Milestone 1 — `runs` table SQL migration

Scope: add the migration directory and the initial schema. Add `data-files` /
`extra-source-files` wiring so the SQL is locatable at runtime via `Paths_shiki_core`.

Create `shiki-core/sql/migrations/001-create-runs.sql`:

```sql
CREATE TABLE runs (
  id              uuid PRIMARY KEY,
  service_name    text NOT NULL,
  command         text[] NOT NULL,
  namespace       text NOT NULL,
  job_name        text NOT NULL,
  image           text,
  status          text NOT NULL CHECK (status IN ('pending','running','succeeded','failed')),
  exit_code       integer,
  started_at      timestamptz NOT NULL,
  ended_at        timestamptz,
  duration_ms     bigint,
  log_tail        text,
  service_config  jsonb NOT NULL,
  error           text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX runs_service_started_idx ON runs (service_name, started_at DESC);
CREATE INDEX runs_status_idx          ON runs (status);
```

Edit `shiki-core/shiki-core.cabal`:

- Add a `data-files:` section listing `sql/migrations/*.sql`.
- Add `Paths_shiki_core` to the library's `other-modules:` so the generated module is
  exposed inside the package.
- Add `extra-source-files: sql/migrations/*.sql` so cabal sdist ships them.

Acceptance: `cabal build shiki-core` succeeds; `cabal install --lib --dry-run shiki-core`
reports the SQL files as data files (the dry run merely verifies the wiring).

### Milestone 2 — `RunStatus` and `RunRecord` types with codecs

Scope: introduce the Haskell types that mirror the `runs` row, plus the parameter encoders
and row decoders. No I/O yet.

Add `shiki-core/src/Shiki/Persistence/RunStatus.hs`:

```haskell
module Shiki.Persistence.RunStatus
  ( RunStatus (..)
  , runStatusToText
  , runStatusFromText
  ) where

import Shiki.Prelude

import Data.Text qualified as Text

data RunStatus
  = Pending
  | Running
  | Succeeded
  | Failed
  deriving stock (Generic, Eq, Show, Bounded, Enum)
  deriving anyclass (FromJSON, ToJSON)

runStatusToText :: RunStatus -> Text
runStatusToText = \case
  Pending   -> "pending"
  Running   -> "running"
  Succeeded -> "succeeded"
  Failed    -> "failed"

runStatusFromText :: Text -> Either Text RunStatus
runStatusFromText t = case Text.toLower t of
  "pending"   -> Right Pending
  "running"   -> Right Running
  "succeeded" -> Right Succeeded
  "failed"    -> Right Failed
  other       -> Left ("unknown run status: " <> other)
```

Add `shiki-core/src/Shiki/Persistence/Run.hs`:

```haskell
module Shiki.Persistence.Run
  ( -- * Identifier
    RunId (..)
  , newRunId

    -- * Records
  , RunRecord (..)
  , NewRun (..)
  , RunCompletion (..)

    -- * Statements
  , insertRunStatement
  , markRunRunningStatement
  , completeRunStatement
  , getRunStatement
  , listRecentRunsStatement
  ) where

import Shiki.Prelude

import Shiki.Persistence.RunStatus
  ( RunStatus (Pending), runStatusFromText, runStatusToText
  )

import Data.Aeson qualified as Aeson
import Data.Functor.Contravariant ((>$<))
import Data.UUID (UUID)
import Data.UUID.V4 qualified as UUIDv4
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Statement (Statement (..))

newtype RunId = RunId { unRunId :: UUID }
  deriving stock (Generic, Eq, Ord, Show)
  deriving newtype (FromJSON, ToJSON)

newRunId :: IO RunId
newRunId = RunId <$> UUIDv4.nextRandom

-- | One row of @runs@.
data RunRecord = RunRecord
  { runId         :: !RunId
  , serviceName   :: !Text
  , command       :: ![Text]
  , namespace     :: !Text
  , jobName       :: !Text
  , image         :: !(Maybe Text)
  , status        :: !RunStatus
  , exitCode      :: !(Maybe Int)
  , startedAt     :: !UTCTime
  , endedAt       :: !(Maybe UTCTime)
  , durationMs    :: !(Maybe Int)
  , logTail       :: !(Maybe Text)
  , serviceConfig :: !Aeson.Value
  , errorMessage  :: !(Maybe Text)
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

-- | What the CLI provides when it inserts a new pending run.
data NewRun = NewRun
  { runId         :: !RunId
  , serviceName   :: !Text
  , command       :: ![Text]
  , namespace     :: !Text
  , jobName       :: !Text
  , image         :: !(Maybe Text)
  , startedAt     :: !UTCTime
  , serviceConfig :: !Aeson.Value
  }
  deriving stock (Generic, Eq, Show)

-- | What the CLI provides when a run finishes.
data RunCompletion = RunCompletion
  { runId        :: !RunId
  , status       :: !RunStatus
  , exitCode     :: !(Maybe Int)
  , endedAt      :: !UTCTime
  , durationMs   :: !Int
  , logTail      :: !(Maybe Text)
  , errorMessage :: !(Maybe Text)
  }
  deriving stock (Generic, Eq, Show)

-- ── Statements ─────────────────────────────────────────────────────────────

-- | INSERT a freshly created run in 'Pending' status.
insertRunStatement :: Statement NewRun ()
insertRunStatement = Statement sql encoder Decoders.noResult True
  where
    sql = """
      INSERT INTO runs
        ( id, service_name, command, namespace, job_name
        , image, status, started_at, service_config )
      VALUES
        ( $1, $2, $3, $4, $5, $6, $7, $8, $9 )
      """
    encoder =
         ((\r -> unRunId (r ^. #runId))      >$< uuidParam)
      <> ((^. #serviceName)                  >$< textParam)
      <> ((^. #command)                      >$< textArrayParam)
      <> ((^. #namespace)                    >$< textParam)
      <> ((^. #jobName)                      >$< textParam)
      <> ((^. #image)                        >$< nullableTextParam)
      <> (const Pending                      >$< runStatusParam)
      <> ((^. #startedAt)                    >$< utcTimeParam)
      <> ((^. #serviceConfig)                >$< jsonbParam)

-- | Mark an existing run as 'Running'.
markRunRunningStatement :: Statement RunId ()
markRunRunningStatement = Statement sql encoder Decoders.noResult True
  where
    sql = """
      UPDATE runs
         SET status     = 'running',
             updated_at = now()
       WHERE id = $1
      """
    encoder = unRunId >$< uuidParam

-- | Update an existing row with completion details.
completeRunStatement :: Statement RunCompletion ()
completeRunStatement = Statement sql encoder Decoders.noResult True
  where
    sql = """
      UPDATE runs
         SET status       = $2,
             exit_code    = $3,
             ended_at     = $4,
             duration_ms  = $5,
             log_tail     = $6,
             error        = $7,
             updated_at   = now()
       WHERE id = $1
      """
    encoder =
         ((\r -> unRunId (r ^. #runId)) >$< uuidParam)
      <> ((^. #status)                  >$< runStatusParam)
      <> ((^. #exitCode)                >$< nullableInt4Param)
      <> ((^. #endedAt)                 >$< utcTimeParam)
      <> ((^. #durationMs)              >$< int8Param)
      <> ((^. #logTail)                 >$< nullableTextParam)
      <> ((^. #errorMessage)            >$< nullableTextParam)

-- | Look up a single run by id.
getRunStatement :: Statement RunId (Maybe RunRecord)
getRunStatement = Statement sql encoder decoder True
  where
    sql = """
      SELECT id, service_name, command, namespace, job_name,
             image, status, exit_code, started_at, ended_at,
             duration_ms, log_tail, service_config, error
        FROM runs
       WHERE id = $1
      """
    encoder = unRunId >$< uuidParam
    decoder = Decoders.rowMaybe runRecordRow

-- | List the most recent N runs, newest first.
listRecentRunsStatement :: Statement Int [RunRecord]
listRecentRunsStatement = Statement sql encoder decoder True
  where
    sql = """
      SELECT id, service_name, command, namespace, job_name,
             image, status, exit_code, started_at, ended_at,
             duration_ms, log_tail, service_config, error
        FROM runs
    ORDER BY started_at DESC
       LIMIT $1
      """
    encoder = fromIntegral >$< int8Param
    decoder = Decoders.rowList runRecordRow

-- ── Internal parameter / row helpers ───────────────────────────────────────

uuidParam :: Encoders.Params UUID
uuidParam = Encoders.param (Encoders.nonNullable Encoders.uuid)

textParam :: Encoders.Params Text
textParam = Encoders.param (Encoders.nonNullable Encoders.text)

nullableTextParam :: Encoders.Params (Maybe Text)
nullableTextParam = Encoders.param (Encoders.nullable Encoders.text)

utcTimeParam :: Encoders.Params UTCTime
utcTimeParam = Encoders.param (Encoders.nonNullable Encoders.timestamptz)

nullableInt4Param :: Encoders.Params (Maybe Int)
nullableInt4Param =
  Encoders.param (Encoders.nullable (fromIntegral >$< Encoders.int4))

int8Param :: Encoders.Params Int
int8Param =
  Encoders.param (Encoders.nonNullable (fromIntegral >$< Encoders.int8))

textArrayParam :: Encoders.Params [Text]
textArrayParam =
  Encoders.param $
    Encoders.nonNullable $
      Encoders.array $
        Encoders.dimension foldl' $
          Encoders.element (Encoders.nonNullable Encoders.text)

runStatusParam :: Encoders.Params RunStatus
runStatusParam =
  Encoders.param
    (Encoders.nonNullable (runStatusToText >$< Encoders.text))

jsonbParam :: Encoders.Params Aeson.Value
jsonbParam = Encoders.param (Encoders.nonNullable Encoders.jsonb)

runRecordRow :: Decoders.Row RunRecord
runRecordRow =
  RunRecord
    <$> (RunId <$> Decoders.column (Decoders.nonNullable Decoders.uuid))
    <*> Decoders.column (Decoders.nonNullable Decoders.text)
    <*> Decoders.column (Decoders.nonNullable textArrayDecoder)
    <*> Decoders.column (Decoders.nonNullable Decoders.text)
    <*> Decoders.column (Decoders.nonNullable Decoders.text)
    <*> Decoders.column (Decoders.nullable    Decoders.text)
    <*> Decoders.column (Decoders.nonNullable runStatusDecoder)
    <*> (fmap fromIntegral
           <$> Decoders.column (Decoders.nullable Decoders.int4))
    <*> Decoders.column (Decoders.nonNullable Decoders.timestamptz)
    <*> Decoders.column (Decoders.nullable    Decoders.timestamptz)
    <*> (fmap fromIntegral
           <$> Decoders.column (Decoders.nullable Decoders.int8))
    <*> Decoders.column (Decoders.nullable    Decoders.text)
    <*> Decoders.column (Decoders.nonNullable Decoders.jsonb)
    <*> Decoders.column (Decoders.nullable    Decoders.text)

textArrayDecoder :: Decoders.Value [Text]
textArrayDecoder =
  Decoders.array $
    Decoders.dimension replicateM $
      Decoders.element (Decoders.nonNullable Decoders.text)

runStatusDecoder :: Decoders.Value RunStatus
runStatusDecoder =
  Decoders.enum (either (const Nothing) Just . runStatusFromText)
```

Edit `shiki-core/shiki-core.cabal`:

- Add `Shiki.Persistence.RunStatus` and `Shiki.Persistence.Run` to `exposed-modules`.
- Add to `build-depends`:
  - `hasql ^>= 1.10`
  - `hasql-pool ^>= 1.3`
  - `hasql-transaction ^>= 1.2`
  - `uuid ^>= 1.3`
  - `contravariant ^>= 1.5`
  - `bytestring`

Acceptance: `cabal build shiki-core` succeeds; `cabal repl shiki-core` and
`:t insertRunStatement` shows `Statement NewRun ()`.

### Milestone 3 — Connection pool and migration runner

Scope: thin wrappers around `Hasql.Pool` and `Hasql.Migration` that EP-4 and the test
suite can call.

Add `shiki-core/src/Shiki/Persistence/Connection.hs`:

```haskell
module Shiki.Persistence.Connection
  ( ConnectionString (..)
  , acquirePool
  , releasePool
  ) where

import Shiki.Prelude

import Data.ByteString (ByteString)
import Data.Text.Encoding qualified as TE
import Data.Time.Clock (NominalDiffTime)
import Hasql.Pool qualified as Pool
import Hasql.Pool.Config qualified as PoolConfig

newtype ConnectionString = ConnectionString { unConnectionString :: Text }
  deriving stock (Generic, Eq, Show)
  deriving newtype (FromJSON, ToJSON)

-- | Acquire a 5-connection pool with a 10-second acquisition timeout and
-- 1-hour idle / max lifetimes. Suitable for a short-lived CLI.
acquirePool :: ConnectionString -> IO Pool.Pool
acquirePool (ConnectionString cs) =
  Pool.acquire $
    PoolConfig.settings
      [ PoolConfig.size 5
      , PoolConfig.acquisitionTimeout (10  :: NominalDiffTime)
      , PoolConfig.idlenessTimeout    (3600 :: NominalDiffTime)
      , PoolConfig.agingTimeout       (3600 :: NominalDiffTime)
      , PoolConfig.staticConnectionSettings (toBytes cs)
      ]
  where
    toBytes :: Text -> ByteString
    toBytes = TE.encodeUtf8

releasePool :: Pool.Pool -> IO ()
releasePool = Pool.release
```

Add `shiki-core/src/Shiki/Persistence/Migration.hs`:

```haskell
module Shiki.Persistence.Migration
  ( runMigrations
  , migrationsDirectory
  ) where

import Shiki.Prelude

import Hasql.Migration qualified as Migration
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Transaction qualified as Transaction
import Hasql.Transaction.Sessions
  ( IsolationLevel (Serializable), Mode (Write), transaction
  )
import Paths_shiki_core qualified as Paths

-- | Location of the SQL migrations shipped with the @shiki-core@ package.
migrationsDirectory :: IO FilePath
migrationsDirectory = Paths.getDataFileName "sql/migrations"

-- | Apply all unapplied migrations. Throws if a script's checksum does not
-- match what was recorded previously.
runMigrations :: Pool.Pool -> IO ()
runMigrations pool = do
  dir <- migrationsDirectory
  scripts <- Migration.loadMigrationsFromDirectory dir
  result <-
    Pool.use
      pool
      (migrationSession (Migration.MigrationInitialization : scripts))
  case result of
    Left poolErr ->
      error ("shiki: migration pool error: " <> show poolErr)
    Right Nothing -> pure ()
    Right (Just merr) ->
      error ("shiki: migration failed: " <> show merr)

migrationSession
  :: [Migration.MigrationCommand]
  -> Session.Session (Maybe Migration.MigrationError)
migrationSession scripts =
  transaction Serializable Write (runFirstError scripts)
  where
    runFirstError [] = pure Nothing
    runFirstError (c : cs) = Transaction.runMigration c >>= \case
      Just err -> pure (Just err)
      Nothing  -> runFirstError cs
```

Edit `shiki-core/shiki-core.cabal`:

- Add `Shiki.Persistence.Connection`, `Shiki.Persistence.Migration` to `exposed-modules`.
- Add `hasql-migration ^>= 0.4` to `build-depends`. Pin via the user's local checkout if
  not on Hackage:

  ```text
  source-repository-package
    type: git
    location: https://github.com/shinzui/hasql-migration
    tag: <commit sha>
  ```

  Add this block to `cabal.project` if needed. Verify with `cabal build shiki-core` under
  `nix develop`.

Acceptance: `cabal build shiki-core` succeeds.

### Milestone 4 — Tasty test against an ephemeral Postgres

Scope: add a test that proves the full round-trip works end-to-end on a real Postgres.

Add `shiki-core/test/Shiki/Persistence/RunSpec.hs` (the `ephemeral-pg` imports below are
placeholders — read
`/Users/shinzui/Keikaku/bokuno/ephemeral-pg-project/ephemeral-pg/src` and replace them
with the actual module names exported by that library):

```haskell
module Shiki.Persistence.RunSpec (tests) where

import Shiki.Prelude

import Shiki.Persistence.Connection
  ( ConnectionString (..), acquirePool, releasePool
  )
import Shiki.Persistence.Migration (runMigrations)
import Shiki.Persistence.Run
  ( NewRun (..), RunCompletion (..)
  , completeRunStatement, getRunStatement
  , insertRunStatement, listRecentRunsStatement
  , markRunRunningStatement, newRunId
  )
import Shiki.Persistence.RunStatus (RunStatus (Failed, Succeeded))

import Control.Exception (bracket)
import Data.Aeson qualified as Aeson
import Data.Time.Clock (getCurrentTime)
import EphemeralPg qualified as Pg   -- ← verify actual module name
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (Statement)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase)

tests :: TestTree
tests = testGroup "Shiki.Persistence.Run"
  [ testCase "insert / mark running / complete / list" $
      withTempPg $ \pool -> do
        runMigrations pool
        now <- getCurrentTime
        rid <- newRunId

        useStmt pool insertRunStatement NewRun
          { runId         = rid
          , serviceName   = "mls-service-v2"
          , command       = ["subscription", "process"]
          , namespace     = "prod"
          , jobName       = "mls-service-v2-oneoff-20260526-123000-1234"
          , image         = Just "gcr.io/example/mls-service-v2:abc123"
          , startedAt     = now
          , serviceConfig = Aeson.object [("name", Aeson.String "mls-service-v2")]
          }
        useStmt pool markRunRunningStatement rid
        useStmt pool completeRunStatement RunCompletion
          { runId        = rid
          , status       = Succeeded
          , exitCode     = Just 0
          , endedAt      = now
          , durationMs   = 12345
          , logTail      = Just "everything is fine\n"
          , errorMessage = Nothing
          }

        mRow <- useStmtRead pool getRunStatement rid
        case mRow of
          Nothing -> fail "expected row"
          Just r  -> do
            assertEqual "status"   Succeeded (r ^. #status)
            assertEqual "exitCode" (Just 0)  (r ^. #exitCode)

        recent <- useStmtRead pool listRecentRunsStatement (10 :: Int)
        assertBool "one row recent" (length recent == 1)
  , testCase "Failed status round-trips" $
      withTempPg $ \pool -> do
        runMigrations pool
        now <- getCurrentTime
        rid <- newRunId
        useStmt pool insertRunStatement NewRun
          { runId = rid, serviceName = "x", command = ["y"]
          , namespace = "z", jobName = "j"
          , image = Nothing, startedAt = now
          , serviceConfig = Aeson.object []
          }
        useStmt pool completeRunStatement RunCompletion
          { runId = rid, status = Failed, exitCode = Just 137
          , endedAt = now, durationMs = 0
          , logTail = Nothing, errorMessage = Just "OOMKilled"
          }
        Just r <- useStmtRead pool getRunStatement rid
        assertEqual "status" Failed (r ^. #status)
        assertEqual "error"  (Just "OOMKilled") (r ^. #errorMessage)
  ]

withTempPg :: (Pool.Pool -> IO ()) -> IO ()
withTempPg action =
  Pg.withCleanDatabase $ \connString ->
    bracket (acquirePool (ConnectionString connString)) releasePool action

useStmt :: Pool.Pool -> Statement a () -> a -> IO ()
useStmt pool stmt input =
  Pool.use pool (Session.statement input stmt) >>= either (fail . show) pure

useStmtRead :: Pool.Pool -> Statement a b -> a -> IO b
useStmtRead pool stmt input =
  Pool.use pool (Session.statement input stmt) >>= either (fail . show) pure
```

Edit `shiki-core/shiki-core.cabal`:

- Extend the `test-suite shiki-core-test` stanza:

  ```cabal
    other-modules:
      Shiki.Service.ConfigSpec
      Shiki.Persistence.RunSpec
    build-depends:
      ...,
      ephemeral-pg ^>=0.1,
      hasql,
      hasql-pool,
      time,
      aeson,
  ```

  Add `source-repository-package` blocks to `cabal.project` for `shinzui/ephemeral-pg` and
  `shinzui/hasql-migration` if they are not on Hackage.

Acceptance: `cabal test shiki-core` runs the new spec and passes.


## Concrete Steps

All commands assume the working directory is `/Users/shinzui/Keikaku/bokuno/shiki` and the
dev shell is active.

After Milestone 1:

```bash
cabal build shiki-core
```

Expected (last line):

```text
Linking ...
```

After Milestones 2-3:

```bash
cabal build shiki-core
cabal repl shiki-core
-- in REPL:
:t insertRunStatement
:t runMigrations
```

Expected:

```text
insertRunStatement :: Hasql.Statement.Statement NewRun ()
runMigrations :: Hasql.Pool.Pool -> IO ()
```

After Milestone 4:

```bash
cabal test shiki-core
```

Expected (truncated):

```text
shiki-core
  Shiki.Service.Config
    loadServiceConfig parses mls-service-v2.dhall: OK
    first init container is cloud-sql-proxy:      OK
  Shiki.Persistence.Run
    insert / mark running / complete / list:      OK (1.34s)
    Failed status round-trips:                    OK (0.42s)

All 4 tests passed (1.76s)
```


## Validation and Acceptance

After all four milestones:

1. `cabal build all` succeeds.
2. `cabal test shiki-core` includes the two new persistence assertions and they pass.
3. Manual check: enter `nix develop`, run `process-compose up &`, then in another shell

   ```bash
   psql "$PG_CONNECTION_STRING" -c "\\d runs"
   ```

   shows the `runs` table with all columns from milestone 1 — after invoking
   `cabal repl shiki-core` and calling `runMigrations` against a pool built from
   `$PG_CONNECTION_STRING`. (Optional but reassuring.)
4. The cabal package's `data-files` mechanism finds the SQL at runtime: in
   `cabal repl shiki-core`, calling `Shiki.Persistence.Migration.migrationsDirectory`
   returns an absolute path ending in `sql/migrations`.


## Idempotence and Recovery

`hasql-migration` records executed scripts by filename + MD5, so re-running
`runMigrations` against a database that has already been migrated is a no-op. The migration
filenames are immutable once committed: if a schema change is needed, add a new file
(`002-*.sql`); do not edit `001-create-runs.sql` — the checksum mismatch is intentional and
will cause `runMigrations` to error.

The tests are self-contained: each `withTempPg` call allocates a fresh database. There is
no shared mutable state across test cases.

If a test fails with a connection error, verify that the dev shell is active
(`echo $PGHOST` should print `$PWD/db`) and that `nix develop` placed `pg_ctl` and
`initdb` on the PATH.


## Interfaces and Dependencies

Libraries:

- `hasql ^>= 1.10` — typed PostgreSQL driver.
- `hasql-pool ^>= 1.3` — connection pool.
- `hasql-transaction ^>= 1.2` — transactional sessions, required by `hasql-migration`.
- `hasql-migration ^>= 0.4` (mori name `shinzui/hasql-migration`) — file-based migrations.
- `ephemeral-pg ^>= 0.1` (mori name `shinzui/ephemeral-pg`) — throwaway Postgres for tests.
- `uuid ^>= 1.3`, `contravariant ^>= 1.5`, `aeson ^>= 2.2`, `time ^>= 1.12`,
  `bytestring`, `text ^>= 2.1` — supporting.

Module surface at end of plan:

- `Shiki.Persistence.RunStatus`

  ```haskell
  data RunStatus = Pending | Running | Succeeded | Failed
  runStatusToText   :: RunStatus -> Text
  runStatusFromText :: Text -> Either Text RunStatus
  ```

- `Shiki.Persistence.Run`

  ```haskell
  newtype RunId = RunId { unRunId :: UUID }
  newRunId :: IO RunId

  data RunRecord     = RunRecord     { ... }
  data NewRun        = NewRun        { ... }
  data RunCompletion = RunCompletion { ... }

  insertRunStatement      :: Statement NewRun ()
  markRunRunningStatement :: Statement RunId ()
  completeRunStatement    :: Statement RunCompletion ()
  getRunStatement         :: Statement RunId (Maybe RunRecord)
  listRecentRunsStatement :: Statement Int [RunRecord]
  ```

- `Shiki.Persistence.Connection`

  ```haskell
  newtype ConnectionString = ConnectionString { unConnectionString :: Text }
  acquirePool :: ConnectionString -> IO Pool.Pool
  releasePool :: Pool.Pool -> IO ()
  ```

- `Shiki.Persistence.Migration`

  ```haskell
  runMigrations       :: Pool.Pool -> IO ()
  migrationsDirectory :: IO FilePath
  ```

Downstream consumers:

- `docs/plans/4-run-cli-command-end-to-end.md` — uses `acquirePool`, `runMigrations`,
  `insertRunStatement`, `markRunRunningStatement`, `completeRunStatement`.
- `docs/plans/5-runs-query-cli-commands.md` — uses `acquirePool`, `getRunStatement`,
  `listRecentRunsStatement`.
