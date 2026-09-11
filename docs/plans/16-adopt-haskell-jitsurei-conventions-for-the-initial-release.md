---
id: 16
slug: adopt-haskell-jitsurei-conventions-for-the-initial-release
title: "Adopt haskell-jitsurei conventions for the initial release"
kind: exec-plan
created_at: 2026-09-11T18:36:40Z
provenance:
  created_by:
    model: "claude-opus-5[1m]"
    harness: "claude-code"
    at: 2026-09-11T18:36:40Z
  revisions:
    - model: "claude-opus-5[1m]"
      harness: "claude-code"
      at: 2026-09-11T18:48:44Z
      mode: "implement"
      note: "Implementing milestones 1-7"
---

# Adopt haskell-jitsurei conventions for the initial release

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

shiki is about to have its first tagged release (`shiki-cli` and `shiki-core`, version
`0.1.0.0`). The author keeps a catalog of prescriptive Haskell conventions, the
*haskell-jitsurei* pattern catalog (Mori project `mori://shinzui/haskell-jitsurei`). shiki
followed that catalog when it started in May 2026. The catalog has changed since, and some
of its CLI patterns were never adopted. This plan brings shiki into line with every
catalog pattern that applies to a Kubernetes operations CLI. It does this before the
release so the first published source already follows the conventions, and later work
does not need a sweeping refactor.

After this plan, an operator using the released binary gets three new things:

1. `shiki completions bash|zsh|fish` prints a shell completion script. Once installed,
   pressing Tab after `shiki ru` offers `run` and `runs`, and Tab after `shiki runs `
   offers `list show logs error analyze`. The same works for every flag.
2. `shiki help <topic>` re-flows topic prose to the terminal width, capped at 140 columns,
   and accepts `--width N` to set it explicitly. When the output is piped
   (`shiki help runs | less`, `> file`), the bytes are the same as the embedded source
   file, so scripts see stable output.
3. `shiki --help` and `shiki agent assist --help` list their flags under labeled
   sections (`Environment`, `Provider`, `Session context`) instead of one flat list.
   Running bare `shiki`, or `shiki runs` with no subcommand, prints the help page
   instead of a terse `Missing: COMMAND` error.

A contributor also gets a codebase that passes the catalog's "Adopt Haskell project
conventions" checklist: one shared `common` Cabal stanza, package-qualified imports
confined to `Shiki.Prelude`, generic-lens `#label` support imported per module rather
than leaked from the prelude, and unprefixed, lens-accessed record fields everywhere,
including the two modules that still use prefixed fields and selector functions today.

To see it working, build and run the commands in Validation and Acceptance. The key
checks are `cabal test all` passing, the conformance greps returning nothing, the Bash
completion demo printing `run` and `runs`, and `nix build .#shiki` producing a binary
that does all of the above.


## Progress

Milestone 1 — Cabal baseline and package-import hygiene

- [x] (2026-09-11 19:05Z) Pre-format, in a separate `style:` commit, the 64 Haskell files the rewrite touches, so the refactor diff stays readable (see Decision Log).
- [x] (2026-09-11 19:10Z) Rename the `common common-options` stanza to `common common` in `shiki-core/shiki-core.cabal` and `shiki-cli/shiki-cli.cabal` and update every `import:` line.
- [x] (2026-09-11 19:10Z) Remove `PackageImports` from both `default-extensions` lists; add `{-# LANGUAGE PackageImports #-}` to `shiki-core/src/Shiki/Prelude.hs`.
- [x] (2026-09-11 19:10Z) Strip the package qualifier from every import outside `shiki-core/src/Shiki/Prelude.hs` (374 lines across src, test, app, and example).
- [x] (2026-09-11 19:10Z) Tighten `base` to `>=4.21 && <5`, add `tested-with: GHC ==9.12.4` (cabal-gild writes it as `ghc ==9.12.4`), and bound `generic-lens` as `>=2.2 && <2.4`.
- [x] (2026-09-11 19:15Z) `cabal build all` and `cabal test all` pass (33 and 42 tests, as at baseline); conformance greps for M1 return nothing; commit.

Milestone 2 — Per-module generic-lens labels

- [x] (2026-09-11 19:25Z) Remove `import "generic-lens" Data.Generics.Labels ()` from `Shiki.Prelude` and update its Haddock comment.
- [x] (2026-09-11 19:25Z) Add `import Data.Generics.Labels ()` to every module that uses `#label` syntax (the same 25 files listed in Context and Orientation).
- [x] (2026-09-11 19:25Z) Add `generic-lens` to the `build-depends` of the `shiki-core` test suite and the `shiki-run-once` example executable.
- [x] (2026-09-11 19:30Z) `cabal build all` and `cabal test all` pass (33 and 42 tests); the missing-import check prints nothing; commit.

Milestone 3 — Record-shape conformance

- [x] (2026-09-11 19:40Z) Unprefix and lens-access the records in `shiki-cli/src/Shiki/Cli/Fzf.hs` (`FzfConfig`, `FzfOpts`, `Candidate`) and update `Fzf/Selector/Run.hs`, `Fzf/Selector/Service.hs`, and `test/Shiki/Cli/Fzf/Selector/RunSpec.hs`.
- [x] (2026-09-11 19:50Z) Unprefix and lens-access the records in `shiki-core/src/Shiki/K8s/ExecCredential.hs` and update `shiki-core/src/Shiki/K8s/Client.hs` and `shiki-core/test/Shiki/K8s/ExecCredentialSpec.hs`.
- [x] (2026-09-11 19:40Z) Replace selector-function access in `shiki-cli/test/Shiki/Cli/Agent/ContextSpec.hs` with `^. #label`.
- [x] (2026-09-11 19:55Z) `cabal build all` and `cabal test all` pass (33 and 42 tests); a clean rebuild reports 11 warnings, all from the baseline list (one fewer, because `ExecCredentialSpec` now uses its `Shiki.Prelude` import); the prefixed-field grep prints nothing; commit.

Milestone 4 — Terminal-aware help width

- [ ] Add `terminal-size` to `shiki-cli`; extend `HelpCommand` with a `--width` option; add `resolveWidth`, `renderTopic`, and `rewrap` to `Shiki.Cli.Help`.
- [ ] Extend `shiki-cli/test/Shiki/Cli/HelpSpec.hs` with parser and wrap tests.
- [ ] Update `docs/user/help.md`, `docs/user/commands.md` (if it lists help flags), and `CHANGELOG.md`.
- [ ] Piped output is byte-identical to the source file; `--width 40` keeps every prose line at or under 40 columns; commit.

Milestone 5 — Shell completions

- [ ] Add `shiki-cli/src/Shiki/Cli/Completions.hs` with Bash, Zsh, and Fish generators and a `completions` subparser; wire `Completions` into `Shiki.Cli`.
- [ ] Add `shiki-cli/test/Shiki/Cli/ParserSpec.hs` with a completion-protocol test and generator smoke tests.
- [ ] Document `shiki completions` in `docs/user/commands.md`, `docs/user/getting-started.md`, `README.md`, and `CHANGELOG.md`.
- [ ] The Bash completion demo prints `run` and `runs`; `bash -n` and `zsh -n` accept the scripts; commit.

Milestone 6 — Option groups and help-on-empty

- [ ] Raise `optparse-applicative` to `>=0.19 && <0.20` in the `shiki-cli` library and test suite.
- [ ] Group the global flags under `Environment`, and the `agent assist` flags under `Provider` and `Session context`, with `parserOptionGroup`.
- [ ] Switch `runCli` to `customExecParser cliPrefs` where `cliPrefs = prefs showHelpOnEmpty`, exported for tests.
- [ ] Extend `ParserSpec` with help-rendering tests; update docs; commit.

Milestone 7 — Release conformance audit, ADR, and Nix build

- [ ] Clear the 12 pre-existing GHC warnings (see Surprises & Discoveries) so a clean rebuild is warning-free.
- [ ] Run the full conformance audit and record the transcript in this plan.
- [ ] `nix build .#shiki` succeeds; exercise `--version`, `completions`, `help --width` on `./result/bin/shiki`.
- [ ] Create `docs/adr/1-follow-haskell-jitsurei-conventions.md`.
- [ ] Fill in Outcomes & Retrospective; commit.


## Surprises & Discoveries

- The catalog revised its core guidance on 2026-07-24, after shiki's EP-1 adopted it on
  2026-05-26. The earlier version put `PackageImports` in the shared default extensions
  and imported `Data.Generics.Labels ()` inside the prelude. The current version confines
  `PackageImports` to the prelude module and requires the labels import per module.
  That drift explains most of the core non-conformance found during research, and why
  EP-1's Decision Log (`docs/plans/1-service-configuration-model-and-dhall-loader.md`)
  records the old guidance as authoritative. Evidence from the current tree:

  ```text
  $ git grep -n 'import "' -- '*.hs' | grep -v Prelude.hs | wc -l
  374
  $ git grep -n 'Data.Generics.Labels' -- '*.hs'
  shiki-core/src/Shiki/Prelude.hs:39:import "generic-lens" Data.Generics.Labels ()
  ```

- The Nix build does not use the versions `cabal` resolves. The package set built by
  `flake.module.nix` (nixpkgs `haskell.packages.ghc9124` plus the shared haskell-nix
  extension plus `nix/haskell-overlay.nix`) provides `optparse-applicative 0.19.0.0`,
  `terminal-size 0.3.4`, `lens 5.3.6`, and `generic-lens 2.2.2.0`. `cabal` resolves
  `generic-lens 2.3.0.0`. `nix/haskell-overlay.nix` applies `doJailbreak` to both shiki
  packages, so Nix ignores the `.cabal` bounds entirely. A bound the Nix build violates
  would therefore not fail, but it would misstate what the release is built against.
  Evidence (evaluated during planning):

  ```text
  optparse=0.19.0.0 terminal-size=0.3.4 generic-lens=2.2.2.0 lens=5.3.6
  ```

- The repository's pre-commit hook runs `treefmt --fail-on-change` (fourmolu for Haskell,
  configured by `fourmolu.yaml`; cabal-gild for `.cabal` files) on staged files. A commit
  that touches unformatted files is rejected once while the hook rewrites them. This plan
  touches most Haskell files, so expect the rejection. Re-stage and commit again (see
  Idempotence and Recovery).

- (Implementation, M1) The hook formats each staged file in full, and 36 of the 64 files
  the qualifier rewrite touches were not fourmolu-clean. Formatting them together with
  the rewrite produced a 1,646-line diff, most of it layout. Running the hook's
  `treefmt` binary on the original files first gave a separate formatting-only commit
  (36 files, about 1,250 lines), and the re-applied rewrite then needed no reformatting:

  ```text
  $ git diff --name-only | xargs <hook treefmt> --no-cache
  formatted 66 files (0 changed) in 317ms
  ```

- (Implementation, M1) The build was not warning-free at the start of this plan. A clean
  rebuild of both packages reports 12 pre-existing GHC warnings, unrelated to any change
  here: six `-Wname-shadowing` in `shiki-core/src/Shiki/Analysis/Heuristic.hs` (locals
  `ix` and `chosen` shadow lens names re-exported by `Shiki.Prelude`), four
  `-Wunused-imports` (`Shiki.Prelude` in `ExecCredentialSpec.hs` and `TestPg.hs`,
  `Data.List (foldl')` in `Shiki/Cli/Agent/Prompt.hs`, `assertEqual` in `PromptSpec.hs`),
  and two `-Wdeprecations` for tasty's `sequentialTestGroup` in `ContextSpec.hs` and
  `ProviderSpec.hs`. Validation item 1 demands a warning-free build, so Milestone 7 now
  clears them.

- (Implementation, M1) `cabal-gild` normalizes `tested-with: GHC ==9.12.4` to
  `tested-with: ghc ==9.12.4`. Cabal treats compiler names case-insensitively, so this
  is only cosmetic, and the audit greps should match either case.

- (Implementation, M1) `git grep -n PackageImports` without a pathspec also matches the
  historical plans under `docs/`, which describe the old convention. The conformance
  check is scoped to code: `git grep -n PackageImports -- '*.hs' '*.cabal'`.

- (Implementation, M2) The plan asks the prelude's Haddock to tell readers to add
  `import Data.Generics.Labels ()` themselves, but its own check,
  `git grep -n 'Data.Generics.Labels' -- shiki-core/src/Shiki/Prelude.hs`, then matches
  that comment. The check is now anchored to import lines:
  `git grep -n '^import.*Data.Generics.Labels' -- shiki-core/src/Shiki/Prelude.hs`. For
  the same reason, the Haddock says "overloaded labels" rather than the literal
  `#label`, which the label-usage loop would otherwise count as a use.

- (Implementation, M2) The label-usage loop is a heuristic. It matches any
  `#identifier` text outside CPP directives, including inside string literals. Milestone
  5's Zsh script contains `"#compdef shiki"`, and the loop would demand a labels import
  in `Completions.hs` for it. Such a hit is a false positive, to be recognized and
  ignored rather than silenced with an unneeded import.

- (Implementation, M3) The two `shiki-cli` test modules that gained `^. #label` reads,
  `RunSpec.hs` and `ContextSpec.hs`, do not import `Shiki.Prelude`, so `^.` was not in
  scope as the plan assumed. They now import `Shiki.Prelude ((^.))`. With the selectors
  gone, their `Candidate (..)`, `AgentContext (..)`, and `ServiceSummary (..)` imports
  became redundant and were dropped, as was `ResolvedContext (..)` in
  `shiki-core/src/Shiki/K8s/Client.hs` and `ExecCredentialSpec.hs`. Generic-lens labels
  need only the `Generic` instance, not the field names in scope.
  `shiki-cli/src/Shiki/Cli/Fzf/Selector/Service.hs` builds a `Candidate` with record
  syntax but reads no labels, so it needs no labels import.

- (Implementation, M3) Renaming fields to plain words made several locals in
  `ExecCredential.hs` shadow the new top-level field selectors (`apiVersion`, `command`,
  `args` in the `FromJSON ExecAuth` parser; `name` and `user` in the `NamedUser` parser;
  `cluster`, `user`, and `status` in the resolver and runner). They were renamed
  (`apiVer`, `cmd`, `argv`, `userName`, `userEntry`, `namedCluster`, `namedUser`,
  `clusterRef`, `credStatus`) before the first build, so no `-Wname-shadowing` warning
  appeared. GHC did not warn about unused selectors on the unexported records
  (`NamedContext`, `ExecCredentialResponse`, and others) now read only through labels.


## Decision Log

- Decision: Scope is "every haskell-jitsurei pattern that applies to shiki", decided
  pattern by pattern during research. In scope: Haskell Core Standards
  (`mori://shinzui/haskell-jitsurei/docs/core-standards`), Custom Prelude
  (`mori://shinzui/haskell-jitsurei/docs/core-custom-prelude`), Record Patterns
  (`mori://shinzui/haskell-jitsurei/docs/core-record-patterns`), Terminal-Aware Help
  Width (`mori://shinzui/haskell-jitsurei/docs/cli-help-width`), Shell Completion
  Generation (`mori://shinzui/haskell-jitsurei/docs/cli-shell-completions`), and Option
  Groups (`mori://shinzui/haskell-jitsurei/docs/cli-option-groups`).
  Rationale: The user asked to adopt the catalog's best practices "when applicable" before
  the initial release. These are the patterns whose preconditions shiki meets and that
  shiki does not yet satisfy.
  Date: 2026-09-11

- Decision: Several patterns are already satisfied, and this plan only re-verifies them
  in Milestone 7. They are help topics (`mori://shinzui/haskell-jitsurei/docs/cli-help-topics`,
  done by `docs/plans/9-shiki-help-command-with-topic-guides.md`), fzf integration
  (`mori://shinzui/haskell-jitsurei/docs/cli-fzf-integration`, done by
  `docs/plans/10-integrate-fzf-for-interactive-id-selection.md`), git-SHA version output
  (`mori://shinzui/haskell-jitsurei/docs/cli-version-git-sha`, done by
  `docs/plans/15-add-shiki-version-output-with-git-sha.md`), agent assist commands
  (`mori://shinzui/haskell-jitsurei/docs/cli-agent-assist-commands`, done by
  `docs/plans/8-agent-assist-subcommand-backed-by-baikai.md`), multiline strings, and
  postpositive qualified imports.
  Rationale: Research confirmed each against the current tree. For example,
  `shiki-cli/src/Shiki/Cli/Fzf.hs` uses `--with-nth=2..`, `-1`, `delegate_ctlc = True`,
  exit 130 for cancel, and the `/dev/tty` probe. `shiki agent assist` has `--debug`, a
  hard-coded tool allowlist, a file-embedded prompt template, and exit-code propagation.
  `git grep -nE '^import qualified ' -- '*.hs'` returns nothing.
  Date: 2026-09-11

- Decision: Several patterns are out of scope because shiki does not meet their
  preconditions:
  - The eight Servant API patterns (routes, RFC 9457 problem details, OpenAPI, Hurl,
    OpenTelemetry, request logging, health endpoints, Relay pagination): shiki has no
    HTTP server.
  - Stdin integration: shiki has no free-text positional input. The `run` passthrough
    arguments must come from argv, and the interactive `agent assist` providers need the
    terminal on stdin.
  - Copy to clipboard: no command's stdout is a single short value.
  - Command aliases (YAML and KDL variants): shiki has no user-scope config file.
    Inventing one for aliases right before the release would add surface area and a
    second config format.
  - Hierarchical Dhall config: `legacy` in the catalog, and shiki's `shiki.dhall` is a
    single project scope rather than the layered pattern. Its successor, the settei
    standard (`mori://shinzui/keiro-runtime-patterns/docs/config-settei-cli-standard`),
    targets keiro fleet applications and lives outside this catalog.
  - Per-command agent configuration: shiki has one agent-launching command. That
    pattern's own "When NOT to use" covers this case.
  - Claude CLI subprocess gotchas: shiki never runs `claude -p` with `--add-dir`. baikai
    builds the argv and shiki passes `extraDirs = []`.
  - Skill and agent registry: shiki does not distribute end-user skills.
  - The governance review policy and the tech radar: these govern the catalog itself,
    and shiki uses neither interval types nor crypton directly.
  Rationale: Adopting a pattern whose preconditions are absent adds code without the
  benefit the pattern exists for. Each item can be revisited post-release if shiki grows
  the matching surface.
  Date: 2026-09-11

- Decision: Supersede EP-1's choices to enable `PackageImports` project-wide and to
  import `Data.Generics.Labels ()` from `Shiki.Prelude`. Follow the current catalog:
  `PackageImports` only as a pragma in `shiki-core/src/Shiki/Prelude.hs`, and the labels
  import in each module that uses `#label`.
  Rationale: The catalog changed these rules on 2026-07-24 (see Surprises & Discoveries).
  The labels import in the prelude leaks an orphan `IsLabel` instance into every module,
  which breaks libraries that define their own `IsLabel` instances. Package-qualified
  imports outside the prelude add noise without disambiguating anything.
  Date: 2026-09-11

- Decision: Rename the Cabal stanza `common common-options` to `common common`.
  Rationale: EP-1 kept the old name to avoid churn. The catalog's checklist now names
  `common common` literally, and this plan already edits every stanza's `import:` line,
  so renaming costs nothing extra.
  Date: 2026-09-11

- Decision: Bound `generic-lens` as `>=2.2 && <2.4` rather than the catalog's `^>=2.3`.
  Rationale: The released Nix build uses generic-lens 2.2.2.0 and cabal uses 2.3.0.0 (see
  Surprises & Discoveries). The bound should admit both versions that are actually built
  and tested. shiki only uses the `#label` lens API, which both versions provide.
  Date: 2026-09-11

- Decision: Implement completions as a `shiki completions <shell>` subcommand whose
  scripts call `shiki` by name. Do not use optparse-applicative's built-in hidden
  `--bash-completion-script PATH` options.
  Rationale: The built-in scripts embed the absolute binary path given as their argument.
  For a Nix-installed binary, that is a `/nix/store/...` path that changes with every
  release, so installed completions silently break on upgrade. The subcommand form is
  also discoverable in `shiki --help`, and it is the catalog's pattern.
  Date: 2026-09-11

- Decision: Group options with `parserOptionGroup`, but do not group subcommands with
  `commandGroup`.
  Rationale: shiki has seven top-level commands, which a flat list shows readably.
  `commandGroup` requires splitting the single `hsubparser` into several alternatives,
  and optparse-applicative then renders a `(COMMAND | COMMAND | COMMAND)` usage line.
  Date: 2026-09-11

- Decision: Do not add the optional fzf picker to bare `shiki help`.
  Rationale: The help-topics pattern recommends the picker "when the topic list grows
  large". shiki has six topics, and the plain index fits on one screen.
  Date: 2026-09-11

- Decision: Adopt `showHelpOnEmpty` via `customExecParser (prefs showHelpOnEmpty)`.
  Rationale: The catalog's CLI examples parse with `prefs showHelpOnEmpty`, and it turns
  `shiki runs` with no subcommand into the help page instead of `Missing: COMMAND`. It
  keeps the completion protocol, because `customExecParser` handles
  `--bash-completion-*` exactly as `execParser` does.
  Date: 2026-09-11

- Decision: Record-update syntax remains allowed on third-party types that have no
  `Generic` instance or whose library documents update-a-default construction, such as
  `(proc cmd args) { env = … }` from `System.Process` and baikai's
  `_Model { … }` / `_Context { … }`. The "prefer lens over record update" rule applies to
  shiki's own records.
  Rationale: `#label` lenses need `Generic`, which `CreateProcess` lacks. baikai's
  defaults are designed to be overridden with record syntax.
  Date: 2026-09-11

- Decision: Rename `ExecAuth`'s environment field to `environment`, not `env`.
  Rationale: `shiki-core/src/Shiki/K8s/ExecCredential.hs` imports the `env` field of
  `System.Process.CreateProcess` and uses it in a record update. A second `env` field in
  the same module would make that update ambiguous.
  Date: 2026-09-11

- Decision: Record the adoption as the repository's first ADR, a plain Markdown file
  `docs/adr/1-follow-haskell-jitsurei-conventions.md` without OKF frontmatter.
  Rationale: No `docs/adr/` exists, and `mori.dhall` declares no OKF bundle for it. The
  shared ADR workflow says not to invent OKF identity as an incidental plan edit. The
  convention choice and its exceptions are durable project context that should outlive
  this plan.
  Date: 2026-09-11

- Decision: Land formatting separately. Before each large mechanical rewrite, run the
  pre-commit hook's `treefmt` on the files the rewrite will touch, while they still hold
  their original content, and commit that as `style: …`. Then apply the rewrite.
  Rationale: The hook formats whole files. Without the split, Milestone 1's diff was
  about 1,650 lines, of which only about 440 were the substantive import and cabal
  changes. The split keeps each commit reviewable and still honors the plan's rule not
  to run a tree-wide format. Only files this plan touches are formatted.
  Date: 2026-09-11

- Decision: Clear the 12 pre-existing GHC warnings in Milestone 7.
  Rationale: Validation item 1 requires no warnings from shiki modules, and the release
  should build cleanly under its own `-Wall` settings. The fixes are local: rename locals
  that shadow lens names, drop unused imports, and replace the deprecated
  `sequentialTestGroup` with tasty's `dependentTestGroup`.
  Date: 2026-09-11


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

### What shiki is and how the repository is laid out

shiki is a command-line tool that submits one-off Kubernetes Jobs for a configured
service and records each run in PostgreSQL. The repository root is
`/Users/shinzui/Keikaku/bokuno/shiki`. It is a Cabal project (`cabal.project`) with two
packages:

- `shiki-core/` (`shiki-core/shiki-core.cabal`): the library. Its modules live under
  `shiki-core/src/Shiki/` (for example `Shiki.K8s.ExecCredential`,
  `Shiki.Persistence.Run`, and the project prelude `Shiki.Prelude`). Tests live under
  `shiki-core/test/` (entry `Spec.hs`). A small developer example executable
  `shiki-run-once` lives at `shiki-core/example/RunOnce.hs`.
- `shiki-cli/` (`shiki-cli/shiki-cli.cabal`): a library of CLI modules under
  `shiki-cli/src/Shiki/Cli/`, the executable `shiki` (`shiki-cli/app/Main.hs`, which just
  calls `Shiki.Cli.runCli`), and tests under `shiki-cli/test/` (entry `Spec.hs`, which
  lists each spec module's `tests` value and runs them with `NumThreads 1`). Help-topic
  text lives in `shiki-cli/data/help/*.md`, and the agent prompt template in
  `shiki-cli/data/prompts/assist.md`. Both are embedded at compile time with `file-embed`.

The top-level parser is `Shiki.Cli.parserInfo` in `shiki-cli/src/Shiki/Cli.hs`. It
parses three global flags (`--db CONNSTR`, `--db-schema SCHEMA`, `--env NAME`) followed
by one of the subcommands `run`, `runs`, `service`, `agent`, `config`, and `help`, via
`Opt.hsubparser`. `runCli` calls `Opt.execParser parserInfo` and dispatches on the
`Command` sum type. `help`, `config`, and `service show` run without a database. `run`,
`runs`, and `agent` first build a `CliEnv` (database pool, Kubernetes client, fzf probe)
through `withDbEnv`.

### Toolchain, build, and test

Enter the development shell with `nix develop` from the repository root, or rely on
direnv. It provides GHC 9.12.4, cabal-install, PostgreSQL binaries (the tests start
throwaway databases through the `ephemeral-pg` library; no running server is needed),
`treefmt`, and the git hooks. Inside it:

```bash
cd /Users/shinzui/Keikaku/bokuno/shiki
cabal build all
cabal test all
```

At the start of this plan (2026-09-11), both test suites pass. The `shiki-cli` suite
ends with `All 42 tests passed`, and the `shiki-core` suite reports `PASS`.

The release binary is built with Nix: `nix build .#shiki` produces `./result/bin/shiki`.
The package set comes from `flake.module.nix`, and `nix/haskell-overlay.nix` builds both
shiki packages with `callCabal2nix`, `doJailbreak` (which ignores `.cabal` version
bounds), and a `-DGIT_HASH` define for the version string.

Formatting: `.git/hooks/pre-commit` runs `treefmt --fail-on-change` on staged files.
`treefmt` runs fourmolu (configured by `fourmolu.yaml`: 2-space indent, trailing commas)
on `.hs` files and cabal-gild on `.cabal` and `cabal.project`. If the hook changes a
file, the commit is rejected and the file is left reformatted in the working tree.
`git add` it and commit again. Do not run `nix fmt` over the whole tree: parts of the
repository are not yet formatted, and a tree-wide format would bury this plan's changes
in unrelated churn.

### Terms used in this plan

A *Cabal common stanza* is a named block of settings (`common NAME`) that other
components pull in with `import: NAME`. Both `.cabal` files currently define
`common common-options` with `default-language: GHC2024` and these
`default-extensions`: `DeriveAnyClass`, `DuplicateRecordFields`, `MultilineStrings`,
`OverloadedLabels`, `OverloadedStrings`, and `PackageImports`. Every library, executable,
and test-suite stanza imports it.

A *package-qualified import* names the package a module comes from, as in
`import "text" Data.Text qualified as Text`. It needs the `PackageImports` GHC
extension. Without the extension, the quoted package name is a parse error.

A *custom prelude* is a project module that re-exports the names almost every module
needs, so modules write one import instead of ten. shiki's is `Shiki.Prelude`
(`shiki-core/src/Shiki/Prelude.hs`). It re-exports `Generic`, `Text`, common
`Control.Monad` and `Data.Maybe` functions, aeson's `FromJSON`/`ToJSON` family,
`UTCTime`, and all of `Control.Lens`. Today it also contains
`import "generic-lens" Data.Generics.Labels ()`.

*Overloaded labels* are the `#fieldName` syntax enabled by `OverloadedLabels`. GHC turns
`#status` into a call to the `IsLabel` type class. The `generic-lens` package provides an
`IsLabel` instance, in module `Data.Generics.Labels`, that makes `#status` a lens onto
the `status` field of any record with a `Generic` instance. Code then writes
`record ^. #status` to read, `record & #status .~ x` to set, and `record & #m ?~ x` to
set a `Maybe` field to `Just x`. That instance is an *orphan instance*: it is defined in
neither the module that defines `IsLabel` nor the one that defines the record types. GHC
makes an orphan visible to every module that imports, directly or transitively, the
module containing it. Importing it from the prelude therefore imposes it on the whole
project.

A *selector function* is the function GHC generates for each record field, such as
`execCommand :: ExecAuth -> Text`. With `DuplicateRecordFields`, two records in scope
may share a field name, and then a bare selector use is ambiguous and does not compile.
The catalog therefore requires `^. #field` for access and lens setters for updates on
shiki's own records. Pattern matching on fields (`\HelpTopic {name} -> …`) and record
*construction* syntax stay fine.

*optparse-applicative* is the command-line parsing library. `parserOptionGroup LABEL p`
(new in 0.19) makes every option inside parser `p` render under the heading `LABEL` in
`--help`, without changing parsing. The library also has a built-in completion protocol.
When the program is invoked with hidden flags such as
`--bash-completion-index N --bash-completion-word W …`, `execParser` and
`customExecParser` print the matching completions instead of running the program.
`--bash-completion-enriched` adds a tab-separated description to each completion.

*terminal-size* is a small library whose `System.Console.Terminal.Size.hSize stdout`
returns `Just (Window {height, width})` from the operating system's `ioctl(TIOCGWINSZ)`
call, or `Nothing` when stdout is not a terminal. The catalog forbids
`ansi-terminal`'s `getTerminalSize` for this job. That function writes escape sequences
to stdout and blocks reading stdin for the reply, which prints garbage in pipes and can
hang.

### What the catalog requires, restated so this plan is self-contained

The core standard requires GHC 9.12 or newer, `default-language: GHC2024`, and a shared
`common common` stanza. That stanza lists the mandatory `default-extensions`
`DeriveAnyClass`, `DuplicateRecordFields`, `OverloadedLabels`, and `OverloadedStrings`,
and every stanza imports it. Extra project-wide extensions are allowed only when a
documented pattern justifies them. `MultilineStrings` is such an extension (shiki uses
`"""` literals in two files). `PackageImports` is explicitly *not*: it must be enabled
by a pragma in the prelude module only. Qualified imports use the postpositive form
`import X qualified as Y`. Operators are never imported qualified. When a prelude
re-export clashes with another import, hide the name at the prelude import
(`import Shiki.Prelude hiding (argument)`), never at the other import.

The prelude standard says `<Project>.Prelude` uses package-qualified imports
(`import "base" Control.Monad as X (…)`) and re-exports them via `module X`, plus a
blanket `module Control.Lens`. It must not import `Data.Generics.Labels ()`. Each module
that uses `#label` over `Generic` records imports it itself, with a plain import
`import Data.Generics.Labels ()`.

The record standard says fields have no type-name prefixes (use `command`, not
`execCommand`). All fields are strict (`!`). Every `deriving` clause names its strategy
(`deriving stock (…)`, `deriving anyclass (…)`, `deriving newtype (…)`). For event and
command data, the entity ID comes first. Fields are read with `^. #field` rather than
selector functions, and updated with `&`, `.~`, `?~`, and `%~` rather than `r { f = x }`
update syntax. shiki's cabal files already pass `-Wmissing-deriving-strategies`, and a
research sweep found every shiki record field strict. The remaining record gaps are in
two modules, listed next.

### The current state, measured during research

The core checks pass except in these places:

- Both `.cabal` files enable `PackageImports` globally, and 374 package-qualified import
  lines exist outside the prelude, in almost every module, test, the example, and
  `shiki-cli/app/Main.hs`.
- `Shiki.Prelude` imports `Data.Generics.Labels ()`, so 25 modules use `#label` without
  importing it:

  ```text
  shiki-cli/src/Shiki/Cli.hs
  shiki-cli/src/Shiki/Cli/Agent.hs
  shiki-cli/src/Shiki/Cli/Agent/Config.hs
  shiki-cli/src/Shiki/Cli/Agent/Context.hs
  shiki-cli/src/Shiki/Cli/Agent/Launch.hs
  shiki-cli/src/Shiki/Cli/Agent/Prompt.hs
  shiki-cli/src/Shiki/Cli/Config.hs
  shiki-cli/src/Shiki/Cli/ConfigInit.hs
  shiki-cli/src/Shiki/Cli/ConfigShow.hs
  shiki-cli/src/Shiki/Cli/Fzf/Selector/Run.hs
  shiki-cli/src/Shiki/Cli/Help.hs
  shiki-cli/src/Shiki/Cli/Project.hs
  shiki-cli/src/Shiki/Cli/Run.hs
  shiki-cli/src/Shiki/Cli/Runs.hs
  shiki-core/example/RunOnce.hs
  shiki-core/src/Shiki/Analysis/Baikai.hs
  shiki-core/src/Shiki/K8s/Introspection.hs
  shiki-core/src/Shiki/K8s/JobBuilder.hs
  shiki-core/src/Shiki/K8s/Logs.hs
  shiki-core/src/Shiki/K8s/Runner.hs
  shiki-core/src/Shiki/Persistence/Run.hs
  shiki-core/test/Shiki/Analysis/BackendSpec.hs
  shiki-core/test/Shiki/Persistence/RunListSpec.hs
  shiki-core/test/Shiki/Persistence/RunSpec.hs
  shiki-core/test/Shiki/Service/ConfigSpec.hs
  ```

- `shiki-cli/src/Shiki/Cli/Fzf.hs` defines `FzfConfig` (fields `fzfBinary`,
  `fzfAvailable`, `stdinIsTerminal`, `stdoutIsTerminal`, `ttyAvailable`), `FzfOpts`
  (fields `fzfPrompt`, `fzfHeader`, `fzfHeight`, `fzfAnsi`, `fzfNoSort`), and
  `Candidate a` (fields `candidateDisplay`, `candidateValue`; it derives only
  `Functor`). The module reads these with selector functions and builds `FzfOpts` with
  `mempty { fzfPrompt = Just t }` update syntax. `Selector/Run.hs`,
  `Selector/Service.hs`, and `test/Shiki/Cli/Fzf/Selector/RunSpec.hs` use the
  `Candidate` selectors and `isFzfAvailable`.
- `shiki-core/src/Shiki/K8s/ExecCredential.hs` defines records with prefixed fields and
  reads them with selectors throughout (about 60 occurrences):
  - `ExecAuth`: `execApiVersion`, `execCommand`, `execArgs`, `execEnv`,
    `execProvideClusterInfo`, `execInteractiveMode`.
  - `ClusterRef`: `clusterServer`, `clusterCAData`, `clusterCAFile`,
    `clusterInsecureSkipTLS`.
  - `ResolvedContext`: `resolvedCluster`, `resolvedExec`.
  - `KubeConfigDoc`: `kcCurrentContext`, `kcContexts`, `kcClusters`, `kcUsers`.
  - `NamedContext`: `ncName`, `ncContext`.
  - `ContextRef`: `crCluster`, `crUser`.
  - `NamedCluster`: `nclName`, `nclCluster`.
  - `NamedUser`: `nuName`, `nuExec`.
  - `ExecCredentialStatus`: `statusToken`, `statusClientCertData`,
    `statusClientKeyData`, `statusExpirationTimestamp`.
  - `ExecCredentialResponse`: `ecrApiVersion`, `ecrKind`, `ecrStatus`.

  Every `FromJSON` instance in that module is hand-written with `withObject` and
  positional constructors, so renaming Haskell fields does not change the JSON or YAML
  wire format. `shiki-core/src/Shiki/K8s/Client.hs` (lines 82 and 85) and
  `shiki-core/test/Shiki/K8s/ExecCredentialSpec.hs` use the selectors.
- `shiki-cli/test/Shiki/Cli/Agent/ContextSpec.hs` reads `AgentContext` and
  `ServiceSummary` with selectors (`services ctx`, `name svc`, `analyzer svc`,
  `serviceLoadErrors ctx`, `recentRuns ctx`, `schemaName ctx`, `cluster ctx`).
- `shiki help <topic>` prints the embedded file verbatim, with no width handling.
  `shiki-cli/src/Shiki/Cli/Help.hs` defines
  `data HelpCommand = ListTopics | ShowTopic !Text`. The topic files follow the
  catalog's authoring discipline: ALL-CAPS section headings, prose paragraphs separated
  by blank lines, and every table or example indented by at least two spaces. No line
  exceeds 82 columns.
- There is no completions command, no option grouping, and
  `optparse-applicative >=0.18` is the only bound. The resolved version is 0.19.0.0 in
  both cabal and Nix.
- `cabal.project` pins GHC indirectly through the Nix shell (GHC 9.12.4). The `.cabal`
  files say `base >=4.20 && <5`, which admits GHC 9.10, and have no `tested-with` field.

### ADRs

There is no `docs/adr/` directory, and `mori.dhall` declares no OKF bundle, so no local
ADR applies. No cross-repository ADR was needed. The earlier convention decision lives
in the Decision Logs of `docs/plans/1-service-configuration-model-and-dhall-loader.md`
and `docs/masterplans/1-microservice-job-runner-with-postgres-backed-run-history.md`,
which this plan supersedes where noted. Milestone 7 creates the first ADR.


## Plan of Work

The work runs in seven milestones. Milestones 1–3 are internal conformance changes. Each
is verified by the unchanged test suite plus a grep that proves the rule now holds.
Milestones 4–6 add user-visible CLI behavior, each with new tests and documentation.
Milestone 7 audits the whole tree against the catalog checklist, proves the Nix release
build, and records the durable decision as an ADR. Commit at the end of every milestone,
and more often if convenient. Every commit message follows Conventional Commits and ends
with the trailer `ExecPlan: docs/plans/16-adopt-haskell-jitsurei-conventions-for-the-initial-release.md`.


### Milestone 1 — Cabal baseline and package-import hygiene

Scope: make both `.cabal` files match the catalog's baseline, and confine
package-qualified imports to the prelude. At the end, `PackageImports` appears only as
a pragma at the top of `shiki-core/src/Shiki/Prelude.hs`, and the build and tests
behave exactly as before.

In `shiki-core/shiki-core.cabal` and `shiki-cli/shiki-cli.cabal`, rename the line
`common common-options` to `common common`, and change every `import: common-options`
to `import: common`. shiki-core has three importing stanzas (library, executable
`shiki-run-once`, and test-suite `shiki-core-test`); shiki-cli has three (library,
executable `shiki`, and test-suite `shiki-cli-test`). Delete the `PackageImports` line
from each `default-extensions` list. Leave `MultilineStrings`, which the catalog allows
project-wide. Change every `base >=4.20 && <5` to `base >=4.21 && <5`. base 4.21 is the
version that ships with GHC 9.12, so the bound now encodes the GHC 9.12 minimum. Add
`tested-with: GHC ==9.12.4` to each package's top-level fields, directly after
`build-type: Simple`. In `shiki-core/shiki-core.cabal` and `shiki-cli/shiki-cli.cabal`,
change the unbounded `generic-lens,` dependency to `generic-lens >=2.2 && <2.4,` (see
the Decision Log for why this is not `^>=2.3`).

At the very top of `shiki-core/src/Shiki/Prelude.hs`, before the Haddock comment, add:

```haskell
{-# LANGUAGE PackageImports #-}
```

Then remove the package qualifier from every import in every other Haskell file. The
command in Concrete Steps does this mechanically. One import in
`shiki-cli/src/Shiki/Cli/Help.hs` spans two lines (`import "optparse-applicative"`
followed by `  Options.Applicative`), and the command handles that shape too. fourmolu
re-sorts and re-indents the rewritten import blocks when the commit hook runs.

If `cabal build all` then reports `Ambiguous module name` for some import, two packages
in that component's `build-depends` expose the same module. Resolve it by removing the
package the component does not need. If both are genuinely needed, the only allowed
exception is a per-file `{-# LANGUAGE PackageImports #-}` on that one module with a
comment explaining why. Record that exception in the Decision Log. Research found no
such collision among shiki's direct dependencies, so this is not expected.

Acceptance: `cabal build all` and `cabal test all` pass with the same results as the
baseline. `git grep -n 'import "' -- '*.hs'` lists only lines from
`shiki-core/src/Shiki/Prelude.hs`. `git grep -n PackageImports` lists only that
module's pragma.


### Milestone 2 — Per-module generic-lens labels

Scope: stop the prelude from exporting the generic-lens orphan instance. At the end,
each module that uses `#label` imports `Data.Generics.Labels ()` itself, and the prelude
does not.

In `shiki-core/src/Shiki/Prelude.hs`, delete the line
`import "generic-lens" Data.Generics.Labels ()`. Rewrite the module's Haddock comment so
it no longer claims to re-export "generic-lens labels". Add a sentence saying that
modules using `#label` must add `import Data.Generics.Labels ()` themselves, so the
orphan `IsLabel` instance stays a per-module choice.

Add `import Data.Generics.Labels ()` to each of the 25 files listed under "The current
state" in Context and Orientation. Place it with the other non-prelude imports. It is a
plain import, with no package qualifier and no `qualified`. Because orphan instances
are visible transitively, the compiler will *not* flag every file that forgot the
import. A module that imports another shiki module which imports the labels will still
compile. Use the check in Concrete Steps, which compares the files that use labels with
the files that import them, as the source of truth.

The test suite `shiki-core-test` and the executable `shiki-run-once` do not currently
list `generic-lens` in `build-depends`. Their modules will now import
`Data.Generics.Labels` directly, so add `generic-lens >=2.2 && <2.4` to both stanzas in
`shiki-core/shiki-core.cabal`. No `shiki-cli` test module uses `#label` today, so
`shiki-cli-test` needs no change in this milestone. Milestone 3 changes that; see there.

Acceptance: the build and tests pass, and the label check prints nothing.


### Milestone 3 — Record-shape conformance

Scope: remove the last prefixed fields and selector-function access from shiki's own
records. At the end, the record-prefix grep prints nothing, and the fzf and kubeconfig
behavior is unchanged, as shown by the existing tests.

In `shiki-cli/src/Shiki/Cli/Fzf.hs`, rename these fields:

- `FzfConfig`: `fzfBinary` becomes `binary`; `fzfAvailable` becomes `available`.
  `stdinIsTerminal`, `stdoutIsTerminal`, and `ttyAvailable` keep their names.
- `FzfOpts`: `fzfPrompt`, `fzfHeader`, `fzfHeight`, `fzfAnsi`, and `fzfNoSort` become
  `prompt`, `header`, `height`, `ansi`, and `noSort`.
- `Candidate a`: `candidateDisplay` and `candidateValue` become `display` and `value`.
  Change its deriving clause to `deriving stock (Generic, Functor)` so `#display` and
  `#value` resolve.

Add `import Data.Generics.Labels ()` to the module. Rewrite every selector use as a lens
read, for example:

```haskell
isFzfAvailable :: FzfConfig -> Bool
isFzfAvailable cfg =
  cfg ^. #available && (cfg ^. #stdinIsTerminal || cfg ^. #ttyAvailable)
```

Rewrite the `Semigroup` instance's field reads the same way, and the smart constructors
as lens setters:

```haskell
withPrompt :: Text -> FzfOpts
withPrompt t = mempty & #prompt ?~ t

withAnsi :: FzfOpts
withAnsi = mempty & #ansi .~ True
```

Leave the `(proc (cfg ^. #binary) args) { std_in = CreatePipe, … }` update alone, per
the Decision Log's third-party exception. Update
`shiki-cli/src/Shiki/Cli/Fzf/Selector/Run.hs` and
`shiki-cli/src/Shiki/Cli/Fzf/Selector/Service.hs`: record construction becomes
`Candidate { display = …, value = … }`. Update
`shiki-cli/test/Shiki/Cli/Fzf/Selector/RunSpec.hs` to read `c ^. #display` and
`c ^. #value`. Each of these three files, and
`shiki-cli/test/Shiki/Cli/Agent/ContextSpec.hs` below, then needs
`import Data.Generics.Labels ()`. Because the two test files live in `shiki-cli-test`,
add `generic-lens >=2.2 && <2.4` to that test-suite's `build-depends`. `Shiki.Prelude`
already re-exports the `^.` operator.

In `shiki-core/src/Shiki/K8s/ExecCredential.hs`, rename the fields as follows. None of
the new names collides with an import in that module.

- `ExecAuth`: `apiVersion`, `command`, `args`, `environment` (not `env`; see the
  Decision Log), `provideClusterInfo`, `interactiveMode`.
- `ClusterRef`: `server`, `caData`, `caFile`, `insecureSkipTls`.
- `ResolvedContext`: `cluster`, `exec` (matching `NamedUser`'s field and the
  kubeconfig's `user.exec` key; do not use `execAuth`, which the prefix check in
  Concrete Steps would flag).
- `KubeConfigDoc`: `currentContext`, `contexts`, `clusters`, `users`.
- `NamedContext`: `name`, `context`.
- `ContextRef`: `cluster`, `user`.
- `NamedCluster`: `name`, `cluster`.
- `NamedUser`: `name`, `exec`.
- `ExecCredentialStatus`: `token`, `clientCertData`, `clientKeyData`,
  `expirationTimestamp`.
- `ExecCredentialResponse`: `apiVersion`, `kind`, `status`.

The module ends up with several records sharing field names (`name`, `cluster`,
`apiVersion`). `DuplicateRecordFields` allows that, and every access must then go
through `^. #field`. Add `import Data.Generics.Labels ()`. Rewrite `findBy ncName …` as
`findBy (^. #name) …`, `execCommand execAuth` as `execAuth ^. #command`, and so on. The
`ExecAuth { … }` construction in the `FromJSON ExecAuth` instance uses the new field
names. The other instances construct positionally and need no change.

Local variables now named like a field (`cluster` in `runExecCredential` and
`buildChildEnv`, `user` in `execAuthForContext` and the `NamedUser` parser) may trigger
`-Wname-shadowing` warnings under `-Wall`. Rename such locals (for example
`clusterRef`, `namedUser`) so the build stays warning-free. Update
`shiki-core/src/Shiki/K8s/Client.hs`: `resolvedExec rc` becomes `rc ^. #exec`, and
`resolvedCluster rc` becomes `rc ^. #cluster`. Add the labels import there. Update
`shiki-core/test/Shiki/K8s/ExecCredentialSpec.hs` the same way. It is in
`shiki-core-test`, which gained `generic-lens` in Milestone 2.

In `shiki-cli/test/Shiki/Cli/Agent/ContextSpec.hs`, replace the selector reads with
lens reads, such as `ctx ^. #services`, `svc ^. #name`, and `ctx ^. #serviceLoadErrors`.

Acceptance: the build and tests pass, `cabal build all` prints no new warnings, and the
prefix grep in Concrete Steps prints nothing.


### Milestone 4 — Terminal-aware help width

Scope: `shiki help <topic>` fits prose to the terminal, capped at 140 columns. It
accepts `--width COLUMNS`, and it stays byte-identical to the source when piped. At the
end, an operator on an 80-column terminal sees topic prose wrapped at 80 columns, and
`shiki help runs | cmp - shiki-cli/data/help/runs.md` succeeds.

Add `terminal-size >=0.3.4 && <0.4` to the `shiki-cli` library's `build-depends`.
0.3.4 is the version in both the Hackage index and the Nix package set. Re-check Hackage
for a newer release before committing the bound.

In `shiki-cli/src/Shiki/Cli/Help.hs`, change the command type and parser:

```haskell
data HelpCommand
  = ListTopics
  | ShowTopic !Text !(Maybe Int)
  deriving stock (Generic, Eq, Show)

helpParser :: Parser HelpCommand
helpParser = mkHelpCommand <$> optional topicArg <*> widthOption
  where
    mkHelpCommand Nothing _ = ListTopics
    mkHelpCommand (Just t) w = ShowTopic t w
    topicArg =
      argument
        str
        ( metavar "TOPIC"
            <> help ("Help topic (one of: " <> Text.unpack topicList <> ")")
        )
    topicList = Text.intercalate ", " (fmap (^. #name) helpTopics)

widthOption :: Parser (Maybe Int)
widthOption =
  optional
    ( option
        auto
        ( long "width"
            <> short 'w'
            <> metavar "COLUMNS"
            <> help "Wrap topic prose to COLUMNS (indented blocks stay verbatim)"
        )
    )
```

The single shared `widthOption` matters. The catalog records two tempting shapes that
break. Attaching `--width` only to the topic branch makes `shiki help --width 60` fail
with `Missing: TOPIC`, because `<|>` commits to the branch owning the flag. Declaring
`--width` in two alternatives lists it twice in `--help`. With this shape, the usage line
reads `shiki help [TOPIC] [-w|--width COLUMNS]`, and `--width` without a topic is
accepted and ignored, because the index is short and width-agnostic.

Add the width resolution and renderer, exporting `resolveWidth`, `renderTopic`, and
`rewrap` for tests:

```haskell
import System.Console.Terminal.Size qualified as TermSize
import System.IO (hIsTerminalDevice, stdout)

-- | Cap for auto-detected widths. An explicit --width bypasses it.
maxAutoWidth :: Int
maxAutoWidth = 140

resolveWidth :: Maybe Int -> IO (Maybe Int)
resolveWidth (Just w) = pure (Just w)
resolveWidth Nothing = do
  isTty <- hIsTerminalDevice stdout
  if not isTty
    then pure Nothing
    else do
      mWin <- TermSize.hSize stdout
      pure $ case mWin of
        Just win | win ^. #width > 0 -> Just (min (win ^. #width) maxAutoWidth)
        _ -> Nothing

renderTopic :: Maybe Int -> Text -> Text
renderTopic Nothing body = body
renderTopic (Just w) body = rewrap (max 1 w) body
```

`TermSize.Window` derives `Generic`, so `#width` works once the module imports
`Data.Generics.Labels ()`, which `Help.hs` already does after Milestone 2. The `Nothing`
branch of `resolveWidth` is what keeps piped output byte-stable. An explicit `--width`
always wins, with no cap and no terminal check.

`rewrap` is conservative. It splits the body into paragraphs at blank lines. A paragraph
in which every non-blank line starts with two spaces is a table, example, or transcript,
and passes through untouched. Every other paragraph is joined, split on whitespace, and
packed greedily into lines no wider than the width. A word longer than the width gets
its own line. Paragraphs are rejoined with one blank line:

```haskell
rewrap :: Int -> Text -> Text
rewrap width body =
  Text.intercalate "\n\n" (fmap (rewrapParagraph width) (splitOnBlankLines body))

splitOnBlankLines :: Text -> [Text]
splitOnBlankLines body = go [] [] (Text.lines body)
  where
    go acc cur [] = reverse (flush cur acc)
    go acc cur (l : ls)
      | Text.null (Text.strip l) = go (flush cur acc) [] ls
      | otherwise = go acc (l : cur) ls
    flush [] acc = acc
    flush cur acc = Text.intercalate "\n" (reverse cur) : acc

rewrapParagraph :: Int -> Text -> Text
rewrapParagraph width paragraph
  | isIndentedBlock paragraph = paragraph
  | otherwise = reflow width paragraph

isIndentedBlock :: Text -> Bool
isIndentedBlock paragraph = not (null nonBlank) && all ("  " `Text.isPrefixOf`) nonBlank
  where
    nonBlank = filter (not . Text.null . Text.strip) (Text.lines paragraph)

reflow :: Int -> Text -> Text
reflow width paragraph = Text.intercalate "\n" (pack (Text.words paragraph))
  where
    pack [] = []
    pack (firstWord : rest) = go firstWord rest
    go acc [] = [acc]
    go acc (w : ws)
      | Text.length acc + 1 + Text.length w <= width = go (acc <> " " <> w) ws
      | otherwise = acc : go w ws
```

A consequence worth knowing: the source files use two blank lines between sections, and
the re-flowed output uses one. Piped output is unaffected, because it is not re-flowed.

Change `runHelp` and `showTopic` so the verbatim path still uses `TIO.putStr` (the
embedded content already ends in a newline), and the re-flowed path uses `TIO.putStrLn`
(`rewrap` drops the trailing newline):

```haskell
runHelp :: HelpCommand -> IO ()
runHelp = \case
  ListTopics -> listTopics
  ShowTopic topic mWidth -> showTopic topic mWidth

showTopic :: Text -> Maybe Int -> IO ()
showTopic raw mWidth =
  let key = Text.toLower (Text.strip raw)
   in case find (\t -> (t ^. #name) == key) helpTopics of
        Just t -> do
          effective <- resolveWidth mWidth
          case effective of
            Nothing -> TIO.putStr (t ^. #content)
            Just w -> TIO.putStrLn (renderTopic (Just w) (t ^. #content))
        Nothing -> … -- unchanged unknown-topic error path
```

`Shiki.Prelude` re-exports all of `Control.Lens`. If one of the new optparse or
terminal-size names collides with a lens name (lens exports `argument`, for example),
add it to the existing `import Shiki.Prelude hiding (…)` list.

Tests in `shiki-cli/test/Shiki/Cli/HelpSpec.hs`:

- Update the existing parser test to expect
  `Right (ShowTopic "services" Nothing)` for `["services"]`.
- Add a test that `["services", "--width", "60"]` parses to
  `ShowTopic "services" (Just 60)`, and one that `["--width", "60"]` parses to
  `ListTopics`.
- Add a pure `rewrap` test: `rewrap 20` of a prose paragraph yields no line longer than
  20, and preserves an indented block verbatim even when its lines exceed 20.
- Add a test that `renderTopic Nothing` is the identity on every topic's content.

Update `docs/user/help.md` (its Usage section) to document `--width`/`-w`,
auto-detection with the 140-column cap, and the verbatim-when-piped rule. Add an entry
under `## [Unreleased]` / `### Added` in `CHANGELOG.md`.

Acceptance: the tests pass, and the piped and `--width` checks in Validation and
Acceptance hold.


### Milestone 5 — Shell completions

Scope: add `shiki completions bash|zsh|fish`, which prints a script that delegates
completion back to the `shiki` binary through optparse-applicative's protocol. Because
the completion answers come from the parser itself, every current and future
subcommand and flag completes with no hand-kept command list. At the end, the Bash demo
in Validation and Acceptance prints `run` and `runs`.

Create `shiki-cli/src/Shiki/Cli/Completions.hs`:

```haskell
-- | The @shiki completions@ subcommand. Each generator prints a static script
--   that asks the @shiki@ binary for completions at Tab time through
--   optparse-applicative's @--bash-completion-*@ protocol, so the scripts never
--   need a hand-maintained command list. Bash uses the plain protocol, because
--   Bash cannot display descriptions. Zsh and Fish use the enriched protocol,
--   which appends a tab-separated description to each word.
module Shiki.Cli.Completions
  ( CompletionsShell (..),
    completionsParser,
    completionScript,
    runCompletions,
  )
where

import Data.Text qualified as Text
import Data.Text.IO qualified as TIO
import Options.Applicative (Parser, command, hsubparser, info, progDesc)
import Shiki.Prelude

data CompletionsShell = Bash | Zsh | Fish
  deriving stock (Generic, Eq, Show, Enum, Bounded)

completionsParser :: Parser CompletionsShell
completionsParser =
  hsubparser
    ( command "bash" (info (pure Bash) (progDesc "Print the Bash completion script"))
        <> command "zsh" (info (pure Zsh) (progDesc "Print the Zsh completion script"))
        <> command "fish" (info (pure Fish) (progDesc "Print the Fish completion script"))
    )

runCompletions :: CompletionsShell -> IO ()
runCompletions = TIO.putStr . completionScript

completionScript :: CompletionsShell -> Text
completionScript = \case
  Bash -> bashScript
  Zsh -> zshScript
  Fish -> fishScript

bashScript :: Text
bashScript =
  Text.unlines
    [ "_shiki_completions() {",
      "    local CMDLINE",
      "    local IFS=$'\\n'",
      "    CMDLINE=(--bash-completion-index $COMP_CWORD)",
      "",
      "    for arg in ${COMP_WORDS[@]}; do",
      "        CMDLINE=(${CMDLINE[@]} --bash-completion-word \"$arg\")",
      "    done",
      "",
      "    COMPREPLY=( $(shiki \"${CMDLINE[@]}\" 2>/dev/null) )",
      "}",
      "",
      "complete -o filenames -F _shiki_completions shiki"
    ]

zshScript :: Text
zshScript =
  Text.unlines
    [ "#compdef shiki",
      "",
      "_shiki() {",
      "    local -a completions",
      "    local CMDLINE",
      "    local IFS=$'\\n'",
      "",
      "    CMDLINE=(--bash-completion-enriched --bash-completion-index $((CURRENT - 1)))",
      "",
      "    for arg in ${words[@]}; do",
      "        CMDLINE=(${CMDLINE[@]} --bash-completion-word \"$arg\")",
      "    done",
      "",
      "    local line",
      "    for line in $(shiki \"${CMDLINE[@]}\" 2>/dev/null); do",
      "        local word=${line%%$'\\t'*}",
      "        local desc=${line#*$'\\t'}",
      "        if [[ \"$word\" != \"$desc\" ]]; then",
      "            completions+=(\"${word//:/\\\\:}:${desc}\")",
      "        else",
      "            completions+=(\"$word\")",
      "        fi",
      "    done",
      "",
      "    if [[ ${#completions[@]} -gt 0 ]]; then",
      "        _describe 'shiki' completions",
      "    fi",
      "}",
      "",
      "_shiki"
    ]

fishScript :: Text
fishScript =
  Text.unlines
    [ "# Disable file completion by default",
      "complete -c shiki -f",
      "",
      "function __shiki_complete",
      "    set -l tokens (commandline -cop)",
      "    set -l current (commandline -ct)",
      "    set -l index (count $tokens)",
      "",
      "    set -l args --bash-completion-enriched --bash-completion-index $index",
      "    for token in $tokens",
      "        set args $args --bash-completion-word $token",
      "    end",
      "    set args $args --bash-completion-word \"$current\"",
      "",
      "    for line in (shiki $args 2>/dev/null)",
      "        set -l parts (string split \\t -- $line)",
      "        if test (count $parts) -ge 2",
      "            printf '%s\\t%s\\n' $parts[1] $parts[2]",
      "        else",
      "            echo $line",
      "        end",
      "    end",
      "end",
      "",
      "complete -c shiki -a '(__shiki_complete)'"
    ]
```

How the scripts work: when the user presses Tab, the shell calls
`shiki --bash-completion-index N --bash-completion-word shiki --bash-completion-word …`
with the words typed so far and the index of the word under the cursor.
optparse-applicative walks the parser tree, prints the candidates one per line, and
exits without running any command. Bash's `complete -o filenames` falls back to file
completion when shiki returns nothing. Zsh escapes `:` in words because `_describe` uses
`:` to separate a word from its description. Fish's `complete -c shiki -f` disables its
default file completion.

Register the module under `exposed-modules` in `shiki-cli/shiki-cli.cabal`. In
`shiki-cli/src/Shiki/Cli.hs`, add a constructor `Completions !CompletionsShell` to
`Command`. Add a subcommand with
`Opt.command "completions" (Opt.info (Completions <$> completionsParser) (Opt.progDesc "Print a shell completion script (bash, zsh, fish)"))`,
placed after `help`. Dispatch it in `runCli` as `Completions shell -> runCompletions shell`,
without `withDbEnv`, like `Help`. The completion protocol runs inside the parser, before
any dispatch, so pressing Tab never touches the database or the cluster. Update the
module's Haddock subcommand list.

Create `shiki-cli/test/Shiki/Cli/ParserSpec.hs` (module `Shiki.Cli.ParserSpec`,
exporting `tests :: TestTree`). Register it in `shiki-cli/shiki-cli.cabal` under the test
suite's `other-modules`, and in `shiki-cli/test/Spec.hs`'s list. Its completion test
drives the real top-level parser through the protocol:

```haskell
completionsFor :: [String] -> IO [String]
completionsFor wordsSoFar =
  case Opt.execParserPure Opt.defaultPrefs parserInfo protocolArgs of
    Opt.CompletionInvoked c -> lines <$> Opt.execCompletion c "shiki"
    _ -> assertFailure "expected the completion protocol to be invoked" >> pure []
  where
    protocolArgs =
      ["--bash-completion-index", show (length wordsSoFar - 1)]
        <> concatMap (\w -> ["--bash-completion-word", w]) wordsSoFar
```

With `wordsSoFar = ["shiki", "ru"]`, assert the result contains `"run"` and `"runs"` and
does not contain `"agent"`. With `["shiki", "runs", ""]`, assert it contains `"list"`
and `"analyze"`. Add smoke tests that `completionScript Bash` contains
`complete -o filenames -F _shiki_completions shiki`, that `completionScript Zsh` starts
with `#compdef shiki`, and that `completionScript Fish` contains
`complete -c shiki -a '(__shiki_complete)'`. Milestone 6 switches these tests from
`Opt.defaultPrefs` to the exported `cliPrefs`.

Documentation: add a `## \`shiki completions\`` section to `docs/user/commands.md` with
the three install commands:

```bash
shiki completions bash > ~/.local/share/bash-completion/completions/shiki
shiki completions zsh  > "${fpath[1]}/_shiki"     # or: eval "$(shiki completions zsh)"
shiki completions fish > ~/.config/fish/completions/shiki.fish
```

Add one line to the command list in `README.md` ("What it does") and to
`docs/user/getting-started.md` (after "Build the CLI"). Add a `CHANGELOG.md` entry
under `### Added`.

Acceptance: the tests pass, and the Bash demo and syntax checks in Validation and
Acceptance hold.


### Milestone 6 — Option groups and help-on-empty

Scope: make `--help` output scannable, and make a bare command print help. At the end,
`shiki --help` shows an `Environment` section holding `--db`, `--db-schema`, and
`--env`. `shiki agent assist --help` shows `Provider` (`--provider`, `--model`) and
`Session context` (`--prompt`, `--service`, `--run`), with `--debug` left under the
default options section. Bare `shiki` prints the full help page.

In `shiki-cli/shiki-cli.cabal`, change both `optparse-applicative >=0.18` entries (the
library and the test suite) to `optparse-applicative >=0.19 && <0.20`.
`parserOptionGroup` first appeared in 0.19.0.0, which cabal and the Nix set both
resolve. Re-check Hackage for a newer 0.19.x or 0.20 before committing the bound.

In `shiki-cli/src/Shiki/Cli.hs`, wrap the three global flags. The `Options` record is
unchanged:

```haskell
optionsParser :: Parser Options
optionsParser =
  (\(conn, schema, env) cmd -> Options conn schema env cmd)
    <$> Opt.parserOptionGroup "Environment" ((,,) <$> dbOpt <*> dbSchemaOpt <*> envOpt)
    <*> commandParser
```

`dbOpt`, `dbSchemaOpt`, and `envOpt` are the three existing
`Opt.optional (Opt.strOption …)` parsers, moved unchanged into `where` bindings. In
`shiki-cli/src/Shiki/Cli/Agent.hs`, restructure `assistOptionsParser` the same way.
Nothing else in the file changes:

```haskell
assistOptionsParser :: Parser AssistOptions
assistOptionsParser =
  (\(prov, mdl) (prm, svc, rid) dbg -> AssistOptions prov mdl prm svc rid dbg)
    <$> Opt.parserOptionGroup "Provider" ((,) <$> providerOpt <*> modelOpt)
    <*> Opt.parserOptionGroup "Session context" ((,,) <$> promptOpt <*> serviceOpt <*> runOpt)
    <*> debugSwitch
```

Also in `Shiki.Cli`, define and export `cliPrefs`, and use it in `runCli`:

```haskell
cliPrefs :: Opt.ParserPrefs
cliPrefs = Opt.prefs Opt.showHelpOnEmpty

runCli :: IO ()
runCli = do
  opts <- Opt.customExecParser cliPrefs parserInfo
  …
```

Extend `shiki-cli/test/Shiki/Cli/ParserSpec.hs`. First change `completionsFor` to use
`cliPrefs`. Then add a helper that renders the help a user would see:

```haskell
renderedHelp :: [String] -> String
renderedHelp args =
  case Opt.execParserPure cliPrefs parserInfo args of
    Opt.Failure failure -> fst (Opt.renderFailure failure "shiki")
    _ -> error ("expected help output for " <> show args)
```

Assert that `renderedHelp ["--help"]` contains `"Environment"` and `"--db-schema"`, that
`renderedHelp ["agent", "assist", "--help"]` contains `"Provider"` and
`"Session context"`, and that `renderedHelp []` contains `"Available commands:"`. The
last one proves `showHelpOnEmpty` is active. The `--version` test in
`shiki-cli/test/Shiki/Cli/VersionSpec.hs` must keep passing unchanged. The
optparse-applicative 0.19 Haddock places grouped sections after the default
`Available options:` block. Assert only that each heading is present, not its position.

Update the "Global options" and "`shiki agent assist`" sections of
`docs/user/commands.md` if they reproduce `--help` output. Add a `### Changed` entry to
`CHANGELOG.md` for the grouped help and help-on-empty.

Acceptance: the tests pass, and running `shiki --help` in a terminal visibly shows the
sections.


### Milestone 7 — Release conformance audit, ADR, and Nix build

Scope: prove, on the whole tree and on the Nix-built release binary, that everything
above holds, and record the durable decision. At the end, the audit transcript is pasted
into this plan, `./result/bin/shiki` shows all three new behaviors, and
`docs/adr/1-follow-haskell-jitsurei-conventions.md` exists.

Run the audit commands in Concrete Steps and paste the transcript into Outcomes &
Retrospective. They cover the catalog checklist items `ghc-version`, `common-stanza`,
`import-common`, `project-prelude`, `package-imports`, `generic-labels`, `record-shape`,
`qualified-imports`, and `extra-extensions`. Also re-verify the already-adopted CLI
patterns named in the Decision Log: `--version` shows a commit hash on the Nix build,
`shiki runs show` with no ID opens fzf when it is installed, and `shiki help` lists six
topics.

Build the release with `nix build .#shiki`. The Nix derivation for `shiki-cli` comes
from `callCabal2nix` on `shiki-cli/shiki-cli.cabal`, so the new `terminal-size`
dependency is picked up automatically. The planning evaluation showed it present in the
package set at 0.3.4. If the build fails because a dependency is missing from the set,
add it in `nix/haskell-overlay.nix` and record a Surprise.

Create `docs/adr/1-follow-haskell-jitsurei-conventions.md` as plain Markdown, with no
YAML frontmatter, using these sections:

- a title line;
- `Status: Accepted` and `Date:` (the completion date);
- `Context`: shiki adopted the catalog in 2026-05, the catalog changed in 2026-07, and
  the release needs one stated convention;
- `Decision`: shiki follows `mori://shinzui/haskell-jitsurei/docs/core-standards`,
  `mori://shinzui/haskell-jitsurei/docs/core-custom-prelude`, and
  `mori://shinzui/haskell-jitsurei/docs/core-record-patterns`, plus the adopted CLI
  patterns, with these standing exceptions: `MultilineStrings` is a project-wide default
  extension; record update is allowed on third-party types without `Generic`; the
  `generic-lens` bound is `>=2.2 && <2.4` because of the Nix set;
- `Consequences`: new modules must import `Data.Generics.Labels ()` locally,
  package-qualified imports belong only in `Shiki.Prelude`, and a catalog change is
  adopted by a new plan that revises this ADR.

Reference this plan from the ADR by its repository-relative path.

Acceptance: every audit command prints its expected result, the Nix binary behaves as
described in Validation and Acceptance, and the ADR is committed.


## Concrete Steps

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/shiki`,
inside `nix develop`.

Milestone 1, strip package qualifiers everywhere except the prelude. The first
substitution handles the two-line form; the second handles the ordinary one-line form:

```bash
git ls-files -- '*.hs' \
  | grep -v '^shiki-core/src/Shiki/Prelude.hs$' \
  | xargs perl -0pi -e 's/^import "[^"]+"\n[ \t]+/import /mg; s/^import "[^"]+"[ \t]+/import /mg'
```

Then verify and build:

```bash
git grep -n 'import "' -- '*.hs' | grep -v '^shiki-core/src/Shiki/Prelude.hs:'   # expect no output
git grep -n PackageImports -- '*.hs' '*.cabal'                                   # expect only the Prelude pragma
cabal build all
cabal test all
```

Expected tail of `cabal test all`, identical to the baseline:

```text
All 42 tests passed
Test suite shiki-cli-test: PASS
```

Commit, for example:

```text
refactor: confine PackageImports to Shiki.Prelude and adopt the common stanza

Rename the shared Cabal stanza to `common`, drop PackageImports from the
default extensions, strip package qualifiers from every import outside the
prelude, require GHC 9.12 through base >=4.21, and bound generic-lens.

ExecPlan: docs/plans/16-adopt-haskell-jitsurei-conventions-for-the-initial-release.md
```

If the commit is rejected by the `treefmt` hook, run `git add -u` and repeat the
`git commit`.

Milestone 2, the label-import check. Lines starting with a CPP directive (`#if`,
`#else`, `#endif`) are excluded:

```bash
for f in $(git grep -lE '#[a-z][A-Za-z0-9_]*' -- '*.hs'); do
  if git grep -nE '#[a-z][A-Za-z0-9_]*' -- "$f" | grep -vqE ':[0-9]+:#(if|ifdef|ifndef|else|elif|endif|define|include)'; then
    grep -q '^import Data.Generics.Labels ()' "$f" || echo "MISSING labels import: $f"
  fi
done
git grep -n '^import.*Data.Generics.Labels' -- shiki-core/src/Shiki/Prelude.hs   # expect no output
cabal build all && cabal test all
```

Milestone 3, the prefix grep. It matches strict record-field declarations (`name :: !T`)
whose name starts with one of the retired prefixes. `git grep -E` does not support `\s`,
so the pattern uses `[[:space:]]`. Before Milestone 3 it reports 9 lines in `Fzf.hs` and
about 30 in `ExecCredential.hs`:

```bash
git grep -nE '^[[:space:]]*[,{]?[[:space:]]*(fzf|candidate|exec|cluster|resolved|kc|nc|ncl|cr|nu|status|ecr)[A-Z][A-Za-z0-9]*[[:space:]]*::[[:space:]]*!' -- '*.hs'   # expect no output
cabal build all 2>&1 | grep -c 'warning'   # expect 0 (on a clean rebuild of the touched components)
cabal test all
```

Milestone 4, observe the width behavior:

```bash
SHIKI=$(cabal list-bin shiki)
"$SHIKI" help runs | cmp - shiki-cli/data/help/runs.md && echo identical
"$SHIKI" help runs --width 40 | awk '!/^  / && length($0) > 40' | wc -l
"$SHIKI" help --help
```

Expected:

```text
identical
       0
Usage: shiki help [TOPIC] [-w|--width COLUMNS]
```

Milestone 5, observe completions working in a real Bash:

```bash
SHIKI=$(cabal list-bin shiki)
PATH="$(dirname "$SHIKI"):$PATH" bash -c '
  source <(shiki completions bash)
  COMP_WORDS=(shiki ru); COMP_CWORD=1; _shiki_completions; printf "%s\n" "${COMPREPLY[@]}"
  COMP_WORDS=(shiki runs ""); COMP_CWORD=2; _shiki_completions; printf "%s\n" "${COMPREPLY[@]}"'
"$SHIKI" completions bash | bash -n && echo bash-ok
"$SHIKI" completions zsh | zsh -n && echo zsh-ok
command -v fish >/dev/null && "$SHIKI" completions fish | fish --no-execute && echo fish-ok
```

Expected (the order within each group may differ):

```text
run
runs
list
show
logs
error
analyze
bash-ok
zsh-ok
```

Milestone 6:

```bash
SHIKI=$(cabal list-bin shiki)
"$SHIKI" --help | grep -A4 '^Environment'
"$SHIKI" agent assist --help | grep -E '^(Provider|Session context)'
"$SHIKI"; echo "exit=$?"
```

Expected: an `Environment` heading followed by the `--db`, `--db-schema`, and `--env`
lines; both `Provider` and `Session context` headings; and the full help page followed by
`exit=1` (optparse-applicative exits 1 when it shows help on empty input).

Milestone 7, the audit:

```bash
grep -nE '^(common|library|executable|test-suite|benchmark)\b|^\s*import:' shiki-core/shiki-core.cabal shiki-cli/shiki-cli.cabal
grep -nE 'default-language|tested-with|base >=' shiki-core/shiki-core.cabal shiki-cli/shiki-cli.cabal
git grep -nE '^import qualified ' -- '*.hs'                                      # expect no output
git grep -n 'import "' -- '*.hs' | grep -v '^shiki-core/src/Shiki/Prelude.hs:'   # expect no output
git grep -n PackageImports -- '*.hs' '*.cabal'                                   # expect only the Prelude pragma
git grep -n '^import.*Data.Generics.Labels' -- shiki-core/src/Shiki/Prelude.hs   # expect no output
cabal build all && cabal test all
nix build .#shiki
./result/bin/shiki --version
./result/bin/shiki completions zsh | head -1
./result/bin/shiki help runs --width 60 | head -8
```

Expected: every stanza line is followed by `import: common`. Both packages show
`default-language: GHC2024`, `tested-with: GHC ==9.12.4`, and `base >=4.21`. The greps
print nothing except the prelude pragma. The version line reads
`shiki v0.1.0.0 (<7-char sha>)`. The completion line reads `#compdef shiki`. The help
excerpt is wrapped at 60 columns or fewer.


## Validation and Acceptance

The plan is complete when all of the following hold on a fresh checkout of the final
commit:

1. `cabal build all` succeeds with no warnings from shiki modules, and `cabal test all`
   reports PASS for both suites. `shiki-cli-test` reports more than the baseline 42
   tests, because `HelpSpec` and the new `ParserSpec` add cases.
2. The conformance commands from Milestone 7 print only the expected lines. This is the
   catalog checklist, restated as commands.
3. Help width: `shiki help runs | cmp - shiki-cli/data/help/runs.md` prints nothing and
   exits 0. `shiki help runs --width 40` produces no un-indented line longer than 40
   characters. In an 80-column interactive terminal, `shiki help runs` shows prose
   wrapped at 80 columns. In a terminal wider than 140 columns, prose wraps at 140.
4. Completions: the Bash session in Concrete Steps prints `run` and `runs` for
   `shiki ru<Tab>`, and the five `runs` subcommands for `shiki runs <Tab>`. `bash -n`
   and `zsh -n` accept the scripts. In an interactive zsh after
   `eval "$(shiki completions zsh)"`, `shiki <Tab>` lists subcommands with their
   descriptions.
5. Help layout: `shiki --help` shows an `Environment` section, and
   `shiki agent assist --help` shows `Provider` and `Session context` sections. Bare
   `shiki` prints the help page rather than `Missing: COMMAND`.
6. Release: `nix build .#shiki` succeeds, and `./result/bin/shiki` shows behaviors 3–5
   plus a `--version` line carrying the commit hash.
7. `docs/adr/1-follow-haskell-jitsurei-conventions.md` exists and states the decision
   and its exceptions. `CHANGELOG.md` lists the new features under `[Unreleased]`.

Milestones 1–3 change no behavior. Their proof is the unchanged test results together
with the greps, which fail before the milestone and pass after it.


## Idempotence and Recovery

The Milestone 1 `perl` rewrite is idempotent. After the first run, no line outside the
prelude matches `import "…"`, so a second run changes nothing. It edits only tracked
`.hs` files. To undo it before committing, run `git checkout -- shiki-core shiki-cli`.
Every milestone ends in a commit that builds and passes tests, so `git revert` of a
single milestone commit is a clean rollback.

The pre-commit hook may reject a commit once, after reformatting staged files with
fourmolu or cabal-gild. That is expected. Inspect the reformatted diff with `git diff`,
`git add -u`, and commit again. If fourmolu fails outright on a file (a parse error),
the file has a real syntax problem from an edit. Fix it, rather than bypassing the hook.

If Milestone 2 leaves a module using `#label` without the import, the build may still
succeed because of transitive orphan visibility. The loop in Concrete Steps is the
authoritative check. Run it again after any later milestone that adds label usage
(Milestones 3, 4, and 6 do).

If Milestone 3 breaks kubeconfig parsing, `ExecCredentialSpec` fails. Parsing is
positional, so a failure means a constructor argument order changed by mistake. Compare
against the `withObject` parsers. Real-cluster behavior can be spot-checked with
`shiki runs list --env <name>` against an environment whose kubeconfig uses an exec
plugin. That command loads the client in `withCliEnv`.

No step touches a database, a cluster, or a remote service. The tests start their own
throwaway PostgreSQL instances.


## Interfaces and Dependencies

New or changed dependencies, with the reason for each:

- `terminal-size >=0.3.4 && <0.4` in the `shiki-cli` library, for
  `System.Console.Terminal.Size.hSize` (ioctl-based terminal width, required by the
  help-width pattern instead of `ansi-terminal`).
- `optparse-applicative >=0.19 && <0.20` in the `shiki-cli` library and test suite, for
  `parserOptionGroup`.
- `generic-lens >=2.2 && <2.4` in the `shiki-core` library, the `shiki-core` test suite,
  the `shiki-run-once` executable, the `shiki-cli` library, and the `shiki-cli` test
  suite, for the per-module `Data.Generics.Labels` import.
- `base >=4.21 && <5` everywhere, encoding the GHC 9.12 minimum.

Interfaces that must exist at the end of the plan:

In `shiki-core/src/Shiki/Prelude.hs`: the first line is
`{-# LANGUAGE PackageImports #-}`, and there is no `Data.Generics.Labels` import. The
export list stays `(module X, module Control.Lens)`.

In `shiki-cli/src/Shiki/Cli.hs`:

```haskell
module Shiki.Cli (runCli, parserInfo, cliPrefs) where

data Command
  = Run !RunOptions
  | Runs !RunsCommand
  | ServiceShow !(Maybe Text)
  | Agent !AgentCommand
  | Help !HelpCommand
  | Config !ConfigCommand
  | Completions !CompletionsShell

cliPrefs :: Opt.ParserPrefs
parserInfo :: Opt.ParserInfo Options
runCli :: IO ()
```

In `shiki-cli/src/Shiki/Cli/Help.hs`:

```haskell
data HelpCommand = ListTopics | ShowTopic !Text !(Maybe Int)
helpParser :: Parser HelpCommand
runHelp :: HelpCommand -> IO ()
resolveWidth :: Maybe Int -> IO (Maybe Int)
renderTopic :: Maybe Int -> Text -> Text
rewrap :: Int -> Text -> Text
```

In `shiki-cli/src/Shiki/Cli/Completions.hs`:

```haskell
data CompletionsShell = Bash | Zsh | Fish
completionsParser :: Parser CompletionsShell
completionScript :: CompletionsShell -> Text
runCompletions :: CompletionsShell -> IO ()
```

In `shiki-cli/src/Shiki/Cli/Fzf.hs`, the records are:

```haskell
data FzfConfig = FzfConfig
  { binary :: !FilePath, available :: !Bool, stdinIsTerminal :: !Bool
  , stdoutIsTerminal :: !Bool, ttyAvailable :: !Bool }
data FzfOpts = FzfOpts
  { prompt :: !(Maybe Text), header :: !(Maybe Text), height :: !(Maybe Text)
  , ansi :: !Bool, noSort :: !Bool }
data Candidate a = Candidate { display :: !Text, value :: !a }
  deriving stock (Generic, Functor)
```

The exported functions `detectFzfConfig`, `isFzfAvailable`, `runFzf`, `withPrompt`,
`withHeader`, `withHeight`, `withAnsi`, and `withNoSort` keep their names and types.

In `shiki-core/src/Shiki/K8s/ExecCredential.hs`, the exported records `ExecAuth`,
`ClusterRef`, `ResolvedContext`, and `ExecCredentialStatus` use the unprefixed field
names listed in Milestone 3. The exported functions `execAuthForContext`,
`readKubeConfigExecAuth`, and `runExecCredential` keep their names and types.

New test module `shiki-cli/test/Shiki/Cli/ParserSpec.hs` exports `tests :: TestTree`
and is registered in `shiki-cli/shiki-cli.cabal` and `shiki-cli/test/Spec.hs`.
