---
id: 2
slug: project-local-configuration-with-per-environment-databases
title: "Project-Local Configuration with Per-Environment Databases"
kind: master-plan
created_at: 2026-06-11T18:40:18Z
intention: "intention_01ktvznw1xewqamnvyfhsbb4w2"
---

# Project-Local Configuration with Per-Environment Databases

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

Today `shiki` connects to exactly one PostgreSQL database, resolved globally each
invocation: the `--db` flag, then the `SHIKI_DATABASE_URL` environment variable, then
`PG_CONNECTION_STRING` (exported by the project's `nix develop` shell hook). This is the
function `resolveConnectionString` in `shiki-cli/src/Shiki/Cli/Config.hs`. There is no
notion of a "staging" versus a "prod" database; an operator who works against both must
juggle environment variables by hand and risks recording a staging run into the prod
history (or worse, running against the wrong database entirely).

After this initiative an operator drops a single project-local file named `shiki.dhall`
at the root of their checkout. That file declares a set of **named environments** — for
example `staging` and `prod` — each carrying its own database connection string, plus a
**default environment**. From then on:

- `shiki config show` prints the resolved project configuration: the discovered
  `shiki.dhall` path, the list of environments, the default environment, the currently
  active environment, and the database URL that the active environment resolves to (with
  the password component masked so it is safe to paste into a terminal or ticket).
- `shiki run mls-service-v2 --env staging -- ...` submits the job and records the run
  into the **staging** database; `shiki run mls-service-v2 --env prod -- ...` records into
  the **prod** database. The same `--env` selector applies to `shiki runs list/show/logs`
  and `shiki agent`, so every database-touching subcommand reads and writes the
  environment the operator selected.
- The active environment is chosen by `--env NAME` (highest precedence), then the
  `SHIKI_ENV` environment variable, then the `defaultEnvironment` declared in
  `shiki.dhall`.

The `shiki.dhall` file is deliberately introduced as a **general-purpose project
configuration foundation**, not merely a database-routing mechanism. The user has stated
that this config "we'll use for other features later" — so the configuration type is
modelled to grow (additional per-environment fields such as a Kubernetes context, a
default namespace, or a schema name can be added later without reworking the loader or the
discovery mechanism).

**Scope — included:**

- A new project-local Dhall configuration file `shiki.dhall`, its shared Dhall type
  definitions under `shiki-core/dhall/`, a Haskell `ProjectConfig` type, and a loader.
- Discovery of `shiki.dhall` by walking up from the current working directory to the
  filesystem root (so the command works from any subdirectory of a project).
- Active-environment resolution from `--env` / `SHIKI_ENV` / `defaultEnvironment`.
- A new read-only `shiki config show` subcommand that demonstrates the foundation without
  touching the database or the cluster.
- Routing the database connection used by `run`, `runs`, and `agent` to the active
  environment's URL, while preserving today's behavior when no `shiki.dhall` is present.
- Documentation updates and tests (Dhall round-trip tests, environment-resolution tests,
  and an end-to-end database-routing test using the existing ephemeral-Postgres harness).

**Scope — explicitly excluded:**

- Per-service database isolation (a separate database or schema per service). The user
  selected **per-environment-only** isolation: all services in a project share the active
  environment's database, and individual runs remain distinguished by the existing
  `service_name` column in the `runs` table. Schema selection continues to be governed by
  the existing global `--db-schema` / `SHIKI_DB_SCHEMA` mechanism (EP-6,
  `docs/plans/6-configurable-postgresql-schema-namespace-for-shiki-tables.md`) and is not
  moved into `shiki.dhall` by this initiative.
- Secret management. `shiki.dhall` stores connection strings as Dhall `Text` (which may
  itself reference `env:VAR` using Dhall's native environment-variable imports if the
  operator wishes). Building a secrets backend is out of scope.
- Any change to how services themselves are defined (`services/<name>.dhall` and
  `Shiki.Service.Config`) beyond what routing requires.


## Decomposition Strategy

The initiative splits into two child ExecPlans along a clean **produce/consume** seam,
which is the natural functional boundary and matches the user's own framing ("a config …
once that lands we need to … use that info").

**EP-12 — the configuration foundation (producer).** This plan introduces everything
needed to *describe and load* project configuration: the Dhall types, the Haskell
`ProjectConfig` / `Environment` types, the loader, the upward-walking file discovery, the
active-environment resolution function, and a `shiki config show` command that makes the
whole thing observable on its own. Crucially, EP-12 delivers a demonstrable, independently
verifiable behavior (`shiki config show` prints the resolved configuration) **without**
changing how any database connection is made. This keeps the foundation reusable for the
"other features later" the user mentioned, and lets it be reviewed and merged in isolation.

**EP-13 — environment-aware run storage (consumer).** This plan consumes the foundation:
it changes the connection-string resolution so that `run`, `runs`, and `agent` connect to
the active environment's database from `shiki.dhall`, with `--db` still able to override
and a clean fall-through to today's behavior when no config or no environment URL is
present. Its deliverable is the user-visible payoff: runs land in the staging or prod
database according to `--env`.

**Principles applied.** The boundary minimizes cross-plan coupling: EP-12 owns the config
type and the resolution function; EP-13 only *calls* them at one well-defined site
(`withDbEnv` in `shiki-cli/src/Shiki/Cli.hs`, plus `resolveConnectionString` in
`shiki-cli/src/Shiki/Cli/Config.hs`). Each plan is independently verifiable: EP-12 by
`shiki config show` and unit tests; EP-13 by an end-to-end test that records a run and
reads it back from the environment-selected database. Scope is balanced — EP-12 carries
the bulk of the new code (types, loader, discovery, command) while EP-13 is a focused
rewiring, but EP-13's behavioral payoff justifies it as a separate, separately-reviewable
change with its own risk profile (it touches the live run path).

**Alternative considered and rejected: a single ExecPlan.** The whole initiative could be
one plan with two milestones. It was rejected because (a) the user explicitly asked for
two plans with distinct intentions, (b) the config foundation is intended to be reused by
unrelated future features and benefits from standing alone, and (c) EP-13 changes the live
database-connection path and carries more risk than EP-12, so a reviewable seam between
"introduce inert config" and "rewire the live connection" is valuable.

**Alternative considered and rejected: per-service schema/database isolation.** An earlier
reading of the request was schema-per-service or database-per-service isolation. The user
clarified the intent is **per-environment-only**: environments map to databases, and runs
stay tagged by `service_name`. The decomposition therefore does not include a schema- or
database-per-service plan.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 12 | Project-local shiki.dhall configuration foundation | docs/plans/12-project-local-shiki-dhall-configuration-foundation.md | None | None | Complete |
| 13 | Route run storage to the active environment database | docs/plans/13-route-run-storage-to-the-active-environment-database.md | EP-12 | None | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-12, EP-13).


## Dependency Graph

EP-13 has a **hard dependency** on EP-12. EP-13 must call the Haskell types and functions
that EP-12 introduces — specifically the `ProjectConfig` / `Environment` types
(`shiki-core/src/Shiki/Project/Config.hs`), the loader and discovery in
`shiki-cli/src/Shiki/Cli/Project.hs`, and the active-environment resolver. Without EP-12's
artifacts, EP-13's code would not compile: there would be no `ProjectConfig` to read a URL
from and no resolver to choose the environment. This is the canonical case for a hard
dependency (the later plan's code cannot exist without the earlier plan's types).

There is no reverse or parallel relationship: EP-12 is fully self-standing (its
deliverable, `shiki config show`, requires nothing from EP-13). The two plans are
therefore strictly sequential: implement and merge EP-12, then implement EP-13.


## Integration Points

There is one integration point, owned by EP-12 and consumed by EP-13.

**The project configuration type and its resolution functions.** EP-12 defines, and EP-13
consumes, the following exact surface (full module paths; signatures are normative — EP-13
relies on them verbatim):

- `shiki-core/src/Shiki/Project/Config.hs` exports:

  ```haskell
  newtype EnvironmentName = EnvironmentName { unEnvironmentName :: Text }
    deriving stock (Generic, Eq, Ord, Show)
    deriving newtype (FromJSON, ToJSON)

  data Environment = Environment
    { databaseUrl :: !Text          -- libpq-style Postgres connection string
    }
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)

  data ProjectConfig = ProjectConfig
    { environments       :: !(Map Text Environment)   -- keyed by environment name
    , defaultEnvironment :: !Text
    }
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)
  ```

  The `environments` field is a `Data.Map.Strict.Map Text Environment` keyed by the
  environment name. `Environment` is a record (not a bare `Text`) precisely so future
  features can add fields without breaking the type or its consumers.

- `shiki-cli/src/Shiki/Cli/Project.hs` exports the discovery and resolution surface
  (signatures normative):

  ```haskell
  -- Walk up from the current working directory looking for "shiki.dhall".
  -- Returns the absolute path if found, Nothing otherwise.
  discoverProjectConfigPath :: IO (Maybe FilePath)

  -- Load and parse a discovered shiki.dhall into a ProjectConfig.
  loadProjectConfig :: FilePath -> IO ProjectConfig

  -- Resolve the active environment NAME from: explicit flag, then SHIKI_ENV,
  -- then the config's defaultEnvironment. The Maybe Text is the --env flag value.
  resolveActiveEnvironmentName :: ProjectConfig -> Maybe Text -> IO (Text, EnvSelectionSource)

  data EnvSelectionSource = FromFlag | FromEnvVar | FromDefault

  -- Convenience: discover + load + resolve, returning the active Environment
  -- (and its name) when a shiki.dhall exists and names that environment.
  -- Returns Nothing when no shiki.dhall is discovered, so callers can fall
  -- back to legacy behavior. Errors out (calls error) when a config exists
  -- but the requested environment is not declared in it.
  resolveActiveEnvironment :: Maybe Text -> IO (Maybe (Text, Environment))
  ```

EP-12 is responsible for defining all of the above and for registering the new modules in
`shiki-core/shiki-core.cabal` and `shiki-cli/shiki-cli.cabal`, plus the new Dhall files in
`shiki-core`'s `data-files`. EP-13 must not redefine any of these; it imports them. The
global `--env` command-line flag (added to the top-level `Options` record in
`shiki-cli/src/Shiki/Cli.hs`) is **defined by EP-12** (so `config show` can use it) and
**also consumed by EP-13** for the database-touching subcommands. If EP-12's signatures
change during its implementation, the change must be recorded here and in EP-13 before
EP-13 begins.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan and
the milestone.

- [x] EP-12 M1: Shared Dhall types (`Environment.dhall`, `ProjectConfig.dhall`) and the
  Haskell `ProjectConfig`/`Environment`/`EnvironmentName` types with a Dhall loader; both
  cabal files and `data-files` updated; round-trip unit test passes.
- [x] EP-12 M2: Upward-walking discovery of `shiki.dhall` and active-environment
  resolution (`--env` → `SHIKI_ENV` → `defaultEnvironment`) with unit tests.
- [x] EP-12 M3: `shiki config show` subcommand prints discovered path, environments,
  default, active environment, and masked active database URL; global `--env` flag added.
- [x] EP-12 M4: Documentation (`docs/user/`) and tracked `shiki.dhall.example` committed;
  local `shiki.dhall` ignored.
- [ ] EP-13 M1: `resolveConnectionString` extended to consult the active environment's URL
  with the agreed precedence; `withDbEnv` threads `--env` through `run`/`runs`/`agent`.
- [ ] EP-13 M2: End-to-end test proving a run is recorded into and read back from the
  environment-selected database; legacy fall-through test (no `shiki.dhall`) passes.
- [ ] EP-13 M3: Documentation updates reflecting environment-aware connection precedence.


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- Discovery: EP-12 implements `resolveActiveEnvironmentName` as
  `ProjectConfig -> Maybe Text -> IO (Text, EnvSelectionSource)`, not plain `IO Text`, so
  `config show` can explain whether the active environment came from `--env`, `SHIKI_ENV`,
  or `defaultEnvironment`. EP-13 already expected this richer signature; the MasterPlan's
  integration point was corrected to match the implemented surface.
  Evidence: `shiki config show`, `shiki config show --env prod`, and
  `SHIKI_ENV=prod shiki config show` print `(from defaultEnvironment)`, `(from --env)`, and
  `(from SHIKI_ENV)` respectively.

- Discovery: The repository now ships `shiki.dhall.example` and ignores local
  `shiki.dhall` files rather than tracking a root `shiki.dhall`.
  Evidence: `.gitignore` contains `shiki.dhall`; `dhall resolve --file shiki.dhall.example`
  succeeds. EP-13 documentation should refer to copying the example or creating a local
  ignored `shiki.dhall`.


## Decision Log

- Decision: Decompose into exactly two child ExecPlans — EP-12 (config foundation,
  producer) and EP-13 (environment-aware run storage, consumer) — with EP-13 hard-depending
  on EP-12.
  Rationale: Clean produce/consume seam; matches the user's explicit request for two plans
  with distinct intentions; lets the reusable config foundation merge independently of the
  riskier live-connection rewiring.
  Date: 2026-06-11

- Decision: Isolation is **per-environment only**, not per-service. `shiki.dhall` maps
  environment → database URL; runs continue to be distinguished by the existing
  `service_name` column; schema selection stays on the existing global
  `--db-schema`/`SHIKI_DB_SCHEMA` mechanism.
  Rationale: User selection during planning. Avoids duplicating EP-6's schema machinery and
  keeps the change additive.
  Date: 2026-06-11

- Decision: Active environment is selected by `--env NAME` → `SHIKI_ENV` →
  `defaultEnvironment` (in `shiki.dhall`).
  Rationale: User selection; mirrors shiki's established flag → env-var → default precedence
  used by `--db`/`SHIKI_DATABASE_URL` and `--db-schema`/`SHIKI_DB_SCHEMA`.
  Date: 2026-06-11

- Decision: `Environment` is modelled as a record (currently a single `databaseUrl` field)
  rather than a bare connection-string alias.
  Rationale: The user intends to reuse this config for future features; a record grows
  additively without breaking consumers.
  Date: 2026-06-11

- Decision: `shiki.dhall` is discovered by walking up from the current working directory to
  the filesystem root; absence of the file is not an error (commands fall back to legacy
  behavior).
  Rationale: "Local for each project" with ergonomic use from subdirectories; backward
  compatibility for users who have no `shiki.dhall`.
  Date: 2026-06-11

- Decision: Connection precedence in EP-13 is `--db` flag → active environment URL from
  `shiki.dhall` → `SHIKI_DATABASE_URL` → `PG_CONNECTION_STRING`.
  Rationale: Keeps the explicit `--db` escape hatch authoritative for one-off overrides
  while making the config the normal source of truth; preserves today's behavior when no
  config is present.
  Date: 2026-06-11

- Decision: Complete EP-12 with `shiki.dhall.example` tracked and local `shiki.dhall`
  ignored.
  Rationale: Operators can copy a safe template while keeping real database URLs and
  machine-local settings out of version control. This preserves the project-local config
  workflow and keeps EP-13's runtime routing target (`shiki.dhall`) unchanged.
  Date: 2026-06-11


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision.

EP-12 is complete as of 2026-06-11. The reusable project-local configuration foundation is
implemented, tested, and documented without changing live database routing. Validation:
`cabal test shiki-core`, `cabal test shiki-cli`, and `cabal test all` all exited 0; manual
`shiki config show` checks covered no-config, default, `--env`, and `SHIKI_ENV` cases with
masked database URLs.
