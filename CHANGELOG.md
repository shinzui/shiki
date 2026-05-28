# Changelog

All notable changes to shiki are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Initial scaffold: `shiki-core` library and `shiki-cli` (executable `shiki`).
- feat(shiki-cli): EP-8 — `shiki agent assist` opens an interactive AI session
  preloaded with shiki context (services, recent runs, schema, cluster).
  Provider/model configurable via `--provider`/`--model` or
  `SHIKI_AGENT_PROVIDER`/`SHIKI_AGENT_MODEL`.
- feat(shiki-cli): EP-9 — `shiki help` and `shiki help <topic>` show curated
  topic guides embedded into the binary at compile time. Initial topics:
  services, runs, analyzers, agent, schema, env.
- feat(shiki-cli): EP-10 — `shiki runs show / logs / error / analyze` now
  accept the `ID` positional as optional; omitting it opens an `fzf` picker
  populated from the 50 most recent recorded runs. `shiki service show`
  accepts `NAME` as optional; omitting it opens an `fzf` picker populated
  from `services/*.dhall`. When `fzf` is not on `PATH` (or no interactive
  terminal is attached), shiki falls back to the existing "argument
  required" error path.

Smoke transcript (the box is fzf's TUI; the JSON is the existing
`runs show` output for the chosen row):

```text
$ shiki runs show
> 3f2c1a9d  2026-05-27 17:22:11  ingest  Succeeded  12s  exit=0  echo hello
  51a40b22  2026-05-27 17:19:08  ingest  Succeeded  03s  exit=0  echo hi
  2/2
> run>

{
  "runId": "3f2c1a9d-…",
  "serviceName": "ingest",
  "status": "Succeeded",
  …
}
```
