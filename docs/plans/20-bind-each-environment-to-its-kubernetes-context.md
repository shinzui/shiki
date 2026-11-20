---
id: 20
slug: bind-each-environment-to-its-kubernetes-context
title: "Bind each environment to its Kubernetes context"
kind: exec-plan
created_at: 2026-11-19T23:46:45Z
intention: "intention_01m7v38v3re9fve6v7qe9yvssj"
provenance:
  created_by:
    model: "gpt-6.2-astra"
    harness: "codex-cli"
    at: 2026-11-19T23:46:45Z
  revisions:
    - model: "gpt-6.2-astra"
      harness: "codex-cli"
      at: 2026-11-19T23:57:21Z
      mode: "implement"
      note: "Implement and verify environment-bound Kubernetes submission and history."
---

# Bind each environment to its Kubernetes context

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

An operator can run `shiki --env prod run worker --no-wait -- check` while their kubeconfig points at a local cluster. If production declares `sennari`, Shiki prints the destination, creates the Job in `sennari`, and records that destination alongside the command. A missing declared context stops the invocation before database migrations, run insertion, or cluster writes. An environment without a binding continues to use the current context. The five acceptance criteria come from [IR-2](../improvement-requests/bind-each-environment-to-its-kubernetes-context.md).

## Progress

- [x] 2026-11-19. Both project formats load and malformed bindings fail. Dhall reported all four package exports. All 74 core and 122 CLI tests passed.
- [x] 2026-11-19. Two loopback servers verified the selected endpoint and bearer token for static and exec authentication. A 401 refreshed the token against the original selection after the kubeconfig changed. Missing contexts and dangling cluster references failed during client loading.
- [x] 2026-11-19. Migration 004 preserved the row in a three-migration database. The CLI listed and showed its absent destination alongside two new destinations with an unusable kubeconfig. Repeated migrations and schema isolation passed against PostgreSQL.
- [x] 2026-11-19. The CLI integration test exercised detached and waiting Jobs, namespace override, missing-context rejection before migration with and without `--db`, default routing, and mixed-context reconciliation. All 74 core and 125 CLI tests passed.

## Surprises & Discoveries

## Decision Log

- 2026-11-19. Extend the public Dhall package with a second pair of types. Existing projects import the original types by name, sometimes from a moving branch. Changing the shape behind those names would break valid project files during Dhall type checking, before Shiki could decode them.
- 2026-11-19. Use the recorded context when reconciling a detached Job. The current `runs sync` can mark a missing Job as failed when the service Deployment exists. Two clusters may have identically named Deployments, so lookup in the submission context is necessary to preserve this existing workflow.

## Outcomes & Retrospective

## Context and Orientation

A Shiki environment maps a name to a PostgreSQL connection in a project-local `shiki.dhall`. A Kubernetes context is a kubeconfig entry naming a cluster and credentials. The Kubernetes namespace is the location of the Deployment and Job *within* that cluster. Shiki takes the namespace from the service file or the run command's `--namespace` flag.

`shiki-cli/src/Shiki/Cli/Project.hs` discovers the project file and chooses an environment using the flag, then `SHIKI_ENV`, then the project default. In `shiki-cli/src/Shiki/Cli/Config.hs`, an explicit `--db` currently bypasses project lookup. Otherwise the active environment supplies storage, with environment-variable fallbacks. In `shiki-cli/src/Shiki/Cli.hs`, the Run branch enters `withStore` (which opens and migrates storage) before installing the default Kubernetes client. `shiki-cli/src/Shiki/Cli/Run.hs` then inspects the Deployment, inserts a pending run, marks it running, and submits or submits-and-waits.

The default client reads one file from `KUBECONFIG` or `~/.kube/config`. `shiki-core/src/Shiki/K8s/ExecCredential.hs` can resolve an explicit name but its caller in `shiki-core/src/Shiki/K8s/Client.hs` passes `Nothing`. The normal authentication path delegates to a library function which reopens the file. The exec-plugin path (an external program supplies a short-lived credential) separately decodes the file for the server address and TLS certificate settings. Selecting the plugin user alone would leave the request pointed at the current server.

Use strict record fields and the local lens conventions. Keep Kubernetes access behind its effect interpreter, which supplies the actual client for operations such as inspecting a Deployment. Render typed failures once at the CLI boundary. Database-only history reads must work with an unusable kubeconfig. Append immutable SQL to the manifest so each configured database schema gets its own migration history. Preserve the existing heartbeat and unfinished-run reconciliation semantics. See [ADR 1](../adr/1-follow-haskell-jitsurei-conventions.md), [ADR 5](../adr/5-use-effectful-with-a-single-top-level-error-handler.md), [ADR 4](../adr/4-use-pg-migrate-with-per-shiki-schema-ledgers.md), and [ADR 3](../adr/3-model-run-watcher-liveness-as-a-display-only-heartbeat.md).

## Plan of Work

### Milestone 1. Read both project formats

In `schema/package.dhall`, retain the existing exports from `schema/Environment.dhall` and `schema/ProjectConfig.dhall`. Add `EnvironmentWithContext` and `ProjectConfigWithContext`. The first is a record with `databaseUrl : Text` and `kubernetesContext : Optional Text`. The second uses that record as the value in the same environment map. A typed map has one value type, so use `Some "sennari"` for production and `None Text` for an unbound sibling. Keep the existing config-init template usable with old schema refs. Show the opt-in form in `shiki.dhall.example`.

Extend `Environment` in `shiki-core/src/Shiki/Project/Config.hs`. In `shiki-core/src/Shiki/Project/Config/Dhall.hs`, distinguish the evaluated input shapes and normalize an old environment to an absent binding. Ensure the legacy decoding path cannot discard a present but ill-typed binding. Preserve Dhall imports and relative path resolution. Exercise a database-only literal, the original package annotation, the new mixed bound/unbound map, and a malformed binding in `shiki-core/test/Shiki/Project/ConfigSpec.hs`. Existing configuration text must still load verbatim. Update Haskell fixture construction as required by the new field. Run the core and CLI suites below.

### Milestone 2. Bind the client to one resolved context

Add a context-aware file loader beside the existing client entry points. Read a file snapshot once, resolve the declared name or the file's current name, and return the effective name with the client. Use the same bytes for the exec-plugin and library representations. Set the library configuration's in-memory `currentContext` to the selected entry before looking up the cluster, authentication or TLS settings. Use the original directory for relative certificate paths. A declared name absent from the context entries is a distinct failure. Reject unresolved referenced cluster data for a bound run before constructing a client. Preserve existing unbound authentication behavior, including anonymous or plugin-free configurations supported by the library and the explicit in-cluster API.

In the regular-auth branch reproduce the library file loader's construction from the selected in-memory config using its exported helpers for TLS, server URI, auth settings, OIDC cache and HTTP manager. In the exec branch capture the same selected cluster and user in the refresh action used after a 401. Keep default-loading wrappers for existing callers. See `shiki-core/src/Shiki/Effect/Kube/Client.hs` for the typed error boundary and `runKubeWith` for installing an already-created client. Unit-check both normal and exec auth with distinct context names, URLs and credentials. Send a request through the real client to a local fake server early in this milestone. Verify the selected endpoint and identity, including after plugin refresh, and verify the kubeconfig bytes are unchanged.

### Milestone 3. Preserve destinations in history

Append `004-add-run-destination.sql` to `shiki-core/sql/migrations/manifest` beside the new SQL file. Add nullable text columns `environment` and `kubernetes_context` to the schema-local `runs` table. Leave historical values NULL. In `shiki-core/src/Shiki/Persistence/Run.hs` extend `NewRun`, `RunRecord`, the insert statement and its parameter encoder, and the shared `runColumnsSql` and `runRecordRow` in matching order. Populate new fields explicitly in every constructor, including test fakes. While wiring this milestone, allow absent metadata at existing call sites. Milestone 4 supplies the resolved values on submission.

Add ENVIRONMENT and CONTEXT cells to the shared header and rows in `shiki-cli/src/Shiki/Cli/Runs/Format.hs`, preserving the ID as the first cell for the picker. Use a dash for absent data. The show command in `shiki-cli/src/Shiki/Cli/Runs.hs` emits the record as JSON. Verify the `environment` and `kubernetesContext` fields and legacy nulls. Exercise an upgrade from migration 003 with an existing row, repeated migration, a new insert, and list and single-record queries using the real ephemeral PostgreSQL harness. Update ledger expectations in `shiki-core/test/Shiki/Persistence/MigrationSpec.hs` to include 004 while retaining the released legacy migration fixtures.

### Milestone 4. Wire submission and reconciliation through the selected client

In the Run branch of `shiki-cli/src/Shiki/Cli.hs`, resolve the project selection once. Use it both to derive the database URL and to request the Kubernetes client. Keep database precedence (`--db`, environment URL, `SHIKI_DATABASE_URL`, `PG_CONNECTION_STRING`). An explicit database override still honors the selected project's cluster binding. Outside a project retain legacy database resolution and leave the recorded environment absent. Keep the existing independent resolution path available to store-only commands. Resolve and validate the run's client before entering the migrating store interpreter, then use `runKubeWith` for the entire run. Turn a missing declaration target into a typed error in `shiki-core/src/Shiki/Error.hs` with the rendered line shown below. Add the corresponding case in `shiki-cli/test/Shiki/Cli/MainSpec.hs`.

Pass the resolved environment and actual context to `runRun`. After choosing the namespace and before inspecting the Deployment, print and flush one stdout line naming all three. Use a dash for an absent environment. Insert those same values on the initial row. Inspection, submission, polling, log collection and credential refresh must all use the same client. Preserve existing success, failure, interrupt and no-wait behavior.

In `shiki-cli/src/Shiki/Cli/Runs.hs` and `shiki-cli/src/Shiki/Cli/Runs/Sync.hs`, choose the client for an unfinished row by its stored context, including in bulk sync over mixed destinations. Keep the existing per-row error boundary around client loading as well as observation. When a recorded context is unavailable, report the failure and leave that row unfinished. Older rows with NULL context use the existing default path and missing-Job checks. Verify this with identical Deployment names in two fake clusters. Update `docs/user/project-config.md` and `docs/user/commands.md` with the binding, preflight output, failure and history semantics. Maintain their metadata and `docs/user/log.md` with the operator documentation changes.

## Concrete Steps

Run these commands from the repository root. The development shell provides Cabal, Dhall and PostgreSQL tools. The tests start disposable databases. Use temporary kubeconfigs and loopback endpoints for the routing tests.

```bash
nix develop -c cabal build all
nix develop -c dhall type --file schema/package.dhall
nix develop -c cabal test shiki-core-test --test-show-details=direct
nix develop -c cabal test shiki-cli-test --test-show-details=direct
nix develop -c just user-documentation-validate
```

Expect the build to exit zero, the schema to type-check with the original and additional exports, both test suites to report PASS, and documentation validation and link checking to succeed. Use the core suite for the loader, client and migration milestones. Run the CLI suite as each user-visible behavior lands and both suites on the final working tree.

## Validation and Acceptance

Drive the normal Run dispatch path in `shiki-cli/test/Shiki/Cli/EnvRoutingSpec.hs` or a sibling integration module. Register any new suite modules in the package's Cabal file and test entry point. Give two fake API endpoints distinguishable request logs, the same worker Deployment and a shared disposable run store so the two rows can be compared. A fake which always submits successfully and only echoes the requested context cannot detect a client sent to the wrong endpoint.

1. **AC-1.** With current context `local` and prod declaring `sennari`, submit a no-wait Job. Only the sennari endpoint receives the Deployment GET and Job POST. The stored context is sennari and current-context is still local. Exercise the waiting branch too and check its status and log requests use sennari.
2. **AC-2.** Delete sennari from the fixture before dispatch. Expect exit 1 and stderr `shiki: environment prod declares missing Kubernetes context sennari`. Assert zero new Jobs and zero new rows. Also instrument store acquisition or use an unmigrated schema to prove the missing-context error precedes migration. Repeat with a database override.
3. **AC-3.** Capture stdout with a service default namespace of `ops`. Expect `environment=prod context=sennari namespace=ops` before the existing `submitted job ` line. With `--namespace qa`, both the announcement and the request path use qa. On the waiting path assert the same announcement precedes the existing outcome.
4. **AC-4.** Submit another run in staging to local. With an unusable kubeconfig, list both rows and show each ID. Assert the table and parsed JSON identify the correct environment/context pair per ID. A row created before migration still lists and shows with absent values.
5. **AC-5.** Run against an unchanged database-only project file and against the new schema with `None Text`. Both submit to the current context and record its actual name. Check legacy discovery outside a project and the existing environment selection precedence. Keep the original regression cases passing, allowing fixture constructors and expectations to reflect additive history fields.

## Idempotence and Recovery

The migration runner records each applied file in the selected schema. Upgrade once with a role that owns the table before running with restricted credentials. Retry a failed migration through the normal runner after correcting the cause. Leave the additive columns in place if reverting the binary. A missing-context failure is safe to retry after correcting the binding or kubeconfig. For a failure after submission, inspect the recorded run and Job before retrying because a new run command can submit a second Job.

## Interfaces and Dependencies

Use the existing Dhall, Kubernetes client, effectful, Hasql and migration dependencies. The run boundary needs the active environment name (optional outside a project), a requested context (optional), and an effective context obtained from the same configuration used to construct the client. Persist and display the effective name, including when it came from current-context. Never persist connection strings, certificates or plugin credentials in these fields. Keep the `Kube` operations themselves about Kubernetes work and select the destination when installing their interpreter. The relevant dependency implementation is in [the Kubernetes client package](mori://codedownio/kubernetes-api/packages/kubernetes-api-client).
