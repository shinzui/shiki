---
type: Reference
title: "Database schema"
description: "Reference shiki's PostgreSQL runs table, its indexes, migration bookkeeping, restricted-role grants, schema-name overrides, and the migration out of public."
docId: DOC-8
tags: [shiki, postgresql, schema, migrations]
generated:
  by: process:codex-cli
  at: 2026-09-15T18:25:00Z
---

# Database schema

shiki keeps its tables in a dedicated PostgreSQL schema (`shiki` by
default) so they do not pollute `public`. Migrations are applied
automatically on every CLI invocation against the configured schema.
The database that receives those migrations is selected by the normal connection
precedence: `--db`, then the active environment's `databaseUrl` from `shiki.dhall`, then
`SHIKI_DATABASE_URL`, then `PG_CONNECTION_STRING`.

## The `runs` table

One row per submitted run. Written by `shiki run`, read by the
`shiki runs *` family.

| Column                 | Type           | Notes                                                                                                                                                      |
|------------------------|----------------|------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `id`                   | `uuid`         | Primary key. Surfaced to operators as an 8-character prefix in `runs list`; commands accept any unambiguous prefix.                                                                                |
| `service_name`         | `text`         | The `name` field from the service's Dhall config.                                                                                                          |
| `command`              | `text[]`       | Everything passed after `--` on the `shiki run` command line.                                                                                              |
| `namespace`            | `text`         | The namespace the Job was submitted into (may differ from the service default if `--namespace` was used).                                                  |
| `job_name`             | `text`         | `<service>-oneoff-YYYYMMDD-HHMMSS-<6 random lowercase letters>` — unique per run.                                                                                                            |
| `image`                | `text`         | Image digest read from the live Deployment at submit time. The column is nullable, but shiki always fills it: a run whose Deployment cannot be read is never inserted. |
| `status`               | `text`         | One of `pending`, `running`, `succeeded`, `failed`. Enforced by `CHECK` constraint.                                                                        |
| `exit_code`            | `integer`      | `0` for a succeeded Job and `1` for a failed one (shiki does not read the container's own exit status); `NULL` on `pending` / `running`, on a timed-out wait, and on failures that happened before the Job reached a verdict. |
| `started_at`           | `timestamptz`  | Time shiki inserted the row.                                                                                                                                |
| `ended_at`             | `timestamptz`  | Time shiki finalized the row; `NULL` while still `pending` / `running`.                                                                                    |
| `duration_ms`          | `bigint`       | `ended_at - started_at`, rounded to the nearest millisecond. `NULL` until finalized.                                                                       |
| `log_tail`             | `text`         | Last 200 lines / 64 KiB of the pod's logs at finalize time. See [Commands → `runs logs`](./commands.md#shiki-runs-logs-id) for the wider in-memory buffer. |
| `service_config`       | `jsonb`        | Full snapshot of the parsed `ServiceConfig` used for this run. Lets you debug "what did we actually submit?" weeks later.                                  |
| `error`                | `text`         | Kubernetes-side failure reason (`BackoffLimitExceeded`, `DeadlineExceeded`, ...) from the failing `V1JobCondition`. Tells you whether the cluster killed the Job. |
| `error_summary`        | `text`         | Short, log-derived one-liner describing what went wrong inside the container. Capped at 512 characters. `NULL` on successful runs by contract.             |
| `error_summary_source` | `text`         | Which analyzer produced the current `error_summary`. `heuristic` or `baikai:<model-id>`. Defaults to `heuristic`.                                          |
| `last_watched_at`      | `timestamptz`  | Nullable database-clock heartbeat refreshed about once a minute by the waiting `shiki run` process. Missing or more than five minutes old makes an unfinished row display as `unwatched`; it does not change stored `status` or `updated_at`. |
| `created_at`           | `timestamptz`  | Row insert time. Defaults to `now()`.                                                                                                                       |
| `updated_at`           | `timestamptz`  | Last update time. Defaults to `now()`.                                                                                                                      |

Indexes:

- `runs_service_started_idx` — `(service_name, started_at DESC)`. Powers
  `runs list --service`.
- `runs_status_idx` — `(status)`. Useful for ad-hoc queries on stuck
  `running` rows.

## Migration bookkeeping

shiki uses `pg-migrate` and stores its authoritative migration ledger in the
same configured schema as `runs`. Each schema therefore migrates independently,
even when several shiki schemas share one PostgreSQL database. The four managed
tables are:

- `ledger_metadata`, which records the ledger format version;
- `migrations`, which records each applied migration and its SHA-256 checksum;
- `history_imports`, which records legacy-history cutovers;
- `repairs`, which records explicit migration repairs.

Do not edit these tables by hand. New migrations live under
[`shiki-core/sql/migrations/`](../../shiki-core/sql/migrations/) and run in the
order declared by that directory's `manifest` on the next CLI invocation.

Releases before the `pg-migrate` cutover used `schema_migrations`. On the first
upgrade run, shiki verifies that its filenames form an ordered prefix of the
current manifest and that every stored MD5 checksum matches the original SQL.
It imports those rows into `migrations` without executing their SQL again, then
applies only the missing suffix. The old `schema_migrations` table is retained
as read-only recovery evidence. A fresh installation does not create it.

## Recording runs with a restricted role

Once an owning role has bootstrapped or upgraded the schema by running any
`shiki` subcommand, a much narrower role can record runs. It needs no `CREATE`
privilege on the database or schema, but it must be able to read the
authoritative ledger:

```sql
GRANT USAGE ON SCHEMA shiki TO some_role;
GRANT SELECT ON shiki.ledger_metadata TO some_role;
GRANT SELECT ON shiki.migrations TO some_role;
GRANT SELECT ON shiki.history_imports TO some_role;
GRANT SELECT ON shiki.repairs TO some_role;
GRANT SELECT, INSERT, UPDATE ON shiki.runs TO some_role;
```

Such a role can verify an already-current ledger but cannot apply a new
migration, because altering `runs` and updating the ledger need their owners.
After upgrading to a shiki release that ships a new migration—or when first
crossing from `schema_migrations` to `pg-migrate`—run any `shiki` subcommand once
as the owning role before the restricted role uses it again.

In particular, migration `003-add-last-watched-at.sql` adds the watcher
heartbeat column. Each environment must run the upgraded binary once as
the owner of `runs` before a restricted runtime role starts using it.

## Schema-name override

The default schema is `shiki`. Override it three ways, in precedence
order:

1. `shiki --db-schema my_other_schema runs list`
2. `export SHIKI_DB_SCHEMA=my_other_schema`
3. *(nothing)* — `shiki` is used.

Schema names must match `[A-Za-z_][A-Za-z0-9_]*` and be ≤ 63 bytes
(PostgreSQL's `NAMEDATALEN`). An invalid name exits with
`shiki: invalid schema name: <reason>` before any database work happens.

## Upgrading from `public`

Old checkouts wrote `runs` and `schema_migrations` directly into
`public`. If you have a dev database from that era and would rather
preserve the rows than drop the database:

```sql
CREATE SCHEMA IF NOT EXISTS shiki;
ALTER TABLE public.runs              SET SCHEMA shiki;
ALTER TABLE public.schema_migrations SET SCHEMA shiki;
```

After that, run any `shiki` subcommand once as the owning role. shiki will
verify and import the moved `schema_migrations` history, retain it as evidence,
and apply only the pending migrations.
