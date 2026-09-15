SHIKI RUNS


Every invocation of 'shiki run <service> -- ARGS' records one row in the
'runs' table of the configured PostgreSQL database. The 'runs' family of
subcommands queries that table; 'analyze' writes, replacing a run's
error_summary, and 'sync' finalizes runs left unfinished.


RUN LIFECYCLE

  1. 'shiki run' parses the service config, introspects the worker
     Deployment, and constructs a batch/v1 Job manifest.
  2. A row is inserted into 'runs' with status 'pending' and a fresh UUID,
     then flipped to 'running' as the Job is submitted to Kubernetes.
  3. Unless --no-wait was passed, shiki follows the Job to completion:
     polling its status at 5-second intervals (with a 96-hour cap),
     fetching the pod's logs on failure, persisting the last 200 lines /
     64 KiB into runs.log_tail.
  4. On terminal status, shiki finalizes the row with status ('succeeded'
     or 'failed'), exit code, duration, and (on failure) an
     error_summary derived by the Heuristic analyzer.
  5. If the waiting process dies first (or --no-wait was passed), the row
     stays 'running' until 'shiki runs sync' reads the Job and finalizes
     it. Finished Jobs are deleted after ttlSecondsAfterFinished (7 days
     by default), so sync within that window to keep the real verdict and
     logs; a run whose Job is already gone is recorded as failed with an
     "outcome is unknown" error.

For commands that may run longer than a few minutes, read
'shiki help long-runs' first: submit with --no-wait, poll sparingly, and
record the result with 'shiki runs sync'.


THE RUNS TABLE COLUMNS

  id                    UUID. Subcommands accept any unambiguous prefix.
  service_name          Logical service name from the config.
  command               argv passed to the container (text[]).
  namespace             The Kubernetes namespace the Job ran in.
  job_name              <service>-<timestamp>-<rand>, unique per run.
  image                 Image digest read from the live Deployment at
                        submit time.
  status                pending | running | succeeded | failed.
  exit_code             The container's exit code; NULL on pending /
                        running and on pre-container failures.
  started_at            UTC timestamp of insert.
  ended_at              UTC timestamp of finalize; NULL while pending /
                        running.
  duration_ms           ended_at - started_at, in milliseconds.
  log_tail              Last 200 lines / 64 KiB of the pod's logs.
  service_config        JSONB snapshot of the parsed ServiceConfig used
                        for this run.
  error                 Kubernetes-side reason (e.g. BackoffLimitExceeded).
  error_summary         Log-derived one-liner. NULL for successful runs.
  error_summary_source  Which analyzer produced error_summary
                        ('heuristic' or 'baikai:<model-id>').
  created_at            Row insert time.
  updated_at            Last update time.


QUERYING RUNS

  shiki runs list                       Newest 20 runs as a table.
  shiki runs list --service NAME        Filter by service.
  shiki runs list --limit 50            Wider window.

  shiki runs show <id>                  One row as pretty JSON.
  shiki runs logs <id>                  log_tail verbatim.
  shiki runs error <id>                 error_summary one-liner.
  shiki runs analyze <id>               Re-run an analyzer over log_tail
                                        (see 'shiki help analyzers').
  shiki runs sync                       Finalize every unfinished run from
                                        its Job in the cluster.
  shiki runs sync <id>                  Finalize one run.

Omit <id> on show, logs, error, or analyze to pick from the 50 newest runs
in an fzf picker (requires fzf on PATH and a terminal). show, logs, and
error take a lone run without asking; analyze always asks, because it
overwrites the stored error summary. See docs/user/commands.md.


ID PREFIX CONVENTIONS

Every 'runs' subcommand that takes an <id> accepts the full UUID or any
unambiguous prefix. The default table view prints the first 8 characters
of each row's UUID; that 8-character prefix is the convention. Empty
matches and ambiguous prefixes both print a message on stderr and exit
non-zero.


Full reference: docs/user/getting-started.md, docs/user/commands.md
See also: 'shiki help long-runs', 'shiki help analyzers', 'shiki help schema'.
