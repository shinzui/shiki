---
type: Improvement Request
title: Accept caller-supplied operation ids for idempotent, adoptable runs
description: Let a caller submit a run under its own operation id and retry the same submission after a crash or a dropped terminal, adopting the existing Kubernetes Job and run instead of starting a second one.
generated:
  by: claude-code/claude-opus-5-5
  at: "2026-10-02T21:10:00Z"
requestId: IR-1
status: proposed
origin: mori://shinzui/shikigami
acceptanceCriteria:
  - id: AC-1
    statement: Two `shiki run --no-wait --operation-id X` invocations with the same service, namespace, and command create exactly one Kubernetes Job and one run row, and both print the same `submitted job <job> (run <uuid>)` line.
    verification: Integration test against a test cluster or a fake Kubernetes API that runs the command twice and compares the Job count, the `runs` row count, and both output lines.
  - id: AC-2
    statement: A retry after a crash at any point between inserting the run row and recording the submitted Job adopts the existing Job or submits it exactly once; it never creates a second Job and never marks the run failed because the Job already exists.
    verification: Tests that inject a failure after the row insert and after the Job create, then rerun the same command and assert one Job and a `running` row with the original run id.
  - id: AC-3
    statement: Reusing an operation id with a different service, namespace, or command is refused with a documented, distinct exit code and creates no Job.
    verification: Test that submits a different request under an existing operation id and asserts the exit code, the error text, and an unchanged Job count.
  - id: AC-4
    statement: Runs submitted without `--operation-id` behave exactly as before.
    verification: The existing test suite passes unchanged, and a regression test asserts the random Job-name format and the output lines of a plain `shiki run`.
---

# Improvement Request: accept caller-supplied operation ids for idempotent, adoptable runs

**Raised by:** `mori://shinzui/shikigami`, while planning
`mori://shinzui/shikigami/plans/78-run-external-operations-from-durable-flows-through-idempotent-shiki-jobs`.
**Addressed to:** `mori://shinzui/shiki`.
**Status:** proposed.


## Why

A caller that retries is safe only if a retry cannot start the work twice. shiki already has what
an unattended caller needs to drive a long run: `shiki run --no-wait` returns as soon as the Job is
submitted and prints the run id, `shiki runs sync <id>` records the outcome later, and
`shiki runs show <id>` prints the run as JSON. The one missing piece is a way to make a submission
repeatable.

A caller can crash or lose its connection after shiki creates the Job but before the caller has
recorded the run id. When it retries, today's shiki starts a second Job. For a read-only command
that is waste. For a data-repair command it is two concurrent writers. The same applies to a human
whose terminal drops during `shiki run`: they cannot tell whether running the command again is safe.

The caller that motivated this request is a durable workflow engine
(`mori://shinzui/shikigami`) running shiki through a generic command executor. Nothing in this
request is specific to that caller. An operation id is an opaque string chosen by whoever runs
shiki.


## Current behavior

All references are to shiki 0.1.0.0 (commit `3f1ff98`).

- `runRun` in `shiki-cli/src/Shiki/Cli/Run.hs` mints a random run id with `newRunId` (UUID v4) and
  a time-plus-random Job name with `generateJobName`
  (`<service>-oneoff-YYYYMMDD-HHMMSS-<6 random letters>`, `shiki-core/src/Shiki/K8s/JobBuilder.hs`).
  A retry always produces a new run and a new Job.
- The run row is inserted and marked `running` before the Job is created. A crash in between
  leaves a `running` row with no Job, which `runs sync` later marks as lost.
- `submitJob` (`shiki-core/src/Shiki/K8s/Runner.hs`) turns any API error, including
  `409 AlreadyExists`, into `JobSubmitFailed`. The run is marked `failed` while the existing Job
  keeps running untracked.
- The Job carries no label or annotation identifying the shiki run.


## Requested behavior

### The option and its storage

Add `--operation-id ID` to `shiki run`. The id is opaque, chosen by the caller, and unique per
operation within one shiki history schema. Validate it as 1 to 200 characters from
`[A-Za-z0-9._:-]`. Store it in a new nullable `runs.operation_id` column with a partial unique
index (`WHERE operation_id IS NOT NULL`), added through the existing pg-migrate manifest in
`shiki-core/sql/migrations/`.

Store a request fingerprint with it: a hash of the service name, namespace, environment, and
command arguments. The fingerprint decides whether a repeated operation id is the same request or a
conflicting one.

### Deterministic Job name and labels

When an operation id is given, derive the Job name from it, for example
`<service>-op-<first 12 hex characters of sha256(operation id)>`, truncated so the whole name stays
within Kubernetes' 63-character limit. Label the Job and its pod template with `shiki.dev/run-id`
and `shiki.dev/operation-hash`, and put the full operation id in the annotation
`shiki.dev/operation-id`. Label values are limited to 63 characters, which is why the full id goes
in an annotation.

### Submission order and adoption

With an operation id, `shiki run` should:

1. Look up the run by operation id. If one exists with the same fingerprint, submit nothing.
   Report the existing run exactly as a fresh submission would: with `--no-wait`, print the same
   `submitted job <job> (run <uuid>)` line; without it, follow the run to completion. If one exists
   with a different fingerprint, refuse with a conflict.
2. Otherwise insert the row as `pending` with the operation id. The unique index makes concurrent
   callers race safely: the loser re-reads and continues as in step 1.
3. Submit the Job under the deterministic name. On `409 AlreadyExists`, read the existing Job. If
   its `shiki.dev/operation-id` annotation matches, adopt it; otherwise refuse with a conflict.
4. Mark the row `running` only after the Job exists.

A row still `pending` on retry means the submission may or may not have happened. The retry resumes
at step 3, where the deterministic name makes either case safe.

### Exit codes

Keep 0 and 1 as they are. Document a distinct exit code for an operation-id conflict (for example
3), so a caller can tell "this request conflicts with an earlier one" apart from "the command
failed".


## Out of scope

Everything else a caller needs already exists and should not change for this request. That
includes `--no-wait`, `runs sync`, `runs show` output, and run statuses. Cancellation and deleting
Jobs are also out of scope.


## Benefits beyond the requesting caller

`scripts/infrastructure/run-oneoff-task.sh` in `mori://tan/mls-service-v2` could pass an operation
id derived from the runbook step. An operator could then rerun a step after a dropped terminal
without risking a duplicate writer.
