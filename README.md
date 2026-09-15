# shiki

**Run one-off operational commands against your Kubernetes services — and keep
a record of every run.**

Every team has commands that don't belong in a deploy: a backfill, a data
repair, a reindex, a one-time import. They usually get run with a hand-edited
Job manifest or a `kubectl exec` into a live pod, and a week later nobody
remembers who ran what, against which cluster, or why it failed.

shiki makes that work repeatable and auditable. You describe a service once;
shiki then launches your command as a Kubernetes Job built from the service's
live Deployment, follows it to completion, and records the result in
PostgreSQL.

```console
$ shiki run billing -- reconcile-invoices --since 2026-09-01
run 3f9c2a1e-7b4d-4c1a-9e2f-5d8a6b0c3e71 Succeeded job=billing-oneoff-20260915-140211-qhxkvm

$ shiki runs list
ID        STARTED              SERVICE  STATUS     DURATION  EXIT  COMMAND
3f9c2a1e  2026-09-15 14:02:11  billing  succeeded  4m12s     0     reconcile-invoices --since 2026-09-01
b71d04c9  2026-09-14 09:30:45  search   failed     38s       1     reindex --all
```

> The name comes from 指揮 (*shiki*), Japanese for "command" or "conducting":
> 指 *to point*, 揮 *to direct*. It is the word for both a commander and an
> orchestra's conductor.

## Features

- **Runs in the environment your service already uses.** shiki reads the
  service's live Deployment for its current image, ConfigMaps, and Secrets,
  so the command runs with the same code and configuration as production.
- **A durable run history.** Every run is stored in PostgreSQL with its
  service, command, namespace, image, status, exit code, timing, and the tail
  of its logs.
- **Explains failures.** A built-in heuristic analyzer summarizes failed runs
  in one line. You can also re-analyze a run with an LLM backend.
- **Handles long jobs.** Submit with `--no-wait` and use `shiki runs sync`
  later to record the outcome. You can close your laptop in the meantime.
- **Named environments.** A project-local `shiki.dhall` maps names like
  `staging` and `prod` to their databases; switch with `--env`.
- **Works well in the terminal.** Pick runs and services with `fzf`, get shell
  completions for bash, zsh, and fish, and read guides with `shiki help`.
- **Works with AI agents.** `shiki agent assist` gives Claude Code or Codex
  (or a one-shot Anthropic or OpenAI API call) your services and recent
  runs up front.

## How a run works

1. shiki reads `services/<name>.dhall`, which describes the service: which
   Deployment to copy, the container, environment variables, init
   containers, and resources.
2. It inspects the live Deployment to get the current image digest and the
   ConfigMap and Secret references.
3. It submits a one-off Job with those settings, running the command you gave
   after `--`.
4. It watches the Job until it finishes, then saves the result to PostgreSQL:
   status, exit code, duration, the Kubernetes failure reason, the log tail,
   and an error summary.

## Installation

shiki is written in Haskell. Build it from source with Nix (recommended) or
with GHC 9.12 and `cabal-install`:

```bash
git clone https://github.com/shinzui/shiki.git
cd shiki

nix develop          # toolchain, plus a local PostgreSQL for development
cabal install exe:shiki
```

At runtime shiki needs:

- a kubeconfig that can read Deployments and create Jobs in the target
  namespace (if `kubectl` works, shiki works; GKE's `gke-gcloud-auth-plugin`
  is supported),
- a PostgreSQL database for the run history. shiki creates and migrates its
  own schema automatically, keeps an independent migration ledger in each
  configured schema, and imports valid history from older shiki releases,
- optionally `fzf`, for the interactive pickers.

## Quick start

```bash
# 1. Point shiki at a database (or pass --db / set SHIKI_DATABASE_URL)
shiki config init --schema-ref <tag-or-commit>
$EDITOR shiki.dhall

# 2. Describe a service in services/<name>.dhall, then check it parses
shiki service show billing

# 3. Run a command and inspect the result
shiki run billing -- reconcile-invoices --since 2026-09-01
shiki runs list
shiki runs logs 3f9c2a1e
```

The [Getting started](./docs/user/getting-started.md) guide walks through each
step in detail.

## Usage at a glance

```bash
shiki run <service> -- <args...>        # run and wait for the result
shiki run <service> --no-wait -- ...    # submit and return right away
shiki runs list                         # recent runs
shiki runs show [id]                    # one run as JSON
shiki runs logs [id]                    # captured log tail
shiki runs error [id]                   # one-line failure summary
shiki runs analyze [id]                 # re-run failure analysis
shiki runs sync [id]                    # record the outcome of unfollowed runs
shiki service show [name]               # inspect a parsed service config
shiki config show                       # inspect shiki.dhall
shiki --env prod runs list              # target a named environment
shiki agent assist --service <service>  # AI session with shiki context
shiki help [topic]                      # built-in guides
shiki completions bash|zsh|fish         # shell completions
```

Wherever `[id]` or `[name]` is optional, leaving it out opens an `fzf`
picker. Run IDs can be shortened to any unambiguous prefix, such as the
8-character ID that `shiki runs list` shows.

## Documentation

The full user guide lives in [`docs/user/`](./docs/user/README.md):

- [Getting started](./docs/user/getting-started.md): from a fresh checkout to
  your first run
- [Commands](./docs/user/commands.md): every subcommand, flag, and
  environment variable
- [Project configuration](./docs/user/project-config.md): `shiki.dhall` and
  named environments
- [Service configuration](./docs/user/service-config.md): writing
  `services/<name>.dhall`
- [Database schema](./docs/user/schema.md): the `runs` table and how
  upgrades work
- [Error analysis](./docs/user/error-analysis.md): heuristic and LLM
  analyzers
- [Agent assist](./docs/user/agent-assist.md): AI sessions preloaded with
  shiki context
- [Help command](./docs/user/help.md): the built-in `shiki help` guides

## Development

```bash
nix develop
process-compose up      # local PostgreSQL, in another terminal
cabal build all
cabal test all
cabal run shiki -- --help
```

The repository contains two packages: `shiki-core`, the library with the
Kubernetes, persistence, and analysis logic, and `shiki-cli`, the `shiki`
executable. Notable changes are recorded in the
[changelog](./CHANGELOG.md).

## License

[BSD-3-Clause](./LICENSE) © 2026 Nadeem Bitar
