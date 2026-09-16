---
type: Reference
title: "Commands reference"
description: "Reference every shiki subcommand, its flags, the global database and environment options, the fzf pickers, and the environment variables shiki reads."
docId: DOC-3
tags: [shiki, cli, commands, reference]
generated:
  by: process:claude-code
  at: 2026-09-16T00:46:10Z
---

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
shiki: no Postgres connection string; pass --db, add a shiki.dhall, or set SHIKI_DATABASE_URL / PG_CONNECTION_STRING
```

The `nix develop` shell hook exports `PG_CONNECTION_STRING` for the local
dev database. `--db-schema` is independent from database selection: it picks
the schema inside whichever database the precedence above selected.

`shiki --version` prints `shiki v<package-version> (<short-commit>)`, for
example `shiki v0.1.0.0 (a23b53e)`. The commit is the 7-character SHA the
binary was built from; it is omitted entirely when no build-time Git
information was available. Like the other global options, `--version` is
accepted anywhere on the command line and short-circuits before any
subcommand runs.

shiki applies any pending migrations on every invocation (after acquiring
the pool, before running the subcommand handler). There is no separate
`migrate` step.

The `service`, `config init`, and `config show` subcommands do **not** need a database —
they parse Dhall files and exit. Neither do `help` and `completions`, which
only print text embedded in the binary.

Only `shiki run` and `shiki runs sync` read your kubeconfig. Every other
subcommand, including `runs list`, `runs show`, `runs logs`, `runs error`,
`runs analyze`, and `agent assist`, works with `KUBECONFIG` pointing at
nothing at all.

## Errors and exit codes

Every failure prints exactly one message on **stderr**, starting with
`shiki: `, and exits `1`. A command's result goes to stdout and nowhere else,
so `shiki runs show abc | jq` stays safe to pipe.

There are three exceptions to the exit code:

- `shiki agent assist` exits with the status of the agent it launched, so a
  `claude` session that exits `3` makes shiki exit `3`.
- A successful command exits `0`, including one that legitimately has nothing
  to show (`shiki runs list` on an empty table prints `(no runs recorded yet)`
  and exits `0`).
- Ctrl-C exits with your shell's interrupt status (`130` in bash and zsh) and
  prints nothing extra — except during `shiki run`, which is described below.

A failure shiki has not classified prints `shiki: unexpected error: <message>`
on one line, with no stack trace. That wording means shiki hit something its
authors did not anticipate; please report it.

These are the messages you are most likely to meet. The picker's own messages
are in [Interactive selection](#interactive-selection-fzf) above.

| Situation | Message |
|-----------|---------|
| No connection string from any source | `shiki: no Postgres connection string; pass --db, add a shiki.dhall, or set SHIKI_DATABASE_URL / PG_CONNECTION_STRING` |
| `--db-schema` is not a legal schema name | `shiki: invalid schema name: <reason>` |
| `--env` or `SHIKI_ENV` names an environment `shiki.dhall` does not declare | `shiki: environment <name> is not declared in <path> (declared: <names>)` |
| `shiki.dhall` or a `services/<name>.dhall` does not parse | `shiki: cannot load <path>: ` followed by Dhall's own diagnostic |
| `shiki run` names a service with no config file | `shiki: no service config at services/<name>.dhall` |
| The database is unreachable | `shiki: cannot connect to the database: <reason>` |
| Migrations could not be applied | `shiki: migration failed for schema <schema>: <reason>` |
| A statement failed | `shiki: database error during <operation>: <message> (SQLSTATE <code>)` |
| Your kubeconfig is missing or unreadable | `shiki: cannot load the Kubernetes config: <reason>` |
| A kubeconfig exec credential plugin failed | `shiki: Kubernetes credential plugin failed: <reason>` |
| A Deployment could not be read | `shiki: cannot inspect deployment <name>: <reason>` |
| Any other cluster request failed | `shiki: Kubernetes request failed during <operation>: <reason>` |
| `--analyzer` names a model shiki does not know | `shiki: unknown analyzer override: baikai:<id>` |
| The analyzer's model backend failed | `shiki: baikai backend failed: <reason>` |
| `runs analyze` on a service whose analyzer is `None` | `shiki: analyzer disabled (backend = None)` |
| `shiki config init` would overwrite a file | `shiki: <path> already exists; refusing to overwrite` |
| `shiki config init` cannot write where you pointed it | `shiki: cannot write <path>: <reason>` |
| `shiki help <topic>` does not know the topic | `Unknown topic: <topic>` followed by the list of topics |

Pressing Ctrl-C while `shiki run` is waiting does **not** cancel the
Kubernetes Job — only shiki's watching of it. shiki says so and leaves the run
row alone:

```text
shiki: interrupted; job <job-name> keeps running; record its outcome later with 'shiki runs sync <id>'
```

The run stays `running` and, five minutes later, displays as `unwatched`. Run
`shiki runs sync <id>` once the Job has finished to record its real outcome.

## Interactive selection (fzf)

The subcommands that take a positional `ID` or `NAME` accept that argument as
optional. When it is omitted, shiki opens a fuzzy picker via the local `fzf`
binary, lists the candidates from the canonical source (PostgreSQL for runs,
the `services/` directory for configs), and uses whatever the operator picks.
Precedence is **positional > fzf > error**; passing the positional always
skips the picker.

The picker needs two things:

1. `fzf` on `PATH`, and
2. an openable `/dev/tty`. fzf reads keys from and draws on the terminal
   device, not through shiki's stdin and stdout, so a piped stdin or stdout
   is fine (`shiki runs show | jq` works), while a terminal stdin without a
   usable `/dev/tty` is not enough.

shiki checks this only when the positional is missing, and for the `runs`
commands it checks **before** connecting to the database or running
migrations, so an unusable picker fails fast even when the database is
unreachable.

The run picker shows the 50 newest runs of the routed database, aligned in the
same columns as `shiki runs list` under a row of column titles. The service
picker lists the `services/*.dhall` basenames in lexical order.

The read-only pickers (`runs show`, `runs logs`, `runs error`, `service
show`) select a lone candidate without drawing the picker. `runs analyze`
always asks, even for a single run, and its header warns that Enter re-runs
analysis and overwrites the stored error summary, because analysis writes to
the database and may call a paid model backend.

Every resolution failure is printed on **stderr** and exits `1`:

| Situation | Message |
|-----------|---------|
| No positional and fzf cannot run | `shiki: no run id given and fzf is not available` / `shiki: no service name given and fzf is not available` |
| The `runs` table is empty | `shiki: no runs recorded yet` |
| No `services/*.dhall` files | `shiki: no service configs found in services/` |
| A typed service name has no config file | `shiki: no service config at services/<NAME>.dhall` |
| The picker query matches nothing and Enter is pressed | `shiki: no run matches the picker query` / `shiki: no service matches the picker query` |
| fzf itself fails | `shiki: fzf: <reason>` |
| A typed id prefix matches no run | `no run matching <id>` |
| A typed id prefix matches several runs | `ambiguous id prefix <id>` |

Esc or Ctrl-C inside the picker cancels silently and exits `1` (Unix
convention for cancelled interactive input). Ctrl-C is delegated to fzf, so
it cancels the picker rather than killing shiki.

The subcommands that honour this convention:

- `shiki runs show [ID]` — picker over the 50 newest runs.
- `shiki runs logs [ID]` — same picker.
- `shiki runs error [ID]` — same picker.
- `shiki runs analyze [ID]` — same picker, never auto-selected, then runs the
  analyzer.
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
| `--no-wait`            | off          | Submit the Job and exit immediately. shiki still writes the `pending` and `running` rows; without a watcher heartbeat the row displays as `unwatched` until `shiki runs sync` finalizes it. |
| `--config-dir DIR`     | `services`   | Directory holding `<name>.dhall` files.                                                                                                                              |
| `-- ARG...`            | *(empty)*    | Everything after `--` becomes the container's command-line arguments. The literal `--` prevents optparse from claiming subcommand flags like `--batch-size`.         |

**Exit codes:**
- `0` — the Job reached `Succeeded`.
- non-zero — the Job failed, was killed by Kubernetes (timeout / backoff
  limit), or submission itself threw. Once the run row exists, every failure
  path finalizes it as `failed` before exiting. Failures that happen before
  the row is inserted — the service Dhall file does not load, or the live
  Deployment cannot be read — exit without recording a run.

**Output:** one line, where `<id>` is the run's full UUID. A Job that ran to
a verdict prints `run <id> Succeeded job=<job-name>` or
`run <id> Failed job=<job-name>`. A run that never got a verdict —
submission threw, the API call failed, polling died — prints
`FAILED run <id>: <message>` instead. With `--no-wait`, prints
`submitted job <job-name> (run <id>)`.

The wait path polls at 5-second intervals for up to 96 hours (345 600
seconds) and records a watcher heartbeat in PostgreSQL immediately and
about once a minute. Jobs that exceed the cap exit as `JobTimedOut` and
record `error = "timed out"`.

The Job's pod carries `cluster-autoscaler.kubernetes.io/safe-to-evict:
"false"`. The Job has `backoffLimit: 0`, so a pod the cluster autoscaler
removed while scaling down a node would fail the whole run with
`BackoffLimitExceeded`; the annotation keeps the autoscaler off that node
until the Job ends.

A Job that ends in failure is recorded with `exit_code = 1`, a succeeded Job
with `0`, and a timed-out wait with no exit code; shiki does not read the
container's own exit status.

If the waiting `shiki run` process dies before the Job ends (terminal
closed, machine asleep, process killed), the stored row stays `running` and
displays as `unwatched` once its heartbeat is more than five minutes old. Run
`shiki runs sync` to record what the Job actually did.

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
`(no runs recorded yet)` on stdout and exits 0 — an empty list is not an
error here.

For display, an unfinished row whose watcher heartbeat is missing or more
than five minutes old has status `unwatched`. A displayed `running` row has
a recent heartbeat. This classification does not change the stored
`pending` or `running` status and cannot prove whether the Job itself is
active. When any listed row is unwatched, shiki prints recovery guidance on
stderr; run `shiki runs sync [ID]` to read the cluster's state.

## `shiki runs show [ID]`

Print one `runs` row as pretty JSON. `ID` may be the full UUID or any
unambiguous prefix (the 8-character id `runs list` shows always works). Empty match → `no run matching <id>` on
stderr and exit 1; multiple matches → `ambiguous id prefix <id>` on stderr
and exit 1.

If `ID` is omitted, shiki opens an `fzf` picker over the 50 most recent
runs; see [Interactive selection (fzf)](#interactive-selection-fzf).

The JSON includes everything: command, namespace, image, stored status,
exit code, timestamps including nullable `lastWatchedAt`, duration, the
captured `logTail`, `errorMessage`, `errorSummary`, `errorSummarySource`,
and a full copy of the `serviceConfig` that was used. For an unwatched row,
the JSON remains unchanged and parseable on stdout while stderr explains
that no watcher has reported recently and recommends `shiki runs sync
<id8>`.

## `shiki runs logs [ID]`

Print just the captured log tail. Rows with no logs (no `log_tail`)
print `(no log captured)`. `ID` is optional — omit it to pick from
an `fzf` picker. Id resolution failures (`no run matching <id>`,
`ambiguous id prefix <id>`) print on stderr and exit 1.

The tail is captured when the run is finalized, whether the Job succeeded
or failed: shiki fetches up to 1 000 lines / 256 KiB of the Job pod's logs
into memory, persists the last 200 lines / 64 KiB into `runs.log_tail`, and
discards the rest. For a failed Job, the wider in-memory buffer is what the
inline Heuristic analyzer looks at (on the wait path and in `shiki runs
sync`); the stored tail is what `shiki runs analyze` reads later.

## `shiki runs error [ID]`

Print just the one-line `error_summary`. Rows with no summary print
`(no summary)`. Successful runs never have a summary by contract — see
[Error analysis](./error-analysis.md) for why. `ID` is optional — omit
it to pick from an `fzf` picker. Id resolution failures print on stderr and
exit 1, as for `runs show`.

## `shiki runs analyze`

Re-run the analyzer over a stored run's `log_tail` and overwrite
`error_summary` / `error_summary_source` on that row.

```
shiki runs analyze [ID] [--analyzer heuristic|baikai:<model-id>|none]
```

`ID` is optional — omit it to pick from an `fzf` picker. Unlike the
read-only pickers, this one never selects a lone run by itself: it always
waits for Enter, and its header says that Enter overwrites the stored error
summary. Id resolution failures print on stderr and exit 1, as for
`runs show`.

Backend resolution:

1. `--analyzer ...` if passed.
2. Otherwise the service's declared `analyzer` field from
   `services/<service>.dhall`.
3. Otherwise `Heuristic`, when there is no `services/<service>.dhall` at
   all (e.g. the Dhall file was deleted after the original run — a run can
   outlive the file that produced it).

Only a *missing* file falls back. A `services/<service>.dhall` that is
present but does not parse or type-check is reported as
`shiki: cannot load <path>: ` followed by Dhall's own diagnostic, and
nothing is analyzed — a broken config is a mistake to fix, not a reason to
silently downgrade to the heuristic analyzer.

`baikai:<model-id>` takes a baikai catalog id, and only three are
dispatched: `anthropic_claude_haiku_4_5`, `anthropic_claude_sonnet_4_6`
(both reading `ANTHROPIC_API_KEY`), and `openai_gpt_4o_mini` (reading
`OPENAI_API_KEY`). Any other id fails with
`shiki: baikai backend failed: unknown baikai model: <id>`.
`--analyzer none` exits with `shiki: analyzer disabled (backend = None)`.

Rows with no captured logs print `(no logs captured; cannot analyze)`.

## `shiki runs sync [ID]`

Finalize unfinished runs from the state of their Jobs in the cluster.

```
shiki runs sync [ID]
```

A row is normally finalized by the `shiki run` process following its Job.
When that process is gone, the row stays `pending` or `running`. `sync`
reads each such run's Job and writes the outcome:

| Job in the cluster                   | Result                                                                                                            |
|--------------------------------------|-------------------------------------------------------------------------------------------------------------------|
| still active                         | left `running`                                                                                                    |
| succeeded or failed                  | finalized exactly as `shiki run` would have: status, exit code, the Job's own end time, log tail, error summary |
| not found, run under 2 minutes old   | left alone (the Job may not be created yet)                                                                       |
| not found, run older                 | `failed`, with `error` saying the Job no longer exists and its outcome is unknown                                |

Without `ID`, every `pending` or `running` run is synced, oldest first.
With `ID`, only that run; a run that already finished prints
`already <status>`. Each run prints one line, `run <id8>: <result>`.

Finished Jobs are deleted `ttlSecondsAfterFinished` seconds after they end
(7 days unless the service config sets it), taking their status and pods
with them, so sync within that window to keep the real verdict and logs.

For commands that run longer than a few minutes, prefer
`shiki run --no-wait` followed by an occasional `shiki runs sync <id>`
(every 15-30 minutes, not a tight loop) over a blocking `shiki run`; see
`shiki help long-runs`.

Safeguards:

- A missing Job only counts as gone if the service's Deployment
  (`detectFromDeployment` from the run's stored service config) exists in
  the run's namespace. Otherwise shiki assumes the kube context points at a
  different cluster, reports that on stderr, and leaves the row unchanged.
- The update applies only while the row is still unfinished, so a sync
  never overwrites a result a live `shiki run` recorded first.
- Any other cluster API error is reported for that run on stderr; the
  remaining runs still sync, and the command exits 1.

## `shiki service show [NAME]`

Pretty-print the parsed `ServiceConfig` for `services/<NAME>.dhall` as
JSON. Touches neither the database nor the cluster — useful for
sanity-checking a config change before running anything.

`NAME` is optional — omit it to pick from an `fzf` picker over
`services/*.dhall`; a lone file is shown without drawing the picker. With no
`.dhall` files present, shiki prints
`shiki: no service configs found in services/` on stderr and exits 1. A typed
`NAME` with no `services/<NAME>.dhall` prints
`shiki: no service config at services/<NAME>.dhall` on stderr and exits 1; a
file that exists but does not parse or type-check reports Dhall's error.

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
| `--schema-ref REF` | `master` | Git branch, tag, or commit used in `https://raw.githubusercontent.com/shinzui/shiki/<REF>/schema/package.dhall`. |
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

An unrecognized provider, from `--provider` or `SHIKI_AGENT_PROVIDER`, exits
with
`shiki: unknown agent provider '<x>'. Expected one of: claude-cli, codex-cli, anthropic, openai.`
The model id is not validated by shiki; it is passed to the provider as is.

`agent assist` is a database subcommand, including with `--debug`: it
resolves a connection string and applies migrations before gathering the
session context.

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
| `SHIKI_DB_SCHEMA`         | every database subcommand | Postgres schema for shiki's tables.                                    |
| `SHIKI_ENV`               | `config show`, `run`, `runs`, `agent` | Active project environment when `--env` is absent.                      |
| `SHIKI_AGENT_PROVIDER`    | `shiki agent assist`   | One of `claude-cli`, `codex-cli`, `anthropic`, `openai`.                |
| `SHIKI_AGENT_MODEL`       | `shiki agent assist`   | Provider-specific model id.                                            |
| `ANTHROPIC_API_KEY`       | `runs analyze --analyzer=baikai:anthropic_...`, `agent assist --provider=anthropic` | One-shot API path only; CLI providers use the local CLI's own auth.  |
| `OPENAI_API_KEY`          | `runs analyze --analyzer=baikai:openai_...`, `agent assist --provider=openai` | Same.                                                                  |
