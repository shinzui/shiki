# Bundle Update Log

## 2026-11-17
* **Addition**: IR-2 requests binding each environment to its Kubernetes context and refusing a mismatched run.

## 2026-10-02

* **Addition**: Created the improvement-request bundle, governed by okf-profiles v0.19.0
  `coordination.improvementRequests`.
* **Addition**: IR-1 asks for caller-supplied operation ids: deterministic Job names, adoption of
  an existing Job and run on retry, and a conflict exit code for a reused id. Everything else a
  durable caller needs (`--no-wait`, `runs sync`, `runs show`) already exists.
