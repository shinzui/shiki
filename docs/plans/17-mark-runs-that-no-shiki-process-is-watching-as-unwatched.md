---
id: 17
slug: mark-runs-that-no-shiki-process-is-watching-as-unwatched
title: "Mark runs that no shiki process is watching as unwatched"
kind: exec-plan
created_at: 2026-09-15T12:31:49Z
intention: "intention_01m2jgrymheserjfvaq2km4d4j"
provenance:
  created_by:
    model: "claude-opus-5[1m]"
    harness: "claude-code"
    at: 2026-09-15T12:31:49Z
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-15T13:25:44Z
      mode: "update"
      note: "Validated against the tree and made clock threading, tests, ADRs, and recovery implementable"
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-15T14:49:52Z
      mode: "implement"
      note: "Implemented watcher heartbeat storage and began the remaining milestones"
---

# Mark runs that no shiki process is watching as unwatched

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

shiki records every one-off Kubernetes Job it submits as a row in a PostgreSQL table
called `runs`. A row's `status` column says `running` from the moment the Job is
submitted until some shiki process writes the final outcome. Today that `running` value
means two very different things, and nothing in the output tells them apart.

In the first case a `shiki run` process is still alive, polling the Job, and will write the
outcome the moment the Job ends. In the second case no process is following the Job at all:
the operator submitted it with `--no-wait`, or the waiting process died (its terminal was
closed, the laptop slept, or an agent harness killed it for memory). Such a row stays
`running` until someone runs `shiki runs sync`, even after the Job has long since succeeded
or failed. On 2026-09-14 and 2026-09-15 this confused both an operator and an agent during
multi-hour property imports in the `mls-service-v2` production namespace of
`mori://tan/mls-service-v2`: rows read
`running` for hours after the waiting process was gone, and in one case after the Job had
already finished.

After this plan, a waiting `shiki run` proves it is alive by writing a timestamp (a
"heartbeat") to its row about once a minute. `shiki runs list`, the `fzf` run picker, and
`shiki agent assist` show a pending or running row whose heartbeat is missing or more than
five minutes old as `unwatched` instead of `running`, and `shiki runs show` tells the reader
on stderr that no watcher has reported itself recently and the row may need
`shiki runs sync <id>` to update. The stored `status` value does not change, so
`shiki runs sync` and every existing query keep working.

To see it working: submit one run with `--no-wait` and one without, then run
`shiki runs list`. The `--no-wait` row shows `unwatched` immediately; the waited row shows
`running` while its `shiki run` is alive, and `unwatched` about five minutes after that
process is killed with `kill -9`.


## Progress

Milestone 1 — Store a watch heartbeat

- [x] (2026-09-15T14:49:52Z) Add `shiki-core/sql/migrations/003-add-last-watched-at.sql`.
- [x] (2026-09-15T14:49:52Z) Add `lastWatchedAt :: !(Maybe UTCTime)` to `RunRecord`; select the column in every run query through one shared column list.
- [x] (2026-09-15T14:49:52Z) Add `touchRunWatchedStatement` and `databaseNowStatement` to `Shiki.Persistence.Run`.
- [x] (2026-09-15T14:49:52Z) Update `shiki-cli/test/Shiki/Cli/Fixtures.hs` and the direct `RunRecord` fixture in `Agent/PromptSpec.hs` for the new field.
- [x] (2026-09-15T14:49:52Z) Add migration, touch, direct `updated_at`, and restricted-role tests; `cabal build all --enable-tests` and `cabal test all` pass with 51 core tests and 99 CLI tests; commit.

Milestone 2 — Heartbeat from the waiting process

- [x] (2026-09-15T14:53:10Z) Add `shiki-cli/src/Shiki/Cli/Heartbeat.hs` with `withHeartbeat`.
- [x] (2026-09-15T14:53:10Z) Wrap the wait in `waitPath` (`shiki-cli/src/Shiki/Cli/Run.hs`) with a 60-second heartbeat; leave `noWaitPath` untouched.
- [x] (2026-09-15T14:53:10Z) Add deterministic, synchronization-based tests in `shiki-cli/test/Shiki/Cli/HeartbeatSpec.hs`; `nix fmt`, `cabal build all --enable-tests`, and `cabal test all` pass with 51 core tests and 102 CLI tests; commit.

Milestone 3 — Show unwatched runs

- [x] (2026-09-15T14:57:56Z) Add `watchStaleAfter`, `isUnwatched`, and `displayStatus` to `shiki-cli/src/Shiki/Cli/Runs/Format.hs`; thread one database timestamp through each status-rendering path, including picker and handler paths.
- [x] (2026-09-15T14:57:56Z) Use the displayed status in `shiki runs list`, the run picker, `shiki agent assist`, and a pure, tested formatter for `shiki runs sync`'s "still running" message.
- [x] (2026-09-15T14:57:56Z) Print the stderr hint from `shiki runs show` (and after `shiki runs list` when any row is unwatched).
- [x] (2026-09-15T14:57:56Z) Extend `FormatSpec`, the fzf `Selector.RunSpec`, `ContextSpec`, `PromptSpec`, and `SyncSpec`; `nix fmt`, `cabal build all --enable-tests`, and `cabal test all` pass with 51 core tests and 107 CLI tests; commit.

Milestone 4 — Documentation and end-to-end check

- [ ] Update `shiki help runs`, `shiki help long-runs`, `shiki help schema`, the agent prompt template, `docs/user/commands.md`, `docs/user/schema.md`, and `CHANGELOG.md`.
- [ ] Update the `docs/user` page provenance and `docs/user/log.md`; strict user-documentation profile validation passes.
- [ ] Add the next numbered local ADR, currently `docs/adr/3-model-run-watcher-liveness-as-a-display-only-heartbeat.md`, after rechecking that `3` is still free.
- [ ] Run the end-to-end scenario in Validation and Acceptance against a real cluster and record the transcript in Surprises & Discoveries.
- [ ] Fill in Outcomes & Retrospective; commit.


## Surprises & Discoveries

- Observation: The repository now has two local ADRs even though the first draft said there
  was no `docs/adr/` directory. [ADR 1](../adr/1-follow-haskell-jitsurei-conventions.md)
  governs the Haskell module and record style used by this work, while
  [ADR 2](../adr/2-resolve-omitted-positionals-with-typed-early-resolvers.md) requires the run
  picker to preserve typed early resolution and stderr-only lookup failures.
  Evidence: `rg --files docs/adr -g '*.md'` lists both records.

- Observation: `RunRecord` does not contain `updated_at`, so the heartbeat test cannot prove
  that column stayed unchanged by comparing records returned by `getRunStatement`.
  Evidence: `shiki-core/src/Shiki/Persistence/Run.hs` decodes sixteen fields ending at
  `error_summary_source`; the test therefore needs a small test-local statement that selects
  `updated_at` directly.

- Observation: an omitted run id can display status twice in one invocation: first in the
  fzf picker and then in the selected command's output or hint. Reading database time inside
  both call sites would contradict the plan's single-snapshot rule and could disagree at the
  five-minute boundary. The timestamp must be acquired by `withRun` and passed to both
  `lookupRun` and the handler.

- Observation: `gatherAgentContext` deliberately turns a database failure into an empty run
  list plus a diagnostic path. The timestamp query must share that best-effort path; making it
  a separate uncaught query would regress `shiki agent assist`.

- Observation: The pre-change baseline builds and tests successfully: `shiki-core-test`
  reports 48 passing tests and `shiki-cli-test` reports 99. The rebuild also emits existing
  Cabal `relative-path-outside` warnings and one redundant-import warning in
  `shiki-core/test/Shiki/K8s/ClassifyJobSpec.hs`; they are outside this plan, but the
  implementation must not add new warnings.

- Observation: `docs/user` is a profile-governed OKF bundle even though `docs/adr` is not.
  The pre-change command `okf validate docs/user --strict --profile
  mori/user-documentation-profile.dhall --profile-enforce --log-enforce` reports
  `OK: 9 concepts (okf_version 0.2)`. Changes to `DOC-3` and `DOC-8` must preserve those
  handles, truthfully update their `generated` provenance, and add matching bundle-log entries.

- Observation: `shiki-cli/test/Shiki/Cli/Agent/PromptSpec.hs` constructs a `RunRecord`
  directly in addition to the shared `fixtureRow`, so adding a strict record field requires
  updating both fixtures.
  Evidence: the first `cabal build all --enable-tests` failed with GHC-95909 naming the
  missing `lastWatchedAt` field in `PromptSpec.sampleRun`; the corrected build and full test
  suite then passed.


## Decision Log

- Decision: Record liveness as a nullable `last_watched_at timestamptz` heartbeat instead of
  a `--no-wait` flag or a new status value.
  Rationale: A `--no-wait` marker only explains detached runs. The case that actually misled
  people was an orphaned run, where a waiting process existed and then died; its row looks
  exactly like a healthy waited run. A heartbeat covers detached runs (never written),
  orphaned runs (stops being written), and healthy runs (kept fresh) with one mechanism. A new
  status such as `submitted` would need the `CHECK` constraint changed and every
  `IN ('pending', 'running')` query updated, and still would not catch orphaned runs.
  Date: 2026-09-15

- Decision: "Unwatched" is computed when a row is displayed and is never stored.
  Rationale: Liveness is a function of the current time, so a stored value would itself go
  stale. Keeping `status` untouched means `shiki runs sync`, `listUnfinishedRunsStatement`, and
  `completeUnfinishedRunStatement` need no changes.
  Date: 2026-09-15

- Decision: Define `unwatched` operationally as "no recent watcher heartbeat," not as proof
  that no operating-system process exists.
  Rationale: A paused machine or repeated heartbeat-write failure can leave a live watcher
  polling Kubernetes without a fresh database timestamp. Operator messages must say the row
  may not update and recommend sync, rather than promise that it cannot update by itself.
  Date: 2026-09-15

- Decision: Heartbeat every 60 seconds; treat a heartbeat older than 300 seconds as stale.
  Rationale: The wait loop already polls Kubernetes every 5 seconds, but a database write
  every 5 seconds for a multi-day run is wasteful (about 17,000 writes a day). One write a
  minute is cheap. Five missed beats tolerate a database or network blip without flapping a
  healthy run to `unwatched`, and five minutes is still short compared with the hours-long
  runs where the confusion arose.
  Date: 2026-09-15

- Decision: Both writing and comparing use the database clock: the heartbeat writes
  `now()` in SQL, and displays read the current time with `SELECT now()`.
  Rationale: The process writing heartbeats and the process displaying runs are often on
  different machines (an operator's laptop and an agent session, for example). Using the
  database's clock for both removes clock skew from the comparison. Each CLI invocation that
  can render watcher state reads one observation timestamp and threads that immutable value
  through every formatter it invokes, so a picker and its selected handler cannot disagree at
  the boundary.
  Date: 2026-09-15

- Decision: `AgentContext.observedAt` is `Maybe UTCTime`; `Just` comes from the same successful
  database session that loads recent runs, and a database failure produces `Nothing`, no runs,
  and the existing diagnostic entry.
  Rationale: This preserves agent context's best-effort contract without substituting the
  operator machine's clock for the database clock. The `Nothing` branch is inert because the
  same failure also yields an empty recent-run list.
  Date: 2026-09-15

- Decision: Extract the `runs sync` active-Job text into a pure function that accepts the
  observation timestamp and row.
  Rationale: `SyncSpec` cannot exercise the current `syncOne` path without Kubernetes. A pure
  formatter makes the new watched/unwatched wording deterministic and leaves reconciliation
  policy in `decideSync` unchanged.
  Date: 2026-09-15

- Decision: Use synchronization primitives rather than timing-count assertions in heartbeat
  tests, and never repair an applied migration by editing its ledger in a shared schema.
  Rationale: scheduler-dependent counts are flaky on busy CI hosts. Migration-ledger surgery
  can hide schema drift; a follow-up migration is the safe recovery once a script has run.
  Date: 2026-09-15

- Decision: The heartbeat does not touch `updated_at`, and only updates rows that are still
  `pending` or `running`.
  Rationale: `updated_at` documents the last meaningful change to a row; bumping it every
  minute would make it useless. Restricting the update to unfinished rows means a heartbeat
  racing with finalization can never modify a finished row.
  Date: 2026-09-15

- Decision: A heartbeat write that fails is reported once on stderr and otherwise ignored;
  it never fails the run.
  Rationale: The Job keeps running whether or not the database accepts a heartbeat. Failing
  or aborting the wait because a liveness write failed would recreate the very problem this
  plan addresses (a healthy Job with no process following it).
  Date: 2026-09-15

- Decision: The "unwatched" hints from `shiki runs show` and `shiki runs list` go to stderr.
  Rationale: `shiki runs show <id> | jq` must keep receiving pure JSON, and scripts parsing the
  list table should not see extra lines. This matches how shiki already prints lookup errors
  on stderr.
  Date: 2026-09-15


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

### What shiki is and where the relevant code lives

shiki is a Haskell command-line tool in this repository that submits one-off Kubernetes Jobs
modeled on a service's live worker Deployment, and records each submission in PostgreSQL.
The repository has two Cabal packages. `shiki-core/` is the library: Kubernetes client code
under `shiki-core/src/Shiki/K8s/`, persistence under `shiki-core/src/Shiki/Persistence/`,
and SQL migrations under `shiki-core/sql/migrations/`. `shiki-cli/` is the `shiki`
executable: command handlers under `shiki-cli/src/Shiki/Cli/`, embedded help topics under
`shiki-cli/data/help/`, and the agent prompt template in
`shiki-cli/data/prompts/assist.md`. Tests live in `shiki-core/test/` and `shiki-cli/test/`,
use `tasty` with `tasty-hunit`, and are registered by module name in each package's
`test/Spec.hs` and its `.cabal` file's `other-modules` list. New library modules must be
added to the `exposed-modules` list of the owning `.cabal` file.

Code style: Fourmolu formatting (run `nix fmt` from the repository root), `GHC2024`, records
with strict unprefixed fields accessed through generic-lens
(`mori://ekmett/lens/packages/generic-lens`) labels (`r ^. #status`, which needs
`import Data.Generics.Labels ()` in each module that uses it), explicit deriving
strategies, and `MultilineStrings` (`"""`) for SQL.

### Terms used in this plan

A "run" is one row in the `runs` table, created by `shiki run`. The "waiting process" is the
`shiki run` process that, unless `--no-wait` is given, stays alive polling the Kubernetes Job
every 5 seconds and writes the outcome when the Job ends. A "detached" run was submitted with
`--no-wait`, so it never had a waiting process. An "orphaned" run had a waiting process that
died before the Job ended. A "heartbeat" is a periodic write of the current time into the
run's `last_watched_at` column by the waiting process, proving it is still alive. A heartbeat
is "stale" when it is more than 300 seconds older than the database's current time. A run is
"unwatched" when its stored status is `pending` or `running` and its heartbeat is missing or
stale. This means the database has no recent proof of a watcher; it cannot prove that an
operating-system process does not exist. "Unfinished" means stored status `pending` or
`running`.

### The runs table and how rows are written

`shiki-core/sql/migrations/001-create-runs.sql` creates `runs` with, among others, `id uuid`,
`status text` constrained to `pending`, `running`, `succeeded`, or `failed`, `started_at`,
`ended_at`, `created_at`, and `updated_at`. `002-add-error-summary.sql` adds `error_summary`
and `error_summary_source`. Migrations run automatically on every shiki invocation through
`runMigrations` in `shiki-core/src/Shiki/Persistence/Migration.hs`, which uses
`mori://shinzui/hasql-migration/packages/hasql-migration`: each script in
`shiki-core/sql/migrations/` is applied once, recorded in a
`schema_migrations` table with its filename and MD5 checksum, and never edited afterwards
(editing an applied script makes every later invocation fail its checksum check). The next
script is therefore `003-...sql`, applied in filename order.

An important operational constraint is documented on `runMigrations`: a restricted database
role with only `SELECT, INSERT, UPDATE` on `runs` can use an already-migrated schema, but it
cannot apply a new migration script, because `ALTER TABLE` needs the table owner. After this
plan ships, each environment's schema must be migrated once by the owning role before
restricted roles can run the new binary. `shiki-core/test/Shiki/Persistence/RestrictedRoleSpec.hs`
tests the restricted-role grants.

`shiki-core/src/Shiki/Persistence/Run.hs` defines `RunRecord` (one row, with
`deriving anyclass (FromJSON, ToJSON)`, so `shiki runs show` prints it as JSON with camelCase
keys), `NewRun`, `RunCompletion`, and every hasql `Statement`. `runRecordRow` decodes columns
positionally, in exactly the order they are listed in each `SELECT`. Five statements select a
full row today, each repeating the column list: `getRunStatement`, `listRecentRunsStatement`,
`listRecentRunsByServiceStatement`, `findRunByPrefixStatement`, and
`listUnfinishedRunsStatement`. Adding a column means changing all five and `runRecordRow`
together; missing one produces a runtime decoding error, not a compile error.

`shiki-cli/src/Shiki/Cli/Run.hs` implements `shiki run`. `runRun` inserts the row
(`insertRunStatement`, status `pending`), marks it `running` (`markRunRunningStatement`), and
then calls `noWaitPath` for `--no-wait` (submit and exit) or `waitPath`, which calls
`runJob (env ^. #client) cfg snap inputs 5 345600` from `shiki-core/src/Shiki/K8s/Runner.hs`
(submit, poll every 5 seconds for up to 96 hours, collect logs) and then `finalizeOutcome` or
`finalizeFailed`. The database pool (`env ^. #pool`, built in
`shiki-core/src/Shiki/Persistence/Connection.hs`) holds up to 5 connections, so a heartbeat
thread can use it concurrently with the waiting code.

### How runs are displayed today

`shiki-cli/src/Shiki/Cli/Runs/Format.hs` renders runs. `runColumns :: RunRecord -> [Text]`
produces the seven cells `ID`, `STARTED`, `SERVICE`, `STATUS`, `DURATION`, `EXIT`, `COMMAND`,
with the status cell from `runStatusToText (r ^. #status)`; `renderTable :: [RunRecord] -> Text`
aligns them under `runTableHeader`. `runColumns` is also used by
`shiki-cli/src/Shiki/Cli/Fzf/Selector/Run.hs` (`formatRunCandidates`, the picker shown when
`shiki runs show` and friends are given no id; its `lookupRun` loads the rows).
`shiki-cli/src/Shiki/Cli/Runs.hs` implements `shiki runs list` (`doList`) and
`shiki runs show` (`doShow`, which pretty-prints the `RunRecord` JSON).
`shiki-cli/src/Shiki/Cli/Agent/Prompt.hs` (`formatRuns`) renders recent runs, with their
status, into the `shiki agent assist` system prompt, using the `AgentContext` gathered by
`gatherAgentContext` in `shiki-cli/src/Shiki/Cli/Agent/Context.hs`.
`shiki-cli/src/Shiki/Cli/Runs/Sync.hs` implements `shiki runs sync`; for a Job that is still
active it prints `run <id8>: still running (job <name>)`.

Existing tests to extend: `shiki-cli/test/Shiki/Cli/Runs/FormatSpec.hs` (table rendering),
`shiki-cli/test/Shiki/Cli/Runs/SyncSpec.hs` (sync decisions, using the `fixtureRow` sample in
`shiki-cli/test/Shiki/Cli/Fixtures.hs`), `shiki-core/test/Shiki/Persistence/RunSpec.hs` and
`RunListSpec.hs` (statements against a throwaway PostgreSQL started by the `ephemeral-pg`
library (`mori://shinzui/ephemeral-pg/packages/ephemeral-pg`) through `withSchemaPool` in
`shiki-core/test/Shiki/Persistence/TestPg.hs`),
`shiki-cli/test/Shiki/Cli/Fzf/Selector/RunSpec.hs` (picker rows),
`shiki-cli/test/Shiki/Cli/Agent/ContextSpec.hs` and
`shiki-cli/test/Shiki/Cli/Agent/PromptSpec.hs` (agent context and rendered prompt), and
`shiki-core/test/Shiki/Persistence/ErrorSummaryColumnSpec.hs` (a model for asserting that a
migration's column exists in the configured schema).

### ADRs

The repository uses plain filesystem ADRs under `docs/adr/`; `mori.dhall` does not declare
that directory as a profiled OKF bundle. [ADR 1](../adr/1-follow-haskell-jitsurei-conventions.md)
requires strict unprefixed record fields, generic-lens labels with a local
`Data.Generics.Labels ()` import, explicit deriving strategies, `GHC2024`, and warning-free
builds. [ADR 2](../adr/2-resolve-omitted-positionals-with-typed-early-resolvers.md) requires
the fzf run picker to decide whether interaction is possible before acquiring the database,
to return the selected `RunRecord` without a second lookup, and to keep lookup errors on
stderr. This plan changes only picker rendering and must preserve those behaviors.

The display-only heartbeat becomes durable schema and interface policy once implemented.
After the end-to-end behavior is verified, Milestone 4 records the accepted policy in a new
local ADR using the established `Status`, `Date`, `Context`, `Decision`, and `Consequences`
shape. Immediately before writing it, rescan `docs/adr/`; use
`docs/adr/3-model-run-watcher-liveness-as-a-display-only-heartbeat.md` if `3` remains free,
otherwise use the next free positive number. No strict OKF ADR validation applies unless the
repository adopts an ADR profile before implementation reaches that milestone.

Separately, `mori.dhall` declares `docs/user` as the `user-documentation` OKF bundle governed
by `mori/user-documentation-profile.dhall`. The two pages this plan changes are
`docs/user/commands.md` (`DOC-3`) and `docs/user/schema.md` (`DOC-8`). Preserve those stable
handles and all unrelated frontmatter. Their `generated.by` values describe the producer of
the current content and `generated.at` is its UTC timestamp, so update both truthfully when
their bodies change and record corresponding entries in `docs/user/log.md`.


## Plan of Work

### Milestone 1 — Store a watch heartbeat

This milestone adds the column and the statements that write and read it, with no behavior
change visible to users yet. At the end, the `runs` table has a nullable `last_watched_at`
column, `shiki runs show` JSON includes `"lastWatchedAt": null`, and tests prove that the
touch statement sets the column on unfinished rows only and that a restricted role can run it.

Create `shiki-core/sql/migrations/003-add-last-watched-at.sql` containing a single
`ALTER TABLE runs ADD COLUMN last_watched_at timestamptz;` with a short SQL comment explaining
that the waiting `shiki run` process writes it about once a minute and that `NULL` means no
process has ever watched the run. Add no index: the column is only read alongside rows already
selected by other criteria.

In `shiki-core/src/Shiki/Persistence/Run.hs`, add `lastWatchedAt :: !(Maybe UTCTime)` as the
last field of `RunRecord` and add a matching nullable `timestamptz` column decoder at the end
of `runRecordRow`. Introduce one top-level `runColumnsSql :: Text` holding the shared
`id, service_name, ..., error_summary_source, last_watched_at` list, and build all five
row-selecting statements from it (for example `"SELECT " <> runColumnsSql <> " FROM runs WHERE id = $1"`),
so a future column cannot be added to one query and forgotten in another. Add
`touchRunWatchedStatement :: Statement RunId ()` running
`UPDATE runs SET last_watched_at = now() WHERE id = $1 AND status IN ('pending', 'running')`
(deliberately not touching `updated_at`), and `databaseNowStatement :: Statement () UTCTime`
running `SELECT now()`. Decode the latter with `Decoders.singleRow` around one non-nullable
`Decoders.timestamptz` column. Export both.

Update `shiki-cli/test/Shiki/Cli/Fixtures.hs` so `fixtureRow` sets `lastWatchedAt = Nothing`.

Add `shiki-core/test/Shiki/Persistence/LastWatchedAtSpec.hs`, registered in
`shiki-core/test/Spec.hs` and `shiki-core/shiki-core.cabal`, with three cases: the migration
creates `last_watched_at` in the configured schema (copy the shape of
`ErrorSummaryColumnSpec`); `touchRunWatchedStatement` on a `running` row sets `lastWatchedAt`
to a value equal to or later than `databaseNowStatement` read just before, and leaves
`updated_at` unchanged; and on a `succeeded` row it leaves `lastWatchedAt` as `Nothing`.
Because `RunRecord` intentionally omits `updated_at`, define a test-local
`Statement RunId UTCTime` that selects that column directly, read it before and after the
touch, and assert equality. In `RestrictedRoleSpec`, make `insertOneRun` return its `RunId`,
then execute `touchRunWatchedStatement` with that id through the restricted pool to prove the
existing `UPDATE` grant suffices.

### Milestone 2 — Heartbeat from the waiting process

This milestone makes a waited run keep its heartbeat fresh. At the end, a `shiki run` without
`--no-wait` writes `last_watched_at` immediately after submission and every 60 seconds until
it finalizes the row, while `--no-wait` leaves the column `NULL`.

Create `shiki-cli/src/Shiki/Cli/Heartbeat.hs` (add it to `exposed-modules` in
`shiki-cli/shiki-cli.cabal`) exporting
`withHeartbeat :: Int -> IO () -> IO a -> IO a`. Its arguments are the interval in
microseconds, the beat action, and the body. It runs the beat once, then forks a thread with
`Control.Concurrent.forkIO` that sleeps the interval and beats again, forever, and runs the
body; `Control.Exception.bracket` kills the thread with `killThread` when the body returns or
throws, so no beat happens after `withHeartbeat` returns. Every beat is wrapped in `try`: a
synchronous exception is reported on stderr the first time only (for example
`shiki: could not record run heartbeat: <exception>; the run continues`), tracked with an
`IORef Bool`, and never propagated. Asynchronous exceptions, including the `ThreadKilled`
sent by `killThread`, must be rethrown so the thread actually stops; reuse the
`fromException @SomeAsyncException` pattern already used in `Shiki.Cli.Runs.Sync.trySync`.
Use only `base`; do not add a dependency on `async`.

In `shiki-cli/src/Shiki/Cli/Run.hs`, define `heartbeatInterval :: Int` as `60_000_000` with a
comment pointing at the Decision Log reasoning, and in `waitPath` wrap the `runJob` call:
`withHeartbeat heartbeatInterval (runSessionUnit env touchRunWatchedStatement rid) (runJob ...)`,
keeping the existing `try` around the whole expression so failures still go through
`finalizeFailed`. Because the thread is killed before `finalizeOutcome` runs, and because the
statement only touches unfinished rows, the heartbeat can never overwrite a finished row.
Note that `runSessionUnit` calls `error` on a persistence failure; that becomes an exception
caught by `withHeartbeat`'s `try`, which is the intended behavior. Do not change `noWaitPath`.

Add `shiki-cli/test/Shiki/Cli/HeartbeatSpec.hs` (registered in `shiki-cli/test/Spec.hs` and
the cabal test suite). Avoid asserting that a scheduler produces a particular count within a
short sleep. Use an `IORef Int` for the count, an `MVar` signaled by the third beat, and
`System.Timeout.timeout` as a generous test-failure bound: assert that the first beat happened
before the body began, block the body until the third beat signals it, then sample the count
after return, wait several test intervals, and assert it did not increase. In separate cases,
use a beat that increments before throwing to prove synchronous failures do not stop later
beats or fail the body, and prove an exception from the body propagates while still stopping
the thread. These tests use only `base` and do not add a dependency.

### Milestone 3 — Show unwatched runs

This milestone makes the heartbeat visible. At the end, every place that shows a run's status
shows `unwatched` for an unfinished run with a missing or stale heartbeat, and
`shiki runs show` explains what that means.

In `shiki-cli/src/Shiki/Cli/Runs/Format.hs`, add `watchStaleAfter :: NominalDiffTime`
(`300`), `isUnwatched :: UTCTime -> RunRecord -> Bool` (true when the status is `Pending` or
`Running` and `lastWatchedAt` is `Nothing` or older than `now` minus `watchStaleAfter`), and
`displayStatus :: UTCTime -> RunRecord -> Text` returning `"unwatched"` when `isUnwatched`
holds and `runStatusToText (r ^. #status)` otherwise. Change `runColumns` and `renderTable` to
take the current database time as their first argument and use `displayStatus` for the
status cell. At exactly 300 seconds old the heartbeat is still fresh; it becomes stale only
when `diffUTCTime observedAt lastWatchedAt > watchStaleAfter`. The observation value must come
from `databaseNowStatement`, read exactly once per CLI invocation that can render watcher
state.

Update the callers. In `shiki-cli/src/Shiki/Cli/Runs.hs`, `doList` reads the database time
once, renders with it, and when any row `isUnwatched`, prints to stderr after the table:
`unwatched: no shiki process has recently reported watching these runs; their status may not update until 'shiki runs sync' is run`.
`doShow` keeps printing the JSON to stdout and, when the run `isUnwatched`, prints
`shiki: run <id8> is unwatched: no shiki process has recently reported watching it, so its status may not update until 'shiki runs sync <id8>' is run`
to stderr.

Acquire that timestamp in `withRun` after the environment is opened, before `lookupRun`.
Change the handler parameter to `CliEnv -> UTCTime -> RunRecord -> IO ()`, change
`lookupRun` to accept the `UTCTime`, and change `formatRunCandidates` to accept it and pass it
to `runColumns`. This deliberately reads the time even for a positional `runs logs`, `runs
error`, or `runs analyze`: one simple query keeps the resolver interface uniform, and an
omitted id can use the same immutable timestamp in the picker and the selected handler.
Preserve ADR 2's early fzf availability decision: `runTarget` still executes before
`withEnv`, and the picker still returns the selected record without another lookup.

In `shiki-cli/src/Shiki/Cli/Agent/Context.hs`, add
`observedAt :: !(Maybe UTCTime)` to `AgentContext`. Change `loadRecentRuns` so one
`Pool.use` session runs `databaseNowStatement` and then `listRecentRunsStatement`, returning
both values together. On success, store `Just observedAt`; on any pool/session failure,
preserve the existing behavior by storing `Nothing`, an empty run list, and one `db: ...`
diagnostic. In `shiki-cli/src/Shiki/Cli/Agent/Prompt.hs`, pass the optional timestamp to
`formatRuns`; use `displayStatus` for rows when it is `Just`, and retain stored status as a
defensive fallback when it is `Nothing`.

In `shiki-cli/src/Shiki/Cli/Runs/Sync.hs`, have `syncRuns` use one database observation time
for all rows and have `syncRun` accept the timestamp supplied by `withRun`. Thread it into
`syncOne` only for display; keep `getCurrentTime` for Kubernetes reconciliation timestamps
and submit-grace decisions. Extract and export a pure
`renderStillRunning :: UTCTime -> RunRecord -> Text`: it returns
`still running (job <name>); no shiki process has recently reported watching it, so sync again later` for an
unwatched row and the existing text otherwise. `decideSync` itself does not change.

Extend `shiki-cli/test/Shiki/Cli/Runs/FormatSpec.hs` with `displayStatus` cases: a `running`
row with `Nothing` is `unwatched`; with a heartbeat 30 seconds before `now` it is `running`;
with one exactly 300 seconds before `now` it is still `running`; with one 301 seconds before
`now` it is `unwatched`; a `succeeded` row with `Nothing` is `succeeded`; and a `renderTable`
alignment case with an `unwatched` row. Update `Fzf/Selector/RunSpec.hs` for the timestamped
`formatRunCandidates`, `Agent/ContextSpec.hs` for `Just observedAt` on success,
`Agent/PromptSpec.hs` for the new context field and displayed status, and `SyncSpec.hs` for
both branches of `renderStillRunning`.

### Milestone 4 — Documentation and end-to-end check

This milestone tells operators and agents what `unwatched` means and proves the whole feature
against a real cluster.

Update `shiki-cli/data/help/runs.md`: add `last_watched_at` to the column list, explain in the
run lifecycle that a waiting `shiki run` heartbeats every minute, and add a short
"UNWATCHED RUNS" section defining the displayed status and pointing at `shiki runs sync`.
Update rule 2 of `shiki-cli/data/help/long-runs.md` so it says an `unwatched` row is
missing a recent watcher heartbeat while a displayed `running` row has one, and explicitly
note that heartbeat loss can also mean a paused watcher or repeated database-write failure;
either way the Job's real state comes from `shiki runs sync`. Add the column to
`shiki-cli/data/help/schema.md` and `docs/user/schema.md`, describe the displayed status in the
`shiki runs list` and `shiki runs show` sections of `docs/user/commands.md`, mention
`unwatched` next to the `shiki runs list` entry in `shiki-cli/data/prompts/assist.md`, and add
an `Added` entry to `CHANGELOG.md` that also states the rollout requirement (the owning role
must run shiki once per environment to apply migration 003).

For `docs/user/commands.md` and `docs/user/schema.md`, preserve `docId: DOC-3` and
`docId: DOC-8`, set each `generated.by` to the actual author actor in the profile's
`<producer>/<version>`, `human:<id>`, or `process:<id>` format, and advance `generated.at` to
the UTC time of the meaningful edit. Append concise log entries with:

```bash
okf log add docs/user DOC-3 --kind Update --message "Document displayed unwatched run status and recovery guidance"
okf log add docs/user DOC-8 --kind Update --message "Document the run watcher heartbeat column and rollout"
okf validate docs/user --strict --profile mori/user-documentation-profile.dhall --profile-enforce --log-enforce
```

Expect `OK: 9 concepts (okf_version 0.2)` unless another documentation page is added before
implementation; the concept count may grow, but validation must still succeed.

Then run the end-to-end scenario in Validation and Acceptance and paste the key transcript
lines into Surprises & Discoveries. After the behavior is proven, create the local ADR named
in Context and Orientation, capturing the nullable heartbeat, display-only `unwatched`
classification, database-clock comparison, 60-second beat, 300-second strict stale boundary,
and the choice not to mutate `updated_at` or stored `status`. Recheck the available ADR number
immediately before creating it and preserve the repository's existing filesystem format.


## Concrete Steps

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/shiki`, inside the
development shell (`nix develop`, or direnv), which provides GHC, cabal, and PostgreSQL.

Before starting, inspect the baseline and preserve any unrelated user changes:

```bash
git status --short
cabal build all
cabal test all
```

Record any pre-existing paths from `git status --short` and do not overwrite or discard them.
Both test suites should end with `All N tests passed`; do not hard-code the count because this
plan adds tests and other concurrent work may do the same.

After each milestone:

```bash
nix fmt
cabal build all --enable-tests
cabal test all
```

After Milestone 4, also run the strict `docs/user` validation command shown in that milestone.

After formatting, inspect `git diff --stat` and `git diff` and include only this plan's changes
in the milestone commit. Do not discard unrelated edits; if formatting changes a file outside
the milestone, preserve any pre-existing work and either include a justified formatter-only
change or leave it for its owner. Commit each milestone with a Conventional Commits message
and both trailers:

```text
feat(shiki-core): store a heartbeat for runs a shiki process is watching

<body>

ExecPlan: docs/plans/17-mark-runs-that-no-shiki-process-is-watching-as-unwatched.md
Intention: intention_01m2jgrymheserjfvaq2km4d4j
```

To inspect the column during development against the local database started by
`just up` (process-compose PostgreSQL; the dev shell sets `PGDATABASE`):

```bash
psql -d "$PGDATABASE" -c "SELECT substr(id::text, 1, 8), status, last_watched_at FROM runs ORDER BY started_at DESC LIMIT 5;"
```

A development build that is not installed cannot find its SQL migrations in cabal's install
directory; point it at the source tree when running the binary directly:

```bash
export shiki_core_datadir=$PWD/shiki-core
"$(cabal list-bin shiki)" runs list --limit 5
```


## Validation and Acceptance

Automated acceptance is `cabal test all` passing with the new cases described in each
milestone. In particular, the `LastWatchedAtSpec`, `HeartbeatSpec`, and new `FormatSpec`
cases must fail before their milestone's code change and pass after it. The picker,
agent-context, prompt, and sync formatter tests must also cover the new timestamp plumbing;
the existing resolver, persistence-failure, and JSON/stdout behavior must remain green.

End-to-end acceptance needs a cluster where the operator may create Jobs and a service config
for it (for example the `mls-service-v2` service in the `test` namespace from
`mori://tan/mls-service-v2`, using that project's repository-local `shiki.dhall` and
`services/` directory), plus a command known to run for several minutes. From that project's
directory, with `shiki` built from this branch:

```bash
kubectl config current-context        # must name the intended cluster
shiki run <service> --namespace <ns> --no-wait -- <long command>
shiki run <service> --namespace <ns> -- <long command> &
WAITER=$!
shiki runs list --limit 2
```

Expect the `--no-wait` row to show `unwatched` immediately and the other to show `running`,
with the stderr footer present because one row is unwatched:

```text
ID        STARTED              SERVICE         STATUS     DURATION  EXIT  COMMAND
b41c07aa  2026-09-16 10:02:11  mls-service-v2  running    -         -     <long command>
9e2f5d10  2026-09-16 10:01:58  mls-service-v2  unwatched  -         -     <long command>
unwatched: no shiki process has recently reported watching these runs; their status may not update until 'shiki runs sync' is run
```

Then simulate an orphaned run and confirm it turns `unwatched` after the stale threshold, while
the Job itself keeps running:

```bash
kill -9 "$WAITER"
# about six minutes later:
shiki runs list --limit 2          # both rows now show unwatched
shiki runs show <waited-id8> > /dev/null   # stderr explains the row is unwatched
kubectl get job -n <ns> <job-name>        # still active, or completed
shiki runs sync                           # records whatever the Jobs reported
```

Finally, confirm `shiki runs show <id> | jq .lastWatchedAt` prints a timestamp for the waited
run and `null` for the `--no-wait` run, proving the JSON on stdout stayed parseable.


## Idempotence and Recovery

Migration 003 is additive and nullable, so applying it cannot lose data, and
`mori://shinzui/hasql-migration/packages/hasql-migration` applies it only once. Never edit
`003-add-last-watched-at.sql` after it has been applied anywhere; fix mistakes with a new
`004-...sql` script instead, or every later shiki invocation against that schema fails its
checksum check. Do not remove a row from `schema_migrations` to conceal an applied script. If
a disposable local test schema needs a clean retry, verify its exact generated schema name
and dispose of that schema through the existing test harness; never perform a manual rollback
in a shared environment.

Rollout: a restricted role cannot apply migration 003. After releasing, run any shiki command
once per environment as the role that owns the `runs` table (for example
`shiki --env staging runs list` with that role's connection string) before restricted roles
use the new binary; until then, restricted roles fail at startup with a `hasql-migration`
error naming the script. Older shiki binaries keep working after the migration, because they
select explicit column lists and ignore the new column.

The heartbeat is self-healing: a failed write is retried at the next interval. Nothing can
re-attach a new waiting process to an existing row, so an orphaned row simply stays
`unwatched` until `shiki runs sync` finalizes it. Every milestone's edits can be re-run safely; the tests
use fresh throwaway schemas.


## Interfaces and Dependencies

No new libraries. The heartbeat uses `Control.Concurrent` (`forkIO`, `killThread`,
`threadDelay`), `Control.Exception` (`bracket`, `try`, `fromException`, `SomeAsyncException`),
`Data.IORef`, `MVar`, and `System.Timeout` from `base`. Statements use
`mori://hasql/hasql/packages/hasql` exactly like the existing ones in
`Shiki.Persistence.Run`; the current `preparable`, `Decoders.singleRow`, and
`Decoders.timestamptz` APIs are already used by this working tree, so no dependency-bound
change is required.

At the end of Milestone 1, `shiki-core/src/Shiki/Persistence/Run.hs` exports, in addition to
its current interface:

```haskell
data RunRecord = RunRecord
  { -- existing fields unchanged, then:
    lastWatchedAt :: !(Maybe UTCTime)
  }

touchRunWatchedStatement :: Statement RunId ()
databaseNowStatement :: Statement () UTCTime
```

At the end of Milestone 2, `shiki-cli/src/Shiki/Cli/Heartbeat.hs` exports:

```haskell
-- | Run the beat now and then every interval (microseconds) until the body
--   returns or throws. Beat failures are reported once on stderr and ignored.
withHeartbeat :: Int -> IO () -> IO a -> IO a
```

At the end of Milestone 3, `shiki-cli/src/Shiki/Cli/Runs/Format.hs` exports:

```haskell
watchStaleAfter :: NominalDiffTime
isUnwatched :: UTCTime -> RunRecord -> Bool
displayStatus :: UTCTime -> RunRecord -> Text
runColumns :: UTCTime -> RunRecord -> [Text]
renderTable :: UTCTime -> [RunRecord] -> Text
```

`shiki-cli/src/Shiki/Cli/Fzf/Selector/Run.hs` changes these internal interfaces:

```haskell
formatRunCandidates :: UTCTime -> [RunRecord] -> (Text, [Candidate RunRecord])
lookupRun :: CliEnv -> UTCTime -> RunTarget -> IO (Either RunLookupFailure RunRecord)
```

`shiki-cli/src/Shiki/Cli/Runs.hs` changes its internal handler seam to carry the same
timestamp:

```haskell
withRun ::
  ((CliEnv -> IO ()) -> IO ()) ->
  FzfOpts ->
  Maybe Text ->
  (CliEnv -> UTCTime -> RunRecord -> IO ()) ->
  IO ()
```

`Shiki.Cli.Agent.Context.AgentContext` adds
`observedAt :: !(Maybe UTCTime)`, and `Shiki.Cli.Runs.Sync` exports for testing:

```haskell
renderStillRunning :: UTCTime -> RunRecord -> Text
```


Revision note (2026-09-15): Validated the draft against the current tree and dependency
sources, then repaired stale ADR context, canonicalized cross-repository references, made the
single database-clock snapshot implementable across picker and handler paths, preserved agent
context's best-effort failure behavior, specified direct `updated_at` observation and a pure
sync formatter for testability, replaced scheduler-sensitive heartbeat tests and unsafe
migration rollback advice, clarified that a stale heartbeat is a failure-detector signal rather
than proof that no process exists, verified the 48/99-test and strict `docs/user` baselines,
and added ADR distillation to the final milestone.
