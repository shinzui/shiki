---
id: 6
slug: configurable-postgresql-schema-namespace-for-shiki-tables
title: "Configurable PostgreSQL Schema Namespace for Shiki Tables"
kind: exec-plan
created_at: 2026-05-27T20:35:12Z
intention: "intention_01ksnj532hepmtqf5qax83gnt8"
master_plan: "docs/masterplans/1-microservice-job-runner-with-postgres-backed-run-history.md"
---

# Configurable PostgreSQL Schema Namespace for Shiki Tables

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Today the `shiki` CLI installs its bookkeeping into the PostgreSQL `public` schema: it
creates the `runs` table and the `schema_migrations` table that
[`hasql-migration`](https://hackage.haskell.org/package/hasql-migration) uses to track
applied scripts. A "schema" in PostgreSQL — sometimes called a "namespace" — is a named
container for tables, indexes, types, and other objects; every database always has at
least one (`public`). Installing into `public` means `shiki`'s tables collide with anything
else the operator happens to use that same database for (a sandbox app, a side project,
the output of `pg_dump` from production, …), and it makes a `\d` listing in `psql` noisy.

After this plan, `shiki` defaults to creating its tables inside a dedicated PostgreSQL
schema named `shiki`, and operators can override that name via a CLI flag or environment
variable. Specifically:

- A fresh checkout that runs `cabal run shiki -- run …` (or any other subcommand) against
  an empty PostgreSQL database ends up with `shiki.runs` and `shiki.schema_migrations`,
  and `\dt public.*` in `psql` is empty.
- An operator who wants to run multiple isolated `shiki` instances against the same
  PostgreSQL database can give each instance its own schema with
  `shiki --db-schema=staging-shiki …` and watch them not interfere.
- An operator who wants the old behavior keeps it with `shiki --db-schema=public …`.
- The test suite uses a per-test schema so concurrent test runs do not stomp on each
  other.

A reader can see this working by running, against a freshly initialized PostgreSQL:

```bash
psql "$PG_CONNECTION_STRING" -c '\dt public.*'
# expected (an empty listing):
# Did not find any relation matching public.* in schema "public".

cabal run shiki -- runs list --limit 0
# (runs migrations as a side effect, prints an empty table)

psql "$PG_CONNECTION_STRING" -c '\dn'
# expected: a row for "shiki" appears

psql "$PG_CONNECTION_STRING" -c '\dt shiki.*'
# expected: "schema_migrations" and "runs"

psql "$PG_CONNECTION_STRING" -c '\dt public.*'
# expected (still empty): Did not find any relation matching public.*
```

The same behavior is asserted programmatically by a new tasty test that asks the
information schema for the schema of `runs` after migrations have run.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1 — Introduce `Shiki.Persistence.Schema` (new module) exporting a `Schema` newtype,
  a `defaultSchema = Schema "shiki"`, a `mkSchema :: Text -> Either Text Schema`
  validator, a `schemaText :: Schema -> Text` unwrapper, and `quoteSchema :: Schema -> Text`
  that double-quotes the validated identifier for use in SQL literals. Add unit tests
  under `shiki-core/test/Shiki/Persistence/SchemaSpec.hs` that pin down the accepted and
  rejected inputs. _(done 2026-05-27 — 4/4 cases green)_
- [x] M2 — Teach `Shiki.Persistence.Connection.acquirePool` to take a `Schema` argument and
  set `search_path` on every connection acquired from the pool, either via a hasql-pool
  connection-init hook (preferred — research at the start of M2) or by appending
  `options=-c%20search_path%3D...` to the libpq connection URI (fallback). Document the
  approach taken in the Decision Log. _(done 2026-05-27 — hook path via `PoolConfig.initSession`; downstream callers wired in M3/M5)_
- [x] M3 — Teach `Shiki.Persistence.Migration.runMigrations` to take a `Schema` argument
  and to run `CREATE SCHEMA IF NOT EXISTS "<schema>"` inside the same transaction as
  the migration session, before `hasql-migration` initializes `schema_migrations`. The
  `001-create-runs.sql` script is **not** edited — search_path resolves `runs` to
  `<schema>.runs`. _(done 2026-05-27 — `withCliEnv` threads `defaultSchema`; existing
  tasty suite stays green; live `psql` check deferred to M6's ephemeral-pg test since the
  dev Postgres is not running in this session)_
- [x] M4 — Surface the schema as a CLI flag and environment variable. Add
  `Shiki.Cli.Schema` exporting `resolveSchema :: Maybe Text -> IO Schema`, with
  precedence `--db-schema` flag > `SHIKI_DB_SCHEMA` env > default `shiki`. Wire it
  through `Options` in `shiki-cli/src/Shiki/Cli.hs` and `CliEnv` in
  `shiki-cli/src/Shiki/Cli/Env.hs`. Threading the `Schema` through `withCliEnv` is
  enough; nothing else changes in the CLI handlers because table references stay
  unqualified. _(done 2026-05-27 — `cabal run shiki -- --help` lists `--db-schema
  SCHEMA` with the expected help text)_
- [ ] M5 — Update the existing tasty suite so each test runs against a unique schema
  (e.g. `shiki_test_<random>`) instead of the default `shiki`. This proves the
  configurability is real and isolates concurrent test runs.
- [ ] M6 — Add an integration test
  `shiki-core/test/Shiki/Persistence/SchemaIsolationSpec.hs` that, against an
  ephemeral Postgres, runs migrations with `Schema "alpha"` and `Schema "beta"`
  against the same database, inserts one `NewRun` into each, and asserts that
  selecting from `public.runs` raises an `undefined_table` error while
  `information_schema.tables WHERE table_schema = 'alpha' AND table_name = 'runs'`
  returns exactly one row, and the same for `beta`.
- [ ] M7 — Update `README.md` with a short section ("Database schema") describing the
  default and the override knobs. Run `cabal test all` end-to-end and capture the
  transcript into the Concrete Steps section.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **M2** — `hasql-pool 1.4.2` exposes `Hasql.Pool.Config.initSession :: Session () -> Setting`
  exactly for this use case. Its docstring at
  `src/library/other/Hasql/Pool/Config/Setting.hs:87-94` literally cites
  `initSession (Session.sql "SET search_path TO schema1, schema2, public;")` as the
  motivating example. The hook path described as "preferred" in the plan is therefore
  available — no URI rewrite fallback required.
- **M2** — `Hasql.Session.sql` (mentioned in the plan's sample code) no longer exists in
  the `hasql` version we pin. The equivalent is `Hasql.Session.script :: Text -> Session ()`
  (takes `Text` directly, no `Text.Encoding.encodeUtf8` wrapping). Adjusted the
  `setSearchPath` helper accordingly.


## Decision Log

Record every decision made while working on the plan.

- Decision: The default schema is the literal string `shiki`. Configurable, but
  defaulting to the project's own name follows the principle of least surprise and
  matches what the user asked for verbatim in the original task brief.
  Rationale: Operators reading `psql -c '\dn'` immediately understand which extension
  owns the schema; the name does not collide with PostgreSQL reserved words; it is
  short enough to type in ad-hoc `psql` sessions.
  Date: 2026-05-27

- Decision: Resolve unqualified table references via PostgreSQL's `search_path` setting
  (per-connection), rather than rewriting every SQL string in `Shiki.Persistence.Run`
  and every migration script to be schema-qualified.
  Rationale: There are two reasons.

  First, `hasql-migration`'s `schema_migrations` table is created by SQL **inside the
  library itself** (`Hasql.Migration.initializeSchema` at
  `/Users/shinzui/Keikaku/hub/haskell/hasql-migration/src/Hasql/Migration.hs:103`). The
  literal `create table if not exists schema_migrations …` is not parameterizable. The
  only way to redirect that `CREATE TABLE` to a custom schema without forking the
  library is to set `search_path` on the session before invoking
  `Migration.runMigration`. Once we do that for `schema_migrations`, we may as well do
  it for our own tables and keep `001-create-runs.sql` (and every Statement SQL string
  in `shiki-core/src/Shiki/Persistence/Run.hs`) unqualified.

  Second, `hasql-migration` records each applied script by filename + MD5. Editing the
  existing `001-create-runs.sql` to schema-qualify the `CREATE TABLE` would change its
  checksum, which makes the migration runner emit `ScriptChanged` against any database
  where it had already been applied. Avoiding that incompatibility is reason enough to
  leave `001-create-runs.sql` alone.

  Date: 2026-05-27

- Decision: Set `search_path` on every pool-acquired connection at the connection layer
  (not on every Session), so callers of `Pool.use` do not need to wrap their sessions.
  The exact mechanism (hasql-pool connection-init hook vs libpq `options=-c …` URI
  parameter) is left to milestone M2 to resolve based on what `hasql-pool 1.4` actually
  exposes; both approaches are equivalent from the caller's perspective.
  Rationale: If we only set `search_path` inside `migrationSession`, then any
  `Pool.use pool (Session.statement input insertRunStatement)` from EP-4 would acquire
  a fresh connection without `search_path` set and the unqualified `INSERT INTO runs`
  would silently land in `public` (or fail, if `public.runs` does not exist). The
  guarantee must be that every connection handed out by the pool already has
  `search_path` set.
  Date: 2026-05-27

- Decision: Validate schema names against `[A-Za-z_][A-Za-z0-9_]*`, max length 63
  characters. Reject everything else. The validated `Schema` newtype carries the proof,
  and `quoteSchema` adds double-quote delimiters before splicing into SQL.
  Rationale: The schema name appears in a `CREATE SCHEMA IF NOT EXISTS "…"` literal
  that we build by `Text` concatenation. SQL parameter binding only works for values,
  not identifiers. Restricting the character set to a conservative ASCII subset
  eliminates the SQL injection risk; double-quoting handles the (now impossible) case
  of a reserved word like `user`. 63 bytes is PostgreSQL's `NAMEDATALEN` default — a
  longer identifier would be silently truncated on the server.
  Date: 2026-05-27

- Decision: M2 uses `hasql-pool`'s `PoolConfig.initSession` hook rather than the URI
  rewrite fallback.
  Rationale: `hasql-pool 1.4.2` exposes `initSession :: Session () -> Setting`
  (`Hasql.Pool.Config.initSession`), invoked on every newly-acquired connection. The
  upstream docstring at
  `/Users/shinzui/Keikaku/hub/haskell/hasql-project/hasql-pool/src/library/other/Hasql/Pool/Config/Setting.hs:87-94`
  even uses our exact `SET search_path TO …` example. The connection string stays
  untouched and the schema lives in one obvious place at the pool config.
  Note: the plan's sample code calls `Hasql.Session.sql`; in the pinned `hasql` version
  that helper is named `Hasql.Session.script` and takes `Text` directly. The
  implementation uses `Session.script`.
  Date: 2026-05-27

- Decision: Do **not** provide an automatic data migration from `public.runs` to
  `<schema>.runs` for users upgrading from a pre-plan checkout.
  Rationale: This is an early-stage project; per EP-2's Outcomes section the only
  persisted data so far is whatever an operator happened to write during local
  development. The README will document the manual `psql` recipe ("either drop the
  dev database, or `ALTER TABLE public.runs SET SCHEMA shiki` and the matching move
  for `schema_migrations`"). Coding an automatic migration that we will run zero
  production times is not a good use of effort.
  Date: 2026-05-27


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

This plan modifies the `shiki` project — a two-package Haskell cabal repository at
`/Users/shinzui/Keikaku/bokuno/shiki` consisting of `shiki-core` (the library) and
`shiki-cli` (the executable named `shiki`). It targets GHC 9.12.4 inside a Nix flake; the
dev shell at `flake.nix` provides `cabal`, `ghc`, `postgresql`, and `process-compose`. The
flake's shellHook exports `PGHOST`, `PGDATA`, `PGDATABASE=shiki`, and
`PG_CONNECTION_STRING=postgresql:///shiki?host=$PGHOST`.

The persistence layer was built by `docs/plans/2-postgresql-schema-migrations-and-run-persistence.md`
("EP-2"). The relevant files today are:

- `shiki-core/sql/migrations/001-create-runs.sql` — DDL for the `runs` table and two
  supporting indexes. The `CREATE TABLE runs (…)` is unqualified, so the table currently
  lands wherever the connection's `search_path` resolves `runs` to — by default, the
  `public` schema.
- `shiki-core/src/Shiki/Persistence/Migration.hs` — wraps `hasql-migration`'s
  `loadMigrationsFromDirectory` and runs every script through a serializable write
  transaction. Today it takes only `Pool.Pool` and does not know what schema to use.
- `shiki-core/src/Shiki/Persistence/Connection.hs` — wraps `Hasql.Pool` with a
  five-connection pool. Today its `acquirePool :: ConnectionString -> IO Pool.Pool`
  signature ignores schema entirely.
- `shiki-core/src/Shiki/Persistence/Run.hs` — exports the typed hasql `Statement` values
  used by EP-4 (`shiki run`) and EP-5 (`shiki runs …`). Every SQL literal references
  `runs` and `service_name` etc. without a schema prefix; this means it currently
  resolves to `public.runs` and is what we want to keep working unchanged after this
  plan lands.
- `shiki-cli/src/Shiki/Cli.hs` — top-level CLI entry point. Owns the `Options` record
  with `dbConnStr :: Maybe Text` and the `Command` sum.
- `shiki-cli/src/Shiki/Cli/Config.hs` — resolves the Postgres connection string from
  flag, then `SHIKI_DATABASE_URL`, then `PG_CONNECTION_STRING`. We will add a sibling
  module for the schema using the same pattern.
- `shiki-cli/src/Shiki/Cli/Env.hs` — bundles `Pool.Pool` and `ClientEnv` into `CliEnv`
  and runs migrations on startup. We extend the bundle to thread the schema.
- `shiki-core/test/Shiki/Persistence/RunSpec.hs` and
  `shiki-core/test/Shiki/Persistence/RunListSpec.hs` — existing tests that spin up an
  ephemeral Postgres and run migrations + statements. They will be updated to use
  per-test schemas in M5, and M6 adds a dedicated isolation test.

### Term Definitions

- **PostgreSQL schema** — a named container for tables, views, types, etc., scoped to a
  single database. Every database has a default `public` schema. Schemas are listed in
  `psql` with `\dn`. In this plan, a schema is what we use to isolate `shiki`'s tables.
  When the user said "namespace" in the task brief, this is what they meant.
- **Kubernetes namespace** — the existing `runs.namespace :: Text` column refers to a
  Kubernetes namespace, an unrelated concept that happens to share the word. To avoid
  confusion in the codebase, the new Haskell type for the PostgreSQL concept is named
  `Schema`, not `Namespace`.
- **`search_path`** — a per-session PostgreSQL setting (`SET search_path TO …`) that
  controls how unqualified table/type names are resolved. The default value is
  `"$user", public`; we change it to `<schema>, public` so unqualified `runs` resolves
  to `<schema>.runs`. `public` stays in the path so that PostgreSQL extensions
  installed into `public` (e.g. `pgcrypto`) keep working.
- **`hasql-migration`** — the third-party migration runner (forked locally at
  `/Users/shinzui/Keikaku/hub/haskell/hasql-migration` and pinned via `cabal.project`).
  Reads scripts from a directory, applies any not yet applied, and tracks results in a
  `schema_migrations` table whose name is hardcoded inside the library.
- **`hasql-pool`** — the connection pool. We acquire it at CLI startup and use it for
  every database call.

### Cross-Plan Contract

This plan touches the integration points owned by EP-2 (the `runs` schema, the
migration runner, the connection pool wrapper). It does **not** change the public types
exported from `Shiki.Persistence.Run` (`RunRecord`, `NewRun`, `RunCompletion`, the five
`Statement` values), so EP-4 and EP-5 keep working unchanged. The two functions whose
signatures grow are:

- `acquirePool :: ConnectionString -> Schema -> IO Pool.Pool` (new `Schema` parameter)
- `runMigrations :: Pool.Pool -> Schema -> IO ()` (new `Schema` parameter)

Both callers live in this repository (`shiki-cli/src/Shiki/Cli/Env.hs`); there are no
external consumers to coordinate with.


## Plan of Work

The work proceeds in seven milestones. M1 and M2 are the structural backbone; M3 wires
migrations to use the new mechanism; M4 makes the schema selectable at the CLI; M5–M7 are
test and documentation polish. Every milestone leaves the build and the existing test
suite green.

### Milestone 1 — `Shiki.Persistence.Schema` module

Scope: introduce a validated `Schema` newtype and the helpers used to splice it into SQL.
No I/O changes yet.

Create `shiki-core/src/Shiki/Persistence/Schema.hs`:

```haskell
-- | A validated PostgreSQL schema (namespace) identifier. The
--   value-constructor is hidden so callers can only obtain a 'Schema' via
--   'mkSchema' or 'defaultSchema'; this gives every internal user the proof
--   that the wrapped 'Text' is safe to splice into a SQL identifier literal.
module Shiki.Persistence.Schema
  ( Schema
  , defaultSchema
  , mkSchema
  , schemaText
  , quoteSchema
  ) where

import Shiki.Prelude

import "text" Data.Text qualified as Text

-- | A validated PostgreSQL schema name. Members of this type are guaranteed
--   to match @[A-Za-z_][A-Za-z0-9_]*@ and to fit within PostgreSQL's
--   @NAMEDATALEN@ default (63 bytes).
newtype Schema = Schema { unSchema :: Text }
  deriving stock (Generic, Eq, Show)
  deriving newtype (FromJSON, ToJSON)

-- | The default schema used by @shiki@ when nothing else is configured.
defaultSchema :: Schema
defaultSchema = Schema "shiki"

-- | Validate and lift a 'Text' into a 'Schema'. Returns a human-readable
--   error message on failure suitable for printing to stderr.
mkSchema :: Text -> Either Text Schema
mkSchema t
  | Text.null t =
      Left "schema name is empty"
  | Text.length t > 63 =
      Left "schema name exceeds 63 bytes (PostgreSQL NAMEDATALEN)"
  | not (isInitial (Text.head t)) =
      Left "schema name must start with ASCII letter or underscore"
  | not (Text.all isSubsequent t) =
      Left "schema name may only contain ASCII letters, digits, and underscore"
  | otherwise = Right (Schema t)
  where
    isInitial c    = isAsciiAlpha c || c == '_'
    isSubsequent c = isAsciiAlpha c || isAsciiDigit c || c == '_'
    isAsciiAlpha c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
    isAsciiDigit c = c >= '0' && c <= '9'

-- | The raw schema name without quoting. Use this when feeding into a SQL
--   parameter (e.g. @information_schema.tables.table_schema = $1@) or
--   composing libpq connection options.
schemaText :: Schema -> Text
schemaText = unSchema

-- | The schema name wrapped in double quotes, suitable for splicing into a
--   SQL identifier position (e.g. @CREATE SCHEMA IF NOT EXISTS "shiki"@).
--   Because 'mkSchema' rejects everything containing a double quote, no
--   escaping is needed beyond the wrapping pair.
quoteSchema :: Schema -> Text
quoteSchema (Schema s) = "\"" <> s <> "\""
```

Add `Shiki.Persistence.Schema` to the `exposed-modules:` of the library stanza in
`shiki-core/shiki-core.cabal`.

Add unit tests `shiki-core/test/Shiki/Persistence/SchemaSpec.hs`:

```haskell
module Shiki.Persistence.SchemaSpec (tests) where

import Shiki.Prelude

import Shiki.Persistence.Schema
  ( Schema, defaultSchema, mkSchema, quoteSchema, schemaText
  )

import "tasty" Test.Tasty (TestTree, testGroup)
import "tasty-hunit" Test.Tasty.HUnit (assertEqual, testCase)

tests :: TestTree
tests =
  testGroup "Shiki.Persistence.Schema"
    [ testCase "defaultSchema is shiki" $
        assertEqual "" "shiki" (schemaText defaultSchema)

    , testCase "quoteSchema wraps in double quotes" $
        assertEqual "" "\"shiki\"" (quoteSchema defaultSchema)

    , testCase "accepts plain identifiers" $ do
        accept "shiki"
        accept "Shiki"
        accept "_private"
        accept "shiki_test_42"
        accept (Text.replicate 63 "a") -- exactly 63 bytes

    , testCase "rejects empty / leading-digit / long / illegal" $ do
        reject ""
        reject "1shiki"
        reject "shiki-staging"     -- hyphen
        reject "shiki staging"     -- space
        reject "shiki;DROP"        -- semicolon
        reject "shiki\""           -- double quote
        reject (Text.replicate 64 "a") -- one over the limit
    ]
  where
    accept t = case mkSchema t of
      Right s -> assertEqual "round-trips" t (schemaText s)
      Left e  -> fail ("expected " <> show t <> " to validate but got: " <> show e)
    reject t = case mkSchema t of
      Left _  -> pure ()
      Right s -> fail ("expected " <> show t <> " to fail but got: " <> show (schemaText s))
```

Wire the new spec into the test runner: add `Shiki.Persistence.SchemaSpec` to
`other-modules:` of the `test-suite shiki-core-test` stanza in
`shiki-core/shiki-core.cabal`, and add `SchemaSpec.tests` to the `testGroup` list in
`shiki-core/test/Spec.hs`.

Acceptance: `cabal build shiki-core && cabal test shiki-core` — the new
`Shiki.Persistence.Schema` test group reports 4 passing cases; nothing previously green
turns red.

### Milestone 2 — Per-connection `search_path` in `Shiki.Persistence.Connection`

Scope: extend `acquirePool` to take a `Schema` and arrange for every connection it hands
out to start with `search_path = "<schema>", public`. No callers update yet — we wire the
new parameter through in the next milestone.

**Research first.** Read the actual `Hasql.Pool.Config` API surface for the version
pinned by `cabal.project` (`hasql-pool >= 1.4`). Run, from the repo root with the dev
shell active:

```bash
cabal repl shiki-core
-- in the REPL:
:browse Hasql.Pool.Config
```

Look specifically for a setting that runs SQL on each newly-acquired connection
(historically called things like `connectionInit`, `onConnectionEstablished`, or a
session hook). Two outcomes are possible:

- **Hook exists.** Use it. Pass a `Session ()` that runs
  `Session.sql ("SET search_path TO " <> quoteSchema schema <> ", public;")`. This is
  the cleanest path — we keep the connection string untouched and the schema lives in
  one obvious place. Record the chosen setting name in the Decision Log.
- **No hook.** Fall back to rewriting the libpq connection URI to append
  `options=-c%20search_path%3D...` (URL-encoded). PostgreSQL applies `options` to every
  new session that connects with that URI. Record this in the Decision Log too.

Implement whichever path applies in
`shiki-core/src/Shiki/Persistence/Connection.hs`. The new signature is:

```haskell
acquirePool :: ConnectionString -> Schema -> IO Pool.Pool
```

For the **fallback (connection-string rewrite) path**, the helper is:

```haskell
-- | Append @options=-c search_path=...@ to the libpq connection URI so
--   every connection acquired from the resulting pool starts with the
--   shiki schema first on its search_path.
withSchemaOption :: Schema -> Text -> Text
withSchemaOption schema base =
  base <> separator <> "options=" <> urlEncode opt
  where
    -- "-c search_path=\"<schema>\",public"
    opt = "-c search_path=" <> quoteSchema schema <> ",public"
    separator
      | Text.isInfixOf "?" base = "&"
      | otherwise               = "?"
```

`urlEncode` is a small helper that percent-encodes the bytes outside
`[A-Za-z0-9._~-]` per RFC 3986; write it inline or use `http-types`'
`Network.HTTP.Types.URI.urlEncode True` (depends on whether `http-types` is already
transitively available — check with `cabal info shiki-core` if unsure).

For the **hook path** the helper is just a `Session ()`:

```haskell
setSearchPath :: Schema -> Hasql.Session.Session ()
setSearchPath schema =
  Hasql.Session.sql
    ( Text.Encoding.encodeUtf8
        ( "SET search_path TO " <> quoteSchema schema <> ", public;" )
    )
```

Either way, the **types** to expose are the same: only `acquirePool`'s signature
grows.

Acceptance: `cabal build shiki-core` succeeds. The function compiles and is callable
from `cabal repl shiki-core` with `:t acquirePool` showing the new signature. End-to-end
verification happens in M3.

### Milestone 3 — Schema-aware migrations

Scope: extend `runMigrations` to take a `Schema`, ensure the schema exists in the
database before any migration runs, and rely on the search_path machinery from M2 for
everything else.

Edit `shiki-core/src/Shiki/Persistence/Migration.hs`:

```haskell
-- | Apply every unapplied migration script in 'migrationsDirectory',
--   ensuring @CREATE SCHEMA IF NOT EXISTS \"<schema>\"@ runs first so the
--   @schema_migrations@ table that @hasql-migration@ creates lands inside
--   the configured schema rather than @public@.
runMigrations :: Pool.Pool -> Schema -> IO ()
runMigrations pool schema = do
  dir <- migrationsDirectory
  scripts <- Migration.loadMigrationsFromDirectory dir
  let cmds = Migration.MigrationInitialization : scripts
  result <- Pool.use pool (migrationSession schema cmds)
  case result of
    Left poolErr ->
      error ("shiki: migration pool error: " <> show poolErr)
    Right Nothing -> pure ()
    Right (Just merr) ->
      error ("shiki: migration failed: " <> show merr)

migrationSession
  :: Schema
  -> [Migration.MigrationCommand]
  -> Session.Session (Maybe Migration.MigrationError)
migrationSession schema scripts =
  transaction Serializable Write $ do
    -- Belt-and-braces: the pool already sets search_path on connection
    -- acquire (M2), but CREATE SCHEMA does not need search_path and is
    -- a no-op when the schema is already there.
    Transaction.sql
      ( Text.Encoding.encodeUtf8
          ( "CREATE SCHEMA IF NOT EXISTS " <> quoteSchema schema <> ";" )
      )
    runFirstError scripts
  where
    runFirstError [] = pure Nothing
    runFirstError (c : cs) =
      Migration.runMigration c >>= \case
        Just err -> pure (Just err)
        Nothing -> runFirstError cs
```

Note the imports required:

```haskell
import "hasql-transaction" Hasql.Transaction qualified as Transaction
import "text" Data.Text.Encoding qualified as Text.Encoding
import Shiki.Persistence.Schema (Schema, quoteSchema)
```

Edit `shiki-cli/src/Shiki/Cli/Env.hs` to thread the schema through; for now (M3) hardcode
`defaultSchema` at the call site:

```haskell
import Shiki.Persistence.Schema (defaultSchema)

withCliEnv :: ConnectionString -> (CliEnv -> IO a) -> IO a
withCliEnv cs action =
  bracket (acquirePool cs defaultSchema) releasePool $ \p -> do
    runMigrations p defaultSchema
    cl <- loadDefaultClientConfig
    action CliEnv { pool = p, client = cl }
```

Update the existing test helpers in `shiki-core/test/Shiki/Persistence/RunSpec.hs` and
`shiki-core/test/Shiki/Persistence/RunListSpec.hs` to pass `defaultSchema` to the new
signatures so the build does not break. (M5 will tighten this to per-test schemas; for
now the migration to a non-default schema is the responsibility of M6's dedicated
isolation test.)

Acceptance:

1. `cabal build all && cabal test shiki-core` — all previously-green tests stay green.
2. Manual check from the dev shell, with `process-compose up` running and
   `PG_CONNECTION_STRING` exported:

   ```bash
   psql "$PG_CONNECTION_STRING" -c 'DROP SCHEMA IF EXISTS shiki CASCADE;'
   cabal run shiki-core:shiki-run-once   -- (or any command that triggers withCliEnv)
   psql "$PG_CONNECTION_STRING" -c '\dn'
   psql "$PG_CONNECTION_STRING" -c '\dt shiki.*'
   ```

   The `\dn` listing must include a row named `shiki`. The `\dt shiki.*` listing must
   include `runs` and `schema_migrations`. The `\dt public.*` listing must remain empty.

### Milestone 4 — CLI flag and environment variable

Scope: let the operator choose the schema at invocation time. Default stays `shiki`.

Create `shiki-cli/src/Shiki/Cli/Schema.hs`:

```haskell
-- | Resolve the PostgreSQL schema for @shiki@ subcommands.
--   Precedence: @--db-schema@ flag, then @SHIKI_DB_SCHEMA@ env var, then
--   @defaultSchema@ (which is @"shiki"@).
module Shiki.Cli.Schema
  ( resolveSchema
  ) where

import Shiki.Prelude

import Shiki.Persistence.Schema (Schema, defaultSchema, mkSchema)

import "text" Data.Text qualified as Text
import "base" System.Environment (lookupEnv)

resolveSchema :: Maybe Text -> IO Schema
resolveSchema = \case
  Just t  -> liftEither (mkSchema t)
  Nothing ->
    lookupEnv "SHIKI_DB_SCHEMA" >>= \case
      Just s | not (null s) -> liftEither (mkSchema (Text.pack s))
      _                     -> pure defaultSchema
  where
    liftEither = \case
      Right s  -> pure s
      Left err -> error ("shiki: invalid schema name: " <> Text.unpack err)
```

Edit `shiki-cli/src/Shiki/Cli.hs`:

- Add `Shiki.Cli.Schema (resolveSchema)` to the imports.
- Extend `data Options`:

  ```haskell
  data Options = Options
    { dbConnStr :: !(Maybe Text)
    , dbSchema  :: !(Maybe Text)
    , command   :: !Command
    }
    deriving stock (Generic, Eq, Show)
  ```

- Extend `optionsParser`:

  ```haskell
  optionsParser :: Parser Options
  optionsParser =
    Options
      <$> Opt.optional
            ( Opt.strOption
                ( Opt.long "db"
                    <> Opt.metavar "CONNSTR"
                    <> Opt.help
                        "Postgres connection string (overrides SHIKI_DATABASE_URL / PG_CONNECTION_STRING)"
                )
            )
      <*> Opt.optional
            ( Opt.strOption
                ( Opt.long "db-schema"
                    <> Opt.metavar "SCHEMA"
                    <> Opt.help
                        "Postgres schema for shiki tables (default: shiki, overrides SHIKI_DB_SCHEMA)"
                )
            )
      <*> commandParser
  ```

- Update `withDbEnv` to resolve and thread the schema:

  ```haskell
  withDbEnv :: Maybe Text -> Maybe Text -> (CliEnv -> IO a) -> IO a
  withDbEnv mConn mSchema k = do
    cs     <- resolveConnectionString mConn
    schema <- resolveSchema mSchema
    withCliEnv cs schema k
  ```

- Update the two callers of `withDbEnv` in `runCli`:

  ```haskell
  Run runOpts    ->
    withDbEnv (opts ^. #dbConnStr) (opts ^. #dbSchema) $ \env -> runRun env runOpts
  Runs runsOpts  ->
    withDbEnv (opts ^. #dbConnStr) (opts ^. #dbSchema) $ \env -> runRuns env runsOpts
  ```

Edit `shiki-cli/src/Shiki/Cli/Env.hs` so `withCliEnv` accepts and forwards the schema
to `acquirePool` and `runMigrations`:

```haskell
withCliEnv :: ConnectionString -> Schema -> (CliEnv -> IO a) -> IO a
withCliEnv cs schema action =
  bracket (acquirePool cs schema) releasePool $ \p -> do
    runMigrations p schema
    cl <- loadDefaultClientConfig
    action CliEnv { pool = p, client = cl }
```

Add `Shiki.Cli.Schema` to the `exposed-modules:` of the library stanza in
`shiki-cli/shiki-cli.cabal`.

Acceptance:

1. `cabal build all` succeeds and `cabal run shiki -- --help` lists the new
   `--db-schema` flag in the help output.
2. Against a freshly initialized Postgres:

   ```bash
   psql "$PG_CONNECTION_STRING" -c 'DROP SCHEMA IF EXISTS shiki CASCADE;'
   psql "$PG_CONNECTION_STRING" -c 'DROP SCHEMA IF EXISTS staging CASCADE;'
   cabal run shiki -- --db-schema=staging runs list --limit 0
   psql "$PG_CONNECTION_STRING" -c '\dt staging.*'
   psql "$PG_CONNECTION_STRING" -c '\dt shiki.*'
   ```

   The `staging.*` listing has `runs` and `schema_migrations`; the `shiki.*` listing is
   empty (no schema named `shiki` exists in this database).

### Milestone 5 — Per-test schemas in the existing suite

Scope: prove the schema parameter is real by giving every existing test its own
schema. The current `Shiki.Persistence.RunSpec` and `Shiki.Persistence.RunListSpec`
modules both spin up an ephemeral Postgres and then call `runMigrations pool`. Update
them to generate a unique schema per test (e.g. via `Data.UUID.V4.nextRandom`) and pass
it through to both `acquirePool` and `runMigrations`.

A small helper in a new module `shiki-core/test/Shiki/Persistence/TestPg.hs` keeps the
two test files dry:

```haskell
module Shiki.Persistence.TestPg
  ( withSchemaPool
  , freshSchema
  ) where

import Shiki.Prelude

import Shiki.Persistence.Connection
  ( ConnectionString (..), acquirePool, releasePool )
import Shiki.Persistence.Migration (runMigrations)
import Shiki.Persistence.Schema (Schema, mkSchema)

import "base" Control.Exception (bracket)
import "ephemeral-pg" EphemeralPg qualified as EpPg
import "hasql-pool" Hasql.Pool qualified as Pool
import "text" Data.Text qualified as Text
import "uuid" Data.UUID.V4 qualified as UUIDv4

-- | A fresh, randomly-named schema each call. Useful for test isolation.
--   The name is always prefixed with @shiki_test_@ so a leftover schema is
--   obviously test detritus.
freshSchema :: IO Schema
freshSchema = do
  u <- UUIDv4.nextRandom
  -- UUID4s contain hyphens which mkSchema rejects; strip them.
  let raw = "shiki_test_" <> Text.replace "-" "" (Text.pack (show u))
  case mkSchema raw of
    Right s -> pure s
    Left e  -> error ("freshSchema: unexpectedly invalid schema: " <> Text.unpack e)

-- | Spin up an ephemeral Postgres, allocate a fresh schema, acquire a pool,
--   run migrations, hand the pool to the action.
withSchemaPool :: (Pool.Pool -> IO ()) -> IO ()
withSchemaPool action = do
  schema <- freshSchema
  result <- EpPg.with $ \db -> do
    let cs = ConnectionString (EpPg.connectionString db)
    bracket (acquirePool cs schema) releasePool $ \pool -> do
      runMigrations pool schema
      action pool
  case result of
    Right () -> pure ()
    Left err ->
      fail ("ephemeral-pg failed to start: " <> show (EpPg.renderStartError err))
```

Replace the local `withTempPg` definitions in `RunSpec.hs` and `RunListSpec.hs` with
`withSchemaPool` from this helper. Drop the inline `runMigrations pool` line from those
specs because the helper now runs migrations as part of the bracket.

Wire `Shiki.Persistence.TestPg` into `other-modules:` of the test-suite stanza in
`shiki-core/shiki-core.cabal`.

Acceptance: `cabal test shiki-core` — every previously-green test stays green; the two
specs no longer share a hardcoded schema name, which the M6 isolation test will rely
on.

### Milestone 6 — Schema isolation integration test

Scope: a new tasty test that proves two distinct schemas coexist in one database.

Add `shiki-core/test/Shiki/Persistence/SchemaIsolationSpec.hs`:

```haskell
module Shiki.Persistence.SchemaIsolationSpec (tests) where

import Shiki.Prelude

import Shiki.Persistence.Connection
  ( ConnectionString (..), acquirePool, releasePool )
import Shiki.Persistence.Migration (runMigrations)
import Shiki.Persistence.Run
  ( NewRun (..), insertRunStatement, newRunId )
import Shiki.Persistence.Schema (Schema, mkSchema, schemaText)

import "base" Control.Exception (bracket)
import "aeson" Data.Aeson qualified as Aeson
import "ephemeral-pg" EphemeralPg qualified as EpPg
import "hasql-pool" Hasql.Pool qualified as Pool
import "hasql" Hasql.Decoders qualified as Decoders
import "hasql" Hasql.Encoders qualified as Encoders
import "hasql" Hasql.Session qualified as Session
import "hasql" Hasql.Statement (Statement, preparable)
import "base" Data.Functor.Contravariant ((>$<))
import "tasty" Test.Tasty (TestTree, testGroup)
import "tasty-hunit" Test.Tasty.HUnit (assertEqual, testCase)

tests :: TestTree
tests = testGroup "Shiki.Persistence.Schema (isolation)"
  [ testCase "two schemas in one database stay separate" $ do
      Right alpha <- pure (mkSchema "alpha")
      Right beta  <- pure (mkSchema "beta")
      result <- EpPg.with $ \db -> do
        let cs = ConnectionString (EpPg.connectionString db)
        runOnePool cs alpha
        runOnePool cs beta
        verifyCount cs alpha 1
        verifyCount cs beta  1
        verifyMissingFromPublic cs
      case result of
        Right () -> pure ()
        Left err ->
          fail ("ephemeral-pg failed to start: " <> show (EpPg.renderStartError err))
  ]

runOnePool :: ConnectionString -> Schema -> IO ()
runOnePool cs schema =
  bracket (acquirePool cs schema) releasePool $ \pool -> do
    runMigrations pool schema
    now <- getCurrentTime
    rid <- newRunId
    let r = NewRun
          { runId         = rid
          , serviceName   = "svc-" <> schemaText schema
          , command       = ["x"]
          , namespace     = "ns"
          , jobName       = "job"
          , image         = Nothing
          , startedAt     = now
          , serviceConfig = Aeson.object []
          }
    Pool.use pool (Session.statement r insertRunStatement)
      >>= either (fail . show) pure

verifyCount :: ConnectionString -> Schema -> Int -> IO ()
verifyCount cs schema expected =
  bracket (acquirePool cs schema) releasePool $ \pool -> do
    n <- Pool.use pool (Session.statement () countRuns)
           >>= either (fail . show) pure
    assertEqual ("rows in " <> show (schemaText schema)) expected n

countRuns :: Statement () Int
countRuns =
  preparable
    "SELECT COUNT(*) :: int FROM runs"
    Encoders.noParams
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int4)))
  & fmap fromIntegral

verifyMissingFromPublic :: ConnectionString -> IO ()
verifyMissingFromPublic cs = do
  -- Acquire a pool without setting search_path to a shiki schema. The
  -- cleanest way is to pass a schema named "public" so search_path falls
  -- back to the default behavior; then "SELECT 1 FROM public.runs LIMIT 1"
  -- must fail with undefined_table because we never created it there.
  Right pub <- pure (mkSchema "public")
  bracket (acquirePool cs pub) releasePool $ \pool -> do
    res <- Pool.use pool (Session.statement () existsRunsInPublic)
    case res of
      Left _  -> pure ()              -- expected: undefined table / similar
      Right 0 -> pure ()              -- also fine (table absent → empty count)
      Right n ->
        fail ("public.runs unexpectedly held " <> show n <> " row(s)")

existsRunsInPublic :: Statement () Int
existsRunsInPublic =
  preparable
    "SELECT COUNT(*) :: int FROM information_schema.tables \
    \WHERE table_schema = 'public' AND table_name = 'runs'"
    Encoders.noParams
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int4)))
```

(The `countRuns` and `existsRunsInPublic` decoders are small enough to inline; if the
compiler complains about the `& fmap fromIntegral` punning, replace with an explicit
helper.)

Wire it into `Spec.hs`:

```haskell
import Shiki.Persistence.SchemaIsolationSpec qualified as SchemaIsolationSpec

main =
  defaultMain $
    testGroup "shiki-core"
      [ ConfigSpec.tests
      , RunSpec.tests
      , RunListSpec.tests
      , JobBuilderSpec.tests
      , SchemaSpec.tests
      , SchemaIsolationSpec.tests
      ]
```

Add `Shiki.Persistence.SchemaIsolationSpec` to `other-modules:` in
`shiki-core/shiki-core.cabal`.

Acceptance: `cabal test shiki-core` runs both the new spec and the unit spec from M1
and reports them green. The "two schemas in one database stay separate" case
demonstrates the user-visible win: two namespaces, one database, no collision.

### Milestone 7 — README and end-to-end transcript

Scope: tell future operators about the new knob; capture proof-of-life.

Edit `README.md` (anchor: a new `## Database schema` subsection just after `## Layout`).
The prose of that subsection should say:

> `shiki` installs its tables into a dedicated PostgreSQL schema (`shiki` by default)
> so they do not pollute `public`. Override the schema name with `--db-schema=<name>`
> on any subcommand, or with `SHIKI_DB_SCHEMA=<name>` in the environment. The default
> behavior is unchanged for fresh databases. If you are upgrading from a checkout that
> wrote into `public`, either drop the dev database or move the existing tables
> manually with the `ALTER TABLE … SET SCHEMA shiki` recipe below.

Inside that README subsection, include this fenced `sql` example showing the migration
recipe:

```sql
CREATE SCHEMA IF NOT EXISTS shiki;
ALTER TABLE public.runs              SET SCHEMA shiki;
ALTER TABLE public.schema_migrations SET SCHEMA shiki;
```

Then run an end-to-end check and paste the transcript into the Concrete Steps section
of this plan.

Acceptance: `cabal test all` reports every test passing; the README change renders
cleanly in a Markdown viewer; the Concrete Steps section contains the transcript.


## Concrete Steps

All commands assume the working directory is `/Users/shinzui/Keikaku/bokuno/shiki` and
the dev shell is active (`nix develop` or direnv).

After Milestone 1:

```bash
cabal build shiki-core
cabal test shiki-core --test-options="--pattern=Schema"
```

Expected tail:

```text
Shiki.Persistence.Schema
  defaultSchema is shiki:                              OK
  quoteSchema wraps in double quotes:                  OK
  accepts plain identifiers:                           OK
  rejects empty / leading-digit / long / illegal:      OK

All 4 tests passed
```

After Milestones 2-3:

```bash
psql "$PG_CONNECTION_STRING" -c 'DROP SCHEMA IF EXISTS shiki CASCADE;'
cabal test shiki-core
psql "$PG_CONNECTION_STRING" -c '\dn'
```

Expected (relevant lines):

```text
 List of schemas
   Name   |  Owner
----------+----------
 public   | postgres
 shiki    | shinzui     -- ← created by runMigrations
```

After Milestone 4:

```bash
cabal run shiki -- --help
```

Expected (excerpt):

```text
  --db-schema SCHEMA       Postgres schema for shiki tables (default: shiki,
                           overrides SHIKI_DB_SCHEMA)
```

After Milestones 5-7:

```bash
cabal test all
```

Expected: every previously-green test is still green; the new `Schema` group and
`SchemaIsolationSpec` group both report `OK`.

Final psql proof:

```bash
psql "$PG_CONNECTION_STRING" -c '\dt public.*'
psql "$PG_CONNECTION_STRING" -c '\dt shiki.*'
```

Expected:

```text
Did not find any relation matching public.* in schema "public".

 List of relations
 Schema |       Name        | Type  |  Owner
--------+-------------------+-------+---------
 shiki  | runs              | table | shinzui
 shiki  | schema_migrations | table | shinzui
```


## Validation and Acceptance

Acceptance is the conjunction of the following observable facts. Each can be checked by
a human from a fresh checkout under `nix develop`:

1. `cabal build all && cabal test all` succeeds end-to-end.

2. `cabal run shiki -- --help` lists `--db-schema SCHEMA` exactly once.

3. Against an empty Postgres, `cabal run shiki -- runs list --limit 0` causes the
   `shiki` schema and the two tables `shiki.runs` and `shiki.schema_migrations` to be
   created, and `public` stays empty:

   ```bash
   psql "$PG_CONNECTION_STRING" -c '\dt public.*'
   # → "Did not find any relation matching public.*"
   psql "$PG_CONNECTION_STRING" -c "select table_schema from information_schema.tables where table_name='runs'"
   # → exactly one row, "shiki"
   ```

4. Running `cabal run shiki -- --db-schema=staging runs list --limit 0` against the same
   database creates the same tables in `staging` without disturbing `shiki`.

5. `cabal test shiki-core` includes a `Shiki.Persistence.Schema (isolation)` group with
   one passing case proving that two schemas in one database stay separate.

6. The Surprises & Discoveries section is populated with the outcome of M2's research
   step (which `hasql-pool` hook was used, or that none existed and we fell back to
   the URI rewrite).


## Idempotence and Recovery

Re-running `runMigrations p schema` is a no-op: `CREATE SCHEMA IF NOT EXISTS` does
nothing if the schema exists, and `hasql-migration` skips scripts whose
filename+checksum already appears in `schema_migrations`.

`acquirePool cs schema` is likewise idempotent in the sense that calling it multiple
times yields independent pools; the connection-level `search_path` is reset each time
a new connection is established, so leftover state from previous test runs does not
leak in.

If a migration ever errors out partway through, the schema may exist but the migration
record may not. The recovery is to inspect `<schema>.schema_migrations`, decide whether
the partial state is salvageable, and either re-run (if the migration is idempotent at
the DDL level — `CREATE TABLE IF NOT EXISTS` etc.) or drop the schema (`DROP SCHEMA
<schema> CASCADE`) and let the next run recreate everything from scratch. The drop
recovery path is the same as today; nothing about this plan makes it riskier.

For operators upgrading from a pre-plan checkout whose existing data lives in
`public.runs`: the README documents two safe paths (drop the dev database, or move the
tables with `ALTER TABLE … SET SCHEMA shiki`). Neither happens automatically; this is
deliberate (see the Decision Log).


## Interfaces and Dependencies

No new third-party dependencies. The plan uses libraries already pinned by EP-2:

- `hasql >= 1.10` — for `Hasql.Session.sql`, the `preparable` smart constructor, and the
  encoder/decoder primitives that already power `Shiki.Persistence.Run`.
- `hasql-pool >= 1.4` — for the connection pool and (if the API supports it) the
  per-connection init hook.
- `hasql-transaction >= 1.2` — for `Hasql.Transaction.sql` inside the migration session.
- `hasql-migration` (local fork at `/Users/shinzui/Keikaku/hub/haskell/hasql-migration`)
  — unchanged.
- `uuid ^>=1.3` — only used in the test helper `freshSchema`.

Module surface at end of plan:

- `Shiki.Persistence.Schema` (new)

  ```haskell
  data Schema                          -- abstract; value constructor hidden
  defaultSchema :: Schema              -- = Schema "shiki"
  mkSchema      :: Text -> Either Text Schema
  schemaText    :: Schema -> Text
  quoteSchema   :: Schema -> Text
  ```

- `Shiki.Persistence.Connection` (changed)

  ```haskell
  acquirePool :: ConnectionString -> Schema -> IO Pool.Pool   -- new Schema parameter
  releasePool :: Pool.Pool -> IO ()                            -- unchanged
  ```

- `Shiki.Persistence.Migration` (changed)

  ```haskell
  runMigrations       :: Pool.Pool -> Schema -> IO ()          -- new Schema parameter
  migrationsDirectory :: IO FilePath                            -- unchanged
  ```

- `Shiki.Cli.Schema` (new)

  ```haskell
  resolveSchema :: Maybe Text -> IO Schema
  ```

- `Shiki.Persistence.Run` (unchanged surface — but every Statement now resolves through
  the configured schema via `search_path`)

Downstream consumers in this repository:

- `Shiki.Cli.Env.withCliEnv` (changed to take and forward a `Schema`).
- `Shiki.Cli.runCli` (changed to parse `--db-schema` and call `resolveSchema`).
- EP-4 (`Shiki.Cli.Run`) and EP-5 (`Shiki.Cli.Runs`) — **no changes**. They consume the
  same `CliEnv` they always have; they keep running unqualified SQL Statements; the
  Statements continue to find the `runs` table because `search_path` resolves it.
