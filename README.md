# shiki

> shiki conducts operational commands across Kubernetes services and records what ran, where it ran, and how long it took.

The name comes from 指揮 (*shiki*) — Japanese for "command," "direction," or
"conducting," used both for military command and for an orchestral conductor.
指 means *to point / indicate*; 揮 means *to wave / direct*. Together they
describe what this tool does: it directs operational commands at the right
service in the right cluster, the way a conductor cues an orchestra.

Shiki is a CLI for conducting operational commands across Kubernetes services with a durable execution history. It helps operators run service-specific commands against the right cluster and environment, while recording each run in PostgreSQL with metadata such as the service, command, status, timing, and duration. The goal is to make ad hoc operational work safer, easier to audit, and easier to understand after the fact.

## Layout

This project is split into two cabal packages:

- **`shiki-core`** — the library. Domain types, business logic, and
  the project-wide `Shiki.Prelude` that re-exports
  [`lens`](https://hackage.haskell.org/package/lens) and
  [`generic-lens`](https://hackage.haskell.org/package/generic-lens).
- **`shiki-cli`** — the command-line interface. Exposes
  `Shiki.Cli.runCli` and ships an executable named
  **`shiki`** that just calls it.

Both packages target **GHC `ghc9124`** with `default-language: GHC2024`
and the same warning set + default extensions
(`DeriveAnyClass`, `DuplicateRecordFields`, `OverloadedLabels`, `OverloadedStrings`).

## Database schema

`shiki` installs its tables into a dedicated PostgreSQL schema (`shiki` by default)
so they do not pollute `public`. Override the schema name with `--db-schema=<name>`
on any subcommand, or with `SHIKI_DB_SCHEMA=<name>` in the environment. The default
behavior is unchanged for fresh databases. If you are upgrading from a checkout that
wrote into `public`, either drop the dev database or move the existing tables
manually with this `psql` recipe:

```sql
CREATE SCHEMA IF NOT EXISTS shiki;
ALTER TABLE public.runs              SET SCHEMA shiki;
ALTER TABLE public.schema_migrations SET SCHEMA shiki;
```

Schema names must match `[A-Za-z_][A-Za-z0-9_]*` and fit within PostgreSQL's 63-byte
identifier limit; invalid names exit with `shiki: invalid schema name: …` before any
database work happens.

## Error summaries and analysis backends

Every failed run carries two distinct signals on the `runs` row:

- **`runs.error`** — the Kubernetes-side reason from the failing `V1JobCondition`
  (`BackoffLimitExceeded`, `DeadlineExceeded`, …). Tells you whether the cluster
  killed the Job before it got a chance to finish.
- **`runs.error_summary`** — a short, log-derived one-liner describing what
  actually went wrong inside the container. Capped at 512 characters.
  Accompanied by **`runs.error_summary_source`**, which records which analyzer
  produced the current value (`heuristic`, `baikai:<model-id>`).

When `shiki run` follows a Job to completion it fetches a wider buffer of the
failing pod's logs (up to 1000 lines / 256 KiB into memory), persists the last
200 lines / 64 KiB into `runs.log_tail`, and — only on failure — runs the
deterministic **Heuristic** analyzer to populate `error_summary`. The Heuristic
analyzer currently understands:

- Python tracebacks (the final exception line of the last `Traceback (most
  recent call last):` block)
- JVM exception chains (`Exception in thread "X"` plus the latest `Caused by:`
  line)
- Go panics (`panic:` header plus the preceding `goroutine` context if present)
- Rust panics (`thread '...' panicked at ...`)
- Generic level-prefixed log lines (`ERROR`, `FATAL`, `PANIC`, `EMERGENCY`, the
  bracketed variants, and JSON `"level":"error"` / `"level":"fatal"`)

If no recogniser matches, the summary falls back to the last non-blank line.
Empty / whitespace-only input returns no summary at all.

The analyzer backend is **pluggable**. Each service config can declare a
default via the new `analyzer` field on `ServiceConfig`:

```dhall
let AnalyzerBackend = ../shiki-core/dhall/AnalyzerBackend.dhall
in  { …
    , analyzer = AnalyzerBackend.Heuristic
    -- or: analyzer = AnalyzerBackend.Baikai { model = "anthropic_claude_haiku_4_5" }
    -- or: analyzer = AnalyzerBackend.None
    }
```

The inline `shiki run` path always uses `Heuristic` regardless of the service
default — interactive runs stay deterministic, zero-network, and zero-credential.
To opt into a richer LLM-derived summary, use the post-hoc subcommand:

```bash
shiki runs analyze <id>                                # use the service's declared default
shiki runs analyze <id> --analyzer=heuristic           # force the deterministic backend
shiki runs analyze <id> --analyzer=baikai:anthropic_claude_haiku_4_5
shiki runs analyze <id> --analyzer=baikai:openai_gpt_4o_mini
shiki runs analyze <id> --analyzer=none                # disable analysis
```

`runs analyze` re-runs the chosen backend over the *stored* `log_tail` (the
wider in-memory buffer does not survive process exit) and overwrites
`error_summary` / `error_summary_source` on that row. The Baikai backend goes
through the local
[`shinzui/baikai`](https://github.com/shinzui/baikai-project) library; it
reads `ANTHROPIC_API_KEY` for `anthropic_*` models and `OPENAI_API_KEY` for
`openai_*` models when `Options.apiKey` is unset (it is, by default).

Read the summary either through the full row dump:

```bash
shiki runs show <id>     # JSON; includes errorSummary + errorSummarySource
```

or via the dedicated text-only printer:

```bash
shiki runs error <id>    # prints just the summary, like `runs logs`
```

`runs error` prints `(no summary)` when the row has none — including for
successful runs, whose `error_summary` is always `NULL` by contract (a
successful Job's logs may incidentally contain `ERROR` or `Exception` strings
that were caught and recovered from, so promoting them into `error_summary`
would actively mislead the operator).

## Agent assist

`shiki agent assist` opens an interactive AI session preloaded with shiki's
current view of the operator's local state: the working directory, the
PostgreSQL schema, the cluster context, every `.dhall` file under `services/`,
and the last twenty rows from the `runs` table. The agent then drives shiki's
own subcommands (`shiki run`, `shiki runs list`, `shiki runs error`,
`shiki runs analyze`, `shiki service show`) on the operator's behalf through a
hard-coded allowed-tool list (`Bash(shiki *)`, `Bash(kubectl get *)`,
`Bash(kubectl logs *)`, plus `Read` / `Glob` / `Grep` and a few read-only shell
verbs).

Four providers ship out of the box. The two CLI providers spawn a local
subprocess and hand the terminal over to it; the two API providers issue a
single non-interactive call and print the assistant's text:

```bash
shiki agent assist                                       # claude-cli (default)
shiki agent assist --provider codex-cli                  # Codex CLI
shiki agent assist --provider anthropic --model claude-sonnet-4-6
shiki agent assist --provider openai    --model gpt-4o-mini
shiki agent assist --debug                               # print the rendered system prompt and exit
shiki agent assist --service mls-service-v2 \
                   --prompt "the last run failed, help me re-run with --batch-size 100"
```

Pin defaults via environment variables — CLI flags still win, and a typo in
either variable exits with `shiki: unknown agent provider '<x>'. ...` before
any other work happens:

```bash
export SHIKI_AGENT_PROVIDER=claude-cli
export SHIKI_AGENT_MODEL=claude-sonnet-4-6
```

Flags accepted by `shiki agent assist`:

- `--provider PROVIDER` — `claude-cli`, `codex-cli`, `anthropic`, or `openai`.
- `--model MODEL` — provider-specific model id (e.g.
  `claude-sonnet-4-6`, `gpt-4o-mini`); CLI providers default to whatever
  the local CLI uses.
- `--prompt PROMPT` — the first user-role message sent to the model.
- `--service NAME` — pre-seeds the system prompt with a hint pointing the
  agent at one service.
- `--run ID` — pre-seeds the system prompt with a hint pointing the agent
  at a run id (8-char prefixes work, just like every other `runs` subcommand).
- `--debug` — render and print the system prompt, then exit 0. Useful for
  inspecting what the agent will see before launching a real session.

The API providers (`anthropic`, `openai`) read `ANTHROPIC_API_KEY` and
`OPENAI_API_KEY` from the environment the same way `shiki runs analyze
--analyzer=baikai:...` does.

## Develop

The project ships a Nix flake (`nix-haskell-flake`) that pins GHC and provides
the dev shell. Enter the shell with:

```bash
nix develop      # or: direnv allow, if you use direnv
```

Then build and run:

```bash
cabal build all
cabal run shiki -- hello --name world
```

## License

[BSD-3-Clause](./LICENSE) — (c) 2026 Nadeem Bitar.
