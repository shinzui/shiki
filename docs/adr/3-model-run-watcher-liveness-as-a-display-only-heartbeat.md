# ADR 3: Model run-watcher liveness as a display-only heartbeat

Status: Accepted

Date: 2026-09-15


## Context

The persisted `running` status historically meant only that no terminal outcome had been
written. It did not distinguish a Job followed by a live `shiki run` process from a detached
`--no-wait` Job or a Job whose waiting process had died. Operators could therefore mistake a
stale database row for evidence that either the watcher or the Kubernetes Job was still
running.

[EP-17](../plans/17-mark-runs-that-no-shiki-process-is-watching-as-unwatched.md) adds a
failure-detector signal for the waiting process. The signal must preserve existing stored
statuses and reconciliation queries, remain usable by restricted database roles, and avoid
changing `updated_at`, whose meaning is a run-state update rather than a watcher-liveness
update.


## Decision

The `runs` table has a nullable `last_watched_at timestamptz` column. A waiting `shiki run`
writes the database's current time immediately after submission and about every 60 seconds
until the wait ends. `--no-wait` does not write a heartbeat. Heartbeat writes update only
rows whose stored status is `pending` or `running`, and do not modify `updated_at`.

Status-rendering paths read the database clock once for their observation and display an
unfinished row as `unwatched` when `last_watched_at` is absent or strictly more than 300
seconds old. A heartbeat exactly 300 seconds old is still considered recent. The fzf picker,
run list, run detail guidance, synchronization messages, and agent context use this displayed
classification.

`unwatched` is not a persisted status and does not prove that the operating-system process or
Kubernetes Job is absent. A paused watcher or repeated heartbeat-write failure can produce the
same observation. Stored status remains `pending` or `running`; `shiki runs sync` remains the
authority for reconciling it with Kubernetes. Explanatory guidance is written to stderr so
JSON and table output on stdout remain machine-readable.


## Consequences

- Existing status constraints and unfinished-run queries need no new status value. Older
  shiki binaries ignore the additive nullable column and continue to work.
- A missing heartbeat makes a newly detached run visibly `unwatched` immediately. A watcher
  that dies can appear healthy for at most a little over five minutes, depending on when its
  last beat occurred.
- Heartbeat failures are warnings rather than run failures. The next interval retries, while
  the Kubernetes Job and its watcher continue independently of this diagnostic write.
- Every environment must apply migration 003 once as the owner of `runs` before a restricted
  runtime role uses the upgraded binary. The existing restricted role's `UPDATE` grant is
  sufficient after migration.
- Consumers must use the database clock for classification. Comparing a database timestamp
  with a workstation clock would make the five-minute boundary sensitive to clock skew.
