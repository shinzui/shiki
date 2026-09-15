# shiki User Documentation Log

## 2026-09-15
* **Update**: Document the `shiki service show` message for a typed name with no config file
* **Update**: Audit the user guide against the code: correct the `config init` schema ref default, exit-code and image column semantics, pre-row failure behavior, analyzer override error, agent provider validation and `--debug` database requirement, run id prefix rules, and the help topic catalog; remove duplicated `shiki run` paragraphs
* **Update**: Document pg-migrate ledgers, legacy-history import, and restricted-role grants
* **Update**: Document the run watcher heartbeat column and rollout
* **Update**: Document displayed unwatched run status and recovery guidance

## 2026-09-11
* **Update**: Document exec-plugin credential renewal on 401 and the wait loop's tolerance for consecutive status-read failures.
* **Update**: Correct the agent safety policy, the baikai model allowlist, the generated Job name format, the dev-shell hook location, the shiki run output lines, and the help topic catalog claim; document --version.
* **Migration**: Adopt the shared user-documentation profile and assign stable document handles.
