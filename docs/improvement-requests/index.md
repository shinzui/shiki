---
okf_version: "0.2"
---

# Files

- [profile](../../mori/improvement-requests-profile.dhall)

# Improvement Request

- [Accept caller-supplied operation ids for idempotent, adoptable runs](accept-caller-supplied-operation-ids-for-idempotent-runs.md) - Let a caller submit a run under its own operation id and retry the same submission after a crash or a dropped terminal, adopting the existing Kubernetes Job and run instead of starting a second one.
