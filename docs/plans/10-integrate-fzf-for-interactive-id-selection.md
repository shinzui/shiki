---
id: 10
slug: integrate-fzf-for-interactive-id-selection
title: "Integrate fzf for interactive ID selection"
kind: exec-plan
created_at: 2026-05-28T03:18:59Z
intention: "intention_01ksp9d2g6e7hb7cvm51402pe7"
provenance:
  revisions:
    - model: "claude-opus-5[1m]"
      harness: "claude-code"
      at: 2026-09-11T19:24:00Z
      mode: "update"
      note: "Refresh completed plan against HEAD d0686f7: current field names, nix fmt restored, mori URI, Esc exit code, re-verified evidence"
---

# Integrate fzf for interactive ID selection

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

**Status (2026-09-11): reopened.** Milestones 1–5 landed on 2026-05-28 (commits `811c9db`,
`818e39b`, `cd32aa6`, `aa111b2`, `d51aecc`) and deliver the feature. An architecture review
on 2026-09-11 found a real bug (a picker query that matches nothing reports "no runs
recorded yet"), a stringly-typed seam between the picker and the command handlers, fzf
detection in the wrong place, and several smaller defects. Milestones 6–10 fix all of
them. Milestones 1–5 describe the first implementation; where they disagree with
milestones 6–10, milestones 6–10 win.


## Purpose / Big Picture

Before this plan, every `shiki runs *` subcommand that operates on a single recorded run
required the operator to first run `shiki runs list`, copy an id prefix, then re-issue the
read command:

```text
$ shiki runs list -l 5
ID        STARTED              SERVICE   STATUS     DURATION  EXIT  COMMAND
3f2c1a9d  2026-05-27 17:22:11  ingest    Succeeded  12s       0     reindex --batch 100
…
$ shiki runs show 3f2c1a9d
```

`shiki service show` was the same: the operator had to already know the service name.

Milestones 1–5 made the `ID` / `NAME` positional of `shiki runs show`, `runs logs`,
`runs error`, `runs analyze`, and `shiki service show` optional. When it is omitted, shiki
opens an `fzf` picker populated from the canonical source of truth: the `runs` table in
PostgreSQL for runs (the 50 newest rows), the `services/` directory for service configs.
`fzf` is a terminal fuzzy finder: it reads a list of lines, lets the operator type to
filter them, and prints the chosen line. When `fzf` cannot run, shiki exits with a clear
error instead. Passing the positional still skips the picker entirely.

Milestones 6–10 keep that behaviour and make it correct and honest. After them:

- Typing a query that matches nothing and pressing Enter says
  `shiki: no run matches the picker query` (today it wrongly says there are no runs).
- `shiki runs show` with no id and no usable fzf fails immediately, before shiki connects
  to the database, runs migrations, or loads the Kubernetes config. You can prove it by
  pointing `--db` at a port nothing listens on: the fzf message appears, not a connection
  error.
- The run picker's rows are aligned in the same columns as `shiki runs list`, under a
  header row of column titles, instead of ragged two-space-joined text.
- `shiki runs analyze` with no id never auto-selects a lone run and shows a header warning
  that Enter overwrites the stored error summary, because analysis writes to the database
  and may call a paid model backend. The read-only pickers still auto-select a lone
  candidate.
- Every resolution failure (no match, ambiguous prefix, empty table, fzf missing, fzf
  error) is printed on stderr from one place, so `shiki runs show abc | jq` no longer feeds
  an error message to `jq`.
- A picked run is used as-is; shiki no longer throws the fetched row away and re-queries it
  by id text.

The runs picker reads from whichever database the invocation is routed to: the active
`shiki.dhall` environment (or `--db`, `SHIKI_DATABASE_URL`, `PG_CONNECTION_STRING`, in
that order of fallback; see
`docs/plans/13-route-run-storage-to-the-active-environment-database.md`).

A reader can see the finished work by:

1. Entering the dev shell with `nix develop`, building with `cabal build all`, and running
   `cabal test shiki-cli-test` (all groups pass, including `Shiki.Cli.Fzf`,
   `Shiki.Cli.Runs.Format`, `Shiki.Cli.Fzf.Selector.Run`, and
   `Shiki.Cli.Fzf.Selector.Service`).
2. Starting PostgreSQL (`just up`), seeding two runs
   (`just shiki run <service> -- echo hello` twice), and running `just shiki runs show`: an
   fzf picker opens with a `run> ` prompt, a column-title header, and aligned rows; Enter
   prints the same JSON as `shiki runs show <prefix>`.
3. In the same picker, typing `zzzz` and pressing Enter: shiki prints
   `shiki: no run matches the picker query` on stderr and exits 1.
4. Running `just shiki runs analyze`: the picker shows the warning header and waits for a
   choice even if only one run exists.
5. Running `env PATH=/usr/bin "$(cabal list-bin shiki)" --db postgresql://127.0.0.1:1/none
   runs show </dev/null`: shiki prints `shiki: no run id given and fzf is not available`
   and exits 1, without any connection error.

The scope stays limited to read paths. `shiki run SERVICE -- ARG...` is **not** changed:
making `SERVICE` optional collides with the trailing positional `commandArgs` list (see
the Decision Log).


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

### M1 — Core `Shiki.Cli.Fzf` module + detection wired into `CliEnv` (commit `811c9db`)

- [x] Add `process` and `containers` to `shiki-cli/shiki-cli.cabal` library deps. [2026-05-28]
- [x] Create `shiki-cli/src/Shiki/Cli/Fzf.hs` with `FzfConfig`, `detectFzfConfig`,
      `isFzfAvailable`, `FzfOpts` (Monoid), smart constructors, `Candidate`, `FzfResult`,
      `runFzf`. [2026-05-28]
- [x] Add `Shiki.Cli.Fzf` to `exposed-modules`. [2026-05-28]
- [x] Extend `Shiki.Cli.Env.CliEnv` with `fzf :: !FzfConfig`; call `detectFzfConfig` inside
      `withCliEnv` so every handler sees the same snapshot. [2026-05-28]
- [x] `cabal build all` is green; no behaviour change in any subcommand yet. [2026-05-28]

### M2 — `Shiki.Cli.Fzf.Selector.Run` and `resolveRunId` (commit `818e39b`)

- [x] Create `shiki-cli/src/Shiki/Cli/Fzf/Selector/Run.hs` with `RunSelection`,
      `formatRunCandidate`, `defaultRunOpts`, `selectRun`, `resolveRunId`. [2026-05-28]
- [x] Add module to `exposed-modules`. [2026-05-28]
- [x] Unit test for `formatRunCandidate` (pure shape check) in
      `shiki-cli/test/Shiki/Cli/Fzf/Selector/RunSpec.hs`; wire into `Spec.hs`. [2026-05-28]
- [x] `cabal test all` is green. [2026-05-28]

### M3 — Wire fzf into `runs show / logs / error / analyze` (commit `cd32aa6`)

- [x] Change `RunsCommand` constructors to take `Maybe Text` instead of `Text` for the
      four read subcommands. [2026-05-28]
- [x] Update `runsParser` to use `optional (argument str …)` and tweak the help text to
      include "(uses fzf if omitted)". [2026-05-28]
- [x] In `doShow / doLogs / doError / doAnalyze`, on `Nothing`, call `resolveRunId`; on
      `Just t`, behave exactly as before. [2026-05-28] — implemented as a single
      `withResolved` wrapper that the dispatcher routes the four read paths through.
- [x] When `resolveRunId` returns `Nothing` (cancelled / fzf unavailable / no rows /
      error), print the matching message and exit 1. [2026-05-28]
- [x] Manual smoke: `shiki runs show --help` shows `[ID]` and the fzf hint;
      `cabal build all` green. [2026-05-28]

### M4 — `Shiki.Cli.Fzf.Selector.Service` and wire `service show` (commit `aa111b2`)

- [x] Create `shiki-cli/src/Shiki/Cli/Fzf/Selector/Service.hs` with `ServiceSelection`,
      `selectService`, `resolveServiceName`. [2026-05-28]
- [x] Change `ServiceShow Text` → `ServiceShow (Maybe Text)`; update
      `serviceSubparser` to use `optional`. [2026-05-28]
- [x] In `serviceShowHandler`, on `Nothing`, call `resolveServiceName`. [2026-05-28]
- [x] Manual smoke: `shiki service show --help` shows `[NAME]` and the fzf hint.
      [2026-05-28]

### M5 — Docs, tests, smoke transcript (commit `d51aecc`)

- [x] Update `docs/user/commands.md` for the four `runs` read subcommands and
      `service show` to note the optional positional and the fzf picker. [2026-05-28]
- [x] Add a `## Interactive selection (fzf)` subsection to `docs/user/commands.md`
      explaining the precedence (positional ID > fzf > error) and the env conditions
      under which fzf is invoked. [2026-05-28]
- [x] Update `CHANGELOG.md` with a smoke transcript showing `shiki runs show` opening a
      picker. [2026-05-28]
- [x] `cabal test all` is green (after the LaunchSpec race fix); `shiki --help`
      surfaces the new optional positionals. `nix flake check` and `nix fmt` were
      both unavailable in the flake at the time (see Surprises; `nix fmt` has since been
      restored). [2026-05-28]

### Post-completion refresh (2026-09-11, `HEAD` `d0686f7`, commit `705d4f6`)

- [x] Reconcile the plan's descriptions and code excerpts with the tree after later plans
      renamed fields, reformatted code, and routed storage by environment. [2026-09-11]
- [x] Re-verify: `cabal test shiki-cli-test` reports `All 62 tests passed`; `--help`
      output and the no-fzf path for `service show` behave as documented. [2026-09-11]
- [x] Confirm fourmolu-clean fzf modules and a working `nix fmt` (treefmt). [2026-09-11]
- [x] Cite the design reference by its `mori://` URI. [2026-09-11]

### Architecture review (2026-09-11)

- [x] Review the design against the code and against fzf 0.74.1 run under a
      pseudo-terminal; record findings in Surprises & Discoveries and the resulting
      decisions in the Decision Log. [2026-09-11]
- [x] Reopen the plan with milestones 6–10. [2026-09-11]

### M6 — Harden the fzf core

- [ ] Drop `stdinIsTerminal` and `stdoutIsTerminal` from `FzfConfig`; make
      `isFzfAvailable` require `available && ttyAvailable`.
- [ ] Add `selectOne :: Bool` (`withSelectOne`) and `headerRow :: Maybe Text`
      (`withHeaderRow`) to `FzfOpts`; stop hard-coding `-1` in `runFzf`; emit the header row
      as the first stdin line with `--header-lines=1`.
- [ ] Catch only `IOException` in `runFzf` instead of `SomeException`.
- [ ] Keep behaviour identical: add `withSelectOne` to the run and service picker options
      and drop the no-op `withAnsi` from the run picker options.
- [ ] Add `shiki-cli/test/Shiki/Cli/FzfSpec.hs` (fake-fzf subprocess tests and the
      `isFzfAvailable` truth table); wire it into `Spec.hs` and the cabal test stanza.
- [ ] `cabal build all` warning-free and `cabal test shiki-cli-test` green; commit.

### M7 — Share run formatting between `runs list` and the picker

- [ ] Create `shiki-cli/src/Shiki/Cli/Runs/Format.hs` by moving `renderTable`,
      `renderRow` (renamed `runColumns`), `humanDuration`, `computeWidths`, and
      `formatRow` out of `shiki-cli/src/Shiki/Cli/Runs.hs`, plus a `runTableHeader`.
- [ ] Replace `formatRunCandidate` with `formatRunCandidates`, which aligns rows with the
      shared helpers and returns the column-title row; delete the private
      `formatDuration`; pass the titles with `withHeaderRow`.
- [ ] Add `shiki-cli/test/Shiki/Cli/Runs/FormatSpec.hs`; update `RunSpec` for alignment.
- [ ] `shiki runs list` output is byte-identical to before the move; tests green; commit.

### M8 — One run resolver: target before the database, record after

- [ ] Replace `RunSelection` / `selectRun` / `resolveRunId` in
      `shiki-cli/src/Shiki/Cli/Fzf/Selector/Run.hs` with `RunTarget`, `RunLookupFailure`,
      `runTarget`, `pickerRunTarget`, `lookupRun`, `fromPrefixMatches`,
      `fromRunFzfResult`, `renderRunLookupFailure`, `readRunOpts`, `analyzeRunOpts`.
- [ ] Change `runRuns` to take an environment-acquiring continuation, resolve the target
      before acquiring it, and hand handlers a `RunRecord`; delete `withResolved`,
      `noMatch`, and `ambiguous`; print failures on stderr from one place.
- [ ] Remove the `fzf` field and probe from `Shiki.Cli.Env`; update `runCli`.
- [ ] Extend `RunSpec` with the pure mapping and rendering tests, including the
      no-match regression test.
- [ ] Build warning-free, tests green, manual checks for rows 2–13 of the acceptance
      matrix; commit.

### M9 — Same resolver shape for `service show`

- [ ] Replace `ServiceSelection` / `selectService` / `resolveServiceName` with
      `ServiceTarget`, `ServiceLookupFailure`, `serviceTarget`, `pickerServiceTarget`,
      `resolveService`, `listServiceNames`, `fromServiceFzfResult`,
      `renderServiceLookupFailure`, `serviceOpts`.
- [ ] Rewrite `serviceShowHandler` in `shiki-cli/src/Shiki/Cli.hs` on top of them.
- [ ] Add `shiki-cli/test/Shiki/Cli/Fzf/Selector/ServiceSpec.hs`.
- [ ] Build warning-free, tests green, manual checks for rows 14–19; commit.

### M10 — Docs, help topic, changelog, retrospective

- [ ] Update `docs/user/commands.md` ("Interactive selection (fzf)" and the five command
      entries).
- [ ] Mention the picker in `shiki-cli/data/help/runs.md`.
- [ ] Add `Changed` / `Fixed` entries to `CHANGELOG.md`.
- [ ] Run `nix fmt`, `cabal test all`, and the full acceptance matrix; record evidence.
- [ ] Fill in Outcomes & Retrospective and the ADR distillation note; commit.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-05-28: First M3 attempt tried to re-export `humanDuration` from
  `Shiki.Cli.Runs` for re-use by `Shiki.Cli.Fzf.Selector.Run`, but that produces a
  module cycle (`Runs` → `Selector.Run` for `resolveRunId`, `Selector.Run` → `Runs`
  for `humanDuration`). Resolution: inline a private `formatDuration` in the selector
  module. (Superseded by M7, which moves the helpers into a module both can import.)

- 2026-05-28: `cabal test shiki-cli-test` started failing intermittently after M3
  with the captured stdout of `Shiki.Cli.Agent.LaunchSpec` returning
  `"OKPROMPT"` instead of `"PROMPT"`. Root cause is pre-existing: `captureStdout`
  in `LaunchSpec` does an OS-level `hDuplicateTo stdout` redirect, which is
  fundamentally racy against any concurrent tasty test that prints — adding the
  three new `RunSelectorSpec` cases made the race fire reliably. Fix:
  `localOption (NumThreads 1)` on the top-level test tree in
  `shiki-cli/test/Spec.hs`. Verified stable across 5 consecutive runs. (Still in
  place on 2026-09-11; M6's subprocess tests rely on it too.)

- 2026-05-28: The plan's M5 step "run `nix fmt`" was not executable against the flake
  at the time — `flake.nix` did not define a `formatter` output. `cabal-fmt --inplace`
  rewrote `shiki-cli.cabal` into a divergent style, so the reformat was reverted.
  **Update 2026-09-11:** resolved. Commits `162b0f3` and `568a56f` added
  `nix/treefmt.nix`, which wires `nix fmt` to treefmt running fourmolu (configured by
  `fourmolu.yaml`), cabal-gild, and nixpkgs-fmt. `nix eval --raw
  .#formatter.aarch64-darwin.name` prints `treefmt`; `fourmolu --mode check` on the fzf
  modules exits 0.

- 2026-09-11: The design reference moved inside its repository (from
  `cli/fzf-integration.md` to `patterns/cli/fzf-integration.md`), so the absolute path the
  plan originally cited no longer existed. Its canonical identity is
  `mori://shinzui/haskell-jitsurei/docs/cli-fzf-integration`.

- 2026-09-11 (bug): A picker query that matches nothing is reported as an empty table.
  fzf exits 1 when the operator presses Enter while the query matches no row; `runFzf` maps
  exit 1 to `FzfNoMatch`; `selectRun` maps `FzfNoMatch` to `RunNoRows`; `resolveRunId`
  prints `(no runs recorded yet)`. The service picker prints
  `(no service configs found in services/)` in the same case. fzf's exit codes, measured by
  running fzf 0.74.1 under `script` (a pseudo-terminal) with `--bind` driving it:

  ```text
  bind=load:accept query=''    exit=0   picked=0|ingest
  bind=load:accept query='zzz' exit=1   picked=
  bind=load:abort  query=''    exit=130 picked=
  bind=load:abort  query='zzz' exit=130 picked=
  ```

  So Enter on a row is 0, Enter on no match is 1, and Esc (`abort`) is 130.

- 2026-09-11: fzf draws its interface on the terminal device, not on stderr, and reads keys
  from `/dev/tty` whenever its stdin is a pipe (which it always is here). Under a
  pseudo-terminal with fzf's stderr redirected to a file, the terminal received the screen
  output and the stderr file stayed empty (`stderr bytes: 0` in two runs). Consequences:
  `std_err = Inherit` matters only so fzf's own error messages reach the operator; and
  whether shiki's stdin is a terminal is irrelevant to whether fzf can run. Only "is fzf
  installed" and "can `/dev/tty` be opened" matter, so the `stdinIsTerminal` half of
  `isFzfAvailable` is dead logic and `stdoutIsTerminal` is recorded but never read.

- 2026-09-11: From an agent's non-interactive shell (the Claude Code Bash tool), `/dev/tty`
  cannot be opened (`device not configured: /dev/tty`) and stdin is not a terminal. The
  `/dev/tty` probe therefore makes `shiki runs show` fail fast with a clear message there
  instead of hanging on an invisible picker. This matters because `shiki agent assist`
  allows its agent to run `Bash(shiki *)` (`shiki-cli/src/Shiki/Cli/Agent/Launch.hs`).

- 2026-09-11: The `runs` pickers cannot report "fzf is not available" without a working
  database. `runCli` routes `Runs` through `withDbEnv`, which resolves a connection string,
  acquires the pool, runs migrations, and loads the Kubernetes client config
  (`Shiki.Cli.Env.withCliEnv`) before `runRuns` calls `resolveRunId`. M8 fixes this.

- 2026-09-11: `defaultRunOpts` passes `--ansi`, but `formatRunCandidate` emits no ANSI
  escape codes, so the flag does nothing and the plan's earlier claim that "ANSI status
  colours render" was false. The candidate's columns are joined with two spaces without
  padding, so they do not line up, although the module comment says they use "the same
  column shape as `runs list`".

- 2026-09-11: The positional path prints `no run matching <id>` and
  `ambiguous id prefix <id>` on **stdout** (`noMatch` / `ambiguous` in
  `shiki-cli/src/Shiki/Cli/Runs.hs`), and `(no runs recorded yet)` from the picker also goes
  to stdout. Piping `shiki runs show` into `jq` therefore feeds error text to `jq`.

- 2026-09-11: After a pick, `resolveRunId` discards the `RunRecord` the picker already
  fetched and returns the UUID as text; the handler re-fetches it with
  `WHERE id::text LIKE $1 || '%'`. Casting the key to text defeats the primary-key index, so
  that second query scans the table. The same "no match / one match / ambiguous" block is
  repeated in `doShow`, `doLogs`, `doError`, and `doAnalyze`.

- 2026-09-11: This checkout's `services/` holds one file (`services/mls-service-v2.dhall`).
  Because `runFzf` always passes `-1` (`--select-1`), `shiki service show` with no name
  prints it immediately. The same flag makes `shiki runs analyze` with one recorded run
  re-analyze it without the operator confirming anything; analysis overwrites
  `error_summary` and, with a `baikai:<model>` analyzer, calls a paid model.


## Decision Log

Record every decision made while working on the plan.

- Decision: Adopt the architecture from the haskell-jitsurei fzf-integration cookbook
  (`mori://shinzui/haskell-jitsurei/docs/cli-fzf-integration`) for the core
  (`Shiki.Cli.Fzf`) and the entity selector pattern (`Shiki.Cli.Fzf.Selector.*`).
  Rationale: The reference document is the user-supplied design source; the patterns it
  describes (index-based selection, monoidal options, `delegate_ctlc = True`, lazy stdout
  read + `waitForProcess`, `/dev/tty` fallback) all directly answer the problems shiki
  would otherwise have to rediscover.
  Date: 2026-05-27.

- Decision: Skip the toggle / expect-keys / multi-select / preview features described in
  sections 6, 8, 9, 10 of the reference document. Ship only single-select `runFzf`.
  Rationale: No shiki subcommand needs them yet. Future plans can layer in `FzfOpts`
  extensions because they're a Monoid.
  Date: 2026-05-27.

- Decision: Make `runs show / logs / error / analyze` accept `Maybe Text` instead of
  `Text` for the positional ID, using `optparse-applicative` Pattern A (`optional
  strArgument`) from §11 of the reference doc.
  Rationale: Each of these subcommands has exactly one positional and no trailing
  variadic, so the pattern is unambiguous; the help line stays one positional wide.
  Date: 2026-05-27.

- Decision: Do **not** make `shiki run`'s `SERVICE` positional optional in this plan.
  Rationale: `RunOptions` ends with `many (argument str (metavar "-- ARG..."))` to collect
  the container's command tail. If `SERVICE` becomes `optional`, optparse-applicative
  greedily binds the first positional after `run` to `SERVICE`, which makes
  `shiki run -- echo hi` parse as `service = Just "echo"`, `commandArgs = ["hi"]`. Fixing
  this would require a parser refactor (likely a `--service` flag or two-phase argument
  parsing) that is out of scope. Recorded as a follow-up.
  Date: 2026-05-27.

- Decision: Make the fzf picker for `runs *` show the **50 most recent runs** (not the
  default `runs list` limit of 20).
  Rationale: A picker with fuzzy-search is more useful with more candidates, and 50 rows
  still fits in a `40%`-height fzf pane. The number is the constant `selectorRowLimit` in
  `Shiki.Cli.Fzf.Selector.Run`.
  Date: 2026-05-27.

- Decision (superseded 2026-09-11 by "Detect fzf on demand" below): Detect fzf
  availability once per CLI invocation, inside `withCliEnv`, and thread the resulting
  `FzfConfig` through `CliEnv`.
  Rationale at the time: §1 of the reference doc recommends it, and it would avoid repeated
  probes if a command ever composed two selectors.
  Date: 2026-05-27.

- Decision: When fzf is unavailable AND the positional is omitted, exit non-zero with a
  helpful message rather than degrading to "show the most recent run" or similar.
  Rationale: Silent fallbacks hide misconfiguration. Unavailability in practice means the
  binary is driven from a scripted, piped, or agent environment, where a clear error beats
  a guess.
  Date: 2026-05-27.

- Decision: Place fzf modules under `Shiki.Cli.Fzf*` in `shiki-cli`, not in `shiki-core`.
  Rationale: fzf is strictly an interactive CLI affordance with no meaning in a library
  context.
  Date: 2026-05-27.

- Decision (superseded 2026-09-11 by "Share run formatting" below): Inline a private
  `formatDuration` in `Shiki.Cli.Fzf.Selector.Run` instead of exporting helpers from
  `Shiki.Cli.Runs`.
  Rationale at the time: `Shiki.Cli.Runs` imports the selector, so importing it back is a
  module cycle, and ten duplicated lines were cheaper than a new module.
  Date: 2026-05-28.

- Decision: Esc and Ctrl-C cancel silently and shiki exits **1**, not 0.
  Rationale: A script wrapping `shiki runs show` can tell "nothing was shown" from success,
  which matches Unix convention for cancelled interactive input. Early drafts of M2 and M5
  said Esc exits 0; those passages were corrected on 2026-09-11. Milestones 6–10 keep
  exit 1.
  Date: 2026-05-28.

- Decision: Describe interfaces as they exist in the tree (unprefixed fields read with
  generic-lens `^. #field`), not with the prefixed names the milestones first shipped
  (`fzfBinary`, `fzfPrompt`, `candidateDisplay`).
  Rationale: The rename was done by
  `docs/plans/16-adopt-haskell-jitsurei-conventions-for-the-initial-release.md` and changed
  no behaviour; a living plan must match the working tree.
  Date: 2026-09-11.

- Decision: Reopen this plan with milestones 6–10 instead of writing a new plan.
  Rationale: The user asked for this plan to be updated to address the review. Every change
  reworks code this plan created, and keeping the history and the fixes in one document
  makes the reasoning traceable.
  Date: 2026-09-11.

- Decision: Resolve a run in two phases: choose a `RunTarget` before acquiring the database
  environment, then look the target up to a `RunRecord` inside it.
  Rationale: Whether a picker is possible depends only on the arguments and the terminal,
  so it must be decided before paying for a connection, migrations, and Kubernetes config.
  The picker itself needs the database for its candidates, so the lookup stays inside.
  `runRuns` receives the environment-acquiring function as an argument
  (`(CliEnv -> IO ()) -> IO ()`) so it controls when acquisition happens; every handler
  returns `()`, so a monomorphic type is enough and no rank-2 type is needed.
  Date: 2026-09-11.

- Decision: Detect fzf on demand, only when a positional is missing, and remove the `fzf`
  field from `CliEnv`.
  Rationale: Probing in `withCliEnv` ran for every database command (including `run`,
  `runs list`, and `agent assist`) that never uses fzf, while `service show` already probed
  separately, so there was never a single snapshot. No command composes two pickers. The
  probe is two cheap system calls; doing it where it is needed removes an unrelated
  concern from the shared environment record.
  Date: 2026-09-11.

- Decision: Handlers take the resolved `RunRecord`. The positional path performs the only
  prefix lookup; the picker path uses the record fzf returned, with no second query.
  Rationale: Flattening the picked row back to text and re-querying was chosen in M3 to
  avoid touching the handlers. It cost a table scan per pick, four copies of the
  match-count logic, and a stringly-typed seam. One `lookupRun` owns both paths.
  Date: 2026-09-11.

- Decision: Model every way resolution can fail as one sum type per entity
  (`RunLookupFailure`, `ServiceLookupFailure`), map fzf results and prefix matches into it
  with pure functions, and render messages with one pure function whose output the
  dispatcher prints on stderr before exiting 1.
  Rationale: The old `Maybe` return merged cancel, empty table, no match, fzf missing, and
  errors, which is exactly how "no match" came to be reported as "no runs recorded". Pure
  mapping and rendering are unit-testable without spawning fzf. A shared cross-entity
  failure type is not worth it for two entities whose messages all differ.
  Date: 2026-09-11.

- Decision: Send all resolution failures to stderr, keeping the existing wording of the
  positional-path messages (`no run matching <id>`, `ambiguous id prefix <id>`); new
  messages use the `shiki: ` prefix like the rest of the CLI.
  Rationale: Errors on stdout corrupt pipelines such as `shiki runs show abc | jq`.
  Keeping the old wording limits the change to the stream, which the CHANGELOG records
  under "Changed". `shiki runs list` keeps printing `(no runs recorded yet)` on stdout with
  exit 0, because an empty list is not an error there.
  Date: 2026-09-11.

- Decision: Make fzf's auto-select (`-1`) an explicit option (`withSelectOne`). The
  read-only pickers (`runs show`, `runs logs`, `runs error`, `service show`) keep it;
  `runs analyze` drops it and adds a header warning.
  Rationale: Auto-selecting a lone candidate is a convenience for reads but turns a picker
  into an unconfirmed write for `analyze`, which overwrites `error_summary` and may call a
  paid model backend.
  Date: 2026-09-11.

- Decision: Share run formatting: move the `runs list` rendering helpers into
  `Shiki.Cli.Runs.Format`, imported by both `Shiki.Cli.Runs` and the selector, and show the
  column titles in the picker through fzf's `--header-lines=1`.
  Rationale: A module that both import breaks the cycle that forced the inlined copy. Using
  the same widths computation over the titles and the rows makes the picker line up the way
  `runs list` does. Sending the titles as the first input line (hidden index `-`) means fzf
  renders them through the same `--with-nth=2..` transformation as the rows, so they align,
  and fzf never returns a header line as a selection.
  Date: 2026-09-11.

- Decision: Drop `--ansi` from the run picker instead of adding status colours.
  Rationale: No escape codes are emitted, so the flag is a no-op; adding colour is a
  separate feature with no request behind it. `withAnsi` stays exported for a future
  consumer.
  Date: 2026-09-11.

- Decision: `isFzfAvailable` is `available && ttyAvailable`; `FzfConfig` drops
  `stdinIsTerminal` and `stdoutIsTerminal`.
  Rationale: fzf's stdin is always shiki's pipe, so fzf always reads keys from `/dev/tty`
  and draws on the terminal (see Surprises). A terminal stdin without an openable
  `/dev/tty` cannot drive fzf, and stdout was never consulted.
  Date: 2026-09-11.

- Decision: Catch `IOException` in `runFzf`, not `SomeException`.
  Rationale: Spawn failures, broken pipes, and the failed pattern match on
  `createProcess`'s handles are all `IOException`s. Catching `SomeException` would also
  swallow asynchronous exceptions such as `UserInterrupt` or a timeout's kill.
  Date: 2026-09-11.

- Decision: Test `runFzf` end to end with a generated fake `fzf` shell script.
  Rationale: The script, written to a temporary directory by the test, records its
  arguments and plays back an exit code and a chosen line. An `FzfConfig` built by hand
  with `ttyAvailable = True` points at it. This checks the process plumbing, the exit-code
  mapping, the header line, and the `-1` flag without a terminal, which the earlier plan
  had ruled out of scope.
  Date: 2026-09-11.

- Decision: Keep the resolvers in `Shiki.Cli.Fzf.Selector.Run` and
  `Shiki.Cli.Fzf.Selector.Service`, even though they also handle the typed positional.
  Rationale: Renaming modules adds churn without changing behaviour, and a "selector" that
  selects by prefix or by picker is still a selector. The module comments say so.
  Date: 2026-09-11.

- Decision: Keep `services/` relative to the current directory; do not anchor it to the
  directory containing `shiki.dhall` in this plan.
  Rationale: `serviceShowOne`, the service picker, `shiki run --config-dir` (default
  `services`), `effectiveBackend` in `shiki-cli/src/Shiki/Cli/Runs.hs`, and the agent
  context builder all share the convention. Changing one without the others would make the
  picker disagree with the command it feeds. It belongs to a plan that anchors every
  service lookup at once.
  Date: 2026-09-11.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

### 2026-05-28 — Milestones 1–5 complete

**Outcome.** All five milestones landed green; `shiki runs show / logs / error / analyze`
and `shiki service show` accept the positional as optional and fall through to an `fzf`
picker; `--help` for each surfaces the `[ID]`/`[NAME]` syntax and the picker behaviour.
The positional path's output was unchanged.

**What matched the plan.** The five-milestone split sequenced cleanly; the index-prefix
trick with `--with-nth=2..` worked first try; `delegate_ctlc = True` gave clean Ctrl-C
handling.

**What deviated.** The `humanDuration` re-export created a module cycle, so the helper was
inlined; `nix fmt` did not exist in the flake yet; a pre-existing race in `LaunchSpec` was
fixed with `localOption (NumThreads 1)`.

**Gaps / follow-ups** at the time: `shiki run [SERVICE]` selection, `shiki agent assist`
selection, and restoring `nix fmt`.

### 2026-09-11 — Refresh and architecture review

The feature still behaved as specified at `HEAD` `d0686f7`; ten later commits touched its
files without changing behaviour (environment routing `1961fef`, `d2e1e4e`, `0206a92`,
`0cd89bd`, `ef61ae3`; conventions refactor `78d2189`, `5825569`, `5c061f8`, `e51c138`;
completions `3e2ed64`). `nix fmt` is restored.

The review then found that the first design traded correctness for a small diff in the
places listed in Surprises: the picker's result is flattened to text and re-queried, every
failure collapses into `Nothing` (producing a misleading message), detection lives in the
shared environment and runs after database setup, and the options, formatting, and
availability check each carry a small defect. The core subprocess technique is sound and
stays. Lesson: a resolver should return the entity and a typed outcome, not a string for
the old code path to re-parse; "zero changes to handlers" was the wrong thing to optimise.

**Follow-up status.** `nix fmt`: done. Help topic gap, misleading no-match message,
stdout errors, `-1` on `analyze`, alignment, `--ansi`, detection placement, and the
re-query: scheduled in milestones 6–10. Still open and out of scope: `shiki run [SERVICE]`
selection, `shiki agent assist` run selection, and anchoring `services/` to the project
root (see the Decision Log).

**ADR distillation.** The repository has no ADR corpus (`docs/adr/` is absent and
`mori.dhall` declares no ADR bundle). Candidates for promotion once one exists, to be
revisited in M10: interactive affordances live in `shiki-cli`; an omitted positional
resolves as positional > picker > explicit error, decided before any expensive resource is
acquired; resolvers return entities plus a typed failure rendered in one place.


## Context and Orientation

**The repository.** `shiki` is a Haskell CLI (a cabal multi-package project) that runs
one-off Kubernetes Jobs for microservices and records each run in PostgreSQL. The two
packages are:

- `shiki-core/` — domain types, persistence (hasql), Kubernetes runner, analyzer
  backends, project configuration.
- `shiki-cli/` — the optparse-applicative parser and command handlers; the
  `executable shiki` in `shiki-cli/shiki-cli.cabal` calls `Shiki.Cli.runCli` from
  `shiki-cli/app/Main.hs`.

The build is driven from a `Justfile` at the repository root (`just build` runs
`cabal build all`, `just test` runs `cabal test all`, `just shiki <args>` runs
`cabal run shiki -- <args>`, `just fmt` runs `nix fmt`) and a Nix flake built with
flake-parts whose modules live under `nix/`. PostgreSQL is started via process-compose
(`just up` / `just down`); `nix develop` exports `PG_CONNECTION_STRING` for the local
database, and ships `fzf` (0.74.1 at the time of writing).

**Code conventions that affect every excerpt below.** Both packages share a `common`
cabal stanza (`GHC2024`, `DuplicateRecordFields`, `OverloadedLabels`,
`OverloadedStrings`, `MultilineStrings`) and build with `-Wall` and friends; the tree is
warning-free and must stay so. Record fields carry no type prefix and are read and updated
through generic-lens labels: `cfg ^. #available`, `mempty & #prompt ?~ t`. The lens
operators (including `^.`, `&`, `.~`, `?~`, `<&>`) come from `Shiki.Prelude`
(`shiki-core/src/Shiki/Prelude.hs`), which every module imports alongside the normal
Prelude; a module that uses `#label` syntax must also write
`import Data.Generics.Labels ()` itself. Records read through labels must derive
`Generic`. Anything else (`Data.Bifunctor (first)`, `Data.Maybe (maybeToList)`) is
imported explicitly. Haskell is formatted with fourmolu (`fourmolu.yaml`) and cabal files
with cabal-gild; `nix fmt` runs both.

**Architecture Decision Records.** No relevant ADR exists: there is no `docs/adr/`
directory and `mori.dhall` declares no ADR bundle.

**How a command reaches its handler.** `shiki-cli/src/Shiki/Cli.hs` defines:

```haskell
data Command
  = Run !RunOptions
  | Runs !RunsCommand
  | ServiceShow !(Maybe Text)
  | Agent !AgentCommand
  | Help !HelpCommand
  | Config !ConfigCommand
  | Completions !CompletionsShell
  deriving stock (Generic, Eq, Show)
```

`runCli` dispatches `ServiceShow`, `Help`, `Completions`, and `Config` directly, without
touching the database. `Run`, `Runs`, and `Agent` go through `withDbEnv`, which resolves a
connection string (`--db`, then the active `shiki.dhall` environment's `databaseUrl`, then
`SHIKI_DATABASE_URL`, then `PG_CONNECTION_STRING`), resolves the schema, and calls
`Shiki.Cli.Env.withCliEnv`. Today the `Runs` branch reads:

```haskell
Runs runsOpts ->
  withDbEnv (opts ^. #dbConnStr) (opts ^. #dbSchema) (opts ^. #envName) $ \_ env ->
    runRuns env runsOpts
```

**`CliEnv`** (`shiki-cli/src/Shiki/Cli/Env.hs`) bundles `pool :: !Pool.Pool`,
`client :: !ClientEnv`, and (until M8) `fzf :: !FzfConfig`. `withCliEnv` acquires the pool,
runs pending migrations, loads the Kubernetes client config, probes for fzf, calls the
continuation, and releases the pool. `Shiki.Cli.Run` and `Shiki.Cli.Agent` also take a
`CliEnv` but never read `fzf`.

**The `runs` read commands today** (`shiki-cli/src/Shiki/Cli/Runs.hs`). `RunsCommand` has
`RunsList !(Maybe Text) !Int`, `RunsShow !(Maybe Text)`, `RunsLogs !(Maybe Text)`,
`RunsError !(Maybe Text)`, and `RunsAnalyze !(Maybe Text) !(Maybe AnalyzerKind)`.
`runRuns :: CliEnv -> RunsCommand -> IO ()` sends the four single-run commands through
`withResolved`, which calls `resolveRunId` and then a handler taking the id text. Each
handler starts with the same block:

```haskell
doShow :: CliEnv -> Text -> IO ()
doShow env idText = do
  matches <- runRead env findRunByPrefixStatement idText
  case matches of
    [] -> noMatch idText            -- stdout "no run matching <id>", exit 1
    [r] -> BL8.putStrLn (AesonPretty.encodePretty r)
    _ -> ambiguous idText           -- stdout "ambiguous id prefix <id>", exit 1
```

`runRead` turns a persistence error into an `error` call. The bottom of the file holds the
table helpers used by `runs list`: `renderTable`, `renderRow` (the seven cells of one run:
8-character id, start time, service, status, duration, exit code, command), `humanDuration`,
`computeWidths` (the widest cell per column), and `formatRow` (pads every cell to its
column width and joins with two spaces). `doAnalyze` also reads the service's Dhall file to
choose an analyzer and writes the result with `updateErrorSummaryStatement`.

**The persistence statements** live in `shiki-core/src/Shiki/Persistence/Run.hs`:
`listRecentRunsStatement :: Statement Int [RunRecord]` (newest first, around line 212) and
`findRunByPrefixStatement :: Statement Text [RunRecord]` (around line 251), which returns
at most two rows whose `id::text LIKE $1 || '%'`, enough to tell "unique" from
"ambiguous". `RunRecord` derives `Eq` and `Show`, so tests can compare it directly.

**The fzf modules today.** `shiki-cli/src/Shiki/Cli/Fzf.hs` holds the subprocess core:
`FzfConfig` (`binary`, `available`, `stdinIsTerminal`, `stdoutIsTerminal`,
`ttyAvailable`), `detectFzfConfig`, `isFzfAvailable`, the `FzfOpts` monoid (`prompt`,
`header`, `height`, `ansi`, `noSort`) with smart constructors `withPrompt`, `withHeader`,
`withHeight`, `withAnsi`, `withNoSort`, the `Candidate a` record (`display`, `value`),
`FzfResult a` (`FzfSelected`, `FzfNoMatch`, `FzfCancelled`, `FzfError`), and
`runFzf :: FzfConfig -> FzfOpts -> [Candidate a] -> IO (FzfResult a)`.
`shiki-cli/src/Shiki/Cli/Fzf/Selector/Run.hs` holds `RunSelection`, `defaultRunOpts`,
`formatRunCandidate`, `selectRun`, `resolveRunId`, and a private `formatDuration`.
`shiki-cli/src/Shiki/Cli/Fzf/Selector/Service.hs` holds `ServiceSelection`,
`defaultServiceOpts`, `selectService`, `resolveServiceName`, and a private `listEntries`
that lists `services/*.dhall`. `serviceShowHandler` in `shiki-cli/src/Shiki/Cli.hs` calls
`detectFzfConfig` and `resolveServiceName` when no name is given, then `serviceShowOne`
loads `services/<NAME>.dhall` and prints it as JSON.

**Tests.** `shiki-cli/test/Spec.hs` runs one tasty tree with `localOption (NumThreads 1)`.
`shiki-cli/test/Shiki/Cli/Fzf/Selector/RunSpec.hs` holds a `fixtureRow :: RunRecord` (id
starting `3f2c1a9d`, service `ingest`, command `reindex --batch 100`, status `Succeeded`)
and three formatter tests. Test modules must be listed in the `other-modules` of the
`test-suite shiki-cli-test` stanza in `shiki-cli/shiki-cli.cabal`, whose dependencies
already include `directory`, `filepath`, `temporary`, `text`, `time`, `uuid`, and
`aeson`.

**Terminology.**

- **fzf**: the junegunn/fzf terminal fuzzy finder, run as a subprocess. We pipe
  newline-delimited candidate lines to its stdin and parse the line it prints on stdout.
  Its exit codes: 0 a row was accepted, 1 Enter with no matching row, 130 Esc or Ctrl-C,
  anything else an error.
- **Candidate**: a record with `display :: Text` (what the operator sees) and `value :: a`
  (what comes back). fzf only ever sees `"<index>\t<display>"` lines, hidden by
  `--with-nth=2..` (show fields 2 onward, fields being whitespace-separated by default), and
  reports the index back; we look it up in a `Map Int a`.
- **Header row**: a line of column titles fzf shows above the candidates and never lets the
  operator select, enabled by `--header-lines=1` (treat the first input line as header).
- **Auto-select**: fzf's `-1` (`--select-1`) flag, which accepts the only candidate
  without drawing the picker.
- **Target**: what the operator asked for before any lookup: a typed prefix or name, or
  "use the picker" (which carries the detected `FzfConfig`).
- **Resolver**: the functions that turn a target into the entity (a `RunRecord`, or a
  service name) or a typed failure.

**External reference.** The patterns come from the haskell-jitsurei fzf-integration
cookbook, `mori://shinzui/haskell-jitsurei/docs/cli-fzf-integration` (resolve it on disk
with `mori path <uri>`). It is not part of this repository; everything needed is restated
here. The invariants to preserve:

1. **Index-based selection**: emit `"<i>\t<display>"` with `--with-nth=2..`.
2. **`delegate_ctlc = True`** so Ctrl-C reaches fzf (exit 130) instead of killing shiki.
3. **`std_err = Inherit`** so fzf's own error messages reach the operator. fzf draws its
   interface on the terminal device and reads keys from `/dev/tty`, not through these
   handles (see Surprises).
4. **Lazy `hGetContents` + `waitForProcess`**, forcing the stdout read before the result
   is interpreted.
5. **`/dev/tty` probe** in availability detection.

**Prior and later plans** (all in `docs/plans/`): `4-run-cli-command-end-to-end.md`
introduced `RunOptions`; `5-runs-query-cli-commands.md` introduced `RunsCommand`;
`7-job-log-fetch-and-error-summary-analysis.md` added `runs analyze` and `runs error`;
`8-agent-assist-subcommand-backed-by-baikai.md` added `shiki agent assist`;
`13-route-run-storage-to-the-active-environment-database.md` added environment routing;
`16-adopt-haskell-jitsurei-conventions-for-the-initial-release.md` unprefixed the fzf
records and declined a picker for bare `shiki help`.


## Plan of Work

Milestones 1–5 built the feature; their descriptions are kept below as the record of the
first implementation. Milestones 6–10 revise it. Each of milestones 6–10 leaves the build
warning-free and the test suite green, and each is one commit that can be reverted on its
own (in reverse order).

### Milestone 1 — Core `Shiki.Cli.Fzf` module and `CliEnv` integration (done)

Added `process ^>=1.6` and `containers ^>=0.7` to the `shiki-cli` library, created
`shiki-cli/src/Shiki/Cli/Fzf.hs` with the types and functions listed under "The fzf
modules today" in Context and Orientation, and added `fzf :: !FzfConfig` to `CliEnv`,
filled by `detectFzfConfig` inside `withCliEnv`. `detectFzfConfig` uses
`System.Directory.findExecutable "fzf"`, `hIsTerminalDevice` on `stdin` and `stdout`, and a
`try`-guarded `openFile "/dev/tty" ReadMode >>= hClose`. `runFzf` short-circuits to
`FzfNoMatch` on an empty list and to `FzfError "fzf not available"` when unavailable,
spawns `proc (cfg ^. #binary) (["-1", "--with-nth=2.."] <> optsToArgs opts)` with piped
stdin/stdout, inherited stderr, and `delegate_ctlc = True`, writes the numbered lines,
reads stdout lazily, waits, and maps exit 0 / 1 / 130 / other to `FzfSelected` (after
parsing the index before the first tab) / `FzfNoMatch` / `FzfCancelled` / `FzfError`. Any
`SomeException` becomes `FzfError "fzf spawn failed: …"`.

### Milestone 2 — `Shiki.Cli.Fzf.Selector.Run` and pure unit tests (done)

Created `shiki-cli/src/Shiki/Cli/Fzf/Selector/Run.hs`. `defaultRunOpts` is
`withPrompt "run> " <> withHeight "40%" <> withAnsi <> withNoSort`. `formatRunCandidate`
joins seven cells with two spaces (exit code written as `exit=<n>`). `selectRun` fetches
`listRecentRunsStatement` with limit 50 and maps `FzfResult` to `RunSelection`.
`resolveRunId :: CliEnv -> Maybe Text -> IO (Maybe Text)` returns `Just t` for a
positional, and otherwise prints a message and returns `Nothing` unless the operator
picked a row, in which case it returns the full UUID as text. Added `RunSpec` with three
formatter tests.

### Milestone 3 — Wire fzf into the four `runs` read subcommands (done)

Changed the four constructors to `Maybe Text`, parsed each id with
`optional (argument str idArgHelp)` where `idArgHelp` is
`metavar "ID" <> help "Run id (UUID or unambiguous prefix); opens an fzf picker if omitted"`,
suffixed each `progDesc` with "(uses fzf if omitted)", and routed the four commands through
`withResolved env mId handler`, which exits 1 when `resolveRunId` returns `Nothing`.

### Milestone 4 — `Shiki.Cli.Fzf.Selector.Service` and `service show` (done)

Created `shiki-cli/src/Shiki/Cli/Fzf/Selector/Service.hs` (prompt `service> `, height
40%, no sort; candidates are the sorted `services/*.dhall` basenames), changed
`ServiceShow` to `!(Maybe Text)` with an optional `NAME` argument whose help reads
"Service name (basename of services/<NAME>.dhall); opens an fzf picker if omitted", and
made `serviceShowHandler Nothing` call `detectFzfConfig` and `resolveServiceName` directly,
since `service show` has no `CliEnv`.

### Milestone 5 — Docs, smoke transcript, formatting (done)

Added the "Interactive selection (fzf)" section and per-command notes to
`docs/user/commands.md`, a CHANGELOG entry with a smoke transcript, and matched the
surrounding code style by hand because `nix fmt` did not exist yet.

### Milestone 6 — Harden the fzf core

Scope: fix the core module's availability check, exception handling, and hard-coded
`-1`, and add the header-row option M7 needs, without changing any command's behaviour. At
the end, `runFzf` has subprocess tests that run without a terminal.

**File `shiki-cli/src/Shiki/Cli/Fzf.hs`.** Change `FzfConfig` and its probe:

```haskell
data FzfConfig = FzfConfig
  { binary :: !FilePath,
    available :: !Bool,
    ttyAvailable :: !Bool
  }
  deriving stock (Generic, Eq, Show)

detectFzfConfig :: IO FzfConfig
detectFzfConfig = do
  mPath <- findExecutable "fzf"
  ttyOk <- probeTty
  pure
    FzfConfig
      { binary = fromMaybe "fzf" mPath,
        available = isJust mPath,
        ttyAvailable = ttyOk
      }
  where
    probeTty :: IO Bool
    probeTty = do
      r <- try @IOException (openFile "/dev/tty" ReadMode >>= hClose)
      pure (either (const False) (const True) r)

-- | fzf reads keys from @\/dev\/tty@ (its stdin is our pipe), so it can run
--   exactly when the binary exists and @\/dev\/tty@ opens.
isFzfAvailable :: FzfConfig -> Bool
isFzfAvailable cfg = cfg ^. #available && cfg ^. #ttyAvailable
```

Remove the now-unused `hIsTerminalDevice`, `stdin`, and `stdout` imports.

Add two fields to `FzfOpts` and their constructors, and export `withSelectOne` and
`withHeaderRow`:

```haskell
data FzfOpts = FzfOpts
  { prompt :: !(Maybe Text),
    header :: !(Maybe Text),
    height :: !(Maybe Text),
    ansi :: !Bool,
    noSort :: !Bool,
    selectOne :: !Bool,
    headerRow :: !(Maybe Text)
  }
  deriving stock (Generic, Eq, Show)

-- in the Semigroup instance:
--   selectOne = a ^. #selectOne || b ^. #selectOne,
--   headerRow = b ^. #headerRow <|> a ^. #headerRow
-- in mempty: selectOne = False, headerRow = Nothing

-- | Accept the only candidate without drawing the picker (fzf's @-1@).
withSelectOne :: FzfOpts
withSelectOne = mempty & #selectOne .~ True

-- | A line of column titles shown above the candidates. It is sent as the
--   first input line and marked with @--header-lines=1@, so fzf renders it
--   through the same @--with-nth@ as the rows and never returns it.
withHeaderRow :: Text -> FzfOpts
withHeaderRow t = mempty & #headerRow ?~ t
```

In `runFzf`, stop hard-coding `-1`, prepend the header line, and narrow the exception type:

```haskell
stdinPayload =
  Text.unlines
    ( ["-\t" <> row | row <- maybeToList (opts ^. #headerRow)]
        <> [Text.pack (show i) <> "\t" <> c ^. #display | (i, c) <- numbered]
    )
args = "--with-nth=2.." : optsToArgs opts
…
r <- try @IOException $ do
```

and extend `optsToArgs` with `["-1" | o ^. #selectOne]` and
`["--header-lines=1" | isJust (o ^. #headerRow)]`. The header's hidden index is `-`, which
`parsePicked` would reject, but fzf never prints a header line, so it cannot come back.
Update the module comment: the flags are now all driven by `FzfOpts`, and detection is
described as "per call site" rather than "threaded through `CliEnv`" (M8 makes that true;
write the final wording now). Import `IOException` instead of `SomeException` and
`maybeToList` from `Data.Maybe`.

**Keep behaviour identical.** In `shiki-cli/src/Shiki/Cli/Fzf/Selector/Run.hs` set
`defaultRunOpts = withPrompt "run> " <> withHeight "40%" <> withNoSort <> withSelectOne`
(dropping the no-op `withAnsi`), and in
`shiki-cli/src/Shiki/Cli/Fzf/Selector/Service.hs` append `<> withSelectOne` to
`defaultServiceOpts`. Nothing else in the selectors changes yet.

**File `shiki-cli/test/Shiki/Cli/FzfSpec.hs` (new).** Build a fake fzf per test in a
temporary directory. The script records its arguments and stdin next to itself, then runs a
per-test body:

```haskell
withFakeFzf :: String -> (FzfConfig -> FilePath -> IO a) -> IO a
withFakeFzf body k =
  withSystemTempDirectory "fake-fzf" $ \dir -> do
    let script = dir </> "fzf"
    writeFile script $
      unlines
        [ "#!/bin/sh",
          "dir=$(dirname \"$0\")",
          "printf '%s\\n' \"$@\" > \"$dir/args\"",
          "cat > \"$dir/stdin\"",
          body
        ]
    perms <- getPermissions script
    setPermissions script (setOwnerExecutable True perms)
    k FzfConfig {binary = script, available = True, ttyAvailable = True} dir
```

Candidates are `[Candidate "ingest" "ingest", Candidate "worker" "worker"]`. Cases:

- Body `sed -n 2p "$dir/stdin"` (prints `1\tworker`) → `FzfSelected "worker"`.
- Body `exit 1` → `FzfNoMatch`; body `exit 130` → `FzfCancelled`; body `exit 2` →
  `FzfError "fzf exited with code 2"`.
- Body `echo nonsense` → `FzfError "fzf returned no parseable index"`.
- `binary = "/nonexistent/fzf"` → an `FzfError` whose text starts with
  `fzf spawn failed`.
- An empty candidate list returns `FzfNoMatch` and never creates the `args` file.
- With `withSelectOne` the `args` file contains a line `-1`; with `mempty` it does not.
- With `withHeaderRow "NAME"` and body `sed -n 3p "$dir/stdin"`: the first stdin line is
  `-\tNAME`, the `args` file contains `--header-lines=1`, and the result is
  `FzfSelected "worker"` (line 3 is candidate index 1).
- `isFzfAvailable` truth table: true only when both `available` and `ttyAvailable` are
  true.

`FzfResult` has no `Eq` instance; either add `deriving stock (Eq, Show)` to it (preferred:
it is a plain data type) or compare with pattern matches. Add the module to
`other-modules` in the test stanza and to the tree in `shiki-cli/test/Spec.hs`
(`import Shiki.Cli.FzfSpec qualified as FzfSpec`).

Acceptance: `cabal build all` prints no warnings; `cabal test shiki-cli-test` passes with
a new `Shiki.Cli.Fzf` group; `shiki runs show --help` and every picker behave as before.

### Milestone 7 — Share run formatting between `runs list` and the picker

Scope: one set of column helpers used by both views, aligned picker rows under a
column-title header, and no duplicated duration formatter. `runs list` output must not
change by a single byte.

**File `shiki-cli/src/Shiki/Cli/Runs/Format.hs` (new).** Move, unchanged, `renderTable`,
`humanDuration`, `computeWidths`, and `formatRow` from `shiki-cli/src/Shiki/Cli/Runs.hs`;
move `renderRow` and rename it `runColumns`; lift the header list into a named value:

```haskell
module Shiki.Cli.Runs.Format
  ( runTableHeader,
    runColumns,
    humanDuration,
    computeWidths,
    formatRow,
    renderTable,
  )
where

runTableHeader :: [Text]
runTableHeader = ["ID", "STARTED", "SERVICE", "STATUS", "DURATION", "EXIT", "COMMAND"]

renderTable :: [RunRecord] -> Text
renderTable rs =
  let body = map runColumns rs
      widths = computeWidths (runTableHeader : body)
   in Text.unlines (formatRow widths runTableHeader : map (formatRow widths) body)
```

It imports only `shiki-core` modules and the prelude, so both `Shiki.Cli.Runs` and the
selector can import it without a cycle. Add it to `exposed-modules`. In `Shiki.Cli.Runs`
import `renderTable` from it and delete the moved code and any imports that become unused.

**File `shiki-cli/src/Shiki/Cli/Fzf/Selector/Run.hs`.** Replace `formatRunCandidate` and
the private `formatDuration` with:

```haskell
-- | Align the picker rows exactly like @runs list@: the widths are computed
--   over the column titles and every row, and the titles are returned so the
--   caller can show them with 'withHeaderRow'.
formatRunCandidates :: [RunRecord] -> (Text, [Candidate RunRecord])
formatRunCandidates rows =
  let cells = map runColumns rows
      widths = computeWidths (runTableHeader : cells)
   in ( formatRow widths runTableHeader,
        zipWith (\r cs -> Candidate {display = formatRow widths cs, value = r}) rows cells
      )
```

In `selectRun`, build candidates with it and call
`runFzf cfg (defaultRunOpts <> withHeaderRow titles) candidates`; `FzfSelected r` becomes
`RunChosen (r ^. #runId) r`. (`RunSelection` survives until M8.) The exit code cell is now a
bare number under the `EXIT` title, as in `runs list`.

**Tests.** New `shiki-cli/test/Shiki/Cli/Runs/FormatSpec.hs`: `humanDuration` gives `12s`,
`2m5s`, and `1h1m1s` for 12000, 125000, and 3661000; `renderTable [fixture]` has exactly
two lines, the first starting with `ID`, and the column that starts with `STATUS` in the
header starts with `Succeeded` in the row (same character offset). In `RunSpec`, replace
the three `formatRunCandidate` tests with `formatRunCandidates` tests over two rows whose
services have different lengths (`ingest` and `a-much-longer-service`) and different
statuses (`Succeeded`, `Failed`): displays are single-line and contain the id prefix, the
service, and the command; and the offset of `STATUS` in the title row equals the offset of
each row's status text. Move `fixtureRow` into a small shared test helper module
(`shiki-cli/test/Shiki/Cli/Fixtures.hs`, listed in `other-modules`) so both specs use it.

Acceptance: with the database up, capture `cabal run -v0 shiki -- runs list > before.txt`
before the move and `after.txt` after it; `diff before.txt after.txt` prints nothing. Tests
green. `just shiki runs show` shows a title row above aligned rows.

### Milestone 8 — One run resolver: target before the database, record after

Scope: replace the text-returning resolver with a two-phase resolver, move fzf detection
out of `CliEnv`, and print every failure on stderr from one place. This fixes the
misleading no-match message, the database-before-fzf ordering, the re-query, and
`runs analyze` auto-selecting.

**File `shiki-cli/src/Shiki/Cli/Fzf/Selector/Run.hs`.** Replace `RunSelection`,
`defaultRunOpts`, `selectRun`, and `resolveRunId` with the API below. The module comment
should say that it resolves a run from either a typed prefix or the picker.

```haskell
module Shiki.Cli.Fzf.Selector.Run
  ( RunTarget (..),
    RunLookupFailure (..),
    readRunOpts,
    analyzeRunOpts,
    formatRunCandidates,
    runTarget,
    pickerRunTarget,
    lookupRun,
    fromPrefixMatches,
    fromRunFzfResult,
    renderRunLookupFailure,
  )
where

-- | What the operator asked for, decided before any database work.
data RunTarget
  = RunByPrefix !Text
  | RunByPicker !FzfConfig !FzfOpts

-- | Every way turning a target into a run can fail.
data RunLookupFailure
  = NoRunMatching !Text
  | AmbiguousRunPrefix !Text
  | NoRunsRecorded
  | RunPickerNoMatch
  | RunPickerCancelled
  | RunFzfUnavailable
  | RunPickerFailed !Text
  | RunLookupPersistenceError !Text
  deriving stock (Eq, Show)

pickerBaseOpts :: FzfOpts
pickerBaseOpts = withPrompt "run> " <> withHeight "40%" <> withNoSort

-- | For show / logs / error: a lone run is picked without asking.
readRunOpts :: FzfOpts
readRunOpts = pickerBaseOpts <> withSelectOne

-- | For analyze, which writes: always ask, and say what Enter does.
analyzeRunOpts :: FzfOpts
analyzeRunOpts =
  pickerBaseOpts
    <> withHeader "Enter re-runs analysis on the selected run and overwrites its stored error summary"

-- | Decide the target. Probes for fzf only when no positional was given.
runTarget :: FzfOpts -> Maybe Text -> IO (Either RunLookupFailure RunTarget)
runTarget _ (Just t) = pure (Right (RunByPrefix t))
runTarget opts Nothing = pickerRunTarget opts <$> detectFzfConfig

pickerRunTarget :: FzfOpts -> FzfConfig -> Either RunLookupFailure RunTarget
pickerRunTarget opts cfg
  | isFzfAvailable cfg = Right (RunByPicker cfg opts)
  | otherwise = Left RunFzfUnavailable

-- | Resolve a target to a run. The prefix path is the only one that queries
--   by id; the picker path returns the record fzf handed back.
lookupRun :: CliEnv -> RunTarget -> IO (Either RunLookupFailure RunRecord)
lookupRun env = \case
  RunByPrefix t ->
    query findRunByPrefixStatement t <&> (>>= fromPrefixMatches t)
  RunByPicker cfg opts ->
    query listRecentRunsStatement selectorRowLimit >>= \case
      Left e -> pure (Left e)
      Right [] -> pure (Left NoRunsRecorded)
      Right rows -> do
        let (titles, candidates) = formatRunCandidates rows
        fromRunFzfResult <$> runFzf cfg (opts <> withHeaderRow titles) candidates
  where
    query stmt input =
      first (RunLookupPersistenceError . Text.pack . show)
        <$> Pool.use (env ^. #pool) (Session.statement input stmt)

fromPrefixMatches :: Text -> [RunRecord] -> Either RunLookupFailure RunRecord
fromPrefixMatches t = \case
  [] -> Left (NoRunMatching t)
  [r] -> Right r
  _ -> Left (AmbiguousRunPrefix t)

fromRunFzfResult :: FzfResult RunRecord -> Either RunLookupFailure RunRecord
fromRunFzfResult = \case
  FzfSelected r -> Right r
  FzfNoMatch -> Left RunPickerNoMatch
  FzfCancelled -> Left RunPickerCancelled
  FzfError e -> Left (RunPickerFailed e)

-- | The message for a failure, or 'Nothing' for a silent cancel. The caller
--   prints it on stderr and exits 1.
renderRunLookupFailure :: RunLookupFailure -> Maybe Text
renderRunLookupFailure = \case
  NoRunMatching t -> Just ("no run matching " <> t)
  AmbiguousRunPrefix t -> Just ("ambiguous id prefix " <> t)
  NoRunsRecorded -> Just "shiki: no runs recorded yet"
  RunPickerNoMatch -> Just "shiki: no run matches the picker query"
  RunPickerCancelled -> Nothing
  RunFzfUnavailable -> Just "shiki: no run id given and fzf is not available"
  RunPickerFailed e -> Just ("shiki: fzf: " <> e)
  RunLookupPersistenceError e -> Just ("shiki: persistence error: " <> e)
```

`first` comes from `Data.Bifunctor`; `<&>` from `Shiki.Prelude`. The module still must not
import `Shiki.Cli.Runs`.

**File `shiki-cli/src/Shiki/Cli/Runs.hs`.** `runRuns` receives the function that acquires
the environment, so it can decide the target first:

```haskell
runRuns :: ((CliEnv -> IO ()) -> IO ()) -> RunsCommand -> IO ()
runRuns withEnv = \case
  RunsList mService limit -> withEnv (\env -> doList env mService limit)
  RunsShow mId -> withRun withEnv readRunOpts mId (const doShow)
  RunsLogs mId -> withRun withEnv readRunOpts mId (const doLogs)
  RunsError mId -> withRun withEnv readRunOpts mId (const doError)
  RunsAnalyze mId override ->
    withRun withEnv analyzeRunOpts mId (\env r -> doAnalyze env r override)

-- | Decide the target before acquiring the environment (so a missing fzf never
--   costs a database connection), then look the run up and run the handler.
withRun ::
  ((CliEnv -> IO ()) -> IO ()) ->
  FzfOpts ->
  Maybe Text ->
  (CliEnv -> RunRecord -> IO ()) ->
  IO ()
withRun withEnv opts mId body =
  runTarget opts mId >>= \case
    Left failure -> failLookup failure
    Right target ->
      withEnv $ \env ->
        lookupRun env target >>= either failLookup (body env)

failLookup :: RunLookupFailure -> IO a
failLookup failure = do
  mapM_ (TIO.hPutStrLn stderr) (renderRunLookupFailure failure)
  exitFailure
```

The handlers lose their lookup block and take the record: `doShow :: RunRecord -> IO ()`
prints `AesonPretty.encodePretty r`; `doLogs :: RunRecord -> IO ()` and
`doError :: RunRecord -> IO ()` print the log tail / summary (or their existing
`(no log captured)` / `(no summary)` lines); `doAnalyze :: CliEnv -> RunRecord -> Maybe
AnalyzerKind -> IO ()` keeps everything after its `[r] ->` branch. Delete `withResolved`,
`noMatch`, and `ambiguous`, and drop imports that become unused (for example
`findRunByPrefixStatement`). Update the `runRuns` haddock.

**File `shiki-cli/src/Shiki/Cli/Env.hs`.** Remove the `fzf` field, the `detectFzfConfig`
call, and the `Shiki.Cli.Fzf` import; update the module and `withCliEnv` comments ("probes
for fzf" goes away).

**File `shiki-cli/src/Shiki/Cli.hs`.** Pass the acquisition function:

```haskell
Runs runsOpts ->
  runRuns
    (\k -> withDbEnv (opts ^. #dbConnStr) (opts ^. #dbSchema) (opts ^. #envName) (\_ env -> k env))
    runsOpts
```

**Tests (`RunSpec`).** Add: `fromPrefixMatches "3f" []` is `Left (NoRunMatching "3f")`,
with one row is `Right row`, with two rows is `Left (AmbiguousRunPrefix "3f")`;
`fromRunFzfResult` maps each constructor as above, and in particular
`fromRunFzfResult FzfNoMatch == Left RunPickerNoMatch` (the regression test for the
misleading message); `renderRunLookupFailure RunPickerCancelled == Nothing` and the other
constructors render the strings above; `pickerRunTarget readRunOpts cfg` is
`Left RunFzfUnavailable` whenever `isFzfAvailable cfg` is false; `readRunOpts ^. #selectOne`
is `True` and `analyzeRunOpts ^. #selectOne` is `False`.

Acceptance: build warning-free, tests green, and rows 1–13 of the acceptance matrix hold.
The quickest proof of the ordering fix is row 10: with an unreachable `--db`, the fzf
message appears instead of a connection error.

### Milestone 9 — Same resolver shape for `service show`

Scope: give the service picker the same typed outcome and single renderer, which fixes its
misleading no-match message and moves its messages to stderr.

**File `shiki-cli/src/Shiki/Cli/Fzf/Selector/Service.hs`.** Replace `ServiceSelection`,
`defaultServiceOpts`, `selectService`, and `resolveServiceName` with:

```haskell
module Shiki.Cli.Fzf.Selector.Service
  ( ServiceTarget (..),
    ServiceLookupFailure (..),
    serviceOpts,
    serviceTarget,
    pickerServiceTarget,
    resolveService,
    listServiceNames,
    fromServiceFzfResult,
    renderServiceLookupFailure,
  )
where

data ServiceTarget
  = ServiceByName !Text
  | ServiceByPicker !FzfConfig

data ServiceLookupFailure
  = NoServiceConfigs
  | ServicePickerNoMatch
  | ServicePickerCancelled
  | ServiceFzfUnavailable
  | ServicePickerFailed !Text
  deriving stock (Eq, Show)

serviceOpts :: FzfOpts
serviceOpts = withPrompt "service> " <> withHeight "40%" <> withNoSort <> withSelectOne

serviceTarget :: Maybe Text -> IO (Either ServiceLookupFailure ServiceTarget)
serviceTarget (Just n) = pure (Right (ServiceByName n))
serviceTarget Nothing = pickerServiceTarget <$> detectFzfConfig

pickerServiceTarget :: FzfConfig -> Either ServiceLookupFailure ServiceTarget
pickerServiceTarget cfg
  | isFzfAvailable cfg = Right (ServiceByPicker cfg)
  | otherwise = Left ServiceFzfUnavailable

resolveService :: ServiceTarget -> IO (Either ServiceLookupFailure Text)
resolveService = \case
  ServiceByName n -> pure (Right n)
  ServiceByPicker cfg ->
    try @IOException (listServiceNames serviceConfigDir) >>= \case
      Left e -> pure (Left (ServicePickerFailed (Text.pack ("listDirectory failed: " <> show e))))
      Right [] -> pure (Left NoServiceConfigs)
      Right names ->
        fromServiceFzfResult
          <$> runFzf cfg serviceOpts [Candidate {display = n, value = n} | n <- names]

fromServiceFzfResult :: FzfResult Text -> Either ServiceLookupFailure Text
-- FzfSelected n -> Right n; FzfNoMatch -> ServicePickerNoMatch;
-- FzfCancelled -> ServicePickerCancelled; FzfError e -> ServicePickerFailed e

renderServiceLookupFailure :: ServiceLookupFailure -> Maybe Text
-- NoServiceConfigs      -> "shiki: no service configs found in services/"
-- ServicePickerNoMatch  -> "shiki: no service matches the picker query"
-- ServicePickerCancelled -> Nothing
-- ServiceFzfUnavailable -> "shiki: no service name given and fzf is not available"
-- ServicePickerFailed e -> "shiki: fzf: " <> e
```

`listServiceNames :: FilePath -> IO [Text]` is the old private `listEntries`, exported so
it can be tested (missing directory → `[]`; otherwise sorted `.dhall` basenames without the
extension).

**File `shiki-cli/src/Shiki/Cli.hs`.** Replace `serviceShowHandler` and drop the direct
`detectFzfConfig` import:

```haskell
serviceShowHandler :: Maybe Text -> IO ()
serviceShowHandler mName =
  serviceTarget mName >>= \case
    Left failure -> failService failure
    Right target -> resolveService target >>= either failService serviceShowOne

failService :: ServiceLookupFailure -> IO a
failService failure = do
  mapM_ (TIO.hPutStrLn stderr) (renderServiceLookupFailure failure)
  exitFailure
```

**File `shiki-cli/test/Shiki/Cli/Fzf/Selector/ServiceSpec.hs` (new).**
`fromServiceFzfResult FzfNoMatch == Left ServicePickerNoMatch`; each failure renders as
above; `pickerServiceTarget` is `Left ServiceFzfUnavailable` for an unavailable config;
`listServiceNames` on a temporary directory holding `b.dhall`, `a.dhall`, and `notes.txt`
returns `["a", "b"]`, and on a missing directory returns `[]`. Register it in the test
stanza and `Spec.hs`.

Acceptance: build warning-free, tests green, rows 14–19 of the acceptance matrix hold.

### Milestone 10 — Docs, help topic, changelog, retrospective

**File `docs/user/commands.md`.** Rewrite "Interactive selection (fzf)": the picker needs
`fzf` on `PATH` and an openable `/dev/tty` (a terminal stdin alone is not enough, and a
piped stdin or stdout is fine); the check happens before shiki connects to the database;
the run picker shows the 50 newest runs aligned under the `runs list` column titles; the
read-only pickers auto-select a lone candidate but `runs analyze` always asks and shows
what Enter does; every failure goes to stderr with exit 1 (list the messages from the
acceptance matrix); Esc and Ctrl-C cancel silently with exit 1. In the `runs show`,
`runs logs`, `runs error`, `runs analyze`, and `service show` entries, note that
`no run matching` / `ambiguous id prefix` are now on stderr.

**File `shiki-cli/data/help/runs.md`.** Under `QUERYING RUNS`, after the `analyze` line,
add a short paragraph: omit `<id>` on show, logs, error, or analyze to pick from the 50
newest runs in fzf (requires fzf and a terminal; see `docs/user/commands.md`). Keep lines
within the file's existing width so `shiki help runs` re-flows cleanly; `HelpSpec` must
stay green.

**File `CHANGELOG.md`.** Under `## [Unreleased]` add to `### Changed`: run and service
resolution errors (`no run matching`, `ambiguous id prefix`, picker messages) print on
stderr; the run picker shows aligned `runs list` columns under a title row; `runs analyze`
no longer auto-selects a lone run; a missing fzf is reported before connecting to the
database. Add a `### Fixed` entry: a picker query that matches nothing now says so instead
of reporting that no runs (or no service configs) exist.

Then run the full validation (below), record the evidence in this plan, fill in Outcomes &
Retrospective, and revisit the ADR distillation note.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/shiki` inside a `nix develop` shell.
Lines prefixed with `$` are commands; lines without are expected output excerpts. Every
commit carries both trailers:

```text
ExecPlan: docs/plans/10-integrate-fzf-for-interactive-id-selection.md
Intention: intention_01ksp9d2g6e7hb7cvm51402pe7
```

### Bootstrap

```bash
$ nix develop
$ just up                              # PostgreSQL, needed for the runs checks
$ cabal build all
$ cabal test shiki-cli-test            # baseline: All 62 tests passed
$ just shiki runs list -l 3            # seed runs with `just shiki run <service> -- echo hi` if empty
$ cabal run -v0 shiki -- runs list > /tmp/runs-list-before.txt   # baseline for M7
```

### M6

```bash
$ $EDITOR shiki-cli/src/Shiki/Cli/Fzf.hs
$ $EDITOR shiki-cli/src/Shiki/Cli/Fzf/Selector/Run.hs shiki-cli/src/Shiki/Cli/Fzf/Selector/Service.hs
$ $EDITOR shiki-cli/test/Shiki/Cli/FzfSpec.hs shiki-cli/test/Spec.hs shiki-cli/shiki-cli.cabal
$ cabal build all 2>&1 | grep -i warning     # expect no output
$ cabal test shiki-cli-test
```

Expected excerpt:

```text
  Shiki.Cli.Fzf
    runFzf returns the line fzf printed:                      OK
    exit 1 is FzfNoMatch:                                     OK
    exit 130 is FzfCancelled:                                 OK
    …
```

Commit `refactor(shiki-cli): EP-10 M6 — harden the fzf core and test it with a fake fzf`.

### M7

```bash
$ $EDITOR shiki-cli/src/Shiki/Cli/Runs/Format.hs shiki-cli/src/Shiki/Cli/Runs.hs
$ $EDITOR shiki-cli/src/Shiki/Cli/Fzf/Selector/Run.hs
$ $EDITOR shiki-cli/test/Shiki/Cli/Fixtures.hs shiki-cli/test/Shiki/Cli/Runs/FormatSpec.hs
$ $EDITOR shiki-cli/test/Shiki/Cli/Fzf/Selector/RunSpec.hs shiki-cli/test/Spec.hs shiki-cli/shiki-cli.cabal
$ cabal test shiki-cli-test
$ cabal run -v0 shiki -- runs list > /tmp/runs-list-after.txt
$ diff /tmp/runs-list-before.txt /tmp/runs-list-after.txt     # expect no output
$ just shiki runs show                                          # title row above aligned rows
```

If fzf's title row does not sit exactly above the columns, record the observation in
Surprises and fall back to passing the titles with `withHeader` (unaligned but labelled).

Commit `refactor(shiki-cli): EP-10 M7 — share run formatting with the picker`.

### M8

```bash
$ $EDITOR shiki-cli/src/Shiki/Cli/Fzf/Selector/Run.hs shiki-cli/src/Shiki/Cli/Runs.hs
$ $EDITOR shiki-cli/src/Shiki/Cli/Env.hs shiki-cli/src/Shiki/Cli.hs
$ $EDITOR shiki-cli/test/Shiki/Cli/Fzf/Selector/RunSpec.hs
$ cabal build all 2>&1 | grep -i warning     # expect no output
$ cabal test shiki-cli-test
$ env PATH=/usr/bin "$(cabal list-bin shiki)" --db postgresql://127.0.0.1:1/none runs show </dev/null; echo "exit=$?"
shiki: no run id given and fzf is not available
exit=1
$ cabal run -v0 shiki -- runs show zzzzzzzz >/dev/null; echo "exit=$?"
no run matching zzzzzzzz
exit=1
$ just shiki runs show        # type zzzz, press Enter
shiki: no run matches the picker query
$ just shiki runs analyze     # header warning shown; no auto-select even with one run
```

Commit `fix(shiki-cli): EP-10 M8 — resolve runs to records and report picker outcomes precisely`.

### M9

```bash
$ $EDITOR shiki-cli/src/Shiki/Cli/Fzf/Selector/Service.hs shiki-cli/src/Shiki/Cli.hs
$ $EDITOR shiki-cli/test/Shiki/Cli/Fzf/Selector/ServiceSpec.hs shiki-cli/test/Spec.hs shiki-cli/shiki-cli.cabal
$ cabal test shiki-cli-test
$ env PATH=/usr/bin "$(cabal list-bin shiki)" service show </dev/null; echo "exit=$?"
shiki: no service name given and fzf is not available
exit=1
$ bin="$(cabal list-bin shiki)"
$ (cd /tmp && "$bin" service show >/dev/null; echo "exit=$?")
shiki: no service configs found in services/
exit=1
```

The last command runs, from a terminal, in a directory without `services/`; the message
still appears with stdout discarded, which proves it now goes to stderr. Commit `fix(shiki-cli): EP-10 M9 — typed outcomes for the service picker`.

### M10

```bash
$ $EDITOR docs/user/commands.md shiki-cli/data/help/runs.md CHANGELOG.md
$ nix fmt
$ git status --short           # only the files you edited
$ cabal test all
$ cabal run -v0 shiki -- help runs | grep -i fzf
```

Commit `docs(shiki): EP-10 M10 — document the revised picker behaviour`.


## Validation and Acceptance

### Behavioural acceptance matrix (after M10)

The plan is accepted when **every row** holds. Rows marked *changed* differ from
milestones 1–5. Rows 4–9 and 11–13 need a reachable database with at least one recorded
run (at least two where stated).

| # | Inputs | Observed | Exit |
|---|--------|----------|------|
| 1 | `shiki runs show <unambiguous-prefix>` | Pretty-prints the row's JSON. | 0 |
| 2 | `shiki runs show <ambiguous-prefix>` | `ambiguous id prefix <prefix>` on **stderr** (*changed*: was stdout). | 1 |
| 3 | `shiki runs show <nonexistent-prefix>` | `no run matching <prefix>` on **stderr** (*changed*). | 1 |
| 4 | `shiki runs show` (no arg, ≥2 runs) | Picker: `run> ` prompt, column-title row, aligned rows (*changed*); Enter prints the row's JSON. | 0 |
| 5 | `shiki runs show` (no arg, exactly 1 run) | No picker drawn; the JSON prints immediately. | 0 |
| 6 | `shiki runs show` (no arg, empty `runs`) | `shiki: no runs recorded yet` on stderr (*changed*: was `(no runs recorded yet)` on stdout). | 1 |
| 7 | `shiki runs show` (no arg) + Esc or Ctrl-C | Nothing printed, no traceback. | 1 |
| 8 | `shiki runs show` (no arg), type `zzzz`, Enter | `shiki: no run matches the picker query` on stderr (*changed*: was `(no runs recorded yet)`). | 1 |
| 9 | `shiki runs logs` / `runs error` (no arg) | Same picker and auto-select as rows 4–5; Enter prints the log tail / summary. | 0 |
| 10 | `env PATH=/usr/bin shiki --db postgresql://127.0.0.1:1/none runs show </dev/null` | `shiki: no run id given and fzf is not available`; **no connection error** (*changed*: the database was contacted first). | 1 |
| 11 | `shiki runs analyze` (no arg, exactly 1 run) | Picker **is** drawn with the header "Enter re-runs analysis on the selected run and overwrites its stored error summary" (*changed*: was auto-selected). | 0 after Enter |
| 12 | `shiki runs analyze` (no arg) + Enter | Analysis runs for the chosen row and prints `analyzed run <id> with <source>: …`. | 0 |
| 13 | `shiki runs list` | Byte-identical to before M7; `(no runs recorded yet)` on stdout with exit 0 for an empty table. | 0 |
| 14 | `shiki service show <existing-name>` | Prints JSON. | 0 |
| 15 | `shiki service show <missing-name>` | Dhall load error on stderr. | non-zero |
| 16 | `shiki service show` (no arg) | Picker over `services/*.dhall` with ≥2 files; a lone file prints immediately. | 0 |
| 17 | `shiki service show` (no arg, no `services/`) | `shiki: no service configs found in services/` on stderr (*changed*: was stdout). | 1 |
| 18 | `env PATH=/usr/bin shiki service show </dev/null` | `shiki: no service name given and fzf is not available`. | 1 |
| 19 | `shiki service show` (no arg), type `zzzz`, Enter | `shiki: no service matches the picker query` (*changed*). | 1 |
| 20 | `shiki run <svc> -- echo hi` | Unchanged — no fzf integration on `shiki run`. | 0 / non-zero |
| 21 | `shiki runs show --help`, `shiki service show --help` | `[ID]` / `[NAME]` with "opens an fzf picker if omitted". | 0 |

### Test commands

```bash
cd /Users/shinzui/Keikaku/bokuno/shiki
cabal test shiki-cli-test    # CLI suite: Shiki.Cli.Fzf, Shiki.Cli.Runs.Format, and both selector specs
cabal test all               # every suite; shiki-core's persistence tests start throwaway Postgres instances
```

The unit tests cover everything that is not an interactive terminal: the subprocess
plumbing and exit-code mapping (via the fake fzf), formatting and alignment, prefix-match
and fzf-result mapping, message rendering, option contents, and service enumeration. The
interactive rows (4–9, 11, 12, 16, 19) need a person at a terminal.

### Evidence captured on 2026-09-11 (`HEAD` `d0686f7`, before milestones 6–10)

```text
$ cabal run -v0 shiki -- runs show --help
Usage: shiki runs show [ID]

  Show one run by id (UUID or unambiguous prefix; uses fzf if omitted)

Available options:
  ID                       Run id (UUID or unambiguous prefix); opens an fzf
                           picker if omitted
  -h,--help                Show this help text

$ env PATH=/usr/bin "$(cabal list-bin shiki)" service show </dev/null
shiki: no service name given and fzf is not available
$ echo $?
1

$ cabal test -v0 shiki-cli-test
  …
All 62 tests passed (4.75s)
```


## Idempotence and Recovery

No migrations, schema changes, or destructive operations.

- Builds, tests, and `nix fmt` are idempotent. The fake-fzf tests write only inside
  temporary directories that `withSystemTempDirectory` deletes.
- Pickers are read-only (`SELECT … ORDER BY started_at DESC LIMIT 50`, or a directory
  listing); cancelling leaves no trace. Like every database-backed shiki command, the `runs`
  commands apply pending migrations once the environment is acquired, which after M8 happens
  only when a target was chosen.
- `runs analyze` writes through `updateErrorSummaryStatement`, an `UPDATE` keyed on `id`,
  so repeating it on the same row converges to the same state. After M8 it always asks
  before running.

### Rollback

Milestones 6–10 are one commit each and build on one another; revert them newest first
(`git revert <M10> <M9> <M8> <M7> <M6>`). Reverting M8 alone after M9 does not compile,
because M9's `Shiki.Cli` changes sit next to M8's. Milestones 1–5 can no longer be reverted
commit by commit, because later refactors rewrote their files; removing the feature
entirely means making the five positionals required again, deleting the
`shiki-cli/src/Shiki/Cli/Fzf*` modules and their tests and cabal entries, and calling the
handlers directly. There is no persisted state to roll back.


## Interfaces and Dependencies

### Libraries used

| Library | Why |
|---------|-----|
| `process` (`^>=1.6`) | `createProcess` / `waitForProcess` / `CreateProcess` with `delegate_ctlc` |
| `containers` (`^>=0.7`) | `Data.Map.Strict` for the index-to-value lookup |
| `directory`, `filepath` (existing) | `findExecutable`, `listDirectory`, `.dhall` filtering; test permissions |
| `text`, `time` (existing) | display text and start-time formatting |
| `hasql`, `hasql-pool` (existing) | `Pool.use` + `Session.statement` for the candidate and prefix queries |
| `generic-lens`, `lens` (existing) | `^. #field` access and `& #field ?~ v` updates |
| `temporary` (existing test dep) | temporary directories for the fake fzf and service listing tests |

No new dependencies and no flake changes.

### External system: fzf

- Binary: `fzf`, 0.40 or newer (the dev shell has 0.74.1); `--header-lines` and `-1` are
  long-standing flags.
- Invocation: `--with-nth=2..` always; `-1` when `selectOne`; `--header-lines=1` when
  `headerRow`; `--prompt`, `--header`, `--height`, `--ansi`, `--no-sort` per `FzfOpts`.
- Streams: stdin piped (`-\t<titles>` first when a header row is set, then
  `"<i>\t<display>"` lines); stdout piped (the accepted line); stderr inherited (fzf's
  error messages). fzf draws on and reads keys from the terminal via `/dev/tty`.
- Exit codes: 0 accepted, 1 no match, 130 Esc or Ctrl-C (delivered to fzf by
  `delegate_ctlc = True`), other values are errors.

### Module signatures after M10

`Shiki.Cli.Fzf`:

```haskell
data FzfConfig = FzfConfig
  { binary :: !FilePath,
    available :: !Bool,
    ttyAvailable :: !Bool
  }
  deriving stock (Generic, Eq, Show)

detectFzfConfig :: IO FzfConfig
isFzfAvailable :: FzfConfig -> Bool

data FzfOpts = FzfOpts
  { prompt :: !(Maybe Text),
    header :: !(Maybe Text),
    height :: !(Maybe Text),
    ansi :: !Bool,
    noSort :: !Bool,
    selectOne :: !Bool,
    headerRow :: !(Maybe Text)
  }
  deriving stock (Generic, Eq, Show)

instance Semigroup FzfOpts
instance Monoid FzfOpts

withPrompt, withHeader, withHeight, withHeaderRow :: Text -> FzfOpts
withAnsi, withNoSort, withSelectOne :: FzfOpts

data Candidate a = Candidate {display :: !Text, value :: !a}
  deriving stock (Generic, Functor)

data FzfResult a = FzfSelected !a | FzfNoMatch | FzfCancelled | FzfError !Text
  deriving stock (Eq, Show, Functor)

runFzf :: FzfConfig -> FzfOpts -> [Candidate a] -> IO (FzfResult a)
```

`Shiki.Cli.Env.CliEnv` has exactly `pool` and `client`.

`Shiki.Cli.Runs.Format`:

```haskell
runTableHeader :: [Text]
runColumns :: RunRecord -> [Text]
humanDuration :: Int -> Text
computeWidths :: [[Text]] -> [Int]
formatRow :: [Int] -> [Text] -> Text
renderTable :: [RunRecord] -> Text
```

`Shiki.Cli.Fzf.Selector.Run`:

```haskell
data RunTarget = RunByPrefix !Text | RunByPicker !FzfConfig !FzfOpts
data RunLookupFailure
  = NoRunMatching !Text | AmbiguousRunPrefix !Text | NoRunsRecorded
  | RunPickerNoMatch | RunPickerCancelled | RunFzfUnavailable
  | RunPickerFailed !Text | RunLookupPersistenceError !Text

readRunOpts, analyzeRunOpts :: FzfOpts
formatRunCandidates :: [RunRecord] -> (Text, [Candidate RunRecord])
runTarget :: FzfOpts -> Maybe Text -> IO (Either RunLookupFailure RunTarget)
pickerRunTarget :: FzfOpts -> FzfConfig -> Either RunLookupFailure RunTarget
lookupRun :: CliEnv -> RunTarget -> IO (Either RunLookupFailure RunRecord)
fromPrefixMatches :: Text -> [RunRecord] -> Either RunLookupFailure RunRecord
fromRunFzfResult :: FzfResult RunRecord -> Either RunLookupFailure RunRecord
renderRunLookupFailure :: RunLookupFailure -> Maybe Text
```

`Shiki.Cli.Runs`: `RunsCommand` is unchanged;
`runRuns :: ((CliEnv -> IO ()) -> IO ()) -> RunsCommand -> IO ()`.

`Shiki.Cli.Fzf.Selector.Service`:

```haskell
data ServiceTarget = ServiceByName !Text | ServiceByPicker !FzfConfig
data ServiceLookupFailure
  = NoServiceConfigs | ServicePickerNoMatch | ServicePickerCancelled
  | ServiceFzfUnavailable | ServicePickerFailed !Text

serviceOpts :: FzfOpts
serviceTarget :: Maybe Text -> IO (Either ServiceLookupFailure ServiceTarget)
pickerServiceTarget :: FzfConfig -> Either ServiceLookupFailure ServiceTarget
resolveService :: ServiceTarget -> IO (Either ServiceLookupFailure Text)
listServiceNames :: FilePath -> IO [Text]
fromServiceFzfResult :: FzfResult Text -> Either ServiceLookupFailure Text
renderServiceLookupFailure :: ServiceLookupFailure -> Maybe Text
```

The `Command` type in `Shiki.Cli` keeps `ServiceShow !(Maybe Text)`.

### Out of scope (explicitly deferred)

- Toggle / expect-keys, `--preview`, multi-select, a unified multi-entity picker, and a
  skip-entry candidate (§§5, 6, 8, 9, 10 of the reference doc) — no consumer.
- Status colours in the run picker — no request; `withAnsi` remains available.
- `shiki run [SERVICE]` selection — collides with the trailing `commandArgs` variadic.
- `shiki agent assist` run selection — needs its own design.
- Anchoring `services/` to the project root — cross-cutting (see the Decision Log).
- A picker for bare `shiki help` — declined by
  `docs/plans/16-adopt-haskell-jitsurei-conventions-for-the-initial-release.md`.


## Revision Notes

- 2026-09-11 — Refreshed the completed plan against `HEAD` `d0686f7` (commit `705d4f6`):
  code excerpts moved to the unprefixed field names from
  `docs/plans/16-adopt-haskell-jitsurei-conventions-for-the-initial-release.md`, Context
  and Orientation described the current tree, the design reference was cited by its
  `mori://` URI, the `nix fmt` Surprise was marked resolved, M2/M5 text claiming Esc exits 0
  was corrected to 1, and re-captured evidence was added. No code changed.

- 2026-09-11 — Reopened the plan after an architecture review, at the user's request, to
  address every finding. Added milestones 6–10: harden the fzf core (availability check,
  `IOException`, opt-in `-1`, header rows, fake-fzf tests); share run formatting with the
  picker; replace the text-returning run resolver with a two-phase target/lookup resolver
  that decides before acquiring the database, returns the `RunRecord`, and renders typed
  failures on stderr (fixing the misleading no-match message and `analyze` auto-selecting);
  give `service show` the same shape; update docs, the `runs` help topic, and the
  CHANGELOG. Added the review's evidence to Surprises (fzf exit codes, UI on the terminal
  rather than stderr, `/dev/tty` in agent shells, `--ansi` no-op, stdout errors, re-query
  scan, `-1` on analyze), new Decision Log entries (and marked the "detect in `withCliEnv`"
  and "inline `formatDuration`" decisions superseded), a rewritten acceptance matrix
  marking changed rows, new interfaces, and rollback guidance. Also corrected two claims from
  the refresh: the run picker never rendered ANSI colours, and fzf does not draw on stderr.
  Condensed the Plan of Work text for completed milestones 1–5, whose full excerpts are
  superseded by milestones 6–10.
