---
id: 18
slug: migrate-shiki-from-hasql-migration-to-pg-migrate
title: "Migrate Shiki from hasql-migration to pg-migrate"
kind: exec-plan
created_at: 2026-09-15T16:46:27Z
intention: "intention_01m2jz6d9debtrwdsm5b4a84y1"
provenance:
  created_by:
    model: "gpt-5.6-sol"
    harness: "codex-cli"
    at: 2026-09-15T16:46:27Z
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-15T18:20:26Z
      mode: "implement"
      note: "Milestones 1 and 2 implemented; transition coverage underway"
---

# Migrate Shiki from hasql-migration to pg-migrate

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Shiki will use the same `pg-migrate` migration model as the author's other Haskell
projects instead of carrying a private `hasql-migration` checkout and its compatibility
pins. SQL migrations will be validated and embedded at compile time, execution will use
`pg-migrate`'s versioned ledger and advisory lock, and an existing Shiki database will
have its legacy `schema_migrations` history imported without re-running already-applied
SQL or losing its run history.

The visible behavior remains intentionally familiar: invoking a database-backed `shiki`
command still brings the selected schema up to date automatically. A fresh database, a
database with any valid prefix of the three existing legacy migrations, and a database
already converted to `pg-migrate` must all reach the same current schema. Integration
tests will demonstrate those paths, a second invocation will do no new work, and a
deliberately corrupted legacy checksum will fail before the target ledger is trusted.


## Progress

- [x] (2026-09-15 16:46Z) Created Intention
  `intention_01m2jz6d9debtrwdsm5b4a84y1` and initialized this ExecPlan.
- [x] (2026-09-15 17:05Z) Inspected Shiki's migration wrapper, schema isolation and
  restricted-role tests, Cabal/Nix wiring, operator documentation, related completed
  plans, and local ADR convention.
- [x] (2026-09-15 17:05Z) Located `pg-migrate` through Mori, read its v1.1 core,
  embedding, and predecessor-import APIs and peer-project usage, and verified v1.1.0.0
  against Hackage and the upstream `v1.1.0.0` tag.
- [x] (2026-09-15 18:20Z) Milestone 1: adopted the released `pg-migrate` packages and an
  embedded, manifest-backed Shiki migration plan; `cabal build shiki-core` passes and a
  clean-build unlisted-SQL probe fails with `UnlistedSqlFiles` as intended.
- [x] (2026-09-15 18:20Z) Milestone 2: replaced the runner with schema-aware
  `pg-migrate` execution and automatic import of valid legacy-history prefixes.
- [x] (2026-09-15 18:20Z) Added passing transition coverage for fresh and repeat runs,
  legacy prefixes 1–3, initialized-but-empty recovery, checksum/prefix rejection,
  per-schema ledgers, and restricted-role reuse.
- [x] (2026-09-15 18:27Z) Milestone 3: added transition coverage, updated the README,
  built-in schema help, strict-valid user documentation and its log, replaced Mori
  dependency metadata, and recorded the durable decision in ADR 4.
- [ ] Milestone 4: run the complete Cabal, Nix, documentation, packaging, and repository
  validation matrix and record the evidence here.


## Surprises & Discoveries

- Observation: `pg-migrate`'s default ledger schema is the database-global `pgmigrate`,
  but Shiki supports two independent Shiki schemas in one database. Reusing the default
  would let the second schema see the first schema's migrations as applied. Evidence:
  `defaultLedgerConfig` uses `pgmigrate`, while
  `shiki-core/test/Shiki/Persistence/SchemaIsolationSpec.hs` migrates `alpha` and `beta`
  in one database and expects both to contain their own `runs` table.

- Observation: the released history adapter recomputes each predecessor row's base64 MD5
  from the exact source bytes, then imports a target SHA-256 ledger row without executing
  its action. Evidence: the public implementation in
  `mori://shinzui/pg-migrate/packages/pg-migrate-import-hasql-migration` rejects missing,
  duplicate, extra, and checksum-mismatched source rows before calling
  `importMigrationHistory`.

- Observation: `pg-migrate` executes its `CREATE SCHEMA IF NOT EXISTS` ledger DDL only
  when `ledger_metadata` is absent. A read-only runtime role can therefore rerun an
  already-applied plan after the owner has bootstrapped or upgraded it, preserving the
  current Shiki operating model with updated grants.

- Observation: the old three-package Git pin was needed before `crypton` completed its
  `memory`-to-`ram` transition. Hackage now publishes `crypton` 1.1.2 with
  `ram >=0.20.1 && <0.23`, and all three `pg-migrate` packages needed here are published
  at 1.1.0.0. The unrelated `jose-jwt` and `hoauth2` overrides still serve the Kubernetes
  authentication graph and are outside this migration.

- Observation: Cabal can decide a component is `Up to date` before invoking GHC, so adding
  only an unlisted sibling SQL file did not run the module's `ForceRecompile` plugin in the
  existing build directory. Evidence: the incremental probe printed `Up to date`, while
  the same tree built in a fresh `--builddir` failed at the splice with
  `UnlistedSqlFiles ["999-unlisted-probe.sql"]`. The plugin does force reconsideration once
  GHC is invoked, as the subsequent test build reported `Impure plugin forced
  recompilation`; final manifest-guard evidence therefore uses an isolated build directory.

- Observation: the installed `okf log add` treats its second positional as a concept key,
  not a document `docId`; passing `DOC-8` warned `concept not found` but still added the
  requested bundle log entry. Evidence: subsequent strict profile/log enforcement passed
  with `OK: 9 concepts (okf_version 0.2)`.


## Decision Log

- Decision: Use the released `pg-migrate`, `pg-migrate-embed`, and
  `pg-migrate-import-hasql-migration` 1.1 family from Hackage.
  Rationale: Hackage reports 1.1.0.0 as normal for all three packages and upstream has a
  `v1.1.0.0` release tag. The published API supports GHC 9.12.4, Hasql 1.10,
  PostgreSQL 17/18, embedded manifests, and the predecessor ledger Shiki uses.
  Date: 2026-09-15

- Decision: Keep the existing SQL files byte-for-byte unchanged, add an ordered manifest,
  and embed them into a single component named `shiki`.
  Rationale: unchanged bytes allow `SamePayload` mappings to prove that legacy filenames
  such as `001-create-runs.sql` are the same actions as target IDs such as
  `shiki/001-create-runs`. Embedding also makes missing, duplicate, or unlisted SQL a
  compile error and removes runtime file discovery from production execution.
  Date: 2026-09-15

- Decision: Put each `pg-migrate` ledger in the selected Shiki schema and use the stable
  Shiki-owned advisory-lock key `0x7368696B695F6D67` (the ASCII bytes `shiki_mg`).
  Rationale: co-location gives each configured Shiki schema independent metadata and
  preserves two-schemas-in-one-database behavior. Sharing one lock only serializes rare
  migration operations across those schemas; it is safe, avoids an unstable hash rule, and
  does not copy an unexposed implementation detail from `defaultLedgerConfig`.
  Date: 2026-09-15

- Decision: Preserve automatic migration on database-backed CLI startup, but change
  `runMigrations` to accept `ConnectionString` instead of `Pool.Pool` so `pg-migrate` can
  own the dedicated connection required by its lock and cleanup lifecycle.
  Rationale: this retains current user behavior while honoring the public provider
  contract. The dedicated connection receives a validated libpq
  `options=-csearch_path=<schema>,public` setting so unchanged unqualified SQL targets the
  selected schema; the application pool keeps its existing init-session search path.
  Date: 2026-09-15

- Decision: When the target ledger has no migration rows, import a non-empty legacy history
  only if its filenames form an exact ordered prefix of the embedded manifest, then run the
  full plan to apply the remaining suffix. Keep `schema_migrations` as read-only evidence.
  Rationale: users can upgrade from releases with one, two, or all three migrations.
  Prefix validation rejects unknown or reordered history, and retaining the predecessor
  table gives recovery evidence without affecting future runs. Testing row count rather
  than only `ledger_metadata` existence also recovers from interruption after pg-migrate
  initializes its ledger but before the separate history-import transaction commits.
  Date: 2026-09-15

- Decision: Preserve restricted-role operation after an owner runs the upgraded binary.
  Rationale: the runtime role needs `USAGE` on the selected schema, `SELECT` on the new
  `ledger_metadata` and `migrations` tables, and existing DML rights on `runs`. It still
  cannot apply pending DDL and must wait for the owner after releases adding migrations.
  Date: 2026-09-15


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Shiki is a Haskell CLI with two Cabal packages. `shiki-core` owns persistence and Kubernetes
logic; `shiki-cli` acquires resources and implements commands. Database statements use
unqualified table names. `shiki-core/src/Shiki/Persistence/Connection.hs` sets every pooled
connection's `search_path` to the selected `Schema` followed by `public`, and
`shiki-core/src/Shiki/Persistence/Schema.hs` validates schema names against
`[A-Za-z_][A-Za-z0-9_]*` with PostgreSQL's 63-byte limit.

`shiki-core/src/Shiki/Persistence/Migration.hs` currently discovers
`shiki-core/sql/migrations/` through Cabal `data-files`, asks `hasql-migration` to load every
file lexicographically, conditionally creates the selected schema and predecessor
`schema_migrations` table, and executes everything in one Hasql transaction. That ledger
stores filename, base64 MD5, and a timestamp. The directory has three immutable files:
`001-create-runs.sql`, `002-add-error-summary.sql`, and `003-add-last-watched-at.sql`.

`shiki-cli/src/Shiki/Cli/Env.hs` acquires the application pool and calls `runMigrations`
before loading Kubernetes configuration, so database-backed commands migrate automatically.
`shiki-core/test/Shiki/Persistence/TestPg.hs` centralizes most ephemeral-PostgreSQL setup;
`SchemaIsolationSpec.hs` proves two schemas in one database do not share tables, and
`RestrictedRoleSpec.hs` proves a runtime role without `CREATE` can proceed after an owner
applies migrations. Other core and CLI tests call `runMigrations` directly; all hits from
`rg -n 'runMigrations' shiki-core shiki-cli` must move to the new interface.

`shiki-core/shiki-core.cabal` directly depends on `hasql-migration` and
`hasql-transaction` and ships SQL as data files. `cabal.project` pins the old library plus
historical `crypton` and `ram` commits. The later `jose-jwt` and `hoauth2` overrides solve
a separate Kubernetes-authentication constraint and remain unless the solver independently
proves them obsolete. `mori.dhall` identifies `shinzui/hasql-migration` as a dependency.
The Nix lock already contains the shared `pg-migrate-src` input supplied by
`haskell-nix`; do not add a project-specific flake input.

In `pg-migrate`, a component is an ordered, named migration collection, a plan is the
validated dependency order of components, and a ledger is the set of `ledger_metadata`,
`migrations`, `history_imports`, and `repairs` tables recording durable outcomes. Core,
embedding, and import APIs are respectively
`mori://shinzui/pg-migrate/packages/pg-migrate`,
`mori://shinzui/pg-migrate/packages/pg-migrate-embed`, and
`mori://shinzui/pg-migrate/packages/pg-migrate-import-hasql-migration`. Curated references
are `mori://shinzui/pg-migrate/docs/quickstart`,
`mori://shinzui/pg-migrate/docs/public-api`,
`mori://shinzui/pg-migrate/docs/compatibility`, and
`mori://shinzui/pg-migrate/docs/operations`.

[ExecPlan 2](2-postgresql-schema-migrations-and-run-persistence.md) introduced the old
runner. [ExecPlan 6](6-configurable-postgresql-schema-namespace-for-shiki-tables.md)
introduced schema isolation, automatic migration, and the restricted-role contract.
[ADR 1](../adr/1-follow-haskell-jitsurei-conventions.md) requires warning-free GHC 9.12
code, repository-standard imports, and checking both Cabal and Nix for dependency changes.
No existing ADR chooses a migration engine, so Milestone 3 adds one using the repository's
plain Markdown convention; `docs/adr` is not a profiled OKF bundle in `mori.dhall`.


## Plan of Work

Milestone 1 replaces the dependency and definition layer. Add
`shiki-core/sql/migrations/manifest` containing the three existing filenames in order. In
`shiki-core/src/Shiki/Persistence/Migration.hs`, enable `TemplateHaskell`, load
`Database.PostgreSQL.Migrate.Embed.RecompilePlugin` with a module-local `OPTIONS_GHC`
pragma, embed the manifest, build a component named `shiki` with no dependencies, and turn
it into a one-component `MigrationPlan`. Static definition or plan errors are programmer
errors and should fail with a precise `invalid embedded Shiki migration plan` message.
Keep `migrationsDirectory` for test-fixture access, but production execution must consume
the embedded bytes.

Update `shiki-core/shiki-core.cabal` to include the manifest in `extra-source-files`,
replace `hasql-migration` with `pg-migrate ^>=1.1`, `pg-migrate-embed ^>=1.1`, and
`pg-migrate-import-hasql-migration ^>=1.1`, and add only other direct dependencies imported
by the final module. Remove `hasql-transaction` if no remaining production module imports
it. In `cabal.project`, delete the `hasql-migration`, `crypton`, and `ram` source package
blocks and rewrite nearby comments. Retain Kubernetes, `jose-jwt`, and `hoauth2` overrides
unless a solver check proves a separate cleanup safe. Acceptance is a successful
`cabal build shiki-core` and an intentional compile failure when an unlisted `.sql` is
temporarily placed beside the manifest.

Milestone 2 replaces execution and performs the history transition. Change `runMigrations`
to accept `ConnectionString` and `Schema`. Derive Hasql settings from the existing text and
append a right-precedence libpq `options` setting selecting `<schema>,public`; concretely,
combine `Settings.connectionString cs` with
`Settings.other "options" ("-csearch_path=" <> schemaText schema <> ",public")`. The schema
validator makes this safe. Create a `LedgerConfig` using `schemaText schema` and the stable
Shiki lock key `0x7368696B695F6D67`. Apply that config to normal run and import options. Use
`connectionProviderFromSettings` so each operation owns one dedicated connection for
advisory locking and cleanup.

Before normal execution, use a short, bracketed `Hasql.Connection.acquire`/`release` call
with those settings to inspect `<schema>.ledger_metadata` and, when initialized, count
`<schema>.migrations` rows for component `shiki`. Existing target rows mean cutover has
started or completed, so skip predecessor import and let normal verification decide whether
they match. A missing target ledger or an initialized target ledger with zero Shiki rows
must inspect qualified `<schema>.schema_migrations`; this distinction handles a crash after
ledger initialization but before history import commits. No source table or an empty source
table means a fresh target. A non-empty source table must name an exact prefix of the
embedded manifest when ordered by `executed_at, filename`; otherwise fail with expected and
observed filenames. Keep this probe on raw Hasql settings because the public
`ConnectionProvider` is intentionally opaque. For a valid prefix, build a strict
`HasqlMigrationSourceConfig`, source payload map, and one `HistoryMapping` per row. Each
mapping targets
`migrationId "shiki" (dropExtension sourceFilename)` and requires the matching
`hasqlMigrationEvidenceKey` as both `Evidence` and `SamePayload`. Call
`importHasqlMigrationHistory` with the same provider for source and target and an explicit
audit reason. Then call `runMigrationPlanWith`; imported entries are already applied and
only the suffix executes. Preserve the source table.

Replace old pool/transaction errors with one Shiki-facing renderer for structured import
and execution failures, keeping the `IO ()` and fail-fast startup behavior. Update
`shiki-cli/src/Shiki/Cli/Env.hs` and every core/CLI test caller to pass `ConnectionString`.
The application pool remains for command work and retains its init-session search path.
Acceptance is a fresh migration and repeat invocation passing against ephemeral PostgreSQL.

Milestone 3 pins compatibility with tests and docs. Add
`shiki-core/test/Shiki/Persistence/MigrationSpec.hs`, register it in the Cabal test suite
and `shiki-core/test/Spec.hs`, and use the real SQL data files plus fixed legacy MD5 values
to construct predecessor databases. Cover fresh installation; prefix lengths 1, 2, and 3;
repeat conversion; recovery from an initialized-but-empty target ledger; checksum mismatch;
unknown/non-prefix filenames; independent `alpha` and `beta` ledgers; and the
owner-then-restricted-role path. Assert existing SQL is not executed twice, all three target
rows are applied under `shiki`, imported prefixes have matching `history_imports`, suffixes
do not, and `schema_migrations` remains. Update the existing isolation and restricted-role
assertions and grants for the new tables.

Update `README.md` and `docs/user/schema.md`: automatic migration remains; the authoritative
ledger is the selected schema's four pg-migrate tables; legacy history is imported and
retained; restricted roles need new read grants after owner upgrade. Advance
`docs/user/log.md` with `okf log add`. Replace `shinzui/hasql-migration` with
`shinzui/pg-migrate` in `mori.dhall` at package and project levels. Create
`docs/adr/4-use-pg-migrate-with-per-shiki-schema-ledgers.md` in the established format,
recording the engine, embedded manifest, per-schema ledger, dedicated connection/search
path, safe prefix import, retained evidence, and owner-before-runtime rule. Do not add OKF
frontmatter because no ADR profile binding exists.

Milestone 4 captures final evidence. Build/test both Cabal packages, build source
distributions, run strict user-doc checks, validate Mori metadata, run Nix checks, and
confirm formatting and an unchanged `flake.lock`. Search current production code, Cabal,
metadata, and user docs for stale old-runner references; historical plans and explicitly
labeled predecessor-import prose may retain them. Finish ADR distillation and Outcomes &
Retrospective before marking Progress complete.


## Concrete Steps

Run all commands from `/Users/shinzui/Keikaku/bokuno/shiki`. Reconfirm dependency identity
and release state immediately before implementation:

```bash
mori registry show shinzui/pg-migrate --full
mori registry docs shinzui/pg-migrate
mori registry dependents shinzui/pg-migrate --packages
curl -fsSL https://hackage.haskell.org/package/pg-migrate.json
curl -fsSL https://hackage.haskell.org/package/pg-migrate-embed.json
curl -fsSL https://hackage.haskell.org/package/pg-migrate-import-hasql-migration.json
git ls-remote --tags https://github.com/shinzui/pg-migrate
```

Expected evidence includes `"1.1.0.0":"normal"` for every package and
`refs/tags/v1.1.0.0`. If a newer normal release and matching tag exist, inspect its
Mori-located source and release notes, choose a compatible PVP family, and record the
decision here instead of mechanically retaining 1.1.

After Milestone 1, build the definition layer and verify the manifest guard:

```bash
cabal build shiki-core
probe_sql=shiki-core/sql/migrations/999-unlisted-probe.sql
probe_build_dir=$(mktemp -d /tmp/shiki-manifest-probe.XXXXXX)
touch "$probe_sql"
if cabal build shiki-core --builddir="$probe_build_dir"; then
  echo "unexpected success: unlisted SQL was accepted" >&2
  rm -f "$probe_sql"
  rm -rf "$probe_build_dir"
  exit 1
fi
rm -f "$probe_sql"
rm -rf "$probe_build_dir"
cabal build shiki-core
```

The middle build must fail with `UnlistedSqlFiles ["999-unlisted-probe.sql"]`; the final
build succeeds. The temporary target is explicit and removed on both documented paths.

After Milestones 2 and 3, run targeted and complete tests:

```bash
cabal test shiki-core-test --test-show-details=direct --test-options='-p /Shiki.Persistence.Migration/'
cabal test all --test-show-details=direct
```

Expected evidence is a passing migration group covering fresh install, three legacy
prefixes, interrupted-cutover recovery, repeat execution, rejection cases, schema
isolation, and restricted-role reuse, followed by successful core and CLI suites.

Validate documentation and repository metadata:

```bash
okf log add docs/user docs/user/schema.md --profile mori/user-documentation-profile.dhall
okf validate docs/user --strict --profile mori/user-documentation-profile.dhall --profile-enforce --log-enforce
okf graph docs/user
dhall type --file mori.dhall
mori show --full
```

Use the installed `okf log add --help` syntax if it differs, and record that surprise
rather than hand-editing generated coverage. Mori must show `shinzui/pg-migrate` for
`shiki-core` and no active `shinzui/hasql-migration` dependency.

Complete build and packaging checks:

```bash
cabal build all
cabal sdist shiki-core shiki-cli
nix fmt -- --fail-on-change
nix flake check
git diff --check
git diff --exit-code -- flake.lock
rg -n 'hasql-migration|Hasql\.Migration' \
  cabal.project shiki-core shiki-cli README.md docs/user mori.dhall
```

The final search may find labeled legacy-import and upgrade text, but no production import
or Cabal dependency. If the pinned formatter lacks `--fail-on-change`, run `nix fmt`,
inspect its formatting-only diff, and record the substitute here.


## Validation and Acceptance

Acceptance requires observable database behavior. On empty ephemeral PostgreSQL,
`runMigrations connectionString schema` creates the selected schema, four pg-migrate ledger
tables, and current `runs`. The ledger has three applied rows:
`shiki/001-create-runs`, `shiki/002-add-error-summary`, and
`shiki/003-add-last-watched-at`. A second call succeeds without changing row counts or
timestamps.

For each predecessor prefix, a test creates `<schema>.schema_migrations`, executes that
prefix, and inserts authentic filename/base64-MD5 rows. The new runner imports them without
executing their SQL again, applies only the missing suffix, creates one audit row per
imported target, retains the source table, and reaches the fresh-install schema. A changed
checksum, unknown filename, gap, or reordered prefix fails before target history is trusted.
The same import succeeds when a pg-migrate ledger was initialized earlier but still has no
Shiki migration rows, proving retry after interruption is safe.

Running the scenario in `alpha` and `beta` in one database creates independent ledger and
application tables in both and no `public.runs`. Applying/importing one does not make the
other current.

After an owner fully converts a schema, a role without database/schema `CREATE` but with
documented `USAGE`, ledger `SELECT`, and `runs` DML grants can invoke `runMigrations` and
write a run. A pending migration still requires the owner first.

The solver uses released packages instead of the old checkout; source distributions contain
the manifest and SQL; Nix builds without a project-local input or lock churn; the user-doc
bundle is strict-valid; and complete Cabal and Nix suites pass.


## Idempotence and Recovery

Manifest definition, legacy import, and plan execution are rerunnable. The importer returns
already-imported outcomes when target and audit rows match, and the runner does not
re-execute applied actions. Shiki probes target migration rows first, so a completed import
does not retrigger cutover while an initialized-but-empty target ledger can resume import
from the retained predecessor evidence.

The cutover is additive and never updates or deletes `schema_migrations`. If interruption
occurs before import commits, the target ledger may already be initialized but contains no
partial imported rows; the next invocation detects zero Shiki rows and retries the atomic
import. If import commits but a pending suffix fails, the prefix remains auditable and
pg-migrate records the later failure. Fix forward; none of the current SQL is
nontransactional.

Back up irreplaceable data and test restore before rollout, as required by
`mori://shinzui/pg-migrate/docs/operations`. On checksum/prefix failure, do not edit either
ledger. Restore source bytes or investigate unexpected rows. Because source evidence is
retained, an owner can remove only the newly created pg-migrate tables and retry after
fixing the cause, but only from a backup-confirmed session and never in application code.

The unlisted-manifest probe has one exact file target and must be removed on expected or
unexpected outcomes. All other edits are version-controlled and recover with follow-up
patches, not destructive Git operations.


## Interfaces and Dependencies

The verified baseline is `pg-migrate-1.1.0.0`, `pg-migrate-embed-1.1.0.0`, and
`pg-migrate-import-hasql-migration-1.1.0.0`, bounded as `^>=1.1`. Hackage marks all normal
and upstream tags v1.1.0.0. They support GHC 9.12.4, Hasql 1.10, and PostgreSQL 17/18.
Use public modules only, never a dependency `Internal` module.

`shiki-core/src/Shiki/Persistence/Migration.hs` retains this external surface:

```haskell
runMigrations :: ConnectionString -> Schema -> IO ()
migrationsDirectory :: IO FilePath
```

Internal responsibilities should have explicit signatures along these lines; names may
change for clarity:

```haskell
embeddedMigrationEntries :: NonEmpty (FilePath, ByteString)
shikiMigrationPlan :: MigrationPlan
migrationSettings :: ConnectionString -> Schema -> Settings.Settings
migrationRunOptions :: Schema -> RunOptions
migrationProvider :: ConnectionString -> Schema -> ConnectionProvider
legacyHistoryPrefix :: Settings.Settings -> Schema -> IO (Either MigrationBootstrapError [FilePath])
importLegacyHistory :: ConnectionProvider -> Schema -> NonEmpty FilePath -> IO (Either HasqlMigrationImportError HistoryImportReport)
```

`MigrationBootstrapError` is a Shiki-owned internal sum type distinguishing definition,
predecessor inspection/prefix validation, import, and execution failures. Rendering names
the selected schema.

Required dependency calls are:

```haskell
embedMigrationManifest :: FilePath -> Q Exp
migrationComponentFromEmbeddedSql :: Text -> Set Text -> NonEmpty (FilePath, ByteString) -> Either DefinitionError MigrationComponent
migrationPlan :: NonEmpty MigrationComponent -> Either PlanError MigrationPlan
ledgerConfig :: Text -> Int64 -> Either DefinitionError LedgerConfig
withLedger :: LedgerConfig -> RunOptions -> RunOptions
withImportRunOptions :: RunOptions -> ImportOptions -> ImportOptions
connectionProviderFromSettings :: Settings.Settings -> ConnectionProvider
qualifiedTable :: Text -> Either HasqlMigrationDefinitionError QualifiedTable
hasqlMigrationSourceConfig :: ConnectionProvider -> QualifiedTable -> NonEmpty FilePath -> Bool -> Map FilePath ByteString -> [StateValidator] -> Text -> Either HasqlMigrationDefinitionError HasqlMigrationSourceConfig
hasqlMigrationEvidenceKey :: FilePath -> Either HasqlMigrationDefinitionError EvidenceKey
historyMapping :: MigrationId -> EvidenceRequirement -> PayloadRelation -> HistoryMapping
importHasqlMigrationHistory :: ImportOptions -> HasqlMigrationSourceConfig -> ConnectionProvider -> MigrationPlan -> NonEmpty HistoryMapping -> IO (Either HasqlMigrationImportError HistoryImportReport)
runMigrationPlanWith :: RunOptions -> ConnectionProvider -> MigrationPlan -> IO (Either MigrationError MigrationReport)
```

`shiki-cli/src/Shiki/Cli/Env.hs` keeps:

```haskell
withCliEnv :: ConnectionString -> Schema -> (CliEnv -> IO a) -> IO a
```

It calls `runMigrations cs schema` before handing a pool to the continuation.
`Shiki.Persistence.Connection.acquirePool` remains unchanged.

Durable metadata uses `mori://shinzui/pg-migrate` and, when package specificity matters,
the three `mori://shinzui/pg-migrate/packages/...` URIs named above.


Revision note (2026-09-15): Recorded Milestones 1 and 2 and the transition-test portion of
Milestone 3 as implemented. The manifest guard now specifies a fresh Cabal build directory
because an already up-to-date Cabal component can skip GHC before the recompile plugin runs.

Revision note (2026-09-15): Completed Milestone 3 with operator documentation, built-in
help, Mori metadata, strict OKF log coverage, and ADR 4. Recorded the installed `okf log
add` warning so future updates can distinguish document IDs from concept keys.
