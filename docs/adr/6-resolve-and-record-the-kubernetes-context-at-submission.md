# ADR 6: Resolve and record the Kubernetes context at submission

Status: Accepted

Date: 2026-11-19

## Context

An environment selects run storage. Two clusters can contain a Deployment with
the same name in the same namespace. Reading a detached Job in the wrong cluster
can therefore turn a healthy run into a recorded failure.

## Decision

Resolve the active project environment once for submission, including when the
operator overrides the database. Resolve its bound context or the current
context from one kubeconfig snapshot before opening the migrating store.
Use that selection for the server, TLS, credentials, and any credential refresh.
Record the environment and effective context in the initial run row.

Reconciliation selects a client per unfinished row using its recorded context.
An unavailable recorded context leaves the row eligible for retry. Rows that
predate destination tracking retain the current-context lookup and Deployment
check. History reads require only the store.

## Consequences

The public Dhall package keeps the original project and environment types.
Additional types let projects opt into context bindings while older files remain
valid. The database records context names as they appeared at submission. A
renamed context must be available under its recorded name for reconciliation.
Operators must keep that name associated with the original cluster.

See [Plan 20](../plans/20-bind-each-environment-to-its-kubernetes-context.md).
