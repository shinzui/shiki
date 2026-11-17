---
okf_version: "0.2"
---

# Files

- [profile](../../mori/improvement-requests-profile.dhall)

# Improvement Request

- [Accept caller-supplied operation ids for idempotent, adoptable runs](accept-caller-supplied-operation-ids-for-idempotent-runs.md) - Let a caller submit a run under its own operation id and retry the same submission after a crash or a dropped terminal, adopting the existing Kubernetes Job and run instead of starting a second one.
- [Bind each environment to its Kubernetes context and refuse a mismatched run](bind-each-environment-to-its-kubernetes-context.md) - Let an environment in shiki.dhall name the Kubernetes context its Jobs belong in, submit every run to that context, and refuse a run whose environment and context disagree, so a production command can't quietly go to staging storage or a local cluster.
