# Project Configuration

`shiki.dhall` is a project-local configuration file. Place it at the root of a checkout
and `shiki` discovers it by walking up from the current working directory until it finds
the first file named `shiki.dhall`.

This foundation currently powers `shiki config show`. A follow-up change,
`docs/plans/13-route-run-storage-to-the-active-environment-database.md`, wires the same
environment selection into `shiki run`, `shiki runs`, and `shiki agent`.

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

For now, this selection is visible through `shiki config show` and does not change the
database used by `run`, `runs`, or `agent` until the follow-up environment-routing work is
implemented.

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
