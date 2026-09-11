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

- feat(shiki-cli): `shiki help <topic>` re-flows topic prose to the terminal
  width, capped at 140 columns, and accepts `--width COLUMNS` (`-w`) to set it
  explicitly. Indented tables and examples are left as written. Piped output is
  unchanged: when stdout is not a terminal, the topic is printed byte-for-byte
  as embedded.
- feat(shiki-cli): `shiki completions bash|zsh|fish` prints a shell completion
  script. The scripts ask the `shiki` binary for candidates at Tab time, so
  every subcommand and flag completes, Zsh and Fish show descriptions, and the
  scripts keep working when an upgrade moves the binary.

### Changed

- feat(shiki-cli): `shiki --help` lists the global `--db`, `--db-schema`, and
  `--env` flags under an `Environment` heading, and `shiki agent assist --help`
  groups its flags under `Provider` and `Session context`. Running bare `shiki`,
  or a command group such as `shiki runs` without a subcommand, prints that
  command's help page instead of a terse `Missing: COMMAND` error.
- build(shiki-cli): require `optparse-applicative` 0.19, the first release with
  option groups.
- build: require GHC 9.12 (`base >=4.21`) and declare `tested-with: GHC ==9.12.4`.
- build: depend on `baikai`, `baikai-claude`, and `baikai-openai` 0.7 from
  Hackage instead of a GitHub pin of the pre-release tree. The pin no longer
  built once Hackage `claude` reached 1.5, and the Nix build already resolved
  baikai 0.7 from the shared package registry. The mirrored streamly fork pins
  are gone too; baikai 0.7 builds against Hackage streamly 0.11. `time` moves to
  `^>=1.14` to match baikai.
- fix(shiki-core, shiki-cli): baikai 0.7 reports provider, transport, and
  missing-API-key failures in-band as an error-shaped response rather than by
  throwing. `shiki runs analyze --analyzer=baikai:<id>` and
  `shiki agent assist --provider anthropic|openai` now check for that and fail
  with the error, instead of recording an empty summary or printing an empty
  answer and exiting 0. `shiki agent assist` also reports a safety policy the
  claude or codex CLI cannot express instead of launching it.

### Fixed

- fix(shiki-core): migrations no longer run `CREATE SCHEMA IF NOT EXISTS` or
  `create table if not exists schema_migrations` when those objects already
  exist. PostgreSQL checks creation privileges before existence, so a role
  without `CREATE` on the database failed on every invocation even against a
  bootstrapped schema. A role with only `USAGE` on the schema, `SELECT` on
  `schema_migrations`, and `SELECT, INSERT, UPDATE` on `runs` can now record
  runs.
