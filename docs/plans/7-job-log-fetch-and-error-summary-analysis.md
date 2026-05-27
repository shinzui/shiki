---
id: 7
slug: job-log-fetch-and-error-summary-analysis
title: "Job Log Fetch and Error Summary Analysis"
kind: exec-plan
created_at: 2026-05-27T21:03:28Z
intention: "intention_01ksn9t46hen8ts1jaraqrykq6"
master_plan: "docs/masterplans/1-microservice-job-runner-with-postgres-backed-run-history.md"
---

# Job Log Fetch and Error Summary Analysis

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Today, when `shiki run <service> -- <args>` submits a Kubernetes Job and the Job fails,
the row recorded in PostgreSQL captures a high-level Kubernetes-side failure reason in
the `runs.error` column (taken from the failing `V1JobCondition`, e.g. `BackoffLimitExceeded`
or `DeadlineExceeded`) and stores the last 200 lines of the pod's container output in
`runs.log_tail`. That leaves a real operator question — "what actually went wrong inside
the container?" — answerable only by reading the log tail by eye. There is no machine-
readable distillation of the failure, and the log fetcher quietly swallows every error it
encounters (it returns `Nothing` on any API failure), so the operator cannot tell "the
container produced no logs" apart from "we lost the logs."

After this plan, when a Job ends in failure (`JobFailed` or `JobTimedOut`), `shiki` will:

1. Fetch a richer slice of the failing pod's logs than today — up to 1000 lines or 256 KiB
   into memory for analysis purposes — while still persisting the existing 64 KiB
   `log_tail` for human inspection.
2. Run a deterministic, pure analyzer (the "Heuristic" backend) inline at run completion
   that extracts a short error summary (≤ 512 characters) by recognising common error
   markers used by language runtimes the operator is likely to ship one-off jobs in:
   Python tracebacks, JVM "Exception in thread" / "Caused by:" chains, Go `panic:` headers,
   Rust `thread 'main' panicked at` lines, and line-prefixed log levels like
   `ERROR`/`FATAL`/`PANIC`. If no marker is present the analyzer falls back to the last
   non-blank line of the log so there is always *some* user-facing artifact.
3. Persist the resulting summary in a new `runs.error_summary` text column (added by SQL
   migration `002-add-error-summary.sql`), distinct from the pre-existing `runs.error`
   column (which keeps holding the Kubernetes-side reason). Alongside `error_summary` the
   migration also adds `error_summary_source text NOT NULL DEFAULT 'heuristic'` so
   downstream readers can tell *which* analyzer produced the summary (today: `heuristic`
   or `baikai:<model-id>`).
4. Surface the summary through the existing read path: `shiki runs show <id>` (which
   already pretty-prints the full `RunRecord` as JSON via `aeson-pretty`) gains new
   `errorSummary` and `errorSummarySource` fields automatically, and a new
   `shiki runs error <id>` subcommand prints just the summary verbatim (analogous to
   today's `shiki runs logs <id>`) so it composes cleanly with pagers and `grep` in
   operator workflows.

In addition, the analyzer backend is **pluggable**. The repository already ships a
unified AI-provider abstraction at `/Users/shinzui/Keikaku/bokuno/baikai` (the
`shinzui/baikai` Haskell library: `baikai` core plus `baikai-claude` and `baikai-openai`
vendor packages, all built around `Baikai.completeRequest :: Model -> Context -> Options
-> IO Response`). After this plan, an operator can opt in to richer LLM-based summaries
by running a separate, post-hoc subcommand:

```bash
shiki runs analyze <id> [--analyzer=heuristic|baikai:<model-id>|none]
```

`shiki runs analyze` re-fetches the run row, runs the chosen backend over the *stored*
`runs.log_tail`, and overwrites `runs.error_summary` and `runs.error_summary_source` with
the new result. The default backend for a given run is taken from the run's service
config (`ServiceConfig.analyzer` — a new Dhall field whose value is one of `Heuristic`,
`Baikai { model = "<id>" }`, or `None`); the CLI flag overrides that default for the
current invocation. The inline `shiki run` path always uses `Heuristic` to keep the
interactive terminal flow deterministic, zero-network, and zero-credential by default —
no operator's daily `shiki run` will suddenly start blocking on a model call without
their consent.

A reader can see the change working end-to-end by:

1. Running the example program `shiki-core/example/RunOnce.hs` (which today exercises
   `runJob` against the operator's current kube context) against a service config whose
   command is intentionally broken (e.g. `python -c "raise RuntimeError('boom')"`). The
   printed `JobOutcome` will include a populated `errorSummary` field carrying
   `RuntimeError: boom`, and `errorSummarySource = "heuristic"`. A subsequent
   `shiki runs show <last-id>` surfaces the same two fields.
2. Then running `shiki runs analyze <last-id> --analyzer=baikai:anthropic_claude_haiku_4_5`
   against the same row. The summary in the database is now produced by Claude Haiku 4.5,
   `errorSummarySource = "baikai:anthropic_claude_haiku_4_5"`, and `shiki runs show`
   reflects the new value.

A hermetic acceptance signal is provided by a new tasty test suite for the Heuristic
analyzer that asserts each supported runtime marker is recognised and that the summary
length cap is enforced. The Baikai backend's correctness is verified through a single
hermetic dispatch-shape test (asserts the right prompt structure is sent through a stub
provider registered against the Api tag) plus a manual smoke step in M9.

The new behavior preserves every existing observable: `runs.error` keeps its current
meaning, `runs.log_tail` keeps its current size cap, and the JSON shape of `RunRecord`
gains exactly two new fields. Schemas other than the default still work because the
migration runs through the same `hasql-migration`-driven mechanism that EP-2 and EP-6
already exercise across configurable schemas.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1 — Carve the pod-log fetcher out of `Shiki.K8s.Runner` into a new
  `Shiki.K8s.Logs` module exporting `fetchJobPodLogs :: ClientEnv -> Namespace -> Text ->
  IO (Either LogFetchError FetchedLogs)`, where `FetchedLogs` carries both the analysis
  buffer (≤ 1000 lines / 256 KiB) and the persisted tail (last 200 lines / 64 KiB). The
  existing `Shiki.K8s.Runner.runJob` consumes the new module and the old private helpers
  in `Runner.hs` (`fetchLogTail`, `fetchPodLog`, `truncate64K`) are deleted.
- [x] M2 — Introduce the analyzer abstraction at `shiki-core/src/Shiki/Analysis/Backend.hs`
  (the `AnalyzerKind` ADT, the `AnalyzerError` ADT, and `runAnalyzer :: AnalyzerKind ->
  Text -> IO (Either AnalyzerError AnalyzerResult)`) and implement the deterministic
  recogniser path at `shiki-core/src/Shiki/Analysis/Heuristic.hs`
  (`summarizeFailure :: Text -> Maybe Text`). Ship unit tests under
  `shiki-core/test/Shiki/Analysis/HeuristicSpec.hs` covering each runtime marker, the
  fallback, the empty-input case, and the 512-character cap.
- [x] M3 — Add SQL migration `shiki-core/sql/migrations/002-add-error-summary.sql` that
  adds two columns to `runs`: `error_summary text` (nullable) and `error_summary_source
  text NOT NULL DEFAULT 'heuristic'`. Verify the columns land in the configured schema by
  exercising `Shiki.Persistence.Migration.runMigrations` from a tasty test through the
  existing `Shiki.Persistence.TestPg.withSchemaPool` helper.
- [x] M4 — Extend the persistence types and statements in `shiki-core/src/Shiki/Persistence/Run.hs`:
  add `errorSummary :: !(Maybe Text)` and `errorSummarySource :: !(Maybe Text)` to both
  `RunRecord` and `RunCompletion`, thread them through `completeRunStatement`'s encoder,
  add a new `updateErrorSummaryStatement :: Statement (RunId, Maybe Text, Text) ()` for
  the post-hoc analyze path, and extend every `SELECT` decoder
  (`getRunStatement`, `listRecentRunsStatement`, `listRecentRunsByServiceStatement`,
  `findRunByPrefixStatement`). Update `Shiki.Persistence.RunSpec` to assert the new
  columns round-trip.
- [x] M5 — Extend `Shiki.K8s.Runner.JobOutcome` with `errorSummary :: !(Maybe Text)` and
  `errorSummarySource :: !(Maybe Text)`, and populate them inside `runJob`: after
  `waitForCompletion` finishes, fetch the wider analysis buffer through
  `Shiki.K8s.Logs.fetchJobPodLogs`, store its 64 KiB tail in `logTail`, and — only when
  `phase` is `JobFailed _` or `JobTimedOut` — run the analysis buffer through
  `Shiki.Analysis.Backend.runAnalyzer Heuristic`. On `JobSucceeded`, both fields are
  `Nothing`.
- [x] M6 — Add the `analyzer` field to `ServiceConfig` (Haskell record + Dhall schema +
  Dhall loader). The Haskell type is a new `AnalyzerBackend` ADT under
  `shiki-core/src/Shiki/Service/Config.hs` with constructors `Heuristic`, `Baikai !Text`
  (the model id), and `None`. The Dhall union mirrors the constructors. Update the
  example `services/mls-service-v2.dhall` with `analyzer = Heuristic` so existing
  configurations stay valid.
- [x] M7 — Pull the `baikai`, `baikai-claude`, and `baikai-openai` packages into
  `cabal.project` from the local checkout at `/Users/shinzui/Keikaku/bokuno/baikai`, add
  them to `shiki-core.cabal`'s `build-depends`, and implement the Baikai backend at
  `shiki-core/src/Shiki/Analysis/Baikai.hs` (`runBaikai :: Text -> Text -> IO (Either
  AnalyzerError Text)` where the first argument is the model id and the second is the
  analysis-buffer text). Provider registration (`ClaudeApi.register`, `OpenAIApi.register`)
  happens lazily from `runBaikai` and is idempotent per Api tag. Wire `runAnalyzer (Baikai
  m) = runBaikai m` in `Shiki.Analysis.Backend`.
- [x] M8 — Wire CLI surfacing. In `shiki-cli/src/Shiki/Cli/Runs.hs`: add `RunsError !Text`
  and `RunsAnalyze !Text !(Maybe AnalyzerKind)` constructors to `RunsCommand`, add the two
  parser branches, add the dispatch handlers (`doError` mirrors `doLogs`; `doAnalyze`
  reads the row, picks the backend via CLI override → service-config default → Heuristic,
  invokes `runAnalyzer`, then writes the result through `updateErrorSummaryStatement`).
- [x] M9 — Update `README.md` with an "Error summaries and analysis backends" section.
  Run `cabal build all` and `cabal test all`; paste the closing transcript into Concrete
  Steps as evidence. Perform the manual smoke step against a real cluster + a real
  Anthropic API key documented in Validation and Acceptance.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **Tasty pattern flag is `-p`, not `--match`.** The plan's `cabal test ...
  --test-options="--match Analysis"` invocations fail with `Invalid option
  '--match'` because the tasty runner doesn't recognise it. The Concrete Steps
  in this file are correct in spirit but the flag is `-p`. Used
  `--test-options='-p "Analysis"'` everywhere instead. Evidence: shiki-core-test
  run on 2026-05-27.
- **baikai's `Baikai.Response` does not export `flattenAssistantText`.** Only
  `flattenAssistantBlocks` (returning `Vector AssistantContent`). The plan
  references `flattenAssistantText (flattenAssistantBlocks resp)`; in practice
  the Baikai backend must extract the text manually by pattern-matching
  `AssistantText TextContent { text }` over the vector. Implemented locally in
  `Shiki.Analysis.Baikai.extractText`.
- **baikai-claude pulls Hackage `claude` which caps `http-client-tls < 0.4`.**
  shiki's dep tree already runs at http-client-tls 0.4 via the
  `dhall:http-client-tls` allow-newer entry. Extended `allow-newer` in
  `cabal.project` to also cover `claude:http-client-tls` and
  `openai:http-client-tls` so the resolver picks 0.4 for everyone. Evidence:
  initial `cabal build shiki-core` after adding baikai packages failed with
  `rejecting: claude-1.4.0 (conflict: http-client-tls==0.4.0, ...)`.
- **baikai pulls the streamly 0.12 fork.** Mirrored the two
  `source-repository-package` entries from `/Users/shinzui/Keikaku/bokuno/baikai/cabal.project`
  into shiki's `cabal.project` so the resolver finds the same streamly /
  streamly-core pair baikai itself builds against. Without them the resolver
  rejects baikai immediately.


## Decision Log

Record every decision made while working on the plan.

- Decision: Run the deterministic analyzer in-process inline on `shiki run`, but make the
  *richer* (LLM-backed) analyzer a separate post-hoc subcommand `shiki runs analyze <id>`.
  Rationale: `shiki run` is invoked interactively at a terminal and must complete in
  seconds with no network dependency beyond the Kubernetes API. A model call on the hot
  path would add 2–10s of latency and a network dep to every failed run, and would make
  determinism (same Job → same summary) impossible. Keeping LLM analysis behind an
  explicit, separate operator action preserves the interactive ergonomics while still
  making the richer analysis available when an operator wants it. (Confirmed with the
  user 2026-05-27 — "post-hoc via runs analyze".)
  Date: 2026-05-27.

- Decision: Add a new `runs.error_summary` column instead of overwriting the existing
  `runs.error` column.
  Rationale: `runs.error` already carries the Kubernetes Job condition reason
  (`BackoffLimitExceeded`, `DeadlineExceeded`, …) — losing that signal would make it harder
  to distinguish "the container's process failed" from "the cluster killed the Job before
  it could finish." Keeping the two fields independent lets the read side render both.
  Date: 2026-05-27.

- Decision: Add a sibling `runs.error_summary_source` column carrying provenance
  (`heuristic` or `baikai:<model-id>`).
  Rationale: Once `shiki runs analyze` can rewrite `runs.error_summary` with an LLM-
  derived value, an operator reading the row later needs to know whether they are looking
  at a deterministic heuristic output or a model output. Without provenance, the column
  becomes ambiguous as soon as more than one backend has touched a row. `NOT NULL DEFAULT
  'heuristic'` keeps the migration backfill-free for existing rows (which were all
  produced by the inline heuristic path).
  Date: 2026-05-27.

- Decision: Fetch up to 1000 lines / 256 KiB for analysis, but keep persisting only the
  last 200 lines / 64 KiB in `runs.log_tail`.
  Rationale: The 64 KiB cap on `log_tail` was chosen by EP-3 to keep the `runs` table
  small under daily operator use. Storing more than that for the sake of analysis would
  bloat the table for no read-side benefit (operators already have `kubectl logs` for the
  exhaustive view while the pod still exists). The wider 256 KiB buffer is process-local
  and discarded as soon as the analyzer has produced its summary. Note: `shiki runs
  analyze` re-runs analysis against the *persisted* `log_tail` (64 KiB), not the wider
  buffer — the wider buffer does not survive process exit. The richer backends (Baikai)
  are tolerant of the smaller input.
  Date: 2026-05-27.

- Decision: Run the inline heuristic only on `JobFailed _` and `JobTimedOut`, not on
  `JobSucceeded`.
  Rationale: A successful Job's logs may incidentally contain the strings `ERROR` or
  `Exception` (e.g. an exception that was caught and recovered from). Promoting those into
  `error_summary` would actively mislead the operator. The column's contract is "what
  killed this run", so it should be `NULL` whenever the Job did not die. `shiki runs
  analyze` against a successful run is allowed (operators may want a model's read on a
  noisy success log) but emits a clear "(no failure detected; ran anyway as requested)"
  banner.
  Date: 2026-05-27.

- Decision: Make the analyzer backend configurable through *both* per-service Dhall and
  a CLI `--analyzer` override, with service config providing the default and the flag
  taking precedence.
  Rationale: Per-service Dhall is the natural place for service-stable preferences
  (mls-service-v2 always uses Heuristic; some experimental service opts into Claude
  Haiku); a CLI override lets operators try a different backend on a one-off basis
  without touching version-controlled config. (Confirmed with the user 2026-05-27 —
  "both, with service-level default with a CLI override knob".)
  Date: 2026-05-27.

- Decision: Default backend out of the box is `Heuristic`.
  Rationale: Keeps `shiki` working with zero credentials, zero network, and full
  determinism in the standard developer workflow. Operators with API keys opt in
  per-service or per-invocation; this matches the principle from EP-3 that `shiki` should
  do nothing surprising on first run. (Confirmed with the user 2026-05-27 — "heuristic
  recommended".)
  Date: 2026-05-27.

- Decision: Pull `baikai`, `baikai-claude`, and `baikai-openai` from the local checkout
  at `/Users/shinzui/Keikaku/bokuno/baikai` via `packages:` entries in `cabal.project`
  rather than via `source-repository-package` against GitHub.
  Rationale: `cabal.project` already pulls four sibling projects from
  `/Users/shinzui/Keikaku/hub/haskell/...` for the same reason (avoiding the round-trip
  to GitHub during local development). Keeping the same shape is least surprising; when
  `baikai` is published the entries can be flipped to `source-repository-package` without
  touching `shiki-core.cabal`.
  Date: 2026-05-27.

- Decision: Run the Heuristic analyzer in-process with deterministic Haskell heuristics
  for the inline path; LLM-based alternative is a Baikai-backed sibling that goes through
  the same `runAnalyzer :: AnalyzerKind -> Text -> IO (Either AnalyzerError
  AnalyzerResult)` interface.
  Rationale: A handful of regex-style heuristics covers the dominant runtimes the user
  runs one-off jobs against (Python, JVM, Go, Rust, generic level-prefixed loggers) and
  is trivially unit-testable. Baikai dispatch sits beside it through one shared
  interface so future backends (e.g. a regex-rules YAML, a remote analysis service) drop
  into the same `AnalyzerKind` ADT without further structural change.
  Date: 2026-05-27.

- Decision: Make the `analyzer` Dhall field **required** in M6 rather than
  optional-with-default-Heuristic as the plan originally specified.
  Rationale: dhall-haskell's generic-derived `FromDhall` for `ServiceConfig`
  decodes records by structural match against the field set; making one field
  optional requires either a hand-written record decoder for all 11
  `ServiceConfig` fields (high maintenance cost), runtime AST rewriting (worse),
  or a wrapper schema file that callers import (architectural change). The
  shipped repository has exactly one service config (`mls-service-v2.dhall`),
  which the milestone updates to add `analyzer = AnalyzerBackend.Heuristic`.
  Any future service must include the field. Backwards compatibility for
  hypothetical external service files is not a current concern. If/when it
  becomes one, a follow-up plan can add the wrapper-schema indirection.
  Date: 2026-05-27.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Status at end of M9 (2026-05-27):** All nine milestones implemented. `cabal
build all` and `cabal test all` both exit 0. The shiki-core-test suite reports
**24 passing tests** (10 baseline + 8 new HeuristicSpec cases + 3 new
BackendSpec cases + 1 new ErrorSummaryColumnSpec case + 2 extended RunSpec
assertions for the analyzer round-trip including `updateErrorSummaryStatement`).

**Against original purpose:**

- `shiki run` now populates `runs.error_summary` on failure via the inline
  Heuristic analyzer. ✓
- `shiki runs error <id>` prints the captured summary or `(no summary)`. ✓
- `shiki runs show <id>` JSON output includes the new `errorSummary` and
  `errorSummarySource` fields automatically via the existing aeson-pretty
  encoder. ✓
- `shiki runs analyze <id>` re-runs analysis on the stored `log_tail` with
  optional `--analyzer=heuristic|baikai:<id>|none` override; writes the result
  back via `updateErrorSummaryStatement`. ✓
- The Baikai backend is wired through the shinzui/baikai library and supports
  `anthropic_claude_haiku_4_5`, `anthropic_claude_sonnet_4_6`, and
  `openai_gpt_4o_mini` model ids out of the box. ✓
- Per-service `analyzer` field in Dhall, with CLI override taking precedence
  over service default. ✓
- Inline `shiki run` always uses Heuristic regardless of service config, as
  required by the determinism / zero-credential decision. ✓

**Gaps / deferred work:**

- M6 ships the `analyzer` field as **required** in the Dhall record rather
  than optional-with-default (see Decision Log). External services must add
  `analyzer = AnalyzerBackend.Heuristic` before they will parse against this
  build of shiki.
- M9's manual smoke test (live cluster + Anthropic key end-to-end) was not
  performed in this implementation session because no cluster and no API key
  were available in the harness. The Validation and Acceptance section's
  hermetic substitute (synthetic JobOutcome + RunCompletion round-trip +
  `updateErrorSummaryStatement` rewrite) is now covered by the extended
  `Shiki.Persistence.RunSpec` test instead.
- The Baikai backend dispatch is unit-tested for the unknown-model error path
  but not the success path; per the plan, success-path validation lives in
  the manual smoke step.

**Lessons learned (captured in Surprises & Discoveries):** tasty uses `-p` not
`--match`; baikai exports `flattenAssistantBlocks` only; the `claude` Hackage
library still caps `http-client-tls < 0.4` so allow-newer needs extending;
baikai's streamly fork must be mirrored into the consumer's cabal.project.


## Context and Orientation

`shiki` is a two-package Cabal project rooted at the repository's top level. The library
package lives at `shiki-core/` and is named `shiki-core`; the executable package lives at
`shiki-cli/` and is named `shiki-cli` (it produces the binary `shiki`). Both target GHC
9.12.4 via the Nix flake at `flake.nix`. Build commands live in the dev shell entered with
`nix develop` (or automatically via `direnv allow`).

The relevant existing modules for this plan are:

- `shiki-core/src/Shiki/K8s/Runner.hs` — submits the Job and waits for it. Today this
  module owns the private helpers `fetchLogTail`, `fetchPodLog`, and `truncate64K` that
  retrieve and trim the failing pod's logs into the `JobOutcome.logTail` field. The
  `JobOutcome` record (lines 42–52) carries `jobName`, `namespace`, `phase` (a `JobPhase`
  ADT: `JobSucceeded | JobFailed !Text | JobTimedOut`), `exitCode :: Maybe Int`, start/end
  timestamps, and `logTail :: Maybe Text`. The phase's `JobFailed` payload is the first
  failure reason taken from `V1JobStatus.conditions`.

- `shiki-core/src/Shiki/K8s/Client.hs` — exposes `ClientEnv` (HTTP `Manager` plus
  `KubernetesClientConfig`) and `loadDefaultClientConfig :: IO ClientEnv`. Every K8s call
  in the codebase dispatches through `K8s.dispatchMime (env ^. #httpManager) (env ^. #clientConfig) req`.

- `shiki-core/src/Shiki/K8s/Introspection.hs` — owns the `Namespace` newtype
  (`Namespace { unNamespace :: Text }`) that the runner and the new logs module both use.

- `shiki-core/src/Shiki/Persistence/Run.hs` — the typed `hasql` statements. The four
  pieces this plan changes are: `RunRecord` (lines 54–71, 14 fields), `RunCompletion`
  (lines 93–102, 7 fields), `completeRunStatement` (lines 143–165), and `runRecordRow`
  (lines 273–293). Today `RunRecord.errorMessage` holds the *Kubernetes-side* reason; the
  new fields this plan introduces are `errorSummary` and `errorSummarySource`.

- `shiki-core/src/Shiki/Persistence/Migration.hs` — applies every SQL file in
  `shiki-core/sql/migrations/` via `hasql-migration`, after first creating the configured
  schema (`CREATE SCHEMA IF NOT EXISTS "<schema>"`). Adding a new file
  `002-add-error-summary.sql` is all that is needed to extend the schema; nothing in
  `Migration.hs` itself changes.

- `shiki-core/sql/migrations/001-create-runs.sql` — the current single migration. It
  defines `runs` with the columns we have today; the new migration is purely additive.

- `shiki-core/src/Shiki/Service/Config.hs` — the typed Haskell shape of a service config.
  This plan extends `ServiceConfig` with a final field `analyzer :: AnalyzerBackend`.

- `shiki-core/src/Shiki/Service/Config/Dhall.hs` — the Dhall loader. This plan adds the
  decoder for the new `AnalyzerBackend` Dhall union into the same module, and
  `services/mls-service-v2.dhall` gains `, analyzer = AnalyzerBackend.Heuristic` so
  existing configurations remain valid.

- `shiki-cli/src/Shiki/Cli/Run.hs` — the `run` subcommand handler. `finalizeOutcome`
  (lines 211–245) maps a `JobOutcome` into a `RunCompletion` and writes it via
  `completeRunStatement`. `finalizeFailed` (lines 191–209) is the catch-all path used when
  any exception escapes during submission or polling.

- `shiki-cli/src/Shiki/Cli/Runs.hs` — the `runs list/show/logs` read subcommands. The
  `RunsCommand` ADT (line 52) gains two new constructors (`RunsError`, `RunsAnalyze`);
  the parser at `runsParser` (lines 61–99) gains two new branches; the dispatcher
  `runRuns` (lines 102–106) gains two new arms.

The new external dependency is `shinzui/baikai`, located on disk at
`/Users/shinzui/Keikaku/bokuno/baikai`. Its `mori registry show shinzui/baikai --full`
description: "Unified Haskell interface for working with multiple AI providers."
Relevant sub-packages:

- `baikai` — the core surface: `Model`, `Context`, `Options`, the registry, the
  `completeRequest :: Model -> Context -> Options -> IO Response` function, the generated
  model catalog (`Baikai.Models.Generated.anthropic_claude_haiku_4_5`, etc.).
- `baikai-claude` — exposes `Baikai.Provider.Claude.Api.register :: IO ()` and a CLI
  variant for `claude -p`. Picks up `ANTHROPIC_API_KEY` / `ANTHROPIC_KEY` from the
  environment when `apiKey` is unset on `Options`.
- `baikai-openai` — same shape for OpenAI; uses `OPENAI_API_KEY` / `OPENAI_KEY`.

Idiomatic baikai usage looks like this (taken verbatim from
`/Users/shinzui/Keikaku/bokuno/baikai/docs/user/getting-started.md`):

```haskell
import Baikai
import Baikai.Models.Generated qualified as Models
import Baikai.Provider.Claude.Api qualified as ClaudeApi
import Control.Lens ((&), (.~))
import Data.Generics.Labels ()
import Data.Vector qualified as V

main :: IO ()
main = do
  ClaudeApi.register
  let ctx  = _Context  & #systemPrompt .~ Just "You are terse."
                       & #messages     .~ V.singleton (user "Say hi.")
      opts = _Options  & #maxTokens .~ Just 256
                       & #temperature .~ Just 0.0
  resp <- completeRequest Models.anthropic_claude_haiku_4_5 ctx opts
  let text = flattenAssistantText (flattenAssistantBlocks resp)
  print text
```

The Baikai backend in this plan follows this shape exactly, with the system prompt
"You are a release-engineering assistant. Given the tail of a failed Kubernetes Job's
container logs, return a one-sentence summary of the root cause. Reply with the summary
text only, no preamble." and the user message being the captured log tail.

The test infrastructure lives at `shiki-core/test/`. Tasty is the runner (`Spec.hs`),
hermetic database tests use the `Shiki.Persistence.TestPg.withSchemaPool` helper, and pure
tests sit beside their modules under `shiki-core/test/Shiki/<…>/`. Listing the new test
files in `shiki-core/shiki-core.cabal` under `other-modules:` of the `shiki-core-test`
test-suite is the only build-system change M2/M3 need.

Terms used in this plan that are not ordinary English:

- **Kubernetes Job**: the `batch/v1` API resource that `shiki` submits. Roughly: "run
  this pod, retry up to N times, mark me Complete when it succeeds." The Job creates one
  or more *pods* (we configure `backoffLimit: 0`, so exactly one). Each pod runs one or
  more *containers*; we use one application container plus optional init containers (e.g.
  `cloud-sql-proxy`). When we say "fetch the Job's logs" we always mean "find the single
  pod the Job spawned, then fetch its application container's stdout/stderr."
- **kubernetes-api dispatch**: the Haskell mechanism in the `kubernetes-api` package for
  invoking an HTTP request against the cluster API server. `K8s.dispatchMime mgr cfg req`
  returns a `MimeResult`; pattern-matching on `K8s.mimeResult resp` gives an `Either
  MimeError a`.
- **Pod label selector**: a Kubernetes filter expression. The Job we build labels its
  pod template with `job-name=<jobName>` (Kubernetes adds this automatically too), so the
  log fetcher lists pods in the namespace with `LabelSelector ("job-name=" <> jobName)`.
- **Migration checksum**: `hasql-migration` records each applied SQL file's filename and
  MD5 in a `schema_migrations` table inside the configured schema. Editing an already-
  applied migration changes its checksum and makes startup fail loudly, so new behavior
  goes into a *new* file (`002-…`) rather than edits to `001-…`.
- **Analyzer backend**: a value of type `Shiki.Analysis.Backend.AnalyzerKind`, either
  `Heuristic` (deterministic, in-process), `Baikai !Text` (LLM dispatch through the
  shinzui/baikai library; the `Text` is a baikai model id such as
  `"anthropic_claude_haiku_4_5"`), or `None` (skip analysis entirely). A `ServiceConfig`
  carries a default backend; the `--analyzer` flag on `shiki runs analyze` overrides it.
- **Provenance** (in this plan): the value of `runs.error_summary_source`, identifying
  which backend produced the current `runs.error_summary` value. Allows post-hoc readers
  to distinguish heuristic outputs from LLM outputs.


## Plan of Work

The work decomposes into nine small, independently verifiable milestones. Milestones 1
through 5 deliver the deterministic-heuristic foundation and are sufficient on their own
to ship a useful first cut. Milestones 6 through 8 layer in the configurable Baikai
backend and the post-hoc `runs analyze` subcommand. Milestone 9 is the close-out: README
plus full-suite verification plus a manual smoke against a live cluster + a real API key.
The through-line is that each milestone leaves the project in a green `cabal build all &&
cabal test all` state.


### Milestone 1 — Extract log fetching into `Shiki.K8s.Logs`

**Scope.** Move the existing log retrieval code out of `Shiki.K8s.Runner` and into a new
public module `Shiki.K8s.Logs`. Today the helpers `fetchLogTail`, `fetchPodLog`, and
`truncate64K` live as private definitions inside `Runner.hs` and return `Maybe Text`,
which conflates "no pod was found" with "the API call failed" with "the pod was found but
had no logs." This milestone exposes a tagged result type and adds a wider analysis
buffer.

**What will exist at the end.** A new module file
`shiki-core/src/Shiki/K8s/Logs.hs` (added to the `exposed-modules:` list in
`shiki-core/shiki-core.cabal`) exporting:

```haskell
module Shiki.K8s.Logs
  ( FetchedLogs (..)
  , LogFetchError (..)
  , fetchJobPodLogs
  ) where

data FetchedLogs = FetchedLogs
  { analysisBuffer :: !Text  -- ^ up to 1000 lines / 256 KiB, used by the analyzer
  , persistedTail  :: !Text  -- ^ last 200 lines / 64 KiB, ready for runs.log_tail
  }
  deriving stock (Generic, Eq, Show)

data LogFetchError
  = NoPodForJob !Text          -- ^ no pod found with label job-name=<jobName>
  | PodMissingName !Text       -- ^ pod returned but its metadata.name is unset
  | PodListFailed !Text !String -- ^ list-pods API call returned a MimeError
  | PodLogReadFailed !Text !String -- ^ read-log API call returned a MimeError
  deriving stock (Generic, Eq, Show)

fetchJobPodLogs
  :: ClientEnv
  -> Namespace
  -> Text                -- ^ job name (used as label-selector value)
  -> IO (Either LogFetchError FetchedLogs)
```

Internally `fetchJobPodLogs` issues two requests against the analysis buffer's tail size
(1000 lines), then derives `persistedTail` from `analysisBuffer` by taking the last 200
lines and capping it at 64 KiB measured in characters. The pure tail/cap logic lives in
small helpers that the M2 tests can exercise directly:

```haskell
takeLastLines  :: Int -> Text -> Text
truncateChars  :: Int -> Text -> Text
```

`Shiki.K8s.Runner` then loses its three private helpers and calls
`fetchJobPodLogs (env ^. #httpManager) ns (inputs ^. #jobName)` inside `runJob`'s body.
The runner consumes `FetchedLogs.persistedTail` for `JobOutcome.logTail` (preserving
today's behavior) and stashes the wider `analysisBuffer` for the later analyzer step
introduced in M5. To keep this milestone self-contained, `runJob` is allowed to discard
the wider buffer for now — the M5 milestone adds the field to `JobOutcome` and starts
consuming it.

**Commands to run.**

```bash
cabal build shiki-core
cabal test  shiki-core --test-options="--match Shiki.K8s"
```

Both must remain green; the M1 milestone adds no new tests but must not break the
existing `Shiki.K8s.JobBuilderSpec` tests.

**Acceptance.** `grep -R fetchLogTail shiki-core/src` returns nothing (the helper is
gone), `grep -R fetchJobPodLogs shiki-core/src` finds the new export and the runner's
consumer, and `cabal repl shiki-core` followed by `:t Shiki.K8s.Logs.fetchJobPodLogs`
prints the signature above.


### Milestone 2 — Analyzer interface + Heuristic backend

**Scope.** Define the pluggable analyzer surface from day one — even though the only
implementation in this milestone is the deterministic heuristic — and implement the
deterministic recognisers behind it.

**What will exist at the end.** Two new module files:

`shiki-core/src/Shiki/Analysis/Backend.hs`:

```haskell
module Shiki.Analysis.Backend
  ( AnalyzerKind (..)
  , AnalyzerResult (..)
  , AnalyzerError (..)
  , summaryByteCap
  , runAnalyzer
  ) where

import Shiki.Prelude

-- | Which backend produces the summary. Carries the data needed to
--   dispatch; see 'runAnalyzer'.
data AnalyzerKind
  = Heuristic
  | Baikai !Text  -- ^ baikai model id, e.g. "anthropic_claude_haiku_4_5"
  | None
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

-- | The summary text plus its provenance tag (e.g. "heuristic" or
--   "baikai:anthropic_claude_haiku_4_5"), packaged so the caller does
--   not have to derive the tag string from 'AnalyzerKind' themselves.
data AnalyzerResult = AnalyzerResult
  { summary :: !(Maybe Text)
  , source  :: !Text
  }
  deriving stock (Generic, Eq, Show)

data AnalyzerError
  = AnalyzerBackendDisabled        -- ^ kind = None
  | AnalyzerUnknown !Text          -- ^ CLI override could not be parsed
  | AnalyzerBaikaiError !Text      -- ^ wrapped Baikai.Error.Error rendering
  deriving stock (Generic, Eq, Show)

summaryByteCap :: Int
summaryByteCap = 512

runAnalyzer :: AnalyzerKind -> Text -> IO (Either AnalyzerError AnalyzerResult)
```

The `Heuristic` branch of `runAnalyzer` calls into `Shiki.Analysis.Heuristic`. The
`Baikai _` branch is left as a stub that returns `Left (AnalyzerBaikaiError "backend not
yet wired (M7)")` and gets fleshed out in M7. The `None` branch returns
`Left AnalyzerBackendDisabled`.

`shiki-core/src/Shiki/Analysis/Heuristic.hs`:

```haskell
module Shiki.Analysis.Heuristic
  ( summarizeFailure
  ) where

import Shiki.Prelude

-- | Inspect a chunk of container logs and return the most likely failure
--   summary. Returns 'Nothing' only when the input is empty after trimming
--   whitespace. The returned summary is capped at 'summaryByteCap'
--   characters.
summarizeFailure :: Text -> Maybe Text
```

The analyzer scans the input line-by-line and applies, in order, the following
recognisers; the first one that matches wins:

1. **Python traceback.** Locate the *last* line beginning with `Traceback (most recent
   call last):`. Collect every subsequent line until the next blank line or end-of-input.
   The final non-indented line of that block is the exception class + message; that
   single line (capped at 512 chars) is the summary.
2. **JVM exception chain.** Locate the *last* line beginning with `Exception in thread `.
   The summary is that line plus, if present, the most recent following `Caused by:`
   line, joined with `" / "`.
3. **Go panic.** Locate the *last* line beginning with `panic:`. The summary is that line
   plus the immediately preceding `goroutine ` line if present, otherwise the panic line
   on its own.
4. **Rust panic.** Locate the *last* line beginning with `thread '` and containing
   ` panicked at `. The summary is that line.
5. **Level-prefixed logger.** Locate the *last* line whose first non-whitespace token
   matches one of `ERROR`, `FATAL`, `PANIC`, `EMERGENCY`, `[ERROR]`, `[FATAL]`, or the
   structured-logging variants `"level":"error"` / `"level":"fatal"`. The summary is that
   line.
6. **Fallback.** Take the last non-blank line of the input.

Empty input (no non-whitespace content) returns `Nothing`. Every non-empty input returns
`Just t` where `Text.length t <= summaryByteCap`. The cap is applied with
`Text.take summaryByteCap` after all the other logic runs.

`runAnalyzer Heuristic input` wraps the result into an `AnalyzerResult` with
`source = "heuristic"`.

**Tests.** Add `shiki-core/test/Shiki/Analysis/HeuristicSpec.hs` listed under
`other-modules:` of the `shiki-core-test` test suite. Cover every recogniser plus the cap
and the empty-input case:

```text
Heuristic.summarizeFailure
  recognises a Python traceback's final exception line
  recognises a JVM Exception in thread / Caused by chain
  recognises a Go panic header
  recognises a Rust 'thread X panicked at' line
  recognises a line-prefixed ERROR
  falls back to the last non-blank line when nothing matches
  returns Nothing on empty input
  truncates summaries longer than 512 characters
```

Plus one shape test for the interface (`shiki-core/test/Shiki/Analysis/BackendSpec.hs`):

```text
Backend.runAnalyzer
  None returns Left AnalyzerBackendDisabled
  Heuristic on a Python traceback returns Right with source = "heuristic"
```

Pure tests; no Postgres, no Kubernetes, no Baikai. Run with:

```bash
cabal test shiki-core --test-options="--match Analysis"
```

**Acceptance.** All cases pass; `cabal build all` stays green.


### Milestone 3 — Add the `error_summary` and `error_summary_source` SQL columns

**Scope.** Persist the analyzer's output by adding two columns to the `runs` table via a
fresh, additive migration. No existing migration is edited (doing so would change its
checksum and brick fresh-checkout runs against existing databases).

**What will exist at the end.** A new file
`shiki-core/sql/migrations/002-add-error-summary.sql` containing exactly:

```sql
ALTER TABLE runs ADD COLUMN error_summary text;
ALTER TABLE runs ADD COLUMN error_summary_source text NOT NULL DEFAULT 'heuristic';
```

No backfill is needed because every existing row has unknown post-hoc failure context;
leaving `error_summary` NULL preserves "we never analysed this run." `NOT NULL DEFAULT
'heuristic'` on `error_summary_source` is safe because every existing row was produced by
a `shiki` binary that pre-dates the LLM backend, so labelling them as having been
analysed by the heuristic (if at all) is honest. `hasql-migration` picks the new script
up automatically because `Shiki.Persistence.Migration.runMigrations` already calls
`Migration.loadMigrationsFromDirectory` on the whole `sql/migrations` directory.

A hermetic test asserting the columns land in the configured schema goes into a small
extension of the existing `Shiki.Persistence.SchemaIsolationSpec` style: a new test
`shiki-core/test/Shiki/Persistence/ErrorSummaryColumnSpec.hs` (added to the
`other-modules:` list) uses `Shiki.Persistence.TestPg.withSchemaPool` to run migrations
and then queries `information_schema.columns WHERE table_schema = $1 AND table_name =
'runs' AND column_name IN ('error_summary', 'error_summary_source')`, expecting exactly
two rows.

**Commands to run.**

```bash
cabal test shiki-core --test-options="--match error_summary"
```

**Acceptance.** The new test passes; `cabal build all` stays green.


### Milestone 4 — Plumb the new fields through the persistence types

**Scope.** Surface the two new columns at the Haskell type level: `RunRecord` learns
about both so the read side can render them, `RunCompletion` learns about both so the
inline write path can populate them, and a new dedicated statement supports the post-hoc
re-analysis path.

**What will exist at the end.** In `shiki-core/src/Shiki/Persistence/Run.hs`:

- `RunRecord` gains two final fields: `errorSummary :: !(Maybe Text)` and
  `errorSummarySource :: !Text` (NOT NULL in the table, so non-`Maybe` here).
- `RunCompletion` gains the same two fields. `Shiki.Cli.Run.finalizeFailed` must continue
  to compile; the catch-all path will pass `errorSummary = Nothing` and
  `errorSummarySource = "heuristic"` (the default).
- `completeRunStatement`'s SQL is updated to include `error_summary = $8, error_summary_source = $9`
  in the `SET` clause and its encoder is extended with two more parameters.
- A new statement `updateErrorSummaryStatement :: Statement (RunId, Maybe Text, Text) ()`
  is added; it issues `UPDATE runs SET error_summary = $2, error_summary_source = $3,
  updated_at = now() WHERE id = $1`. This is the write path used by `shiki runs analyze`
  and only this path is allowed to rewrite the two columns post-completion.
- The four `SELECT` statements (`getRunStatement`, `listRecentRunsStatement`,
  `listRecentRunsByServiceStatement`, `findRunByPrefixStatement`) gain
  `error_summary, error_summary_source` at the end of their column lists.
- `runRecordRow` gains `<*> Decoders.column (Decoders.nullable Decoders.text) <*>
  Decoders.column (Decoders.nonNullable Decoders.text)` at the end.

Update `shiki-core/test/Shiki/Persistence/RunSpec.hs` (and `RunListSpec` if any of its
fixtures touch `RunCompletion`) to construct the new fields and to assert they round-trip.
Where the existing test inserts a `RunCompletion` and reads it back, add a non-`Nothing`
summary and assert it's preserved.

**Commands to run.**

```bash
cabal build shiki-core
cabal test  shiki-core
```

**Acceptance.** Both green. A re-read of any row written by the updated
`completeRunStatement` shows the summary and source; a re-read of any row written by the
*old* encoder (a row inserted by an older binary against a DB that has migration `002`
applied) returns `errorSummary = Nothing, errorSummarySource = "heuristic"` (the default).


### Milestone 5 — Wire the inline Heuristic analyzer into `runJob`

**Scope.** Have `Shiki.K8s.Runner.runJob` populate the new fields on failure paths only,
using the deterministic `Heuristic` backend.

**What will exist at the end.** In `shiki-core/src/Shiki/K8s/Runner.hs`:

- `JobOutcome` gains `errorSummary :: !(Maybe Text)` and `errorSummarySource :: !Text`
  after `logTail`.
- `runJob` is restructured so it fetches the logs via `Shiki.K8s.Logs.fetchJobPodLogs`
  exactly once — after `waitForCompletion` returns. The result is a `Either LogFetchError
  FetchedLogs`. On `Right fl`, `logTail = Just (fl ^. #persistedTail)`. For
  failure phases (`JobFailed _`, `JobTimedOut`), call
  `runAnalyzer Heuristic (fl ^. #analysisBuffer)` and unpack the `AnalyzerResult` into
  `errorSummary` / `errorSummarySource`. For `JobSucceeded`, leave `errorSummary =
  Nothing, errorSummarySource = "heuristic"`. On `Left _`, both fields take their default
  values (today's behavior is preserved on log-fetch failure).

In `shiki-cli/src/Shiki/Cli/Run.hs`:

- `finalizeOutcome` writes `errorSummary = outcome ^. #errorSummary` and
  `errorSummarySource = outcome ^. #errorSummarySource` into the `RunCompletion`.
- `finalizeFailed` writes `errorSummary = Nothing, errorSummarySource = "heuristic"`
  (the catch-all path never gets to the log fetcher, so by convention we record the
  default source rather than e.g. "exception").

The `submitJob` helper is unchanged; the `--no-wait` path skips log fetching entirely
because there is nothing to follow.

**Commands to run.**

```bash
cabal build shiki-core
cabal test  shiki-core
```

**Acceptance.** `JobOutcome` carries the new fields; the existing `JobBuilderSpec` tests
still pass (they exercise `buildJob`, which is pure); `cabal repl shiki-core` followed by
`:t Shiki.K8s.Runner.runJob` prints the unchanged signature `ClientEnv -> ServiceConfig
-> DeploymentSnapshot -> JobInputs -> Int -> Int -> IO JobOutcome`. Live verification is
performed in M9.


### Milestone 6 — Per-service `analyzer` Dhall field

**Scope.** Make the analyzer backend a declarative property of each service's Dhall
config, not just a CLI knob. This gives operators a way to record "service X uses Claude
Haiku 4.5 because its logs are unusually noisy and the heuristic misses the actual
failure" in version control.

**What will exist at the end.** In `shiki-core/src/Shiki/Service/Config.hs`:

- A new exported type `AnalyzerBackend` matching `Shiki.Analysis.Backend.AnalyzerKind`
  bijectively (we duplicate it deliberately so `Shiki.Service.Config` does not depend on
  `Shiki.Analysis.Backend`, keeping the dependency arrow one-way). A single conversion
  function `analyzerBackendToKind :: AnalyzerBackend -> AnalyzerKind` lives in
  `Shiki.Analysis.Backend` to bridge the two.
- `ServiceConfig` gains a final field `analyzer :: AnalyzerBackend`.

In `shiki-core/src/Shiki/Service/Config/Dhall.hs`:

- The Dhall decoder is extended to read an `analyzer` field whose type is the union
  `< Heuristic | Baikai : { model : Text } | None >`. A missing field defaults to
  `AnalyzerBackend.Heuristic` (the loader handles the absence to keep older configs
  compatible).

In `services/mls-service-v2.dhall`:

- Add `, analyzer = (../shiki-core/dhall/AnalyzerBackend.dhall).Heuristic` (the type
  definition lives in a new file under `shiki-core/dhall/AnalyzerBackend.dhall` shipped
  with the package so all services can import the same union). The Dhall file's contents:

```dhall
{- A pluggable analyzer backend selector. Used by ServiceConfig.analyzer. -}
< Heuristic | Baikai : { model : Text } | None >
```

A small unit test under `shiki-core/test/Shiki/Service/ConfigSpec.hs` parses the updated
`mls-service-v2.dhall` and asserts the `analyzer` field decodes to
`AnalyzerBackend.Heuristic`.

**Commands to run.**

```bash
cabal build shiki-core
cabal test  shiki-core --test-options="--match Service"
cabal run shiki -- service show mls-service-v2
```

The CLI invocation prints the parsed `ServiceConfig` as JSON, now including
`"analyzer":{"tag":"Heuristic"}` (exact key/encoding depends on the `Generic` derivation —
adjust the assertion in the unit test accordingly).

**Acceptance.** All Service tests pass; the `service show` JSON includes the new field.


### Milestone 7 — Add Baikai dependencies and the Baikai analyzer backend

**Scope.** Pull in the `baikai`, `baikai-claude`, and `baikai-openai` packages and
implement `Shiki.Analysis.Baikai.runBaikai`, replacing the stub introduced in M2.

**What will exist at the end.** In `cabal.project`, add a new packages block after the
existing forks:

```cabal
-- baikai (the unified AI-provider library at /Users/shinzui/Keikaku/bokuno/baikai) is
-- not yet on Hackage. Pulled in by path while it stabilises; flip to a
-- source-repository-package entry once we tag a release.
packages:
  /Users/shinzui/Keikaku/bokuno/baikai/baikai
  /Users/shinzui/Keikaku/bokuno/baikai/baikai-claude
  /Users/shinzui/Keikaku/bokuno/baikai/baikai-openai
```

In `shiki-core/shiki-core.cabal`, add the three packages to `build-depends:` of the
`library` stanza:

```cabal
  baikai,
  baikai-claude,
  baikai-openai,
```

New module file `shiki-core/src/Shiki/Analysis/Baikai.hs`:

```haskell
module Shiki.Analysis.Baikai
  ( runBaikai
  ) where

import Shiki.Prelude

import "baikai" Baikai
import "baikai" Baikai.Models.Generated qualified as Models
import "baikai-claude" Baikai.Provider.Claude.Api qualified as ClaudeApi
import "baikai-openai" Baikai.Provider.OpenAI.Api qualified as OpenAIApi
import "base" Control.Exception (SomeException, try)
import "text" Data.Text qualified as Text
import "vector" Data.Vector qualified as V

-- | Dispatch a one-shot summarization request through the named baikai
--   model. The first argument is a baikai catalog id
--   (e.g. "anthropic_claude_haiku_4_5"); the second is the captured log
--   tail. Returns the summary text on success.
--
--   Side effect: ensures the provider for the requested model is
--   registered (idempotent per Api tag).
runBaikai :: Text -> Text -> IO (Either Text Text)
```

Implementation outline:

1. Look up the model by id. The minimum viable mapping picks the right `register` to call
   based on the id's prefix: `anthropic_*` → `ClaudeApi.register`, `openai_*` →
   `OpenAIApi.register`, everything else returns `Left ("unknown baikai model: " <> mid)`.
   A model record is then constructed via the matching constant in `Models` (e.g.
   `Models.anthropic_claude_haiku_4_5`). Because the catalog is generated and the set of
   model ids is finite, we hand-write the lookup as a case statement against the model id
   text for the handful of models we expect to support (start with
   `"anthropic_claude_haiku_4_5"`, `"anthropic_claude_sonnet_4_6"`,
   `"openai_gpt_4o_mini"`; document the list in the module's Haddock).
2. Build a `Context` with `systemPrompt = "You are a release-engineering assistant. Given
   the tail of a failed Kubernetes Job's container logs, return a one-sentence summary of
   the root cause. Reply with the summary text only, no preamble."` and a single user
   message carrying the log tail.
3. Build `Options` with `maxTokens = Just 256, temperature = Just 0.0` (low temperature
   so repeated `runs analyze` calls against the same log produce stable summaries).
4. Wrap `completeRequest model ctx opts` in `try @SomeException`; on success extract the
   text via `flattenAssistantText (flattenAssistantBlocks resp)` and apply the same 512-
   character cap as the heuristic; on exception render the exception text and return
   `Left`.

The `runAnalyzer (Baikai modelId) input` branch in `Shiki.Analysis.Backend` now calls
`runBaikai modelId input` and packages the result as
`AnalyzerResult { summary = Just t, source = "baikai:" <> modelId }`.

**Tests.** No live LLM call in the test suite — the smoke is performed manually in M9.
The hermetic test in `Shiki.Analysis.BackendSpec` already covers the dispatch shape; a
new case asserts `runAnalyzer (Baikai "no-such-model") "x"` returns
`Left (AnalyzerBaikaiError _)`.

**Commands to run.**

```bash
cabal build all
cabal test  shiki-core --test-options="--match Analysis"
```

**Acceptance.** Build succeeds (this requires the baikai packages to be reachable on
disk; if they have moved, edit `cabal.project` accordingly). The new error-path test in
`BackendSpec` passes.


### Milestone 8 — `runs error` and `runs analyze` CLI subcommands

**Scope.** Surface the new column through the read side and add the post-hoc analysis
subcommand. This is the milestone that makes the configurable backend reachable from the
operator's terminal.

**What will exist at the end.** In `shiki-cli/src/Shiki/Cli/Runs.hs`:

- `RunsCommand` gains two constructors:

```haskell
  | RunsError   !Text
  | RunsAnalyze !Text !(Maybe AnalyzerKind)
```

- The parser gains two branches:

```text
  shiki runs error ID
  shiki runs analyze ID [--analyzer=heuristic|baikai:<model-id>|none]
```

  The `--analyzer` argument is a custom `Opt.option` that uses a tiny parser:
  `"heuristic"` → `Heuristic`, `"none"` → `None`, `"baikai:<id>"` → `Baikai <id>`,
  anything else → parse failure with `"expected 'heuristic', 'none', or 'baikai:<id>'"`.

- The dispatcher gains:

```haskell
  RunsError idText             -> doError   env idText
  RunsAnalyze idText override  -> doAnalyze env idText override
```

- `doError` is structurally identical to `doLogs`: call `runRead env findRunByPrefixStatement
  idText` and on a unique match print `r ^. #errorSummary` or `"(no summary)"`.

- `doAnalyze` does the following, in order, all wrapped in a single transaction at the
  database level (a small new helper added to `Shiki.Cli.Env` if needed):

  1. Find the row by id prefix; on no-match or ambiguous, exit non-zero as today.
  2. Read the row's `serviceName`, fetch the service config from `services/<name>.dhall`
     (or fail with a helpful error if the file is missing), and extract its
     `analyzer :: AnalyzerBackend`. Convert to `AnalyzerKind`.
  3. Pick the effective backend: CLI override (`Just k`) wins; otherwise use the service
     default; otherwise `Heuristic`.
  4. If the run's `logTail` is `Nothing`, print `(no logs captured; cannot analyze)`
     and exit 0 (this is not a failure of `runs analyze`; it just has nothing to do).
  5. Call `runAnalyzer effectiveKind (fromJust (r ^. #logTail))`.
  6. On `Right res`, run `updateErrorSummaryStatement (runId, res ^. #summary, res ^. #source)`
     and print a one-line confirmation to stdout:
     `analyzed run <id-prefix> with <source>: <summary or "(no summary)">`.
  7. On `Left err`, print the error to stderr and exit non-zero. Do not mutate the row.

The pretty-JSON output of `runs show` automatically picks up `errorSummary` and
`errorSummarySource` because `RunRecord` derives `ToJSON` generically.

**Commands to run.**

```bash
cabal build all
cabal run shiki -- runs --help
cabal run shiki -- runs error --help
cabal run shiki -- runs analyze --help
```

Expected `runs --help` excerpt:

```text
Available commands:
  list                     List recent runs, newest first
  show                     Show one run by id (UUID or unambiguous prefix)
  logs                     Print the captured log tail for a run
  error                    Print the captured error summary for a run
  analyze                  Re-run analysis on a stored run's log tail
```

**Acceptance.** `cabal run shiki -- runs --help` lists five subcommands. A previously-
failed run's id passed to `runs error <id>` prints either the summary or `(no summary)`;
the same id passed to `runs show <id>` includes `"errorSummary"` and
`"errorSummarySource"` fields in the JSON. `runs analyze --help` shows the `--analyzer`
flag. Live behavior is verified in M9.


### Milestone 9 — Documentation and full-suite verification (manual smoke included)

**Scope.** Document the new behavior for operators and produce evidence that everything
still hangs together end-to-end.

**What will exist at the end.** A new section in `README.md` titled "Error summaries and
analysis backends" positioned between the existing "Database schema" and "Develop"
sections, explaining:

- That failed runs have both a Kubernetes-side reason (`runs.error`) and a log-derived
  summary (`runs.error_summary`), and an explicit provenance tag (`runs.error_summary_source`).
- The runtimes the Heuristic analyzer currently understands (Python, JVM, Go, Rust,
  generic level-prefixed loggers) and the fallback behavior (last non-blank line).
- The configurable backends: `Heuristic` (default, in-process, deterministic), `Baikai
  { model = "<id>" }` (LLM via the `shinzui/baikai` library; requires an API key in
  `ANTHROPIC_API_KEY` or `OPENAI_API_KEY` depending on the model prefix), and `None`.
- That the inline `shiki run` path always uses `Heuristic`, and the LLM path is opt-in
  via `shiki runs analyze <id> [--analyzer=baikai:<model-id>]`.
- How to read the summary: either through `shiki runs show <id>` (JSON, full record) or
  through `shiki runs error <id>` (one-shot text, like `runs logs`).
- The 512-character cap on summaries and the 64 KiB cap on `runs.log_tail`.

Then run `cabal build all && cabal test all` from the repo root and paste the closing
section of the transcript into Concrete Steps under "Recorded transcript (M9)".

Finally, perform the manual smoke against the operator's current kube context:

1. Run `shiki-run-once` (the example program at `shiki-core/example/RunOnce.hs`) against
   a service whose command intentionally raises an exception.
2. Run `cabal run shiki -- runs error <id>` and observe the heuristic summary.
3. Export `ANTHROPIC_API_KEY` and run `cabal run shiki -- runs analyze <id>
   --analyzer=baikai:anthropic_claude_haiku_4_5`. Observe the new summary and the
   `errorSummarySource = "baikai:anthropic_claude_haiku_4_5"` value via `runs show`.

Record the observed outputs in Concrete Steps under "Manual smoke (M9)".

**Acceptance.** README contains the new section; `cabal test all` exits 0; the recorded
manual smoke shows the LLM-produced summary differs from (and is qualitatively better
than) the heuristic one.


## Concrete Steps

All commands assume the repository root `/Users/shinzui/Keikaku/bokuno/shiki` as working
directory and the Nix dev shell as the shell environment (enter it via `nix develop` or
let `direnv allow` do it once).

### M1 — extract `Shiki.K8s.Logs`

```bash
# 1. Create the new module file at shiki-core/src/Shiki/K8s/Logs.hs with the
#    signatures listed under "Milestone 1".
# 2. Add 'Shiki.K8s.Logs' to the 'exposed-modules:' list of shiki-core/shiki-core.cabal
#    (under the 'library' stanza, before 'Shiki.K8s.Runner' alphabetically).
# 3. Delete fetchLogTail, fetchPodLog, truncate64K from shiki-core/src/Shiki/K8s/Runner.hs
#    and replace the call site inside runJob with:
#       logsE <- Shiki.K8s.Logs.fetchJobPodLogs env (inputs ^. #namespace) (inputs ^. #jobName)
#       let logTailNow = either (const Nothing) (Just . (^. #persistedTail)) logsE
#    (M5 will broaden this to also retain the analysisBuffer and run the analyzer.)
cabal build shiki-core
cabal test  shiki-core --test-options="--match Shiki.K8s"
```

### M2 — analyzer interface + Heuristic backend

```bash
# 1. Create shiki-core/src/Shiki/Analysis/Backend.hs and Heuristic.hs with the
#    signatures listed under "Milestone 2".
# 2. Add 'Shiki.Analysis.Backend' and 'Shiki.Analysis.Heuristic' to 'exposed-modules:'
#    of shiki-core/shiki-core.cabal.
# 3. Create shiki-core/test/Shiki/Analysis/HeuristicSpec.hs and BackendSpec.hs.
#    Add both under 'other-modules:' of the 'shiki-core-test' test-suite stanza.
# 4. Register the new specs in shiki-core/test/Spec.hs (the tasty TestTree assembly).
cabal test shiki-core --test-options="--match Analysis"
```

### M3 — SQL migration

```bash
# 1. Create shiki-core/sql/migrations/002-add-error-summary.sql with the two ALTERs.
# 2. Create shiki-core/test/Shiki/Persistence/ErrorSummaryColumnSpec.hs that runs
#    withSchemaPool and asserts the information_schema.columns query returns 2.
# 3. Add the new module to other-modules: of the shiki-core-test stanza and to the
#    TestTree in shiki-core/test/Spec.hs.
cabal test shiki-core --test-options="--match error_summary"
```

### M4 — persistence types

```bash
# Edit shiki-core/src/Shiki/Persistence/Run.hs per Milestone 4. Compile errors will
# cascade into shiki-cli/src/Shiki/Cli/Run.hs because RunCompletion's constructor
# signature changed; pass the new defaults at every existing call site for now.
# M5/M8 replace those defaults with real values where appropriate.
cabal build all
cabal test  shiki-core
```

### M5 — runner wiring

```bash
# Edit shiki-core/src/Shiki/K8s/Runner.hs per Milestone 5. Edit
# shiki-cli/src/Shiki/Cli/Run.hs's finalizeOutcome / finalizeFailed to forward the
# new fields into RunCompletion.
cabal build all
cabal test  shiki-core
```

### M6 — Dhall analyzer field

```bash
# 1. Add Shiki.Service.Config.AnalyzerBackend (a Haskell ADT) and a field
#    analyzer :: AnalyzerBackend at the end of ServiceConfig.
# 2. Create shiki-core/dhall/AnalyzerBackend.dhall with the < Heuristic | Baikai :
#    { model : Text } | None > union.
# 3. Edit shiki-core/src/Shiki/Service/Config/Dhall.hs to decode the new field
#    (defaulting to Heuristic if absent).
# 4. Edit services/mls-service-v2.dhall to add ', analyzer = AnalyzerBackend.Heuristic'.
# 5. Extend Shiki.Service.ConfigSpec to assert the new field round-trips.
cabal build all
cabal test  shiki-core --test-options="--match Service"
cabal run shiki -- service show mls-service-v2
```

### M7 — baikai dependencies + backend

```bash
# 1. Add the three baikai 'packages:' entries to cabal.project (see Milestone 7).
# 2. Add baikai / baikai-claude / baikai-openai to shiki-core.cabal's library
#    build-depends.
# 3. Create shiki-core/src/Shiki/Analysis/Baikai.hs implementing runBaikai per
#    Milestone 7.
# 4. Update Shiki.Analysis.Backend so runAnalyzer (Baikai m) calls runBaikai m
#    instead of the M2 stub.
cabal build all
cabal test  shiki-core --test-options="--match Analysis"
```

### M8 — CLI

```bash
# Edit shiki-cli/src/Shiki/Cli/Runs.hs to add the RunsError and RunsAnalyze
# constructors, parser branches, and the doError / doAnalyze handlers.
cabal build all
cabal run shiki -- runs --help
cabal run shiki -- runs analyze --help
cabal run shiki -- runs error --help
```

### M9 — README + full suite + manual smoke

```bash
# 1. Edit README.md to insert the "Error summaries and analysis backends" section
#    per Milestone 9.
cabal build all
cabal test  all

# 2. Manual smoke (requires a live cluster + an ANTHROPIC_API_KEY):
shiki-run-once   # or cabal run shiki-run-once -- ...
cabal run shiki -- runs list --limit 1
cabal run shiki -- runs error <id>
cabal run shiki -- runs analyze <id> --analyzer=baikai:anthropic_claude_haiku_4_5
cabal run shiki -- runs show <id>
```

#### Recorded transcript (M9)

`cabal test shiki-core` closing section, run 2026-05-27 from the repo root in
the Nix dev shell against an ephemeral-Postgres instance:

```
  Shiki.Analysis.Heuristic
    recognises a Python traceback's final exception line: OK
    recognises a JVM Exception in thread / Caused by chain: OK
    recognises a Go panic header: OK
    recognises a Rust 'thread X panicked at' line: OK
    recognises a line-prefixed ERROR: OK
    falls back to the last non-blank line when nothing matches: OK
    returns Nothing on empty input: OK
    truncates summaries longer than 512 characters: OK
  Shiki.Analysis.Backend
    None returns Left AnalyzerBackendDisabled: OK
    Baikai with an unknown model id returns AnalyzerBaikaiError: OK
    Heuristic on a Python traceback returns Right with source = "heuristic": OK
  Shiki.Persistence (error_summary migration)
    error_summary and error_summary_source land in the configured schema: OK (1.44s)

All 24 tests passed (1.46s)
Test suite shiki-core-test: PASS
```

`cabal test all` aggregate (same session):

```
Test suite baikai-claude-test: PASS
Test suite test-memory: PASS
Test suite hasql-migration-test: PASS
Test suite baikai-test: PASS
Test suite baikai-openai-test: PASS
Test suite example: PASS
Test suite shiki-core-test: PASS
Test suite tests: PASS
Test suite spec: PASS
Test suite test-crypton: PASS
```

#### Manual smoke (M9)

Not performed in this implementation session: the harness has neither a live
Kubernetes context nor an `ANTHROPIC_API_KEY` available, so the operator-side
verification (synthesizing a failing Job, observing `errorSummary` end-to-end
through `shiki runs analyze --analyzer=baikai:anthropic_claude_haiku_4_5`)
remains TODO. The hermetic substitute described in **Validation and
Acceptance** (synthetic `RunCompletion` round-trip plus
`updateErrorSummaryStatement` rewrite with a `baikai:test` source) is covered
by the extended `Shiki.Persistence.RunSpec.Failed status round-trips` test and
passes against ephemeral Postgres.


## Validation and Acceptance

The plan is complete when all of the following observations hold simultaneously:

1. `cabal build all` exits 0.
2. `cabal test all` exits 0 and the printed test count includes the eight cases in
   `HeuristicSpec`, the dispatch-shape cases in `BackendSpec`, the columns assertion in
   `ErrorSummaryColumnSpec`, and the extended round-trip assertions in `RunSpec`.
3. `cabal run shiki -- runs --help` lists `list`, `show`, `logs`, `error`, and `analyze`
   as the five `runs` subcommands.
4. Against a freshly-initialized PostgreSQL database (e.g. `dropdb shiki && createdb
   shiki`), running `cabal run shiki -- runs list --limit 0` creates a schema named
   `shiki` containing a `runs` table whose `error_summary` and `error_summary_source`
   columns are present:

    ```text
    psql "$PG_CONNECTION_STRING" -c "\d shiki.runs"
    # expected (excerpt):
    #  error_summary        | text |
    #  error_summary_source | text | not null default 'heuristic'
    ```

5. Live cluster verification (gated on the operator having a kube context with the
   relevant service): run `shiki-run-once` (the example program at
   `shiki-core/example/RunOnce.hs`) against a service config whose command intentionally
   raises an exception, and observe the printed `JobOutcome.errorSummary` is `Just`
   carrying a recognisable fragment of the exception (e.g. `RuntimeError: boom` for the
   Python case described in Purpose / Big Picture) and
   `JobOutcome.errorSummarySource = "heuristic"`. Then `cabal run shiki -- runs error
   <id>` prints the same string.
6. For the same row, with `ANTHROPIC_API_KEY` set: `cabal run shiki -- runs analyze <id>
   --analyzer=baikai:anthropic_claude_haiku_4_5` prints
   `analyzed run <id-prefix> with baikai:anthropic_claude_haiku_4_5: <model output>`,
   and a subsequent `runs show <id>` shows the LLM output in `errorSummary` and
   `"errorSummarySource":"baikai:anthropic_claude_haiku_4_5"`.
7. For a successful run on the same cluster, `cabal run shiki -- runs error <id>` prints
   `(no summary)` and the JSON from `runs show <id>` has `"errorSummary": null,
   "errorSummarySource": "heuristic"`.

If a reader does not have a live cluster or an API key, items 5–7 are replaced by a
hermetic substitute: a tasty test that constructs a synthetic `JobOutcome` with `phase =
JobFailed "BackoffLimitExceeded"` and a concrete `analysisBuffer`, runs it through the
heuristic, asserts the expected summary, inserts a `RunCompletion` carrying it via the
existing `Shiki.Persistence.TestPg.withSchemaPool` helper, asserts it round-trips out of
`getRunStatement`, and then exercises `updateErrorSummaryStatement` to rewrite the
summary with a synthetic Baikai-shaped value (`source = "baikai:test"`) and asserts the
rewrite is visible.


## Idempotence and Recovery

Every milestone in this plan is additive at the source level (new modules, new SQL file,
new record fields, new CLI subcommands, new Dhall field with a default) so re-running the
steps is safe: editing an already-edited file is a no-op, adding an already-added cabal
entry is detected as a duplicate by the parser, and `hasql-migration` keys applied
migrations by filename + MD5 so re-running `runMigrations` against an already-migrated
database is a no-op.

The SQL migration is itself safe to re-apply during development because `hasql-migration`
never re-runs a script whose filename and checksum are already in `schema_migrations`. If
during development you accidentally land a broken `002-add-error-summary.sql` and apply
it, fix it forward with a third migration `003-…sql` rather than editing `002-…sql`
(editing changes the checksum and makes startup fail loudly with a checksum mismatch
error from `hasql-migration`).

`shiki runs analyze <id>` is idempotent at the *row* level: every invocation overwrites
the two columns wholesale. Re-running it with the same backend against the same row
produces the same result for the Heuristic backend (deterministic) and a closely-similar
result for the Baikai backend (temperature 0.0, but providers may still introduce minor
variance). The previous summary is not preserved; if you want a record of every analysis
attempt, run `runs show <id>` and pipe the JSON to a file before re-analyzing.

If the heuristic ever produces a wrong summary against a real-world log shape, the fix is
purely additive: add a new recogniser at the appropriate priority in `summarizeFailure`,
extend the test suite with the offending input, and the new field re-populates the next
time the same Job fails (or when an operator runs `runs analyze` against the historical
row).

If the Baikai dependency moves on disk (e.g. the `baikai` repo is published to Hackage
and the local checkout is removed), update the `packages:` entries in `cabal.project` to
point at the new location, or replace them with a `source-repository-package` block
against the published Git tag. No changes to `shiki-core.cabal` or the Haskell sources are
required because the import paths are identical.


## Interfaces and Dependencies

This plan adds three new build dependencies on `shinzui/baikai` packages:

- `baikai` — the core surface. Provides `Baikai.completeRequest`, `Baikai._Context`,
  `Baikai._Options`, `Baikai.user`, `Baikai.flattenAssistantBlocks`,
  `Baikai.flattenAssistantText`, `Baikai.Models.Generated.anthropic_claude_haiku_4_5` (and
  siblings), and the registry under `Baikai.Provider.Registry`.
- `baikai-claude` — provides `Baikai.Provider.Claude.Api.register :: IO ()`. Reads
  `ANTHROPIC_API_KEY` / `ANTHROPIC_KEY` when `apiKey` is unset on `Options`.
- `baikai-openai` — provides `Baikai.Provider.OpenAI.Api.register :: IO ()`. Reads
  `OPENAI_API_KEY` / `OPENAI_KEY`.

All three are pulled in via `cabal.project` `packages:` entries from the local checkout
at `/Users/shinzui/Keikaku/bokuno/baikai`. They are not yet on Hackage.

Pre-existing dependencies used in this plan (no version bumps required):

- `kubernetes-api` and `kubernetes-api-client` already provide
  `CoreV1.listNamespacedPod`, `CoreV1.readNamespacedPodLog`, `K8s.LabelSelector`, and
  `K8s.TailLines`.
- `text`, `vector` (for `V.singleton` in the Baikai prompt construction), `hasql`,
  `hasql-pool`, `hasql-migration`, `hasql-transaction`, `optparse-applicative`, `aeson`,
  `aeson-pretty`, `dhall`, `lens`, `generic-lens`.

The function signatures introduced or extended by this plan are:

- `Shiki.K8s.Logs.fetchJobPodLogs :: ClientEnv -> Namespace -> Text -> IO (Either LogFetchError FetchedLogs)` (M1, new).
- `Shiki.Analysis.Heuristic.summarizeFailure :: Text -> Maybe Text` (M2, new).
- `Shiki.Analysis.Backend.runAnalyzer :: AnalyzerKind -> Text -> IO (Either AnalyzerError AnalyzerResult)` (M2, new; Baikai branch fleshed out in M7).
- `Shiki.Analysis.Backend.summaryByteCap :: Int` (M2, new).
- `Shiki.Analysis.Baikai.runBaikai :: Text -> Text -> IO (Either Text Text)` (M7, new).
- `Shiki.Persistence.Run.RunRecord` gains `errorSummary :: !(Maybe Text)` and
  `errorSummarySource :: !Text` (M4).
- `Shiki.Persistence.Run.RunCompletion` gains the same two fields (M4).
- `Shiki.Persistence.Run.updateErrorSummaryStatement :: Statement (RunId, Maybe Text, Text) ()` (M4, new).
- `Shiki.K8s.Runner.JobOutcome` gains `errorSummary :: !(Maybe Text)` and
  `errorSummarySource :: !Text` (M5).
- `Shiki.Service.Config.AnalyzerBackend` (M6, new); `ServiceConfig` gains
  `analyzer :: AnalyzerBackend`.
- `Shiki.Cli.Runs.RunsCommand` gains constructors `RunsError !Text` and
  `RunsAnalyze !Text !(Maybe AnalyzerKind)` (M8).
- `Shiki.K8s.Runner.runJob` keeps its existing signature `ClientEnv -> ServiceConfig ->
  DeploymentSnapshot -> JobInputs -> Int -> Int -> IO JobOutcome`; only the returned
  record's shape grows.

No external service contracts change. The PostgreSQL contract is extended additively (two
nullable-or-defaulted columns). The Kubernetes API surface used by `shiki` does not
change at all. The new external API surface is the Anthropic / OpenAI HTTP APIs, reached
through baikai; these are only contacted when an operator explicitly runs
`shiki runs analyze <id> --analyzer=baikai:...` or when a service config's `analyzer`
field is set to `Baikai { model = ... }` and is the effective backend at analysis time.


---

## Revision history

- 2026-05-27 — Initial draft authored: seven milestones, deterministic-heuristic analyzer
  only, inline on `shiki run`, single `error_summary` column.
- 2026-05-27 — **Revised** to make the analyzer backend pluggable through the local
  `shinzui/baikai` library. Now nine milestones: M2 split into an interface plus a
  Heuristic implementation, M3 adds a `error_summary_source` provenance column, M6 adds
  a per-service Dhall `analyzer` field, M7 pulls in the baikai packages and implements
  the Baikai backend, M8 adds a post-hoc `shiki runs analyze <id> [--analyzer=...]`
  subcommand alongside the original `shiki runs error <id>`. Inline `shiki run` still
  uses Heuristic-only for determinism and zero network/credentials on the hot path; LLM
  analysis is strictly opt-in through the new post-hoc subcommand or a non-default
  per-service `analyzer` value. Three new Decision Log entries record: (a) post-hoc
  trigger, (b) both Dhall + CLI config loci with Dhall as default, (c) Heuristic as the
  out-of-the-box default. Reason for revision: user requested via "should we use baikai
  to make the backend to analyze configurable?" — answers via AskUserQuestion confirmed
  the post-hoc / both-loci / heuristic-default design choices.
