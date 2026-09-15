# Changelog

All notable changes to shiki are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- feat(shiki-core): Jobs stay in the cluster for 7 days after finishing
  (was 1 hour), configurable per service with the optional
  `ttlSecondsAfterFinished` field. An hour was too short for `shiki runs
  sync` to reliably collect a multi-day import's result. Service files
  that omit the field keep loading.
- docs(shiki-cli): `shiki help long-runs` sets the rules for long Jobs,
  aimed at agents as much as operators: submit with `--no-wait`, poll every
  15-30 minutes rather than continuously, record outcomes with `runs sync`
  within the TTL, and check the kube context first. `shiki help env` now
  says KUBECONFIG is a single file, not a merged list.
- feat(shiki-cli): `shiki runs sync [ID]` finalizes runs left `pending` or
  `running` because no `shiki run` process was following their Job (it
  died, or `--no-wait` was used). A finished Job is recorded with its own
  end time, log tail, and error summary; a Job already gone is recorded as
  `failed` with an "outcome is unknown" error, but only after confirming
  the service's Deployment exists in that namespace, so a kube context
  pointed at another cluster cannot fail live runs.
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
  from `services/*.dhall`. When `fzf` is not on `PATH` (or `/dev/tty`
  cannot be opened), shiki exits 1 with
  `shiki: no run id given and fzf is not available` (or the service
  equivalent) instead.

Smoke transcript (the rows above the prompt are fzf's interface; the JSON is
the `runs show` output for the chosen row):

```text
$ shiki runs show
▌ 7a01bc22  2026-05-28 09:01:00  a-much-longer-service  failed     2m5s      2     migrate
▌ 3f2c1a9d  2026-05-27 17:22:11  ingest                 succeeded  12s       0     reindex --batch 100
  ID        STARTED              SERVICE                STATUS     DURATION  EXIT  COMMAND
  2/2 ─────────────────────────────────────────────────────────────────────
run>

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

- fix(shiki-cli): EP-10 — run and service resolution errors print on stderr:
  `no run matching <id>`, `ambiguous id prefix <id>`, and every picker message
  (`shiki: no runs recorded yet`, `shiki: no service configs found in
  services/`, and the fzf ones). `shiki runs show abc | jq` no longer feeds an
  error message to `jq`. `shiki runs list` still prints `(no runs recorded
  yet)` on stdout with exit 0.
- feat(shiki-cli): EP-10 — the run picker aligns its rows in the same columns as
  `shiki runs list`, under a row of column titles.
- fix(shiki-cli): EP-10 — `shiki runs analyze` with no id no longer selects a
  lone run by itself; the picker always waits for Enter and its header warns
  that Enter overwrites the stored error summary.
- fix(shiki-cli): EP-10 — with no id and no usable fzf, the `runs` commands fail
  before connecting to the database, running migrations, or loading the
  Kubernetes config. A picked run is used as fetched instead of being looked
  up again by id text.

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

- fix(shiki-core): one-off Job pods carry
  `cluster-autoscaler.kubernetes.io/safe-to-evict: "false"`. The Job has
  `backoffLimit: 0`, so a pod the cluster autoscaler removed while scaling
  down its node failed the run with `BackoffLimitExceeded`; a Houston
  property import in prod was lost this way 1h37m in.
- fix(shiki-core): a Kubernetes credential that expires mid-run no longer
  fails the run. shiki minted an exec-plugin token once, when it built the
  client, and reused it for the whole wait; GKE's plugin hands out what is
  left of a one-hour token, so a long `shiki run` eventually polled with a
  dead token, got `401 Unauthorized`, and recorded a healthy Job as failed
  with no exit code. Every Kubernetes call now goes through `dispatchK8s`,
  which mints a fresh credential and retries once on a 401. The polling loop
  also tolerates up to `maxConsecutiveStatusFailures` consecutive status-read
  errors, since a read that fails is not a Job that failed.

- fix(shiki-cli): EP-10 — a picker query that matches nothing now reports
  `shiki: no run matches the picker query` (or `shiki: no service matches the
  picker query`) instead of claiming that no runs, or no service configs,
  exist.
- fix(shiki-cli): `shiki runs list` no longer hangs forever when the table has
  rows. The column-width computation took the length of an infinite list.

- fix(shiki-core): migrations no longer run `CREATE SCHEMA IF NOT EXISTS` or
  `create table if not exists schema_migrations` when those objects already
  exist. PostgreSQL checks creation privileges before existence, so a role
  without `CREATE` on the database failed on every invocation even against a
  bootstrapped schema. A role with only `USAGE` on the schema, `SELECT` on
  `schema_migrations`, and `SELECT, INSERT, UPDATE` on `runs` can now record
  runs.
