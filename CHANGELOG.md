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
