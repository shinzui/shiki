# Error analysis

Every failed run carries **two distinct error signals** on its `runs`
row, and you almost always want to look at both:

| Column          | Source                                  | Tells you...                                                                       |
|-----------------|-----------------------------------------|------------------------------------------------------------------------------------|
| `error`         | The failing `V1JobCondition` from Kubernetes (`BackoffLimitExceeded`, `DeadlineExceeded`, …) | Whether the **cluster** killed the Job before it finished. |
| `error_summary` | A log-derived one-liner, capped at 512 chars | What actually went wrong **inside the container**.                                  |

Successful runs never have an `error_summary` by contract. A succeeded
Job's logs may incidentally contain `ERROR` or `Exception` strings that
were caught and recovered from, and promoting those into `error_summary`
would actively mislead the operator.

`runs.error_summary_source` records which analyzer produced the current
summary — `heuristic` or `baikai:<model-id>`.

## What you see in the CLI

```bash
shiki runs error <id>     # prints just the summary, or "(no summary)"
shiki runs show <id>      # JSON — includes both errorMessage and errorSummary
shiki runs logs <id>      # raw captured log tail
```

`runs error` prints `(no summary)` for any of: a successful run, a run
whose analyzer found nothing, or a run captured before the analyzer ran.

## Analyzer backends

shiki ships **three** analyzer backends:

### Heuristic (the default)

Deterministic, zero-network, zero-credential. The inline `shiki run`
wait-path **always** uses Heuristic regardless of the service's declared
default — interactive runs stay deterministic.

The Heuristic analyzer currently understands:

- Python tracebacks — the final exception line of the last
  `Traceback (most recent call last):` block.
- JVM exception chains — `Exception in thread "X"` plus the latest
  `Caused by:` line.
- Go panics — the `panic:` header plus the preceding `goroutine`
  context if present.
- Rust panics — `thread '...' panicked at ...`.
- Generic level-prefixed log lines — `ERROR`, `FATAL`, `PANIC`,
  `EMERGENCY`, the bracketed variants (e.g. `[ERROR]`), and JSON-shaped
  `"level":"error"` / `"level":"fatal"`.

If no recogniser matches, the summary falls back to the last non-blank
line of the captured logs. Empty / whitespace-only input returns no
summary at all.

### Baikai (LLM)

Runs through the local
[`shinzui/baikai`](https://github.com/shinzui/baikai-project) library.
Picks the right provider from the model id prefix:

| Model id prefix       | Provider   | API key                |
|-----------------------|------------|------------------------|
| `anthropic_*`         | Anthropic  | `ANTHROPIC_API_KEY`    |
| `openai_*`            | OpenAI     | `OPENAI_API_KEY`       |

The key is read from the environment when shiki's internal
`Options.apiKey` is unset (which it always is — there is currently no
flag for inlining a key).

### None

Disables analysis entirely. Useful for services whose logs are noisy
enough that any summary would mislead more than it helps.

## Declaring a default per service

Each `services/<name>.dhall` config has an `analyzer` field. The Dhall
union lives at
[`shiki-core/dhall/AnalyzerBackend.dhall`](../../shiki-core/dhall/AnalyzerBackend.dhall):

```dhall
< Heuristic | Baikai : { model : Text } | None >
```

Example usage from
[`services/mls-service-v2.dhall`](../../services/mls-service-v2.dhall):

```dhall
let AnalyzerBackend = ../shiki-core/dhall/AnalyzerBackend.dhall

in  { …
    , analyzer = AnalyzerBackend.Heuristic
    -- or: analyzer = AnalyzerBackend.Baikai { model = "anthropic_claude_haiku_4_5" }
    -- or: analyzer = AnalyzerBackend.None
    }
```

The declared analyzer is the **default for `shiki runs analyze`** on
that service's runs. As noted above, the inline `shiki run` path always
uses `Heuristic` regardless.

## Re-running analysis after the fact

```bash
shiki runs analyze <id>                                   # service's declared default
shiki runs analyze <id> --analyzer=heuristic              # force deterministic
shiki runs analyze <id> --analyzer=baikai:anthropic_claude_haiku_4_5
shiki runs analyze <id> --analyzer=baikai:openai_gpt_4o_mini
shiki runs analyze <id> --analyzer=none                   # disable
```

The override is a one-shot. shiki re-runs the chosen backend over the
**stored** `log_tail` (the wider in-memory buffer does not survive
process exit) and overwrites `error_summary` and `error_summary_source`
on that row.

Notable error paths:

- `shiki: analyzer disabled (backend = None)` — `--analyzer=none` was
  used (or the service's default is `None` and no override was passed).
- `shiki: unknown analyzer override: ...` — typo in `--analyzer`.
  Accepted forms: `heuristic`, `none`, `baikai:<model-id>` with a
  non-empty model id.
- `shiki: baikai backend failed: ...` — the Baikai library itself
  rejected the request (bad API key, model id, network failure, …).
- `(no logs captured; cannot analyze)` — the row has `log_tail = NULL`
  (e.g. submission itself failed before logs existed).

After a successful analyze, the row's `error_summary_source` reflects
the analyzer you actually used, not the service default — so running
`runs show <id>` is the easiest way to see which backend produced the
current summary.
