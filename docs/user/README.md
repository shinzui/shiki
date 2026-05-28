# shiki user guide

Operator-facing documentation for [`shiki`](../../README.md) — the CLI for
conducting one-off operational commands across Kubernetes services with a
durable run history in PostgreSQL.

## Where to start

- **[Getting started](./getting-started.md)** — prerequisites, the dev shell,
  bringing up the local Postgres, your first service config, and your first
  `shiki run`.
- **[Commands](./commands.md)** — every subcommand and flag, the global
  `--db` / `--db-schema` options, and the environment variables they read.
- **[Service configuration](./service-config.md)** — what lives in a
  `services/<name>.dhall` file, how shiki turns it into a Job, and how to
  inspect a parsed config with `shiki service show`.
- **[Database schema](./schema.md)** — the `runs` table, the `shiki` schema,
  schema-name overrides, and how to migrate an old `public.runs` install.
- **[Error analysis](./error-analysis.md)** — the difference between
  `runs.error` and `runs.error_summary`, the Heuristic analyzer's
  vocabulary, the Baikai LLM backend, and the `shiki runs analyze` flow.
- **[Agent assist](./agent-assist.md)** — `shiki agent assist`, the four
  providers, what context the session is preloaded with, and the
  allowed-tool list.
