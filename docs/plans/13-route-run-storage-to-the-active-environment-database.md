---
id: 13
slug: route-run-storage-to-the-active-environment-database
title: "Route run storage to the active environment database"
kind: exec-plan
created_at: 2026-06-11T18:40:28Z
intention: "intention_01ktvznw1xewqamnvyfhsbb4w2"
master_plan: "docs/masterplans/2-project-local-configuration-with-per-environment-databases.md"
---

# Route run storage to the active environment database

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This plan is the second of two under the MasterPlan
`docs/masterplans/2-project-local-configuration-with-per-environment-databases.md`. It is
the **consumer**: it relies on the configuration foundation built by
`docs/plans/12-project-local-shiki-dhall-configuration-foundation.md`.

**Hard dependency.** Do not start this plan until EP-12 is complete and merged. EP-12
introduces the Haskell types and functions this plan calls; without them this plan's code
will not compile. Before beginning, verify the following exist (build `shiki-cli` and grep):

- `shiki-cli/src/Shiki/Cli/Project.hs` exporting `discoverProjectConfigPath`,
  `loadProjectConfig`, `resolveActiveEnvironmentName`, `resolveActiveEnvironment`,
  `ProjectConfig (..)`, `Environment (..)`.
- `shiki-cli/src/Shiki/Cli.hs` whose `Options` record has an `envName :: !(Maybe Text)`
  field populated from a global `--env` flag.

If those are absent, stop and implement EP-12 first.


## Purpose / Big Picture

`shiki` is a command-line tool that runs one-off Kubernetes Jobs against microservices and
records each run in a PostgreSQL database. Today the database it connects to is resolved
**globally**, the same for every project and every environment, by this function in
`shiki-cli/src/Shiki/Cli/Config.hs`:

```haskell
resolveConnectionString :: Maybe Text -> IO ConnectionString
resolveConnectionString = \case
  Just t  -> pure (ConnectionString t)                       -- the --db flag
  Nothing -> do
    fromEnv <- firstEnv ["SHIKI_DATABASE_URL", "PG_CONNECTION_STRING"]
    case fromEnv of
      Just s  -> pure (ConnectionString s)
      Nothing -> error "shiki: no Postgres connection string. ..."
```

EP-12 added a project-local `shiki.dhall` file that declares named **environments** (e.g.
`staging`, `prod`), each with its own connection string, and a way to choose the active one
via `--env` / `SHIKI_ENV` / `defaultEnvironment`. But EP-12 deliberately left the live
connection path untouched: `shiki run`, `shiki runs`, and `shiki agent` still connect to the
single global database.

After **this** plan, those database-touching subcommands connect to the **active
environment's** database from `shiki.dhall`. Concretely, with a `shiki.dhall` that declares
a `staging` and a `prod` environment:

```text
$ shiki run mls-service-v2 --env staging -- some-command
run <id> SUCCEEDED job=mls-service-v2-...        # recorded in the STAGING database

$ shiki runs list --env staging                  # reads the STAGING database
$ shiki runs list --env prod                     # reads the PROD database (different rows)
```

The operator no longer hand-juggles `SHIKI_DATABASE_URL` to switch databases; they pick an
environment by name and shiki routes the run history to the matching database. When no
`shiki.dhall` is present (or it declares no URL for the active environment), behavior is
exactly as before — this change is backward compatible.

This realizes the user's goal of storing runs **per environment, not globally**. (Per the
MasterPlan, runs continue to be distinguished within a database by the existing
`service_name` column; this plan does not add per-service database or schema isolation.)


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here.

- [x] M1: Environment-aware connection resolution and threading (see Milestone 1). Completed 2026-06-11.
  - [x] Extend `resolveConnectionString` to consult the active environment URL.
  - [x] Thread `--env` (`opts ^. #envName`) through `withDbEnv` for `run`/`runs`/`agent`.
- [x] M2: End-to-end + fall-through tests (see Milestone 2). Completed 2026-06-11.
  - [x] Test: a run recorded under `--env staging` lands in the staging database and is
    readable back; a `prod` run is isolated from it.
  - [x] Test: with no `shiki.dhall`, resolution falls back to `SHIKI_DATABASE_URL`.
- [x] M3: Documentation of the new connection precedence (see Milestone 3). Completed 2026-06-11.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Discovery: The environment-routing test uses two real `ephemeral-pg` instances, one for
  `staging` and one for `prod`, instead of creating two databases inside one server.
  Evidence: `Shiki.Cli.EnvRouting` resolves two distinct libpq connection strings from a
  temporary `shiki.dhall`, inserts a run through the staging pool, then observes one row in
  staging and zero rows in prod.

- Discovery: In this workspace, `cabal test all` also runs local dependency test suites
  such as `crypton`, so the output is large. It completed successfully after the shiki
  routing suite passed.
  Evidence: `cabal test all` exited 0 on 2026-06-11.


## Decision Log

- Decision: Connection precedence is `--db` flag → active environment URL from `shiki.dhall`
  → `SHIKI_DATABASE_URL` → `PG_CONNECTION_STRING`.
  Rationale: Inherited from the MasterPlan. Keeps `--db` as an explicit one-off override;
  makes the project config the normal source of truth; preserves legacy behavior when no
  config is present.
  Date: 2026-06-11

- Decision: The active-environment lookup is performed inside (or just before)
  `resolveConnectionString`, which is given the `--env` flag value; an explicit `--db` flag
  short-circuits before any `shiki.dhall` discovery.
  Rationale: Single, well-defined resolution site; avoids discovering/parsing `shiki.dhall`
  when the operator already specified `--db`.
  Date: 2026-06-11

- Decision: Use two `ephemeral-pg` instances in `Shiki.Cli.EnvRoutingSpec` as the staging
  and prod stores.
  Rationale: This proves database-level separation without introducing ad hoc database
  creation SQL into the test. Each temporary server exposes a normal libpq connection
  string, matching the production shape consumed by `resolveConnectionString`.
  Date: 2026-06-11


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.

Completed EP-13 on 2026-06-11. The live connection resolver now uses precedence
`--db` flag → active environment `databaseUrl` from `shiki.dhall` →
`SHIKI_DATABASE_URL` → `PG_CONNECTION_STRING`, and `run`, `runs`, and `agent` thread the
global `--env` selector into that resolver. The change preserves the explicit `--db`
override and legacy env-var fallback. Documentation now describes the new precedence and
clarifies that schema selection remains orthogonal to database selection.

Validation passed with `cabal build all`, `cabal test shiki-cli`, and `cabal test all`.
The new `Shiki.Cli.EnvRouting` suite proves staging/prod database separation, legacy
fallback, missing-source failure, and `--db` override behavior.


## Context and Orientation

`shiki` is built with **Cabal** across two packages: `shiki-core` (library,
`shiki-core/shiki-core.cabal`) and `shiki-cli` (library + `shiki` executable,
`shiki-cli/shiki-cli.cabal`). Both use GHC2024 with project-wide default extensions
including `PackageImports` (imports look like `import "text" Data.Text qualified as Text`)
and `OverloadedLabels` (records accessed via `value ^. #field`). There is a custom prelude
`Shiki.Prelude` re-exporting common names; import it first in new code.

This plan touches exactly three areas of the CLI; read each before editing.

**1. The connection-string resolver — `shiki-cli/src/Shiki/Cli/Config.hs`.** This is the
file you change most. Its current full contents:

```haskell
-- | Resolve the Postgres connection string for @shiki@ subcommands.
--   Precedence: @--db@ flag, then @SHIKI_DATABASE_URL@, then
--   @PG_CONNECTION_STRING@ (the variable the project's @nix develop@
--   shellHook exports).
module Shiki.Cli.Config
  ( resolveConnectionString
  ) where

import Shiki.Prelude

import Shiki.Persistence.Connection (ConnectionString (..))

import "text" Data.Text qualified as Text
import "base" System.Environment (lookupEnv)

resolveConnectionString :: Maybe Text -> IO ConnectionString
resolveConnectionString = \case
  Just t  -> pure (ConnectionString t)
  Nothing -> do
    fromEnv <- firstEnv ["SHIKI_DATABASE_URL", "PG_CONNECTION_STRING"]
    case fromEnv of
      Just s  -> pure (ConnectionString s)
      Nothing ->
        error
          "shiki: no Postgres connection string. \
          \Pass --db or set SHIKI_DATABASE_URL / PG_CONNECTION_STRING."

firstEnv :: [String] -> IO (Maybe Text)
firstEnv [] = pure Nothing
firstEnv (n : rest) =
  lookupEnv n >>= \case
    Just v  -> pure (Just (Text.pack v))
    Nothing -> firstEnv rest
```

The single argument is the `--db` flag value. This plan adds a second argument: the `--env`
flag value, used to consult `shiki.dhall`.

**2. The environment bundler — `shiki-cli/src/Shiki/Cli.hs`.** This module
(`module Shiki.Cli`) parses `Options` and dispatches. After EP-12, `Options` looks like:

```haskell
data Options = Options
  { dbConnStr :: !(Maybe Text)
  , dbSchema  :: !(Maybe Text)
  , envName   :: !(Maybe Text)     -- the --env flag, added by EP-12
  , command   :: !Command
  }
```

and `runCli` dispatches like this (the `Config` branch was added by EP-12):

```haskell
runCli :: IO ()
runCli = do
  opts <- Opt.execParser parserInfo
  case opts ^. #command of
    ServiceShow nm -> serviceShowHandler nm
    Help helpOpts  -> runHelp helpOpts
    Config cfgCmd  -> ...                              -- EP-12, no DB
    Run runOpts    ->
      withDbEnv (opts ^. #dbConnStr) (opts ^. #dbSchema) $ \_ env ->
        runRun env runOpts
    Runs runsOpts  ->
      withDbEnv (opts ^. #dbConnStr) (opts ^. #dbSchema) $ \_ env ->
        runRuns env runsOpts
    Agent agentOpts ->
      withDbEnv (opts ^. #dbConnStr) (opts ^. #dbSchema) $ \schema env ->
        runAgent env schema agentOpts

withDbEnv
  :: Maybe Text
  -> Maybe Text
  -> (Shiki.Persistence.Schema.Schema -> CliEnv -> IO a)
  -> IO a
withDbEnv mConn mSchema k = do
  cs     <- resolveConnectionString mConn
  schema <- resolveSchema mSchema
  withCliEnv cs schema (k schema)
```

`withDbEnv` is the one place all three database subcommands funnel through to build their
connection. This plan adds the `--env` value to `withDbEnv` and forwards it to
`resolveConnectionString`.

**3. The pool/env bundle — `shiki-cli/src/Shiki/Cli/Env.hs`.** `withCliEnv :: ConnectionString
-> Schema -> (CliEnv -> IO a) -> IO a` acquires the `hasql` pool from the `ConnectionString`,
runs migrations, loads the Kubernetes client, and hands a `CliEnv` to the continuation. You
do **not** need to modify this file: it already takes a `ConnectionString`, and this plan
only changes which `ConnectionString` is computed. It is described here so you understand
that once `resolveConnectionString` returns the environment's URL, everything downstream
(pool, migrations against `--db-schema`, run recording) already works unchanged.

**What EP-12 gives you (the integration surface).** From
`shiki-cli/src/Shiki/Cli/Project.hs` (built and merged by EP-12):

```haskell
discoverProjectConfigPath     :: IO (Maybe FilePath)
loadProjectConfig             :: FilePath -> IO ProjectConfig
resolveActiveEnvironmentName  :: ProjectConfig -> Maybe Text -> IO (Text, EnvSelectionSource)
resolveActiveEnvironment      :: Maybe Text -> IO (Maybe (Text, Environment))
-- ProjectConfig { environments :: Map Text Environment, defaultEnvironment :: Text }
-- Environment   { databaseUrl  :: Text }
```

`resolveActiveEnvironment mEnvFlag` is the convenience you want: it discovers `shiki.dhall`,
loads it, resolves the active environment from `mEnvFlag`/`SHIKI_ENV`/`defaultEnvironment`,
and returns `Just (name, Environment)` if a config exists and names that environment, or
`Nothing` if no `shiki.dhall` was found. It calls `error` (failing loudly) if a config
exists but the requested environment is not declared — which is the desired behavior for a
typo'd `--env`.

**Term definitions.**

- *Active environment*: the shiki environment selected for this invocation (from `--env` /
  `SHIKI_ENV` / `defaultEnvironment`). Defined and resolved by EP-12.
- *Connection string* (`ConnectionString`, a newtype in
  `shiki-core/src/Shiki/Persistence/Connection.hs`): an opaque libpq-style PostgreSQL
  connection string handed to `hasql`. shiki never parses it.
- *Schema*: an unrelated, orthogonal concern (`--db-schema`/`SHIKI_DB_SCHEMA`) that selects
  a PostgreSQL schema/namespace within whichever database is chosen. This plan does not
  touch schema resolution; the two compose (environment picks the database, schema picks the
  namespace within it).


## Plan of Work

Three milestones. M1 is the behavioral change; M2 proves it with tests; M3 documents it.

### Milestone 1 — Environment-aware connection resolution and threading

Scope: make `resolveConnectionString` consult the active environment's database URL, and
thread the `--env` flag value to it through `withDbEnv` for the `run`, `runs`, and `agent`
subcommands. At the end, `shiki run --env staging ...` connects to the staging database.

Edit `shiki-cli/src/Shiki/Cli/Config.hs`. Change `resolveConnectionString` to take the
`--env` flag value as a second argument and to insert the `shiki.dhall` lookup between the
`--db` flag and the environment variables. The new precedence is: `--db` → active
environment URL from `shiki.dhall` → `SHIKI_DATABASE_URL` → `PG_CONNECTION_STRING`.

```haskell
-- | Resolve the Postgres connection string for @shiki@ subcommands.
--   Precedence: @--db@ flag, then the active environment's @databaseUrl@
--   from a project-local @shiki.dhall@ (see "Shiki.Cli.Project"), then
--   @SHIKI_DATABASE_URL@, then @PG_CONNECTION_STRING@ (the variable the
--   project's @nix develop@ shellHook exports).
--
--   The first argument is the @--db@ flag value; the second is the @--env@
--   flag value (used only to choose the active environment when @--db@ is
--   absent and a @shiki.dhall@ exists).
module Shiki.Cli.Config
  ( resolveConnectionString
  ) where

import Shiki.Prelude

import Shiki.Cli.Project (Environment (..), resolveActiveEnvironment)
import Shiki.Persistence.Connection (ConnectionString (..))

import "text" Data.Text qualified as Text
import "base" System.Environment (lookupEnv)

resolveConnectionString :: Maybe Text -> Maybe Text -> IO ConnectionString
resolveConnectionString mDb mEnv = case mDb of
  Just t  -> pure (ConnectionString t)
  Nothing -> do
    mActive <- resolveActiveEnvironment mEnv
    case mActive of
      Just (_name, e)
        | not (Text.null (e ^. #databaseUrl)) ->
            pure (ConnectionString (e ^. #databaseUrl))
      _ -> do
        fromEnv <- firstEnv ["SHIKI_DATABASE_URL", "PG_CONNECTION_STRING"]
        case fromEnv of
          Just s  -> pure (ConnectionString s)
          Nothing ->
            error
              "shiki: no Postgres connection string. \
              \Pass --db, add a shiki.dhall, or set \
              \SHIKI_DATABASE_URL / PG_CONNECTION_STRING."

firstEnv :: [String] -> IO (Maybe Text)
firstEnv [] = pure Nothing
firstEnv (n : rest) =
  lookupEnv n >>= \case
    Just v  -> pure (Just (Text.pack v))
    Nothing -> firstEnv rest
```

Note the guard `not (Text.null (e ^. #databaseUrl))`: if a `shiki.dhall` exists but the
active environment's `databaseUrl` is empty, treat it as "not configured" and fall through
to the environment variables rather than handing an empty connection string to `hasql`.

Now thread the `--env` value through `withDbEnv` in `shiki-cli/src/Shiki/Cli.hs`. Change
`withDbEnv`'s signature to accept the `--env` value and pass it on:

```haskell
withDbEnv
  :: Maybe Text                       -- --db
  -> Maybe Text                       -- --db-schema
  -> Maybe Text                       -- --env
  -> (Shiki.Persistence.Schema.Schema -> CliEnv -> IO a)
  -> IO a
withDbEnv mConn mSchema mEnv k = do
  cs     <- resolveConnectionString mConn mEnv
  schema <- resolveSchema mSchema
  withCliEnv cs schema (k schema)
```

and update the three call sites in `runCli` to pass `opts ^. #envName`:

```haskell
    Run runOpts    ->
      withDbEnv (opts ^. #dbConnStr) (opts ^. #dbSchema) (opts ^. #envName) $ \_ env ->
        runRun env runOpts
    Runs runsOpts  ->
      withDbEnv (opts ^. #dbConnStr) (opts ^. #dbSchema) (opts ^. #envName) $ \_ env ->
        runRuns env runsOpts
    Agent agentOpts ->
      withDbEnv (opts ^. #dbConnStr) (opts ^. #dbSchema) (opts ^. #envName) $ \schema env ->
        runAgent env schema agentOpts
```

Leave the `Config`, `ServiceShow`, and `Help` branches unchanged (they do not open the
database).

Because `resolveConnectionString` now imports `Shiki.Cli.Project`, confirm there is no
import cycle: `Shiki.Cli.Config` → `Shiki.Cli.Project` → `Shiki.Project.Config*` (in
`shiki-core`). `Shiki.Cli.Project` must not import `Shiki.Cli.Config`. EP-12 created
`Shiki.Cli.Project` with no such import, so this is acyclic; verify after editing.

Acceptance for M1: `cabal build all` succeeds. Manual check (needs a reachable Postgres, or
defer to M2's automated test): with a `shiki.dhall` whose `staging` URL points at one
database and `prod` at another, `shiki runs list --env staging` and `shiki runs list --env
prod` read from the respective databases (initially both empty → both print the empty-table
output, but `shiki config show --env <name>` from EP-12 confirms the URL each resolves to).

### Milestone 2 — End-to-end and fall-through tests

Scope: prove behavior with automated tests. At the end there is a test that records a run
into a `--env staging` database and reads it back, demonstrating environment routing, plus a
test that confirms the legacy fall-through when no `shiki.dhall` exists.

This project already tests against a real PostgreSQL using the `ephemeral-pg` library (see
`shiki-core/test/Shiki/Persistence/TestPg.hs` and specs like
`shiki-core/test/Shiki/Persistence/RunSpec.hs` and
`shiki-core/test/Shiki/Persistence/SchemaIsolationSpec.hs`). The `shiki-cli` test suite also
depends on `ephemeral-pg`, `temporary`, `hasql`, and `hasql-pool` (see
`shiki-cli/shiki-cli.cabal`). Read `TestPg.hs` to learn how a throwaway Postgres is started
and how a `ConnectionString`/pool is obtained, and mirror it.

Add `shiki-cli/test/Shiki/Cli/EnvRoutingSpec.hs` with two test cases.

Test A — environment routing. Start an ephemeral Postgres. Create two logical databases (or,
if creating databases is awkward with the harness, two distinct **schemas** used as proxies
for "two environments" — but prefer two real databases/connection strings so the test
mirrors production semantics; `ephemeral-pg` exposes a base connection string you can use to
`CREATE DATABASE staging_db` / `CREATE DATABASE prod_db` via a one-off `hasql` session, then
build per-database connection strings). Write a temporary `shiki.dhall` (in a temp dir you
`setCurrentDirectory` into, saving/restoring the cwd) whose `staging` and `prod`
environments point at those two connection strings. Then:

1. Call the real resolution path used by the CLI:
   `resolveConnectionString Nothing (Just "staging")` and assert it returns the staging
   connection string; likewise for `"prod"`.
2. Acquire a pool for the staging connection string (reuse `acquirePool` from
   `Shiki.Persistence.Connection` and `runMigrations` from `Shiki.Persistence.Migration`,
   as the specs do), insert a run row using the existing
   `Shiki.Persistence.Run.insertRunStatement` (see `RunSpec.hs` for how to build a
   `NewRun`), and assert it is present when listing runs from the staging pool and **absent**
   when listing from a freshly-migrated prod pool. This proves the two environments are
   genuinely separate stores.

Test B — legacy fall-through. In a temp dir with **no** `shiki.dhall`, set `SHIKI_DATABASE_URL`
to a known connection string (use `System.Environment.setEnv`, and restore afterwards) and
assert `resolveConnectionString Nothing Nothing` returns it. Then unset both
`SHIKI_DATABASE_URL` and `PG_CONNECTION_STRING` and assert that `resolveConnectionString
Nothing Nothing` raises the "no Postgres connection string" error (catch it with
`Control.Exception.try`/`evaluate` or `tasty-hunit`'s assertion that an `IO` action throws).

Because `getCurrentDirectory`, `SHIKI_ENV`, and `SHIKI_DATABASE_URL` are process-global,
isolate these tests: save and restore the cwd and any env vars within each case, and do not
run env-mutating cases concurrently with each other (the existing suites are run by `tasty`,
which by default may parallelize — if interference appears, wrap the env-sensitive cases in
`Test.Tasty.sequentialTestGroup` or use `Test.Tasty.HUnit` within a single `testCase` that
performs the steps in order).

Register `Shiki.Cli.EnvRoutingSpec` in `shiki-cli/shiki-cli.cabal`'s `test-suite
shiki-cli-test` `other-modules`, and wire its `tests` into the suite aggregator
`shiki-cli/test/Spec.hs`.

Acceptance for M2: `cabal test shiki-cli` runs both cases and they pass, demonstrating that
(a) a run recorded under `--env staging` is stored in and read back from the staging
database and is not visible in the prod database, and (b) with no `shiki.dhall`, resolution
falls back to `SHIKI_DATABASE_URL` and then errors when nothing is set.

### Milestone 3 — Documentation

Scope: document the new connection precedence. No code changes.

Update `docs/user/commands.md`: its environment-variable / option summary currently
describes `--db` as "`SHIKI_DATABASE_URL`, then `PG_CONNECTION_STRING`". Revise the
description of `--db` and the environment-variable summary table to state the full
precedence: `--db` flag → active environment's `databaseUrl` from `shiki.dhall` →
`SHIKI_DATABASE_URL` → `PG_CONNECTION_STRING`. Mention the `--env` / `SHIKI_ENV` selector
and link to `docs/user/project-config.md` (created in EP-12). If EP-12 created
`docs/user/project-config.md` with a note that it "only affects `shiki config show` for
now," update that note to say environment selection now also routes the database for
`run`/`runs`/`agent`. Also update `docs/user/getting-started.md` where it explains
`SHIKI_DATABASE_URL` precedence, and `docs/user/schema.md`'s opening line about migrations
running "against the configured schema" remains accurate (schema is orthogonal) but add a
sentence clarifying that which **database** is migrated/used now depends on the active
environment.

Acceptance for M3: docs accurately describe the precedence and a reader can follow them to
route runs to a chosen environment.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/shiki`. Prefix with `nix develop -c`
if a binary is not found.

Verify the hard dependency (EP-12) is present:

```bash
grep -n "resolveActiveEnvironment" shiki-cli/src/Shiki/Cli/Project.hs
grep -n "envName" shiki-cli/src/Shiki/Cli.hs
```

Both must return matches before proceeding.

Build after M1:

```bash
cabal build all
```

Run tests after M2:

```bash
cabal test shiki-cli
cabal test all      # before considering the plan done
```

Expected M2 output (illustrative; key is the new group passes):

```text
Shiki.Cli.EnvRouting
  staging run is stored in and read back from the staging database: OK
  staging run is not visible in the prod database: OK
  no shiki.dhall falls back to SHIKI_DATABASE_URL: OK
  no connection source errors out: OK
All N tests passed
```

Manual smoke test after M1 (no live database required for the URL check), using a local
ignored `shiki.dhall` copied from EP-12's tracked `shiki.dhall.example`:

```bash
cp shiki.dhall.example shiki.dhall
cabal run shiki -- config show --env staging   # shows staging url (EP-12 command)
cabal run shiki -- config show --env prod       # shows prod url
```

If you have two reachable databases, point the example file at them and confirm:

```bash
cabal run shiki -- runs list --env staging
cabal run shiki -- runs list --env prod
```

read from different stores (after recording a run into one). Update this section with the
actual transcripts as you implement.

Observed 2026-06-11 after implementation:

```text
$ grep -n "resolveActiveEnvironment" shiki-cli/src/Shiki/Cli/Project.hs
13:    resolveActiveEnvironmentName,
14:    resolveActiveEnvironment,
50:resolveActiveEnvironmentName ::
53:resolveActiveEnvironmentName cfg mFlag =
67:resolveActiveEnvironment :: Maybe Text -> IO (Maybe (Text, Environment))
68:resolveActiveEnvironment mFlag =
73:      (name, _src) <- resolveActiveEnvironmentName cfg mFlag
```

```text
$ grep -n "envName" shiki-cli/src/Shiki/Cli.hs
56:    envName :: !(Maybe Text),
70:      runConfigShow (opts ^. #envName)
72:      withDbEnv (opts ^. #dbConnStr) (opts ^. #dbSchema) (opts ^. #envName) $ \_ env ->
75:      withDbEnv (opts ^. #dbConnStr) (opts ^. #dbSchema) (opts ^. #envName) $ \_ env ->
78:      withDbEnv (opts ^. #dbConnStr) (opts ^. #dbSchema) (opts ^. #envName) $ \schema env ->
```

```text
$ cabal build all
... command completed successfully with exit code 0
```

```text
$ cabal test shiki-cli
Shiki.Cli.EnvRouting
  staging run is stored in staging database and absent from prod: OK
  legacy fallback, missing source error, and db flag override:    OK
All 35 tests passed
```

```text
$ cabal test all
... command completed successfully with exit code 0
```


## Validation and Acceptance

The plan is acceptable when:

1. `cabal build all` and `cabal test all` succeed.
2. The M2 routing test proves a run recorded with `--env staging` is stored in and read back
   from the staging database, and is absent from the prod database — i.e. environments are
   genuinely separate stores.
3. The M2 fall-through test proves that with no `shiki.dhall`, `resolveConnectionString
   Nothing Nothing` returns `SHIKI_DATABASE_URL` when set, and errors with the documented
   message when no source is available.
4. `--db CONNSTR` still overrides everything (a quick test or manual check: with a
   `shiki.dhall` present, `resolveConnectionString (Just "host=x") (Just "prod")` returns
   `host=x`, never consulting the config).
5. `shiki config show` (from EP-12) and the database subcommands agree on which URL an
   environment resolves to.
6. Documentation in `docs/user/` states the full precedence.

Acceptance is behavioral: a reviewer with two databases declared in `shiki.dhall` can record
a run under one `--env` and see it appear only in that environment's `runs` history.


## Idempotence and Recovery

All code changes are additive or signature-extending; rebuilding and re-testing is safe and
repeatable. The change is backward compatible: with no `shiki.dhall`, the resolver behaves
exactly as before (verified by the M2 fall-through test), so deploying this does not disturb
existing single-database users.

No data migration occurs. The only runtime behavior change is *which* database a connection
is opened against; that is determined fresh each invocation from flags/config/env and holds
no persistent state. To back out before merge, revert the edits to
`shiki-cli/src/Shiki/Cli/Config.hs` and `shiki-cli/src/Shiki/Cli.hs` and remove the new
test module; nothing else is affected.

If, after this change, an operator sees runs landing in an unexpected database, have them run
`shiki config show --env <name>` (EP-12) to see exactly which URL that environment resolves
to and from where the active environment was selected — that command and this resolver share
the same precedence logic, so they will agree.


## Interfaces and Dependencies

Libraries (all already declared; this plan adds no new dependency to non-test stanzas):

- From `shiki-cli` library `build-depends`: `text`, `base`, plus the EP-12 module
  `Shiki.Cli.Project` (same package).
- From `shiki-core` (already a dependency of `shiki-cli`): `Shiki.Persistence.Connection`
  (`ConnectionString`, `acquirePool`), `Shiki.Persistence.Migration` (`runMigrations`),
  `Shiki.Persistence.Run` (`insertRunStatement`, `NewRun`, run-listing statements) for the
  M2 tests.
- Test stanza already has `ephemeral-pg`, `temporary`, `directory`, `filepath`, `hasql`,
  `hasql-pool`, `tasty`, `tasty-hunit`, `text`, `time`, `uuid`.

Signatures changed by this plan (callers within the repo are limited to `Shiki.Cli`):

- `Shiki.Cli.Config.resolveConnectionString :: Maybe Text -> Maybe Text -> IO ConnectionString`
  (was `Maybe Text -> IO ConnectionString`).
- `Shiki.Cli` (file `shiki-cli/src/Shiki/Cli.hs`) local helper
  `withDbEnv :: Maybe Text -> Maybe Text -> Maybe Text -> (Schema -> CliEnv -> IO a) -> IO a`
  (gained the `--env` argument).

Unchanged but relied upon: `Shiki.Cli.Env.withCliEnv`,
`Shiki.Persistence.Connection.acquirePool`, and the entire run-recording path in
`Shiki.Cli.Run` — they all operate on whatever `ConnectionString` is computed, so no change
is needed there.

Depends on the integration surface defined by
`docs/plans/12-project-local-shiki-dhall-configuration-foundation.md`:
`Shiki.Cli.Project.{resolveActiveEnvironment, ProjectConfig, Environment}` and the
`Options.envName` field. If those signatures differ from what is written above when you
begin, reconcile against EP-12's "Interfaces and Dependencies" section and update this plan's
Decision Log with any deltas.
