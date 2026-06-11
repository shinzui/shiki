---
id: 15
slug: add-shiki-version-output-with-git-sha
title: "Add shiki version output with git SHA"
kind: exec-plan
created_at: 2026-06-11T20:34:08Z
intention: intention_01ktw64jjme9z8y3chegv3g7ya
---

# Add shiki version output with git SHA

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

After this change, a person running `shiki --version` can see exactly which CLI release and source commit they are using. The output will look like `shiki v0.1.0.0 (a1b2c3d)` when a commit hash is available, and `shiki v0.1.0.0` when the build environment cannot provide one. This matters for support and operations: a copied version line is enough to connect a locally built binary or a Nix-built binary back to source.

The implementation follows `/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/cli/version-with-git-sha.md`. Cabal builds should get the commit hash from `.git/` at compile time through Template Haskell. Nix builds should get the commit hash through a GHC C preprocessor define because Nix source snapshots do not expose `.git/` inside the Haskell build.


## Progress

- [x] Add a version module for `shiki-cli` that exposes the Cabal package version, optional short commit hash, and final display text. Completed 2026-06-11T20:45:37Z.
- [x] Wire `shiki --version` into the top-level optparse-applicative parser without requiring a subcommand or database configuration. Completed 2026-06-11T20:45:37Z.
- [x] Add parser/unit coverage for the version text and the top-level informational option. Completed 2026-06-11T20:45:37Z.
- [x] Extend the Nix package overlay so Nix builds pass `GIT_HASH` to GHC for the `shiki-cli` package. Completed 2026-06-11T21:00:54Z.
- [x] Validate both build paths with Cabal and Nix commands and record the results in this plan. Completed 2026-06-11T21:02:56Z. `cabal build all`, `cabal test all`, `cabal run shiki -- --version`, `nix build .#shiki`, and `./result/bin/shiki --version` passed; `nix flake check` failed in an unrelated repository-wide treefmt check.


## Surprises & Discoveries

- `nix flake show --json` reported that the working tree is dirty and that the current flake already exposes `packages.default` through uncommitted files. Evidence:

```text
warning: Git tree '/Users/shinzui/Keikaku/bokuno/shiki' has uncommitted changes
...
"packages":{"doc":"The `packages` flake output contains packages that can be added to a shell using `nix shell`."
```

- `mori registry search githash` returned no local project for `githash`, so this plan relies on the user-provided spec for `githash` API details and on the Cabal dependency resolver for the package. Evidence:

```text
No projects matching 'githash'
```

- Importing Cabal's generated `Paths_shiki_cli` module from the `shiki-cli` library requires declaring it as both an `autogen-modules` and `other-modules` entry in the library stanza. Without that declaration, `cabal build shiki-cli` compiled the library but failed while linking the executable and test suite. Evidence:

```text
Undefined symbols for architecture arm64:
  "_shikizmclizm0zi1zi0zi0zminplace_Pathszushikizucli_version1_closure", referenced from:
      _shikizmclizm0zi1zi0zi0zminplace_ShikiziCliziVersion_appVersion1_info in libHSshiki-cli-0.1.0.0-inplace.a(Version.o)
```

- The first Nix-built binary printed `shiki v0.1.0.0` even though the evaluated derivation included `configureFlags = ["--ghc-option=-DGIT_HASH=\"dirty\""]`. Treating an empty Template Haskell hash as unavailable and then trying `GIT_HASH` fixed the Nix output. Evidence after the fix:

```text
$ ./result/bin/shiki --version
shiki v0.1.0.0 (dirty)
```

- `nix flake check` did not pass because the repository-wide treefmt check wants to reformat unrelated Haskell files outside this version feature. The feature-specific Nix package build and binary behavior passed, so this plan does not include the broad formatter churn. Evidence:

```text
checks.aarch64-darwin.treefmt failed
error: Cannot build '/nix/store/04zrd8xdzdmzjdpncvpzqxa4y172wmsy-treefmt-check.drv'.
...
> -    , testCase "first init container is cloud-sql-proxy" $ do
> +          (cfg ^. #defaultNamespace),
> +      testCase "first init container is cloud-sql-proxy" $ do
```


## Decision Log

- Decision: Put version formatting in a new `Shiki.Cli.Version` module in the `shiki-cli` library, not in `Main`.
  Rationale: The parser lives in the library module `Shiki.Cli`, and tests link against the library. A library module lets tests exercise formatting and parser behavior without running the executable.
  Date: 2026-06-11

- Decision: Add `--version` as a top-level informational option with `Options.Applicative.infoOption`, composed beside `helper`.
  Rationale: `infoOption` aborts parsing successfully with a message before a command is required, which matches the expected CLI behavior for `shiki --version`.
  Date: 2026-06-11

- Decision: Extend the existing working-tree Nix overlay files instead of designing a new Nix package path from scratch.
  Rationale: The current working tree already contains `flake.module.nix` and `nix/haskell-overlay.nix`, where `packages.default` and `packages.shiki` point at `haskellPackages.shiki-cli`. The version feature only needs to pass a CPP define through that existing `shiki-cli` derivation.
  Date: 2026-06-11

- Decision: Treat an empty hash from `githash` as missing and fall back to the Nix-provided `GIT_HASH` value.
  Rationale: In the Nix build, the derivation had the expected `--ghc-option=-DGIT_HASH="dirty"` flag, but the first binary still omitted the suffix. Trying the CPP fallback when the Template Haskell hash is empty preserves the Cabal behavior and makes the Nix behavior observable.
  Date: 2026-06-11


## Outcomes & Retrospective

Implemented `shiki --version` for both local Cabal builds and Nix builds. Cabal builds read the git commit through `githash` and produced output like `shiki v0.1.0.0 (ef61ae3)`. Nix builds receive `GIT_HASH` through the `shiki-cli` derivation and produced `shiki v0.1.0.0 (dirty)` for the current dirty working tree.

The main implementation lesson is that Cabal's generated `Paths_shiki_cli` module must be declared in the library stanza when the library imports it directly. The main validation gap is repository-wide formatting: `nix flake check` fails in `checks.aarch64-darwin.treefmt` because treefmt wants to reformat unrelated files that this plan intentionally did not change.


## Context and Orientation

The repository root is `/Users/shinzui/Keikaku/bokuno/shiki`. `mori show --full` identifies this project as `shinzui/shiki`, a Haskell application with two packages: `shiki-core`, the reusable library for configuration, persistence, Kubernetes, and analysis, and `shiki-cli`, the command-line executable package. The version feature belongs to `shiki-cli`.

The top-level CLI parser is in `shiki-cli/src/Shiki/Cli.hs`. The executable entry point in `shiki-cli/app/Main.hs` only imports `Shiki.Cli (runCli)` and calls `runCli`, so parser and option changes should happen in `Shiki.Cli`, not in `Main`. `Shiki.Cli` currently imports `Options.Applicative` as `Opt`, defines `parserInfo :: ParserInfo Options`, and builds `parserInfo` with:

```haskell
Opt.info
  (optionsParser <**> Opt.helper)
  ...
```

That parser currently requires a subcommand. There is no existing `--version`, `infoOption`, or version module in `shiki-cli` or `shiki-core`.

The Cabal package file is `shiki-cli/shiki-cli.cabal`. It declares package version `0.1.0.0`, uses `GHC2024`, and exposes library modules under the `library` stanza. Any new source module under `shiki-cli/src` must be added to the `exposed-modules` list so Cabal and downstream code can import it. The Cabal-generated module `Paths_shiki_cli` is available to the `shiki-cli` package and exports `version :: Data.Version.Version`, which should be used as the source of the base version string.

The test entry point is `shiki-cli/test/Spec.hs`, which builds a Tasty test group and imports individual test modules such as `Shiki.Cli.HelpSpec`. Parser tests in `shiki-cli/test/Shiki/Cli/HelpSpec.hs` use `Options.Applicative.execParserPure Opt.defaultPrefs (Opt.info parser Opt.idm) args` and inspect `Opt.Success`, `Opt.Failure`, or `Opt.CompletionInvoked`.

The Nix context already has uncommitted build wiring in the working tree. `flake.nix` imports `./flake.module.nix` only when that file exists. `flake.module.nix` defines a `haskellPackages` set from `pkgs.haskell.packages.ghc9124.override`, composes `inputs.haskell-nix.lib.haskellExtension`, imports `./nix/haskell-overlay.nix`, and exposes:

```nix
packages.shiki = haskellPackages.shiki-cli;
packages.default = haskellPackages.shiki-cli;
```

The overlay in `nix/haskell-overlay.nix` defines `shiki-core` and `shiki-cli` with `final.callCabal2nix`, `doJailbreak`, `dontCheck`, and `overrideCabal stageRootFiles`. `stageRootFiles` copies `CHANGELOG.md`, `LICENSE`, and `schema` into the build layout so Cabal data and doc paths resolve. This plan assumes those working-tree files remain part of the current implementation surface and extends them.

Template Haskell means Haskell code that runs at compile time to generate or embed values in the compiled program. The `githash` package provides `tGitInfoCwdTry`, a Template Haskell splice that tries to read `.git/` during compilation. CPP means the C preprocessor pass that GHC can run before compiling Haskell; it lets code test whether a compile-time macro such as `GIT_HASH` was provided. Nix builds generally build from source snapshots without a `.git/` directory, so Nix must pass a `GIT_HASH` macro to GHC while Cabal local builds can read `.git/`.


## Plan of Work

Milestone 1 adds a pure, testable version module to the `shiki-cli` library. At the end of this milestone, code can import `Shiki.Cli.Version` and ask for the Cabal package version, the optional short commit hash, and the final `shiki` display string. The acceptance check for this milestone is a focused Cabal build of `shiki-cli` and a unit test that can verify formatting without depending on the actual repository commit.

Create `shiki-cli/src/Shiki/Cli/Version.hs`. Enable `CPP` and `TemplateHaskell` at the top of the file. Export these names:

```haskell
module Shiki.Cli.Version
  ( appVersion,
    appVersionWithGit,
    formatVersionWithGit,
    gitCommitShort,
  )
where
```

Use `Paths_shiki_cli (version)`, `Data.Version (showVersion)`, `GitHash (GitInfo, giHash, tGitInfoCwdTry)`, and `Data.Text`. `appVersion :: Text` should be `Text.pack (showVersion version)`. Define `gitInfo :: Either String GitInfo` with `$$tGitInfoCwdTry`. Define `nixGitHash :: Maybe Text` with CPP:

```haskell
#ifdef GIT_HASH
nixGitHash = Just GIT_HASH
#else
nixGitHash = Nothing
#endif
```

Define `gitCommitShort :: Maybe Text` by preferring `gitInfo`; when it is `Right gi`, use `Text.take 7 (Text.pack (giHash gi))`; when it is `Left _`, use `Text.take 7 <$> nixGitHash`. Define `formatVersionWithGit :: Text -> Maybe Text -> Text` so tests can pass controlled inputs. It should produce `"shiki v" <> versionText` and append `" (" <> commit <> ")"` only when the commit argument is present and non-empty. Define `appVersionWithGit :: Text` as `formatVersionWithGit appVersion gitCommitShort`.

Edit `shiki-cli/shiki-cli.cabal`. Add `Shiki.Cli.Version` to the library `exposed-modules`. Add `githash ^>=0.1` to the library `build-depends`. The `githash` dependency belongs only in the library stanza because `Shiki.Cli.Version` is compiled there; the executable only depends on `shiki-cli`.

Milestone 2 wires the version module into the CLI parser. At the end of this milestone, `cabal run shiki -- --version` should print the version line and exit without asking for a subcommand, database connection, or environment. Edit `shiki-cli/src/Shiki/Cli.hs` to import `Shiki.Cli.Version (appVersionWithGit)` and `Data.Text qualified as Text` is already present. Change `parserInfo` so its parser composes both helper and a version option:

```haskell
(optionsParser <**> Opt.helper <**> versionOption)
```

Add a local or top-level helper in `Shiki.Cli`:

```haskell
versionOption :: Parser (a -> a)
versionOption =
  Opt.infoOption
    (Text.unpack appVersionWithGit)
    (Opt.long "version" <> Opt.help "Show version information")
```

Keep `versionOption` visible only inside `Shiki.Cli` unless tests need direct access. Because `infoOption` has type `String -> Mod OptionFields (a -> a) -> Parser (a -> a)`, composing it with `<**>` lets `--version` act like `--help`: it displays information and stops normal command parsing.

Milestone 3 adds tests. Create `shiki-cli/test/Shiki/Cli/VersionSpec.hs` and import it from `shiki-cli/test/Spec.hs`. Add it to the `other-modules` list in the `test-suite shiki-cli-test` stanza of `shiki-cli/shiki-cli.cabal`. Test `formatVersionWithGit` directly with at least three cases: no commit gives `shiki v0.1.0.0`, a seven-character commit gives `shiki v0.1.0.0 (a1b2c3d)`, and a longer commit is accepted only after the caller shortens it or, if `formatVersionWithGit` performs the guard itself, produces a seven-character suffix. The preferred design is to keep shortening in `gitCommitShort` and have `formatVersionWithGit` only format the value it receives; then the long-commit test should target a small helper only if one is added.

Also test top-level parser behavior. The current `parserInfo` is not exported from `Shiki.Cli`, so choose the smallest testable change: export `parserInfo` from `Shiki.Cli` in addition to `runCli`. Then `VersionSpec` can run:

```haskell
Opt.execParserPure Opt.defaultPrefs parserInfo ["--version"]
```

For `infoOption`, success is represented as `Opt.Failure failure`, not `Opt.Success`, because the parser aborts normal parsing with an informational message. Use `Opt.handleParseResult` only in an integration-style test if you want to observe stdout; for a unit test, inspect the rendered failure with `Opt.renderFailure failure "shiki"` and assert that the rendered text contains `"shiki v"` and `"0.1.0.0"`, and that the exit code is `ExitSuccess` from `System.Exit`.

Milestone 4 extends Nix so the same version code works when `.git/` is absent. Edit `flake.module.nix` to derive a short revision from the flake itself:

```nix
let
  gitRev = inputs.self.shortRev or "dirty";
  haskellPackages = pkgs.haskell.packages.ghc9124.override {
    overrides = pkgs.lib.composeExtensions
      (inputs.haskell-nix.lib.haskellExtension pkgs.haskell.lib.compose pkgs)
      (import ./nix/haskell-overlay.nix {
        inherit pkgs gitRev;
        inherit (inputs) kubernetes-api-src jose-jwt-src hoauth2-src;
      });
  };
in
```

Edit `nix/haskell-overlay.nix` to accept `gitRev` as an argument. Add a small override function:

```nix
  shikiVersionFlags = drv: {
    configureFlags = (drv.configureFlags or [ ]) ++ [
      "--ghc-option=-DGIT_HASH=\"${builtins.substring 0 7 gitRev}\""
    ];
  };
```

Then compose it into the `shiki-cli` derivation without dropping `stageRootFiles`:

```nix
  shiki-cli =
    dontCheck
      (overrideCabal (drv: (stageRootFiles drv) // (shikiVersionFlags drv))
        (doJailbreak (final.callCabal2nix "shiki-cli" ../shiki-cli { })));
```

This passes a Haskell string literal as the CPP macro. The escaped quotes are required because the Haskell code expects `GIT_HASH` to expand to a string-like value that can become `Text`.

Milestone 5 validates the end-to-end behavior. Build and test through Cabal first. Then build with Nix and run the Nix-built binary. The Cabal path proves `.git/` plus Template Haskell works; the Nix path proves CPP `GIT_HASH` works when the source snapshot does not include `.git/`.


## Concrete Steps

From `/Users/shinzui/Keikaku/bokuno/shiki`, inspect the current project state before editing:

```bash
mori show --full
git status --short --untracked-files=all
```

Expected relevant output is that `mori` shows packages `shiki-core` and `shiki-cli`, and `git status` may show pre-existing changes such as `flake.nix`, `flake.module.nix`, `nix/haskell-overlay.nix`, or `cabal.project`. Do not revert those changes.

Create and edit the Haskell version module and parser files:

```bash
$EDITOR shiki-cli/src/Shiki/Cli/Version.hs
$EDITOR shiki-cli/src/Shiki/Cli.hs
$EDITOR shiki-cli/shiki-cli.cabal
```

Add tests:

```bash
$EDITOR shiki-cli/test/Shiki/Cli/VersionSpec.hs
$EDITOR shiki-cli/test/Spec.hs
$EDITOR shiki-cli/shiki-cli.cabal
```

Extend Nix:

```bash
$EDITOR flake.module.nix
$EDITOR nix/haskell-overlay.nix
```

Run formatting:

```bash
nix fmt
```

Run Cabal build and tests:

```bash
cabal build shiki-cli
cabal test shiki-cli-test
```

Expected success should look like this in substance:

```text
Build profile: -w ghc-9.12.4 -O1
...
Building library for shiki-cli-0.1.0.0...
...
Running 1 test suites...
Test suite shiki-cli-test: PASS
```

Run the Cabal-built CLI:

```bash
cabal run shiki -- --version
```

Expected output when building inside this git checkout is:

```text
shiki v0.1.0.0 (abcdef1)
```

The seven characters will be the current commit prefix. If the working tree is in a state where `githash` cannot read `.git/`, acceptable fallback output is:

```text
shiki v0.1.0.0
```

Run the Nix build and Nix-built CLI:

```bash
nix build .#shiki
./result/bin/shiki --version
```

Expected output from a committed, clean flake build is:

```text
shiki v0.1.0.0 (abcdef1)
```

Expected output from a dirty working tree can be:

```text
shiki v0.1.0.0 (dirty)
```

If `dirty` is considered too noisy after testing, revise `flake.module.nix` to pass an empty string for dirty builds and update this plan's Decision Log with that choice.

Finally run the full validation set:

```bash
cabal build all
cabal test all
nix flake check
```


## Validation and Acceptance

The change is accepted when `shiki --version` works as a top-level option and does not require a subcommand. Running `cabal run shiki -- --version` from `/Users/shinzui/Keikaku/bokuno/shiki` must print one line beginning with `shiki v0.1.0.0`. In a normal git checkout it should include a parenthesized seven-character commit suffix, such as `shiki v0.1.0.0 (a1b2c3d)`.

The parser test must prove that `["--version"]` renders an informational success message, not a parse error asking for a command. The unit tests for `formatVersionWithGit` must prove the exact output with and without a commit suffix.

The Cabal build path is accepted when:

```bash
cabal build shiki-cli
cabal test shiki-cli-test
cabal run shiki -- --version
```

all succeed, and the final command prints the version line.

The Nix build path is accepted when:

```bash
nix build .#shiki
./result/bin/shiki --version
```

succeeds and the final command prints a version line with either a short commit suffix or the explicit dirty fallback chosen in `flake.module.nix`. This demonstrates that the Haskell fallback from Template Haskell to the CPP `GIT_HASH` macro works in the Nix build.

The repository-level validation is accepted when:

```bash
cabal build all
cabal test all
nix flake check
```

complete successfully. If `nix flake check` only checks formatting and pre-commit hooks in this flake, that is still useful but not sufficient by itself; `nix build .#shiki` remains the required Nix package validation.


## Idempotence and Recovery

The Haskell edits are additive and can be repeated safely. If `Shiki.Cli.Version` already exists when implementation starts, read it first and adapt it to the interfaces in this plan instead of replacing unrelated user changes. If adding `parserInfo` to the `Shiki.Cli` export list exposes too much surface, keep the export because it is test-only and stable; do not add a second duplicate parser just for tests.

The Nix edits must preserve any existing uncommitted build wiring. Do not delete `flake.module.nix`, `nix/haskell-overlay.nix`, or the project-specific inputs in `flake.nix`. If `nix build .#shiki` fails because a dependency is missing from the overlay, first read the error and extend the existing overlay with the missing dependency; do not switch to an unrelated Nix build system in the same change.

If the CPP macro quoting is wrong, GHC will usually fail with a parse error near `GIT_HASH` or a type error in `Shiki.Cli.Version`. Recover by inspecting the generated GHC option in the Nix build log and ensure the option has this shape:

```text
--ghc-option=-DGIT_HASH="abcdef1"
```

If the `githash` dependency cannot resolve under Cabal, run `cabal update` if the package index is stale. If it still cannot resolve, record the exact solver error in Surprises & Discoveries and pin a compatible version in `cabal.project` only as narrowly as necessary.


## Interfaces and Dependencies

The new module `shiki-cli/src/Shiki/Cli/Version.hs` must expose:

```haskell
appVersion :: Text
gitCommitShort :: Maybe Text
formatVersionWithGit :: Text -> Maybe Text -> Text
appVersionWithGit :: Text
```

`appVersion` is the package version from `Paths_shiki_cli.version`. `gitCommitShort` is the best available seven-character commit identifier, preferring `githash` Template Haskell and falling back to the CPP `GIT_HASH` macro. `formatVersionWithGit` is pure formatting for tests. `appVersionWithGit` is the final string shown by the CLI.

`shiki-cli/src/Shiki/Cli.hs` must continue to expose `runCli` and should also expose `parserInfo` for parser tests:

```haskell
module Shiki.Cli
  ( runCli,
    parserInfo,
  )
where
```

It must define:

```haskell
versionOption :: Parser (a -> a)
```

using `Options.Applicative.infoOption`.

The Cabal dependency to add is:

```cabal
, githash ^>=0.1
```

in the `library` stanza of `shiki-cli/shiki-cli.cabal`. The new test module must be listed under the `test-suite shiki-cli-test` `other-modules`.

The Nix interface is the argument `gitRev` passed from `flake.module.nix` into `nix/haskell-overlay.nix`. `flake.module.nix` should compute `gitRev` from `inputs.self.shortRev or "dirty"`. `nix/haskell-overlay.nix` should add a `--ghc-option=-DGIT_HASH=...` configure flag only to `shiki-cli`, because that is the package that compiles `Shiki.Cli.Version`.
