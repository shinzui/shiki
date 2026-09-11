# ADR 2: Resolve omitted positionals with typed resolvers that decide early

Status: Accepted

Date: 2026-09-11


## Context

[EP-10](../plans/10-integrate-fzf-for-interactive-id-selection.md) made the positional of
`shiki runs show`, `runs logs`, `runs error`, `runs analyze`, and `shiki service show`
optional. When it is omitted, shiki opens an `fzf` picker (a terminal fuzzy finder run as a
subprocess) over the candidates. The first implementation (May 2026) resolved the picker's
choice back to id text so the existing handlers could look it up again, collapsed every
non-selection outcome into `Nothing`, detected fzf inside the shared database environment,
and always passed fzf's `-1` flag, which accepts a lone candidate without asking.

An architecture review in September 2026 traced four defects to that shape. A query that
matched nothing was reported as "no runs recorded yet". A missing fzf was only reported after
shiki had connected to PostgreSQL, run migrations, and loaded the Kubernetes config.
Resolution errors were printed on stdout, where they corrupted pipelines such as
`shiki runs show abc | jq`. `runs analyze`, which overwrites a stored summary and may call a
paid model, re-analyzed a lone run without confirmation. EP-10 milestones 6–10 rebuilt the
resolvers in `shiki-cli/src/Shiki/Cli/Fzf/Selector/Run.hs` and
`shiki-cli/src/Shiki/Cli/Fzf/Selector/Service.hs` around the decisions below.


## Decision

An omitted positional resolves with the precedence **positional > picker > explicit
error**, never with a silent fallback such as "the most recent run".

Resolution has two phases. The first decides the target (the typed value, or the picker)
from the arguments and a fzf probe, before any expensive resource is acquired. A command
handler that needs a database takes the environment-acquiring function as an argument
(`runRuns :: ((CliEnv -> IO ()) -> IO ()) -> RunsCommand -> IO ()`) so it can decide first.
The second phase looks the target up and returns the entity itself (for runs, the
`RunRecord` fzf returned), not an identifier for the handler to look up again.

Every way resolution can fail is a constructor of one sum type per entity
(`RunLookupFailure`, `ServiceLookupFailure`). Pure functions map fzf results and prefix
matches into it. One pure function renders it to `Maybe Text` (`Nothing` for a silent
cancel), and the dispatcher prints that on stderr and exits 1.

fzf is available exactly when the binary is on `PATH` and `/dev/tty` can be opened, because
fzf reads keys and draws on the terminal device, not through shiki's piped stdin and stdout.
The probe runs only when a picker is needed; fzf configuration is not part of `CliEnv`.

Auto-selecting a lone candidate is opt-in per picker (`withSelectOne`). Read-only pickers
use it. A picker whose choice triggers a write or a paid call does not, and its header says
what Enter does.

Interactive affordances live in `shiki-cli`, never in `shiki-core`.


## Consequences

- A new picker (for example `shiki run [SERVICE]` or run selection in `shiki agent assist`)
  follows the same shape. It gets a target type, a failure sum type, pure mapping and
  rendering functions with unit tests, and a dispatcher that prints failures on stderr. It
  decides whether it can use fzf before acquiring anything expensive.
- Errors from resolution never go to stdout. A command's stdout carries only its result, so
  it stays safe to pipe. An empty listing that is not an error (`shiki runs list` on an empty
  table) still prints on stdout with exit 0.
- Esc and Ctrl-C in a picker exit 1 without a message.
- From a non-interactive shell, including an agent's, `/dev/tty` cannot be opened, so a
  command with an omitted positional fails fast with a clear message instead of waiting on a
  picker nobody can see.
- `runFzf` can be tested without a terminal against a generated fake `fzf` script, as
  `shiki-cli/test/Shiki/Cli/FzfSpec.hs` does. New picker options should be covered the same
  way.
