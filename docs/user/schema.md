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
| `id`                   | `uuid`         | Primary key. Surfaced to operators as an 8-character prefix in `runs list`.                                                                                |
| `service_name`         | `text`         | The `name` field from the service's Dhall config.                                                                                                          |
| `command`              | `text[]`       | Everything passed after `--` on the `shiki run` command line.                                                                                              |
| `namespace`            | `text`         | The namespace the Job was submitted into (may differ from the service default if `--namespace` was used).                                                  |
| `job_name`             | `text`         | `<service>-<timestamp>-<rand>` — unique per run.                                                                                                            |
| `image`                | `text`         | Image digest read from the live Deployment at submit time. `NULL` only if introspection itself failed.                                                     |
| `status`               | `text`         | One of `pending`, `running`, `succeeded`, `failed`. Enforced by `CHECK` constraint.                                                                        |
| `exit_code`            | `integer`      | The container's exit code on `succeeded` / `failed`; `NULL` on `pending` / `running` and on failures that happened before the container could exit.        |
| `started_at`           | `timestamptz`  | Time shiki inserted the row.                                                                                                                                |
| `ended_at`             | `timestamptz`  | Time shiki finalized the row; `NULL` while still `pending` / `running`.                                                                                    |
| `duration_ms`          | `bigint`       | `ended_at - started_at`, rounded to the nearest millisecond. `NULL` until finalized.                                                                       |
| `log_tail`             | `text`         | Last 200 lines / 64 KiB of the pod's logs at finalize time. See [Commands → `runs logs`](./commands.md#shiki-runs-logs-id) for the wider in-memory buffer. |
| `service_config`       | `jsonb`        | Full snapshot of the parsed `ServiceConfig` used for this run. Lets you debug "what did we actually submit?" weeks later.                                  |
| `error`                | `text`         | Kubernetes-side failure reason (`BackoffLimitExceeded`, `DeadlineExceeded`, ...) from the failing `V1JobCondition`. Tells you whether the cluster killed the Job. |
| `error_summary`        | `text`         | Short, log-derived one-liner describing what went wrong inside the container. Capped at 512 characters. `NULL` on successful runs by contract.             |
| `error_summary_source` | `text`         | Which analyzer produced the current `error_summary`. `heuristic` or `baikai:<model-id>`. Defaults to `heuristic`.                                          |
| `created_at`           | `timestamptz`  | Row insert time. Defaults to `now()`.                                                                                                                       |
| `updated_at`           | `timestamptz`  | Last update time. Defaults to `now()`.                                                                                                                      |

Indexes:

- `runs_service_started_idx` — `(service_name, started_at DESC)`. Powers
  `runs list --service`.
- `runs_status_idx` — `(status)`. Useful for ad-hoc queries on stuck
  `running` rows.

## The `schema_migrations` bookkeeping table

shiki tracks applied migrations in `schema_migrations` (one row per
applied migration). You should not need to touch it by hand. New
migrations live under
[`shiki-core/sql/migrations/`](../../shiki-core/sql/migrations/) and run
in lexicographic order on the next CLI invocation.

## Recording runs with a restricted role

Migrations only create the schema and `schema_migrations` when they are
missing, so once a role that is allowed to create them has bootstrapped
the schema (by running any `shiki` subcommand once), a much narrower role
can record runs. It needs no `CREATE` privilege on the database or the
schema:

```sql
GRANT USAGE ON SCHEMA shiki TO some_role;
GRANT SELECT ON shiki.schema_migrations TO some_role;
GRANT SELECT, INSERT, UPDATE ON shiki.runs TO some_role;
```

Such a role cannot apply a new migration, because altering `runs` needs
the table owner. After upgrading to a shiki release that ships a new
migration, run any `shiki` subcommand once as the owning role before the
restricted role uses it again.

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

After that, run any `shiki` subcommand once — pending migrations will
catch the moved tables up to current.
