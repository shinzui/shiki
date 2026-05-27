---
id: 1
slug: microservice-job-runner-with-postgres-backed-run-history
title: "Microservice Job Runner with Postgres-Backed Run History"
kind: master-plan
created_at: 2026-05-27T04:45:12Z
---

# Microservice Job Runner with Postgres-Backed Run History

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

After this initiative, an operator at a terminal can run a single command of the form

```bash
shiki run mls-service-v2 -- subscription process --batch-size 100
```

and the `shiki` CLI will: (1) read a declarative configuration describing the `mls-service-v2`
microservice (its Kubernetes namespace, deployment to mirror, init containers like
`cloud-sql-proxy`, environment variable wiring, container name and command path), (2) connect
to the operator's current Kubernetes cluster, (3) inspect the live worker Deployment to fill in
the dynamic bits (container image tag, ConfigMap name, Secret name, ServiceAccount), (4)
construct an equivalent `batch/v1` Job that runs the given subcommand against the same
configuration as the worker, (5) submit the Job and (unless `--no-wait` is passed) follow it to
completion while streaming logs, and (6) record the full lifecycle of the run — service name,
command, namespace, image, job name, exit status, start and end timestamps, duration, and
truncated tail of logs — into a local PostgreSQL database so the operator can later answer
"what one-off ran in prod last Tuesday, by whom, with what arguments, and how did it end?"

A second set of subcommands (`shiki runs list`, `shiki runs show <id>`, `shiki runs logs <id>`)
makes the recorded history queryable from the same CLI. The CLI is structured so new top-level
verbs and `<service>`-specific commands can be added later without touching the run-recording
plumbing.

In scope: replacing one shell script (`run-oneoff-task.sh`) with a typed Haskell CLI that
generalizes the pattern across multiple microservices via a declarative service registry;
durable PostgreSQL observability for every run; a CLI surface designed for accretion (more
verbs, more services). Out of scope: replacing `kubectl logs -f`/`kubectl wait`-style
interactive ergonomics beyond what is necessary to follow a single Job; multi-cluster
orchestration; a web UI; alerting/paging; RBAC of who may run what; running anything other than
`batch/v1` Jobs (no Deployments, CronJobs, Pods directly).


## Decomposition Strategy

The initiative was decomposed along functional concerns rather than along files or modules.
Each work stream produces an independently demonstrable behavior that can be exercised on its
own — a service config can be parsed and pretty-printed without a database; the database schema
and `RunRecord` writer can be exercised against a local Postgres without any Kubernetes contact;
the Kubernetes job runner can launch and follow a Job against a real cluster without writing
anything to Postgres; the `run` CLI subcommand ties all three together; and the `runs` query
subcommands consume only the Postgres side.

The five resulting work streams are: **service configuration model** (declarative description
of a microservice and how to derive its Job spec), **PostgreSQL persistence** (schema,
migrations, run-record writer/reader), **Kubernetes job runner** (Kubernetes API client wiring,
Deployment introspection, Job construction, submission, wait/log follow), **`run` CLI command**
(end-to-end integration that produces the observable user behavior described in Vision &
Scope), and **runs query CLI commands** (read-side observability subcommands proving the
recorded data is useful).

Alternatives considered:

- **One large ExecPlan.** Rejected because the work touches three distinct external systems
  (filesystem/Dhall, PostgreSQL, Kubernetes API), each with non-trivial setup and validation
  steps. A single plan would be over ten milestones long and would hide ordering decisions.

- **Decomposition by Haskell module** (one plan per new module). Rejected because module
  boundaries do not map cleanly to user-visible behaviors and would force premature commitment
  to a module layout before the domain types had been validated.

- **Decomposition by layer** (data layer / business layer / presentation layer). Rejected
  because layered plans must all reach completion before any user-visible behavior emerges,
  which violates the "each work stream produces an independently verifiable behavior" principle
  from `MASTERPLAN.md`.

- **Merging the runs-query commands into the run command plan.** Rejected because the query
  side is purely a read-only consumer of the `runs` table and has no dependency on Kubernetes;
  keeping it separate lets it ship without blocking on cluster access and shrinks the `run`
  plan to a manageable integration scope.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Service Configuration Model and Dhall Loader | [docs/plans/1-service-configuration-model-and-dhall-loader.md](../plans/1-service-configuration-model-and-dhall-loader.md) | None | None | In Progress |
| 2 | PostgreSQL Schema Migrations and Run Persistence | [docs/plans/2-postgresql-schema-migrations-and-run-persistence.md](../plans/2-postgresql-schema-migrations-and-run-persistence.md) | None | None | Not Started |
| 3 | Kubernetes Job Runner | [docs/plans/3-kubernetes-job-runner.md](../plans/3-kubernetes-job-runner.md) | EP-1 | None | Not Started |
| 4 | run CLI Command End to End | [docs/plans/4-run-cli-command-end-to-end.md](../plans/4-run-cli-command-end-to-end.md) | EP-1, EP-2, EP-3 | None | Not Started |
| 5 | Runs Query CLI Commands | [docs/plans/5-runs-query-cli-commands.md](../plans/5-runs-query-cli-commands.md) | EP-2 | EP-4 | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their `EP-N` prefix.


## Dependency Graph

EP-1 (service config) and EP-2 (Postgres persistence) are independent and may be implemented in
either order or in parallel; both are leaves of the dependency graph.

EP-3 (Kubernetes job runner) has a hard dependency on EP-1 because constructing a `V1Job` from
a service configuration is the job runner's central responsibility: without the `ServiceConfig`
type and loader from EP-1, the runner has no input. It does not depend on EP-2 — the runner can
be exercised in isolation against a real cluster with no database involvement, which is useful
both for development and for tests.

EP-4 (the `run` CLI command) has hard dependencies on all three of EP-1, EP-2, and EP-3 because
its job is exactly to compose them into the user-visible behavior described in Vision & Scope.
There is no meaningful partial form of EP-4 that skips any of these.

EP-5 (runs query commands) has a hard dependency on EP-2 because it reads the `runs` table
schema defined there. It has a soft dependency on EP-4: although EP-5 can technically be
implemented against rows inserted by a test helper, it is far easier to demonstrate end-to-end
once EP-4 is producing real rows. The soft dependency does not block ordering; EP-5 may begin
as soon as EP-2 is complete.

Parallelism: once EP-1 and EP-2 are complete, EP-3 and EP-5 can proceed in parallel. EP-4 is
the natural integration point and is implemented last.


## Integration Points

The following artifacts are touched by more than one child plan. Each child plan repeats the
relevant definitions verbatim per the self-containment requirement; this section is the
authoritative cross-reference.

**`Shiki.Service.Config.ServiceConfig`** (Haskell record type, module `Shiki.Service.Config` in
`shiki-core/src/Shiki/Service/Config.hs`). Defined by EP-1. Consumed by EP-3 (the job runner
turns it into a `V1Job`) and EP-4 (the CLI loads it from disk and passes it to the runner).
EP-1 owns its shape; if EP-3 or EP-4 discover a missing field they must update EP-1 first via
the MasterPlan's update mode rather than extending the record locally.

**`runs` PostgreSQL table** (schema). Defined by EP-2 in `shiki-core/sql/migrations/`.
Written to by EP-4 (one row per `shiki run` invocation: insert at submit, update on completion).
Read by EP-5 (`runs list`, `runs show`, `runs logs`). Column names, types, and the
`run_status` enum are the canonical shared vocabulary; all three plans must agree on them. EP-2
is the authority; later plans must use the migration files as the source of truth and never
add columns ad-hoc from the writer or reader side.

**`Shiki.Persistence.Run.RunRecord` / `RunStatus`** (Haskell types, module
`Shiki.Persistence.Run` in `shiki-core/src/Shiki/Persistence/Run.hs`). Defined by EP-2 to
mirror the `runs` table. Consumed by EP-4 (constructs and updates rows) and EP-5 (decodes rows
into `RunRecord` for display). The hasql `Statement` values exported from this module are the
shared API.

**`Shiki.K8s.Runner.JobOutcome`** (Haskell record returned by the runner, module
`Shiki.K8s.Runner` in `shiki-core/src/Shiki/K8s/Runner.hs`). Defined by EP-3. Consumed by EP-4
to translate cluster-side results into the `RunRecord` finalization update. Contains job name,
final phase, exit code, start/end timestamps as observed from the cluster, and a truncated log
tail.

**CLI subcommand registry** (`Shiki.Cli` in `shiki-cli/src/Shiki/Cli.hs`). The existing
`Command` sum type is extended by EP-4 (adding `Run`) and by EP-5 (adding `RunsList`,
`RunsShow`, `RunsLogs` under a `runs` subparser). Both plans must extend the same sum type
rather than introducing a parallel one; EP-4 lands first and lays out the convention
(per-subcommand record types, a `runCommand` dispatch case per constructor).

**`Shiki.Prelude`** (in `shiki-core/src/Shiki/Prelude.hs`). EP-1 extends it to re-export
`Generic`, `Text`, `UTCTime`, `MonadIO`, `FromJSON`/`ToJSON`, the `aeson` casing helpers,
`Control.Lens`, and `Data.Generics.Labels` per the standard documented in
`/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/core/custom-prelude.md`. Every later plan
imports it and adds nothing to it unless the addition is justified by the standard's "What
Belongs Here" rules (small project-wide utilities). Updates to the prelude must be
recorded in this MasterPlan's Decision Log.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan and
its milestone; child plans own the granular checklists. This section is the at-a-glance view
of the entire initiative and must be updated whenever a child plan milestone is checked off.

- [ ] EP-1: ServiceConfig record type and JSON/Dhall round-trip
- [ ] EP-1: Loader reads `services/<name>.dhall` and prints a `ServiceConfig`
- [ ] EP-2: Migration tooling wired into `shiki-core` with `runs` table created
- [ ] EP-2: `RunRecord` insert/update/query statements with tests against ephemeral Postgres
- [ ] EP-3: Load kubeconfig and list deployments in a namespace
- [ ] EP-3: Introspect a Deployment and derive a `V1Job` from a `ServiceConfig`
- [ ] EP-3: Submit Job, follow to completion, return `JobOutcome` with log tail
- [ ] EP-4: `shiki run <service> -- <args...>` parses and dispatches
- [ ] EP-4: End-to-end run is recorded in Postgres (start row + completion update)
- [ ] EP-5: `shiki runs list` reads recent rows and prints a table
- [ ] EP-5: `shiki runs show <id>` prints a single run's full record
- [ ] EP-5: `shiki runs logs <id>` prints the stored log tail


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

(None yet.)


## Decision Log

- Decision: Decompose into five child plans along functional concerns (service config,
  persistence, job runner, run command, runs query).
  Rationale: Each stream produces an independently verifiable behavior; the three external
  systems (filesystem, Postgres, Kubernetes) each get one dedicated plan with isolation, and
  the integration is concentrated in EP-4.
  Date: 2026-05-26

- Decision: Service configuration is a declarative Dhall file under `services/<name>.dhall`
  rather than auto-detected at runtime from a fixed Deployment.
  Rationale: The example shell script hard-codes assumptions about deployment names, init
  containers, and env vars. A typed declarative config makes adding new services a code
  change reviewed in source control, keeps the runner free of magic strings, and matches the
  user's stated convention of Dhall configuration across other CLIs.
  Date: 2026-05-26

- Decision: Use `codedownio/kubernetes-api` (specifically `kubernetes-api-1.34` plus
  `kubernetes-api-client`) for cluster access instead of shelling out to `kubectl`.
  Rationale: The user's stated goal is a typed Haskell CLI replacing shell scripts; relying on
  `kubectl` would only relocate the shell-script fragility. The API client supports kubeconfig
  loading, GCP/OIDC auth, and full Job CRUD, which is exactly what is needed.
  Date: 2026-05-26

- Decision: Persistence uses `hasql` + `hasql-pool` + `shinzui/hasql-migration` rather than
  postgresql-simple or persistent.
  Rationale: Matches existing patterns across the user's other Haskell services; `hasql-migration`
  is already a tracked dependency in the user's registry; this gives a typed `Statement`-based
  API with low ceremony.
  Date: 2026-05-26

- Decision: Runs are recorded synchronously inline with the CLI invocation rather than via
  an async queue or background worker.
  Rationale: The CLI is the only writer, runs are infrequent, and synchronous writes make the
  failure model trivial: if the database is down, the user sees the error and can decide
  whether to proceed. Adding asynchrony before there is a second writer would be premature.
  Date: 2026-05-26

- Decision: Logs are stored as a truncated tail (last N kilobytes) on the `runs` row rather
  than streamed to object storage or to a separate `run_logs` table.
  Rationale: Keeps the schema simple and the observability story self-contained for v1;
  long-form logs already live in the cluster (`kubectl logs` against the Job's Pod) until the
  Job is GC'd. EP-2 must size the column generously (e.g., `text` with an application-side
  truncation policy documented in the writer).
  Date: 2026-05-26

- Decision: Every child plan follows the Haskell standards defined in
  `/Users/shinzui/Keikaku/bokuno/haskell-jitsurei` (mori name `shinzui/haskell-jitsurei`).
  The relevant cookbook documents are `core/standards.md`, `core/custom-prelude.md`,
  `core/record-patterns.md`, and `core/multiline-strings.md`. The contract: GHC 9.12+ with
  GHC2024; default-extensions `DeriveAnyClass`, `DuplicateRecordFields`, `OverloadedLabels`,
  `OverloadedStrings`, `MultilineStrings`, `PackageImports`; postpositive `qualified`
  imports (`import Data.Text qualified as Text`); custom prelude `Shiki.Prelude` re-exports
  the common vocabulary (`Generic`, `Text`, `UTCTime`, `MonadIO`, `FromJSON`/`ToJSON`,
  `Control.Lens`, `Data.Generics.Labels`); records use no field prefixes, strict fields
  (`!`), explicit deriving strategies (`stock`/`anyclass`/`newtype`), and `#fieldName` lens
  access in preference to record syntax for both reading (`r ^. #field`) and writing
  (`r & #field .~ v`); embedded SQL/JSON/Dhall uses the `MultilineStrings` `"""..."""`
  syntax.
  Rationale: User-stated requirement; existing `Shiki.Prelude` already follows the lens
  half of the convention; staying consistent with the user's other Haskell projects makes
  code reviews and cross-project reuse straightforward.
  Date: 2026-05-26

- Decision: EP-1 extends `Shiki.Prelude` to match the `core/custom-prelude.md` standard
  (re-exporting `Generic`, `Text`, `UTCTime`, `MonadIO`, `FromJSON`/`ToJSON`, etc.) before
  introducing any new records.
  Rationale: All later plans depend on the extended prelude; doing it once up-front avoids
  every later plan re-importing the same baseline. EP-1 owns this change since it is the
  first plan to introduce records.
  Date: 2026-05-26


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion. Compare
the result against the original vision.

(To be filled during and after implementation.)
