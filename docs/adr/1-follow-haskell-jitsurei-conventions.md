# ADR 1: Follow the haskell-jitsurei conventions

Status: Accepted

Date: 2026-09-11


## Context

shiki adopted the author's Haskell pattern catalog, haskell-jitsurei
(`mori://shinzui/haskell-jitsurei`), when the project started in May 2026. The decisions
were recorded in the Decision Logs of
[EP-1](../plans/1-service-configuration-model-and-dhall-loader.md) and the
[job-runner MasterPlan](../masterplans/1-microservice-job-runner-with-postgres-backed-run-history.md).

The catalog revised its core guidance on 2026-07-24. The earlier version enabled
`PackageImports` project-wide and imported generic-lens's `Data.Generics.Labels ()` from the
project prelude. The current version confines `PackageImports` to the prelude module and
requires each module that uses `#label` lenses to import the labels module itself. The
reason is that `Data.Generics.Labels` carries an orphan `IsLabel` instance. An orphan
imported from the prelude reaches every module in the project, and it breaks libraries that
define their own `IsLabel` instances.

By September 2026, shiki had drifted from the catalog in those two places. It also still
had prefixed record fields read with selector functions in two modules, and it had not
adopted the catalog's CLI patterns for help width, shell completions, and option groups.
The first tagged release (`shiki-cli` and `shiki-core` 0.1.0.0) needed one stated convention
that the published source actually follows.
[EP-16](../plans/16-adopt-haskell-jitsurei-conventions-for-the-initial-release.md) brought the
tree into line.


## Decision

shiki follows these catalog standards:

- Haskell Core Standards (`mori://shinzui/haskell-jitsurei/docs/core-standards`). GHC 9.12 or
  newer (encoded as `base >=4.21`, with `tested-with: GHC ==9.12.4`), `GHC2024`, and one
  `common common` Cabal stanza imported by every component. Its mandatory default extensions
  are `DeriveAnyClass`, `DuplicateRecordFields`, `OverloadedLabels`, and
  `OverloadedStrings`. Qualified imports use the postpositive form.
- Custom Prelude (`mori://shinzui/haskell-jitsurei/docs/core-custom-prelude`).
  `Shiki.Prelude` (`shiki-core/src/Shiki/Prelude.hs`) is the only module with
  package-qualified imports and the only one that enables `PackageImports`, which it does
  with a pragma. It does not import `Data.Generics.Labels ()`.
- Record Patterns (`mori://shinzui/haskell-jitsurei/docs/core-record-patterns`). Fields have
  no type-name prefixes, are strict, and are read with `^. #field` and updated with lens
  setters. Every `deriving` clause names its strategy.

shiki also follows the catalog's CLI patterns for help topics, terminal-aware help width,
shell completion generation (a `shiki completions` subcommand whose scripts call `shiki` by
name), option groups, fzf integration, git-SHA version output, and agent assist commands.

These exceptions stand:

- `MultilineStrings` is a project-wide default extension. The catalog allows extra
  project-wide extensions when a documented pattern needs them, and shiki uses `"""` literals.
- Record-update syntax is allowed on third-party types that have no `Generic` instance, or
  whose library documents update-a-default construction. Examples are
  `(proc cmd args) { env = … }` from `System.Process` and baikai's `_Model { … }` and
  `_Context { … }` defaults. The lens-update rule applies to shiki's own records.
- `generic-lens` is bounded `>=2.2 && <2.4` rather than the catalog's `^>=2.3`. The Nix
  release build uses generic-lens 2.2.2.0 and cabal resolves 2.3.0.0, so the bound admits
  both versions that are actually built.

These catalog patterns are deliberately not adopted, because shiki does not meet their
preconditions:

- the Servant API patterns (shiki has no HTTP server);
- stdin integration and copy to clipboard;
- command aliases (shiki has no user-scope config file);
- hierarchical Dhall config (`shiki.dhall` is a single project scope);
- per-command agent configuration (shiki has one agent-launching command);
- the skill and agent registry.


## Consequences

- A new module that uses `#label` lenses must add `import Data.Generics.Labels ()` itself.
  The compiler will not always catch a missing import, because orphan instances are visible
  transitively. The check in EP-16's Concrete Steps (Milestone 2) compares the files that
  use labels with the files that import the module. It flags `#…` text inside string
  literals too, such as the `#compdef` line of the Zsh completion script. Such hits are
  false positives.
- Package-qualified imports belong only in `Shiki.Prelude`. Elsewhere, write
  `import Data.Text qualified as Text` without a package name. If two dependencies ever
  expose the same module, drop the dependency the component does not need. If both are
  genuinely needed, add a per-file `PackageImports` pragma with a comment explaining why.
- Records read through labels need a `Generic` instance. Test modules that do not import
  `Shiki.Prelude` get `(^.)` with `import Shiki.Prelude ((^.))`.
- The build is warning-free under the shared `-Wall` settings. Keep it that way. Name
  locals so they do not shadow lens names re-exported by the prelude, or plain-word field
  names in the same module.
- Changing the Cabal bounds does not change the Nix build. `nix/haskell-overlay.nix` builds
  both packages with `doJailbreak`, which ignores bounds, and the Nix package set can differ
  from what cabal resolves. When choosing a bound, check both.
- When the catalog changes, adopt the change in a new ExecPlan that revises this ADR,
  rather than drifting silently.
