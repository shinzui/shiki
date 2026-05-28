SHIKI ANALYZERS


On a failed run, shiki populates two distinct columns on the runs row:

  runs.error          The Kubernetes-side reason from V1JobCondition (e.g.
                      BackoffLimitExceeded, DeadlineExceeded). Tells you
                      whether the cluster killed the Job before it had a
                      chance to finish.

  runs.error_summary  A short, log-derived one-liner describing what
                      actually went wrong inside the container. Capped at
                      512 characters. Accompanied by runs.error_summary_source,
                      which records which analyzer produced it.


ANALYZER BACKENDS

  Heuristic           Deterministic, zero-network. Recognises Python
                      tracebacks, JVM exception chains, Go panics, Rust
                      panics, and generic level-prefixed log lines. Falls
                      back to the last non-blank line.

  Baikai              LLM-derived summary via the baikai library. Requires
                      ANTHROPIC_API_KEY (for anthropic_* models) or
                      OPENAI_API_KEY (for openai_*) in the environment.
                      Model spelled as 'baikai:<model-id>', e.g.
                      'baikai:anthropic_claude_haiku_4_5'.

  None                Disable analysis. error_summary stays NULL.


WHEN ANALYZERS RUN

The inline 'shiki run' path always uses Heuristic regardless of the
service default. Interactive runs stay deterministic, zero-network, and
zero-credential.

To opt into a richer summary, use the post-hoc subcommand:

  shiki runs analyze <id>                              # service default
  shiki runs analyze <id> --analyzer=heuristic         # force Heuristic
  shiki runs analyze <id> --analyzer=baikai:anthropic_claude_haiku_4_5
  shiki runs analyze <id> --analyzer=none              # disable


ANALYZING SUCCEEDED RUNS

A successful run's error_summary is NULL by contract, even if its logs
contain ERROR or Exception strings. Those messages may have been caught
and recovered from inside the container; promoting them into error_summary
would actively mislead the operator.


Full reference: docs/user/error-analysis.md
See also: 'shiki help runs', 'shiki help env'.
