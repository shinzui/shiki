---
type: Reference
title: "Agent assist"
description: "Reference the shiki agent assist providers, preloaded session context, per-provider safety policy, flags, and exit behavior."
docId: DOC-2
tags: [shiki, agent, llm, cli]
generated:
  by: human:nadeem
  at: 2026-09-11T22:39:25Z
---

# Agent assist

`shiki agent assist` opens an AI session preloaded with shiki's current
view of the operator's local state. The agent then drives shiki's own
subcommands on the operator's behalf — `shiki run`, `shiki runs list`,
`shiki runs error`, `shiki runs analyze`, `shiki service show`, plus a
few read-only shell verbs — inside the safety policy shiki picks for the
provider. See [Session safety policy](#session-safety-policy).

## Quick start

```bash
shiki agent assist                                          # interactive Claude Code
shiki agent assist --provider codex-cli                     # interactive Codex CLI
shiki agent assist --provider anthropic --model claude-sonnet-4-6
shiki agent assist --provider openai --model gpt-4o-mini
shiki agent assist --debug                                  # print system prompt, exit 0
shiki agent assist --service mls-service-v2 \
                   --prompt "the last run failed, help me re-run with --batch-size 100"
```

## What the agent sees at session start

shiki gathers a typed snapshot of "what shiki knows right now" and
substitutes it into the system prompt. The snapshot is **best-effort**:
a missing `services/` directory, a broken Dhall file, or a database
error each surface as data on the prompt rather than as exceptions, so
the session still starts and you can still see what *did* work.

The snapshot includes:

- **Working directory** — `cwd` at session-start time.
- **Postgres schema** — the schema name shiki resolved (default
  `shiki`).
- **Cluster** — surfaced as `unknown` today; this slot is reserved for
  later kubeconfig context detection.
- **Services directory** — every `services/*.dhall` file shiki could
  parse, with `name`, `defaultNamespace`, and the analyzer backend
  rendered with the same `--analyzer=...` vocabulary you'd use on the
  command line (`heuristic`, `baikai:<model-id>`, `none`).
- **Recent runs** — up to the last twenty rows from the `runs` table.
  Each row contributes its 8-character id prefix, service name, displayed
  status (`unwatched` for an unfinished row with no recent watcher
  heartbeat), and current `error_summary` (or `-`).
- **Operator hints** — anything you pass via `--service`, `--run`,
  `--prompt`. Each one lands as a markdown bullet inside the prompt's
  hints block. With none of the three set, the block renders as
  `(no hints)`.

Inspect the rendered prompt with `--debug`:

```bash
shiki agent assist --debug
shiki agent assist --debug --service my-service --run abc12345
```

`--debug` prints the system prompt to stdout and exits `0` without
spawning anything. It still needs a database: like every session, it
resolves a connection string and applies migrations before gathering the
recent runs, so it fails if no database is configured.

## Providers

Four providers ship out of the box. Two spawn a local subprocess and
hand the terminal over to it; two issue a single non-interactive call
and print the assistant's text.

| `--provider`  | Mode                | Auth used                                   |
|---------------|---------------------|---------------------------------------------|
| `claude-cli` (default) | Interactive subprocess (`claude` binary) | Whatever `claude` is logged in as.          |
| `codex-cli`   | Interactive subprocess (`codex` binary)  | Whatever `codex` is logged in as.           |
| `anthropic`   | One-shot Messages API call               | `ANTHROPIC_API_KEY`                         |
| `openai`      | One-shot Chat Completions API call       | `OPENAI_API_KEY`                            |

If `claude` / `codex` is not on `$PATH` the CLI providers exit with a
helpful "not found" message instead of a stack trace.

### Default models for the API providers

| Provider     | Default model id        |
|--------------|-------------------------|
| `anthropic`  | `claude-sonnet-4-6`     |
| `openai`     | `gpt-4o-mini`           |

The CLI providers do not have a shiki-side default — they pass through
whatever the local CLI uses if `--model` is omitted.

## Pinning defaults via environment

CLI flags always win. Use the env vars for stable defaults across many
sessions:

```bash
export SHIKI_AGENT_PROVIDER=claude-cli
export SHIKI_AGENT_MODEL=claude-sonnet-4-6
```

An unrecognized provider, from `--provider` or `SHIKI_AGENT_PROVIDER`,
exits with:

```
shiki: unknown agent provider '<x>'. Expected one of: claude-cli, codex-cli, anthropic, openai.
```

…before any context-gathering or subprocess work happens. The provider
name is matched case-insensitively. shiki does not validate the model id;
an unknown model is reported by the provider itself.

## Session safety policy

The two interactive providers express safety differently, because the two
CLIs do. shiki picks the policy for you; neither is configurable from the
shiki command line.

### `claude-cli` — a hard-coded allowed-tool list

`shiki agent assist --provider claude-cli` launches `claude` with this
allowed-tool list:

- `Bash(shiki *)` — drive any shiki subcommand.
- `Bash(kubectl get *)` — read-only cluster inspection.
- `Bash(kubectl logs *)` — pod logs.
- `Bash(pwd)`, `Bash(ls *)`, `Bash(cat *)` — read-only shell verbs.
- `Read`, `Glob`, `Grep` — Claude Code's own filesystem read tools.

The list is scoped to verbs an operator would not be surprised to see
issued on their behalf. Anything else (`kubectl apply`, `kubectl
delete`, `rm`, …) still prompts inside the agent CLI as usual.

### `codex-cli` — a sandbox, not a tool list

`shiki agent assist --provider codex-cli` launches `codex` with sandbox
mode `workspace-write` and approval-on-request — the same default Codex
uses when you launch it by hand. The allowed-tool list above does **not**
apply to this provider; Codex's own sandbox and approval prompts are what
bound the session.

If a launcher cannot express the safety policy shiki asked for, it refuses
without spawning anything and prints `shiki: <reason>` on stderr.

## All flags

```
shiki agent assist [--provider PROVIDER] [--model MODEL]
                   [--prompt PROMPT] [--service NAME] [--run ID]
                   [--debug]
```

| Flag         | Meaning                                                                                                |
|--------------|--------------------------------------------------------------------------------------------------------|
| `--provider` | `claude-cli`, `codex-cli`, `anthropic`, `openai`. Env: `SHIKI_AGENT_PROVIDER`.                          |
| `--model`    | Provider-specific model id. Env: `SHIKI_AGENT_MODEL`.                                                  |
| `--prompt`   | First user-role message sent to the model.                                                             |
| `--service`  | Pre-seeds the hints block with one service name.                                                       |
| `--run`      | Pre-seeds the hints block with one run id (8-char prefix is fine — same convention as `runs show`).    |
| `--debug`    | Render and print the system prompt, then exit `0`.                                                     |

## Exit behavior

- Interactive providers return the spawned CLI's exit code.
- API providers exit `0` on success, non-zero on API failure (the error
  is printed to stderr as `shiki: agent api call failed: ...`).
- `--debug` exits `0` once the prompt is rendered; it exits non-zero
  earlier if the database cannot be resolved or migrated.
- An invalid `--provider` / `SHIKI_AGENT_PROVIDER` exits non-zero before
  the session would have started.
