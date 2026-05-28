---
id: 10
slug: integrate-fzf-for-interactive-id-selection
title: "Integrate fzf for interactive ID selection"
kind: exec-plan
created_at: 2026-05-28T03:18:59Z
intention: "intention_01ksp9d2g6e7hb7cvm51402pe7"
---

# Integrate fzf for interactive ID selection

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Today every `shiki runs *` subcommand that operates on a single recorded run requires the
operator to first run `shiki runs list`, copy an id prefix, then re-issue the read command:

```text
$ shiki runs list -l 5
ID        STARTED              SERVICE   STATUS     DURATION  EXIT  COMMAND
3f2c1a9d  2026-05-27 17:22:11  ingest    Succeeded  12s       0     reindex --batch 100
…
$ shiki runs show 3f2c1a9d
```

`shiki service show` is the same: the operator must already know the service name. There is
no in-binary affordance for "show me what's available, let me pick one."

After this plan, every read-only subcommand that takes an `ID` or `NAME` positional makes
that positional optional, and when it is omitted shiki opens an `fzf` picker populated from
the canonical source of truth (Postgres for runs, the `services/` directory for service
configs). When `fzf` is unavailable (not on `PATH`, or `stdin`/`stdout`/`/dev/tty` are all
non-terminals), shiki falls back to the existing "argument required" error path. The
non-interactive transcript-driven UX (`shiki runs show <prefix>`) is unchanged.

The concrete affordances after this plan:

- `shiki runs show` (no arg) → fzf picker of the 50 most recent runs; pressing Enter on a
  row runs `shiki runs show <full-uuid>` against the chosen row.
- `shiki runs logs` (no arg) → same picker, prints the log tail of the chosen row.
- `shiki runs error` (no arg) → same picker, prints the error summary of the chosen row.
- `shiki runs analyze` (no arg) → same picker, then runs the analyzer for the chosen row.
- `shiki service show` (no arg) → fzf picker populated by scanning `services/*.dhall`,
  pretty-prints the chosen config.
- `shiki runs show <prefix>` and friends are **unchanged** — the positional remains a
  parseable prefix, fzf is only invoked when the positional is absent.

A reader can see the change working by:

1. Building in `nix develop` with `cabal build all`.
2. Pre-seeding at least two recorded runs (`just shiki run <service> -- echo hello` twice).
3. Running `just shiki runs show` (no id). An fzf picker appears with the recent runs; the
   prompt is `run> `, the height is `40%`, and ANSI status colours render. Pressing Enter
   on a row prints the same JSON `shiki runs show <prefix>` prints.
4. Running `just shiki service show` (no name). An fzf picker appears with one entry per
   `services/*.dhall` file; pressing Enter on a row prints the parsed JSON.
5. Running `just shiki runs show` inside an environment where `PATH` does not contain `fzf`
   (e.g. `env -u PATH PATH=/usr/bin shiki runs show`). The CLI exits with
   `shiki: no run id given and fzf is not available` and exit code 1 — no picker, no crash.

The scope is deliberately limited to read paths. `shiki run SERVICE -- ARG...` is **not**
changed in this plan: making `SERVICE` optional collides with the trailing positional
`commandArgs` list and would require a parser refactor that the user did not ask for. See
the Decision Log for the reasoning.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

### M1 — Core `Shiki.Cli.Fzf` module + detection wired into `CliEnv`

- [x] Add `process` and `containers` to `shiki-cli/shiki-cli.cabal` library deps. [2026-05-28]
- [x] Create `shiki-cli/src/Shiki/Cli/Fzf.hs` with `FzfConfig`, `detectFzfConfig`,
      `isFzfAvailable`, `FzfOpts` (Monoid), smart constructors, `Candidate`, `FzfResult`,
      `runFzf`. [2026-05-28]
- [x] Add `Shiki.Cli.Fzf` to `exposed-modules`. [2026-05-28]
- [x] Extend `Shiki.Cli.Env.CliEnv` with `fzf :: !FzfConfig`; call `detectFzfConfig` inside
      `withCliEnv` so every handler sees the same snapshot. [2026-05-28]
- [x] `cabal build all` is green; no behaviour change in any subcommand yet. [2026-05-28]

### M2 — `Shiki.Cli.Fzf.Selector.Run` and `resolveRunId`

- [ ] Create `shiki-cli/src/Shiki/Cli/Fzf/Selector/Run.hs` with `RunSelection`,
      `formatRunCandidate`, `defaultRunOpts`, `selectRun`, `resolveRunId`.
- [ ] Add module to `exposed-modules`.
- [ ] Unit test for `formatRunCandidate` (pure shape check) in
      `shiki-cli/test/Shiki/Cli/Fzf/Selector/RunSpec.hs`; wire into `Spec.hs`.
- [ ] `cabal test all` is green.

### M3 — Wire fzf into `runs show / logs / error / analyze`

- [ ] Change `RunsCommand` constructors to take `Maybe Text` instead of `Text` for the
      four read subcommands.
- [ ] Update `runsParser` to use `optional (argument str …)` and tweak the help text to
      include "(uses fzf if not provided)".
- [ ] In `doShow / doLogs / doError / doAnalyze`, on `Nothing`, call `resolveRunId`; on
      `Just t`, behave exactly as today.
- [ ] When `resolveRunId` returns `RunCancelled` / `RunFzfUnavailable` / `RunNoMatch`,
      print the matching message and exit 1 / 0 per the table in
      "Validation and Acceptance".
- [ ] Manual smoke: `just shiki runs show` (no arg) picks; `just shiki runs show <prefix>`
      unchanged.

### M4 — `Shiki.Cli.Fzf.Selector.Service` and wire `service show`

- [ ] Create `shiki-cli/src/Shiki/Cli/Fzf/Selector/Service.hs` with `ServiceSelection`,
      `selectService`, `resolveServiceName`.
- [ ] Change `ServiceShow Text` → `ServiceShow (Maybe Text)`; update
      `serviceSubparser` to use `optional`.
- [ ] In `serviceShowHandler`, on `Nothing`, call `resolveServiceName`.
- [ ] Manual smoke: `just shiki service show` (no arg) picks; `just shiki service show
      <name>` unchanged.

### M5 — Docs, tests, smoke transcript

- [ ] Update `docs/user/commands.md` for the four `runs` read subcommands and
      `service show` to note the optional positional and the fzf picker.
- [ ] Add a `## Interactive selection (fzf)` subsection to `docs/user/commands.md`
      explaining the precedence (positional ID > fzf > error) and the env conditions
      under which fzf is invoked.
- [ ] Update `CHANGELOG.md` with a smoke transcript showing `shiki runs show` opening a
      picker.
- [ ] `cabal test all` and `just shiki --help` both green; `nix flake check` passes.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Adopt the architecture from
  `/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/cli/fzf-integration.md` verbatim for the
  core (`Shiki.Cli.Fzf`) and the entity selector pattern (`Shiki.Cli.Fzf.Selector.*`).
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
  still fits in a `40%`-height fzf pane on a typical terminal. The number is a constant in
  `defaultRunOpts`; bump it in a later plan if operators ask.
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


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

**The repository.** `shiki` is a Haskell CLI (cabal multi-package project) that records
one-off Kubernetes Job runs in PostgreSQL. The two packages are:

- `shiki-core/` — domain types, persistence (hasql), Kubernetes runner, analyzer
  backends. The library that the CLI binary and any future programmatic consumer use.
- `shiki-cli/` — the optparse-applicative parser and command handlers; the
  `executable shiki` defined in `shiki-cli/shiki-cli.cabal` simply re-exports
  `Shiki.Cli.runCli`.

The build is driven from a `Justfile` at the repository root (`just build`, `just test`,
`just shiki <subcommand>`) and a Nix flake. PostgreSQL is started via process-compose
(`just up` / `just down`); `nix develop` exports `PG_CONNECTION_STRING` so `shiki` can find
the local database without flags.

**The CLI surface today** (relevant subcommands only) lives in
`shiki-cli/src/Shiki/Cli.hs`:

```haskell
data Command
  = Run         !RunOptions     -- shiki-cli/src/Shiki/Cli/Run.hs
  | Runs        !RunsCommand    -- shiki-cli/src/Shiki/Cli/Runs.hs
  | ServiceShow !Text           -- service-show handler in Shiki.Cli
  | Agent       !AgentCommand   -- shiki-cli/src/Shiki/Cli/Agent.hs
```

`RunsCommand` (`shiki-cli/src/Shiki/Cli/Runs.hs:63-69`) is currently:

```haskell
data RunsCommand
  = RunsList    !(Maybe Text) !Int
  | RunsShow    !Text
  | RunsLogs    !Text
  | RunsError   !Text
  | RunsAnalyze !Text !(Maybe AnalyzerKind)
```

The four single-id constructors (`RunsShow`, `RunsLogs`, `RunsError`, `RunsAnalyze`) are
the targets of this plan. Their handlers (`doShow / doLogs / doError / doAnalyze`) all
share the same shape:

```haskell
doShow env idText = do
  matches <- runRead env findRunByPrefixStatement idText
  case matches of
    []  -> noMatch   idText      -- prints "no run matching <id>", exit 1
    [r] -> …                     -- per-handler success branch
    _   -> ambiguous idText      -- prints "ambiguous id prefix <id>", exit 1
```

`findRunByPrefixStatement` (`shiki-core/src/Shiki/Persistence/Run.hs:251-265`) returns at
most two rows whose `id::text LIKE $1 || '%'`. This means the resolver only needs to
produce a string that uniquely identifies one row, not a full UUID. After fzf picks a row,
we have the full UUID in hand, so the existing handlers can be left intact — the resolver
hands them a string and they re-query (one extra `findRunByPrefixStatement` round-trip per
fzf-selected run is fine; this is interactive code).

`listRecentRunsStatement` (same file, lines 212-226) is what `runs list` uses; the run
selector reuses it with a 50-row limit.

**`CliEnv`** (`shiki-cli/src/Shiki/Cli/Env.hs`) is the bundle threaded through every
handler:

```haskell
data CliEnv = CliEnv { pool :: !Pool.Pool, client :: !ClientEnv } deriving stock (Generic)
```

This plan adds a third field, `fzf :: !FzfConfig`, populated once inside `withCliEnv`.
Existing handlers that don't use fzf continue to ignore the new field.

**`service show`** is the smallest case. The current parser (`Shiki.Cli`) is:

```haskell
serviceSubparser :: Parser Command
serviceSubparser =
  Opt.hsubparser
    ( Opt.command "show"
        ( Opt.info
            (ServiceShow <$> Opt.argument Opt.str (Opt.metavar "NAME"))
            …
        )
    )
```

…and the handler reads `"services/" <> NAME <> ".dhall"`. The service selector enumerates
`<config-dir>/*.dhall`, displaying the basename without extension. `--config-dir` is a
`shiki run` flag, not a `service` flag, so the selector hard-codes `"services"` (consistent
with `serviceShowHandler`'s current path construction).

**Terminology used in this plan.**

- **fzf**: the [junegunn/fzf](https://github.com/junegunn/fzf) terminal fuzzy finder. We
  invoke it as a subprocess (no Haskell binding); piping a newline-delimited candidate
  list to stdin and parsing stdout.
- **Candidate**: a `(Text display, a value)` pair. The display is what the user sees in
  fzf; the value is what comes back on Enter. Hidden integer indices are interposed
  between fzf and the candidate list — fzf only ever sees `"<index>\t<display>"` lines and
  reports back the index, which we look up in a `Map Int a`. This avoids parsing display
  text back into structured values.
- **Selector module**: one module per entity type (`Run`, `Service`) that knows how to
  fetch its candidates from the right source, how to format a row, and what default
  `FzfOpts` to use. The selector exposes a `resolveXId` function that the CLI handlers call
  with a `Maybe Text` (positional or absent).
- **Resolver three-way dispatch**: §7 of the reference doc. `Just idText` → parse and
  return; `Nothing` with `isFzfAvailable` → fzf picker; `Nothing` with no fzf → print
  error, exit 1.

**External reference.** The patterns used here are taken from
`/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/cli/fzf-integration.md`. That document is
**not** checked into this repository; readers without access to it should still be able to
implement this plan from the prose and code excerpts in the sections below. Key invariants
the implementation must preserve from the reference:

1. **Index-based selection**: emit `"<i>\t<display>"` to fzf's stdin with
   `--with-nth=2..` so the index column is hidden but used for round-tripping.
2. **`delegate_ctlc = True`** on the `CreateProcess` record so Ctrl-C goes to fzf
   (exit 130 → `FzfCancelled`) instead of killing shiki.
3. **`std_err = Inherit`** so fzf's TUI renders to the terminal.
4. **Lazy `hGetContents` + `waitForProcess`** — the exit code forces the stdout read.
5. **`/dev/tty` fallback** in `isFzfAvailable` so the picker still works when stdin is
   piped but the operator has a terminal attached.

**Prior plans** that this one composes with (all in `docs/plans/`):

- `4-run-cli-command-end-to-end.md` — introduced `RunOptions` and the `runs` table writer.
- `5-runs-query-cli-commands.md` — introduced `RunsCommand` and the existing positional
  arguments this plan makes optional.
- `7-job-log-fetch-and-error-summary-analysis.md` — added `runs analyze` and
  `runs error`, both also covered here.
- `8-agent-assist-subcommand-backed-by-baikai.md` — set the precedent for "interactive
  affordance scoped to `shiki-cli`" and is the most recent example of adding a
  package-level dep to `shiki-cli.cabal`.


## Plan of Work

The work is five milestones. Every milestone leaves the build green and the existing CLI
surface intact; milestones 3 and 4 are the ones that change user-visible behaviour.

### Milestone 1 — Core `Shiki.Cli.Fzf` module and `CliEnv` integration

Scope: introduce the core fzf abstraction and detection. No subcommand changes yet.

**File:** `shiki-cli/shiki-cli.cabal` — under the `library` stanza's `build-depends:`,
add `process ^>=1.6` and `containers ^>=0.7`. Both ship with current GHC, so no
flake-input changes are needed. Add `Shiki.Cli.Fzf` to `exposed-modules`.

**File:** `shiki-cli/src/Shiki/Cli/Fzf.hs` — new module exporting:

```haskell
module Shiki.Cli.Fzf
  ( -- * Detection
    FzfConfig (..)
  , detectFzfConfig
  , isFzfAvailable

    -- * Options (Monoid)
  , FzfOpts (..)
  , withPrompt
  , withHeader
  , withHeight
  , withAnsi
  , withNoSort

    -- * Selection
  , Candidate (..)
  , FzfResult (..)
  , runFzf
  ) where
```

Internal structure (one file is enough at this stage; split out `Selector/*` in M2):

```haskell
data FzfConfig = FzfConfig
  { fzfBinary        :: !FilePath
  , fzfAvailable     :: !Bool
  , stdinIsTerminal  :: !Bool
  , stdoutIsTerminal :: !Bool
  , ttyAvailable     :: !Bool
  } deriving stock (Generic, Eq, Show)

data FzfOpts = FzfOpts
  { fzfPrompt  :: !(Maybe Text)
  , fzfHeader  :: !(Maybe Text)
  , fzfHeight  :: !(Maybe Text)
  , fzfAnsi    :: !Bool
  , fzfNoSort  :: !Bool
  } deriving stock (Generic, Eq, Show)

data Candidate a = Candidate
  { candidateDisplay :: !Text
  , candidateValue   :: !a
  } deriving stock (Functor)

data FzfResult a
  = FzfSelected !a
  | FzfNoMatch
  | FzfCancelled
  | FzfError !Text
  deriving stock (Functor)
```

`FzfOpts` has a right-biased `Semigroup`/`Monoid` instance and smart constructors that
each set one field on `mempty`, per §2 of the reference doc. `detectFzfConfig` uses
`System.Directory.findExecutable` and `System.IO.hIsTerminalDevice`, plus a `try`-guarded
`openFile "/dev/tty" ReadMode` for the tty probe. `isFzfAvailable cfg = fzfAvailable cfg
&& (stdinIsTerminal cfg || ttyAvailable cfg)`.

`runFzf` (§4 of the reference doc):

- Short-circuits to `FzfNoMatch` if `candidates` is empty (don't spawn fzf with an empty
  list).
- Short-circuits to `FzfError "fzf not available"` if `not (isFzfAvailable cfg)`.
  Callers are expected to check `isFzfAvailable` first; this is defence in depth.
- Builds the args list: `["-1", "--with-nth=2.."] ++ optsToArgs opts`.
- Builds `CreateProcess` with `std_in = CreatePipe`, `std_out = CreatePipe`,
  `std_err = Inherit`, `delegate_ctlc = True`.
- Writes each `"<i>\t<display>"` line to stdin, closes stdin, reads stdout with
  `hGetContents`, then `waitForProcess`. Parses the leading integer field of the only
  output line, looks it up in `Map Int a`. Exit `0` → `FzfSelected`; exit `1` →
  `FzfNoMatch`; exit `130` → `FzfCancelled`; any other exit → `FzfError`.
- Wraps the IO in `try @SomeException` so a thrown process error maps to `FzfError`.

**File:** `shiki-cli/src/Shiki/Cli/Env.hs` — extend `CliEnv`:

```haskell
data CliEnv = CliEnv
  { pool   :: !Pool.Pool
  , client :: !ClientEnv
  , fzf    :: !FzfConfig
  } deriving stock (Generic)
```

…and inside `withCliEnv` after `loadDefaultClientConfig`:

```haskell
fzfCfg <- detectFzfConfig
action CliEnv { pool = p, client = cl, fzf = fzfCfg }
```

No other handler needs to change yet; record-construction syntax with named fields means
the existing `withCliEnv` callers keep working.

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
  ( RunSelection (..)
  , defaultRunOpts
  , formatRunCandidate
  , selectRun
  , resolveRunId
  ) where

import Shiki.Cli.Env (CliEnv (..))
import Shiki.Cli.Fzf (Candidate (..), FzfOpts, FzfResult (..), isFzfAvailable, runFzf,
                      withAnsi, withHeight, withNoSort, withPrompt)
import Shiki.Persistence.Run (RunId (..), RunRecord, listRecentRunsStatement)

data RunSelection
  = RunChosen          !RunId !RunRecord
  | RunNoRows          -- table is empty
  | RunSelectionCancelled
  | RunFzfUnavailable
  | RunSelectionError  !Text

defaultRunOpts :: FzfOpts
defaultRunOpts = withPrompt "run> " <> withHeight "40%" <> withAnsi <> withNoSort

selectorRowLimit :: Int
selectorRowLimit = 50

formatRunCandidate :: RunRecord -> Candidate (RunId, RunRecord)

selectRun :: CliEnv -> IO RunSelection
resolveRunId :: CliEnv -> Maybe Text -> IO (Maybe Text)
```

`formatRunCandidate` produces something like:

```text
3f2c1a9d  2026-05-27 17:22:11  ingest    Succeeded  12s   exit=0  reindex --batch 100
```

Reuse the helpers already in `Shiki.Cli.Runs` (`humanDuration`, the per-column rendering)
— either move them into a small shared module or copy the few-line implementations. The
simpler path is to expose `humanDuration` + `renderRow` from `Shiki.Cli.Runs` (small
refactor: change two helpers from `where`-locals on `renderTable` to top-level
`module-private` bindings, then re-export). The selector calls them; existing
`renderTable` keeps working.

`selectRun` runs the read statement, builds candidates, calls `runFzf`, maps the result
to a `RunSelection`.

`resolveRunId cfg env mIdText` is the public entry point. Returns `IO (Maybe Text)` — the
text the existing handlers expect to feed into `findRunByPrefixStatement`. The three-way
dispatch:

```haskell
resolveRunId env = \case
  Just t  -> pure (Just t)                              -- positional present
  Nothing -> case isFzfAvailable (env ^. #fzf) of
    False -> do
      TIO.hPutStrLn stderr "shiki: no run id given and fzf is not available"
      pure Nothing
    True  -> do
      sel <- selectRun env
      case sel of
        RunChosen (RunId u) _    -> pure (Just (Text.pack (show u)))
        RunNoRows                -> TIO.putStrLn "(no runs recorded yet)"           *> pure Nothing
        RunSelectionCancelled    -> pure Nothing
        RunFzfUnavailable        -> pure Nothing  -- impossible: guarded above
        RunSelectionError e      -> TIO.hPutStrLn stderr ("shiki: fzf: " <> e) *> pure Nothing
```

The cancelled / no-rows / unavailable / error branches all return `Nothing` and the
caller exits non-zero (except cancelled, which exits 0 — see Decision Log on the
specific exit codes table in Validation and Acceptance).

**File:** `shiki-cli/shiki-cli.cabal` — add `Shiki.Cli.Fzf.Selector.Run` to
`exposed-modules`.

**File:** `shiki-cli/test/Shiki/Cli/Fzf/Selector/RunSpec.hs` — new test file with one or
two pure tests:

```haskell
tests :: TestTree
tests = testGroup "Shiki.Cli.Fzf.Selector.Run"
  [ testCase "formatRunCandidate produces single-line display" $
      let row = mkFixtureRow …
          c   = formatRunCandidate row
       in do
            assertBool "no embedded newlines"
              (not (Text.any (== '\n') (candidateDisplay c)))
            assertBool "id prefix appears in display"
              (Text.isInfixOf "3f2c1a9d" (candidateDisplay c))
  ]
```

Wire into `shiki-cli/test/Spec.hs`. Don't try to test `runFzf` end-to-end — it spawns a
subprocess and reads `/dev/tty`. The reference doc deliberately keeps the IO surface thin
so the pure parts are testable.

Acceptance:

```bash
just test
```

Includes the new test group and is green.

### Milestone 3 — Wire fzf into the four `runs` read subcommands

Scope: change the four `RunsCommand` constructors to `Maybe Text`, update the parser,
update the four handlers to call `resolveRunId` on `Nothing`. No new files.

**File:** `shiki-cli/src/Shiki/Cli/Runs.hs`:

```haskell
data RunsCommand
  = RunsList    !(Maybe Text) !Int
  | RunsShow    !(Maybe Text)
  | RunsLogs    !(Maybe Text)
  | RunsError   !(Maybe Text)
  | RunsAnalyze !(Maybe Text) !(Maybe AnalyzerKind)
```

In `runsParser`, replace each `argument str (metavar "ID")` with
`optional (argument str (metavar "ID" <> help "Run id; opens an fzf picker if omitted"))`.

Replace each handler with a small wrapper that resolves first:

```haskell
runRuns :: CliEnv -> RunsCommand -> IO ()
runRuns env = \case
  RunsList    mService limit -> doList    env mService limit
  RunsShow    mId            -> withResolved env mId doShow
  RunsLogs    mId            -> withResolved env mId doLogs
  RunsError   mId            -> withResolved env mId doError
  RunsAnalyze mId override   -> withResolved env mId (\e t -> doAnalyze e t override)

withResolved :: CliEnv -> Maybe Text -> (CliEnv -> Text -> IO ()) -> IO ()
withResolved env mIdText body = do
  mResolved <- resolveRunId env mIdText
  case mResolved of
    Just t  -> body env t
    Nothing -> exitFailure  -- resolveRunId already printed any error
```

The `doShow / doLogs / doError / doAnalyze` bodies keep their current
`findRunByPrefixStatement` call. This is one extra round-trip when fzf picks a row
(prefix → full row, then `findRunByPrefix` re-fetches the row by the full UUID); that's
fine for an interactive code path. The benefit is zero changes to the success branches.

**Cancellation exit code.** When the operator hits Esc in fzf, `resolveRunId` returns
`Nothing` *without* printing anything. The wrapper exits 1 (above). That matches Unix
convention for cancelled interactive input; document it in `docs/user/commands.md`.

Acceptance:

```bash
just build && just test
just up   # if not running
just shiki run echo -- echo hi   # twice, to seed runs
just shiki runs show              # fzf picker opens
just shiki runs show <prefix>     # unchanged
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
  ( ServiceSelection (..)
  , defaultServiceOpts
  , selectService
  , resolveServiceName
  ) where

data ServiceSelection
  = ServiceChosen           !Text  -- bare service name, sans .dhall
  | ServiceNoneFound
  | ServiceSelectionCancelled
  | ServiceFzfUnavailable
  | ServiceSelectionError   !Text
```

`selectService` enumerates `services/*.dhall` with `System.Directory.listDirectory`,
filters to entries ending in `.dhall`, strips the extension, sorts lexically, builds
`Candidate`s where display is just the bare name, calls `runFzf`. No DB hit.

`resolveServiceName` mirrors `resolveRunId`'s three-way dispatch.

**File:** `shiki-cli/src/Shiki/Cli.hs`:

```haskell
data Command
  = …
  | ServiceShow !(Maybe Text)
  …

serviceSubparser :: Parser Command
serviceSubparser =
  Opt.hsubparser
    ( Opt.command "show"
        ( Opt.info
            (ServiceShow <$> optional (Opt.argument Opt.str (Opt.metavar "NAME")))
            (Opt.progDesc "Pretty-print the parsed ServiceConfig for NAME (fzf if omitted)")
        )
    )
```

`service show` is the one subcommand in shiki that does **not** need a database
(`Shiki.Cli` short-circuits it before `withDbEnv`). But the service selector still needs a
`FzfConfig`. Two options:

1. Run `detectFzfConfig` directly in `serviceShowHandler` (no DB pool needed).
2. Promote `detectFzfConfig` out of `withCliEnv` into the top-level
   `runCli`, passing it into both `withDbEnv` and `serviceShowHandler`.

Pick option 1: it keeps `withCliEnv` as the only place that ever calls
`detectFzfConfig` for DB-backed handlers, and `serviceShowHandler` makes one extra
direct call. Trivially testable and avoids a parameter cascade.

```haskell
serviceShowHandler :: Maybe Text -> IO ()
serviceShowHandler (Just nm) = serviceShowOne nm
serviceShowHandler Nothing   = do
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
just shiki service show           # fzf opens; choose one
just shiki service show ingest    # unchanged
```

### Milestone 5 — Docs, smoke transcript, formatting

Scope: update operator docs, CHANGELOG, and run formatters.

**File:** `docs/user/commands.md` — for each of `shiki runs show`, `shiki runs logs`,
`shiki runs error`, `shiki runs analyze`, and `shiki service show`, edit the synopsis
line so `ID` / `NAME` is bracketed (optional) and add one short paragraph:

> If `ID` is omitted, shiki opens an `fzf` picker populated from the 50 most recent
> runs. Press Enter to select; Esc to cancel (exits 0, no error message). If `fzf` is not
> installed or no terminal is attached, shiki exits 1 with
> `shiki: no run id given and fzf is not available`.

Add a new top-level section after "Global options":

> ## Interactive selection (fzf)
>
> The read-only subcommands that take a positional `ID` or `NAME` accept the argument as
> optional. When omitted, shiki opens a fuzzy picker via the local `fzf` binary, lists the
> candidates from the canonical source (Postgres for runs, the `services/` directory for
> configs), and replaces the missing positional with whatever the operator picks. Precedence
> is **flag/positional > fzf > error**; passing the positional always skips the picker.

**File:** `CHANGELOG.md` — append an entry under the unreleased section. Use two
separate markdown blocks (a bulleted list, then a single-level fenced transcript) so
nothing nests:

```markdown
### Added

- `shiki runs show / logs / error / analyze` now accept the `ID` positional as
  optional; omitting it opens an `fzf` picker populated from the 50 most recent
  recorded runs.
- `shiki service show` accepts `NAME` as optional; omitting it opens an `fzf`
  picker populated from `services/*.dhall`.
```

Followed by a transcript fenced as `text`:

```text
$ shiki runs show
 ┌─────────────────────────────────────────────────────────────────┐
 │ 3f2c1a9d  2026-05-27 17:22:11  ingest  Succeeded  12s  exit=0   │
 │ 51a40b22  2026-05-27 17:19:08  worker  Failed     03s  exit=1   │
 │ …                                                               │
 │ run>                                                            │
 └─────────────────────────────────────────────────────────────────┘
{ "runId": "3f2c1a9d-…", "serviceName": "ingest", "status": "Succeeded", … }
```

**Format pass.** Run `nix fmt` (treefmt) on the new modules so trailing whitespace,
import ordering, and end-of-file newlines match the rest of the tree.

Acceptance:

```bash
nix fmt
just test
nix flake check
```

All three green.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/shiki` inside a `nix develop` shell.
Lines prefixed with `$` are commands; lines without are expected output excerpts.

### One-time bootstrap

```bash
$ nix develop
$ just up                          # if Postgres is not already up
$ just build                       # baseline green
$ just shiki runs list -l 3        # confirm there are recorded runs to pick from
```

If `runs list` is empty, seed a couple of runs:

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
$ $EDITOR shiki-cli/src/Shiki/Cli/Fzf/Selector/Run.hs     # new file
$ $EDITOR shiki-cli/src/Shiki/Cli/Runs.hs                 # promote humanDuration / renderRow if needed
$ $EDITOR shiki-cli/shiki-cli.cabal                       # expose Selector.Run, add to test other-modules
$ $EDITOR shiki-cli/test/Shiki/Cli/Fzf/Selector/RunSpec.hs # new file
$ $EDITOR shiki-cli/test/Spec.hs                          # wire the new test group
$ just test
```

Expected:

```text
shiki-cli
  …
  Shiki.Cli.Fzf.Selector.Run
    formatRunCandidate produces single-line display:   OK
    formatRunCandidate embeds id prefix:               OK

All 1X tests passed
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

Expected interactive transcript for the no-arg case (the box is fzf's TUI; the JSON is
the existing `runs show` output for the chosen row):

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

Expected fzf-missing:

```text
$ env PATH=/usr/bin shiki runs show
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

Expected interactive transcript:

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
$ nix flake check
```

Expected: all three commands exit 0. The CHANGELOG transcript matches the actual output
of `shiki runs show` against the seeded runs.

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
operator types; "Observed" is what shiki does; "Exit" is the process exit code.

| # | Inputs                                       | Observed                                                                          | Exit |
|---|----------------------------------------------|-----------------------------------------------------------------------------------|------|
| 1 | `shiki runs show <unambiguous-prefix>`       | Pretty-prints the row's JSON. (Unchanged from EP-5.)                              | 0    |
| 2 | `shiki runs show <ambiguous-prefix>`         | `ambiguous id prefix <prefix>`. (Unchanged.)                                      | 1    |
| 3 | `shiki runs show <nonexistent-prefix>`       | `no run matching <prefix>`. (Unchanged.)                                          | 1    |
| 4 | `shiki runs show` (no arg, ≥1 run in DB)     | fzf picker opens; on Enter, the JSON for the picked row prints.                   | 0    |
| 5 | `shiki runs show` (no arg, empty `runs`)     | `(no runs recorded yet)`; no picker.                                              | 1    |
| 6 | `shiki runs show` (no arg) + Esc             | No JSON, no error message.                                                        | 1    |
| 7 | `shiki runs show` (no arg) + Ctrl-C in fzf   | No JSON, no traceback (delegate_ctlc absorbs the signal).                         | 1    |
| 8 | `env PATH=/usr/bin shiki runs show` (no arg) | `shiki: no run id given and fzf is not available` on stderr.                      | 1    |
| 9 | `shiki runs logs` / `runs error` / `runs analyze` (no arg)  | Same picker; on Enter, the per-subcommand behaviour against the row.  | 0 or 1 by subcommand|
| 10 | `shiki service show <existing-name>`         | Prints JSON. (Unchanged.)                                                         | 0    |
| 11 | `shiki service show <missing-name>`          | Dhall load error to stderr. (Unchanged.)                                          | non-zero |
| 12 | `shiki service show` (no arg)                | fzf picker over `services/*.dhall`; on Enter, the JSON for the chosen config.     | 0    |
| 13 | `shiki service show` (no arg, no `.dhall` files) | `(no service configs found in services/)`; no picker.                         | 1    |
| 14 | `shiki run <svc> -- echo hi`                 | Unchanged — submits a Job. **No fzf integration on `shiki run`.**                 | 0 / non-zero |
| 15 | `shiki --help`                               | Lists `runs`, `run`, `service`, `agent` as before. (Help text mentions the picker for the changed subcommands.) | 0 |

### Test commands

```bash
cd /Users/shinzui/Keikaku/bokuno/shiki
just test
```

The new unit tests (`Shiki.Cli.Fzf.Selector.RunSpec`) verify the pure parts of the run
selector. There is no end-to-end test of the fzf subprocess; the reference architecture
deliberately keeps the IO surface thin so the testable parts are pure (the formatter, the
candidate-list builder, the result-dispatch case statement on `FzfResult`).

If a future plan needs to test the subprocess path, the right approach is to inject a
mock binary on `PATH` (a shell script that echoes a chosen index back to stdin) and call
`runFzf` with an in-process candidate list — but that is out of scope here.

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

Each of these must produce identical output to a build from `master` (modulo the new
"(uses fzf if not provided)" string in `--help` for the changed subcommands).


## Idempotence and Recovery

This plan adds new code only. No migrations, no schema changes, no destructive
operations.

- **Build steps** (`just build`, `just test`) are idempotent — re-run freely.
- **Picker invocations** are read-only: `selectRun` issues a `SELECT … FROM runs ORDER BY
  started_at DESC LIMIT 50`; `selectService` does a `listDirectory`. Cancelling
  (Esc / Ctrl-C) leaves no side effects.
- **Resolved IDs** are fed back into the same `findRunByPrefixStatement` the
  positional path uses, so behaviour after the picker is byte-for-byte identical to a
  positional invocation with the full UUID — same exit codes, same error messages, same
  JSON output.
- **`runs analyze`** does write through `updateErrorSummaryStatement`, but that statement
  is an `UPDATE … SET error_summary = …` keyed on `id`; calling it twice on the same row
  produces the same final state. Re-picking the same row and pressing Enter is safe.

### Rollback

If a milestone needs to be reverted:

- M1 (the cabal + Env changes) is reverted by `git revert` of the M1 commit. No persisted
  state to clean up.
- M2-M4 each touch only `shiki-cli/src/Shiki/Cli/Fzf*` and the parser. `git revert` of
  the milestone commit is sufficient; the binary returns to its previous behaviour.
- M5 is a docs-only commit. `git revert` if it goes out wrong.

There is no need to flush a cache, restart a process, or roll back a migration — fzf
integration is entirely in-process. The PostgreSQL connection pool and migrations are
unaffected.

### Recovery if a picker is invoked on a misconfigured DB

If `selectRun` is called when the pool is unhealthy (DB down, schema missing, etc.), the
underlying `Pool.use` returns a `Left` that the existing `runRead` helper turns into a
fatal `error`. That behaviour matches the rest of the read subcommands; no fzf-specific
handling is needed.


## Interfaces and Dependencies

### Libraries used

| Library             | Why                                                                            |
|---------------------|--------------------------------------------------------------------------------|
| `process` (≥1.6)    | `System.Process` for `createProcess` / `waitForProcess` / `CreateProcess`-with-`delegate_ctlc` |
| `containers` (≥0.7) | `Data.Map.Strict` for the `Int → a` index→value lookup                          |
| `directory` (already a dep) | `findExecutable "fzf"` and `listDirectory "services"`                  |
| `text` (already a dep)      | `Text` is the project-wide string type                                 |
| `hasql-pool` (already a dep)| Reuse of `Pool.use` + `Session.statement` for the candidate query      |

The flake's GHC pin already ships these versions; no flake input changes are expected. If
`cabal build` reports a missing index, run `cabal update` once.

### External system: fzf

- Binary: `fzf` (≥0.40 recommended; 0.71 is the version on the user's nix profile).
- Invocation: subprocess with `--with-nth=2..` to hide the index column; `-1` to
  auto-select when exactly one candidate matches; `--ansi`, `--no-sort`, `--prompt`,
  `--header`, `--height` per `FzfOpts`.
- Signals: Ctrl-C delivered to the parent is forwarded to fzf via
  `delegate_ctlc = True`; fzf exits 130, which `runFzf` maps to `FzfCancelled`.
- Streams: stdin (piped, newline-delimited `"<i>\t<display>"` lines), stdout (piped,
  one line containing the chosen index), stderr (inherited so fzf's TUI renders to the
  terminal).

### Module signatures at each milestone

#### After M1

`Shiki.Cli.Fzf` exports:

```haskell
data FzfConfig = FzfConfig
  { fzfBinary        :: !FilePath
  , fzfAvailable     :: !Bool
  , stdinIsTerminal  :: !Bool
  , stdoutIsTerminal :: !Bool
  , ttyAvailable     :: !Bool
  } deriving stock (Generic, Eq, Show)

detectFzfConfig :: IO FzfConfig
isFzfAvailable  :: FzfConfig -> Bool

data FzfOpts = FzfOpts
  { fzfPrompt :: !(Maybe Text)
  , fzfHeader :: !(Maybe Text)
  , fzfHeight :: !(Maybe Text)
  , fzfAnsi   :: !Bool
  , fzfNoSort :: !Bool
  } deriving stock (Generic, Eq, Show)

instance Semigroup FzfOpts
instance Monoid    FzfOpts

withPrompt :: Text -> FzfOpts
withHeader :: Text -> FzfOpts
withHeight :: Text -> FzfOpts
withAnsi   :: FzfOpts
withNoSort :: FzfOpts

data Candidate a = Candidate
  { candidateDisplay :: !Text
  , candidateValue   :: !a
  } deriving stock (Functor)

data FzfResult a
  = FzfSelected !a
  | FzfNoMatch
  | FzfCancelled
  | FzfError !Text
  deriving stock (Functor)

runFzf :: FzfConfig -> FzfOpts -> [Candidate a] -> IO (FzfResult a)
```

`Shiki.Cli.Env.CliEnv` gains:

```haskell
data CliEnv = CliEnv
  { pool   :: !Pool.Pool
  , client :: !ClientEnv
  , fzf    :: !FzfConfig
  } deriving stock (Generic)
```

#### After M2

`Shiki.Cli.Fzf.Selector.Run` exports:

```haskell
data RunSelection
  = RunChosen              !RunId !RunRecord
  | RunNoRows
  | RunSelectionCancelled
  | RunFzfUnavailable
  | RunSelectionError      !Text

defaultRunOpts     :: FzfOpts
formatRunCandidate :: RunRecord -> Candidate (RunId, RunRecord)
selectRun          :: CliEnv -> IO RunSelection
resolveRunId       :: CliEnv -> Maybe Text -> IO (Maybe Text)
```

#### After M3

`Shiki.Cli.Runs.RunsCommand` becomes:

```haskell
data RunsCommand
  = RunsList    !(Maybe Text) !Int
  | RunsShow    !(Maybe Text)
  | RunsLogs    !(Maybe Text)
  | RunsError   !(Maybe Text)
  | RunsAnalyze !(Maybe Text) !(Maybe AnalyzerKind)
```

`runRuns :: CliEnv -> RunsCommand -> IO ()` keeps its signature.

#### After M4

`Shiki.Cli.Fzf.Selector.Service` exports:

```haskell
data ServiceSelection
  = ServiceChosen            !Text  -- bare name, no .dhall
  | ServiceNoneFound
  | ServiceSelectionCancelled
  | ServiceFzfUnavailable
  | ServiceSelectionError    !Text

defaultServiceOpts  :: FzfOpts
selectService       :: FzfConfig -> IO ServiceSelection
resolveServiceName  :: FzfConfig -> IO (Maybe Text)
```

`Shiki.Cli.Command.ServiceShow` becomes `ServiceShow !(Maybe Text)`.

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
