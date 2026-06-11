# Getting started

This guide takes you from a fresh checkout to your first recorded
`shiki run` against a Kubernetes service. It assumes you can read a
Kubernetes namespace and a PostgreSQL connection string.

## 1. Prerequisites

You need three things on your machine:

- **Nix** with flakes enabled, *or* GHC `9.12.4`, `cabal-install`,
  `pkg-config`, `zlib`, and PostgreSQL installed manually. The Nix flake
  pins the supported toolchain — use it if you can.
- **`kubectl` context** pointed at the cluster you intend to drive. shiki
  reads the same client config (`~/.kube/config`, or `KUBECONFIG` if set), so
  if `kubectl get deploy -n <ns> <name>` works, shiki can introspect that
  Deployment. See [Authentication](#authentication) below for which kubeconfig
  auth modes shiki supports — including GKE's `gke-gcloud-auth-plugin`.
- **PostgreSQL** — either the local instance the flake wires up for you
  (see below), or any reachable Postgres you can put in `shiki.dhall`,
  pass with `--db`, or export via `SHIKI_DATABASE_URL`.

## 2. Enter the dev shell

```bash
nix develop          # or: direnv allow, if you use direnv
```

The shell hook in `flake.nix` exports a project-local Postgres
configuration:

| Variable                 | Value                                                 |
|--------------------------|-------------------------------------------------------|
| `PGHOST`                 | `$PWD/db`                                             |
| `PGDATA`                 | `$PWD/db/db`                                          |
| `PGDATABASE`             | `shiki`                                               |
| `PG_CONNECTION_STRING`   | `postgresql://<url-encoded PGHOST>/shiki`             |

`initdb` runs once on first entry, so the very first `nix develop` takes
a few seconds longer than subsequent entries.

## 3. Start Postgres

The project ships a `process-compose.yaml` that brings up the local
Postgres and creates the `shiki` database. From inside the dev shell:

```bash
process-compose up      # foreground; Ctrl-C to stop
```

Alternatively, point shiki at any Postgres you control by creating a project-local
`shiki.dhall` with named environments:

```bash
shiki config init --schema-ref <tag-or-commit>
$EDITOR shiki.dhall
shiki config show
shiki --env staging runs list
```

Database commands use this connection precedence: `--db`, then the active
environment's `databaseUrl` from `shiki.dhall`, then `SHIKI_DATABASE_URL`,
then `PG_CONNECTION_STRING`. shiki **applies its own migrations on every
invocation**, so you do not need to run a separate migration step.

The default schema is `shiki`. Override it per-invocation with
`--db-schema <name>` or persistently with `SHIKI_DB_SCHEMA`. See
[Database schema](./schema.md) for the full table layout and the
migration procedure if you're upgrading a checkout that used to write
into `public`.

## 4. Build the CLI

```bash
cabal build all
cabal run shiki -- --help
```

The executable is named `shiki`. The rest of this guide uses `shiki`
directly; substitute `cabal run shiki --` if you have not put the build
output on your `$PATH`.

## 5. Declare your first service

shiki reads one Dhall file per service from `services/<name>.dhall`. The
checkout already ships [`services/mls-service-v2.dhall`](../../services/mls-service-v2.dhall)
as a worked example — copy it, rename it, and replace the fields that
do not match your service. The minimum you need to fill in:

- `name` — the service's short name (must match the filename).
- `defaultNamespace` — the namespace to introspect and submit Jobs into.
- `detectFromDeployment` — the Deployment name shiki should mirror.
  shiki reads the live Deployment's pod spec at run time, so it picks up
  the current image digest, ConfigMap names, Secret names, etc.
- `containerName` — which container in that Deployment shiki should
  mirror (services that have a `cloud-sql-proxy` init container alongside
  the application container need this to disambiguate).
- `analyzer` — `AnalyzerBackend.Heuristic`, `AnalyzerBackend.None`, or
  `AnalyzerBackend.Baikai { model = "..." }`. See
  [Error analysis](./error-analysis.md).

Sanity-check the parsed config without touching the cluster or the
database:

```bash
shiki service show my-service        # pretty JSON of the parsed ServiceConfig
```

A full reference for every field lives in
[Service configuration](./service-config.md).

## 6. Your first run

```bash
shiki run my-service -- my-subcommand --batch-size 100
```

Walkthrough of what shiki does between the `--` and the first log line:

1. Loads `services/my-service.dhall`.
2. Reads the live Deployment named in `detectFromDeployment` and
   captures the image digest plus other fields it cannot infer from the
   Dhall config.
3. Generates a unique Job name (`<service>-<timestamp>-<rand>`).
4. Inserts a row into `runs` with status `pending`, then flips it to
   `running`.
5. Submits the Job to Kubernetes.
6. Streams the Job to completion (unless you passed `--no-wait`), then
   completes the `runs` row with the final status, exit code, duration,
   and a captured log tail.

Common variations:

```bash
shiki run my-service --namespace staging -- my-subcommand   # override namespace
shiki run my-service --no-wait -- my-subcommand             # fire-and-forget
```

After the run finishes, the row is durable. Inspect it with:

```bash
shiki runs list                    # newest 20 runs as a table
shiki runs show <id-prefix>        # full JSON for one run
shiki runs logs <id-prefix>        # captured log tail
shiki runs error <id-prefix>       # one-line error summary, if any
```

Every `runs` subcommand accepts the **8-character prefix** of the run id
shown in `runs list` — typing the full UUID is rarely necessary.

## Authentication

shiki authenticates to the cluster with your existing kubeconfig — the file
at `KUBECONFIG`, or `~/.kube/config` when that variable is unset. The current
context's user determines how shiki proves who it is. shiki supports:

- **Static bearer token** (`user.token` / `user.tokenFile`).
- **Client certificate** (`user.client-certificate*` / `user.client-key*`).
- **GCP auth provider** (`user.auth-provider: { name: gcp }`, the legacy flow).
- **OIDC** (`user.auth-provider: { name: oidc }`).
- **Exec credential plugins** — the `user.exec` stanza of the
  `client.authentication.k8s.io` contract, which is how current GKE kubeconfigs
  authenticate via **`gke-gcloud-auth-plugin`**.

For an exec-plugin user, shiki runs the plugin the same way `kubectl` does:
once per invocation it executes the configured `command` (passing
`KUBERNETES_EXEC_INFO` when the stanza sets `provideClusterInfo: true`), reads
the `ExecCredential` it prints, and uses the returned bearer token for every API
call. So if `kubectl get deploy -n <ns> <name>` works against your GKE cluster,
`shiki` works too — with your unmodified kubeconfig and no manual token juggling.

This requires the plugin binary on your `PATH`. For GKE:

```bash
gcloud components install gke-gcloud-auth-plugin   # or your distro's package
gke-gcloud-auth-plugin --version                   # should print a version
```

Notes and current limits:

- shiki runs **non-interactively** (it may be invoked from CI or cron), so it
  sets `spec.interactive = false`. A plugin configured with
  `interactiveMode: Always` is refused with a clear error, since there is no
  terminal to prompt on. GKE's default `IfAvailable` is fine.
- shiki resolves a **fresh** credential on every invocation rather than caching
  tokens on disk; it is a short-lived CLI making a handful of calls per process.
  Any caching the plugin itself does (for example `gcloud`'s own token cache)
  still applies.
- The **client-certificate** form of an exec response
  (`status.clientCertificateData` / `clientKeyData`) is not yet supported and is
  rejected with an explicit message; GKE returns a token, which is supported.

## Where to next

- [Commands](./commands.md) — every flag for every subcommand.
- [Error analysis](./error-analysis.md) — what populates `error_summary`
  and how to re-run analysis with an LLM.
- [Agent assist](./agent-assist.md) — drive shiki through an AI session
  preloaded with your services and recent runs.
