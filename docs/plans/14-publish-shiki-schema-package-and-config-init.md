---
id: 14
slug: publish-shiki-schema-package-and-config-init
title: "Publish shiki schema package and config init"
kind: exec-plan
created_at: 2026-06-11T19:53:51Z
intention: "intention_01ktw3z1brenz9ccn25z4rrh7k"
---

# Publish shiki schema package and config init

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

After this change, an operator can run `shiki config init` inside any service repository
and get a `shiki.dhall` that validates without depending on a local checkout of the shiki
source tree. The generated file imports shiki's configuration schema from GitHub at a
well-known raw URL:

```text
https://raw.githubusercontent.com/shinzui/shiki/<tag-or-commit>/schema/package.dhall
```

The important outcome is portability. A service repository such as
`/Users/shinzui/Keikaku/work/microtan/mls-service-v2-master` should not need
`./shiki-core/dhall/ProjectConfig.dhall`, an absolute path into a developer's shiki clone,
or a hand-copied inline schema. It should contain only a local `shiki.dhall` whose schema
contract comes from the published shiki repository. The work is complete when `shiki config
init --schema-ref <ref>` creates a valid file, `dhall type` accepts that file from outside
the shiki checkout, and `shiki config show` reads it.


## Progress

- [x] M1: Move the project config Dhall schema to a root `schema/` package. Completed 2026-06-11T20:15:36Z.
  - [x] Create `schema/Environment.dhall`, `schema/ProjectConfig.dhall`, and
    `schema/package.dhall`.
  - [x] Update Cabal data/extra-source file globs so the moved schema is packaged.
  - [x] Remove or replace stale `shiki-core/dhall/Environment.dhall` and
    `shiki-core/dhall/ProjectConfig.dhall` references.
- [x] M2: Add `shiki config init` that writes a portable, URL-importing `shiki.dhall`. Completed 2026-06-11T20:15:36Z.
  - [x] Add parser and command handling for `shiki config init`.
  - [x] Generate a file that imports
    `https://raw.githubusercontent.com/shinzui/shiki/<ref>/schema/package.dhall`.
  - [x] Refuse to overwrite an existing `shiki.dhall`.
- [x] M3: Update examples, docs, and embedded help to teach the schema package URL. Completed 2026-06-11T20:15:36Z.
  - [x] Update `shiki.dhall.example`.
  - [x] Update `README.md` and `docs/user/*.md`.
  - [x] Update `shiki-cli/data/help/*.md` if the in-terminal topics mention config setup.
- [x] M4: Add validation tests that catch non-portable schemas. Completed 2026-06-11T20:15:36Z.
  - [x] Test that the generated config type-checks with Dhall from an external temporary
    directory.
  - [x] Test that `loadProjectConfig` can load a config using the package import shape.
  - [x] Test overwrite behavior for `config init`.


## Surprises & Discoveries

- Discovery: The current `shiki.dhall.example` imports `./shiki-core/dhall/Environment.dhall`.
  That only works when `shiki.dhall` lives in the shiki repository root. It is wrong for the
  intended project-local use case where `shiki.dhall` lives in another service repository.
  Evidence: `shiki.dhall.example` currently contains:

```dhall
let Environment = ./shiki-core/dhall/Environment.dhall
```

- Discovery: The current test fixtures for project config use unannotated records, so they
  do not prove that a service repo can import the schema contract from a stable location.
  Evidence: `shiki-core/test/Shiki/Project/ConfigSpec.hs` writes a `shiki.dhall` sample that
  is just a record literal and never imports `ProjectConfig.dhall`.

- Discovery: Cabal accepts `../schema/*.dhall` in `shiki-core/shiki-core.cabal`, but warns
  that relative paths outside the package source tree will not work for `sdist` tarballs.
  The root schema still works for the planned GitHub raw publication path because it is a
  repository-level artifact. Evidence from `cabal test shiki-core`:

```text
Warning: [relative-path-outside] 'data-files: ../schema/*.dhall' is a relative
path outside of the source tree. This will not work when generating a tarball
with 'sdist'.
Warning: [relative-path-outside] 'extra-source-files: ../schema/*.dhall' is a
relative path outside of the source tree. This will not work when generating a
tarball with 'sdist'.
```


## Decision Log

- Decision: Publish the Dhall schema as a root-level `schema/package.dhall` package.
  Rationale: A root-level package gives users one obvious import target and avoids exposing
  package-internal source layout such as `shiki-core/dhall`. `package.dhall` reexports both
  `ProjectConfig` and `Environment`, so a generated config can import one URL and then refer
  to `Schema.ProjectConfig` and `Schema.Environment`.
  Date: 2026-06-11

- Decision: `shiki config init` must generate a GitHub raw URL import, not a local path or
  inline schema.
  Rationale: The feature is meant for arbitrary service repositories. Local paths to the
  shiki source checkout are not portable, and inline schema copies drift silently as the
  schema evolves.
  Date: 2026-06-11

- Decision: The first implementation should support an explicit `--schema-ref REF` option
  and use the same URL format for its default.
  Rationale: The URL path requires a Git ref. Tests can provide a deterministic ref without
  depending on the current release process, and release builds can later choose a tag or
  commit as the default ref. This keeps the command shape correct while avoiding a network
  lookup to discover "latest".
  Date: 2026-06-11

- Decision: The generated initial config should contain placeholder database URLs, not
  secrets or environment-variable imports.
  Rationale: `config init` must work in a clean checkout with no secrets available. Dhall
  `env:` imports fail if the environment variable is unset, so they are a bad default for a
  generated file whose first job is to type-check. Operators can replace the placeholder
  strings with real URLs or Dhall environment imports after initialization.
  Date: 2026-06-11

- Decision: Keep the public project config schema as a root repository package even though
  Cabal warns about including it from the `shiki-core` subpackage with `../schema/*.dhall`.
  Rationale: The user-facing publication mechanism in this plan is GitHub raw URLs, not
  Hackage `sdist` contents. Moving the Cabal package root would be a larger packaging
  restructure outside this plan, and keeping compatibility shims in `shiki-core/dhall` would
  preserve the package-internal import path this plan is meant to retire.
  Date: 2026-06-11


## Outcomes & Retrospective

Implemented 2026-06-11. Operators can now run `shiki config init --schema-ref REF` to create
a project-local `shiki.dhall` that imports
`https://raw.githubusercontent.com/shinzui/shiki/REF/schema/package.dhall` and annotates the
file as `Schema.ProjectConfig`. The command refuses to overwrite an existing file. The
public schema files now live at `schema/Environment.dhall`, `schema/ProjectConfig.dhall`,
and `schema/package.dhall`; the old project config schema files no longer live under
`shiki-core/dhall`.

Validation succeeded with:

```text
XDG_CACHE_HOME=/private/tmp/shiki-dhall-cache dhall type --file schema/package.dhall
{ Environment : Type, ProjectConfig : Type }
```

```text
cabal test shiki-core
All 32 tests passed
```

```text
cabal test shiki-cli
All 38 tests passed
```

```text
cabal test all
exit code 0
```

Manual acceptance from a temporary directory created `shiki.dhall`, found the expected raw
GitHub URL, and failed the second init with:

```text
shiki: shiki.dhall already exists; refusing to overwrite
```

The remaining caveat is that the current multi-package Cabal layout warns that
`../schema/*.dhall` is outside the `shiki-core` source tree for `sdist`; a future packaging
plan should decide whether to move package roots, add a separate schema package, or stop
advertising Cabal source distributions as a schema publication vehicle.


## Context and Orientation

`shiki.dhall` is a project-local file. "Project-local" means the file is placed in the
service repository where an operator runs shiki, not necessarily in the shiki source
repository. The CLI discovers it by walking up from the current working directory until it
finds a file named `shiki.dhall`. The discovery and environment selection code is in
`shiki-cli/src/Shiki/Cli/Project.hs`.

The Haskell data model for project configuration lives in
`shiki-core/src/Shiki/Project/Config.hs`. The important types are:

```haskell
data Environment = Environment
  { databaseUrl :: !Text
  }

data ProjectConfig = ProjectConfig
  { environments :: !(Map Text Environment),
    defaultEnvironment :: !Text
  }
```

The Dhall loader is in `shiki-core/src/Shiki/Project/Config/Dhall.hs`. It currently uses
`Dhall.inputFile Dhall.auto`, so the external `shiki.dhall` file must evaluate to something
that Dhall can decode as `ProjectConfig`.

The current Dhall schema files are under `shiki-core/dhall/`:

```text
shiki-core/dhall/Environment.dhall
shiki-core/dhall/ProjectConfig.dhall
```

That location is package-internal and should stop being the public import path. This plan
moves the public project config schema to:

```text
schema/Environment.dhall
schema/ProjectConfig.dhall
schema/package.dhall
```

`schema/package.dhall` is a Dhall package file. In this plan, "package file" means a Dhall
record that reexports related schemas under stable field names. The intended content is:

```dhall
{ Environment = ./Environment.dhall
, ProjectConfig = ./ProjectConfig.dhall
}
```

An external `shiki.dhall` generated by `shiki config init` should then follow this shape:

```dhall
let Schema =
      https://raw.githubusercontent.com/shinzui/shiki/<tag-or-commit>/schema/package.dhall

let mkEnv = \(url : Text) -> { databaseUrl = url } : Schema.Environment

in    { environments =
          toMap
            { staging = mkEnv "postgresql://user@host/staging"
            , prod = mkEnv "postgresql://user@host/prod"
            }
      , defaultEnvironment = "staging"
      }
    : Schema.ProjectConfig
```

The command-line parser is in `shiki-cli/src/Shiki/Cli.hs`. Today the `ConfigCommand` sum
type only has `ConfigShow`, and `configSubparser` only exposes `shiki config show`.
`shiki config init` belongs in the same command group. `config show` intentionally does not
connect to Postgres; `config init` should also avoid database and Kubernetes access.

Tests already cover project config loading in `shiki-core/test/Shiki/Project/ConfigSpec.hs`
and environment routing in `shiki-cli/test/Shiki/Cli/EnvRoutingSpec.hs`. Those tests must be
strengthened so they fail if a config only works from the shiki repository root.


## Plan of Work

Milestone 1 moves the public schema. Create a new root-level `schema/` directory and move
the project configuration Dhall files there. The public package must be
`schema/package.dhall`, and it must reexport `Environment` and `ProjectConfig`. Update
`schema/ProjectConfig.dhall` so its relative import points to `./Environment.dhall`.
After this milestone, `dhall type --file schema/package.dhall` should succeed from the shiki
repository root. Update `shiki-core/shiki-core.cabal` so source distributions and installed
packages include `../schema/*.dhall` or another correct repository-relative package entry;
do not leave Cabal pointing only at `shiki-core/dhall/*.dhall` if those files are gone.

Milestone 2 adds `shiki config init`. In `shiki-cli/src/Shiki/Cli.hs`, extend
`ConfigCommand` with a new constructor, for example:

```haskell
data ConfigCommand
  = ConfigShow
  | ConfigInit !ConfigInitOptions
```

Create a small module such as `shiki-cli/src/Shiki/Cli/ConfigInit.hs` rather than putting
all rendering logic in `Shiki.Cli`. The module should export:

```haskell
data ConfigInitOptions = ConfigInitOptions
  { schemaRef :: !Text,
    outputPath :: !FilePath,
    defaultEnvironment :: !Text
  }

runConfigInit :: ConfigInitOptions -> IO ()
renderProjectConfig :: ConfigInitOptions -> Text
```

The exact option names can be adjusted to fit the parser style, but the command must support
at least `--schema-ref REF` and `--output PATH`; `--default-environment NAME` is useful but
can default to `staging`. The default output path is `shiki.dhall`. The generated import
must be:

```text
https://raw.githubusercontent.com/shinzui/shiki/<REF>/schema/package.dhall
```

The plan intentionally does not require `config init` to contact GitHub to discover the
latest tag. The command should use a compiled-in default ref, and tests can pass
`--schema-ref test-ref`. During a release, the compiled default should be set to a tag or
commit that exists on GitHub. If no release-ref mechanism exists yet, use a named constant in
`ConfigInit.hs`, document it as temporary, and make `--schema-ref` the tested path.

`runConfigInit` should refuse to overwrite an existing output file. Print a clear stderr
message and exit non-zero, for example:

```text
shiki: shiki.dhall already exists; refusing to overwrite
```

Milestone 3 updates all examples and docs. Replace local schema imports in
`shiki.dhall.example` and `docs/user/project-config.md` with the GitHub raw package import.
Update `docs/user/getting-started.md` so the first-time flow says to run `shiki config init`
instead of copying an example by hand. Update `README.md` and `docs/user/commands.md` to
list `shiki config init`. Update embedded help in `shiki-cli/data/help/env.md` or add a
new config help topic if that is the local pattern; keep the in-terminal help consistent
with `docs/user`.

Milestone 4 adds tests that prove portability. In `shiki-core/test/Shiki/Project/ConfigSpec.hs`,
add a test that writes a temporary schema package and a separate temporary service repository,
then writes a `shiki.dhall` in the service repository that imports the package by URL or by
an equivalent local `file://`/absolute path standing in for the GitHub raw URL. The point of
the test is that the config must not rely on relative paths from the service repo back into
`shiki-core/dhall`. In `shiki-cli/test`, add a `ConfigInitSpec` that checks
`renderProjectConfig` exactly and `runConfigInit` file creation/refusal behavior. Register
the new module in `shiki-cli/shiki-cli.cabal` and `shiki-cli/test/Spec.hs`.


## Concrete Steps

Run all commands from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/shiki
```

First, create the root schema package:

```bash
mkdir -p schema
git mv shiki-core/dhall/Environment.dhall schema/Environment.dhall
git mv shiki-core/dhall/ProjectConfig.dhall schema/ProjectConfig.dhall
```

Create `schema/package.dhall` with:

```dhall
{ Environment = ./Environment.dhall
, ProjectConfig = ./ProjectConfig.dhall
}
```

Edit `schema/ProjectConfig.dhall` so it still says:

```dhall
let Environment = ./Environment.dhall

in  { environments : List { mapKey : Text, mapValue : Environment }
    , defaultEnvironment : Text
    }
```

Then validate the package directly:

```bash
XDG_CACHE_HOME=/private/tmp/shiki-dhall-cache dhall type --file schema/package.dhall
```

Expected output should be a record type describing the package fields, similar to:

```text
{ Environment : Type, ProjectConfig : Type }
```

Next, add `shiki-cli/src/Shiki/Cli/ConfigInit.hs`, wire it into
`shiki-cli/src/Shiki/Cli.hs`, and add it to `shiki-cli/shiki-cli.cabal`. The parser should
accept:

```bash
shiki config init --schema-ref test-ref --output shiki.dhall
```

The generated file should contain the URL:

```text
https://raw.githubusercontent.com/shinzui/shiki/test-ref/schema/package.dhall
```

For tests that must avoid network access, make the rendering function pure and test the URL
string exactly. For Dhall type-check tests, use a locally written package file as the import
target; do not require GitHub network access in the test suite.

Update documentation and embedded help, then run:

```bash
cabal test shiki-core
cabal test shiki-cli
cabal test all
```

Before committing implementation work, check for bare Markdown fences in this plan:

```bash
awk 'BEGIN{inside=0} /^```/ { if (!inside && $0 == "```") print FILENAME ":" FNR ": bare opening fence"; inside=!inside }' docs/plans/14-publish-shiki-schema-package-and-config-init.md
```

The command should print nothing.


## Validation and Acceptance

The schema package is accepted when this command succeeds from the shiki repository root:

```bash
XDG_CACHE_HOME=/private/tmp/shiki-dhall-cache dhall type --file schema/package.dhall
```

The generated config behavior is accepted when this command, run in an empty temporary
directory, creates a `shiki.dhall` with a GitHub raw schema package import:

```bash
tmp=$(mktemp -d)
cd "$tmp"
cabal --project-dir=/Users/shinzui/Keikaku/bokuno/shiki run shiki -- config init --schema-ref test-ref
grep -F 'https://raw.githubusercontent.com/shinzui/shiki/test-ref/schema/package.dhall' shiki.dhall
```

Expected output from the `grep` command:

```text
      https://raw.githubusercontent.com/shinzui/shiki/test-ref/schema/package.dhall
```

Overwrite protection is accepted when a second init in the same directory fails without
modifying the file:

```bash
cabal --project-dir=/Users/shinzui/Keikaku/bokuno/shiki run shiki -- config init --schema-ref test-ref
```

Expected stderr should contain:

```text
shiki: shiki.dhall already exists; refusing to overwrite
```

The external repository scenario is accepted when a service repo `shiki.dhall` imports the
schema package URL and `shiki config show` can parse it. For automated tests, do not depend
on GitHub availability; use a local test package import that has the same package structure
as `schema/package.dhall`. For manual release verification, run against a real tag or commit
that has been pushed to `https://github.com/shinzui/shiki`:

```bash
shiki config init --schema-ref <tag-or-commit>
dhall type --file shiki.dhall
shiki config show
```

All Haskell tests must pass:

```bash
cabal test shiki-core
cabal test shiki-cli
cabal test all
```

The feature is not complete if the generated file imports `./shiki-core/dhall/...`, uses an
absolute path into a developer machine, or duplicates the schema inline.


## Idempotence and Recovery

Moving files with `git mv` is safe to repeat only if the source files still exist. If an
implementation attempt is interrupted after the move, inspect `git status --short` and
continue from the actual file locations rather than moving them again.

`shiki config init` must be idempotent from an operator-safety perspective: running it once
creates `shiki.dhall`; running it again without an explicit overwrite option fails and leaves
the existing file unchanged. If a partially written file is possible, write to a temporary
file in the same directory and then atomically rename it to the final path.

Dhall cache warnings can occur in the sandbox if `~/.cache/dhall-haskell` is not writable.
Use a sandbox-local cache when validating Dhall:

```bash
XDG_CACHE_HOME=/private/tmp/shiki-dhall-cache dhall type --file schema/package.dhall
```

Do not edit external service repositories as part of implementing this plan. The acceptance
scenario can use a temporary directory. Real service repositories should be initialized only
after this feature is implemented and the schema ref points at a pushed GitHub tag or commit.


## Interfaces and Dependencies

The public Dhall schema interface at the end of this plan is:

```text
schema/package.dhall
schema/Environment.dhall
schema/ProjectConfig.dhall
```

`schema/package.dhall` reexports:

```dhall
{ Environment = ./Environment.dhall
, ProjectConfig = ./ProjectConfig.dhall
}
```

The generated external config imports that package and annotates its final expression as
`Schema.ProjectConfig`. It should use `Schema.Environment` for helper functions such as
`mkEnv`.

The Haskell loader remains `Shiki.Project.Config.Dhall.loadProjectConfig :: FilePath -> IO
ProjectConfig`. This plan should not change the Haskell config data model unless the schema
itself changes; it only changes how users import the Dhall schema.

The CLI interface adds:

```text
shiki config init [--schema-ref REF] [--output PATH]
```

`--schema-ref REF` selects the `<tag-or-commit>` segment in the GitHub raw URL. `--output
PATH` defaults to `shiki.dhall`. `--default-environment NAME`, if implemented, defaults to
`staging`. The generated file should include valid placeholder database URL strings such as
`postgresql://replace-me/staging` and `postgresql://replace-me/prod`; it must not require
secrets on the command line.

The implementation uses existing dependencies already present in `shiki-cli`: `base`,
`directory`, `filepath`, `optparse-applicative`, and `text`. No network client is required
for `config init`; it writes a URL string and lets Dhall resolve it when the user validates
or loads the config.

Commits implementing this plan must include:

```text
ExecPlan: docs/plans/14-publish-shiki-schema-package-and-config-init.md
Intention: intention_01ktw3z1brenz9ccn25z4rrh7k
```


## Revision Notes

Created 2026-06-11 to repair the portability gap in project-local `shiki.dhall`
configuration. The plan specifically rejects local checkout schema imports and inline
schema copies in favor of a root `schema/package.dhall` published through GitHub raw URLs.
