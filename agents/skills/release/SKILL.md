---
name: release
description: Release shiki-core and shiki-cli to Hackage following PVP, with a shared version, annotated tag, and GitHub release.
argument-hint: "[major|minor|patch]"
disable-model-invocation: true
allowed-tools: Read, Bash, Edit, Glob, Grep, Write, AskUserQuestion
---

# Shiki Release Skill

Release the two shiki packages to [Hackage](https://hackage.haskell.org/)
following the Haskell **PVP** (`A.B.C.D`). The packages share one version and
are released together under a single git tag.

## Versioning strategy

Both packages carry the **same version number** and are released together. A
single annotated git tag `v<version>` marks each release.

The PVP version format is `A.B.C.D`:

- `A.B` — **major**: breaking API changes (removed/renamed exports, changed
  types or semantics).
- `C` — **minor**: backwards-compatible API additions (new exports, modules,
  instances).
- `D` — **patch**: bug fixes, docs, internal-only or performance changes.

Increment:

- **major** → increment `B`, reset `C` and `D` to `0` (`0.2.0.1` → `0.3.0.0`)
- **minor** → increment `C`, reset `D` to `0` (`0.2.0.1` → `0.2.1.0`)
- **patch** → increment `D` (`0.2.0.1` → `0.2.0.2`)

Note the root `CHANGELOG.md` currently references "Semantic Versioning"; for
Hackage releases the version **bump is decided by PVP** as above. The Keep a
Changelog *format* (the `## [Unreleased]` section and dated version headings)
is kept as-is.

## Packages (in dependency order)

Publish in this order — dependencies first:

1. **shiki-core** (`shiki-core/`) — core library; no internal package deps.
2. **shiki-cli** (`shiki-cli/`) — library + the `shiki` executable; depends on
   `shiki-core`.

Both are released to Hackage. There are no packages that are *excluded* from
release, but note that these **components** ship *inside* the two packages and
are not separate Hackage artifacts:

- `shiki-run-once` — the example executable in `shiki-core`.
- `shiki-core-test`, `shiki-cli-test` — the test suites.

## ⚠️ Prerequisites — read before your first release

Hackage will **reject** an upload whose dependency solution cannot be satisfied
from Hackage alone. This repo is currently **not** in that state, so these must
be resolved before any `cabal upload` can succeed. Do NOT attempt to publish
until they are fixed; if you discover any of them still present, stop and
report rather than uploading.

1. **`source-repository-package` git forks in `cabal.project`.** The build
   currently pins several dependencies to git (`shinzui/hasql-migration`,
   `kazu-yamamoto/crypton`, `jappeace/ram`, `codedownio/kubernetes-api`,
   `tekul/jose-jwt`, `shinzui/hoauth2`) plus `allow-newer` / `constraints`
   relaxations. Hackage cannot install a package that needs these. Each such
   dependency must be available on Hackage at a version this project can build
   against before release.
2. **Non-Hackage dependencies.** Confirm every `build-depends` entry
   (`baikai*`, `ephemeral-pg`, `kubernetes-api`, …) is published on Hackage.
   Any that are not must be published first, or the packages that use them
   cannot be released.
3. **Files referenced outside the package directory.** Both cabals point at
   paths above their own directory: `license-file: ../LICENSE`,
   `extra-doc-files: ../CHANGELOG.md`, and (in `shiki-core`)
   `extra-source-files: ../schema/*.dhall`. `cabal sdist` does **not** include
   files outside the package directory, and Hackage rejects `../` paths. Before
   releasing, arrange for a `LICENSE` (and the needed docs/schema) to live
   inside each package directory (e.g. copy or symlink into `shiki-core/` and
   `shiki-cli/`) and update the cabal fields to package-local paths. Verify
   with `cabal sdist` + inspecting the tarball that the license and changelog
   are present.
4. **Internal dependency bound.** `shiki-cli.cabal` currently depends on
   `shiki-core` with **no version bound**. Hackage requires bounds. This skill
   adds a PVP bound during the release (see step 3).

If any prerequisite is unresolved, complete steps 1–5 (version bumps,
changelog, build/test/check, commit, tag, GitHub release) but **stop before the
Hackage upload** in step 6 and tell the user what remains.

## Arguments

`$ARGUMENTS` is optional:

- `major`, `minor`, or `patch` — forces the bump level.
- If omitted, infer the bump level from the changes (step 2).

## Steps

### 1. Determine what changed since the last release

- Read the current version from `shiki-core/shiki-core.cabal` (both packages
  share it; cross-check `shiki-cli/shiki-cli.cabal`).
- Find the latest git tag matching `v*`: `git tag --list 'v*' | sort -V | tail -1`.
- **First release:** if there are no `v*` tags, this is the initial release.
  The current cabal version (`0.1.0.0`) has never been published — if it is
  still unreleased you may publish it *as-is* (no bump), otherwise bump per
  step 2. Use `git log --oneline` over the full history for the changelog.
- **Subsequent releases:** run `git log --oneline <last-tag>..HEAD`. If there
  are no commits since the last tag, tell the user there is nothing to release
  and stop.

Present a summary: current version, last tag (or "none — first release"),
commit count since last release, and which package directories changed.

### 2. Determine the next version using PVP

- If `$ARGUMENTS` is `major` / `minor` / `patch`, use it.
- Otherwise analyze commits (Conventional Commits prefixes help):
  - `feat!:`, `BREAKING CHANGE`, "remove"/"rename"/"change type" → **major**
  - `feat:`, "add"/"new export"/"new module" → **minor**
  - `fix:`, `docs:`, `refactor:`, `chore:`, "internal"/"perf" → **patch**
- Present the proposed bump and the resulting version, and **ask the user to
  confirm** before proceeding.

### 3. Update versions, internal bounds, and the changelog

**Versions** — set the new version in both cabals:

- `shiki-core/shiki-core.cabal`
- `shiki-cli/shiki-cli.cabal`

Verify both read the target version before committing (a core bump may have
happened mid-cycle so a downstream consumer could raise its lower bound).

**Internal dependency bound** — in `shiki-cli/shiki-cli.cabal`, set the
`shiki-core` dependency to a PVP bound matching the new version in **both** the
`library` and the `test-suite shiki-cli-test` sections:

```
shiki-core ^>=A.B.C.D
```

**Changelog** — this repo has one root `CHANGELOG.md` (Keep a Changelog):

- Rename the `## [Unreleased]` section to `## [A.B.C.D] - YYYY-MM-DD` (today's
  date), and add a fresh empty `## [Unreleased]` above it.
- Group entries under `### Added` / `### Changed` / `### Fixed` / `### Removed`
  as appropriate; include only categories with entries.
- Summarize commits since the last release into the new version section.

Show the user **all** changes (both version bumps, the `shiki-core` bound in
`shiki-cli`, and the changelog entries) for review before committing.

### 4. Format, build, test, and check

Run each; stop and fix on any failure before continuing:

- `nix fmt` — format (treefmt + fourmolu).
- `cabal build all` — verify the whole project builds.
- `cabal test all` — run both test suites (`shiki-core-test`, `shiki-cli-test`).
  These use `ephemeral-pg`, so a working PostgreSQL toolchain must be present
  (the Nix dev shell provides it; `just up` starts services if needed).
- `nix flake check` — treefmt + pre-commit gates.
  - **`git add` any newly created files first** (e.g. a new changelog), since
    Nix evaluates the git tree and won't see untracked files.

### 5. Commit, tag, and push

- Stage the modified `.cabal` files and `CHANGELOG.md`.
- Commit with a Conventional Commits message: `chore(release): <version>`. The
  body summarizes the release and why this bump level was chosen.
- Create a single annotated tag: `git tag -a v<version> -m "Release <version>"`.
- Push: `git push && git push --tags`.

### 6. Publish to Hackage (in dependency order)

**Confirm the prerequisites above are resolved first.** If not, stop here and
report what remains.

For each package, in order (**shiki-core → shiki-cli**):

1. `cd <pkg-dir>`
2. `cabal check` — no packaging issues.
3. `cabal test <pkg>-test` — tests pass (`shiki-core-test`, then
   `shiki-cli-test`).
4. `cabal sdist`, then `cabal upload --publish <tarball-path>`. Inspect the
   sdist tarball first to confirm the license/changelog are included.
5. `cabal haddock --haddock-for-hackage --haddock-hyperlink-source --haddock-quickjump`,
   then `cabal upload --publish --documentation <docs-tarball-path>`.
6. Report the Hackage URL: `https://hackage.haskell.org/package/<pkg>-<version>`.

After both are published, present:

| Package | Version | Hackage URL |
|---------|---------|-------------|
| shiki-core | A.B.C.D | https://hackage.haskell.org/package/shiki-core-A.B.C.D |
| shiki-cli  | A.B.C.D | https://hackage.haskell.org/package/shiki-cli-A.B.C.D |

### 7. Create the GitHub release

After both Hackage uploads succeed:

```bash
gh release create v<version> --title "v<version>" --notes "$(cat <<'EOF'
## Packages

| Package | Hackage |
|---------|---------|
| shiki-core | https://hackage.haskell.org/package/shiki-core-A.B.C.D |
| shiki-cli  | https://hackage.haskell.org/package/shiki-cli-A.B.C.D |

## What's Changed

<the new version's entries from CHANGELOG.md>
EOF
)"
```

Report the GitHub release URL when done.

## Important

- Always ask the user to confirm the version bump and changelog before
  committing; create the commit and tag only after approval.
- Always publish in dependency order: **shiki-core → shiki-cli**. Never upload
  `shiki-cli` before `shiki-core`'s upload has succeeded.
- Never skip `cabal check`, the test suites, or `nix flake check`.
- If any step fails (build, test, `nix flake check`, `cabal check`, or an
  upload), **stop and report** — do not continue to dependent packages after an
  upstream upload fails.
- Do not attempt the Hackage upload while the `cabal.project` git-fork
  prerequisites are unresolved; the upload will be rejected.
- Run `nix fmt` before committing.
