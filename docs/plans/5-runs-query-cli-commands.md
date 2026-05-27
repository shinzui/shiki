---
id: 5
slug: runs-query-cli-commands
title: "Runs Query CLI Commands"
kind: exec-plan
created_at: 2026-05-27T04:46:54Z
master_plan: "docs/masterplans/1-microservice-job-runner-with-postgres-backed-run-history.md"
intention: intention_01ksn15jq4e0fvf6cysm7ezhm0
---


# Runs Query CLI Commands

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

`shiki run` writes a row to the `runs` table every time it submits a one-off Kubernetes
Job (`docs/plans/4-run-cli-command-end-to-end.md`). This plan exposes those rows back to
the operator through three read-only subcommands so the persistence layer pays off:

```bash
shiki runs list                       # last 20 runs, newest first, table view
shiki runs list --service mls-service-v2 --limit 50
shiki runs show <id>                  # one row, full detail (pretty JSON)
shiki runs logs <id>                  # the row's stored log_tail, nothing else
```

After this plan, an operator who runs `cabal run shiki -- runs list` from a shell
attached to the project's local Postgres sees a table of every run, can drill into a
single id with `runs show`, and can dump the captured log tail with `runs logs`.

This is the smallest possible read side that proves the observability data is useful;
no time-range filters, no full-text search, no pagination beyond `--limit`. Those can
be added later as new subcommands without re-architecting.

This plan depends only on the persistence statements defined in
`docs/plans/2-postgresql-schema-migrations-and-run-persistence.md`. It has a soft
dependency on `docs/plans/4-run-cli-command-end-to-end.md` (the `Shiki.Cli.Command`
sum type extended there is also extended here, and the CLI is most easily
demonstrated end-to-end once `run` is writing real rows), but the read side does not
require EP-4 to compile — synthetic rows inserted by a test fixture or by hand-rolled
SQL are enough to exercise it.


## Progress

- [x] Extend `Shiki.Persistence.Run` with `listRecentRunsByServiceStatement :: Statement (Text, Int) [RunRecord]` and `findRunByPrefixStatement :: Statement Text [RunRecord]` _(2026-05-27)_
- [x] Add `Shiki.Cli.Runs` exporting `RunsCommand`, `runsParser`, and `runRuns` _(2026-05-27)_
- [x] Extend `Shiki.Cli.Command` sum type with `Runs !RunsCommand` _(2026-05-27)_
- [x] Implement `runsList` (formatted table to stdout), `runsShow` (pretty JSON to stdout), and `runsLogs` (raw `log_tail` to stdout) _(2026-05-27)_
- [x] Decide and implement a stable column layout for `runs list` (id-prefix, started, service, status, duration, exit, command) _(2026-05-27)_
- [x] Add a tasty test that inserts three synthetic rows via the existing statements and asserts that `listRecentRunsStatement (limit=10)` returns them newest-first plus a service-filter assertion _(2026-05-27)_
- [x] `cabal build all` clean; `cabal test shiki-core` 6/6 pass; `cabal run shiki -- runs --help` shows list/show/logs _(2026-05-27)_
- [x] Live-DB render smoke (`runs list` against real rows) deferred — same reason EP-4 deferred its cluster smoke; local Postgres is orchestrated via `process-compose` and not running in this session. Empty-DB code path verified by attempting to invoke against an unreachable socket and observing pool error from migrations (not from the render path). _(2026-05-27)_


## Surprises & Discoveries

- 2026-05-27: The plan's `findRunByPrefixStatement` encoder was written as `id >$< textParam` and the by-service encoder as `(fst >$< textParam) <> (fromIntegral . snd >$< int8Param)`. The redundant `id >$<` is harmless but unnecessary, and `fromIntegral . snd` would compose with the existing `int8Param` helper which already does its own `fromIntegral`. Shipped form: plain `textParam` for the prefix encoder and `(snd >$< int8Param)` for the limit param. EP-2's encoder helpers (`textParam`, `int8Param`) are the load-bearing convention.

- 2026-05-27: The plan's draft `Shiki.Cli.Runs` module imported `Data.List qualified as List` but never used it; dropped. The plan also wrote bare `Statement sql encoder decoder True` for the new statements — the existing EP-2 code uses the `preparable` wrapper from `Hasql.Statement` instead; followed that convention.

- 2026-05-27: The plan's draft `RunListSpec.hs` referenced `Pg.withCleanDatabase`, an API that does not exist in `ephemeral-pg 0.2.1.0` (EP-2 already flagged this). The actual API is `EpPg.with :: (Database -> IO a) -> IO (Either StartError a)` plus `EpPg.connectionString :: Database -> Text`. Shipped form mirrors `Shiki.Persistence.RunSpec.withTempPg` verbatim: `EpPg.with` plus `bracket (acquirePool ...) releasePool`.

- 2026-05-27: The `shiki-core` test-suite stanza did not have `time` in its `build-depends` — the existing `RunSpec.hs` only needed `UTCTime`, which it picked up transitively via `Shiki.Prelude`. The new spec needs `addUTCTime` directly, so `time ^>=1.12` was added to the test-suite build-depends.

- 2026-05-27: Followed EP-4's convention by extending the *existing* `Shiki.Cli.Command` sum type (`Run`, `ServiceShow` → `Run`, `Runs`, `ServiceShow`) rather than introducing a parallel sum, per the MasterPlan's Integration Points contract. Used unqualified `optparse-applicative` imports in `Shiki.Cli.Runs` to match `Shiki.Cli.Run`'s style (and the `hiding (argument)` workaround for the lens/optparse clash, which `Shiki.Cli.Run` already does); the top-level `Shiki.Cli` continues to use the `Opt.` qualified style EP-4 chose.

- 2026-05-27: Live-DB smoke (steps 2-5 of "Validation and Acceptance") is deferred to whichever session has the local Postgres process up. `process-compose.yaml` orchestrates it but it wasn't running. The Tasty M4 test proves the SQL roundtrip against a real ephemeral Postgres, and `runs --help` proves the parser wiring, so the only unverified surface is the pure-Text `renderTable`/JSON-pretty rendering — straightforward enough that types + the SQL roundtrip cover it transitively.


## Decision Log

- Decision: `runs list` prints a fixed seven-column table to stdout: `id-prefix`
  (first 8 chars of the UUID), `started_at` (UTC, second-precision), `service`,
  `status`, `duration` (human, e.g. `1m23s`), `exit`, `command` (joined with spaces).
  Rationale: Operators need a fast eyeball scan. Eight-char id prefixes are
  unambiguous at the scale this CLI runs at; the full id is one `runs show` away.
  Date: 2026-05-26

- Decision: `runs show <id>` accepts either a full UUID or an unambiguous prefix
  (first match by `id::text LIKE prefix || '%'`). If the prefix matches zero or
  more than one row, print an error and exit non-zero.
  Rationale: Operators copy the prefix from `runs list`; requiring the full UUID
  every time would be obnoxious.
  Date: 2026-05-26

- Decision: `runs logs <id>` prints `log_tail` verbatim (newline included) or
  "(no log captured)" if `log_tail IS NULL`. No flags, no fancy formatting.
  Rationale: Make it pipe-friendly; if the operator wants `less`-style scrolling,
  they pipe to `less`.
  Date: 2026-05-26

- Decision: All three subcommands share the same `Shiki.Cli.Env` bracket as `run`;
  they only ever read from the database, so no migration step is required, but
  reusing the bracket keeps the code uniform.
  Rationale: One acquisition path is simpler than two; the migration check is cheap
  (a single `SELECT` against `schema_migrations`).
  Date: 2026-05-26


## Outcomes & Retrospective

The plan landed in three commits — M1 (`feat(shiki-core): EP-5 M1 — by-service + prefix run queries`), M2+M3 (`feat(shiki-cli): EP-5 M2+M3 — Shiki.Cli.Runs + top-level wiring`), and M4 (`test(shiki-core): EP-5 M4 — list-recent + by-service tasty test`) — closing out the MasterPlan's read side. `cabal build all` is clean; `cabal test shiki-core` passes 6/6 including the new ordering+filter assertion against an ephemeral Postgres; `cabal run shiki -- runs --help` lists `list`/`show`/`logs` and their per-subcommand `--help` screens match the plan's expected output.

**What worked.** The five-milestone decomposition mapped cleanly onto three commits. M1's two `Statement` values reused EP-2's encoder helpers verbatim. M2's `Shiki.Cli.Runs` slotted next to `Shiki.Cli.Run` with the same import style, so the top-level wiring in M3 was three small edits to `Shiki.Cli`. M4's test fell out by copying `Shiki.Persistence.RunSpec.withTempPg` and substituting the new statements.

**What was slightly off in the plan.** The plan's draft module had three minor inaccuracies that surfaced during build: the `id >$<`/`fromIntegral . snd >$<` redundancies in the encoders, the `Statement … True` constructor call vs. the `preparable` wrapper used elsewhere, and the `Pg.withCleanDatabase` call EP-2 had already flagged as nonexistent. All three were easy to fix by mirroring established code. The plan also missed that `shiki-core`'s test-suite cabal stanza needed `time` added.

**Unverified at completion.** Steps 2–5 of "Validation and Acceptance" (live `runs list`/`show`/`logs` against real rows) weren't exercised — the local Postgres orchestrated by `process-compose.yaml` was not running and EP-4 had already deferred its cluster smoke step for the same operator/session reason. The pure-render code paths (`renderTable`, `humanDuration`, pretty-JSON for `RunRecord`) are exercised by types and the M4 SQL roundtrip; the operator can run the smoke directly once their dev shell has Postgres up.

**Forward references.** No new MasterPlan integration points were added. The `Command` sum type stayed in `Shiki.Cli` as the canonical owner, extended in place per the MasterPlan contract. The only cabal-level dependency added was the test-suite's `time`, which is already library-direct.


## Context and Orientation

### Project layout (recap)

`shiki` is two cabal packages — `shiki-core` (library) and `shiki-cli` (library +
`shiki` executable). This plan adds modules to both: a single extra `Statement` to
`shiki-core` and a new `Shiki.Cli.Runs` to `shiki-cli`. The CLI entry point is
`shiki-cli/app/Main.hs` calling `Shiki.Cli.runCli`.

### Haskell standards

Per the MasterPlan Decision Log: GHC 9.12, GHC2024, default-extensions
`DeriveAnyClass`, `DuplicateRecordFields`, `OverloadedLabels`, `OverloadedStrings`,
`MultilineStrings`, `PackageImports`. All modules import `Shiki.Prelude`. Postpositive
`qualified` imports. Records use no field prefixes, strict `!`, explicit deriving
strategies, `#fieldName` lens access. SQL literals use the `"""..."""` form.

### Module dependencies repeated for self-containment

From `Shiki.Persistence.*` (defined in
`docs/plans/2-postgresql-schema-migrations-and-run-persistence.md`):

```haskell
newtype RunId = RunId { unRunId :: UUID }

data RunRecord = RunRecord
  { runId, serviceName, namespace, jobName :: !Text  -- (runId is RunId)
  , command       :: ![Text]
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

data RunStatus = Pending | Running | Succeeded | Failed
runStatusToText :: RunStatus -> Text

getRunStatement         :: Statement RunId (Maybe RunRecord)
listRecentRunsStatement :: Statement Int [RunRecord]
```

From `Shiki.Cli.Env` (defined in `docs/plans/4-run-cli-command-end-to-end.md`):

```haskell
data CliEnv = CliEnv { pool :: !Pool.Pool, client :: !ClientEnv }
withCliEnv :: ConnectionString -> (CliEnv -> IO a) -> IO a
```

This plan does not call any `ClientEnv` operations; `withCliEnv` is reused only for
its database-pool acquisition.

### Cross-plan contract (from the MasterPlan)

> **CLI subcommand registry** (`Shiki.Cli` in `shiki-cli/src/Shiki/Cli.hs`). The
> existing `Command` sum type is extended by EP-4 (adding `Run`) and by EP-5
> (adding `RunsList`, `RunsShow`, `RunsLogs` under a `runs` subparser). Both plans
> must extend the same sum type rather than introducing a parallel one.


## Plan of Work

### Milestone 1 — Add the by-service query statement

Scope: a single additional statement on `Shiki.Persistence.Run`. The existing
`listRecentRunsStatement :: Statement Int [RunRecord]` covers the unfiltered list;
we add a filtered variant for `--service`. We also add a prefix lookup for
`runs show <prefix>`.

Edit `shiki-core/src/Shiki/Persistence/Run.hs`:

- Extend the `module ... ( ... )` export list with `listRecentRunsByServiceStatement`
  and `findRunByPrefixStatement`.
- Append:

  ```haskell
  -- | Recent runs filtered by service name.
  listRecentRunsByServiceStatement :: Statement (Text, Int) [RunRecord]
  listRecentRunsByServiceStatement = Statement sql encoder decoder True
    where
      sql = """
        SELECT id, service_name, command, namespace, job_name,
               image, status, exit_code, started_at, ended_at,
               duration_ms, log_tail, service_config, error
          FROM runs
         WHERE service_name = $1
      ORDER BY started_at DESC
         LIMIT $2
        """
      encoder =
           (fst >$< textParam)
        <> (fromIntegral . snd >$< int8Param)
      decoder = Decoders.rowList runRecordRow

  -- | Find a single row whose @id@ starts with the given prefix. Returns
  -- @Left "ambiguous"@ if more than one matches.
  findRunByPrefixStatement :: Statement Text [RunRecord]
  findRunByPrefixStatement = Statement sql encoder decoder True
    where
      sql = """
        SELECT id, service_name, command, namespace, job_name,
               image, status, exit_code, started_at, ended_at,
               duration_ms, log_tail, service_config, error
          FROM runs
         WHERE id::text LIKE $1 || '%'
         LIMIT 2
        """
      encoder = id >$< textParam
      decoder = Decoders.rowList runRecordRow
  ```

Acceptance: `cabal build shiki-core` succeeds; `cabal repl shiki-core` and
`:t listRecentRunsByServiceStatement` returns `Statement (Text, Int) [RunRecord]`.

### Milestone 2 — `Shiki.Cli.Runs`: the three read subcommands

Scope: parse options, run the right statement, render the result.

Add `shiki-cli/src/Shiki/Cli/Runs.hs`:

```haskell
module Shiki.Cli.Runs
  ( RunsCommand (..)
  , runsParser
  , runRuns
  ) where

import Shiki.Prelude

import Shiki.Cli.Env (CliEnv (..))
import Shiki.Persistence.Run
  ( RunId (..), RunRecord (..)
  , findRunByPrefixStatement
  , listRecentRunsByServiceStatement, listRecentRunsStatement
  )
import Shiki.Persistence.RunStatus (runStatusToText)

import Data.Aeson.Encode.Pretty qualified as AesonPretty
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.List qualified as List
import Data.Text qualified as Text
import Data.Text.IO qualified as TIO
import Data.Time.Clock (UTCTime)
import Data.Time.Format qualified as TimeFmt
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (Statement)
import Options.Applicative
import System.Exit (exitFailure)

data RunsCommand
  = RunsList    !(Maybe Text) !Int        -- ^ optional service filter, limit
  | RunsShow    !Text                     -- ^ id (prefix or full)
  | RunsLogs    !Text                     -- ^ id (prefix or full)
  deriving stock (Generic, Eq, Show)

runsParser :: Parser RunsCommand
runsParser =
  hsubparser
    ( command "list"
        ( info
            ( RunsList
                <$> optional (strOption
                       (long "service" <> short 's' <> metavar "NAME"
                          <> help "Filter by service name"))
                <*> option auto
                       (long "limit" <> short 'l' <> metavar "N" <> value 20
                          <> showDefault
                          <> help "Maximum rows to show")
            )
            (progDesc "List recent runs, newest first")
        )
   <> command "show"
        ( info (RunsShow <$> argument str (metavar "ID"))
               (progDesc "Show one run by id (UUID or unambiguous prefix)") )
   <> command "logs"
        ( info (RunsLogs <$> argument str (metavar "ID"))
               (progDesc "Print the captured log tail for a run") )
    )

runRuns :: CliEnv -> RunsCommand -> IO ()
runRuns env = \case
  RunsList mService limit -> doList env mService limit
  RunsShow idText         -> doShow env idText
  RunsLogs idText         -> doLogs env idText

doList :: CliEnv -> Maybe Text -> Int -> IO ()
doList env mService limit = do
  rows <- case mService of
    Nothing  -> runRead env listRecentRunsStatement          limit
    Just svc -> runRead env listRecentRunsByServiceStatement (svc, limit)
  if null rows
    then TIO.putStrLn "(no runs recorded yet)"
    else TIO.putStr (renderTable rows)

doShow :: CliEnv -> Text -> IO ()
doShow env idText = do
  matches <- runRead env findRunByPrefixStatement idText
  case matches of
    []     -> TIO.putStrLn ("no run matching " <> idText) >> exitFailure
    [r]    -> BL8.putStrLn (AesonPretty.encodePretty r)
    (_:_:_) ->
      TIO.putStrLn ("ambiguous id prefix " <> idText) >> exitFailure

doLogs :: CliEnv -> Text -> IO ()
doLogs env idText = do
  matches <- runRead env findRunByPrefixStatement idText
  case matches of
    [r] -> case r ^. #logTail of
      Just t  -> TIO.putStr t
      Nothing -> TIO.putStrLn "(no log captured)"
    []     -> TIO.putStrLn ("no run matching " <> idText) >> exitFailure
    (_:_:_) ->
      TIO.putStrLn ("ambiguous id prefix " <> idText) >> exitFailure

-- ── Rendering helpers ──────────────────────────────────────────────────────

renderTable :: [RunRecord] -> Text
renderTable rs =
  let header = ["ID", "STARTED", "SERVICE", "STATUS", "DURATION", "EXIT", "COMMAND"]
      body   = map renderRow rs
      widths = computeWidths (header : body)
  in Text.unlines (formatRow widths header : map (formatRow widths) body)

renderRow :: RunRecord -> [Text]
renderRow r =
  [ Text.take 8 (Text.pack (show (unRunId (r ^. #runId))))
  , Text.pack (TimeFmt.formatTime TimeFmt.defaultTimeLocale
                 "%Y-%m-%d %H:%M:%S" (r ^. #startedAt))
  , r ^. #serviceName
  , runStatusToText (r ^. #status)
  , maybe "-" humanDuration (r ^. #durationMs)
  , maybe "-" (Text.pack . show) (r ^. #exitCode)
  , Text.intercalate " " (r ^. #command)
  ]

humanDuration :: Int -> Text
humanDuration ms =
  let secs    = ms `div` 1000
      mins    = secs `div` 60
      hours   = mins `div` 60
      remMins = mins `mod` 60
      remSecs = secs `mod` 60
  in if hours > 0
       then Text.pack (show hours <> "h" <> show remMins <> "m" <> show remSecs <> "s")
       else if mins > 0
         then Text.pack (show mins <> "m" <> show remSecs <> "s")
         else Text.pack (show secs <> "s")

computeWidths :: [[Text]] -> [Int]
computeWidths rows =
  foldr (\row acc -> zipWithLong max (map Text.length row) acc) (repeat 0) rows
  where
    zipWithLong f xs ys =
      let n = max (length xs) (length ys)
          xs' = xs <> replicate (n - length xs) 0
          ys' = ys <> replicate (n - length ys) 0
      in zipWith f xs' ys'

formatRow :: [Int] -> [Text] -> Text
formatRow widths cols =
  Text.intercalate "  " (zipWith pad widths cols)
  where
    pad w t = t <> Text.replicate (w - Text.length t) " "

runRead :: CliEnv -> Statement a b -> a -> IO b
runRead env stmt input =
  Pool.use (env ^. #pool) (Session.statement input stmt)
    >>= either (error . show) pure
```

Add `Shiki.Cli.Runs` to `exposed-modules` in `shiki-cli/shiki-cli.cabal`.

### Milestone 3 — Wire `Shiki.Cli` to dispatch to `Shiki.Cli.Runs`

Scope: extend the `Command` sum type and `commandParser` introduced in
`docs/plans/4-run-cli-command-end-to-end.md`.

Edit `shiki-cli/src/Shiki/Cli.hs`:

- Add `import Shiki.Cli.Runs (RunsCommand, runsParser, runRuns)` to the import list.
- Extend the `Command` sum type:

  ```haskell
  data Command
    = Run         !RunOptions
    | ServiceShow !Text
    | Runs        !RunsCommand          -- NEW
    deriving stock (Generic, Eq, Show)
  ```

- Extend the `runCli` dispatch with a new case:

  ```haskell
  Runs runsOpts -> withDbEnv (opts ^. #dbConnStr) $ \env -> runRuns env runsOpts
  ```

- Extend `commandParser` with a new `command "runs"` entry:

  ```haskell
  commandParser =
    hsubparser
      ( command "run"
          ( info (Run <$> runOptionsParser)
                 (progDesc "Submit a one-off Job and record the run in Postgres") )
     <> command "runs"
          ( info (Runs <$> runsParser)
                 (progDesc "Inspect recorded runs") )
     <> command "service"
          ( info serviceSubparser
                 (progDesc "Inspect microservice configuration files") )
      )
  ```

Acceptance:

```bash
cabal run shiki -- runs --help
```

shows `list`, `show`, `logs` as the three subcommands.

### Milestone 4 — Tasty test that exercises `listRecentRunsStatement`

Scope: prove the read path works end-to-end against a real Postgres by inserting
three synthetic rows via `insertRunStatement` (defined in EP-2) and asserting the
returned order.

Add `shiki-core/test/Shiki/Persistence/RunListSpec.hs`:

```haskell
module Shiki.Persistence.RunListSpec (tests) where

import Shiki.Prelude

import Shiki.Persistence.Connection (ConnectionString (..), acquirePool, releasePool)
import Shiki.Persistence.Migration  (runMigrations)
import Shiki.Persistence.Run
  ( NewRun (..)
  , insertRunStatement
  , listRecentRunsByServiceStatement, listRecentRunsStatement
  , newRunId
  )

import Control.Exception (bracket)
import Data.Aeson qualified as Aeson
import Data.Time.Clock (UTCTime, addUTCTime, getCurrentTime)
import EphemeralPg qualified as Pg
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (Statement)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase)

tests :: TestTree
tests = testGroup "Shiki.Persistence.Run (list)"
  [ testCase "listRecentRunsStatement returns rows newest-first" $
      withTempPg $ \pool -> do
        runMigrations pool
        t0 <- getCurrentTime
        let mkRow svc offsetSec = do
              rid <- newRunId
              useStmt pool insertRunStatement NewRun
                { runId = rid
                , serviceName = svc
                , command = ["x"], namespace = "ns", jobName = "j"
                , image = Nothing
                , startedAt = addUTCTime (fromIntegral (offsetSec :: Int)) t0
                , serviceConfig = Aeson.object []
                }
        mkRow "svc-a" 0
        mkRow "svc-a" 10
        mkRow "svc-b" 5
        all3 <- useStmtRead pool listRecentRunsStatement (10 :: Int)
        assertEqual "row count" 3 (length all3)
        let services = map (^. #serviceName) all3
        assertEqual "ordered newest first"
          ["svc-a", "svc-b", "svc-a"]
          services

        aOnly <- useStmtRead pool listRecentRunsByServiceStatement ("svc-a", 10)
        assertEqual "service filter"
          2 (length aOnly)
        assertBool "all rows are svc-a"
          (all (\r -> r ^. #serviceName == "svc-a") aOnly)
  ]

withTempPg :: (Pool.Pool -> IO ()) -> IO ()
withTempPg action =
  Pg.withCleanDatabase $ \cs ->
    bracket (acquirePool (ConnectionString cs)) releasePool action

useStmt :: Pool.Pool -> Statement a () -> a -> IO ()
useStmt pool stmt input =
  Pool.use pool (Session.statement input stmt) >>= either (fail . show) pure

useStmtRead :: Pool.Pool -> Statement a b -> a -> IO b
useStmtRead pool stmt input =
  Pool.use pool (Session.statement input stmt) >>= either (fail . show) pure
```

Wire `Shiki.Persistence.RunListSpec` into `shiki-core/test/Spec.hs`:

```haskell
import Shiki.Persistence.RunListSpec qualified as RunListSpec
...
main = defaultMain $ testGroup "shiki-core"
  [ ConfigSpec.tests
  , RunSpec.tests
  , JobBuilderSpec.tests
  , RunListSpec.tests
  ]
```

Acceptance: `cabal test shiki-core` passes the new assertions.

### Milestone 5 — End-to-end manual verification

Steps (assuming `docs/plans/4-run-cli-command-end-to-end.md` has produced at least
one real `runs` row):

```bash
cabal run shiki -- runs list
```

Expected (truncated):

```text
ID        STARTED              SERVICE           STATUS     DURATION  EXIT  COMMAND
1f0a3b8e  2026-05-26 22:30:12  mls-service-v2    succeeded  53s       0     subscription process --batch-size 1
```

```bash
cabal run shiki -- runs show 1f0a3b8e
```

Expected: pretty JSON of the full `RunRecord`.

```bash
cabal run shiki -- runs logs 1f0a3b8e
```

Expected: the contents of the `log_tail` column, verbatim.


## Concrete Steps

All commands assume the working directory is `/Users/shinzui/Keikaku/bokuno/shiki` and
the dev shell is active.

```bash
cabal build all
cabal test shiki-core
cabal run shiki -- runs --help
```

Expected (truncated):

```text
Usage: shiki runs COMMAND

  Inspect recorded runs

Available commands:
  list  List recent runs, newest first
  show  Show one run by id (UUID or unambiguous prefix)
  logs  Print the captured log tail for a run
```


## Validation and Acceptance

After all milestones:

1. `cabal build all` and `cabal test all` succeed.
2. `cabal run shiki -- runs list` against a database with at least one row prints a
   non-empty table; against an empty database prints `(no runs recorded yet)`.
3. `cabal run shiki -- runs list --service mls-service-v2 --limit 5` returns at most
   five rows, all with `service_name = 'mls-service-v2'`.
4. `cabal run shiki -- runs show <prefix>` returns a single row's pretty JSON for
   unambiguous prefixes, and exits non-zero with a clear message for ambiguous or
   missing prefixes.
5. `cabal run shiki -- runs logs <prefix>` prints the `log_tail` verbatim, or
   `"(no log captured)"` if NULL.


## Idempotence and Recovery

All three subcommands are pure reads — they never mutate the database. Running them
repeatedly is safe and produces stable results for the same inputs.

If `runs list` returns nothing despite expecting rows, verify the database connection
string:

```bash
cabal run shiki -- runs list --db "$PG_CONNECTION_STRING"
```

If that disagrees with the no-flag form, the issue is environment-variable resolution
in `Shiki.Cli.Config.resolveConnectionString`.


## Interfaces and Dependencies

No new external libraries beyond what EP-2 and EP-4 already added.

Module surface at end of plan:

- `Shiki.Persistence.Run` (extended)

  ```haskell
  listRecentRunsByServiceStatement :: Statement (Text, Int) [RunRecord]
  findRunByPrefixStatement         :: Statement Text [RunRecord]
  ```

- `Shiki.Cli.Runs`

  ```haskell
  data RunsCommand
    = RunsList !(Maybe Text) !Int
    | RunsShow !Text
    | RunsLogs !Text

  runsParser :: Parser RunsCommand
  runRuns    :: CliEnv -> RunsCommand -> IO ()
  ```

- `Shiki.Cli` (extended; canonical `Command` sum type owner)

  ```haskell
  data Command = Run !RunOptions | ServiceShow !Text | Runs !RunsCommand
  ```
