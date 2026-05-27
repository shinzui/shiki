---
id: 8
slug: agent-assist-subcommand-backed-by-baikai
title: "Agent assist subcommand backed by baikai"
kind: exec-plan
created_at: 2026-05-27T22:50:13Z
intention: "intention_01ksnstztdesmr29f1awmtyx0e"
master_plan: "docs/masterplans/1-microservice-job-runner-with-postgres-backed-run-history.md"
---

# Agent assist subcommand backed by baikai

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Today an operator who wants help "running and monitoring a one-off Kubernetes Job, then
explaining what happened in its logs" must stitch together half a dozen `shiki` invocations
by hand: `shiki service show <name>` to confirm the config, `shiki run <name> -- <args>` to
submit, `shiki runs list` to watch the row land, `shiki runs show <id>` for the JSON dump,
`shiki runs logs <id>` for the persisted tail, `shiki runs error <id>` for the heuristic
summary, and finally `shiki runs analyze <id> --analyzer=baikai:<model>` for an LLM-derived
root cause. The CLI exposes every primitive needed but does not yet let the operator hand
the whole loop to an AI assistant that already knows the shape of shiki's commands, the
operator's services, and the recent run history.

After this plan, running

```bash
shiki agent assist
```

starts an interactive Claude Code (or Codex) session whose system prompt embeds a live
snapshot of shiki's state — the working directory, the services declared under
`services/*.dhall` (name, default namespace, analyzer backend), the last twenty rows from
the `runs` table (id prefix, service, status, error summary), and the full reference of
shiki subcommands — and whose allowed tools are scoped to exactly the commands an
operator needs to drive shiki end-to-end (`Bash(shiki *)`, `Bash(kubectl get *)`,
`Bash(kubectl logs *)`, `Read`, `Glob`, `Grep`, plus pwd / ls / cat). The agent can then
talk the operator through "submit a run for service mls-service-v2, wait for it to
finish, fetch the logs if it failed, and re-analyze with Claude Haiku if the heuristic
summary is unhelpful" by issuing those exact `shiki` subprocess invocations itself, while
the operator stays in the loop in the terminal.

The provider that backs the session is configurable, so the operator can swap CLI
back-ends without rebuilding shiki:

```bash
shiki agent assist                                # claude-cli (default)
shiki agent assist --provider codex-cli           # Codex CLI
shiki agent assist --provider anthropic --model claude-sonnet-4-6
shiki agent assist --provider openai    --model gpt-4o-mini
shiki agent assist --debug                        # print the rendered system prompt and exit
shiki agent assist --service mls-service-v2--prompt "the last run failed, help me re-run with --batch-size 100"
```

The `claude-cli` and `codex-cli` providers spawn the local CLI subprocess
(`Baikai.Provider.Claude.Interactive.launchClaudeInteractive` and the matching Codex
helper) so the operator gets a real terminal session with tool use. The `anthropic` and
`openai` providers issue a single non-interactive `Baikai.completeRequest` against the
hosted API and print the assistant's text — useful when shiki is being invoked from a
script or CI runner.

Operators can also pin defaults in their environment:

```bash
export SHIKI_AGENT_PROVIDER=claude-cli
export SHIKI_AGENT_MODEL=claude-sonnet-4-6
```

CLI flags win; environment variables are the fallback; hard-coded defaults
(`claude-cli`, no model) are last.

A reader can see the change working by:

1. Checking out this branch, entering `nix develop`, running
   `cabal build all && cabal install --install-method=copy --overwrite-policy=always --installdir=$HOME/.local/bin shiki`,
   exporting `SHIKI_DATABASE_URL=$PG_CONNECTION_STRING`, and from a directory that
   contains a `services/` folder running `shiki agent assist --debug`. They will see a
   markdown system prompt printed to stdout that lists every `.dhall` file under
   `services/` and the last twenty rows from `runs` (or `(no runs yet)` if empty).
2. Then running `shiki agent assist` without `--debug`. A `claude` (Claude Code) session
   opens with that exact prompt pre-loaded; the operator can ask "list my services" and
   the agent will reply by invoking `shiki service show <name>` against each one through
   its allowed-tool list.
3. Then running `shiki agent assist --provider anthropic --model claude-sonnet-4-6
   --prompt "summarise the last failed run"`. Shiki sends the system prompt plus that
   one user message to the Anthropic Messages API and prints the assistant's reply to
   stdout. (Requires `ANTHROPIC_API_KEY` in the environment, which the existing
   `shiki runs analyze --analyzer=baikai:anthropic_*` path already documents.)


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented
here, even if it requires splitting a partially completed task into two ("done" vs.
"remaining"). This section must always reflect the actual current state of the work.

- [x] M1 — Introduce the agent-config types and parsers. Add
  `shiki-cli/src/Shiki/Cli/Agent/Provider.hs` exporting the `AgentProvider` ADT
  (`ClaudeCli`, `CodexCli`, `Anthropic`, `OpenAI`), `providerFromText` /
  `providerToText`, the `AgentModelConfig` record (`provider`, `model :: Maybe Text`),
  and `defaultAgentModelConfig`. Add `shiki-cli/src/Shiki/Cli/Agent/Config.hs` exporting
  `resolveAgentModelConfig :: Maybe Text -> Maybe Text -> IO (Either Text
  AgentModelConfig)` that layers CLI flag → env (`SHIKI_AGENT_PROVIDER`,
  `SHIKI_AGENT_MODEL`) → default. Ship tasty-hunit tests under
  `shiki-cli/test/Shiki/Cli/Agent/ProviderSpec.hs` (the cabal test suite already lives
  on the package; if `shiki-cli` does not have one yet, add one in the same milestone).
- [x] M2 — Add `shiki-cli/src/Shiki/Cli/Agent/Context.hs` exporting an `AgentContext`
  record and a `gatherAgentContext :: CliEnv -> IO AgentContext`. The record captures
  `cwd :: Text`, `servicesDir :: FilePath`, `services :: [ServiceSummary]` (one
  `ServiceSummary` per `.dhall` file under `services/` — the loader is best-effort and
  drops files that fail to parse, capturing the failure path in `serviceLoadErrors`),
  `recentRuns :: [RunRecord]` (the last twenty rows fetched through the existing
  `listRecentRunsStatement` in `Shiki.Persistence.Run`), and `schemaName :: Text` (the
  resolved Postgres schema from `CliEnv`). The Kubernetes side stays loose for now: a
  `cluster :: Text` field carries the textual cluster name read from the kube context
  (or `"unknown"` if introspection fails); no extra cluster RPCs are issued.
- [x] M3 — Embed the prompt template. Create
  `shiki-cli/data/prompts/assist.md` (a plain markdown file with `{{cwd}}`,
  `{{services}}`, `{{recent_runs}}`, `{{schema}}`, `{{cluster}}`, `{{user_prompt}}`
  placeholders), wire it into `shiki-cli.cabal` via a `data-files:` stanza, and add
  `shiki-cli/src/Shiki/Cli/Agent/Prompt.hs` exporting `renderAssistPrompt ::
  AgentContext -> Maybe Text -> Text` plus a private `substitute` helper. Use
  `file-embed`'s `embedStringFile` splice so the template is baked into the binary; no
  runtime file I/O. Add `file-embed` to `shiki-cli.cabal` build-depends and enable
  `TemplateHaskell` for the `Prompt` module.
- [ ] M4 — Add the launcher.
  `shiki-cli/src/Shiki/Cli/Agent/Launch.hs` exports
  `runAssistSession :: AgentModelConfig -> AssistOptions -> Text -> IO ExitCode`
  where `AssistOptions` carries the `debug`, `userPrompt`, and pre-seeding fields. The
  dispatch table is: `debug = True` → print the system prompt and `exitSuccess`;
  `provider ∈ {ClaudeCli, CodexCli}` → call `launchClaudeInteractive` or
  `launchCodexInteractive` from `baikai-claude` / `baikai-openai` with the assist
  allow-list and forward the exit code; `provider ∈ {Anthropic, OpenAI}` → build the
  `Baikai.Model`/`Context`/`Options` triple, call `Baikai.completeRequest`, print the
  assistant text, and exit 0. Vendor `register` calls land lazily before each
  `completeRequest`, mirroring `Shiki.Analysis.Baikai`.
- [ ] M5 — Wire the subcommand. Extend `Shiki.Cli.Command` to add an `Agent
  AgentCommand` arm with an `AssistOptions` payload, add `agentParser` /
  `assistOptionsParser` in `Shiki.Cli`, and route into `runAssist :: CliEnv ->
  AgentModelConfig -> AssistOptions -> IO ()` from `Shiki.Cli.Agent`. Flag surface:
  `--provider`, `--model`, `--prompt`, `--service`, `--run`, `--debug`. Confirm
  `shiki --help` lists the new `agent` subcommand and `shiki agent assist --help`
  lists every flag.
- [ ] M6 — README section, smoke transcript, and CHANGELOG entry. Add a new
  "Agent assist" section to `README.md` documenting the flags, env vars, and a
  one-paragraph example. Record a real terminal transcript in this plan's Concrete
  Steps section showing `shiki agent assist --debug` against the dev DB.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Place the new modules under `Shiki.Cli.Agent.*` rather than
  `Shiki.Agent.*` in `shiki-core`.
  Rationale: The agent loop only makes sense at the CLI boundary — it gathers
  shiki's *CLI* state (working directory, services on disk, recent runs through the
  pool the CLI already opened) and spawns *CLI* subprocesses. Putting it in
  `shiki-core` would force the library to depend on `file-embed`,
  `baikai-claude`'s `Interactive` module, and the `process` infrastructure for no
  consuming library other than `shiki-cli`. The split also keeps `shiki-core`'s
  test surface free of subprocess mocking.
  Date: 2026-05-27.

- Decision: Reuse the seihou-style "single library + Baikai.Interactive +
  per-provider Interactive launcher" pattern verbatim rather than rolling a new
  subprocess wrapper.
  Rationale: `baikai`'s `Baikai.Interactive` already encodes the
  `ClaudeAllowedTools` / `CodexSandbox` safety vocabulary, and its vendor packages
  expose `launchClaudeInteractive` and `launchCodexInteractive` that handle the
  process-spawn, signal forwarding, and exit-code plumbing seihou already proved
  out (see `seihou-cli/src-exe/Seihou/CLI/AgentLaunchExec.hs`). Duplicating that
  surface inside shiki would be net-negative work.
  Date: 2026-05-27.

- Decision: Default the inline `shiki agent assist` provider to `claude-cli` with
  no explicit model.
  Rationale: Matches `defaultAgentModelConfig` in
  `seihou-cli/src/Seihou/CLI/AgentCompletion.hs` and the operator's existing muscle
  memory from seihou. The empty model field lets the Claude Code CLI pick its own
  current default rather than pinning shiki to a particular catalog id.
  Date: 2026-05-27.

- Decision: Do not change `shiki-core`'s existing analyzer surface
  (`Shiki.Analysis.Baikai`, `Shiki.Analysis.Backend`) in this plan.
  Rationale: `runs analyze` is a *post-hoc* summarization path that already uses
  `Baikai.completeRequest` correctly. The agent-assist path is an *interactive*
  session that uses the orthogonal `Baikai.Interactive` surface. They share the
  `baikai` library dependency at the cabal level and nothing else; conflating
  them now would force a refactor that is not justified by either feature.
  Date: 2026-05-27.

- Decision: Allowed-tool list for the assist session is hard-coded in
  `Shiki.Cli.Agent.Launch`, not configurable.
  Rationale: The point of an allow-list is to scope the agent to commands an
  operator would not be surprised to see issued on their behalf. Making it a flag
  invites configuration drift between operators and removes the defense-in-depth
  the allow-list provides. If later work needs a per-environment override, a
  Decision Log entry will record the change.
  Date: 2026-05-27.

- Decision: The `--prompt`, `--service`, `--run` flags are *pre-seeding* hints
  rather than first-class CLI knobs.
  Rationale: They land in the system prompt as a `## User Hints` block and (for
  CLI providers) as the `userPrompt` field of `InteractiveLaunchRequest`. The
  agent decides whether to act on them; shiki does not pre-execute any subcommand
  on the operator's behalf. This keeps the behavior contract simple ("the agent
  reads them and may use them") and avoids the failure mode where shiki tries to
  resolve a stale `--run` id before the agent session even starts.
  Date: 2026-05-27.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

A reader new to this repository should know:

- **shiki** is a Haskell project at `/Users/shinzui/Keikaku/bokuno/shiki` split into two
  cabal packages: `shiki-core` (the library, at `shiki-core/`) and `shiki-cli` (the
  executable wrapper named `shiki`, at `shiki-cli/`). Both target GHC 9.12.4 with
  `default-language: GHC2024`. The Nix dev shell entered via `nix develop` provides
  the toolchain. Build all packages with `cabal build all`.

- The top-level CLI dispatcher is `shiki-cli/src/Shiki/Cli.hs`. Its `Command` ADT
  has three constructors today — `Run`, `Runs`, `ServiceShow` — and an
  `optparse-applicative` `hsubparser` block at the bottom assigns each to the
  string `"run"`, `"runs"`, or `"service"`. New subcommands extend the ADT and add
  a `Opt.command` entry; nothing else in the dispatcher needs to change.

- Per-invocation context lives in `shiki-cli/src/Shiki/Cli/Env.hs` as the `CliEnv`
  record `{ pool :: Hasql.Pool.Pool, client :: Shiki.K8s.Client.ClientEnv }`. It is
  acquired by `withCliEnv :: ConnectionString -> Schema -> (CliEnv -> IO a) -> IO a`,
  which opens the Postgres pool, runs migrations, loads the Kubernetes client
  config, and tears the pool down on exit. The `Run` and `Runs` handlers both
  receive a `CliEnv`; the new `Agent` handler will too.

- The connection string and schema name are resolved by
  `Shiki.Cli.Config.resolveConnectionString` (flag → `SHIKI_DATABASE_URL` →
  `PG_CONNECTION_STRING`) and `Shiki.Cli.Schema.resolveSchema` (flag →
  `SHIKI_DB_SCHEMA` → default `"shiki"`). The new agent code does not need to add
  any new env vars besides its own `SHIKI_AGENT_PROVIDER` and `SHIKI_AGENT_MODEL`.

- Recent-run access is already provided by
  `Shiki.Persistence.Run.listRecentRunsStatement :: Statement Int [RunRecord]`,
  which `Shiki.Cli.Runs.doList` calls via the local `runRead` helper. The new
  context gatherer will call the same statement directly through
  `Hasql.Pool.use` / `Hasql.Session.statement` and ignore service-name filtering.

- Service configs live in `services/*.dhall` (one file per service). The
  repository ships an example at `services/mls-service-v2.dhall`. The loader is
  `Shiki.Service.Config.Dhall.loadServiceConfig :: FilePath -> IO ServiceConfig`;
  the resulting `ServiceConfig` is defined at
  `shiki-core/src/Shiki/Service/Config.hs` and has fields
  `name :: ServiceName`, `defaultNamespace :: Text`, `analyzer :: AnalyzerBackend`,
  plus the deployment-introspection fields the run path uses. The agent's context
  needs only `name`, `defaultNamespace`, and `analyzer`.

- **baikai** is the provider-neutral AI library at
  `/Users/shinzui/Keikaku/bokuno/baikai`, already pinned in
  `cabal.project` (lines 8–11) and already depended on by `shiki-core`'s
  `Shiki.Analysis.Baikai`. The three packages shiki uses are:
  - `baikai` — core types (`Baikai.Model`, `Baikai.Context`, `Baikai.Options`,
    `Baikai.completeRequest`, `Baikai.Response`) plus the interactive vocabulary
    at `Baikai.Interactive` (`InteractiveLaunchRequest`,
    `InteractiveLaunchResult`, `InteractiveSafety = ClaudeAllowedTools [Text] |
    CodexSandbox CodexSandboxMode CodexApprovalPolicy | DefaultSafety`).
  - `baikai-claude` — `Baikai.Provider.Claude.Api.register` (for the API path
    `Anthropic`) and `Baikai.Provider.Claude.Interactive.{launchClaudeInteractive,
    defaultClaudeInteractiveConfig}` (for the CLI path `ClaudeCli`).
  - `baikai-openai` — `Baikai.Provider.OpenAI.Api.register` (for `OpenAI`) and
    `Baikai.Provider.OpenAI.Interactive.{launchCodexInteractive,
    defaultCodexInteractiveConfig}` (for `CodexCli`).

  Shiki-core already lists all three in its `build-depends`. `shiki-cli` will
  pull them in via the same names in M3 / M4.

- **seihou** is the sibling project at
  `/Users/shinzui/Keikaku/bokuno/seihou-project/seihou` that already implements
  the pattern this plan replicates. The relevant files are:
  - `seihou-cli/src/Seihou/CLI/AgentCompletion.hs` — the `AgentProvider` ADT,
    `AgentModelConfig`, `providerFromText`, `buildBaikaiModel`,
    `runAgentCompletion`, and `responseText`. The shiki equivalents in
    M1 / M4 mirror this file almost verbatim, with the names trimmed (shiki has
    no need for the `AgentProvider*` prefix collision avoidance seihou inherited
    from earlier modules).
  - `seihou-cli/src-exe/Seihou/CLI/AgentLaunchExec.hs` — the CLI-vs-API dispatch
    in `launchConfiguredAgent` plus the `claude` / `codex` "not on PATH"
    diagnostic. The shiki equivalent in M4 keeps the same structure.
  - `seihou-cli/src-exe/Seihou/CLI/Assist.hs` — the actual `seihou agent assist`
    handler. The shiki M5 wiring follows its shape: gather context, render
    prompt, dispatch via the configured provider, exit with the subprocess's
    exit code.
  - `seihou-cli/data/assist-prompt.md` — the template seihou embeds. The shiki
    prompt in M3 is a much shorter analogue: shiki has fewer concepts to teach
    the agent (services, runs, analyzers) and one external dependency
    (`kubectl`).

  Reading these four files before editing the shiki code is the fastest way to
  build intuition for what this plan asks for; the structure carries over almost
  one-to-one.

- The reference pattern document is
  `/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/cli/agents/agent-assist-commands.md`.
  It describes the abstract architecture ("CLI command → context assembly → system
  prompt → AI session") and the "file-embed + `{{var}}` substitution" template
  pattern in detail. This plan applies that pattern to shiki; nothing in the plan
  contradicts the reference document.

- **Term: agent.** In this plan "agent" means an interactive AI assistant
  process — Claude Code or Codex CLI — that the operator drives in a terminal,
  not a long-running daemon. The session lasts for one operator conversation; it
  exits when the operator types `/exit` or `Ctrl-D`.

- **Term: prompt template.** A markdown file with `{{name}}` placeholders. At
  call time, `substitute` replaces every `{{name}}` with the matching value from
  a `[(Text, Text)]` list and returns the rendered text. There is no template
  language; computation happens in formatters *before* substitution. This
  matches the rationale in
  `/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/cli/agents/agent-assist-commands.md`
  under "Why Not a Real Template Engine?".


## Plan of Work

The work is broken into six milestones. Each milestone leaves shiki in a state where
`cabal build all` succeeds and the existing `cabal test all` suite still passes.

### M1 — Agent provider & config types (shiki-cli library only)

Goal: introduce the smallest typed surface needed to talk about "which provider, which
model" without yet involving the prompt, the context, or the subprocess. End-of-milestone
state: `shiki-cli` exports a new internal module
`Shiki.Cli.Agent.Provider` and `Shiki.Cli.Agent.Config`; nothing else in the binary uses
them yet; a new tasty test suite verifies the parsers and resolution order.

Edits:

- New file `shiki-cli/src/Shiki/Cli/Agent/Provider.hs`:
  - Module header explaining the file's purpose ("typed selector for the AI
    provider that backs `shiki agent assist`"); see existing modules for the
    voice.
  - `data AgentProvider = ClaudeCli | CodexCli | Anthropic | OpenAI` with
    `deriving stock (Generic, Eq, Show)`.
  - `data AgentModelConfig = AgentModelConfig { provider :: !AgentProvider, model
    :: !(Maybe Text) }` with `Generic, Eq, Show`.
  - `defaultAgentModelConfig :: AgentModelConfig` → `AgentModelConfig ClaudeCli
    Nothing`.
  - `providerFromText :: Text -> Either Text AgentProvider` and
    `providerToText :: AgentProvider -> Text`. The accepted spellings are
    `claude-cli`, `codex-cli`, `anthropic`, `openai` (case-insensitive,
    leading/trailing whitespace stripped). Mismatch returns `Left "unknown
    agent provider '<x>'. Expected one of: claude-cli, codex-cli, anthropic,
    openai."`.

- New file `shiki-cli/src/Shiki/Cli/Agent/Config.hs`:
  - `resolveAgentModelConfig :: Maybe Text -> Maybe Text -> IO (Either Text
    AgentModelConfig)`. Precedence per field: CLI argument → environment
    variable (`SHIKI_AGENT_PROVIDER`, `SHIKI_AGENT_MODEL`) → default. Resolution
    is best-effort: if the environment variable's value fails to parse as a
    provider, return `Left` and let the caller print + exit.
  - Constants `providerEnvVar :: String = "SHIKI_AGENT_PROVIDER"` and
    `modelEnvVar :: String = "SHIKI_AGENT_MODEL"`.

- Edit `shiki-cli/shiki-cli.cabal`:
  - Add `Shiki.Cli.Agent.Provider` and `Shiki.Cli.Agent.Config` to the
    library's `exposed-modules`.

- New file `shiki-cli/test/Shiki/Cli/Agent/ProviderSpec.hs`. Covers:
  - Every `providerFromText` input including a case-insensitive sample
    (`"Claude-CLI"`), a whitespace sample (`"  openai\n"`), and an invalid
    sample.
  - `providerToText . providerFromText` round-trips for all four providers.
  - `resolveAgentModelConfig (Just "openai") Nothing` returns
    `AgentModelConfig OpenAI Nothing` regardless of env.
  - `resolveAgentModelConfig Nothing Nothing` with both env vars unset returns
    the default.
  - `resolveAgentModelConfig Nothing Nothing` with `SHIKI_AGENT_PROVIDER=bad`
    returns `Left`.

  Because `shiki-cli.cabal` does not currently have a test stanza, M1 also adds
  a `test-suite shiki-cli-test` block patterned on `shiki-core`'s, with
  `Shiki.Cli.Agent.ProviderSpec` as its first member. The tasty driver lives in
  `shiki-cli/test/Spec.hs`, also new in this milestone.

Validation: `cabal build all` and `cabal test shiki-cli` from
`/Users/shinzui/Keikaku/bokuno/shiki`. The test suite must report all assertions
passing.

### M2 — Live context gatherer

Goal: produce a typed snapshot of "what shiki knows right now" that downstream code can
render into a prompt. End-of-milestone state: `Shiki.Cli.Agent.Context` exists and can
be exercised from a tasty test against a temporary directory + the existing
`Shiki.Persistence.TestPg` harness.

Edits:

- New file `shiki-cli/src/Shiki/Cli/Agent/Context.hs`:
  - `data ServiceSummary = ServiceSummary { name :: !Text, defaultNamespace ::
    !Text, analyzer :: !Text }` where `analyzer` is the textual rendering of
    `AnalyzerBackend` (`"heuristic"`, `"baikai:<model>"`, or `"none"`).
  - `data AgentContext = AgentContext { cwd :: !Text, servicesDir :: !FilePath,
    services :: ![ServiceSummary], serviceLoadErrors :: ![FilePath], recentRuns
    :: ![RunRecord], schemaName :: !Text, cluster :: !Text }`. Use the existing
    `Shiki.Prelude` re-exports for `Text`.
  - `gatherAgentContext :: CliEnv -> Schema -> IO AgentContext`. Steps, in
    order:
      1. `cwd` ← `getCurrentDirectory` (`Text.pack`).
      2. Enumerate `services/*.dhall` under the cwd. If the directory does not
         exist, return empty lists; do not fail.
      3. For each file, attempt `loadServiceConfig`. On success, project into
         `ServiceSummary`; on failure, push the path into `serviceLoadErrors`.
      4. Query the last twenty rows via
         `Hasql.Session.statement 20 listRecentRunsStatement` against
         `env ^. #pool`. Surface persistence errors by returning empty
         `recentRuns` *and* pushing a textual entry into `serviceLoadErrors`
         prefixed with `"db: "` — the prompt template surfaces them.
      5. `cluster` ← read from the loaded kube config if cheap (best-effort).
         For M2 it is sufficient to return the literal string `"unknown"`; a
         later commit can plumb the cluster name through `Shiki.K8s.Client`.
  - `analyzerBackendToText :: AnalyzerBackend -> Text` is a pure helper exposed
    from the same module (other modules may want it later); covers the three
    constructors of `AnalyzerBackend`.

- Edit `shiki-cli/shiki-cli.cabal`:
  - Add `Shiki.Cli.Agent.Context` to `exposed-modules`.
  - Add `directory`, `filepath` to `build-depends` if they are not already
    pulled in transitively (check via `cabal build`; add only if needed).

- New test `shiki-cli/test/Shiki/Cli/Agent/ContextSpec.hs`:
  - With `withSystemTempDirectory`, create `services/foo.dhall` (a valid
    config), `services/bad.dhall` (intentionally malformed), and run
    `gatherAgentContext`. Assert `services` contains one entry named `"foo"`
    and `serviceLoadErrors` lists the `bad.dhall` path.
  - Use the existing `Shiki.Persistence.TestPg` harness (which boots an
    `ephemeral-pg` Postgres). Insert one row through
    `insertRunStatement` + `completeRunStatement` and assert `recentRuns` has
    length 1. The harness lives in `shiki-core/test/Shiki/Persistence/TestPg.hs`
    and is reused across persistence specs; add `shiki-core` to the test
    suite's `build-depends` if not already present, and depend on the
    persistence modules directly.

Validation: `cabal test shiki-cli`. Both new specs pass.

### M3 — Prompt template and renderer

Goal: produce the system-prompt text from an `AgentContext`. End-of-milestone state: a
new `Shiki.Cli.Agent.Prompt` exposes `renderAssistPrompt`; a golden-style tasty test
asserts the rendered string contains the key context blocks.

Edits:

- New file `shiki-cli/data/prompts/assist.md`. Contents (verbatim, including
  the placeholder syntax — the agent never sees the `{{...}}` markers after
  substitution):

  ```markdown
  # shiki agent assist

  You are assisting a human operator who runs `shiki`, a CLI that submits
  one-off Kubernetes Jobs against declared services and records every run in
  PostgreSQL.

  ## Working environment

  - Working directory: {{cwd}}
  - Postgres schema: {{schema}}
  - Cluster context: {{cluster}}
  - Services directory: {{services_dir}}

  ## Services declared on disk

  {{services}}

  ## Recent runs (most recent first, up to 20)

  {{recent_runs}}

  ## Tools you may run

  The operator has scoped your subprocess access to:

  - `shiki run <service> [-- args...]` — submit a new one-off Job for the
    named service and (without `--no-wait`) follow it to completion.
  - `shiki runs list [--service NAME] [--limit N]` — recent runs as a table.
  - `shiki runs show <id>` — one row as pretty JSON. Accepts an unambiguous
    8-char prefix.
  - `shiki runs logs <id>` — the captured log tail for one run.
  - `shiki runs error <id>` — just the error_summary one-liner.
  - `shiki runs analyze <id> [--analyzer=heuristic|baikai:<model>|none]` —
    re-run analysis over the stored log tail. The baikai backend requires
    `ANTHROPIC_API_KEY` (for `anthropic_*` models) or `OPENAI_API_KEY` (for
    `openai_*`) in the operator's environment.
  - `shiki service show <name>` — pretty-print one service config as JSON.
  - `kubectl get <resource> ...` and `kubectl logs <pod> ...` — for sanity
    checks against the live cluster. Avoid mutating verbs.

  ## How to help

  1. Confirm the operator's intent. If you are about to submit a job, restate
     the service, namespace, and command-line arguments before running it.
  2. Drive shiki's own subcommands rather than re-implementing them. When the
     operator asks "did the last run fail," call `shiki runs list --limit 5`
     and read the row.
  3. When a run failed, fetch its `error_summary` with `shiki runs error <id>`.
     If the summary is missing or looks unhelpful, suggest running
     `shiki runs analyze <id> --analyzer=baikai:anthropic_claude_haiku_4_5`
     to get a richer summary, and run it if the operator agrees.
  4. Pre-seeded hints from the operator (if any) follow. Treat them as the
     opening message, not as commands you must execute immediately:

  ## Operator hints

  {{user_prompt}}
  ```

- Edit `shiki-cli/shiki-cli.cabal`:
  - Add a `data-files:` stanza listing `data/prompts/assist.md`. (This makes
    the file available through `Paths_shiki_cli` for runtime reads, but the
    template is embedded at compile time below; the stanza is a belt-and-braces
    measure for downstream tooling that lists data files.)
  - Add `file-embed` to the library's `build-depends`.

- New file `shiki-cli/src/Shiki/Cli/Agent/Prompt.hs`:
  - `{-# LANGUAGE TemplateHaskell #-}` pragma at the top.
  - `defaultAssistPrompt :: Text` defined as
    `TE.decodeUtf8 $(embedFile "data/prompts/assist.md")` (the path is
    relative to `shiki-cli/` where the cabal file lives).
  - `renderAssistPrompt :: AgentContext -> Maybe Text -> Text`. Builds the
    substitution list (see below) and calls `substitute defaultAssistPrompt
    subs`. The optional second argument is the operator's pre-seeded prompt;
    `Nothing` becomes the literal string `(no hints)`.
  - Private helper `substitute :: Text -> [(Text, Text)] -> Text` implemented
    as `foldl' (\t (k, v) -> Text.replace ("{{" <> k <> "}}") v t) tpl subs`.
  - Private formatters: `formatServices :: [ServiceSummary] -> Text` (returns
    one bullet line per service, or `(none declared)` when empty),
    `formatRuns :: [RunRecord] -> Text` (one line per run with id-prefix,
    service, status, error-summary or `-`, or `(no runs yet)` when empty).

- Edit `shiki-cli/shiki-cli.cabal`:
  - Add `Shiki.Cli.Agent.Prompt` to `exposed-modules`.

- New test `shiki-cli/test/Shiki/Cli/Agent/PromptSpec.hs`:
  - Build a fixture `AgentContext` with two services and three runs. Assert
    that the rendered prompt contains the strings `"foo"`, `"bar"`, every
    run's id-prefix, and the verbatim line `"## Recent runs"`.
  - Assert that `renderAssistPrompt ctx Nothing` produces
    `"...## Operator hints\n\n(no hints)\n"` near the end.

Validation: `cabal test shiki-cli`.

### M4 — Provider launcher

Goal: dispatch a rendered system prompt to the right backend. End-of-milestone state:
`Shiki.Cli.Agent.Launch.runAssistSession` accepts an `AgentModelConfig`, the rendered
prompt, an optional user prompt, and a debug flag, and returns the subprocess exit
code (or `ExitSuccess` for the API and debug paths).

Edits:

- New file `shiki-cli/src/Shiki/Cli/Agent/Launch.hs`:
  - `data AssistDispatch = AssistDispatch { systemPrompt :: !Text, userPrompt
    :: !(Maybe Text), debug :: !Bool }`.
  - `runAssistSession :: AgentModelConfig -> AssistDispatch -> IO ExitCode`.
    Branches:
      - `debug = True` → `TIO.putStr systemPrompt >> pure ExitSuccess`.
      - `provider = ClaudeCli` → `launchClaude (model cfg) systemPrompt
        userPrompt`.
      - `provider = CodexCli` → `launchCodex (model cfg) systemPrompt
        userPrompt`.
      - `provider = Anthropic` → `runOneShotApi anthropic_register
        (anthropicModel cfg) systemPrompt userPrompt`.
      - `provider = OpenAI` → `runOneShotApi openai_register (openAiModel cfg)
        systemPrompt userPrompt`.
  - Private `launchClaude :: Maybe Text -> Text -> Maybe Text -> IO ExitCode`.
    Steps:
      1. `findExecutable "claude"`; if `Nothing`, print
         `shiki: 'claude' CLI not found on PATH (install: https://docs.anthropic.com/en/docs/claude-code)`
         to stderr and `exitFailure`.
      2. `cwd <- getCurrentDirectory`.
      3. Build `InteractiveLaunchRequest { systemPrompt = Just sys, userPrompt
         = fromMaybe "" mPrompt, model = mModel, workingDir = Just cwd,
         extraDirs = [], safety = ClaudeAllowedTools assistAllowedTools,
         extraArgs = [] }`.
      4. Call `launchClaudeInteractive defaultClaudeInteractiveConfig req` and
         return its `exitCode`.
  - Private `launchCodex` mirrors `launchClaude` but uses
    `findExecutable "codex"`, `CodexSandbox CodexWorkspaceWrite
    CodexApprovalOnRequest`, and `launchCodexInteractive
    defaultCodexInteractiveConfig`.
  - Private `runOneShotApi :: IO () -> Model -> Text -> Maybe Text -> IO
    ExitCode`. Calls the `register` action (lazy provider registration the
    same way `Shiki.Analysis.Baikai` does), then `Baikai.completeRequest model
    ctx _Options` where `ctx = _Context { systemPrompt = Just sys, messages =
    maybe V.empty (V.singleton . user) mPrompt }`. On success, prints the
    assistant text (joined `Baikai.flattenAssistantBlocks`-style) and returns
    `ExitSuccess`. On `Baikai.BaikaiError`, prints
    `shiki: agent api call failed: <err>` to stderr and `exitFailure`.
  - `assistAllowedTools :: [Text]`. The exact list:

    ```haskell
    assistAllowedTools :: [Text]
    assistAllowedTools =
      [ "Bash(shiki *)"
      , "Bash(kubectl get *)"
      , "Bash(kubectl logs *)"
      , "Bash(pwd)"
      , "Bash(ls *)"
      , "Bash(cat *)"
      , "Read"
      , "Glob"
      , "Grep"
      ]
    ```

  - Provider/model bridging:
    `anthropicModel :: AgentModelConfig -> Model = Baikai._Model
    { modelId = fromMaybe "claude-sonnet-4-6" cfg.model, name = ..., api =
    Baikai.AnthropicMessages, provider = "anthropic", baseUrl =
    "https://api.anthropic.com" }`. The OpenAI counterpart picks
    `"gpt-4o-mini"` as the fallback model id and uses
    `Baikai.OpenAIChatCompletions`. Both follow the shape in
    `Seihou.CLI.AgentCompletion.buildBaikaiModel`.

- Edit `shiki-cli/shiki-cli.cabal`:
  - Add `Shiki.Cli.Agent.Launch` to `exposed-modules`.
  - Add `baikai`, `baikai-claude`, `baikai-openai`, `directory`, `process`,
    `vector` to `build-depends` if not already present.

- New test `shiki-cli/test/Shiki/Cli/Agent/LaunchSpec.hs`:
  - One assertion: `runAssistSession defaultAgentModelConfig (AssistDispatch
    "PROMPT" Nothing True)` writes the literal string `"PROMPT"` to stdout
    (capture via `hSilence` / `hCapture` from `silently`) and returns
    `ExitSuccess`. This is enough to lock in the debug path without spawning
    Claude. The subprocess paths are exercised manually in M6.

Validation: `cabal test shiki-cli`.

### M5 — Wire the subcommand

Goal: surface `shiki agent assist` on the CLI. End-of-milestone state: `shiki --help`
shows the new `agent` subcommand and `shiki agent assist --help` lists every flag.

Edits:

- New file `shiki-cli/src/Shiki/Cli/Agent.hs` (the dispatcher for the new
  `agent` family — only one verb today, `assist`):
  - `data AgentCommand = AgentAssist !AssistOptions` with `Generic, Eq, Show`.
  - `data AssistOptions = AssistOptions { provider :: !(Maybe Text), model ::
    !(Maybe Text), prompt :: !(Maybe Text), service :: !(Maybe Text), runId ::
    !(Maybe Text), debug :: !Bool }`.
  - `agentParser :: Parser AgentCommand` using `hsubparser` with one entry:
    `Opt.command "assist" (info (AgentAssist <$> assistOptionsParser)
    (progDesc "Open an interactive AI session preloaded with shiki context"))`.
  - `assistOptionsParser :: Parser AssistOptions` building each field through
    `optional (strOption ...)` etc. Flag long names:
    `--provider`, `--model`, `--prompt`, `--service`, `--run`, `--debug`.
  - `runAgent :: CliEnv -> Schema -> AgentCommand -> IO ()`. Implementation:
      1. Pattern-match `AgentAssist opts`.
      2. Resolve the model config with `resolveAgentModelConfig opts.provider
         opts.model`; on `Left err` print `shiki: <err>` and `exitFailure`.
      3. Gather context with `gatherAgentContext env schema`.
      4. Build the user-hint block. If any of `prompt`, `service`, `runId` is
         set, concatenate them into one Markdown bullet list ("Operator
         requested service `mls-service-v2`.", "Operator referenced run
         `abcd1234`.", and the raw prompt body); otherwise pass `Nothing`.
      5. `let sys = renderAssistPrompt ctx hints`.
      6. `code <- runAssistSession cfg (AssistDispatch sys opts.prompt
         opts.debug)`. The user prompt and the hint block are different: the
         hint block is rendered into the system prompt; the user prompt (raw
         `--prompt` value) is what is sent as the first user-role message in
         the conversation.
      7. `exitWith code`.

- Edit `shiki-cli/shiki-cli.cabal`:
  - Add `Shiki.Cli.Agent` to `exposed-modules`.

- Edit `shiki-cli/src/Shiki/Cli.hs`:
  - Import `Shiki.Cli.Agent (AgentCommand, agentParser, runAgent)` and
    `Shiki.Cli.Schema (Schema)` (for passing the schema through).
  - Extend `data Command` with a fourth constructor: `Agent !AgentCommand`.
  - Extend `runCli`'s case-of: add `Agent agentOpts -> withDbEnv (opts ^.
    #dbConnStr) (opts ^. #dbSchema) $ \env -> runAgent env (...) agentOpts`.
    The schema name needs to be available; pass it through by either threading
    the resolved `Schema` out of `withDbEnv` (preferred — bump `withCliEnv`'s
    closure to also expose `Schema`) or by re-resolving it at the call site
    via `resolveSchema (opts ^. #dbSchema)`. The simpler path: re-resolve at
    the call site; the dedicated `Shiki.Cli.Schema` module already exists for
    this purpose, and the second resolution is cheap (no I/O on the default
    path; one `lookupEnv` otherwise).
  - Extend `commandParser` with a fourth `Opt.command "agent" (info (Agent
    <$> agentParser) (progDesc "Agentic helpers for driving shiki"))`.

  Concretely the diff in `runCli` looks like:

  ```haskell
  case opts ^. #command of
    ServiceShow nm -> serviceShowHandler nm
    Run runOpts    ->
      withDbEnv (opts ^. #dbConnStr) (opts ^. #dbSchema) $ \env ->
        runRun env runOpts
    Runs runsOpts  ->
      withDbEnv (opts ^. #dbConnStr) (opts ^. #dbSchema) $ \env ->
        runRuns env runsOpts
    Agent agentOpts -> do
      schema <- resolveSchema (opts ^. #dbSchema)
      withDbEnv (opts ^. #dbConnStr) (opts ^. #dbSchema) $ \env ->
        runAgent env schema agentOpts
  ```

Validation:

```bash
cabal build all
cabal run shiki -- --help
cabal run shiki -- agent --help
cabal run shiki -- agent assist --help
```

Expect `agent` to appear in the top-level `Available commands:` block and the
flag list under `agent assist --help` to include `--provider`, `--model`,
`--prompt`, `--service`, `--run`, `--debug`.

### M6 — Smoke test, README, CHANGELOG

Goal: prove the feature works against a real database and a real `claude` CLI, and
document it.

Edits:

- `README.md`: add a new section "Agent assist" after the "Error summaries and
  analysis backends" section. Document the four providers, the env vars, the
  five flags, and the example transcript captured in this plan's Concrete
  Steps section.

- `CHANGELOG.md`: a one-line entry under the unreleased heading:

  ```text
  - feat(shiki-cli): EP-8 — `shiki agent assist` opens an interactive AI session
    preloaded with shiki context (services, recent runs, schema, cluster).
    Provider/model configurable via `--provider`/`--model` or
    `SHIKI_AGENT_PROVIDER`/`SHIKI_AGENT_MODEL`.
  ```

- This plan's Concrete Steps section: paste the verbatim
  `shiki agent assist --debug` output and the first turn of an interactive
  `shiki agent assist` session against a service named `mls-service-v2`.

Validation: per the Concrete Steps transcripts below.


## Concrete Steps

All commands are run from `/Users/shinzui/Keikaku/bokuno/shiki` inside the Nix dev shell
(`nix develop`).

### Build and unit tests after each milestone

```bash
cabal build all
cabal test shiki-cli
cabal test shiki-core   # sanity: this plan does not touch shiki-core
```

Expected output (last line of each `test` invocation):

```text
All N tests passed (0.0Xs)
```

If any test fails, the milestone is incomplete; fix before moving on.

### Manual smoke after M5

```bash
cabal run shiki -- --help
```

Expected (truncated to the relevant lines):

```text
Available commands:
  run                      Submit a one-off Job and record the run in Postgres
  runs                     Inspect recorded runs
  service                  Inspect microservice configuration files
  agent                    Agentic helpers for driving shiki
```

```bash
cabal run shiki -- agent assist --help
```

Expected (flag list, in order):

```text
Available options:
  --provider PROVIDER      Agent provider: claude-cli, codex-cli, anthropic, openai
  --model MODEL            Agent model name or provider-specific model alias
  --prompt PROMPT          Initial user prompt to seed the session
  --service NAME           Pre-seed the prompt with a reference to a service
  --run ID                 Pre-seed the prompt with a reference to a run id
  --debug                  Print the rendered system prompt and exit
  -h,--help                Show this help text
```

### M6 smoke transcripts

Pre-requisites: `services/mls-service-v2.dhall` exists (the repo ships one), the
operator's `SHIKI_DATABASE_URL` points at a live or ephemeral Postgres, and
`claude` is on `PATH`.

Step 1: render the system prompt without launching a session.

```bash
export SHIKI_DATABASE_URL=$PG_CONNECTION_STRING
cabal install --install-method=copy --overwrite-policy=always --installdir=$HOME/.local/bin shiki
shiki agent assist --debug
```

Expected (first ~15 lines, before the services/runs blocks):

```text
# shiki agent assist

You are assisting a human operator who runs `shiki`, a CLI that submits
one-off Kubernetes Jobs against declared services and records every run in
PostgreSQL.

## Working environment

- Working directory: /Users/shinzui/Keikaku/bokuno/shiki
- Postgres schema: shiki
- Cluster context: unknown
- Services directory: services

## Services declared on disk

- mls-service-v2 (namespace: default, analyzer: heuristic)
```

Paste the *real* output captured during M6 into this section, replacing the
sample above.

Step 2: launch an interactive Claude Code session.

```bash
shiki agent assist --service mls-service-v2--prompt "the last run failed — help me re-run with --batch-size 100"
```

Expected behavior:

- A Claude Code terminal UI takes over the screen.
- The session has been seeded with the full system prompt from step 1 plus a
  first-turn user message containing the `--prompt` string.
- The agent's first action is typically to call
  `shiki runs list --service mls-service-v2 --limit 5` through its
  `Bash(shiki *)` allowance, then explain what it sees and propose a re-run.
- Exiting (Ctrl-D or `/exit`) returns to the shell with the subprocess's exit
  code propagated through `runAssistSession`.

Step 3: one-shot Anthropic API call.

```bash
export ANTHROPIC_API_KEY=...
shiki agent assist --provider anthropic --model claude-sonnet-4-6 --prompt "list my services"
```

Expected: shiki prints the assistant's reply to stdout (typically a bulleted
list of the service names from `## Services declared on disk`) and exits with
code 0.


## Validation and Acceptance

The change is accepted when:

1. `cabal build all` succeeds from a clean checkout entered through
   `nix develop`.
2. `cabal test shiki-cli` reports all tests passing, including the four new
   specs: `Shiki.Cli.Agent.ProviderSpec`, `Shiki.Cli.Agent.ContextSpec`,
   `Shiki.Cli.Agent.PromptSpec`, `Shiki.Cli.Agent.LaunchSpec`.
3. `cabal test shiki-core` still passes (this plan does not touch
   `shiki-core`; if any spec fails, the change has caused a regression and
   must be repaired before merge).
4. `shiki agent assist --debug` against the repo root prints a markdown
   document that:
     - Begins with the literal heading `# shiki agent assist`.
     - Lists every `.dhall` file under `services/` by name, namespace, and
       analyzer.
     - Lists either the last twenty recorded runs or the literal string
       `(no runs yet)`.
     - Closes with an `## Operator hints` block.
5. `shiki agent assist` (no `--debug`) with `claude` on `PATH` opens an
   interactive Claude Code session whose first response, when the operator
   types `"list my services"`, is to invoke `shiki service show <name>` via
   the agent's allowed-tool list.
6. `shiki agent assist --provider anthropic --model claude-sonnet-4-6 --prompt
   "ping"` (with `ANTHROPIC_API_KEY` set) prints a non-empty assistant reply
   to stdout and exits 0.
7. `shiki agent assist --provider bogus` exits with a non-zero code and a
   stderr line matching `shiki: unknown agent provider 'bogus'...`.

The behavior in items 4–7 must be reproducible from the transcripts pasted
into this plan's Concrete Steps section during M6.


## Idempotence and Recovery

Every step in this plan is safe to repeat:

- All milestones are additive at the cabal package level. M1–M4 add modules
  that nothing in the existing binary references; until M5 wires the
  subparser, the new code is dead code that ships in the library but is not
  exercised. Reverting any milestone is a `git revert` of its commit(s).

- The new code does not mutate the database. `gatherAgentContext` issues one
  read-only query (`listRecentRunsStatement`). If the database is unreachable
  the function returns an empty run list and an error entry under
  `serviceLoadErrors`; `shiki agent assist --debug` still works.

- The interactive launch path is process-level idempotent: each invocation
  spawns a fresh `claude` / `codex` subprocess, inherits the controlling
  terminal, and tears down on exit. Ctrl-C inside the agent session is
  forwarded by `baikai`'s interactive launcher to the child; shiki's own
  process exits when the child does.

- The API path is a single `Baikai.completeRequest` per invocation; on
  failure the function prints the error and exits non-zero without retry.
  Re-running the command is the recovery path.

- `cabal build all` after a partial milestone may fail if a module is added
  to `exposed-modules` but its source file has not been written yet, or vice
  versa. The recovery is to either add the missing file or revert the
  `.cabal` edit. No persistent state changes hands.


## Interfaces and Dependencies

The libraries pulled in by this plan, and why:

- `baikai` (path-pinned at `/Users/shinzui/Keikaku/bokuno/baikai/baikai`,
  already in `cabal.project`): provides `Baikai.Model`, `Baikai.Context`,
  `Baikai.Options`, `Baikai.completeRequest`, `Baikai.Response`,
  `Baikai.flattenAssistantBlocks`, plus the interactive vocabulary in
  `Baikai.Interactive` (`InteractiveLaunchRequest`, `InteractiveLaunchResult`,
  `InteractiveSafety`, `CodexSandboxMode`, `CodexApprovalPolicy`). Reason:
  shared cross-provider abstraction; the existing `Shiki.Analysis.Baikai`
  uses the API surface, and the new launcher uses the interactive surface.
- `baikai-claude` (same path, sibling package): exposes
  `Baikai.Provider.Claude.Api.register` (already used by
  `Shiki.Analysis.Baikai`) and
  `Baikai.Provider.Claude.Interactive.launchClaudeInteractive` /
  `defaultClaudeInteractiveConfig` (new dependency for the agent launcher).
- `baikai-openai` (same path, sibling package): exposes
  `Baikai.Provider.OpenAI.Api.register` and the matching
  `Baikai.Provider.OpenAI.Interactive.launchCodexInteractive` /
  `defaultCodexInteractiveConfig`.
- `file-embed` (Hackage): compile-time embedding of
  `shiki-cli/data/prompts/assist.md` via `embedFile`. No runtime file I/O,
  matching the rationale in
  `/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/cli/agents/agent-assist-commands.md`.
- `directory`, `filepath`, `process` (all Hackage, all transitively present
  via `baikai-claude`'s interactive launcher): used by
  `Shiki.Cli.Agent.Launch` for `findExecutable` and `getCurrentDirectory`,
  and by `Shiki.Cli.Agent.Context` for enumerating `services/*.dhall`.
- `vector` (Hackage): the `Baikai.Context.messages` field is a
  `Vector Message`; the API path constructs a singleton vector.

Function and module surface at the end of each milestone (names are stable
public exports unless marked private):

- End of M1: `Shiki.Cli.Agent.Provider` exports `AgentProvider(..)`,
  `AgentModelConfig(..)`, `defaultAgentModelConfig`, `providerFromText`,
  `providerToText`. `Shiki.Cli.Agent.Config` exports
  `resolveAgentModelConfig`, `providerEnvVar`, `modelEnvVar`.
- End of M2: `Shiki.Cli.Agent.Context` exports
  `AgentContext(..)`, `ServiceSummary(..)`, `gatherAgentContext`,
  `analyzerBackendToText`.
- End of M3: `Shiki.Cli.Agent.Prompt` exports `renderAssistPrompt`.
  `defaultAssistPrompt` and `substitute` stay private to the module.
- End of M4: `Shiki.Cli.Agent.Launch` exports
  `AssistDispatch(..)`, `runAssistSession`, `assistAllowedTools`.
- End of M5: `Shiki.Cli.Agent` exports `AgentCommand(..)`,
  `AssistOptions(..)`, `agentParser`, `runAgent`. `Shiki.Cli` keeps the same
  shape but its `Command` ADT gains an `Agent` constructor.
- End of M6: documentation only; no Haskell-surface changes.

Inter-module dependencies introduced by this plan (pointing parent → child):

```text
Shiki.Cli  ─►  Shiki.Cli.Agent  ─►  Shiki.Cli.Agent.Context  ─►  Shiki.Cli.Env
                                ─►  Shiki.Cli.Agent.Prompt
                                ─►  Shiki.Cli.Agent.Launch
                                ─►  Shiki.Cli.Agent.Config
                                          │
                                          ▼
                                Shiki.Cli.Agent.Provider
```

No edges point *into* `shiki-core` other than the existing
`Shiki.Persistence.Run.listRecentRunsStatement`,
`Shiki.Service.Config.Dhall.loadServiceConfig`,
`Shiki.Service.Config.ServiceConfig`/`AnalyzerBackend`, and
`Shiki.Persistence.Schema.Schema`. The agent layer is a pure consumer of the
existing library surface.
