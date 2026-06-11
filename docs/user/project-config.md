# Project Configuration

`shiki.dhall` is a project-local configuration file. Place it at the root of a checkout
and `shiki` discovers it by walking up from the current working directory until it finds
the first file named `shiki.dhall`.

This file powers `shiki config show` and database routing for `shiki run`, `shiki runs`,
and `shiki agent`.

## File Format

The file declares named shiki environments and one default environment. Each environment
currently carries a PostgreSQL connection string:

```dhall
let Environment = ./shiki-core/dhall/Environment.dhall

let mkEnv = \(url : Text) -> { databaseUrl = url } : Environment

in  { environments =
        toMap
          { staging = mkEnv "postgresql://shiki:changeme@db.staging.internal:5432/shiki"
          , prod    = mkEnv "postgresql://shiki:changeme@db.prod.internal:5432/shiki"
          }
    , defaultEnvironment = "staging"
    }
```

The repository ships `shiki.dhall.example` as a copyable template. Local `shiki.dhall`
files are ignored by git so real database URLs and machine-specific settings stay out of
commits.

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

In that example, `--env staging` still selects the active project environment
for configuration, but `--db` wins for the actual database connection.

If the active environment has no usable database URL and neither fallback
environment variable is set, shiki exits before opening a pool:

```text
shiki: no Postgres connection string. Pass --db, add a shiki.dhall, or set SHIKI_DATABASE_URL / PG_CONNECTION_STRING.
```

`PG_CONNECTION_STRING` is the final fallback because the repository's
`nix develop` shell hook exports it for the project-local Postgres. Prefer
`shiki.dhall` for named project environments that should be shared across
commands.

## Inspect Configuration

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
