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

**Status (2026-09-11): complete.** All five milestones landed on 2026-05-28 (commits
`811c9db`, `818e39b`, `cd32aa6`, `aa111b2`, `d51aecc`). The plan was refreshed on
2026-09-11 against `HEAD` `d0686f7` so that its descriptions, code excerpts, and commands
match the current working tree after later plans renamed record fields, reformatted the
code, and restored `nix fmt`. See the revision notes at the bottom.


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
There was no in-binary affordance for "show me what's available, let me pick one."

After this plan, every read-only subcommand that takes an `ID` or `NAME` positional makes
that positional optional, and when it is omitted shiki opens an `fzf` picker populated from
the canonical source of truth (the `runs` table in PostgreSQL for runs, the `services/`
directory for service configs). `fzf` is a terminal fuzzy finder: it reads a list of lines,
lets the operator type to filter them, and prints the chosen line. When `fzf` is unavailable
(not on `PATH`, or neither stdin nor `/dev/tty` gives shiki an interactive keyboard), shiki
exits with a clear "argument required" error. The non-interactive, transcript-driven UX
(`shiki runs show <prefix>`) is unchanged.

The concrete affordances:

- `shiki runs show` (no arg) → fzf picker of the 50 most recent runs; pressing Enter on a
  row prints the same JSON `shiki runs show <full-uuid>` prints for that row.
- `shiki runs logs` (no arg) → same picker, prints the log tail of the chosen row.
- `shiki runs error` (no arg) → same picker, prints the error summary of the chosen row.
- `shiki runs analyze` (no arg) → same picker, then runs the analyzer for the chosen row.
- `shiki service show` (no arg) → fzf picker populated by scanning `services/*.dhall`,
  pretty-prints the chosen config.
- `shiki runs show <prefix>` and friends are **unchanged** — the positional remains a
  parseable prefix, fzf is only invoked when the positional is absent.

The runs picker reads from whichever database the invocation is routed to. Since
`docs/plans/13-route-run-storage-to-the-active-environment-database.md` landed, that is the
database of the active `shiki.dhall` environment (or `--db`, `SHIKI_DATABASE_URL`,
`PG_CONNECTION_STRING`, in that order of fallback), so `shiki --env prod runs show` picks
from production runs.

A reader can see the change working by:

1. Entering the dev shell with `nix develop` and building with `cabal build all`.
2. Starting PostgreSQL (`just up`) and pre-seeding at least two recorded runs
   (`just shiki run <service> -- echo hello` twice).
3. Running `just shiki runs show` (no id). An fzf picker appears with the recent runs; the
   prompt is `run> `, the height is `40%`, and ANSI status colours render. Pressing Enter
   on a row prints the same JSON `shiki runs show <prefix>` prints.
4. Running `just shiki service show` (no name). An fzf picker appears with one entry per
   `services/*.dhall` file; pressing Enter on a row prints the parsed JSON. If exactly one
   file exists, fzf's `-1` flag selects it without drawing the picker.
5. Running the binary with a `PATH` that does not contain `fzf`:
   `env PATH=/usr/bin "$(cabal list-bin shiki)" service show </dev/null`. The CLI prints
   `shiki: no service name given and fzf is not available` and exits 1 — no picker, no
   crash. The `runs` equivalent prints `shiki: no run id given and fzf is not available`,
   but only once the database is reachable, because the `runs` commands connect and
   migrate before any handler runs.

The scope is deliberately limited to read paths. `shiki run SERVICE -- ARG...` is **not**
changed by this plan: making `SERVICE` optional collides with the trailing positional
`commandArgs` list and would require a parser refactor that the user did not ask for. See
the Decision Log for the reasoning.


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
      error), print the matching message and exit 1 per the table in
      "Validation and Acceptance". [2026-05-28]
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

### Post-completion refresh (2026-09-11, `HEAD` `d0686f7`)

- [x] Re-read every file this plan touches and reconcile the plan's descriptions and code
      excerpts with the current tree (unprefixed record fields read through generic-lens
      labels, fourmolu layout, new `Command` constructors, environment-routed database).
      [2026-09-11]
- [x] Re-verify behaviour: `cabal build shiki-cli:exe:shiki shiki-cli-test` succeeds;
      `cabal test shiki-cli-test` reports `All 62 tests passed`, including the three
      `Shiki.Cli.Fzf.Selector.Run` cases; `runs show --help` and `service show --help`
      render `[ID]` / `[NAME]` with the fzf hint; the no-fzf path prints
      `shiki: no service name given and fzf is not available` and exits 1. [2026-09-11]
- [x] Confirm the fzf modules pass `fourmolu --mode check` and that the flake now exposes
      a `formatter` output (`treefmt`), closing the `nix fmt` follow-up. [2026-09-11]
- [x] Replace the stale absolute path to the design reference with its canonical
      `mori://` URI. [2026-09-11]
- [x] ADR distillation pass: no ADR corpus exists (`docs/adr/` is absent and `mori.dhall`
      declares no ADR bundle), so no ADR was written; candidate decisions are listed in
      Outcomes & Retrospective. [2026-09-11]
- [ ] Not re-verified in this refresh: the interactive `runs` picker transcripts (the
      local PostgreSQL was not running) and `nix flake check` (it builds the whole
      project through Nix). Re-run both when next touching this area.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-05-28: First M3 attempt tried to re-export `humanDuration` from
  `Shiki.Cli.Runs` for re-use by `Shiki.Cli.Fzf.Selector.Run`, but that produces a
  module cycle (`Runs` → `Selector.Run` for `resolveRunId`, `Selector.Run` → `Runs`
  for `humanDuration`). Resolution: inline a private `formatDuration` in the selector
  module — the helper is 10 lines and there is no other consumer of the renamed
  version. The selector module now has zero compile-time dependency on
  `Shiki.Cli.Runs`, which is the cleaner direction anyway.

- 2026-05-28: `cabal test shiki-cli-test` started failing intermittently after M3
  with the captured stdout of `Shiki.Cli.Agent.LaunchSpec` returning
  `"OKPROMPT"` instead of `"PROMPT"`. Root cause is pre-existing: `captureStdout`
  in `LaunchSpec` does an OS-level `hDuplicateTo stdout` redirect, which is
  fundamentally racy against any concurrent tasty test that prints — adding the
  three new `RunSelectorSpec` cases made the race fire reliably. Fix:
  `localOption (NumThreads 1)` on the top-level test tree in
  `shiki-cli/test/Spec.hs`. Verified stable across 5 consecutive runs. (Still in
  place on 2026-09-11.)

- 2026-05-28: The plan's M5 step "run `nix fmt`" was not executable against the flake
  at the time — `flake.nix` did not define a `formatter` output, so `nix fmt` exited
  with `does not provide attribute 'formatter.aarch64-darwin'`. `just fmt` wraps the
  same command. Running `cabal-fmt --inplace` directly rewrote `shiki-cli.cabal` into a
  style that diverged sharply from `shiki-core.cabal` (leading-comma, aligned keys), so
  the cabal reformat was reverted and new Haskell modules followed the style of the
  surrounding code by hand.
  **Update 2026-09-11:** resolved by later flake work. Commit `162b0f3` moved the flake to
  flake-parts and commit `568a56f` adopted `nix/treefmt.nix`, which wires `nix fmt` to
  treefmt running fourmolu (Haskell, configured by `fourmolu.yaml`), cabal-gild (cabal
  files, replacing cabal-fmt), and nixpkgs-fmt. `nix eval --raw
  .#formatter.aarch64-darwin.name` now prints `treefmt`. Commit `78d2189` reformatted the
  fzf modules with fourmolu and commit `1aa1fb3` reformatted the cabal files with
  cabal-gild; `fourmolu --mode check` on the fzf modules exits 0.

- 2026-09-11: The design reference this plan was written from moved inside its
  repository, from `cli/fzf-integration.md` to `patterns/cli/fzf-integration.md`, so
  the absolute checkout path the plan originally cited no longer existed. Its canonical,
  location-independent identity is
  `mori://shinzui/haskell-jitsurei/docs/cli-fzf-integration` (`mori path` resolves it).
  The plan now cites only the URI.

- 2026-09-11: The `runs` pickers cannot report "fzf is not available" without a
  database. `runCli` routes `Runs` through `withDbEnv`, which resolves a connection
  string, acquires the pool, and runs migrations (`Shiki.Cli.Env.withCliEnv`) before
  `runRuns` ever calls `resolveRunId`. With the database down, `shiki runs show` fails on
  the connection first. `service show` has no such dependency, which is why the
  2026-09-11 no-fzf check used it.

- 2026-09-11: This checkout's `services/` directory holds a single file
  (`services/mls-service-v2.dhall`). Because `runFzf` always passes `-1`
  (`--select-1`), `shiki service show` with no name prints that config straight away
  without drawing the picker. That is intended behaviour, but it surprises anyone
  expecting to see the picker on a one-service project.


## Decision Log

Record every decision made while working on the plan.

- Decision: Adopt the architecture from the haskell-jitsurei fzf-integration cookbook
  (`mori://shinzui/haskell-jitsurei/docs/cli-fzf-integration`) verbatim for the core
  (`Shiki.Cli.Fzf`) and the entity selector pattern (`Shiki.Cli.Fzf.Selector.*`).
  Rationale: The reference document is the user-supplied design source; the patterns it
  describes (index-based selection, monoidal options, `delegate_ctlc = True`, lazy stdout
  read + `waitForProcess`, `/dev/tty` fallback) all directly answer the problems shiki
  would otherwise have to rediscover.
  Date: 2026-05-27.

- Decision: Skip the toggle / expect-keys / multi-select / preview features described in
  sections 6, 8, 9, 10 of the reference document. Ship only `runFzf` (single-select,
  `--with-nth=2..`, `-1` auto-select).
  Rationale: No shiki subcommand needs them yet. The user's example list is
  `runs analyze | show | error` — all single-selection. Adding the toggle loop or
  `--preview` infrastructure would expand surface area without a current consumer.
  Future plans can layer in `FzfOpts` extensions because they're a Monoid.
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
  `shiki run -- echo hi` parse as `service = Just "echo"`, `commandArgs = ["hi"]` — the
  opposite of what an operator would expect. Fixing this would require a parser refactor
  (likely a `--service` flag or two-phase argument parsing) that is out of scope for "wire
  fzf where appropriate". Recorded as a follow-up.
  Date: 2026-05-27.

- Decision: Make the fzf picker for `runs *` show the **50 most recent runs** (not the
  default `runs list` limit of 20).
  Rationale: A picker with fuzzy-search is more useful with more candidates, and 50 rows
  still fits in a `40%`-height fzf pane on a typical terminal. The number is the constant
  `selectorRowLimit` in `Shiki.Cli.Fzf.Selector.Run`; bump it in a later plan if
  operators ask.
  Date: 2026-05-27.

- Decision: Detect fzf availability **once per CLI invocation**, inside `withCliEnv`, and
  thread the resulting `FzfConfig` through `CliEnv`.
  Rationale: §1 of the reference doc explicitly recommends this. Detecting per-call would
  let a slow `findExecutable` or `/dev/tty` open get hit multiple times in subcommands
  that may later compose two selectors (e.g. a future "pick service then pick run"
  flow). One snapshot is also easier to mock in tests.
  Date: 2026-05-27.

- Decision: When fzf is unavailable AND the positional is omitted, exit non-zero with a
  helpful message rather than degrading to "show the most recent run" or similar.
  Rationale: Silent fallbacks hide misconfiguration. The operator's `nix develop` shell
  ships `fzf`, so unavailability in practice means the binary is being driven from a
  scripted / piped environment, where a clear error is preferable to a guess.
  Date: 2026-05-27.

- Decision: Place fzf modules under `Shiki.Cli.Fzf*` in `shiki-cli`, not in `shiki-core`.
  Rationale: `shiki-core` is the library used by the CLI binary and by future programmatic
  consumers (e.g. the agent assist context builder). fzf is strictly an interactive CLI
  affordance — it has no meaning in a library context — so it belongs in `shiki-cli`.
  Date: 2026-05-27.

- Decision: Inline a private `formatDuration` in `Shiki.Cli.Fzf.Selector.Run` instead of
  exporting `humanDuration` / `renderRow` from `Shiki.Cli.Runs` as M2 originally
  proposed.
  Rationale: `Shiki.Cli.Runs` imports the selector (for `resolveRunId`), so the selector
  importing `Shiki.Cli.Runs` back is a module cycle. Ten duplicated lines are cheaper than
  a new shared module with one consumer. See Surprises (2026-05-28).
  Date: 2026-05-28.

- Decision: Esc (fzf exit 130 or a no-match exit) cancels silently and shiki exits **1**,
  not 0.
  Rationale: The implementation routes every "no id resolved" outcome through
  `exitFailure`, so a script that wraps `shiki runs show` can tell "nothing was shown"
  apart from success, which matches Unix convention for cancelled interactive input.
  Early drafts of M2 and M5 said Esc exits 0; those passages were inconsistent with the
  acceptance matrix and with the shipped code and have been corrected.
  Date: 2026-05-28 (reconciled in the plan text on 2026-09-11).

- Decision: When refreshing this completed plan, describe the interfaces as they exist in
  the current tree (unprefixed fields such as `binary`, `prompt`, `display`, read with
  generic-lens `^. #field`) rather than the prefixed names the milestones originally
  shipped (`fzfBinary`, `fzfPrompt`, `candidateDisplay`).
  Rationale: A reader of a living plan compares it against the working tree. The rename
  was done by `docs/plans/16-adopt-haskell-jitsurei-conventions-for-the-initial-release.md`
  and changed no behaviour; the old names are kept in this Decision Log and in the
  revision notes so the history is still traceable.
  Date: 2026-09-11.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

### 2026-05-28 — All milestones complete

**Outcome.** All five milestones land green; `cabal build all` and
`cabal test shiki-cli-test` both pass; `shiki runs show / logs / error /
analyze` and `shiki service show` accept the positional as optional and
fall through to an `fzf` picker; `--help` for each surfaces the
`[ID]`/`[NAME]` syntax and the picker behaviour. The non-interactive
positional path is byte-for-byte unchanged.

**What matched the plan.**

- The 5-milestone split (core / run-selector / wire-runs / service /
  docs) sequenced cleanly; every milestone left the build green.
- The "index-prefix on stdin, `--with-nth=2..` on argv" trick from the
  reference doc worked first try.
- `delegate_ctlc = True` + `std_err = Inherit` gave clean Ctrl-C
  semantics without any extra signal handling.
- `detectFzfConfig` once per `withCliEnv` keeps the env snapshot
  immutable and makes the resolver pure-by-construction.

**What deviated.**

- The plan called for re-exporting `humanDuration` from
  `Shiki.Cli.Runs`; that created a module cycle, so the helper is
  inlined in `Selector.Run` instead. Recorded in Surprises.
- `nix fmt` did not exist in the flake then, so the M5 "format pass" step
  was satisfied by hand-matching surrounding code style. The
  `cabal-fmt` output diverged from the in-repo cabal style and was
  reverted.
- Pre-existing race in `LaunchSpec` started firing reliably once the
  test count crossed 30; fixed in-place via `localOption (NumThreads
  1)` on the test tree.

**Gaps / follow-ups** as recorded at completion:

- `shiki run [SERVICE]` interactive selection (parser refactor).
- `shiki agent assist` selection ("attach to run X" affordance).
- Restore a `nix fmt` formatter output to the flake.

### 2026-09-11 — Refresh against `HEAD` `d0686f7`

**Outcome.** The feature still behaves as specified. Ten later commits touched the fzf
modules, `CliEnv`, the test tree, or `docs/user/commands.md`, none of them changing the
picker's behaviour: project configuration, environment-routed databases, `config init`,
and version output (`1961fef`, `d2e1e4e`, `0206a92`, `0cd89bd`, `ef61ae3`), the
conventions refactor from
`docs/plans/16-adopt-haskell-jitsurei-conventions-for-the-initial-release.md` (`78d2189`
fourmolu layout, `5825569` common cabal stanza, `5c061f8` per-module generic-lens label
imports, `e51c138` unprefixed record fields), and `3e2ed64` shell completions. The
`shiki-cli` test suite passes (62 tests), help output and the no-fzf error path were
re-observed, and the fzf modules are fourmolu-clean. The plan text now matches the tree.

**Follow-up status.**

- Restore `nix fmt`: **done** by the flake migration (`162b0f3`, `568a56f`); `nix fmt`
  runs treefmt.
- `shiki run [SERVICE]` interactive selection: still open; the parser still ends in the
  trailing `-- ARG...` list.
- `shiki agent assist` run selection: still open.
- New: the curated help topic for runs (`shiki-cli/data/help/runs.md`, shown by
  `shiki help runs`) does not mention the picker; only `docs/user/commands.md` and the
  per-command `--help` text do.
- New: both the service picker and `serviceShowOne` read `services/` relative to the
  current directory, while `shiki.dhall` is found by walking up from it. Running
  `shiki service show` from a subdirectory of a project therefore reports
  `(no service configs found in services/)`. This matches `shiki run`'s `--config-dir`
  default of `services`, so fixing it belongs to a plan that anchors all service lookups
  to the project root rather than to this one.

**ADR distillation.** The repository has no ADR corpus: `docs/adr/` does not exist and
`mori.dhall` declares no ADR bundle, so, per the ADR workflow, no corpus was created as an
incidental plan edit. When the project adopts ADRs, three decisions from this plan are
durable enough to promote: interactive affordances such as fzf live in `shiki-cli`, never
`shiki-core`; an omitted positional resolves as positional > fzf picker > explicit error,
with no silent fallback; and environment probes (fzf, terminals) run once per invocation
and travel in `CliEnv`.


## Context and Orientation

**The repository.** `shiki` is a Haskell CLI (a cabal multi-package project) that runs
one-off Kubernetes Jobs for microservices and records each run in PostgreSQL. The two
packages are:

- `shiki-core/` — domain types, persistence (hasql), Kubernetes runner, analyzer
  backends, project configuration. It is the library that the CLI binary and any future
  programmatic consumer use.
- `shiki-cli/` — the optparse-applicative parser and command handlers; the
  `executable shiki` defined in `shiki-cli/shiki-cli.cabal` simply calls
  `Shiki.Cli.runCli` from `shiki-cli/app/Main.hs`.

The build is driven from a `Justfile` at the repository root (`just build` runs
`cabal build all`, `just test` runs `cabal test all`, `just shiki <args>` runs
`cabal run shiki -- <args>`, `just fmt` runs `nix fmt`) and a Nix flake built with
flake-parts whose modules live under `nix/`. PostgreSQL is started via process-compose
(`just up` / `just down`); `nix develop` exports `PG_CONNECTION_STRING` for the local
database, so `shiki` finds it without flags.

**Code conventions that affect every excerpt below.** Both packages share a `common`
cabal stanza (`GHC2024`, `DuplicateRecordFields`, `OverloadedLabels`,
`OverloadedStrings`, `MultilineStrings`). Record fields carry no type prefix (a field is
`binary`, not `fzfBinary`) and are read and updated through generic-lens labels:
`cfg ^. #available`, `mempty & #prompt ?~ t`. The lens operators come from
`Shiki.Prelude` (in `shiki-core/src/Shiki/Prelude.hs`), which every module imports; a
module that uses `#label` syntax must also write `import Data.Generics.Labels ()` itself,
because that import carries an orphan instance the prelude deliberately does not
re-export. Records that are read through labels must derive `Generic`. Haskell is
formatted with fourmolu (`fourmolu.yaml`) and cabal files with cabal-gild; `nix fmt` runs
both through treefmt (`nix/treefmt.nix`).

**Architecture Decision Records.** No relevant ADR exists. The repository has no
`docs/adr/` directory and `mori.dhall` declares no ADR bundle, so this plan carries all of
its design context itself.

**The CLI surface** lives in `shiki-cli/src/Shiki/Cli.hs`. Its top-level command type is:

```haskell
data Command
  = Run !RunOptions               -- shiki-cli/src/Shiki/Cli/Run.hs
  | Runs !RunsCommand             -- shiki-cli/src/Shiki/Cli/Runs.hs
  | ServiceShow !(Maybe Text)     -- handled in Shiki.Cli (Maybe since this plan)
  | Agent !AgentCommand           -- shiki-cli/src/Shiki/Cli/Agent.hs
  | Help !HelpCommand             -- shiki-cli/src/Shiki/Cli/Help.hs
  | Config !ConfigCommand         -- config show / config init
  | Completions !CompletionsShell -- shiki-cli/src/Shiki/Cli/Completions.hs
  deriving stock (Generic, Eq, Show)
```

When this plan was written only the first four constructors existed and `ServiceShow`
carried a plain `Text`. `runCli` dispatches `ServiceShow`, `Help`, `Completions`, and
`Config` directly, without touching the database. `Run`, `Runs`, and `Agent` go through
`withDbEnv`, which resolves a connection string (`--db`, then the active `shiki.dhall`
environment's `databaseUrl`, then `SHIKI_DATABASE_URL`, then `PG_CONNECTION_STRING`),
resolves the schema, and calls `Shiki.Cli.Env.withCliEnv`.

**`CliEnv`** (`shiki-cli/src/Shiki/Cli/Env.hs`) is the bundle threaded through every
database-backed handler. `withCliEnv` acquires the pool, runs pending migrations, loads the
Kubernetes client config, probes for fzf, and hands the bundle to the handler:

```haskell
data CliEnv = CliEnv
  { pool :: !Pool.Pool,
    client :: !ClientEnv,
    fzf :: !FzfConfig
  }
  deriving stock (Generic)
```

The `fzf` field was added by this plan. Handlers that do not use fzf ignore it.

**`RunsCommand`** (`shiki-cli/src/Shiki/Cli/Runs.hs`, lines 64-70) was, before this plan,
`RunsShow !Text`, `RunsLogs !Text`, `RunsError !Text`, and `RunsAnalyze !Text !(Maybe
AnalyzerKind)` alongside `RunsList !(Maybe Text) !Int`. This plan changed the four
single-id constructors to take `!(Maybe Text)`. Their handlers (`doShow`, `doLogs`,
`doError`, `doAnalyze`) all share one shape, unchanged by this plan:

```haskell
doShow :: CliEnv -> Text -> IO ()
doShow env idText = do
  matches <- runRead env findRunByPrefixStatement idText
  case matches of
    [] -> noMatch idText            -- prints "no run matching <id>", exit 1
    [r] -> BL8.putStrLn (AesonPretty.encodePretty r)
    _ -> ambiguous idText           -- prints "ambiguous id prefix <id>", exit 1
```

`findRunByPrefixStatement` (`shiki-core/src/Shiki/Persistence/Run.hs`, around line 251)
returns at most two rows whose `id::text LIKE $1 || '%'`. So a resolver only has to
produce a string that uniquely identifies one row, not necessarily a full UUID. After fzf
picks a row we hold the full UUID, so the existing handlers stay intact: the resolver
hands them the UUID as text and they re-query it. One extra round-trip per picked run is
fine for interactive code. `listRecentRunsStatement` (same file, around line 212) is what
`runs list` uses; the run selector reuses it with a 50-row limit.

**`service show`** is the smallest case. Its parser is `serviceSubparser` at the bottom
of `shiki-cli/src/Shiki/Cli.hs`, and its handler `serviceShowOne` loads
`"services/" <> NAME <> ".dhall"` relative to the current directory and prints it as JSON.
The service selector enumerates the same `services/*.dhall`, showing each basename without
its extension. `--config-dir` is a flag of `shiki run` only, so the selector hard-codes
`"services"`, consistent with the handler.

**Terminology used in this plan.**

- **fzf**: the junegunn/fzf terminal fuzzy finder (0.74.1 on the author's machine). We
  invoke it as a subprocess, not through a Haskell binding: we pipe a newline-delimited
  candidate list to its stdin and parse its stdout.
- **Candidate**: a record with a `display :: Text` (what the operator sees in fzf) and a
  `value :: a` (what comes back on Enter). Hidden integer indices sit between fzf and the
  candidate list — fzf only ever sees `"<index>\t<display>"` lines and reports back the
  index, which we look up in a `Map Int a`. This avoids parsing display text back into
  structured values.
- **Selector module**: one module per entity type (`Run`, `Service`) that knows how to
  fetch its candidates from the right source, how to format a row, and what default
  `FzfOpts` to use. The selector exposes a `resolve…` function that CLI handlers call when
  the positional is absent.
- **Resolver three-way dispatch**: §7 of the reference doc. `Just idText` → return it
  unchanged; `Nothing` with `isFzfAvailable` → fzf picker; `Nothing` with no fzf → print
  an error and return `Nothing`, which the caller turns into exit 1.

**External reference.** The patterns come from the haskell-jitsurei fzf-integration
cookbook, `mori://shinzui/haskell-jitsurei/docs/cli-fzf-integration` (resolve it on disk
with `mori path <uri>`). It is **not** part of this repository; everything needed to
implement or maintain this feature is restated here. The invariants the implementation
must preserve from it are:

1. **Index-based selection**: emit `"<i>\t<display>"` to fzf's stdin with
   `--with-nth=2..` so the index column is hidden but used for round-tripping.
2. **`delegate_ctlc = True`** on the `CreateProcess` record so Ctrl-C goes to fzf
   (exit 130 → `FzfCancelled`) instead of killing shiki.
3. **`std_err = Inherit`** so fzf's TUI, which fzf draws on stderr, renders to the
   terminal.
4. **Lazy `hGetContents` + `waitForProcess`** — waiting for the exit code happens after
   the stdout read is set up, so the read is forced before we interpret the result.
5. **`/dev/tty` fallback** in `isFzfAvailable` so the picker still works when stdin is
   piped but the operator has a terminal attached.

**Prior plans** that this one composes with (all in `docs/plans/`):

- `4-run-cli-command-end-to-end.md` — introduced `RunOptions` and the `runs` table writer.
- `5-runs-query-cli-commands.md` — introduced `RunsCommand` and the positional arguments
  this plan made optional.
- `7-job-log-fetch-and-error-summary-analysis.md` — added `runs analyze` and
  `runs error`, both also covered here.
- `8-agent-assist-subcommand-backed-by-baikai.md` — set the precedent for "interactive
  affordance scoped to `shiki-cli`".

**Later plans** that changed the code this plan created, without changing its behaviour:

- `13-route-run-storage-to-the-active-environment-database.md` — `withDbEnv` now takes an
  `--env` name and routes to the active `shiki.dhall` environment's database, so the runs
  picker lists that environment's runs.
- `16-adopt-haskell-jitsurei-conventions-for-the-initial-release.md` — unprefixed the
  records in `Shiki.Cli.Fzf` and switched the selectors and `RunSpec` to label access.


## Plan of Work

The work was five milestones. Every milestone left the build green and the existing CLI
surface intact; milestones 3 and 4 are the ones that changed user-visible behaviour. The
excerpts below show the code as it exists in the current tree; the milestones originally
shipped the same code with prefixed field names (see the Decision Log entry dated
2026-09-11).

### Milestone 1 — Core `Shiki.Cli.Fzf` module and `CliEnv` integration

Scope: introduce the core fzf abstraction and detection. No subcommand changes yet.

**File:** `shiki-cli/shiki-cli.cabal` — under the `library` stanza's `build-depends:`,
add `process ^>=1.6` and `containers ^>=0.7`. Both ship with GHC, so no flake-input
changes are needed. Add `Shiki.Cli.Fzf` to `exposed-modules`.

**File:** `shiki-cli/src/Shiki/Cli/Fzf.hs` — new module exporting:

```haskell
module Shiki.Cli.Fzf
  ( -- * Detection
    FzfConfig (..),
    detectFzfConfig,
    isFzfAvailable,

    -- * Options (Monoid)
    FzfOpts (..),
    withPrompt,
    withHeader,
    withHeight,
    withAnsi,
    withNoSort,

    -- * Selection
    Candidate (..),
    FzfResult (..),
    runFzf,
  )
where
```

Its types:

```haskell
data FzfConfig = FzfConfig
  { binary :: !FilePath,
    available :: !Bool,
    stdinIsTerminal :: !Bool,
    stdoutIsTerminal :: !Bool,
    ttyAvailable :: !Bool
  }
  deriving stock (Generic, Eq, Show)

data FzfOpts = FzfOpts
  { prompt :: !(Maybe Text),
    header :: !(Maybe Text),
    height :: !(Maybe Text),
    ansi :: !Bool,
    noSort :: !Bool
  }
  deriving stock (Generic, Eq, Show)

data Candidate a = Candidate
  { display :: !Text,
    value :: !a
  }
  deriving stock (Generic, Functor)

data FzfResult a
  = FzfSelected !a
  | FzfNoMatch
  | FzfCancelled
  | FzfError !Text
  deriving stock (Functor)
```

`FzfOpts` has a right-biased `Semigroup` (for the `Maybe` fields the right-hand value wins
when present; the `Bool` fields are OR-ed) and a `Monoid` whose `mempty` sets nothing.
Each smart constructor sets one field on `mempty`, for example
`withPrompt t = mempty & #prompt ?~ t` and `withAnsi = mempty & #ansi .~ True`, so callers
compose options with `<>`.

`detectFzfConfig` uses `System.Directory.findExecutable "fzf"` (recording the resolved path
in `binary`, or the literal `"fzf"` when not found), `System.IO.hIsTerminalDevice` on
`stdin` and `stdout`, and a `try`-guarded `openFile "/dev/tty" ReadMode >>= hClose` for the
tty probe. `isFzfAvailable cfg = cfg ^. #available && (cfg ^. #stdinIsTerminal ||
cfg ^. #ttyAvailable)`.

`runFzf :: FzfConfig -> FzfOpts -> [Candidate a] -> IO (FzfResult a)` (§4 of the reference
doc):

- Short-circuits to `FzfNoMatch` if the candidate list is empty (never spawn fzf with no
  input).
- Short-circuits to `FzfError "fzf not available"` if `not (isFzfAvailable cfg)`.
  Callers are expected to check `isFzfAvailable` first; this is defence in depth.
- Builds the argument list `["-1", "--with-nth=2.."] <> optsToArgs opts`, where
  `optsToArgs` turns the set fields into `--prompt`, `--header`, `--height`, `--ansi`,
  and `--no-sort`.
- Builds the process from `proc (cfg ^. #binary) args` with `std_in = CreatePipe`,
  `std_out = CreatePipe`, `std_err = Inherit`, `delegate_ctlc = True`.
- Writes each `"<i>\t<display>"` line to stdin, closes stdin, reads stdout with
  `hGetContents`, then `waitForProcess`. Parses the leading integer field of the first
  output line and looks it up in a `Map Int a`. Exit `0` → `FzfSelected`; exit `1` →
  `FzfNoMatch`; exit `130` → `FzfCancelled`; any other exit, an unparseable line, or an
  unknown index → `FzfError`.
- Wraps the process IO in `try @SomeException` so a thrown spawn error maps to
  `FzfError "fzf spawn failed: …"`.

**File:** `shiki-cli/src/Shiki/Cli/Env.hs` — add `fzf :: !FzfConfig` to `CliEnv` (shown in
Context and Orientation) and, inside `withCliEnv`, after `loadDefaultClientConfig`:

```haskell
fzfCfg <- detectFzfConfig
action CliEnv {pool = p, client = cl, fzf = fzfCfg}
```

No other handler needs to change; they receive the whole `CliEnv` and ignore the new
field.

Acceptance:

```bash
cd /Users/shinzui/Keikaku/bokuno/shiki
just build
just test
```

Both green. No subcommand behaviour changes.

### Milestone 2 — `Shiki.Cli.Fzf.Selector.Run` and pure unit tests

Scope: add the run selector and a small test that the candidate-formatting helper
produces the expected display string.

**File:** `shiki-cli/src/Shiki/Cli/Fzf/Selector/Run.hs` — new module:

```haskell
module Shiki.Cli.Fzf.Selector.Run
  ( RunSelection (..),
    defaultRunOpts,
    formatRunCandidate,
    selectRun,
    resolveRunId,
  )
where

data RunSelection
  = RunChosen !RunId !RunRecord
  | RunNoRows
  | RunSelectionCancelled
  | RunFzfUnavailable
  | RunSelectionError !Text

defaultRunOpts :: FzfOpts
defaultRunOpts =
  withPrompt "run> " <> withHeight "40%" <> withAnsi <> withNoSort

selectorRowLimit :: Int
selectorRowLimit = 50

formatRunCandidate :: RunRecord -> Candidate (RunId, RunRecord)
selectRun :: CliEnv -> IO RunSelection
resolveRunId :: CliEnv -> Maybe Text -> IO (Maybe Text)
```

`formatRunCandidate` joins these columns with two spaces into a single line: the first 8
characters of the UUID, `startedAt` as `%Y-%m-%d %H:%M:%S`, the service name, the status
(via `runStatusToText`), the duration (via a private `formatDuration`, or `-`),
`exit=<code>` (or `exit=-`), and the command words joined by spaces. For example:

```text
3f2c1a9d  2026-05-27 17:22:11  ingest  Succeeded  12s  exit=0  reindex --batch 100
```

The duration helper is a private copy of the `runs list` formatter. The module must not
import `Shiki.Cli.Runs`, because `Shiki.Cli.Runs` imports this module for `resolveRunId`
and the reverse import would be a cycle (see the Decision Log).

`selectRun` returns `RunFzfUnavailable` if fzf is not available; otherwise it runs
`listRecentRunsStatement` with `selectorRowLimit` through `Pool.use (env ^. #pool)`, maps a
persistence error to `RunSelectionError`, maps zero rows to `RunNoRows`, and otherwise calls
`runFzf (env ^. #fzf) defaultRunOpts` on the formatted candidates, mapping `FzfSelected`,
`FzfNoMatch`, `FzfCancelled`, and `FzfError` to `RunChosen`, `RunNoRows`,
`RunSelectionCancelled`, and `RunSelectionError`.

`resolveRunId` is the public entry point. It returns the text the existing handlers feed
into `findRunByPrefixStatement`, or `Nothing` after printing any message:

```haskell
resolveRunId :: CliEnv -> Maybe Text -> IO (Maybe Text)
resolveRunId _ (Just t) = pure (Just t)
resolveRunId env Nothing
  | not (isFzfAvailable (env ^. #fzf)) = do
      hPutStrLn stderr "shiki: no run id given and fzf is not available"
      pure Nothing
  | otherwise = do
      sel <- selectRun env
      case sel of
        RunChosen (RunId u) _ -> pure (Just (Text.pack (show u)))
        RunNoRows -> do
          TIO.putStrLn "(no runs recorded yet)"
          pure Nothing
        RunSelectionCancelled -> pure Nothing
        RunFzfUnavailable -> do
          hPutStrLn stderr "shiki: no run id given and fzf is not available"
          pure Nothing
        RunSelectionError e -> do
          TIO.hPutStrLn stderr ("shiki: fzf: " <> e)
          pure Nothing
```

Every `Nothing` result makes the caller exit 1, including a cancel, which prints nothing
(see the Decision Log and the acceptance matrix).

**File:** `shiki-cli/shiki-cli.cabal` — add `Shiki.Cli.Fzf.Selector.Run` to
`exposed-modules` and `Shiki.Cli.Fzf.Selector.RunSpec` to the test suite's
`other-modules`.

**File:** `shiki-cli/test/Shiki/Cli/Fzf/Selector/RunSpec.hs` — new test file with pure
tests over a fixture `RunRecord` whose id starts with `3f2c1a9d`, service `ingest`, and
command `reindex --batch 100`:

```haskell
tests :: TestTree
tests =
  testGroup
    "Shiki.Cli.Fzf.Selector.Run"
    [ testCase "formatRunCandidate produces single-line display" $ do
        let c = formatRunCandidate fixtureRow
        assertBool
          "display must not contain embedded newlines"
          (not (Text.any (== '\n') (c ^. #display))),
      testCase "formatRunCandidate embeds the 8-char id prefix" $ do
        let c = formatRunCandidate fixtureRow
        assertBool
          ("expected id prefix in display: " <> Text.unpack (c ^. #display))
          (Text.isInfixOf "3f2c1a9d" (c ^. #display)),
      testCase "formatRunCandidate includes service name and command" $ …
    ]
```

Wire it into `shiki-cli/test/Spec.hs`. Don't test `runFzf` end-to-end — it spawns a
subprocess and reads `/dev/tty`. The reference doc deliberately keeps the IO surface thin
so the pure parts are testable.

Acceptance:

```bash
cabal test shiki-cli-test
```

Includes the new test group and is green.

### Milestone 3 — Wire fzf into the four `runs` read subcommands

Scope: change the four `RunsCommand` constructors to `Maybe Text`, update the parser,
and route the four handlers through `resolveRunId`. No new files.

**File:** `shiki-cli/src/Shiki/Cli/Runs.hs`:

```haskell
data RunsCommand
  = RunsList !(Maybe Text) !Int
  | RunsShow !(Maybe Text)
  | RunsLogs !(Maybe Text)
  | RunsError !(Maybe Text)
  | RunsAnalyze !(Maybe Text) !(Maybe AnalyzerKind)
  deriving stock (Generic, Eq, Show)
```

In `runsParser`, each of the four subcommands parses its id with
`optional (argument str idArgHelp)`, where

```haskell
idArgHelp :: Opt.Mod Opt.ArgumentFields Text
idArgHelp = metavar "ID" <> help "Run id (UUID or unambiguous prefix); opens an fzf picker if omitted"
```

and each `progDesc` ends in "(uses fzf if omitted)".

The dispatcher resolves first, then calls the unchanged handler:

```haskell
runRuns :: CliEnv -> RunsCommand -> IO ()
runRuns env = \case
  RunsList mService limit -> doList env mService limit
  RunsShow mId -> withResolved env mId doShow
  RunsLogs mId -> withResolved env mId doLogs
  RunsError mId -> withResolved env mId doError
  RunsAnalyze mId override -> withResolved env mId (\e t -> doAnalyze e t override)

withResolved :: CliEnv -> Maybe Text -> (CliEnv -> Text -> IO ()) -> IO ()
withResolved env mIdText body = do
  mResolved <- resolveRunId env mIdText
  case mResolved of
    Just t -> body env t
    Nothing -> exitFailure
```

The `doShow / doLogs / doError / doAnalyze` bodies keep their `findRunByPrefixStatement`
call, so a picked run costs one extra round-trip (the picker already fetched the row; the
handler fetches it again by full UUID). That's fine for an interactive path, and it means
zero changes to the success branches.

**Cancellation exit code.** When the operator hits Esc in fzf, `resolveRunId` returns
`Nothing` without printing anything and the wrapper exits 1, the Unix convention for
cancelled interactive input. `docs/user/commands.md` documents this.

Acceptance (requires a running database with at least two runs):

```bash
just build && just test
just up                                    # if not running
just shiki run <service> -- echo hi        # twice, to seed runs
just shiki runs show                       # fzf picker opens
just shiki runs show <prefix>              # unchanged
just shiki runs logs
just shiki runs error
just shiki runs analyze
```

### Milestone 4 — `Shiki.Cli.Fzf.Selector.Service` and `service show`

Scope: add a service selector, change `ServiceShow` to take `Maybe Text`, wire the
handler.

**File:** `shiki-cli/src/Shiki/Cli/Fzf/Selector/Service.hs` — new module:

```haskell
module Shiki.Cli.Fzf.Selector.Service
  ( ServiceSelection (..),
    defaultServiceOpts,
    selectService,
    resolveServiceName,
  )
where

data ServiceSelection
  = ServiceChosen !Text -- bare service name, sans .dhall
  | ServiceNoneFound
  | ServiceSelectionCancelled
  | ServiceFzfUnavailable
  | ServiceSelectionError !Text

defaultServiceOpts :: FzfOpts
defaultServiceOpts =
  withPrompt "service> " <> withHeight "40%" <> withNoSort
```

`selectService` lists the `services` directory with `System.Directory.listDirectory`
(returning no entries if the directory does not exist, and mapping an `IOException` to
`ServiceSelectionError`), keeps entries whose extension is `.dhall`, strips the extension,
sorts lexically, and builds `Candidate {display = n, value = n}` for each name before
calling `runFzf`. There is no database access.

`resolveServiceName :: FzfConfig -> IO (Maybe Text)` mirrors `resolveRunId`: with fzf
unavailable it prints `shiki: no service name given and fzf is not available`; with no
`.dhall` files it prints `(no service configs found in services/)`; a cancel prints
nothing; an error prints `shiki: fzf: <message>`. All of these return `Nothing`.

**File:** `shiki-cli/src/Shiki/Cli.hs` — `ServiceShow` takes `!(Maybe Text)`, and the
parser makes the name optional:

```haskell
serviceSubparser :: Parser Command
serviceSubparser =
  Opt.hsubparser
    ( Opt.command
        "show"
        ( Opt.info
            ( ServiceShow
                <$> Opt.optional
                  ( Opt.argument
                      Opt.str
                      ( Opt.metavar "NAME"
                          <> Opt.help
                            "Service name (basename of services/<NAME>.dhall); opens an fzf picker if omitted"
                      )
                  )
            )
            (Opt.progDesc "Pretty-print the parsed ServiceConfig for NAME (uses fzf if omitted)")
        )
    )
```

`service show` does **not** need a database (`runCli` dispatches it before `withDbEnv`),
so it has no `CliEnv` from which to read an `FzfConfig`. There were two options:

1. Run `detectFzfConfig` directly in `serviceShowHandler`.
2. Hoist `detectFzfConfig` out of `withCliEnv` into `runCli` and pass it to both
   `withDbEnv` and `serviceShowHandler`.

Option 1 was chosen: `withCliEnv` stays the only place database-backed handlers get their
probe, `serviceShowHandler` makes one direct call, and no parameter cascades through the
other commands.

```haskell
serviceShowHandler :: Maybe Text -> IO ()
serviceShowHandler (Just nm) = serviceShowOne nm
serviceShowHandler Nothing = do
  fzfCfg <- detectFzfConfig
  resolveServiceName fzfCfg >>= \case
    Just nm -> serviceShowOne nm
    Nothing -> exitFailure

serviceShowOne :: Text -> IO ()
serviceShowOne nm = do
  let path = "services/" <> Text.unpack nm <> ".dhall"
  cfg <- loadServiceConfig path
  printConfig cfg
```

Add `Shiki.Cli.Fzf.Selector.Service` to `exposed-modules`.

Acceptance:

```bash
just shiki service show           # fzf opens (or auto-selects a lone config); choose one
just shiki service show <name>    # unchanged
```

### Milestone 5 — Docs, smoke transcript, formatting

Scope: update operator docs and the CHANGELOG, and format the new code.

**File:** `docs/user/commands.md` — for each of `shiki runs show`, `shiki runs logs`,
`shiki runs error`, `shiki runs analyze`, and `shiki service show`, bracket `ID` / `NAME`
in the synopsis (optional) and add one short paragraph, for example:

> If `ID` is omitted, shiki opens an `fzf` picker over the 50 most recent runs; see
> [Interactive selection (fzf)](#interactive-selection-fzf).

Add a section after "Global options" titled `## Interactive selection (fzf)` that says the
read-only subcommands taking an `ID` or `NAME` accept it as optional; that omitting it opens
a picker over the canonical source (PostgreSQL for runs, `services/` for configs); that
precedence is **positional > fzf > error**; that the picker needs `fzf` on `PATH` plus either
a terminal stdin or an openable `/dev/tty`; that without them shiki prints
`shiki: no run id given and fzf is not available` (or the service equivalent) and exits 1;
and that Esc cancels silently with exit 1 while Ctrl-C is delegated to fzf.

**File:** `CHANGELOG.md` — add an entry under `## [Unreleased]` → `### Added`:

```markdown
- feat(shiki-cli): EP-10 — `shiki runs show / logs / error / analyze` now
  accept the `ID` positional as optional; omitting it opens an `fzf` picker
  populated from the 50 most recent recorded runs. `shiki service show`
  accepts `NAME` as optional; omitting it opens an `fzf` picker populated
  from `services/*.dhall`.
```

Follow it with a smoke transcript fenced as `text`:

```text
$ shiki runs show
> 3f2c1a9d  2026-05-27 17:22:11  ingest  Succeeded  12s  exit=0  echo hello
  51a40b22  2026-05-27 17:19:08  ingest  Succeeded  03s  exit=0  echo hi
  2/2
> run>

{
  "runId": "3f2c1a9d-…",
  "serviceName": "ingest",
  "status": "Succeeded",
  …
}
```

**Format pass.** Run `nix fmt`. It runs treefmt, which formats Haskell with fourmolu (using
`fourmolu.yaml`), cabal files with cabal-gild, and Nix files with nixpkgs-fmt. (When M5 was
first implemented the flake had no formatter, so this step was done by hand; see
Surprises.)

Acceptance:

```bash
nix fmt
git status --short     # expect no changes after formatting already-formatted code
just test
```


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/shiki` inside a `nix develop` shell.
Lines prefixed with `$` are commands; lines without are expected output excerpts. The
feature is already implemented; these steps describe how it was built and double as a way
to re-check it.

### One-time bootstrap

```bash
$ nix develop
$ just up                          # if Postgres is not already up
$ just build                       # baseline green
$ just shiki runs list -l 3        # confirm there are recorded runs to pick from
```

If `runs list` prints `(no runs recorded yet)`, seed a couple of runs:

```bash
$ just shiki run <service> -- echo hello
$ just shiki run <service> -- echo world
```

### M1: scaffolding

```bash
$ $EDITOR shiki-cli/shiki-cli.cabal                       # add process, containers, expose new module
$ $EDITOR shiki-cli/src/Shiki/Cli/Fzf.hs                  # new file
$ $EDITOR shiki-cli/src/Shiki/Cli/Env.hs                  # add fzf :: !FzfConfig to CliEnv, detect in withCliEnv
$ just build
```

Expected: build succeeds, no test regressions, no behaviour change.

Commit:

```text
feat(shiki-cli): EP-10 M1 — Shiki.Cli.Fzf core + CliEnv detection

ExecPlan: docs/plans/10-integrate-fzf-for-interactive-id-selection.md
Intention: intention_01ksp9d2g6e7hb7cvm51402pe7
```

### M2: run selector

```bash
$ $EDITOR shiki-cli/src/Shiki/Cli/Fzf/Selector/Run.hs      # new file (private formatDuration)
$ $EDITOR shiki-cli/shiki-cli.cabal                        # expose Selector.Run, add RunSpec to test other-modules
$ $EDITOR shiki-cli/test/Shiki/Cli/Fzf/Selector/RunSpec.hs # new file
$ $EDITOR shiki-cli/test/Spec.hs                           # wire the new test group
$ cabal test shiki-cli-test
```

Expected excerpt:

```text
  Shiki.Cli.Fzf.Selector.Run
    formatRunCandidate produces single-line display:                OK
    formatRunCandidate embeds the 8-char id prefix:                 OK
    formatRunCandidate includes service name and command:           OK
```

Commit `feat(shiki-cli): EP-10 M2 — Shiki.Cli.Fzf.Selector.Run + tests` with the trailers.

### M3: wire fzf into `runs *`

```bash
$ $EDITOR shiki-cli/src/Shiki/Cli/Runs.hs
$ just build
$ just shiki runs show           # picker
$ just shiki runs show <prefix>  # unchanged
$ just shiki runs logs           # picker → log tail
$ just shiki runs error          # picker → error summary
$ just shiki runs analyze        # picker → analyze
```

Expected interactive transcript for the no-arg case (the lines above `run>` are fzf's TUI;
the JSON is the existing `runs show` output for the chosen row):

```text
$ just shiki runs show
> 3f2c1a9d  2026-05-27 17:22:11  ingest  Succeeded  12s  exit=0  echo hello
  51a40b22  2026-05-27 17:19:08  ingest  Succeeded  03s  exit=0  echo hi
  2/2
> run>

{
  "runId": "3f2c1a9d-…",
  "serviceName": "ingest",
  …
}
```

Expected Esc-cancel:

```text
$ just shiki runs show
> (picker opens, operator hits Esc)
$ echo $?
1
```

Expected fzf-missing (database reachable; `just` is not on `/usr/bin`, so call the built
binary directly):

```text
$ env PATH=/usr/bin "$(cabal list-bin shiki)" runs show </dev/null
shiki: no run id given and fzf is not available
$ echo $?
1
```

Commit `feat(shiki-cli): EP-10 M3 — runs show/logs/error/analyze fzf integration`.

### M4: service selector + `service show`

```bash
$ $EDITOR shiki-cli/src/Shiki/Cli/Fzf/Selector/Service.hs # new file
$ $EDITOR shiki-cli/src/Shiki/Cli.hs                      # ServiceShow (Maybe Text), optional parser, handler dispatch
$ $EDITOR shiki-cli/shiki-cli.cabal                       # expose Selector.Service
$ just build
$ just shiki service show
$ just shiki service show <one-of-the-listed-names>
```

Expected interactive transcript with two configs in `services/` (with only one, fzf's `-1`
selects it and the JSON prints immediately):

```text
$ just shiki service show
> ingest
  worker
  2/2
> service>

{
  "name": "ingest",
  "defaultNamespace": "data",
  …
}
```

Commit `feat(shiki-cli): EP-10 M4 — service show fzf integration`.

### M5: docs + smoke transcript

```bash
$ $EDITOR docs/user/commands.md
$ $EDITOR CHANGELOG.md
$ nix fmt
$ just test
```

Expected: both commands exit 0, and the CHANGELOG transcript matches the shape of
`shiki runs show` against the seeded runs. `nix flake check` additionally runs the treefmt
check but builds the whole project through Nix, so treat it as an optional, slower gate.

Commit `docs(shiki): EP-10 M5 — operator docs + smoke transcript`.

### Progress updates as you go

After each milestone:

1. Tick the corresponding boxes in the Progress section above with a timestamp like
   `[2026-05-27 22:14]`.
2. Append any unexpected behaviour to Surprises & Discoveries with the command that
   produced it.
3. Add a one-line Decision Log entry if you make a judgement call not already covered.


## Validation and Acceptance

### Behavioural acceptance matrix

The plan is accepted when **every row** below holds. The "Inputs" column is what the
operator types; "Observed" is what shiki does; "Exit" is the process exit code. Rows 4-9
need a reachable database.

| # | Inputs                                       | Observed                                                                          | Exit |
|---|----------------------------------------------|-----------------------------------------------------------------------------------|------|
| 1 | `shiki runs show <unambiguous-prefix>`       | Pretty-prints the row's JSON. (Unchanged from EP-5.)                              | 0    |
| 2 | `shiki runs show <ambiguous-prefix>`         | `ambiguous id prefix <prefix>`. (Unchanged.)                                      | 1    |
| 3 | `shiki runs show <nonexistent-prefix>`       | `no run matching <prefix>`. (Unchanged.)                                          | 1    |
| 4 | `shiki runs show` (no arg, ≥1 run in DB)     | fzf picker opens; on Enter, the JSON for the picked row prints.                   | 0    |
| 5 | `shiki runs show` (no arg, empty `runs`)     | `(no runs recorded yet)`; no picker.                                              | 1    |
| 6 | `shiki runs show` (no arg) + Esc             | No JSON, no error message.                                                        | 1    |
| 7 | `shiki runs show` (no arg) + Ctrl-C in fzf   | No JSON, no traceback (delegate_ctlc hands the signal to fzf).                    | 1    |
| 8 | `env PATH=/usr/bin shiki runs show` (no arg) | `shiki: no run id given and fzf is not available` on stderr.                      | 1    |
| 9 | `shiki runs logs` / `runs error` / `runs analyze` (no arg)  | Same picker; on Enter, the per-subcommand behaviour against the row.  | 0 or 1 by subcommand|
| 10 | `shiki service show <existing-name>`         | Prints JSON. (Unchanged.)                                                        | 0    |
| 11 | `shiki service show <missing-name>`          | Dhall load error to stderr. (Unchanged.)                                         | non-zero |
| 12 | `shiki service show` (no arg)                | fzf picker over `services/*.dhall` (auto-selects a lone file); on Enter, the JSON for the chosen config. | 0 |
| 13 | `shiki service show` (no arg, no `.dhall` files) | `(no service configs found in services/)`; no picker.                        | 1    |
| 14 | `env PATH=/usr/bin shiki service show` (no arg) | `shiki: no service name given and fzf is not available` on stderr.            | 1    |
| 15 | `shiki run <svc> -- echo hi`                 | Unchanged — submits a Job. **No fzf integration on `shiki run`.**                | 0 / non-zero |
| 16 | `shiki runs show --help`, `shiki service show --help` | Usage shows `[ID]` / `[NAME]` and the "opens an fzf picker if omitted" hint. | 0 |

### Evidence captured on 2026-09-11 (`HEAD` `d0686f7`)

Rows 14 and 16, and the unit tests, were re-run while refreshing this plan:

```text
$ cabal run -v0 shiki -- runs show --help
Usage: shiki runs show [ID]

  Show one run by id (UUID or unambiguous prefix; uses fzf if omitted)

Available options:
  ID                       Run id (UUID or unambiguous prefix); opens an fzf
                           picker if omitted
  -h,--help                Show this help text

$ cabal run -v0 shiki -- service show --help
Usage: shiki service show [NAME]

  Pretty-print the parsed ServiceConfig for NAME (uses fzf if omitted)

Available options:
  NAME                     Service name (basename of services/<NAME>.dhall);
                           opens an fzf picker if omitted
  -h,--help                Show this help text

$ env PATH=/usr/bin "$(cabal list-bin shiki)" service show </dev/null
shiki: no service name given and fzf is not available
$ echo $?
1

$ cabal test -v0 shiki-cli-test
  …
  Shiki.Cli.Fzf.Selector.Run
    formatRunCandidate produces single-line display:                OK
    formatRunCandidate embeds the 8-char id prefix:                 OK
    formatRunCandidate includes service name and command:           OK
  …
All 62 tests passed (4.75s)
```

The interactive rows (4-9, 12) were not re-run in the refresh because the local PostgreSQL
was not running (`pg_isready` reported no response); re-check them with a live terminal.

### Test commands

```bash
cd /Users/shinzui/Keikaku/bokuno/shiki
cabal test shiki-cli-test    # the CLI suite, including the fzf selector tests
just test                    # every suite; shiki-core's persistence tests start throwaway Postgres instances
```

The unit tests in `shiki-cli/test/Shiki/Cli/Fzf/Selector/RunSpec.hs` verify the pure part
of the run selector (the candidate formatter). There is no end-to-end test of the fzf
subprocess; the reference architecture deliberately keeps the IO surface thin so the
testable parts are pure.

If a future plan needs to test the subprocess path, the right approach is to put a fake
`fzf` on `PATH` (a shell script that reads stdin and echoes one chosen `"<index>\t…"` line)
and call `runFzf` with an in-process candidate list — but that is out of scope here.

### Non-regression

Run the existing test suite plus a smoke pass over the unchanged subcommands:

```bash
just test
just shiki runs list                         # table renders
just shiki runs show <prefix>                # JSON for the row
just shiki runs logs <prefix>                # log tail
just shiki runs error <prefix>               # error summary
just shiki runs analyze <prefix>             # analyzer outcome
just shiki service show <name>               # config JSON
just shiki run <svc> -- echo regression-check # actually submits
```

Each of these must produce the same output as a build from before this plan (commit
`5a7f1f5`), apart from the "(uses fzf if omitted)" wording in `--help` for the changed
subcommands.


## Idempotence and Recovery

This plan adds new code only. No migrations, no schema changes, no destructive
operations.

- **Build steps** (`just build`, `just test`, `nix fmt`) are idempotent — re-run freely.
- **Picker invocations** are read-only: `selectRun` issues a `SELECT … FROM runs ORDER BY
  started_at DESC LIMIT 50`; `selectService` does a `listDirectory`. Cancelling
  (Esc / Ctrl-C) leaves no side effects. Note that, like every database-backed shiki
  command, the `runs` commands apply pending migrations before running.
- **Resolved IDs** are fed back into the same `findRunByPrefixStatement` the
  positional path uses, so behaviour after the picker is identical to a positional
  invocation with the full UUID — same exit codes, same error messages, same JSON output.
- **`runs analyze`** does write through `updateErrorSummaryStatement`, but that statement
  is an `UPDATE … SET error_summary = …` keyed on `id`; calling it twice on the same row
  produces the same final state. Re-picking the same row and pressing Enter is safe.

### Rollback

The milestone commits (`811c9db` … `d51aecc`) can no longer be reverted cleanly one by one:
the later commits listed in Outcomes & Retrospective rewrote the same files. To remove the
feature today, edit by hand: make the four `runs` positionals and the `service show`
positional required again (drop `optional`, change the constructors back to `Text`), call
the handlers directly from `runRuns` and `runCli`, remove the `fzf` field from `CliEnv` and
its probe in `withCliEnv`, and delete `shiki-cli/src/Shiki/Cli/Fzf.hs`,
`shiki-cli/src/Shiki/Cli/Fzf/Selector/`, and
`shiki-cli/test/Shiki/Cli/Fzf/Selector/RunSpec.hs` together with their cabal entries and
the `Spec.hs` import. There is no persisted state, cache, or migration to roll back.

### Recovery if a picker is invoked on a misconfigured DB

If the database is unreachable, `withCliEnv` fails while acquiring the pool or running
migrations, before the picker is reached, exactly as for any other `runs` command. If the
pool comes up but the `SELECT` fails, `selectRun` maps the error to `RunSelectionError`
and the operator sees `shiki: fzf: persistence error: …` with exit 1.


## Interfaces and Dependencies

### Libraries used

| Library             | Why                                                                            |
|---------------------|--------------------------------------------------------------------------------|
| `process` (`^>=1.6`)    | `System.Process` for `createProcess` / `waitForProcess` / `CreateProcess` with `delegate_ctlc` |
| `containers` (`^>=0.7`) | `Data.Map.Strict` for the `Int → a` index-to-value lookup                  |
| `directory` (already a dep) | `findExecutable "fzf"`, `doesDirectoryExist` and `listDirectory "services"` |
| `filepath` (already a dep)  | `takeExtension` / `-<.>` to filter and strip `.dhall`                  |
| `text` (already a dep)      | `Text` is the project-wide string type                                 |
| `hasql-pool` (already a dep)| `Pool.use` + `Session.statement` for the candidate query               |
| `generic-lens` / `lens` (already deps) | `^. #field` access and `& #field ?~ v` updates on the records |

The flake's GHC (9.12.4) ships these; no flake-input changes were needed. If `cabal build`
reports a missing index, run `cabal update` once.

### External system: fzf

- Binary: `fzf` (≥0.40 recommended; 0.74.1 is on the author's nix profile and ships in the
  dev shell).
- Invocation: subprocess with `--with-nth=2..` to hide the index column; `-1` to
  auto-select when exactly one candidate matches; `--ansi`, `--no-sort`, `--prompt`,
  `--header`, `--height` per `FzfOpts`.
- Signals: Ctrl-C is delivered to fzf because of `delegate_ctlc = True`; fzf exits 130,
  which `runFzf` maps to `FzfCancelled`.
- Streams: stdin (piped, newline-delimited `"<i>\t<display>"` lines), stdout (piped,
  one line containing the chosen row, whose first tab-separated field is the index),
  stderr (inherited, so fzf's TUI renders to the terminal).

### Module signatures (current tree)

`Shiki.Cli.Fzf` (`shiki-cli/src/Shiki/Cli/Fzf.hs`) exports:

```haskell
data FzfConfig = FzfConfig
  { binary :: !FilePath,
    available :: !Bool,
    stdinIsTerminal :: !Bool,
    stdoutIsTerminal :: !Bool,
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
    noSort :: !Bool
  }
  deriving stock (Generic, Eq, Show)

instance Semigroup FzfOpts
instance Monoid FzfOpts

withPrompt :: Text -> FzfOpts
withHeader :: Text -> FzfOpts
withHeight :: Text -> FzfOpts
withAnsi :: FzfOpts
withNoSort :: FzfOpts

data Candidate a = Candidate
  { display :: !Text,
    value :: !a
  }
  deriving stock (Generic, Functor)

data FzfResult a
  = FzfSelected !a
  | FzfNoMatch
  | FzfCancelled
  | FzfError !Text
  deriving stock (Functor)

runFzf :: FzfConfig -> FzfOpts -> [Candidate a] -> IO (FzfResult a)
```

`Shiki.Cli.Env.CliEnv` has the fields `pool`, `client`, and `fzf :: !FzfConfig`.

`Shiki.Cli.Fzf.Selector.Run` (`shiki-cli/src/Shiki/Cli/Fzf/Selector/Run.hs`) exports:

```haskell
data RunSelection
  = RunChosen !RunId !RunRecord
  | RunNoRows
  | RunSelectionCancelled
  | RunFzfUnavailable
  | RunSelectionError !Text

defaultRunOpts :: FzfOpts
formatRunCandidate :: RunRecord -> Candidate (RunId, RunRecord)
selectRun :: CliEnv -> IO RunSelection
resolveRunId :: CliEnv -> Maybe Text -> IO (Maybe Text)
```

`Shiki.Cli.Runs.RunsCommand` has `RunsShow`, `RunsLogs`, `RunsError` taking
`!(Maybe Text)` and `RunsAnalyze !(Maybe Text) !(Maybe AnalyzerKind)`;
`runRuns :: CliEnv -> RunsCommand -> IO ()` kept its signature.

`Shiki.Cli.Fzf.Selector.Service` (`shiki-cli/src/Shiki/Cli/Fzf/Selector/Service.hs`)
exports:

```haskell
data ServiceSelection
  = ServiceChosen !Text -- bare name, no .dhall
  | ServiceNoneFound
  | ServiceSelectionCancelled
  | ServiceFzfUnavailable
  | ServiceSelectionError !Text

defaultServiceOpts :: FzfOpts
selectService :: FzfConfig -> IO ServiceSelection
resolveServiceName :: FzfConfig -> IO (Maybe Text)
```

The `Command` type in `Shiki.Cli` (not exported) has `ServiceShow !(Maybe Text)`.

### Out of scope (explicitly deferred)

- Toggle / expect-keys (§6 of the reference doc) — no consumer yet.
- `--preview` integration (§8) — would require shelling back into `shiki runs show` per
  highlighted row, which is reasonable but adds a round-trip per keystroke.
- Multi-select (`FzfMultiResult`, §5) — no batch-on-runs subcommand exists.
- Unified multi-entity selector (§9) — no command yet operates across `runs` and
  `services` in a single picker.
- Skip-entry candidate (§10) — no current subcommand has an "optional referent" semantics.
- `shiki run [SERVICE]` fzf integration — collides with the trailing `commandArgs`
  variadic, requires a parser refactor (see Decision Log).
- `shiki agent assist` fzf integration — `assist` does not take a positional ID today;
  the natural place for fzf there would be a future "attach this assist session to
  run X" affordance, which is its own design discussion.
- A picker for bare `shiki help` — declined by
  `docs/plans/16-adopt-haskell-jitsurei-conventions-for-the-initial-release.md` because the
  six topics fit on one screen.


## Revision Notes

- 2026-09-11 — Refreshed the completed plan against `HEAD` `d0686f7`. Later work changed the
  code this plan created without changing its behaviour, and the plan had drifted from the
  tree. Changes: (1) code excerpts and the Interfaces section now use the unprefixed field
  names (`binary`, `available`, `prompt`, `header`, `height`, `ansi`, `noSort`, `display`,
  `value`) read through generic-lens labels, fourmolu layout, and `Candidate` deriving
  `Generic`, following the rename in
  `docs/plans/16-adopt-haskell-jitsurei-conventions-for-the-initial-release.md`;
  (2) Context and Orientation describes the current `Command` type, database routing
  through `withDbEnv`, the project code conventions, and the absence of ADRs; (3) the
  design reference is cited by `mori://shinzui/haskell-jitsurei/docs/cli-fzf-integration`
  instead of an absolute path that no longer exists; (4) the `nix fmt` Surprise, the M5
  format step, and the follow-up list record that the flake now has a treefmt formatter;
  (5) passages in M2 and M5 that said Esc exits 0 were corrected to exit 1, matching the
  code, the docs, and the acceptance matrix, and the M2 paragraph proposing to export
  `humanDuration` from `Shiki.Cli.Runs` was replaced with what was built; (6) Progress
  gained commit hashes and a post-completion refresh section, the Decision Log gained
  entries for the inlined duration formatter, the Esc exit code, and the refresh itself,
  Surprises gained the moved reference, the database-before-fzf ordering, and `-1`
  auto-selection, and Validation gained a re-captured evidence block; (7) Rollback now
  explains that the milestone commits no longer revert cleanly. No code changed.
