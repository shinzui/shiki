---
type: Improvement Request
title: Bind each environment to its Kubernetes context and refuse a mismatched run
description: Let an environment in shiki.dhall name the Kubernetes context its Jobs belong in, submit every run to that context, and refuse a run whose environment and context disagree, so a production command can't quietly go to staging storage or a local cluster.
generated:
  by: claude-code/claude-opus-5-5
  at: "2026-11-17T22:30:00Z"
requestId: IR-2
status: proposed
origin: mori://shinzui/tan-os
acceptanceCriteria:
  - id: AC-1
    statement: An environment in `shiki.dhall` can declare the Kubernetes context its Jobs run in, and `shiki --env <name> run` submits the Job to that context whatever the kubeconfig's current context is.
    verification: Integration test, or a test against a fake Kubernetes client, with two contexts in the kubeconfig and the current context set to the other one. The Job is created in the declared context, and the recorded run names that context.
  - id: AC-2
    statement: A run whose environment declares a context that doesn't exist in the kubeconfig fails before creating a Job or a run row, with a message naming the environment and the missing context.
    verification: Test with a kubeconfig that lacks the declared context. The command exits nonzero with the documented message, and the Job count and `runs` row count are unchanged.
  - id: AC-3
    statement: Before submitting, `shiki run` prints the environment, the Kubernetes context and the namespace it will use.
    verification: Test that captures stdout of a submitted run and asserts one line naming all three, before the `submitted job` line.
  - id: AC-4
    statement: Each recorded run stores the environment and the Kubernetes context it ran in, and `shiki runs list` and `shiki runs show` display them.
    verification: Test that submits runs in two environments and asserts that both commands show the right environment and context for each.
  - id: AC-5
    statement: Environments that declare no context behave exactly as before.
    verification: The existing test suite passes unchanged, and a regression test asserts that a run in an environment without a context uses the current context.
---

# Improvement Request: bind each environment to its Kubernetes context and refuse a mismatched run

**Raised by:** `mori://shinzui/tan-os`, while the work-planner skill
(`mori://shinzui/tan-os`, `agents/skills/work-planner/SKILL.md`; the artifact-level URI for a
tan-os skill isn't defined yet) coordinated the first automatic QA creation for Austin in
`mori://tan/mls-service-v2` on 2026-11-17.
**Addressed to:** `mori://shinzui/shiki`.
**Status:** proposed.


## Context

shiki records production operations in mls-service-v2, so a run that lands in the wrong place
defeats the reason for using it. On 2026-11-17 a session was told to run this production
command:

```bash
shiki run mls-service-v2 -- agent-qualification enable-qa-creation --chapter-id 100
```

It failed before doing anything, for two separate reasons:

- The checkout's `shiki.dhall` sets `defaultEnvironment = "staging"`, so without `--env prod`
  shiki tried to reach the staging database socket for its run storage.
- `shiki run` submits the Job to the kubeconfig's current context. That was a local k3d cluster,
  `k3d-nagare-webhook-readiness-49505`, not the production cluster `sennari`. `shiki run --help`
  offers `--namespace`, `--no-wait` and `--config-dir`, and no way to choose a context.

The workaround was `shiki --env prod run …` after switching the global kubectl context to
`sennari`. That fixes one machine's state for every tool, and nothing stops the next run from
pairing production storage with a local cluster, or staging storage with the production
cluster. Here the mismatch only failed. With a reachable database and a different cluster, it
would have run the command somewhere other than intended and recorded it as a normal run.


## Requested change

Let each environment in `shiki.dhall` name the Kubernetes context that belongs with its run
storage, and have `shiki run` use that context for the Job rather than the kubeconfig's current
context. Refuse the run before any write when the declared context is missing. Print the
environment, context and namespace before submitting, and store the environment and context
on the run, so the history shows where each command ran. Environments without a declared
context keep today's behavior.
