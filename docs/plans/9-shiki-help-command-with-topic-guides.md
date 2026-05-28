---
id: 9
slug: shiki-help-command-with-topic-guides
title: "shiki help command with topic guides"
kind: exec-plan
created_at: 2026-05-28T03:05:29Z
intention: "intention_01ksp8hwqdeqqr71b49q315nc4"
---

# shiki help command with topic guides

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Today an operator who wants to learn how `shiki` works has three options: read the
top-level `README.md`, read the in-repo user guides under `docs/user/` (the canonical
operator-facing reference, broken out into getting-started, commands, service-config,
schema, error-analysis, and agent-assist pages), or run `shiki <subcommand> --help`
(which only lists flags, not concepts). The first two are comprehensive but live
outside the binary and assume the reader is sitting in the repo; the third only ever
describes flags. There is no way for the operator to read, in their terminal and
without context-switching to a browser or a separate Markdown viewer, a short curated
guide to "what is a service config?", "what does an analyzer do?", or "what env vars
does shiki read?".

After this plan, running

```bash
shiki help
```

prints an index of named topic guides — one short paragraph per topic — and

```bash
shiki help services
```

prints the full guide for the named topic verbatim to the terminal. Topic lookup is
case-insensitive (`shiki help SERVICES` works), unknown topic names exit non-zero with
a clear error and the available list, and the topic content itself is baked into the
binary at compile time via `file-embed`, so there is no runtime file I/O and the binary
remains a single executable that needs no companion files.

The initial topic catalog (shipped in this plan) is:

- `services` — what a `services/*.dhall` config is, what fields a `ServiceConfig` has,
  and how to add a new service.
- `runs` — the lifecycle of a run, the columns of the `runs` table, the meaning of each
  status, and the id-prefix conventions used by the `runs *` subcommands.
- `analyzers` — the difference between `runs.error` and `runs.error_summary`, the three
  analyzer backends (`heuristic`, `baikai`, `none`), and when to use each.
- `agent` — what `shiki agent assist` does, the four providers, the env vars, and the
  allowed-tool list.
- `schema` — how shiki uses Postgres schemas, how to override the default, and how to
  migrate an existing checkout that wrote into `public`.
- `env` — the full list of environment variables shiki reads, with precedence rules.

A reader can see the change working by:

1. Checking out this branch, entering `nix develop`, running
   `cabal build all && cabal install --install-method=copy --overwrite-policy=always --installdir=$HOME/.local/bin shiki`,
   then running `shiki help`. They will see a topic index with six entries.
2. Then running `shiki help services`. They will see a multi-paragraph guide with
   ALL-CAPS section headers and 2-space indented content, as defined by the reference
   pattern at `/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/cli/help-topics.md`.
3. Then running `shiki help bogus`. They will see
   `Unknown topic: bogus` followed by `Available: services, runs, analyzers, agent, schema, env`
   and the process will exit with code 1.
4. Then running `shiki --help` and observing the new `help` line in the
   `Available commands:` block.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented
here, even if it requires splitting a partially completed task into two ("done" vs.
"remaining"). This section must always reflect the actual current state of the work.

- [x] M1 — Scaffold `Shiki.Cli.Help` module with the `HelpTopic` record, the
  `HelpCommand` ADT (`ListTopics`, `ShowTopic !Text`), the optparse parser, and the
  handler. Ship the first topic content file `shiki-cli/data/help/services.md` (the
  `services` guide) and the embedding splice for it. Wire the new subcommand into
  `Shiki.Cli.commandParser` and `Shiki.Cli.runCli`. End-of-milestone state: `shiki help`
  lists exactly one topic (`services`); `shiki help services` prints its content;
  `shiki help bogus` exits non-zero with the expected stderr message.
  Completed 2026-05-27. Build is clean; manual smoke matches the M1 acceptance.
- [x] M2 — Author the remaining five topic content files and register them.
  `shiki-cli/data/help/runs.md`, `shiki-cli/data/help/analyzers.md`,
  `shiki-cli/data/help/agent.md`, `shiki-cli/data/help/schema.md`,
  `shiki-cli/data/help/env.md`. Add one `embedStringFile` binding per file and append
  each to the `helpTopics` registry. End-of-milestone state: `shiki help` lists six
  topics; each `shiki help <name>` prints its content; lookup is case-insensitive.
  Completed 2026-05-27. All six topics are byte-identical to their source files
  (verified via `diff` per acceptance #9).
- [ ] M3 — Tasty specs, user-guide page, README index update, CHANGELOG entry. Add
  `shiki-cli/test/Shiki/Cli/HelpSpec.hs` covering parser branches, registry totality,
  case-insensitive lookup, and the unknown-topic error message. Create
  `docs/user/help.md` documenting the help command in the operator-guide style of its
  sibling pages, and add bullets pointing at it in `docs/user/README.md` and the
  top-level `README.md`'s `## Documentation` list. Append a CHANGELOG line. Paste the
  verbatim `shiki help` and `shiki help services` transcripts into this plan's
  Concrete Steps section.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **2026-05-28 — `docs/user/` exists and contains six near-1:1 pages.** A pre-existing
  set of operator guides under `docs/user/` covers exactly the same six concepts this
  plan needs help topics for. Comparing the initial topic drafts against those guides
  revealed several factual errors in the drafts:
    - `services`: the `ServiceConfig` field is `detectFromDeployment`, not
      `deployment`, and the command field is `commandPath`, not `command`. The config
      also exposes `serviceAccount`, `nodeSelector`, `initContainers`, `env`, and
      `resources`, which the initial draft omitted entirely.
      Evidence: `docs/user/service-config.md` lines 12–25.
    - `runs`: the `status` column's domain is `pending | running | succeeded | failed`
      (lowercase, no `Cancelled`), the finalize timestamp column is `ended_at` (not
      `finished_at`), and the table additionally has `image`, `service_config`,
      `error_summary_source`, `created_at`, and `updated_at` columns the draft did
      not mention. The id-prefix convention in `runs list` is **8 characters**, not
      4–6. Evidence: `docs/user/schema.md` lines 12–32 and
      `docs/user/getting-started.md` line 138.
    - `agent`: the API providers have shiki-side defaults
      (`anthropic` → `claude-sonnet-4-6`, `openai` → `gpt-4o-mini`) the draft did not
      list, and the Codex provider additionally sets sandbox mode to `workspace-write`
      with approval-on-request. Evidence: `docs/user/agent-assist.md` lines 74–82 and
      117–119.
  All three are fixed in the topic content below; the Decision Log records the
  canonical-source policy that surfaced these errors.


## Decision Log

Record every decision made while working on the plan.

- Decision: Place the new module at `Shiki.Cli.Help` under `shiki-cli`, not under
  `shiki-core`.
  Rationale: Help content describes the CLI surface (subcommands, flags, env vars).
  `shiki-core` has no CLI concept; it is the domain library. Adding `file-embed` and a
  Markdown corpus to `shiki-core` would force every library consumer to pull them in for
  no benefit. The agent-assist code already sets this precedent in EP-8 by putting
  prompt embedding under `Shiki.Cli.Agent.Prompt`, not in the core library.
  Date: 2026-05-28.

- Decision: Topic content lives under `shiki-cli/data/help/<topic>.md`, one file per
  topic, with the `.md` extension purely as an editor convenience. The files are
  embedded with `embedStringFile` and printed verbatim — no Markdown rendering, no
  reflow.
  Rationale: Matches the reference pattern at
  `/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/cli/help-topics.md` which explicitly
  notes "Topic files are plain text with ALL-CAPS section headers (no Markdown
  rendering, just printed directly to the terminal)". The `.md` extension keeps editors
  happy and is consistent with the existing `shiki-cli/data/prompts/assist.md` from
  EP-8. Terminal-aware width handling is out of scope for this plan — see the
  Idempotence and Recovery section for the follow-up.
  Date: 2026-05-28.

- Decision: Topic registry is a single Haskell-level `[HelpTopic]` list in
  `Shiki.Cli.Help`. No external configuration, no discovery scan.
  Rationale: The reference pattern uses a single list to drive the parser, the index
  display, and topic lookup; the registry's totality is then a compile-time property.
  Discovery via `Paths_shiki_cli` would push that into runtime and lose the guarantee
  that `helpTopics` and the `data/help/*.md` files agree. The cost of editing two
  places when adding a topic is one extra line in `Help.hs`, which is explicitly
  documented in the "Adding a new topic" section the reference pattern describes.
  Date: 2026-05-28.

- Decision: No FZF integration and no `--width N` flag in this plan.
  Rationale: The reference document at
  `/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/cli/help-topics.md` describes both as
  "optional" extensions composed on top of the base pattern, and shiki does not yet
  depend on either FZF or `terminal-size`. The user's request named only
  `help-topics.md`. Both extensions are additive and can be retrofitted later without
  changing the topic content files; see Idempotence and Recovery for the follow-up
  notes.
  Date: 2026-05-28.

- Decision: Six initial topics: `services`, `runs`, `analyzers`, `agent`, `schema`,
  `env`. Each maps to one existing concept already documented in `README.md`.
  Rationale: These six are the *self-contained* concepts a reader can act on without
  cross-referencing another topic. They cover every user-visible knob shiki has today
  (the four subcommand families plus the two pieces of cross-cutting infrastructure —
  Postgres schema and env vars). A `commands` meta-topic was considered and rejected as
  redundant with `shiki --help`.
  Date: 2026-05-28.

- Decision: `shiki help` (no argument) prints the topic index and exits 0. There is no
  interactive prompt or pager.
  Rationale: A pager would force a `LESS`/`MORE` dependency and break piping. The
  reference pattern says the bare `help` invocation prints the index; shiki follows the
  same convention. Operators who want paging can run `shiki help <topic> | less`.
  Date: 2026-05-28.

- Decision: Treat `docs/user/<page>.md` as the canonical source for every help topic;
  the in-terminal topic content is a *condensed restatement* of one user-guide page,
  not an independently-authored reference. Each topic file ends with a
  `Full reference: docs/user/<page>.md` line so the operator can jump to the long
  form when needed.
  Rationale: The repository already ships a comprehensive operator-facing reference
  under `docs/user/` (six pages mirroring almost exactly the six topics this plan
  introduces). Authoring the topic content independently would create a maintenance
  hazard — two sources of truth that will drift. Anchoring each topic to one canonical
  page keeps the help command terse (the binary stays small, the operator scrolls
  less) and gives drift a single, obvious gradient to repair: when `docs/user/<page>.md`
  changes, the matching `data/help/<topic>.md` is the next file to update. The 1:1 map
  is:
    - `services` ↔ `docs/user/service-config.md`
    - `runs`     ↔ `docs/user/getting-started.md` + `docs/user/commands.md` (the
      runs lifecycle is split across these two pages)
    - `analyzers` ↔ `docs/user/error-analysis.md`
    - `agent`    ↔ `docs/user/agent-assist.md`
    - `schema`   ↔ `docs/user/schema.md`
    - `env`      ↔ `docs/user/commands.md` (env var summary table)
  Date: 2026-05-28.

- Decision: Unknown-topic lookup exits non-zero (`exitFailure`) with the available
  topic list on stderr.
  Rationale: The reference pattern's handler prints the unknown-topic line and the
  available list but does not say whether to exit zero or non-zero. Choosing
  `exitFailure` matches the shell convention that "command did not produce the
  requested output" is a failure, and lets scripts that wrap shiki detect the typo via
  `$?`. The behavior matches what shiki already does for unknown analyzer overrides in
  `Shiki.Cli.Runs.analyzerKindReader` and unknown agent providers in EP-8.
  Date: 2026-05-28.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

A reader new to this repository should know:

- **shiki** is a Haskell project at `/Users/shinzui/Keikaku/bokuno/shiki` split into two
  cabal packages: `shiki-core` (the library, at `shiki-core/`) and `shiki-cli` (the
  executable wrapper named `shiki`, at `shiki-cli/`). Both target GHC 9.12.4 with
  `default-language: GHC2024`. The Nix dev shell entered via `nix develop` provides the
  toolchain. Build all packages from the repo root with `cabal build all`.

- **Canonical operator docs.** The repository ships `docs/user/` as the operator-facing
  reference, with six pages: `README.md` (index), `getting-started.md`,
  `commands.md`, `service-config.md`, `schema.md`, `error-analysis.md`, and
  `agent-assist.md`. These pages are the **source of truth** for every concept the
  in-terminal help topics summarize. Each topic file in this plan must agree with the
  corresponding `docs/user/<page>.md` file, and each topic ends with a
  `Full reference:` line pointing at the `docs/user/` page so an operator who needs
  more detail knows where to go. If a fact diverges between the user guides and the
  topic content during implementation, treat the `docs/user/` page as canonical and
  update the topic to match.

- The top-level CLI dispatcher is `shiki-cli/src/Shiki/Cli.hs`. Its `Command` ADT has
  four constructors today — `Run !RunOptions`, `Runs !RunsCommand`,
  `ServiceShow !Text`, `Agent !AgentCommand` — and an `optparse-applicative`
  `hsubparser` block in `commandParser` assigns each to the string `"run"`, `"runs"`,
  `"service"`, `"agent"`. New subcommands extend the ADT and add a `Opt.command` entry;
  nothing else in the dispatcher needs to change. The `runCli` function pattern-matches
  the four constructors and dispatches each to its handler.

- The library exposes its modules through `shiki-cli/shiki-cli.cabal`. The
  `exposed-modules:` list under `library` currently includes `Shiki.Cli`,
  `Shiki.Cli.Agent`, `Shiki.Cli.Agent.Config`, `Shiki.Cli.Agent.Context`,
  `Shiki.Cli.Agent.Launch`, `Shiki.Cli.Agent.Prompt`, `Shiki.Cli.Agent.Provider`,
  `Shiki.Cli.Config`, `Shiki.Cli.Env`, `Shiki.Cli.Run`, `Shiki.Cli.Runs`, and
  `Shiki.Cli.Schema`. Adding `Shiki.Cli.Help` follows the same pattern.

- The package already depends on `file-embed ^>=0.0.16` (pulled in for the agent prompt
  template). The existing precedent for the embedding pattern lives in
  `shiki-cli/src/Shiki/Cli/Agent/Prompt.hs`, which begins with
  `{-# LANGUAGE TemplateHaskell #-}`, imports `Data.FileEmbed`, and uses an
  `embedStringFile` splice to bake `data/prompts/assist.md` into the binary. The new
  help module uses the same Template Haskell splice for each topic file. No new cabal
  dependencies are needed.

- The package's `data-files:` stanza currently lists `data/prompts/*.md`. The new help
  topic files will be added to it as `data/help/*.md`. `data-files` makes the files
  discoverable via the auto-generated `Paths_shiki_cli` module — useful for downstream
  tooling that inspects a package's data files even when those files are also embedded
  at compile time. `file-embed`'s `embedStringFile` is what actually pulls the content
  into the binary; `data-files` is a belt-and-braces measure that mirrors EP-8.

- The cabal test suite is `test-suite shiki-cli-test` driven by
  `shiki-cli/test/Spec.hs`, which aggregates four existing tasty test groups
  (`ContextSpec`, `LaunchSpec`, `PromptSpec`, `ProviderSpec`) under one root. Adding a
  new spec is a three-line change to `Spec.hs` and a new file under
  `shiki-cli/test/Shiki/Cli/`. The test runner is `tasty` with `tasty-hunit`.

- **Term: topic.** A named guide bundled into the shiki binary. Each topic has a short
  name (one lowercase word, e.g. `services`), a one-line description shown in the
  index, and a multi-paragraph body shown when the user names the topic. Topics are
  identified by `name`, looked up case-insensitively, and there is no nesting — the
  topic list is flat. Topics are *not* `shiki --help` output for subcommands; the
  optparse-applicative-generated `--help` text already covers that.

- **Term: file-embed.** A GHC Template Haskell library that reads a file at compile
  time and produces a literal byte string in the compiled binary. The relevant function
  for this plan is `Data.FileEmbed.embedStringFile :: FilePath -> Q Exp`, which when
  spliced as `$(embedStringFile "path/to/file.md")` produces a value of any
  `IsString a => a` type — in particular `Text`. The path is resolved relative to the
  cabal package's root directory (where `shiki-cli.cabal` lives).

- **Term: ALL-CAPS section header.** The reference document at
  `/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/cli/help-topics.md` defines the topic
  file format as plain text with section titles written in all uppercase
  (`SERVICE CONFIG`, `EXAMPLES`, ...). The body of each section is indented by exactly
  two spaces. Topic files are printed verbatim — no Markdown rendering, no reflow, no
  width adaptation in this plan.

- **Term: optparse-applicative.** The Haskell command-line parsing library used
  throughout shiki. The relevant primitives for this plan are `Opt.hsubparser`
  (already used in `commandParser` for the top-level subcommands), `Opt.command`
  (declares a single subcommand entry), `Opt.info` (wraps a parser with description
  text), `Opt.progDesc` (the one-line description shown in `--help`),
  `Opt.argument Opt.str` (a positional string argument), `Opt.optional` (wraps a parser
  to allow absence), and `Opt.metavar` (sets the placeholder text in `--help` output).

- The reference pattern document is
  `/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/cli/help-topics.md`. It is the
  authoritative source for the structure used in this plan and should be re-read before
  editing. Its companion `help-width.md` describes a `--width` flag and `terminal-size`
  integration for adapting to terminal width; this plan does **not** implement that
  extension. The width-adaptation pattern can be retrofitted later by changing only the
  `showTopic` printer; the registry, parser, and topic content files are independent of
  it.


## Plan of Work

The work is broken into three milestones. Each milestone leaves shiki in a state where
`cabal build all` succeeds and the existing `cabal test all` suite still passes.

### M1 — Scaffold the help module and ship the first topic

Goal: introduce the smallest end-to-end help slice. End-of-milestone state: a new
internal module `Shiki.Cli.Help` exposes the topic ADT, parser, and handler; one topic
content file (`services`) is embedded and printed; `shiki help` and `shiki help services`
both work; `shiki help bogus` exits non-zero.

Edits, in order:

- Create `shiki-cli/data/help/services.md`. Plain text, ALL-CAPS section headers,
  2-space indentation under each section. The full content is given in the Concrete
  Steps section below.

- Create `shiki-cli/src/Shiki/Cli/Help.hs` with module exports
  `HelpTopic(..)`, `HelpCommand(..)`, `helpTopics`, `helpParser`, `runHelp`. The file
  must begin with `{-# LANGUAGE TemplateHaskell #-}` because of the `embedStringFile`
  splices. Use the existing `Shiki.Prelude` to pull in `Text`, `Generic`, `(.)`, etc.;
  see other `Shiki.Cli.*` modules for the import style. Specifically:

  ```haskell
  {-# LANGUAGE TemplateHaskell #-}

  module Shiki.Cli.Help
    ( HelpTopic (..)
    , HelpCommand (..)
    , helpTopics
    , helpParser
    , runHelp
    ) where

  import Shiki.Prelude hiding (argument)

  import "file-embed" Data.FileEmbed (embedStringFile)
  import "text" Data.Text qualified as Text
  import "text" Data.Text.IO qualified as TIO
  import "optparse-applicative" Options.Applicative
    ( Parser, argument, help, info, metavar, optional, progDesc, str )
  import "optparse-applicative" Options.Applicative qualified as Opt
  import "base" Data.List (find)
  import "base" System.Exit (exitFailure)
  import "base" System.IO (hPutStrLn, stderr)

  data HelpTopic = HelpTopic
    { name        :: !Text
    , description :: !Text
    , content     :: !Text
    }
    deriving stock (Generic, Eq, Show)

  data HelpCommand
    = ListTopics
    | ShowTopic !Text
    deriving stock (Generic, Eq, Show)

  helpTopics :: [HelpTopic]
  helpTopics =
    [ HelpTopic "services" "Service configuration: services/*.dhall" servicesContent
    ]

  servicesContent :: Text
  servicesContent = $(embedStringFile "data/help/services.md")

  helpParser :: Parser HelpCommand
  helpParser =
    showTopicParser Opt.<|> pure ListTopics
    where
      showTopicParser =
        ShowTopic
          <$> argument str
                ( metavar "TOPIC"
                    <> help ("Help topic: " <> Text.unpack topicList)
                )
      topicList = Text.intercalate ", " (map (^. #name) helpTopics)

  runHelp :: HelpCommand -> IO ()
  runHelp = \case
    ListTopics      -> listTopics
    ShowTopic topic -> showTopic topic

  listTopics :: IO ()
  listTopics = do
    TIO.putStrLn "HELP TOPICS\n"
    forM_ helpTopics $ \t ->
      TIO.putStrLn ("  " <> (t ^. #name) <> "  " <> (t ^. #description))
    TIO.putStrLn "\nUse 'shiki help <topic>' for details."

  showTopic :: Text -> IO ()
  showTopic raw =
    let lookupName = Text.toLower (Text.strip raw)
     in case find (\t -> (t ^. #name) == lookupName) helpTopics of
          Just t  -> TIO.putStr (t ^. #content)
          Nothing -> do
            hPutStrLn stderr ("Unknown topic: " <> Text.unpack raw)
            hPutStrLn stderr
              ( "Available: "
                  <> Text.unpack (Text.intercalate ", " (map (^. #name) helpTopics))
              )
            exitFailure
  ```

  Notes on the snippet:
    - `Shiki.Prelude` hides `argument` to match how `Shiki.Cli.Run` and
      `Shiki.Cli.Runs` import optparse — keep the same shadowing for consistency.
    - The `Opt.<|>` operator threads through `optparse-applicative`; alternatively
      import `(<|>)` from `Control.Applicative`. Either works.
    - `(^. #name)` uses `generic-lens` + `OverloadedLabels` — both already in shiki's
      default extension set, no new pragmas required.
    - `Text.strip` ahead of `Text.toLower` collapses leading/trailing whitespace so
      `shiki help " services "` (e.g. accidentally pasted from a doc) still works.
    - `TIO.putStr` (not `putStrLn`) so the topic file's trailing newline drives the
      final newline; this keeps the output byte-identical to the source file when the
      file ends with `\n` (which it must).

- Edit `shiki-cli/shiki-cli.cabal`:
    - Append `data/help/*.md` to the existing `data-files:` stanza so it reads:

      ```cabal
      data-files:
        data/prompts/*.md
        data/help/*.md
      ```
    - Add `Shiki.Cli.Help` to the library's `exposed-modules:` list, immediately after
      the existing `Shiki.Cli.Agent.*` entries to keep alphabetical-ish order.
    - No new `build-depends:` entries are needed; `file-embed`, `text`, and
      `optparse-applicative` are already listed.

- Edit `shiki-cli/src/Shiki/Cli.hs`:
    - Add `import Shiki.Cli.Help (HelpCommand, helpParser, runHelp)` after the
      existing `Shiki.Cli.Agent` import.
    - Extend `data Command` with a fifth constructor: `Help !HelpCommand`. Keep
      `deriving stock (Generic, Eq, Show)` unchanged.
    - Extend `runCli`'s `case opts ^. #command of` with the new arm:

      ```haskell
      Help helpOpts -> runHelp helpOpts
      ```

      `runHelp` does not need a `CliEnv` (no database, no Kubernetes) so it sits
      outside the `withDbEnv` block, like the existing `ServiceShow` arm.
    - Extend `commandParser` with a fifth `Opt.command` entry:

      ```haskell
      <> Opt.command
        "help"
        ( Opt.info
            (Help <$> helpParser)
            (Opt.progDesc "Show curated guides for shiki concepts")
        )
      ```

      Add the `<**> Opt.helper` only at the parent `parserInfo` level (already done);
      individual subcommand parsers in shiki do not attach their own `<**> helper`
      argument, so neither does `helpParser`.

Validation:

```bash
cabal build all
cabal run shiki -- --help
cabal run shiki -- help
cabal run shiki -- help services
cabal run shiki -- help bogus ; echo "exit=$?"
```

Expected behavior:

- `shiki --help` lists `help  Show curated guides for shiki concepts` in its
  `Available commands:` block.
- `shiki help` prints the topic index with one entry (`services`).
- `shiki help services` prints the full content of `data/help/services.md` verbatim.
- `shiki help bogus` prints `Unknown topic: bogus` followed by
  `Available: services` to stderr and exits with code 1.

### M2 — Author the remaining five topics

Goal: complete the topic catalog. End-of-milestone state: `shiki help` lists six
topics; each `shiki help <name>` prints content; lookup is still case-insensitive.

For each of the five new topics, do exactly two things:

1. Create the topic file under `shiki-cli/data/help/<topic>.md` with the content given
   in this plan's Concrete Steps section below.
2. Add an `embedStringFile` binding and a `helpTopics` entry in
   `shiki-cli/src/Shiki/Cli/Help.hs`. For example, for the `runs` topic:

   ```haskell
   runsContent :: Text
   runsContent = $(embedStringFile "data/help/runs.md")
   ```

   and inside `helpTopics`:

   ```haskell
   , HelpTopic "runs" "Run lifecycle and the runs table" runsContent
   ```

   Keep the list in the order shown in the Purpose section:
   `services`, `runs`, `analyzers`, `agent`, `schema`, `env`.

No other files change in M2; the parser, handler, and `Shiki.Cli` wiring are unaffected
because the registry is the single source of truth.

Validation:

```bash
cabal build all
cabal run shiki -- help
cabal run shiki -- help runs
cabal run shiki -- help analyzers
cabal run shiki -- help agent
cabal run shiki -- help schema
cabal run shiki -- help env
cabal run shiki -- help SERVICES   # case-insensitive smoke check
```

Expected: each invocation prints the named topic's content; `shiki help` lists six
entries; mixed-case lookup matches.

### M3 — Tasty specs, README, CHANGELOG

Goal: lock in the behavior with automated tests and document the feature.

Edits:

- Create `shiki-cli/test/Shiki/Cli/HelpSpec.hs` exporting `tests :: TestTree`. The spec
  must cover, at minimum:

  1. `helpTopics` has at least six entries.
  2. Every topic in `helpTopics` has a non-empty `name`, a non-empty `description`,
     and a non-empty `content`.
  3. Every topic name is unique within the registry (no duplicates).
  4. Every topic name is lowercase ASCII letters or `-` (so the case-insensitive
     lookup is meaningful and the `--help` output is readable).
  5. `Opt.execParserPure` of `helpParser` on the input `[]` parses to `ListTopics`,
     and on `["services"]` parses to `ShowTopic "services"`. Use
     `Opt.defaultPrefs` and `Opt.info helpParser idm`. This pins the parser shape
     against accidental regressions.

  Suggested skeleton:

  ```haskell
  module Shiki.Cli.HelpSpec (tests) where

  import "tasty" Test.Tasty (TestTree, testGroup)
  import "tasty-hunit" Test.Tasty.HUnit (testCase, (@?=), assertBool)

  import "text" Data.Text qualified as Text

  import "optparse-applicative" Options.Applicative qualified as Opt

  import Shiki.Cli.Help (HelpCommand (..), helpParser, helpTopics)
  import qualified Shiki.Cli.Help as Help
  import Shiki.Prelude

  tests :: TestTree
  tests =
    testGroup
      "Shiki.Cli.Help"
      [ testCase "registry has at least six topics" $
          assertBool "len >= 6" (length helpTopics >= 6)
      , testCase "every topic is well-formed" $
          mapM_ wellFormed helpTopics
      , testCase "topic names are unique" $
          let ns = map (^. #name) helpTopics
           in length ns @?= length (nub ns)
      , testCase "parser: no argument => ListTopics" $
          parsePure [] @?= Right ListTopics
      , testCase "parser: 'services' => ShowTopic" $
          parsePure ["services"] @?= Right (ShowTopic "services")
      ]
    where
      wellFormed t = do
        assertBool "name non-empty"        (not (Text.null (t ^. #name)))
        assertBool "description non-empty" (not (Text.null (t ^. #description)))
        assertBool "content non-empty"     (not (Text.null (t ^. #content)))

      parsePure args =
        Opt.execParserPure
          Opt.defaultPrefs
          (Opt.info helpParser Opt.idm)
          args
          & Opt.getParseResult
          & maybe (Left "parse failed") Right
  ```

  (`nub` from `Data.List`. `&` from `Data.Function`. Both available without explicit
  imports through `Shiki.Prelude`.)

- Edit `shiki-cli/test/Spec.hs`:
    - Import the new spec module:
      `import Shiki.Cli.HelpSpec qualified as HelpSpec`.
    - Append `HelpSpec.tests` to the group list in `main`, after `LaunchSpec.tests`.

- Edit `shiki-cli/shiki-cli.cabal`:
    - Append `Shiki.Cli.HelpSpec` to the `other-modules:` list under
      `test-suite shiki-cli-test`. No new test-suite dependencies are needed; `tasty`,
      `tasty-hunit`, `text`, and `shiki-cli` are already listed.

- Create `docs/user/help.md`:
    - A new operator-facing page mirroring the structure of the existing
      `docs/user/*.md` files. It documents `shiki help`, `shiki help <topic>`,
      case-insensitive lookup, the unknown-topic error contract, and lists the six
      initial topics by name and description using the exact strings from the
      `helpTopics` registry. End with one short example transcript matching the M1
      acceptance.

- Edit `docs/user/README.md`:
    - Add a bullet to the `## Where to start` list pointing at the new
      `./help.md` page, between the `getting-started.md` entry and the
      `commands.md` entry — the help command is itself a "where to start" entry
      point.

- Edit top-level `README.md`:
    - The `## Documentation` section currently mirrors the `docs/user/` index. Add
      a new bullet for `**[Help command](./docs/user/help.md)** — in-terminal
      curated guides for shiki concepts.` between the `getting-started.md` bullet
      and the `commands.md` bullet, so the README index stays in sync with
      `docs/user/README.md`.
    - Optionally, add `shiki help` to the `## What it does` snippet block so the
      reader sees the new subcommand alongside the others.

- Edit `CHANGELOG.md`:
    - Append one line under the existing `## [Unreleased]` / `### Added` block:

      ```text
      - feat(shiki-cli): EP-9 — `shiki help` and `shiki help <topic>` show curated
        topic guides embedded into the binary at compile time. Initial topics:
        services, runs, analyzers, agent, schema, env.
      ```

- This plan's Concrete Steps section:
    - Replace the placeholder transcripts with the verbatim output captured at M3.

Validation:

```bash
cabal build all
cabal test shiki-cli
cabal test shiki-core
```

Expected: both test suites pass; the `shiki-cli` summary now reports five test groups
(`ContextSpec`, `LaunchSpec`, `PromptSpec`, `ProviderSpec`, `Shiki.Cli.Help`) with the
new group adding at least the five test cases listed above.


## Concrete Steps

All commands are run from `/Users/shinzui/Keikaku/bokuno/shiki` inside the Nix dev shell
(`nix develop`).

### Topic file contents

The plan ships six topic content files. Each is plain text with ALL-CAPS section
headers and 2-space body indentation, exactly matching the reference pattern at
`/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/cli/help-topics.md`. Every file must
end with a trailing newline so that `TIO.putStr` produces a clean final line.

The exact contents follow. Reproduce each file verbatim.

`shiki-cli/data/help/services.md`:

```text
SHIKI SERVICES


A "service" in shiki is a Kubernetes workload that shiki can submit one-off
Jobs against. Each service is described by one Dhall configuration file
under the services/ directory at the operator's working directory:

  services/
    mls-service-v2.dhall
    other-service.dhall


SERVICE CONFIG FIELDS

  name                  Logical service name. Must match the file name
                        without the .dhall extension.

  defaultNamespace      Kubernetes namespace used when no --namespace flag
                        is given to 'shiki run'.

  detectFromDeployment  Name of the live Deployment 'shiki run' introspects
                        to pick up the current image digest, ConfigMap
                        names, Secret names, etc. at submit time.

  containerName         Which container inside that Deployment to mirror
                        (e.g. the application container next to a
                        cloud-sql-proxy sidecar).

  commandPath           Path to the binary inside the container image;
                        becomes the Job container's command[0]. Everything
                        after '--' on the 'shiki run' command line is
                        appended as ARGS.

  serviceAccount        Kubernetes ServiceAccount attached to the Job pod.

  nodeSelector          Optional pod nodeSelector map.

  initContainers        Init containers attached to every run (e.g. a
                        restartable cloud-sql-proxy).

  env                   Environment variables; each is ConfigMap, Secret,
                        or Literal-sourced.

  resources             CPU and memory requests/limits for the main
                        container.

  analyzer              Default analyzer backend for failed runs. One of:
                        Heuristic, Baikai { model = "<id>" }, None.
                        'shiki run' always uses Heuristic; 'shiki runs
                        analyze' honors this default unless --analyzer
                        overrides it.


INSPECTING A SERVICE

Use 'shiki service show <name>' to pretty-print one service config as JSON
without touching the cluster or the database:

  shiki service show mls-service-v2


ADDING A NEW SERVICE

  1. Create services/<name>.dhall.
  2. Set name = "<name>" (it must match the file name).
  3. Fill in defaultNamespace, detectFromDeployment, containerName,
     commandPath, serviceAccount, resources, env, and analyzer. The repo
     ships services/mls-service-v2.dhall as a worked example.
  4. Run 'shiki service show <name>' to verify the file parses.


Full reference: docs/user/service-config.md
See also: 'shiki help runs', 'shiki help analyzers'.
```

`shiki-cli/data/help/runs.md`:

```text
SHIKI RUNS


Every invocation of 'shiki run <service> -- ARGS' records one row in the
'runs' table of the configured PostgreSQL database. The 'runs' family of
subcommands queries that table read-only.


RUN LIFECYCLE

  1. 'shiki run' parses the service config, introspects the worker
     Deployment, and constructs a batch/v1 Job manifest.
  2. A row is inserted into 'runs' with status 'pending' and a fresh UUID,
     then flipped to 'running' as the Job is submitted to Kubernetes.
  3. Unless --no-wait was passed, shiki follows the Job to completion:
     polling its status at 5-second intervals (with a 96-hour cap),
     fetching the pod's logs on failure, persisting the last 200 lines /
     64 KiB into runs.log_tail.
  4. On terminal status, shiki finalizes the row with status ('succeeded'
     or 'failed'), exit code, duration, and (on failure) an
     error_summary derived by the Heuristic analyzer.


THE RUNS TABLE COLUMNS

  id                    UUID. Subcommands accept any unambiguous prefix.
  service_name          Logical service name from the config.
  command               argv passed to the container (text[]).
  namespace             The Kubernetes namespace the Job ran in.
  job_name              <service>-<timestamp>-<rand>, unique per run.
  image                 Image digest read from the live Deployment at
                        submit time.
  status                pending | running | succeeded | failed.
  exit_code             The container's exit code; NULL on pending /
                        running and on pre-container failures.
  started_at            UTC timestamp of insert.
  ended_at              UTC timestamp of finalize; NULL while pending /
                        running.
  duration_ms           ended_at - started_at, in milliseconds.
  log_tail              Last 200 lines / 64 KiB of the pod's logs.
  service_config        JSONB snapshot of the parsed ServiceConfig used
                        for this run.
  error                 Kubernetes-side reason (e.g. BackoffLimitExceeded).
  error_summary         Log-derived one-liner. NULL for successful runs.
  error_summary_source  Which analyzer produced error_summary
                        ('heuristic' or 'baikai:<model-id>').
  created_at            Row insert time.
  updated_at            Last update time.


QUERYING RUNS

  shiki runs list                       Newest 20 runs as a table.
  shiki runs list --service NAME        Filter by service.
  shiki runs list --limit 50            Wider window.

  shiki runs show <id>                  One row as pretty JSON.
  shiki runs logs <id>                  log_tail verbatim.
  shiki runs error <id>                 error_summary one-liner.
  shiki runs analyze <id>               Re-run an analyzer over log_tail
                                        (see 'shiki help analyzers').


ID PREFIX CONVENTIONS

Every 'runs' subcommand that takes an <id> accepts the full UUID or any
unambiguous prefix. The default table view prints the first 8 characters
of each row's UUID; that 8-character prefix is the convention. Empty
matches and ambiguous prefixes both exit non-zero.


Full reference: docs/user/getting-started.md, docs/user/commands.md
See also: 'shiki help analyzers', 'shiki help schema'.
```

`shiki-cli/data/help/analyzers.md`:

```text
SHIKI ANALYZERS


On a failed run, shiki populates two distinct columns on the runs row:

  runs.error          The Kubernetes-side reason from V1JobCondition (e.g.
                      BackoffLimitExceeded, DeadlineExceeded). Tells you
                      whether the cluster killed the Job before it had a
                      chance to finish.

  runs.error_summary  A short, log-derived one-liner describing what
                      actually went wrong inside the container. Capped at
                      512 characters. Accompanied by runs.error_summary_source,
                      which records which analyzer produced it.


ANALYZER BACKENDS

  Heuristic           Deterministic, zero-network. Recognises Python
                      tracebacks, JVM exception chains, Go panics, Rust
                      panics, and generic level-prefixed log lines. Falls
                      back to the last non-blank line.

  Baikai              LLM-derived summary via the baikai library. Requires
                      ANTHROPIC_API_KEY (for anthropic_* models) or
                      OPENAI_API_KEY (for openai_*) in the environment.
                      Model spelled as 'baikai:<model-id>', e.g.
                      'baikai:anthropic_claude_haiku_4_5'.

  None                Disable analysis. error_summary stays NULL.


WHEN ANALYZERS RUN

The inline 'shiki run' path always uses Heuristic regardless of the
service default. Interactive runs stay deterministic, zero-network, and
zero-credential.

To opt into a richer summary, use the post-hoc subcommand:

  shiki runs analyze <id>                              # service default
  shiki runs analyze <id> --analyzer=heuristic         # force Heuristic
  shiki runs analyze <id> --analyzer=baikai:anthropic_claude_haiku_4_5
  shiki runs analyze <id> --analyzer=none              # disable


ANALYZING SUCCEEDED RUNS

A successful run's error_summary is NULL by contract, even if its logs
contain ERROR or Exception strings. Those messages may have been caught
and recovered from inside the container; promoting them into error_summary
would actively mislead the operator.


Full reference: docs/user/error-analysis.md
See also: 'shiki help runs', 'shiki help env'.
```

`shiki-cli/data/help/agent.md`:

```text
SHIKI AGENT ASSIST


'shiki agent assist' opens an interactive AI session whose system prompt
embeds a live snapshot of shiki's state — the working directory, the
PostgreSQL schema, the cluster context, every services/*.dhall, and the
last twenty rows from the 'runs' table — and whose tool access is scoped
to a hard-coded allow-list.


PROVIDERS

Four providers ship out of the box. The two CLI providers spawn a local
subprocess and hand the terminal over to it. The two API providers issue
a single non-interactive call and print the assistant's text.

  claude-cli   (default)  Spawns the 'claude' CLI (Claude Code). Uses
                          whatever 'claude' is logged in as.
  codex-cli               Spawns the 'codex' CLI. Sandbox mode is set to
                          'workspace-write' with approval-on-request.
  anthropic               One-shot Anthropic Messages API call. Default
                          model: claude-sonnet-4-6.
  openai                  One-shot OpenAI Chat Completions API call.
                          Default model: gpt-4o-mini.

The CLI providers have no shiki-side model default — they pass through
whatever the local CLI uses when --model is omitted.


FLAGS

  --provider PROVIDER     One of: claude-cli, codex-cli, anthropic, openai.
  --model MODEL           Provider-specific model id (e.g.
                          claude-sonnet-4-6, gpt-4o-mini).
  --prompt PROMPT         First user-role message sent to the model.
  --service NAME          Pre-seed the prompt with one service hint.
  --run ID                Pre-seed the prompt with one run id hint.
  --debug                 Render and print the system prompt, then exit 0.


ENVIRONMENT VARIABLES

  SHIKI_AGENT_PROVIDER    Default provider when --provider is not set.
  SHIKI_AGENT_MODEL       Default model when --model is not set.
  ANTHROPIC_API_KEY       Required for --provider anthropic.
  OPENAI_API_KEY          Required for --provider openai.

CLI flag > env var > hard-coded default (claude-cli, no model).


ALLOWED TOOLS

The agent's subprocess access is scoped to:

  Bash(shiki *)          All shiki subcommands.
  Bash(kubectl get *)    Read-only kubectl introspection.
  Bash(kubectl logs *)   Pod log fetching.
  Bash(pwd)              Working-directory checks.
  Bash(ls *)             Directory listing.
  Bash(cat *)            File reads.
  Read, Glob, Grep       Claude Code's built-in read primitives.

There is no escape hatch; the allow-list is hard-coded.


Full reference: docs/user/agent-assist.md
See also: 'shiki help analyzers', 'shiki help env'.
```

`shiki-cli/data/help/schema.md`:

```text
SHIKI POSTGRES SCHEMA


shiki installs its tables into a dedicated PostgreSQL schema (default
name: 'shiki') so they do not pollute 'public'.


TABLES

  shiki.runs               One row per 'shiki run' invocation. See
                           'shiki help runs' for columns.

  shiki.schema_migrations  Tracks applied migrations. Managed by
                           hasql-migration; do not edit by hand.


OVERRIDING THE SCHEMA NAME

Two ways, in priority order:

  shiki --db-schema=other_name <subcommand>     # CLI flag (highest)
  SHIKI_DB_SCHEMA=other_name shiki <subcommand> # env var


VALIDATION

Schema names must match the regex [A-Za-z_][A-Za-z0-9_]* and fit within
PostgreSQL's 63-byte identifier limit. Invalid names exit with:

  shiki: invalid schema name: <name>

before any database work happens.


MIGRATING FROM 'public'

If an older shiki checkout wrote into 'public', either drop the dev
database and let shiki re-create the schema, or move the tables in psql:

  CREATE SCHEMA IF NOT EXISTS shiki;
  ALTER TABLE public.runs              SET SCHEMA shiki;
  ALTER TABLE public.schema_migrations SET SCHEMA shiki;


Full reference: docs/user/schema.md
See also: 'shiki help env', 'shiki help runs'.
```

`shiki-cli/data/help/env.md`:

```text
SHIKI ENVIRONMENT VARIABLES


CLI flags always win over environment variables. When no flag is set,
shiki reads the listed variable; if it is unset or empty, the hard-coded
default applies.


DATABASE

  SHIKI_DATABASE_URL      Postgres connection string. Read by every
                          subcommand that touches the database (run,
                          runs, agent). Falls back to:

  PG_CONNECTION_STRING    Compatibility alias for SHIKI_DATABASE_URL.

  SHIKI_DB_SCHEMA         Postgres schema name. Default: 'shiki'.
                          Override per-invocation with --db-schema=NAME.


AGENT ASSIST

  SHIKI_AGENT_PROVIDER    Default agent provider. One of:
                          claude-cli, codex-cli, anthropic, openai.

  SHIKI_AGENT_MODEL       Default model name. Provider-specific.

  ANTHROPIC_API_KEY       Required for 'shiki agent assist --provider
                          anthropic' and for 'shiki runs analyze
                          --analyzer=baikai:anthropic_*'.

  OPENAI_API_KEY          Required for 'shiki agent assist --provider
                          openai' and for 'shiki runs analyze
                          --analyzer=baikai:openai_*'.


KUBERNETES

shiki uses the standard kube client search path:

  KUBECONFIG              Path(s) to kubeconfig file(s). When unset,
                          shiki reads ~/.kube/config.


Full reference: docs/user/commands.md (environment variable summary)
See also: 'shiki help schema', 'shiki help agent'.
```

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

### Manual smoke after M1

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
  help                     Show curated guides for shiki concepts
```

```bash
cabal run shiki -- help
```

Expected:

```text
HELP TOPICS

  services  Service configuration: services/*.dhall

Use 'shiki help <topic>' for details.
```

```bash
cabal run shiki -- help services
```

Expected: the full content of `shiki-cli/data/help/services.md` is printed verbatim.

```bash
cabal run shiki -- help bogus ; echo "exit=$?"
```

Expected:

```text
Unknown topic: bogus
Available: services
exit=1
```

### Manual smoke after M2

```bash
cabal run shiki -- help
```

Expected (six topics, in registry order):

```text
HELP TOPICS

  services   Service configuration: services/*.dhall
  runs       Run lifecycle and the runs table
  analyzers  Failure analysis backends
  agent      shiki agent assist
  schema     Postgres schema configuration
  env        Environment variables

Use 'shiki help <topic>' for details.
```

(The exact column padding will be whatever Haskell's two-space separator produces — the
literal strings above are illustrative; the test in M3 does not assert exact spacing.)

```bash
cabal run shiki -- help SERVICES
```

Expected: prints the `services` topic verbatim — the case-insensitive lookup is what
makes this work.

### M3 smoke transcripts

(To be captured during M3. Paste the verbatim output of `shiki help` and
`shiki help services` here at the end of the milestone, plus the `cabal test shiki-cli`
final line.)


## Validation and Acceptance

The change is accepted when:

1. `cabal build all` succeeds from a clean checkout entered through `nix develop`.

2. `cabal test shiki-cli` reports all tests passing, including the new
   `Shiki.Cli.Help` test group with at least the five cases described in M3.

3. `cabal test shiki-core` still passes (this plan does not touch `shiki-core`; any
   regression there is a bug introduced by this plan and must be repaired).

4. `shiki --help` lists the new `help` line in its `Available commands:` block, with
   the description `Show curated guides for shiki concepts`.

5. `shiki help` prints a topic index that lists exactly the six topics
   `services`, `runs`, `analyzers`, `agent`, `schema`, `env`, each with the
   description shown in M2's smoke transcript, and ends with the line
   `Use 'shiki help <topic>' for details.`.

6. For each of the six topics, `shiki help <name>` prints content that:
    - Begins with an ALL-CAPS section header that names the topic.
    - Contains at least one `See also:` line referencing another topic (verifying that
      the cross-references in the topic files have not drifted).

7. `shiki help SERVICES` (uppercase) and `shiki help "  services  "` (with whitespace)
   both print the same content as `shiki help services`.

8. `shiki help bogus` prints `Unknown topic: bogus` followed by an `Available:` list to
   stderr, and exits with code 1. `shiki help` with no argument exits 0.

9. The new topic files exist as plain UTF-8 text under `shiki-cli/data/help/`, end with
   a single trailing newline, and the embedded content shown by `shiki help <name>` is
   byte-identical to the file on disk (verified by `diff <(shiki help services)
   shiki-cli/data/help/services.md`).

The behavior in items 4–9 must be reproducible from the transcripts pasted into this
plan's Concrete Steps section during M3.


## Idempotence and Recovery

Every step in this plan is safe to repeat:

- All milestones are additive at the cabal package level. M1 adds a module and a
  topic file; M2 adds five more topic files and one line each in `Help.hs`; M3 adds a
  test module and updates docs. Reverting any milestone is a `git revert` of its
  commits.

- The new code does not touch the database, the Kubernetes client, or any subprocess.
  `shiki help` and `shiki help <topic>` are pure read-only printers of compile-time
  embedded data. There is no failure mode that requires recovery beyond "fix the typo
  and rebuild".

- `file-embed`'s `embedStringFile` runs at compile time, so editing a `data/help/*.md`
  file without rebuilding the binary will not change the output of `shiki help`. The
  reference document at `/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/cli/help-topics.md`
  warns explicitly about this under "Build caveat":

  > Cabal does not track embedded files as dependencies. If you edit a .md file
  > without touching the .hs file, Cabal may skip recompilation. Force it with:
  > `touch src/Shiki/Cli/Help.hs && cabal build`.

  Apply the same recipe for shiki. The test in M3 will catch the failure mode in CI
  because the test reads `helpTopics` after re-build.

- `cabal build all` after a partial milestone may fail if a module is added to
  `exposed-modules:` but its source file has not been written yet, or if a topic file
  has been deleted but its `embedStringFile` binding remains. The recovery is to
  either add the missing file or revert the `.cabal` edit. No persistent state changes
  hands.

- The `--width N` flag and the FZF picker described in
  `/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/cli/help-width.md` and the lower
  half of `help-topics.md` are explicitly out of scope for this plan. They can be
  retrofitted later by:
    - Adding `terminal-size` to `shiki-cli.cabal`'s `build-depends:`.
    - Threading a `Maybe Int` width through `HelpCommand` and `showTopic`.
    - Replacing the bare `TIO.putStr (t ^. #content)` with a width-aware wrapper.
  None of those changes touch the topic content files or the registry shape, so this
  plan's output remains the foundation.


## Interfaces and Dependencies

The libraries pulled in by this plan, and why:

- `file-embed` (Hackage, already a direct dependency of `shiki-cli` via EP-8): provides
  `Data.FileEmbed.embedStringFile :: FilePath -> Q Exp`, which when spliced as
  `$(embedStringFile "path/to/file.md")` produces a value of any `IsString a => a` type
  — here `Text`. The path is resolved relative to the cabal package's root directory
  (`shiki-cli/`). Used in `Shiki.Cli.Help` to bake each topic file into the binary.

- `optparse-applicative` (Hackage, already a direct dependency): provides the
  `Parser`, `argument`, `hsubparser`, `command`, `info`, `progDesc`, `metavar`, and
  `optional` primitives the help parser is built from.

- `text` (Hackage, already a direct dependency): `Data.Text` and `Data.Text.IO` for
  the case-insensitive lookup and verbatim print.

- `base` (transitive): `Data.List.find`, `System.Exit.exitFailure`,
  `System.IO.hPutStrLn`, `System.IO.stderr`.

- `tasty` and `tasty-hunit` (Hackage, already test-suite dependencies): the new
  `HelpSpec` test group plugs into the existing aggregator in
  `shiki-cli/test/Spec.hs`.

No new cabal dependencies are introduced by this plan.

Function and module surface at the end of each milestone (names are stable public
exports unless marked private):

- End of M1:
    - `Shiki.Cli.Help` exports `HelpTopic(..)`, `HelpCommand(..)`, `helpTopics`,
      `helpParser`, `runHelp`. `helpTopics` contains exactly one entry (`services`).
    - `Shiki.Cli.Command` (the local ADT in `Shiki.Cli`) gains a `Help !HelpCommand`
      constructor.
    - `Shiki.Cli.commandParser` registers the `help` subcommand entry.
    - `Shiki.Cli.runCli` routes `Help helpOpts -> runHelp helpOpts`.
    - File on disk: `shiki-cli/data/help/services.md`.

- End of M2:
    - `Shiki.Cli.Help.helpTopics` contains six entries:
      `services`, `runs`, `analyzers`, `agent`, `schema`, `env`.
    - Files on disk: `shiki-cli/data/help/{services,runs,analyzers,agent,schema,env}.md`.
    - No other module changes.

- End of M3:
    - `Shiki.Cli.HelpSpec` exports `tests :: TestTree` covering at least the five
      cases listed in M3.
    - `shiki-cli/test/Spec.hs` aggregates `HelpSpec.tests` into the root group.
    - `docs/user/help.md` exists, documenting the help command in the operator-guide
      style of its sibling pages.
    - `docs/user/README.md` and the top-level `README.md`'s `## Documentation` list
      both gain a bullet linking to `docs/user/help.md`.
    - `CHANGELOG.md` gains the EP-9 line under `## [Unreleased]` / `### Added`.

Inter-module dependencies introduced by this plan (pointing parent → child):

```text
Shiki.Cli  ─►  Shiki.Cli.Help
                  │
                  ▼
              file-embed (Data.FileEmbed.embedStringFile)
              optparse-applicative (Parser, hsubparser, ...)
              text (Data.Text, Data.Text.IO)
```

No edges point into `shiki-core`; the help module is a pure CLI-side feature.


## Revision History

- **2026-05-28 (revision 1).** Reconciled the plan with the operator-facing user
  guides under `docs/user/` (which were authored after the plan and are now the
  canonical reference for every concept the help topics summarize).
  - Purpose section: rewrote the "two options today" paragraph to acknowledge
    `docs/user/` as the third existing alternative the help command competes with.
  - Decision Log: added a "canonical source" decision establishing the 1:1 map
    between each help topic and one `docs/user/<page>.md` file, with the operating
    rule that the user guide is authoritative when the two disagree.
  - Surprises & Discoveries: recorded the factual errors the canonical-source pass
    revealed in the first-draft topic content (wrong `ServiceConfig` field names,
    wrong `runs.status` casing, wrong finalize-timestamp column name, missing
    columns, wrong id-prefix length, missing API-provider default models, missing
    Codex sandbox note).
  - Concrete Steps: corrected the `services.md`, `runs.md`, and `agent.md` topic
    bodies; added a `Full reference:` line to every topic pointing at its
    `docs/user/` page.
  - M3 (Plan of Work, Progress checklist, Interfaces and Dependencies "End of M3"):
    replaced the "add `## Help command` section to `README.md`" step with a triple
    edit — create `docs/user/help.md`, add a bullet in `docs/user/README.md`, and
    add a bullet in the top-level `README.md`'s `## Documentation` list — to match
    the docs reorganization that has happened since the plan was authored.
