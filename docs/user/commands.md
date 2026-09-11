# Commands reference

Every subcommand `shiki` exposes today, the flags it accepts, and the
environment variables that affect it. For the conceptual walkthroughs see
[Getting started](./getting-started.md), [Error analysis](./error-analysis.md),
and [Agent assist](./agent-assist.md).

## Global options

All subcommands accept these global options. CLI flags always win over
environment variables.

| Flag           | Env var(s)                                        | Default  | Meaning                                                                                       |
|----------------|---------------------------------------------------|----------|-----------------------------------------------------------------------------------------------|
| `--db CONNSTR` | `SHIKI_DATABASE_URL`, then `PG_CONNECTION_STRING` | *(none)* | PostgreSQL connection string. Explicit override for the active project environment database.   |
| `--db-schema SCHEMA` | `SHIKI_DB_SCHEMA`                           | `shiki`  | PostgreSQL schema for shiki's tables. Must match `[A-Za-z_][A-Za-z0-9_]*` and be ≤ 63 bytes. |
| `--env NAME`   | `SHIKI_ENV`                                      | `defaultEnvironment` from `shiki.dhall` | Active project environment for project-local configuration and database routing. |

Database subcommands resolve their connection string in this order:

1. `--db CONNSTR`
2. The active environment's `databaseUrl` from `shiki.dhall`
3. `SHIKI_DATABASE_URL`
4. `PG_CONNECTION_STRING`

If no source is available, shiki exits with:

```text
shiki: no Postgres connection string. Pass --db, add a shiki.dhall, or set SHIKI_DATABASE_URL / PG_CONNECTION_STRING.
```

The `nix develop` shell hook exports `PG_CONNECTION_STRING` for the local
dev database. `--db-schema` is independent from database selection: it picks
the schema inside whichever database the precedence above selected.

shiki applies any pending migrations on every invocation (after acquiring
the pool, before running the subcommand handler). There is no separate
`migrate` step.

The `service`, `config init`, and `config show` subcommands do **not** need a database —
they parse Dhall files and exit. Neither do `help` and `completions`, which
only print text embedded in the binary.

## Interactive selection (fzf)

The read-only subcommands that take a positional `ID` or `NAME` accept
that argument as optional. When it is omitted, shiki opens a fuzzy
picker via the local `fzf` binary, lists the candidates from the
canonical source (PostgreSQL for runs, the `services/` directory for
configs), and replaces the missing positional with whatever the
operator picks. Precedence is **positional > fzf > error**; passing the
positional always skips the picker.

The picker is available when:

1. `fzf` is on `PATH` (shiki probes once at startup with
   `findExecutable`), and
2. shiki has an interactive keyboard — either stdin is a terminal, or
   `/dev/tty` can be opened.

If neither holds, omitting the positional exits with
`shiki: no run id given and fzf is not available` (or the equivalent
service message) on stderr and exit code `1`. The non-interactive
transcript-driven form (`shiki runs show <prefix>`) is unchanged.

Hitting Esc inside the picker cancels without an error message and
exits `1` (Unix convention for cancelled interactive input). Ctrl-C is
delegated to fzf via `delegate_ctlc`, so it cancels the picker rather
than killing shiki.

The subcommands that honour this convention:

- `shiki runs show [ID]` — picker shows the 50 most recent runs.
- `shiki runs logs [ID]` — same picker.
- `shiki runs error [ID]` — same picker.
- `shiki runs analyze [ID]` — same picker, then runs the analyzer.
- `shiki service show [NAME]` — picker over `services/*.dhall`.

## `shiki run`

Submit a one-off Kubernetes Job mirroring a service's live worker
Deployment and record the result.

```
shiki run SERVICE [--namespace NS] [--no-wait] [--config-dir DIR] -- ARG...
```

| Argument / flag        | Default      | Meaning                                                                                                                                                              |
|------------------------|--------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `SERVICE`              | *(required)* | Short name of the service; resolved to `<config-dir>/<SERVICE>.dhall`.                                                                                               |
| `--namespace NS`, `-n` | `defaultNamespace` from the service Dhall | Override the namespace shiki introspects and submits into.                                                                                |
| `--no-wait`            | off          | Submit the Job and exit immediately. shiki still writes the `pending` and `running` rows, but the row stays at `running` until something else completes it.          |
| `--config-dir DIR`     | `services`   | Directory holding `<name>.dhall` files.                                                                                                                              |
| `-- ARG...`            | *(empty)*    | Everything after `--` becomes the container's command-line arguments. The literal `--` prevents optparse from claiming subcommand flags like `--batch-size`.         |

**Exit codes:**
- `0` — the Job reached `Succeeded`.
- non-zero — the Job failed, was killed by Kubernetes (timeout / backoff
  limit), or submission itself threw. In every failure path shiki writes
  a `failed` row before exiting.

**Output:** one line on success (`run <id> Succeeded job=<job-name>`) or
failure (`FAILED run <id>: <message>`). With `--no-wait`, prints
`submitted job <job-name> (run <id>)`.

The wait-path timeout is 96 hours (345 600 seconds) of polling at 5-second
intervals. Jobs that exceed this exit as `JobTimedOut` and record
`error = "timed out"`.

## `shiki runs list`

Recent runs as a fixed-width table, newest first.

```
shiki runs list [--service NAME] [--limit N]
```

| Flag                     | Default | Meaning                                                          |
|--------------------------|---------|------------------------------------------------------------------|
| `--service NAME`, `-s`   | *(off)* | Filter to one service.                                           |
| `--limit N`, `-l`        | `20`    | Max rows.                                                        |

Columns: `ID` (8-char prefix), `STARTED`, `SERVICE`, `STATUS`,
`DURATION`, `EXIT`, `COMMAND`. An empty result prints
`(no runs recorded yet)`.

## `shiki runs show [ID]`

Print one `runs` row as pretty JSON. `ID` may be the full UUID or any
unambiguous 8+ character prefix. Empty match → `no run matching <id>` and
exit 1; multiple matches → `ambiguous id prefix <id>` and exit 1.

If `ID` is omitted, shiki opens an `fzf` picker over the 50 most recent
runs; see [Interactive selection (fzf)](#interactive-selection-fzf).

The JSON includes everything: command, namespace, image, status, exit
code, timestamps, duration, the captured `logTail`, `errorMessage`,
`errorSummary`, `errorSummarySource`, and a full copy of the
`serviceConfig` that was used.

## `shiki runs logs [ID]`

Print just the captured log tail. Rows with no logs (no `log_tail`)
print `(no log captured)`. `ID` is optional — omit it to pick from
an `fzf` picker.

The tail is captured at run-finalize time: shiki fetches up to 1 000
lines / 256 KiB of the failing pod's logs into memory, persists the
last 200 lines / 64 KiB into `runs.log_tail`, and discards the rest. The
wider in-memory buffer is what the inline Heuristic analyzer looks at on
the wait-path; the stored tail is what `shiki runs analyze` reads later.

## `shiki runs error [ID]`

Print just the one-line `error_summary`. Rows with no summary print
`(no summary)`. Successful runs never have a summary by contract — see
[Error analysis](./error-analysis.md) for why. `ID` is optional — omit
it to pick from an `fzf` picker.

## `shiki runs analyze`

Re-run the analyzer over a stored run's `log_tail` and overwrite
`error_summary` / `error_summary_source` on that row.

```
shiki runs analyze [ID] [--analyzer heuristic|baikai:<model-id>|none]
```

`ID` is optional — omit it to pick from an `fzf` picker.

Backend resolution:

1. `--analyzer ...` if passed.
2. Otherwise the service's declared `analyzer` field from
   `services/<service>.dhall`.
3. Otherwise `Heuristic` (e.g. the Dhall file was deleted after the
   original run).

The Baikai backend reads `ANTHROPIC_API_KEY` for `anthropic_*` model ids
and `OPENAI_API_KEY` for `openai_*` ids. `--analyzer none` exits with
`shiki: analyzer disabled (backend = None)`.

Rows with no captured logs print `(no logs captured; cannot analyze)`.

## `shiki service show [NAME]`

Pretty-print the parsed `ServiceConfig` for `services/<NAME>.dhall` as
JSON. Touches neither the database nor the cluster — useful for
sanity-checking a config change before running anything.

`NAME` is optional — omit it to pick from an `fzf` picker over
`services/*.dhall`. With no `.dhall` files present, shiki prints
`(no service configs found in services/)` and exits 1.

This subcommand is exempt from the global `--db`, `--db-schema`, and `--env`
options; they are still accepted but unused.

## `shiki config init`

Create a project-local `shiki.dhall` that imports shiki's public schema package
from GitHub.

```
shiki config init [--schema-ref REF] [--output PATH] [--default-environment NAME]
```

| Flag | Default | Meaning |
|------|---------|---------|
| `--schema-ref REF` | `main` | Git tag or commit used in `https://raw.githubusercontent.com/shinzui/shiki/<REF>/schema/package.dhall`. |
| `--output PATH` | `shiki.dhall` | File to create. Existing files are not overwritten. |
| `--default-environment NAME` | `staging` | Initial `defaultEnvironment` value in the generated file. |

The generated placeholder environments are `staging` and `prod`. Replace their
database URLs before using database-backed commands.

## `shiki config show`

Inspect the project-local `shiki.dhall` file, if one is present in the current
directory or any parent directory.

```
shiki config show [--env NAME]
```

Output includes the discovered file path, declared environments, default
environment, active environment, and the active environment's database URL with
the URI password masked. It does not connect to Postgres. See
[Project configuration](./project-config.md) for the file format and selection
rules.

## `shiki agent assist`

Open an interactive AI session preloaded with shiki's view of the
operator's local state. See [Agent assist](./agent-assist.md) for the
full reference; the flag summary:

```
shiki agent assist [--provider PROVIDER] [--model MODEL]
                   [--prompt PROMPT] [--service NAME] [--run ID]
                   [--debug]
```

| Flag         | Env var                 | Default     |
|--------------|-------------------------|-------------|
| `--provider` | `SHIKI_AGENT_PROVIDER`  | `claude-cli`|
| `--model`    | `SHIKI_AGENT_MODEL`     | provider-specific |

A typo in either env var exits with
`shiki: unknown agent provider '<x>'. Expected one of: claude-cli, codex-cli, anthropic, openai.`

## `shiki completions`

Print a Tab-completion script for Bash, Zsh, or Fish. Once installed,
pressing Tab after `shiki ru` offers `run` and `runs`, Tab after
`shiki runs ` offers the `runs` subcommands, and every flag completes the
same way. Zsh and Fish also show each candidate's description.

```bash
shiki completions bash > ~/.local/share/bash-completion/completions/shiki
shiki completions zsh  > "${fpath[1]}/_shiki"     # or: eval "$(shiki completions zsh)"
shiki completions fish > ~/.config/fish/completions/shiki.fish
```

The scripts are static and short. At Tab time they call `shiki` by name
with optparse-applicative's hidden `--bash-completion-*` flags, and the
parser answers with the candidates, so completions always match the
installed binary's commands without regenerating the script. Because the
script finds `shiki` on `PATH` rather than embedding an absolute path, it
keeps working after an upgrade moves the binary, for example to a new Nix
store path. Completion runs entirely inside the argument parser: pressing
Tab never connects to the database or the cluster. `shiki completions`
itself needs no database either.

Bash completion needs a Bash built with programmable completion (the
`complete` builtin), which every interactive Bash has.

## Environment variable summary

| Variable                  | Read by                | Notes                                                                  |
|---------------------------|------------------------|------------------------------------------------------------------------|
| `SHIKI_DATABASE_URL`      | every database subcommand | Postgres connection string fallback after `--db` and active `shiki.dhall` environment URL. |
| `PG_CONNECTION_STRING`    | same                   | Final fallback. Set by the `nix develop` shell hook to a project-local socket. |
| `SHIKI_DB_SCHEMA`         | every subcommand       | Postgres schema for shiki's tables.                                    |
| `SHIKI_ENV`               | `config show`, `run`, `runs`, `agent` | Active project environment when `--env` is absent.                      |
| `SHIKI_AGENT_PROVIDER`    | `shiki agent assist`   | One of `claude-cli`, `codex-cli`, `anthropic`, `openai`.                |
| `SHIKI_AGENT_MODEL`       | `shiki agent assist`   | Provider-specific model id.                                            |
| `ANTHROPIC_API_KEY`       | `runs analyze --analyzer=baikai:anthropic_*`, `agent assist --provider=anthropic` | One-shot API path only; CLI providers use the local CLI's own auth.  |
| `OPENAI_API_KEY`          | `runs analyze --analyzer=baikai:openai_*`, `agent assist --provider=openai` | Same.                                                                  |
