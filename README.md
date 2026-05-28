# shiki

> shiki conducts operational commands across Kubernetes services and records what ran, where it ran, and how long it took.

The name comes from 指揮 (*shiki*) — Japanese for "command," "direction," or
"conducting," used both for military command and for an orchestral conductor.
指 means *to point / indicate*; 揮 means *to wave / direct*. Together they
describe what this tool does: it directs operational commands at the right
service in the right cluster, the way a conductor cues an orchestra.

Shiki is a CLI for conducting operational commands across Kubernetes services
with a durable execution history. It helps operators run service-specific
commands against the right cluster and environment, while recording each run
in PostgreSQL with metadata such as the service, command, status, timing, and
duration. The goal is to make ad hoc operational work safer, easier to audit,
and easier to understand after the fact.

## What it does

```bash
shiki run my-service -- my-subcommand --batch-size 100
shiki runs list                              # newest 20 runs as a table
shiki runs show <id-prefix>                  # full JSON for one run
shiki runs logs <id-prefix>                  # captured log tail
shiki runs error <id-prefix>                 # one-line error summary
shiki runs analyze <id-prefix> --analyzer=baikai:anthropic_claude_haiku_4_5
shiki service show my-service                # inspect a parsed service config
shiki agent assist --service my-service      # AI session preloaded with shiki state
```

Each `shiki run`:

1. Reads `services/<name>.dhall` to learn the service's shape.
2. Introspects the live worker Deployment to capture the current image
   digest, ConfigMap, and Secret references.
3. Submits a one-off Kubernetes Job mirroring those values, with the
   command you passed after `--`.
4. Streams the Job to completion, captures the failing pod's log tail,
   and finalizes a PostgreSQL row with status, exit code, duration,
   Kubernetes-side failure reason, and a log-derived error summary.

The run history is keyed by an 8-character UUID prefix that every
`shiki runs` subcommand accepts.

## Documentation

The user-facing guide lives under [`docs/user/`](./docs/user/README.md):

- **[Getting started](./docs/user/getting-started.md)** — from `nix develop`
  to your first run.
- **[Commands](./docs/user/commands.md)** — every subcommand, flag, and
  environment variable.
- **[Service configuration](./docs/user/service-config.md)** — what lives
  in a `services/<name>.dhall` file.
- **[Database schema](./docs/user/schema.md)** — the `runs` table, the
  `shiki` schema, and the upgrade path.
- **[Error analysis](./docs/user/error-analysis.md)** — Heuristic vs.
  Baikai analyzers, `runs analyze`, API keys.
- **[Agent assist](./docs/user/agent-assist.md)** — `shiki agent assist`
  providers, context, allowed tools.

## Project layout

This project is split into two cabal packages:

- **`shiki-core`** — the library. Domain types, business logic, and the
  project-wide `Shiki.Prelude` that re-exports
  [`lens`](https://hackage.haskell.org/package/lens) and
  [`generic-lens`](https://hackage.haskell.org/package/generic-lens).
- **`shiki-cli`** — the command-line interface. Exposes
  `Shiki.Cli.runCli` and ships an executable named **`shiki`** that just
  calls it.

Both packages target **GHC `ghc9124`** with `default-language: GHC2024`
and the same warning set + default extensions
(`DeriveAnyClass`, `DuplicateRecordFields`, `OverloadedLabels`,
`OverloadedStrings`).

## Develop

The project ships a Nix flake (`nix-haskell-flake`) that pins GHC and
provides the dev shell. Enter the shell, build, and run:

```bash
nix develop          # or: direnv allow, if you use direnv
cabal build all
cabal run shiki -- --help
```

The shell hook exports `PG_CONNECTION_STRING` pointing at a project-local
Postgres under `./db/`. See
[Getting started](./docs/user/getting-started.md) for the full
local-Postgres bring-up.

## License

[BSD-3-Clause](./LICENSE) — (c) 2026 Nadeem Bitar.
