---
type: Reference
title: "Project Configuration"
description: "Reference the project-local shiki.dhall file format, named environments, Kubernetes context bindings, and database connection precedence."
docId: DOC-7
tags: [shiki, configuration, dhall, environments]
generated:
  by: process:codex
  at: 2026-11-20T00:04:32Z
---

# Project Configuration

`shiki.dhall` is a project-local configuration file. Place it at the root of a checkout
and `shiki` discovers it by walking up from the current working directory until it finds
the first file named `shiki.dhall`.

This file selects storage for database commands and the Kubernetes destination for `shiki run`.

## File Format

Each environment has a database URL. To bind Jobs to a Kubernetes context, use a
schema revision that exports `ProjectConfigWithContext`. Give every environment a
`kubernetesContext` value. Here production uses `sennari` and staging uses the
current context from the operator's kubeconfig.

```dhall
let Schema =
      https://raw.githubusercontent.com/shinzui/shiki/master/schema/package.dhall

let mkEnv =
      \(url : Text) ->
      \(context : Optional Text) ->
        { databaseUrl = url, kubernetesContext = context } : Schema.EnvironmentWithContext

in    { environments =
          toMap
            { staging = mkEnv "postgresql://shiki:changeme@db.staging.internal:5432/shiki" (None Text)
            , prod = mkEnv "postgresql://shiki:changeme@db.prod.internal:5432/shiki" (Some "sennari")
            }
      , defaultEnvironment = "staging"
      }
    : Schema.ProjectConfigWithContext
```

Existing files using `Schema.ProjectConfig` and `Schema.Environment` continue
to use the current context. A project can opt in by switching to the types in
the example above.

Run `shiki config init --schema-ref <tag-or-commit>` to create a starter
`shiki.dhall`. The generated file imports shiki's public schema package from
GitHub, so it works from service repositories that do not contain a shiki
source checkout. Local `shiki.dhall` files are ignored by git so real database
URLs and machine-specific settings stay out of commits.

Connection strings can also come from OS environment variables through Dhall imports:

```dhall
databaseUrl = env:SHIKI_STAGING_DATABASE_URL as Text
```

## Environment Selection

The active shiki environment is resolved in this order:

1. `--env NAME`
2. `SHIKI_ENV`
3. `defaultEnvironment` in `shiki.dhall`

This selection controls which environment `shiki config show` displays and which database
`run`, `runs`, and `agent` use when `--db` is not supplied.

If a `shiki.dhall` is found but the selected name is not one of its declared
environments, database commands exit with:

```text
shiki: environment <name> is not declared in <path> (declared: prod, staging)
```

`SHIKI_ENV` and `--env` have no effect when no `shiki.dhall` is found.

For example:

```bash
shiki --env staging run my-service -- backfill --limit 100
shiki --env staging runs list
shiki --env prod agent assist --service my-service
```

Each command above uses the selected environment's `databaseUrl`. `shiki run`
writes new rows there, `shiki runs` reads rows from there, and
`shiki agent assist` gathers recent runs from there before it starts the
assistant session.

## Database Connection Precedence

Database-backed commands choose their connection string in this order:

1. `--db CONNSTR`
2. The active environment's `databaseUrl` from `shiki.dhall`
3. `SHIKI_DATABASE_URL`
4. `PG_CONNECTION_STRING`

Use `--db` for a one-off override:

```bash
shiki --env staging --db postgresql://localhost/shiki runs list
```

The history command in this example opens the specified database directly.
For `shiki run`, a database override still uses the selected environment's Kubernetes context.
A missing bound context stops the command before migrations or Job creation.

If the active environment has no usable database URL and neither fallback
environment variable is set, shiki exits before opening a pool:

```text
shiki: no Postgres connection string; pass --db, add a shiki.dhall, or set SHIKI_DATABASE_URL / PG_CONNECTION_STRING
```

`PG_CONNECTION_STRING` is the final fallback because the repository's
`nix develop` shell hook exports it for the project-local Postgres. Prefer
`shiki.dhall` for named project environments that should be shared across
commands.

## Inspect Configuration

Initialize a new project-local config:

```bash
shiki config init --schema-ref <tag-or-commit>
```

The command writes `shiki.dhall` and refuses to overwrite an existing file.

Run:

```bash
shiki config show
```

Example output:

```text
config file:         /home/op/project/shiki.dhall
environments:        prod, staging
default environment: staging
active environment:  staging   (from defaultEnvironment)
database url:        postgresql://shiki:****@db.staging.internal:5432/shiki
```

Select another environment with the flag or environment variable:

```bash
shiki config show --env prod
SHIKI_ENV=prod shiki config show
```

If no `shiki.dhall` exists in the current directory or any parent, `shiki config show`
prints:

```text
no shiki.dhall found (searched the current directory and its parents)
```
