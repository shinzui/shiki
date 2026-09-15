---
id: 19
slug: adopt-effectful-as-the-io-stack-with-a-shiki-wide-error-handler
title: "Adopt effectful as the IO stack with a shiki-wide error handler"
kind: exec-plan
created_at: 2026-09-15T22:13:04Z
intention: "intention_01m2kha3snextbxnejnkaq46c0"
provenance:
  created_by:
    model: "claude-opus-5[1m]"
    harness: "claude-code"
    at: 2026-09-15T22:13:04Z
  revisions:
    - model: "claude-opus-5[1m]"
      harness: "claude-code"
      at: 2026-09-15T23:08:33Z
      mode: "update"
      note: "Adopt baikai-effectful 0.4.0.2 for the Analyzer interpreter; correct the Nix package-set findings"
    - model: "claude-opus-5[1m]"
      harness: "claude-code"
      at: 2026-09-15T23:27:43Z
      mode: "implement"
      note: "Implementing EP-19: effectful adoption and the shiki-wide error handler"
---

# Adopt effectful as the IO stack with a shiki-wide error handler

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Today, when almost anything outside the fzf pickers goes wrong, `shiki` dies with GHC's
uncaught-exception banner. Point it at a database that is not running and the operator sees
this instead of a sentence:

```text
$ shiki --db postgresql://127.0.0.1:1/none runs show 3f
shiki: Uncaught exception ghc-internal:GHC.Internal.IO.Exception.IOException:

user error (shiki: migration failed for schema shiki: could not inspect migration history: NetworkingConnectionError "connection to server at \"127.0.0.1\", port 1 failed: Connection refused …")
```

A missing `services/<name>.dhall` under `shiki run`, a typo in `--env`, a missing
kubeconfig, a failed SQL statement, and a Dhall syntax error all end the same way, often
with a `HasCallStack backtrace:` block and a doubled `shiki: shiki:` prefix. The error
handling is also scattered: about twenty handlers print their own message and call
`exitFailure`, four modules each carry a private copy of "run this SQL statement or call
`error`", and `shiki runs list` loads the Kubernetes config even though it never talks to
the cluster, so a broken kubeconfig breaks a pure database read.

This plan does two things together, because each makes the other cheap.

First, it moves shiki's IO onto the `effectful` library. An *effect* in effectful is a
named capability that a function lists in its type, such as `RunStore :> es` ("this code
may read and write run rows") or `Kube :> es` ("this code may talk to the cluster"). `Eff
es a` is the monad such code runs in, where `es` is the list of effects available. An
*interpreter* is the function that gives an effect its meaning, for example by running
hasql statements against a connection pool; it removes the effect from the list. Code that
only lists `RunStore` cannot open files or call the cluster, and a test can swap the
PostgreSQL interpreter for an in-memory one. effectful also provides a typed error effect,
`Error e`, which lets any function `throwError` a value of type `e` that the top of the
program catches as a plain `Either`.

Second, it gives shiki one top-level error handler. Every failure becomes a value of one of
two sum types (`Shiki.Error.ShikiError` for failures from shiki-core, and
`Shiki.Cli.Error.CliError` for command-level failures), is rendered by one pure function,
printed on stderr as a single `shiki: …` line, and exits 1. Anything unexpected is still
caught at the top, printed as `shiki: unexpected error: <message>` without a backtrace, and
exits 1. A deliberate exit code (for example the exit status of the `claude` process that
`shiki agent assist` launches) passes through unchanged, and Ctrl-C still exits with the
shell's interrupt status.

After this plan, an operator can see it working with:

```text
$ shiki --db postgresql://127.0.0.1:1/none runs show 3f; echo "exit=$?"
shiki: cannot connect to the database: connection to server at "127.0.0.1", port 1 failed: Connection refused
exit=1
$ KUBECONFIG=/nonexistent shiki runs list -l 3          # works: no cluster needed
$ shiki run no-such-service -- echo hi; echo "exit=$?"
shiki: no service config at services/no-such-service.dhall
exit=1
$ shiki --env typo runs list; echo "exit=$?"
shiki: environment typo is not declared in /path/to/shiki.dhall (declared: dev, prod)
exit=1
```

and a developer can see it in the types: `grep -rn "exitFailure\|error (\|try @SomeException" shiki-*/src`
returns only the handful of documented exceptions listed in Milestone 5.

The exit-code contract does not change: every rendered failure exits 1, as
[ADR 2](../adr/2-resolve-omitted-positionals-with-typed-early-resolvers.md) and
`docs/user/commands.md` already document. What changes is that the contract now holds for
every command.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

### M1 — Prototype: dependencies and effectful contract tests — done 2026-09-15

- [x] Add `effectful-core ^>=2.7.1.1`, `effectful ^>=2.7.1.0`, and
      `baikai-effectful ^>=0.4.0.2` to both cabal files. (2026-09-15)
- [x] Make the Nix package set provide effectful-core 2.7.1.2, effectful 2.7.1.0,
      `strict-mutable-base` 2.0.0.0, and baikai-effectful 0.4.0.2 (`nix flake update
      haskell-nix` changed nothing, so all four are pinned in `nix/haskell-overlay.nix`);
      `nix build` succeeds and `./result/bin/shiki --version` prints
      `shiki v0.1.0.0 (dirty)`. `file-io` needed no pin — see Surprises. (2026-09-15)
- [x] Add `shiki-core/test/Shiki/EffectfulContractSpec.hs` proving the seven library
      behaviours listed in Milestone 1; wire it into the core test suite. (2026-09-15)
- [x] `cabal build all` warning-free, `cabal test all` green (63 + 108); all seven
      contract facts hold, so the design is **promoted** unchanged; commit. (2026-09-15)

### M2 — Error types and the top-level handler — done 2026-09-15

- [x] Create `shiki-core/src/Shiki/Error.hs` (`ShikiError` and its sub-types,
      `renderShikiError`, plus `renderConnectionError` / `renderSessionError` /
      `renderUsageError` / `collapseWhitespace` for interpreters to use). (2026-09-15)
- [x] Make `runMigrations` return `Either MigrationFailure ()` instead of calling `fail`;
      export the failure type and `renderMigrationFailure`; update `MigrationSpec` and the
      seven other call sites (a `migrateOrFail` helper in `Shiki.Persistence.TestPg` and
      one in each of `MigrationSpec` and `EnvRoutingSpec`). (2026-09-15)
- [x] Create `shiki-cli/src/Shiki/Cli/Error.hs` (`CliError`, `renderCliError`) and
      `shiki-cli/src/Shiki/Cli/Main.hs` (`runShikiMain`, `CliEff`). (2026-09-15)
- [x] Run `runCli`'s dispatch in `Eff`; convert `resolveConnectionString`, `resolveSchema`,
      `resolveActiveEnvironment`, `runConfigShow`, and `withCliEnv` to throw typed errors;
      `shiki-cli/app/Main.hs` is now `main = runCli >>= exitWith`. (2026-09-15)
- [x] Add `shiki-cli/test/Shiki/Cli/MainSpec.hs` (six handler outcomes plus a
      sixteen-row `renderShikiError` table) and update `EnvRoutingSpec` and
      `ProjectSpec`. (2026-09-15)
- [x] Build warning-free, tests green (63 + 115), acceptance rows 1–6 checked against the
      built binary; commit. (2026-09-15)

### M3 — The `RunStore` effect

- [ ] Create `Shiki.Effect.RunStore` and `Shiki.Effect.RunStore.Postgres` in shiki-core.
- [ ] Convert `Shiki.Cli.Runs`, `Shiki.Cli.Runs.Sync` (store part), the run selector,
      `Shiki.Cli.Agent.Context`, and `Shiki.Cli.Run` (store part); delete `runRead`,
      `runWrite`, `runStmt`, `runSessionUnit`, and the selector's private `query`.
- [ ] Keep "decide the target before connecting" for the run pickers.
- [ ] Add a store spec against a throwaway database and a failure-injection test.
- [ ] Build warning-free, tests green, acceptance rows 7–9; commit.

### M4 — The `Kube` effect, `shiki run`, and Ctrl-C

- [ ] Create `Shiki.Effect.Kube` and `Shiki.Effect.Kube.Client` in shiki-core; load the client
      only for commands whose stack includes `Kube`.
- [ ] Convert `Shiki.Cli.Run` and `Shiki.Cli.Runs.Sync` fully; move the heartbeat onto
      `Effectful.Concurrent.Async`; delete `Shiki.Cli.Env`.
- [ ] Replace `try @SomeException` in the run path with `trySync`; print a `runs sync` hint on
      Ctrl-C and let the interrupt propagate.
- [ ] Update `HeartbeatSpec`; build warning-free, tests green, acceptance rows 10–14; commit.

### M5 — Config and analyzer effects, and the remaining exits

- [ ] Create `Shiki.Effect.ConfigLoader` (IO interpreter) and `Shiki.Effect.Analyzer`
      (interpreter over baikai-effectful's `Baikai` effect).
- [ ] Move `agent assist`'s API one-shot onto `Baikai.Effectful.complete`.
- [ ] Convert `service show`, `runs analyze`, `config show`, `config init`, `help`, and
      `agent assist`; replace the remaining `exitFailure` calls with `CliError` values.
- [ ] Run the audit grep; every remaining hit is on the allow-list in Milestone 5.
- [ ] Build warning-free, tests green, acceptance rows 15–21; commit.

### M6 — Documentation, ADRs, and retrospective

- [ ] Write ADR 5 (effect and error conventions) and update ADR 2.
- [ ] Add "Errors and exit codes" to `docs/user/commands.md` (plus its log entry); update
      `CHANGELOG.md`.
- [ ] Full acceptance matrix, `nix build`, `just user-documentation-validate`; fill in
      Outcomes & Retrospective; commit.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

Findings from the research that shaped this plan (2026-09-15):

- The Nix package set does not have effectful 2.7. shiki's set is
  `pkgs.haskell.packages.ghc9124` extended first by the `haskell-nix` flake input's
  `haskellExtension` (which supplies the author's libraries, including baikai and
  baikai-effectful, from pinned sources such as `baikai-src`) and then by
  `nix/haskell-overlay.nix`; see `flake.module.nix`. A first check on 2026-09-15 omitted that
  extension; evaluating the real composition printed:

  ```text
  effectful=2.6.1.0 effectful-core=2.6.1.0 baikai=0.7.0.0 baikai-effectful=0.4.0.1 strict-mutable-base=1.1.0.0 file-io=absent
  ```

  Hackage's latest are effectful 2.7.1.0 and effectful-core 2.7.1.2. effectful-core 2.7 needs
  `strict-mutable-base >= 2.0.0.0 && < 3` and effectful 2.7 needs `file-io >= 0.1.4`, so those
  two must be supplied as well, and the pinned baikai-effectful is one release behind what
  this plan needs. Milestone 1 gives the evaluation expression.

- `baikai-effectful`, the published effect for the baikai LLM library shiki uses, shipped
  0.4.0.2 to Hackage on 2026-09-15 and moved its bound to `effectful-core >=2.7 && <2.8`
  (0.4.0.1 had required `^>=2.6`, which excluded 2.7). The earlier blocker is therefore gone:
  baikai's published effect is usable on shiki's 2.7 line, and Milestone 5 now builds the
  `Analyzer` interpreter on it (see the Decision Log). Its `Baikai` effect offers `complete`,
  `streamCollect`, and `streamEach`, with interpreters `runBaikai` (baikai's process-global
  provider registry) and `runBaikaiWith` (an explicit registry, which its own tests drive with
  a stub provider). It is policy-free: provider failures come back in-band as an error-shaped
  `Response` whose `responseError` is set, exactly like the `completeRequest` calls shiki
  makes today in `shiki-core/src/Shiki/Analysis/Baikai.hs` and
  `shiki-cli/src/Shiki/Cli/Agent/Launch.hs`.

- On GHC 9.12.4, `displayException` applied to a `SomeException` prints only the message,
  without the exception context that produces `HasCallStack backtrace:` in GHC's own
  top-level handler. A scratch program printed `boom` for `error "boom"` and
  `user error (shiki: migration failed)` for `ioError (userError …)`. The fallback branch
  of the top-level handler relies on this.

- effectful's typed errors travel as exceptions whose `Exception` instance classifies them
  as *asynchronous*. In `effectful-core/src/Effectful/Error/Static.hs`:

  ```haskell
  instance Exception ErrorWrapper where
    -- See discussion in https://github.com/haskell-effectful/effectful/pull/232.
    toException = asyncExceptionToException
    fromException = asyncExceptionFromException
  ```

  So `Effectful.Exception.trySync` (defined as `tryIf @SomeException isSyncException`)
  lets an in-flight `throwError` pass, while `try @SomeException` swallows it. `ExitCode`
  is an ordinary synchronous exception, so `trySync` *does* catch `exitWith`, and a
  catch-all must re-throw it. Milestone 1 turns these facts into tests.

- shiki-core and shiki-cli 0.1.0.0 have never been published to Hackage (no git tags, the
  `CHANGELOG.md` has only `[Unreleased]`, and `agents/skills/release/SKILL.md` says so), so
  changing shiki-core's public API needs no major version bump.

- The run path swallows Ctrl-C. `Shiki.Cli.Run.waitPath` wraps the wait in
  `try @SomeException`, which also catches `UserInterrupt`, so pressing Ctrl-C while
  `shiki run` waits writes a `failed` row with the message `user interrupt` even though the
  Kubernetes Job keeps running.

Findings from implementation:

- Milestone 1, 2026-09-15: all seven contract facts hold on effectful-core 2.7.1.2 /
  effectful 2.7.1.0 / GHC 9.12.4, so no design in Milestones 2–4 needed adjusting:

  ```text
    Shiki.EffectfulContract
      trySync lets a typed error through:           OK
      trySync catches ExitCode:                     OK
      trySync does not catch UserInterrupt:         OK
      bracket cleanup runs under throwError:        OK
      a dynamic effect works inside withAsync:      OK
      throwError in a withAsync child reaches wait:  OK
      displayException has no backtrace:            OK
  ```

- `file-io` did not need a Nix pin, and the plan's reading of the evaluation expression was
  wrong about it. The expression maps a `null` attribute to `absent`, and nixpkgs sets an
  attribute to `null` exactly when GHC already ships the library. GHC 9.12.4 ships `file-io`
  behind its bundled `directory-1.3.10.1`, so overriding it made Cabal abort:

  ```text
  Warning:
      This package indirectly depends on multiple versions of the same package. This is very likely to cause a compile failure.
        package directory (directory-1.3.10.1-648c) requires file-io-0.1.6-4839
        package effectful (effectful-2.7.1.0) requires file-io-0.1.6-IkjZGACTP3H6A2ajwrVuaT
  *** abort because of serious configure-time warning from Cabal
  ```

  Dropping the `file-io` entry from `nix/haskell-overlay.nix` fixed it. `strict-mutable-base`
  really is 1.1.0.0 in the set (a real version, not `null`) and does need its 2.0.0.0 pin.

- `nix flake update haskell-nix` produced no change to `flake.lock`, so that input still pins
  baikai-effectful 0.4.0.1 and effectful 2.6.1.0. All four pins listed in Milestone 1 were
  therefore added to `nix/haskell-overlay.nix` by hand, with hashes obtained ahead of the
  build rather than by reading them off a failure:

  ```bash
  $ nix-prefetch-url --unpack https://hackage.haskell.org/package/effectful-2.7.1.0/effectful-2.7.1.0.tar.gz \
      | tail -1 | xargs nix hash to-sri --type sha256
  sha256-1jr7uWldG/qzNljv41c8ustRFNLnD9DuOFBmL3BYT6g=
  ```

- Declaring an effect needs `{-# LANGUAGE TypeFamilies #-}`. `GHC2024`, the project's
  `default-language`, does not include it, so `type instance DispatchOf E = Dynamic` fails
  with `Illegal family instance for 'DispatchOf'`. Every module that declares an effect
  carries the pragma; it is not added to `default-extensions`, so the extension stays visible
  at each declaration site.

- `shiki-cli-test`'s `Shiki.Cli.Agent.Launch` case "debug path writes the prompt and exits
  success" fails intermittently (once in roughly six runs, both before and after this
  milestone's changes). Its `captureStdout` helper swaps the process's stdout file
  descriptor with `hDuplicateTo`, and tasty's own progress output for the preceding test can
  still be sitting in stdout's buffer when the swap happens, so it lands in the captured
  file. Nothing in this plan touches that path — Milestone 1 changes only dependency bounds
  and adds a shiki-core test module — so the flake is pre-existing and is left alone here.

- Milestone 2, 2026-09-15: three library messages are laid out for a terminal and are not
  one line. libpq adds a tab-indented hint to a connection failure, `yaml` prefixes its
  exception with `YAML exception:` and a newline, and Dhall prints a full caret diagnostic.
  The first two are collapsed with `Shiki.Error.collapseWhitespace`, which turns

  ```text
  shiki: cannot connect to the database: connection to server at "127.0.0.1", port 1 failed: Connection refused
  	Is the server running on that host and accepting TCP/IP connections?
  ```

  into one line that keeps the hint. Dhall's diagnostic is kept as it is (see the Decision
  Log), so acceptance rows 4 and 16 read "one message", not "one line".


## Decision Log

Record every decision made while working on the plan.

- Decision: Adopt effectful in both packages. shiki-core defines the effects and their IO
  interpreters; shiki-cli's handlers run in `Eff`.
  Rationale: Chosen by the user on 2026-09-15. The effects describe shiki's domain (run
  storage, the cluster, configuration, analysis), which lives in shiki-core. The core has
  never been published, so its API can change without a PVP major bump.
  Date: 2026-09-15.

- Decision: Target effectful 2.7.1.x: `effectful-core ^>=2.7.1.1` (2.7.1.1 fixed a
  per-operation performance regression in dynamically dispatched effects introduced in
  2.7.0.0) and `effectful ^>=2.7.1.0`.
  Rationale: Chosen by the user. 2.7 is the current release line and is tested with GHC
  9.12.4, shiki's compiler. When this was decided, `baikai-effectful` 0.4.0.1 was pinned to
  effectful-core 2.6 and could not be used on 2.7; that cost has since been removed by
  `baikai-effectful` 0.4.0.2 (Hackage, 2026-09-15), which moved to `effectful-core >=2.7 &&
  <2.8`.
  Date: 2026-09-15.

- Decision (superseded later the same day by "Depend on baikai-effectful" below): Keep
  Milestone 5's shiki-owned `Analyzer` effect over baikai's IO API even though
  `baikai-effectful` 0.4.0.2 (Hackage, 2026-09-15) now supports effectful 2.7
  (`effectful-core >=2.7 && <2.8`) and could be depended on directly.
  Rationale at the time: The unblock removes the only forced reason to wrap IO, but the
  high-level, shiki-owned-effect preference below (one `Analyze` operation that hides the
  backend and stays swappable/in-memory-testable) still favors shiki's own effect over
  baikai-effectful's. Adopting `baikai-effectful` directly remains an open option if shiki
  later wants the library's effect surface; revisit at that point.
  Date: 2026-09-15.

- Decision: Depend on `baikai-effectful ^>=0.4.0.2` and implement the `Analyzer` interpreter
  in terms of its `Baikai` effect. The shiki-owned `Analyzer` effect stays exactly as the
  superseded decision describes it — one `Analyze` operation holding shiki's policy (model
  allow-list, system prompt, 256-token request cap, 512-character summary cap, heuristic
  fallback) — but its production interpreter calls `Baikai.Effectful.complete` instead of
  baikai's IO `completeRequest`, and `agent assist`'s API one-shot calls `complete` too.
  Rationale: Chosen by the user on 2026-09-15, after the earlier decision, because the release
  was made for this plan. Both layers are kept, which is what effectful's documentation
  recommends: shiki's high-level effect hides the backend from commands, and the library's own
  effect is the interpreter's implementation, the same way `RunStore`'s interpreter uses
  hasql. It deletes shiki's two hand-rolled `try @SomeException (completeRequest …)` sites and
  lets analyzer tests interpret `Baikai` with a stub provider registry instead of reaching the
  network. The interpreter still guards `complete` with `trySync`, because a transport
  exception must become `ShikiAnalyzerError` rather than the "unexpected error" fallback.
  Date: 2026-09-15.

- Decision: Model PostgreSQL access as a shiki-owned, high-level `RunStore` effect with one
  operation per thing shiki does to the `runs` table, not a generic "run any hasql session"
  effect.
  Rationale: Chosen by the user, and it is what effectful's own documentation recommends:
  the `Effectful` module haddock ranks "a custom effect with high level operations that the
  library in question will help us implement" above thin wrappers, because it hides the
  library and makes the implementation swappable. It adds no dependency, and it lets tests
  use an in-memory interpreter.
  Date: 2026-09-15.

- Decision: Keep exit status 1 for every rendered failure. Re-throw `ExitCode` unchanged,
  and let asynchronous exceptions (Ctrl-C) propagate to GHC, which exits with the interrupt
  status.
  Rationale: Chosen by the user. It preserves the contract ADR 2 and `docs/user/commands.md`
  document. Exit classes can be added later without changing the error types.
  Date: 2026-09-15.

- Decision: Follow effectful's official guidance where the author's own projects disagree
  with one another. Use dynamic dispatch for shiki's effects. Use `Effectful.Error.Static`,
  not `Effectful.Error.Dynamic`. Keep `IOE` (effectful's "may do arbitrary IO" effect) out
  of shiki-core's effect interfaces, so only interpreters require it. Use `trySync` and
  `catchSync`, never `try @SomeException`. Hand-write the `send` smart constructors (no
  `effectful-th`), and do not use `effectful-plugin`.
  Rationale: The user noted that best practices for effectful are not settled, so the plan
  anchors on the library's documentation (`Effectful.hs`, `Effectful/Dispatch/Dynamic.hs`,
  `Effectful/Error/Static.hs`, `Effectful/Exception.hs`) rather than on any one in-house
  project. Hand-written constructors keep Haddock and error messages readable, need no
  Template Haskell, and are a few lines each. The plugin only helps with polymorphic
  effects such as `State Int`, which shiki does not use. Milestone 6 records the conventions
  that survive implementation in ADR 5.
  Date: 2026-09-15.

- Decision: Allow shiki-cli handlers to use `IOE` for the terminal and the local process:
  stdout and stderr, terminal detection and size, environment variables, the current time,
  random job names, run ids, the fzf subprocess, and launching `claude` or `codex`.
  Rationale: None of these has a second interpretation shiki needs today, effectful's
  bundled wrappers for them are one-to-one and add nothing over `liftIO`, and wrapping each
  one would double the size of the migration. The rule that matters, "shiki-core effects do
  not expose IO", still holds. ADR 5 states the boundary so it can be tightened later.
  Date: 2026-09-15.

- Decision: Two error types, not one. `Shiki.Error.ShikiError` (shiki-core) covers
  configuration, database, cluster, and analyzer failures. `Shiki.Cli.Error.CliError`
  (shiki-cli) covers command-level failures: run and service lookup failures, an unknown
  help topic, a refused overwrite, a run that did not succeed. The top level discharges both
  with `runErrorNoCallStack` and renders either with one function.
  Rationale: shiki-core cannot mention CLI types such as `RunLookupFailure`, and folding core
  errors into a CLI type everywhere would need a `mapError` combinator that effectful does
  not provide. Two stacked handlers at one place cost nothing.
  Date: 2026-09-15.

- Decision: Some failures render no message. `CliError` has constructors (`RunPickerCancelled`
  inside the lookup failures, and `CommandFailed`) whose message the handler already printed,
  so the renderer returns `Maybe Text` and the top level prints nothing for `Nothing` but still
  exits 1.
  Rationale: This keeps ADR 2's silent cancel and the existing output of `shiki run` (which
  prints the run outcome on stdout before failing) unchanged, while still routing the exit
  through the single handler.
  Date: 2026-09-15.

- Decision: The fallback for an unexpected synchronous exception prints
  `shiki: unexpected error: <displayException>` and exits 1. It never shows a backtrace.
  Rationale: Anything reaching the fallback is a bug or a failure no one has classified yet.
  One readable line is still better than the banner, and the word "unexpected" tells the
  reader to report it. On GHC 9.12.4 `displayException` omits the backtrace (see Surprises).
  Date: 2026-09-15.

- Decision: Ctrl-C while `shiki run` waits no longer marks the run `failed`. The run path
  catches only synchronous exceptions. On an interrupt, it prints
  `shiki: interrupted; job <name> keeps running; record its outcome later with 'shiki runs sync <id>'`
  on stderr and re-throws.
  Rationale: The Job does keep running in the cluster, so `failed` was false. After the
  watcher stops, the row's heartbeat goes stale and it displays as `unwatched`, which is the
  situation [ADR 3](../adr/3-model-run-watcher-liveness-as-a-display-only-heartbeat.md)
  designed `unwatched` and `runs sync` for.
  Date: 2026-09-15.

- Decision: Load the Kubernetes client only in the interpreter for the `Kube` effect, so
  commands whose stack has no `Kube` (`runs list`, `show`, `logs`, `error`, `analyze`, and
  `agent assist`) never read the kubeconfig.
  Rationale: Today `withCliEnv` loads the client for every database command, so a missing
  kubeconfig or a failing exec credential plugin breaks pure database reads. Making the
  dependency visible in the effect list removes that coupling for free.
  Date: 2026-09-15.

- Decision: Start with a prototype milestone that proves the library behaviour the design
  depends on, and keep the proof as a permanent test module.
  Rationale: The error handler's correctness depends on facts about effectful and GHC
  exceptions (typed errors pass `trySync`, `ExitCode` does not, `bracket` runs cleanup
  under `throwError`, effects are usable from a thread started with `withAsync`, and so on)
  that are easy to get wrong and would silently regress on a library upgrade. Tests make
  them visible. Milestone 1 also proves the Nix build before any code depends on 2.7.
  Date: 2026-09-15.

- Decision: Promote the prototype. All seven Milestone 1 contract facts hold as written, and
  `nix build` produces a working binary against the pinned 2.7 packages, so Milestones 2–6
  proceed exactly as planned with no fallback to effectful 2.6 and no change to the heartbeat
  design.
  Rationale: The promote-or-fall-back rule in Milestone 1 makes this the decision point. The
  evidence is `cabal test shiki-core-test -p EffectfulContract` (seven OK lines, recorded in
  Surprises) and `./result/bin/shiki --version` from a `nix build`.
  Date: 2026-09-15.

- Decision: Do not pin `file-io` in `nix/haskell-overlay.nix`, contrary to Milestone 1's
  instruction to supply it.
  Rationale: GHC 9.12.4 already ships `file-io` behind its bundled `directory`, and adding a
  second copy makes Cabal abort at configure time with "indirectly depends on multiple
  versions of the same package". The plan's premise came from reading `absent` in the
  evaluation expression, which prints `absent` both for a missing attribute and for the
  `null` that nixpkgs uses to mean "GHC provides this". Evidence is in Surprises.
  Date: 2026-09-15.

- Decision: A failure to load a Dhall file keeps Dhall's own multi-line diagnostic after the
  `shiki: cannot load <path>: ` prefix, instead of being collapsed onto one line. libpq's and
  yaml's messages *are* collapsed.
  Rationale: The point of the acceptance matrix's "one line" is that the operator gets one
  readable message instead of GHC's banner, and that holds either way. Dhall's diagnostic is
  a caret pointing at the offending token; flattening it destroys the only thing that tells
  the operator where the typo is, while libpq's hint and yaml's prefix lose nothing when
  collapsed. Acceptance rows 4 and 16 are reworded to "one message, no banner, no backtrace".
  Date: 2026-09-15.

- Decision: `CliError.UnknownHelpTopic` carries the available topic names as well as the
  requested one (`UnknownHelpTopic !Text ![Text]`), rather than just the topic.
  Rationale: The plan's one-field version forces `renderCliError` to import
  `Shiki.Cli.Help` for `helpTopics`, and Milestone 5 has `Shiki.Cli.Help` importing
  `Shiki.Cli.Error` to throw the error — a module cycle. Passing the list at the throw site
  keeps both modules acyclic and the message identical.
  Date: 2026-09-15.

- Decision: `CliError` also has `AgentBinaryMissing !Text !Text` (binary name plus install
  hint) and a separate `AgentPromptInvalid !Text`, where the plan had `AgentBinaryMissing
  !Text` and folded the prompt-render error into `AgentRequestFailed`.
  Rationale: Today's messages differ per binary (`claude` points at its install docs,
  `codex` says to authenticate the CLI), and the prompt-render error prints
  `shiki: <message>`, not `shiki: agent api call failed: <message>`. Both extra fields exist
  only so Milestone 5 can move the wording across unchanged, which is what the acceptance
  matrix asks for.
  Date: 2026-09-15.

- Decision: `Shiki.Error` also exports `renderConnectionError`, `renderSessionError`,
  `renderUsageError`, and `collapseWhitespace`, which the plan named but did not place.
  Rationale: They are the pieces that turn a hasql failure into the `Text` a `StoreError`
  carries, and every interpreter that touches the database needs them. Putting them beside
  the type they feed keeps the mapping in one file and lets `MainSpec` assert the wording.
  Date: 2026-09-15.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

**The repository.** `shiki` is a Haskell command-line tool that runs one-off Kubernetes Jobs
for microservices and records each run in PostgreSQL. It is a cabal project with two
packages. `shiki-core/` holds domain types, persistence (hasql and hasql-pool), the
Kubernetes runner, analyzer backends, and Dhall configuration loading. `shiki-cli/` holds
the optparse-applicative parser and every command handler; its executable's `main` in
`shiki-cli/app/Main.hs` is just `main = runCli`. The code is about 6,200 lines across 45
modules.

Build and run from the repository root inside `nix develop`: `just build` runs
`cabal build all`, `just test` runs `cabal test all`, `just shiki <args>` runs
`cabal run shiki -- <args>`, `just fmt` runs `nix fmt` (fourmolu and cabal-gild), and
`just nix-build` runs `nix build`. `just up` starts a local PostgreSQL through
process-compose. The compiler is GHC 9.12.4 (`tested-with: ghc ==9.12.4`, dev shell
`ghc9124` in `nix/haskell.nix`).

**Conventions.** Both packages share a `common` cabal stanza: `GHC2024`, default extensions
`DeriveAnyClass`, `DuplicateRecordFields`, `MultilineStrings`, `OverloadedLabels`,
`OverloadedStrings`, and a strict warning set (`-Wall -Wcompat -Wredundant-constraints
-Wmissing-export-lists -Wmissing-deriving-strategies` and others). The build is warning-free
and must stay so. Record fields have no type prefix and are read with generic-lens labels
(`cfg ^. #name`); a module using `#label` syntax must itself write
`import Data.Generics.Labels ()`. Every module imports `Shiki.Prelude`
(`shiki-core/src/Shiki/Prelude.hs`), which re-exports a few base, aeson, and text names plus
all of `Control.Lens`. Because it re-exports lens, some operator names clash with other
libraries (for example `System.FilePath.<.>`); hide or avoid the clashing name rather than
qualifying an operator. Every `deriving` clause names its strategy
(`deriving stock (Generic, Eq, Show)`).

**Architecture Decision Records** live in `docs/adr/` as plain Markdown.
[ADR 1](../adr/1-follow-haskell-jitsurei-conventions.md) records the conventions above and
says a catalog change is adopted by a new plan that revises it; the haskell-jitsurei
catalog (`mori://shinzui/haskell-jitsurei`) has no effectful or error-handling pattern, so
this plan creates ADR 5 instead of revising ADR 1.
[ADR 2](../adr/2-resolve-omitted-positionals-with-typed-early-resolvers.md) governs the
pickers: an omitted positional resolves as positional > picker > explicit error, the target
is decided before any database connection, every resolution failure is a typed value
rendered by one pure function on stderr with exit 1, and Esc or Ctrl-C in a picker exits 1
silently. This plan generalizes that rule from the pickers to every command, and must keep
its ordering guarantee.
[ADR 3](../adr/3-model-run-watcher-liveness-as-a-display-only-heartbeat.md) says a waiting
`shiki run` writes a heartbeat about every 60 seconds, and an unfinished row with no
heartbeat in 300 seconds displays as `unwatched`, with `shiki runs sync` as the authority for
reconciling it. [ADR 4](../adr/4-use-pg-migrate-with-per-shiki-schema-ledgers.md) says
migrations run through pg-migrate over a dedicated connection whose `search_path` is the
shiki schema.

**How a command runs today.** `Shiki.Cli.runCli` in `shiki-cli/src/Shiki/Cli.hs` parses the
options and dispatches:

```haskell
runCli :: IO ()
runCli = do
  opts <- Opt.customExecParser cliPrefs parserInfo
  case opts ^. #command of
    ServiceShow nm -> serviceShowHandler nm
    Help helpOpts -> runHelp helpOpts
    Completions shell -> runCompletions shell
    Config ConfigShow -> runConfigShow (opts ^. #envName)
    Config (ConfigInit initOpts) -> runConfigInit initOpts
    Run runOpts ->
      withDbEnv (opts ^. #dbConnStr) (opts ^. #dbSchema) (opts ^. #envName) $ \_ env ->
        runRun env runOpts
    Runs runsOpts ->
      runRuns
        (\k -> withDbEnv (opts ^. #dbConnStr) (opts ^. #dbSchema) (opts ^. #envName) (\_ env -> k env))
        runsOpts
    Agent agentOpts ->
      withDbEnv (opts ^. #dbConnStr) (opts ^. #dbSchema) (opts ^. #envName) $ \schema env ->
        runAgent env schema agentOpts
```

`withDbEnv` calls `resolveConnectionString` (`shiki-cli/src/Shiki/Cli/Config.hs`: `--db`,
then the active environment's `databaseUrl` from `shiki.dhall`, then `SHIKI_DATABASE_URL`,
then `PG_CONNECTION_STRING`), `resolveSchema` (`shiki-cli/src/Shiki/Cli/Schema.hs`:
`--db-schema`, then `SHIKI_DB_SCHEMA`, then `shiki`), and `withCliEnv`
(`shiki-cli/src/Shiki/Cli/Env.hs`), which does
`bracket (acquirePool cs schema) releasePool`, then `runMigrations cs schema`, then
`loadDefaultClientConfig`, and hands the continuation a `CliEnv { pool, client }`.
`runRuns` (`shiki-cli/src/Shiki/Cli/Runs.hs`) takes the acquisition as a continuation so the
run pickers can decide their target before connecting (ADR 2).

**Where failures escape today.** Each of these reaches GHC's uncaught-exception banner:

1. No connection string: `error "shiki: no Postgres connection string…"` in
   `shiki-cli/src/Shiki/Cli/Config.hs`.
2. Invalid schema name: `error` in `shiki-cli/src/Shiki/Cli/Schema.hs`.
3. `--env` or `SHIKI_ENV` naming an undeclared environment: `error` in
   `resolveActiveEnvironment`, `shiki-cli/src/Shiki/Cli/Project.hs`.
4. A `shiki.dhall` that does not load: exceptions from `loadProjectConfig`
   (`shiki-core/src/Shiki/Project/Config/Dhall.hs`), from `withDbEnv` and from `config show`.
5. An unreachable database or any migration problem: `migrationFailure` calls `fail` in
   `shiki-core/src/Shiki/Persistence/Migration.hs`; its internal `MigrationBootstrapError`
   (`BootstrapConnectionFailed`, `BootstrapSessionFailed`, `LegacyHistoryNotPrefix`,
   `LedgerDefinitionFailed`, `LegacyImportDefinitionFailed`, `LegacyImportFailed`,
   `MigrationExecutionFailed`) is not exported. `migrationFailure`'s message already starts
   with `shiki:`, so the banner shows it twice.
6. A missing or malformed kubeconfig, an unresolvable context, or a failing exec credential
   plugin: `Yaml.decodeFileThrow` and `ExecCredentialError`
   (`shiki-core/src/Shiki/K8s/ExecCredential.hs`, `shiki-core/src/Shiki/K8s/Client.hs`),
   raised by `loadDefaultClientConfig` inside `withCliEnv` for every database command.
7. `shiki run` with a missing or broken `services/<name>.dhall`: `loadServiceConfig`
   (`shiki-core/src/Shiki/Service/Config/Dhall.hs`) is called before any handler.
8. `shiki run` when the Deployment cannot be inspected: `InspectionError`
   (`shiki-core/src/Shiki/K8s/Introspection.hs`) from `inspectDeployment`.
9. Any SQL failure: four private helpers turn a hasql-pool `UsageError` into `error`:
   `runSessionUnit` (`shiki-cli/src/Shiki/Cli/Run.hs`), `runRead`/`runWrite`
   (`shiki-cli/src/Shiki/Cli/Runs.hs`), and `runStmt` (`shiki-cli/src/Shiki/Cli/Runs/Sync.hs`,
   caught per run only inside the sync loop).
10. `runs analyze` when the service's Dhall file does not parse: `effectiveBackend` in
    `shiki-cli/src/Shiki/Cli/Runs.hs` catches only `IOException`.
11. `service show NAME` when the file exists but does not parse (`serviceShowOne` in
    `shiki-cli/src/Shiki/Cli.hs`).
12. `agent assist` when launching `claude` or `codex` throws
    (`shiki-cli/src/Shiki/Cli/Agent/Launch.hs`).
13. `config init` into a missing directory or without permission (`openTempFile` and
    `renameFile` in `shiki-cli/src/Shiki/Cli/ConfigInit.hs`).

Handlers that already report cleanly do it themselves with a message and `exitFailure`:
`failLookup` (`Shiki.Cli.Runs`), `failService` (`Shiki.Cli`), the analyzer error branch of
`doAnalyze`, `syncRuns`/`syncRun`, `finalizeFailed` and `finalizeOutcome` (`Shiki.Cli.Run`),
provider parsing and child exit in `Shiki.Cli.Agent` (`exitWith code`), missing binaries and
API errors in `Shiki.Cli.Agent.Launch`, the refused overwrite in `Shiki.Cli.ConfigInit`, and
the unknown topic in `Shiki.Cli.Help`.

**Other IO that the migration touches.** `Shiki.Cli.Heartbeat.withHeartbeat :: Int -> IO () -> IO a -> IO a`
forks a thread with `forkIO` that runs a database write every 60 seconds while
`Shiki.K8s.Runner.runJob` polls the Job. `Shiki.K8s.Client.ClientEnv` stores an
`IORef` config and `renewAuth :: Maybe (IO KubernetesClientConfig)`, which re-runs the exec
credential plugin on a 401 response; that stays inside the Kube interpreter, in IO.
`Shiki.K8s.Runner.collectOutcome` calls `Shiki.Analysis.Backend.runAnalyzer` internally to
summarize a failed Job's log; that also stays inside the Kube interpreter.
`Shiki.Analysis.Baikai.runBaikai :: Text -> Text -> IO (Either Text Text)` calls the baikai
LLM library.

**Persistence statements** are pure hasql `Statement` values in
`shiki-core/src/Shiki/Persistence/Run.hs`: `insertRunStatement`, `markRunRunningStatement`,
`completeRunStatement`, `completeUnfinishedRunStatement` (returns whether a row was
updated), `updateErrorSummaryStatement`, `touchRunWatchedStatement`, `databaseNowStatement`,
`listRecentRunsStatement`, `listRecentRunsByServiceStatement`, `findRunByPrefixStatement`
(at most two rows), `listUnfinishedRunsStatement`, and `getRunStatement`. The pool comes
from `Shiki.Persistence.Connection.acquirePool :: ConnectionString -> Schema -> IO Pool.Pool`
(size 5, 10-second acquisition timeout, sets `search_path`), released by `releasePool`.
`Pool.use pool (Session.statement input stmt)` returns `IO (Either Pool.UsageError b)`.

**Tests.** `shiki-core-test` and `shiki-cli-test` are tasty suites. Database tests start a
throwaway PostgreSQL with `ephemeral-pg` (`shiki-core/test/Shiki/Persistence/TestPg.hs`,
`withSchemaPool`). `shiki-cli/test/Spec.hs` runs with `localOption (NumThreads 1)` because
`LaunchSpec` redirects the process's stdout. Tests that depend on today's failure shapes and
must change: `shiki-cli/test/Shiki/Cli/EnvRoutingSpec.hs` (catches the `ErrorCall` from a
missing connection string), `shiki-core/test/Shiki/Persistence/MigrationSpec.hs`
(`expectFailureContaining` matches `show SomeException` text from `fail`),
`shiki-cli/test/Shiki/Cli/ConfigInitSpec.hs` (expects an `ExitFailure` exception from a
refused overwrite), and `shiki-cli/test/Shiki/Cli/HeartbeatSpec.hs` (tests the IO
`withHeartbeat`).

**Terms used in this plan.**

- **effectful**: the Haskell effect library at version 2.7.x, split into `effectful-core`
  (the `Eff` monad, `Error`, `Reader`, `State`, dispatch machinery, `Effectful.Exception`) and
  `effectful` (which re-exports core and adds `Effectful.Concurrent`, `Effectful.Process`,
  and similar). Its source is registered in Mori as `effectful/effectful`; find it on disk
  with `mori registry show effectful/effectful --full`.
- **`Eff es a`**: a computation returning `a` that may use the effects in the type-level list
  `es`. `E :> es` means "effect `E` is in `es`".
- **`IOE`**: the effect that permits arbitrary IO (`liftIO`). `runEff :: Eff '[IOE] a -> IO a`
  is the only way out to `IO`.
- **Dynamic effect**: an effect declared as a GADT of operations with
  `type instance DispatchOf E = Dynamic`. Code calls operations through `send`; an interpreter
  written with `interpret` decides what each operation does.
- **`Error e`** (`Effectful.Error.Static`): `throwError :: e -> Eff es a` and
  `runErrorNoCallStack :: Eff (Error e : es) a -> Eff es (Either e a)`.
- **Synchronous vs asynchronous exception**: a synchronous exception is raised by the code
  that is running (a failed `openFile`); an asynchronous one is delivered from outside
  (Ctrl-C arrives as `UserInterrupt`, `killThread` as `ThreadKilled`). `trySync` catches only
  the former.
- **Banner**: GHC's default output for an uncaught exception,
  `shiki: Uncaught exception <type>:` followed by the message and often a backtrace.


## Plan of Work

The work is six milestones. Milestone 1 is a prototype: it proves the dependency builds
everywhere and pins down, in tests, the library behaviour the rest of the plan relies on.
Milestone 2 installs the top-level handler and the error types while most handlers still run
plain IO (lifted into `Eff`), so the banner disappears early. Milestones 3 to 5 move the IO
behind effects one domain at a time, deleting the scattered `error` and `exitFailure` calls
as they go. Milestone 6 records the conventions. Every milestone leaves the build
warning-free and both test suites green, and is one commit.

### Milestone 1 — Prototype: dependencies and effectful contract tests

Scope: add the dependency, prove it builds with cabal and with Nix, and write tests that
state the seven facts about effectful and GHC exceptions that the design depends on. No
production code uses effectful yet. At the end, `cabal test shiki-core-test` shows a
`Shiki.EffectfulContract` group, and `nix build` still produces `result/bin/shiki`.

**Cabal.** In the `library` and test-suite `build-depends` of `shiki-core/shiki-core.cabal`,
and in the `library` of `shiki-cli/shiki-cli.cabal`, add:

```text
baikai-effectful  ^>=0.4.0.2,
effectful         ^>=2.7.1.0,
effectful-core    ^>=2.7.1.1,
```

(`effectful-core` is listed explicitly because 2.7.1.1 is the first release without the
dispatch regression; `effectful` 2.7.1.0 only requires `>= 2.7.1.0`. `baikai-effectful`
0.4.0.2 is the first release that accepts effectful-core 2.7. Only shiki-core needs
`baikai-effectful` in its library stanza; shiki-cli needs it for `agent assist`.)

**Nix.** shiki's package set currently provides effectful 2.6.1.0, `strict-mutable-base`
1.1.0.0, no `file-io`, and baikai-effectful 0.4.0.1 (see Surprises). Measure it with this
expression, saved outside the repository (for example `$TMPDIR/hs.nix`), which rebuilds the
same composition as `flake.module.nix`:

```nix
let
  f = builtins.getFlake (toString /Users/shinzui/Keikaku/bokuno/shiki);
  nixpkgs = f.inputs.haskell-nix.inputs.nixpkgs or f.inputs.nixpkgs;
  pkgs = import nixpkgs { system = "aarch64-darwin"; };
  hp = pkgs.haskell.packages.ghc9124.override {
    overrides = pkgs.lib.composeExtensions
      (f.inputs.haskell-nix.lib.haskellExtension pkgs.haskell.lib.compose pkgs)
      (import /Users/shinzui/Keikaku/bokuno/shiki/nix/haskell-overlay.nix { inherit pkgs; gitRev = "dirty"; });
  };
  v = n: if hp ? ${n} && hp.${n} != null then hp.${n}.version else "absent";
in builtins.concatStringsSep " " (map (n: "${n}=${v n}")
  [ "effectful" "effectful-core" "baikai" "baikai-effectful" "strict-mutable-base" "file-io" ])
```

```bash
$ nix eval --impure --raw -f "$TMPDIR/hs.nix"
```

baikai-effectful comes from the `haskell-nix` input, so first run
`nix flake update haskell-nix` and re-evaluate: if that input has already moved to
baikai-effectful 0.4.0.2 (and perhaps effectful 2.7), fewer pins are needed. For whatever is
still too old or absent, add entries next to `kubernetes-api`, using `callHackageDirect` so
Nix uses the same releases as cabal:

```nix
effectful-core = dontCheck (final.callHackageDirect
  { pkg = "effectful-core"; ver = "2.7.1.2"; sha256 = pkgs.lib.fakeSha256; } { });
effectful = dontCheck (final.callHackageDirect
  { pkg = "effectful"; ver = "2.7.1.0"; sha256 = pkgs.lib.fakeSha256; } { });
baikai-effectful = dontCheck (final.callHackageDirect
  { pkg = "baikai-effectful"; ver = "0.4.0.2"; sha256 = pkgs.lib.fakeSha256; } { });
```

Run `nix build`; it fails once per package with `got: sha256-…`; paste each real hash in
place of `pkgs.lib.fakeSha256` and rebuild. Pin `strict-mutable-base` (a 2.x release) and
`file-io` (>= 0.1.4) the same way, looking up their current versions on Hackage rather than
guessing. Record the final set of pins, and whether the flake update was kept, in Surprises.

**Contract tests.** Create `shiki-core/test/Shiki/EffectfulContractSpec.hs` exporting
`tests :: TestTree` (group name `Shiki.EffectfulContract`), register it in
`shiki-core/test/Spec.hs` and in the test suite's `other-modules`. Each case states one fact
the handler relies on:

1. `trySync` does not catch a typed error: in
   `runEff (runErrorNoCallStack @Text (trySync (throwError @Text "x")))` the result is
   `Left "x"` (the error reached `runErrorNoCallStack`), not `Right (Left _)`.
2. `trySync` catches `ExitCode`: `runEff (trySync (liftIO (exitWith (ExitFailure 3) :: IO ())))`
   returns a `Left e` with `fromException e == Just (ExitFailure 3)`.
3. `trySync` does not catch `UserInterrupt`: running
   `runEff (trySync (liftIO (throwIO UserInterrupt)))` under `Control.Exception.try` gives
   `Left UserInterrupt` at the outer `try`.
4. `bracket` cleanup runs when the body calls `throwError`: an `IORef` set in the release
   action is `True` after `runEff (runErrorNoCallStack @Text (bracket (pure ()) (\_ -> liftIO (writeIORef ref True)) (\_ -> throwError @Text "x")))`.
5. A dynamic effect interpreted outside `withAsync` works inside the child: define a tiny
   test-local effect `Counter` with one operation `Tick :: Counter m ()`, interpret it with an
   `IORef`, call `tick` from `Effectful.Concurrent.Async.withAsync` in a loop, and check the
   count increased. This is the heartbeat's shape.
6. A `throwError` in a `withAsync` child reaches the parent when the parent calls `wait`
   (surfacing as `Left` from `runErrorNoCallStack`).
7. `displayException` on a `SomeException` built from `error "boom"` does not contain
   `HasCallStack`, and equals `"boom"`.

Promote or fall back: if all seven hold and `nix build` passes, record "promoted" in the
Decision Log and continue. If a fact fails (for example 5 or 6 behave differently in 2.7),
record the evidence in Surprises, adjust the corresponding design in Milestones 2–4 (the
heartbeat can fall back to `withEffToIO (ConcUnlift Persistent Unlimited)` around a plain
`forkIO`), and update this plan before continuing. If Nix cannot build 2.7 at all, stop and
ask the user whether to use 2.6.1.0 instead, since that reverses a user decision.

Acceptance: `cabal build all` prints no warnings; `cabal test all` passes including the
seven new cases; `nix build` succeeds and `./result/bin/shiki --version` runs.

### Milestone 2 — Error types and the top-level handler

Scope: introduce the error types, the renderer, and the handler; run the dispatcher in
`Eff`; and convert the failures that happen before any command logic (connection string,
schema, environment, `shiki.dhall`, migrations, kubeconfig) into typed errors. Handlers still
run their IO bodies through `liftIO`. At the end, acceptance rows 1–6 hold: those failures
print one `shiki:` line with exit 1, and any other escaped exception prints
`shiki: unexpected error: …` instead of the banner.

**File `shiki-core/src/Shiki/Error.hs` (new, exposed).**

```haskell
module Shiki.Error
  ( ShikiError (..),
    ConfigError (..),
    StoreError (..),
    KubeError (..),
    renderShikiError,
  )
where

-- | Every failure shiki-core reports. Rendered once, by the CLI's top level.
data ShikiError
  = ShikiConfigError !ConfigError
  | ShikiStoreError !StoreError
  | ShikiKubeError !KubeError
  | ShikiAnalyzerError !AnalyzerError
  deriving stock (Eq, Show)

data ConfigError
  = NoConnectionString
  | InvalidSchemaName !Text
  | UndeclaredEnvironment !Text !FilePath ![Text]   -- name, shiki.dhall path, declared names
  | ProjectConfigInvalid !FilePath !Text           -- path, Dhall's message
  | ServiceConfigNotFound !FilePath
  | ServiceConfigInvalid !FilePath !Text
  deriving stock (Eq, Show)

data StoreError
  = DatabaseUnavailable !Text                      -- the connection error, rendered
  | MigrationFailed !Text !Text                    -- schema, rendered MigrationFailure
  | StatementFailed !Text !Text                    -- operation name, rendered UsageError
  deriving stock (Eq, Show)

data KubeError
  = KubeConfigUnavailable !Text
  | KubeCredentialFailed !Text
  | DeploymentInspectionFailed !Text !Text          -- deployment, rendered InspectionError
  | KubeRequestFailed !Text !Text                   -- operation name, rendered error
  deriving stock (Eq, Show)

renderShikiError :: ShikiError -> Text
```

`AnalyzerError` is `Shiki.Analysis.Backend.AnalyzerError` (add `Eq` if missing). Rendered
messages, all starting `shiki: ` (the renderer adds the prefix; constructor payloads never
include it):

```text
NoConnectionString            shiki: no Postgres connection string; pass --db, add a shiki.dhall, or set SHIKI_DATABASE_URL / PG_CONNECTION_STRING
InvalidSchemaName e           shiki: invalid schema name: <e>
UndeclaredEnvironment n p ds  shiki: environment <n> is not declared in <p> (declared: <ds joined by ", ">)
ProjectConfigInvalid p m      shiki: cannot load <p>: <m>
ServiceConfigNotFound p       shiki: no service config at <p>
ServiceConfigInvalid p m      shiki: cannot load <p>: <m>
DatabaseUnavailable m         shiki: cannot connect to the database: <m>
MigrationFailed s m           shiki: migration failed for schema <s>: <m>
StatementFailed op m          shiki: database error during <op>: <m>
KubeConfigUnavailable m       shiki: cannot load the Kubernetes config: <m>
KubeCredentialFailed m        shiki: Kubernetes credential plugin failed: <m>
DeploymentInspectionFailed d m  shiki: cannot inspect deployment <d>: <m>
KubeRequestFailed op m        shiki: Kubernetes request failed during <op>: <m>
analyzer errors               the existing renderAnalyzerError wording from Shiki.Cli.Runs
```

For `DatabaseUnavailable`, render libpq's message text, not the Haskell `show` of the
constructor: `BootstrapConnectionFailed (NetworkingConnectionError msg)` becomes the `msg`
string. Look at `hasql`'s `Hasql.Errors.ConnectionError` constructors and extract the text
field of each.

**File `shiki-core/src/Shiki/Persistence/Migration.hs`.** Export `MigrationFailure` (rename
`MigrationBootstrapError`) and `renderMigrationFailure`, and change the signature to
`runMigrations :: ConnectionString -> Schema -> IO (Either MigrationFailure ())`, replacing
each `migrationFailure schema e` with `pure (Left e)`. Delete `migrationFailure`. Keep the
`error` for an invalid embedded plan: it can only fail if the build embedded a broken plan,
which is a programming error caught by `MigrationSpec`. In
`shiki-core/test/Shiki/Persistence/MigrationSpec.hs`, change `expectFailureContaining` to
take an `IO (Either MigrationFailure ())` and match on `renderMigrationFailure` text, and add
a helper `migrateOrFail` for the call sites that expect success.

**File `shiki-cli/src/Shiki/Cli/Error.hs` (new).**

```haskell
data CliError
  = CliCoreError !ShikiError
  | CliRunLookup !RunLookupFailure
  | CliServiceLookup !ServiceLookupFailure
  | UnknownHelpTopic !Text
  | ConfigFileExists !FilePath
  | AgentProviderInvalid !Text
  | AgentBinaryMissing !Text
  | AgentRequestFailed !Text
  | CommandFailed               -- the handler already printed why; exit 1 silently
  deriving stock (Eq, Show)

renderCliError :: CliError -> Maybe Text
```

`CliCoreError` is not thrown by handlers (they throw `ShikiError` directly); it exists so
`renderCliError` covers both. `CliRunLookup` and `CliServiceLookup` delegate to the
existing `renderRunLookupFailure` and `renderServiceLookupFailure`. The other messages keep
today's wording, taken from the handler that prints them (see Milestone 5).

**File `shiki-cli/src/Shiki/Cli/Main.hs` (new).**

```haskell
-- | The effects every command may use. Commands add their own effects on top
--   and discharge them before returning to this stack.
type CliEff = '[Error CliError, Error ShikiError, Concurrent, IOE]

-- | Run a command and turn every outcome into an exit code, printing failures
--   on the given handle (stderr in production).
runShikiMain :: Handle -> Eff CliEff () -> IO ExitCode
runShikiMain h action = do
  result <-
    runEff
      . Exc.trySync
      . runConcurrent
      . runErrorNoCallStack @ShikiError
      . runErrorNoCallStack @CliError
      $ action
  case result of
    Right (Right (Right ())) -> pure ExitSuccess
    Right (Right (Left cliErr)) -> failWith (renderCliError cliErr)
    Right (Left coreErr) -> failWith (Just (renderShikiError coreErr))
    Left ex
      | Just code <- fromException @ExitCode ex -> pure code
      | otherwise -> failWith (Just ("shiki: unexpected error: " <> Text.pack (displayException ex)))
  where
    failWith msg = do
      mapM_ (TIO.hPutStrLn h) msg
      pure (ExitFailure 1)
```

`Exc` is `Effectful.Exception` imported qualified. Its
`trySync :: Eff es a -> Eff es (Either SomeException a)` works only in `Eff`, which is why it
sits just inside `runEff`, outside every other handler. It catches only synchronous exceptions:
effectful's typed errors are already turned into `Left` by the two `runErrorNoCallStack`
calls inside, and an asynchronous exception such as Ctrl-C's `UserInterrupt` is not caught
at all. It reaches GHC's own handler, which exits with the interrupt status (130 in a shell)
and prints nothing. `shiki-cli/app/Main.hs` becomes
`main = runCli >>= exitWith`, and `runCli :: IO ExitCode` parses options and calls
`runShikiMain stderr (dispatch opts)`.

**File `shiki-cli/src/Shiki/Cli.hs`.** Rename the `case` to
`dispatch :: Options -> Eff CliEff ()`. Unconverted handlers are called with `liftIO` for
now. `withDbEnv` becomes:

```haskell
withDbEnv ::
  Maybe Text -> Maybe Text -> Maybe Text ->
  (Schema -> CliEnv -> IO a) ->
  Eff CliEff a
withDbEnv mConn mSchema mEnv k = do
  cs <- resolveConnectionString mConn mEnv
  schema <- resolveSchema mSchema
  withCliEnv cs schema (k schema)
```

**Files `shiki-cli/src/Shiki/Cli/Config.hs`, `Schema.hs`, `Project.hs`.** Change
`resolveConnectionString`, `resolveSchema`, and `resolveActiveEnvironment` to
`(IOE :> es, Error ShikiError :> es) => … -> Eff es …`, replacing each `error` with the
matching `throwError (ShikiConfigError …)`. Wrap `loadProjectConfig` with
`Exc.catchSync` and throw `ProjectConfigInvalid path (Text.pack (displayException e))`.
`runConfigShow` calls `resolveActiveEnvironment`, so it moves to `Eff` here too (its own
missing-environment message stays).

**File `shiki-cli/src/Shiki/Cli/Env.hs`.** `withCliEnv` becomes
`(IOE :> es, Error ShikiError :> es) => ConnectionString -> Schema -> (CliEnv -> IO a) -> Eff es a`.
Use `Effectful.Exception.bracket` for the pool; call `runMigrations` and turn `Left` into
`DatabaseUnavailable` (for `BootstrapConnectionFailed`) or `MigrationFailed`; call
`loadDefaultClientConfig` under `Exc.catchSync`, throwing `KubeCredentialFailed` for an
`ExecCredentialError` and `KubeConfigUnavailable` for anything else. The IO continuation is
simply called with `liftIO (k env)` inside the bracket; no unlifting is needed, because only
the continuation is IO. `runRuns` moves to `Eff` with the continuation type
`(CliEnv -> IO ()) -> Eff CliEff ()`; its handlers are still called with `liftIO`, and
`failLookup` keeps calling `exitFailure` until Milestone 3 (the handler passes `ExitCode`
through, so behaviour is unchanged).

**Tests.** New `shiki-cli/test/Shiki/Cli/MainSpec.hs`, using a temporary file handle for
`h`:

- `runShikiMain h (pure ())` is `ExitSuccess` and writes nothing.
- `throwError (ShikiConfigError NoConnectionString)` gives `ExitFailure 1` and the handle
  contains exactly the rendered line.
- `throwError CommandFailed` gives `ExitFailure 1` and writes nothing.
- `liftIO (exitWith (ExitFailure 7))` gives `ExitFailure 7`.
- `liftIO (evaluate (error "boom" :: ()))` gives `ExitFailure 1` and the output is
  `shiki: unexpected error: boom` with no `HasCallStack`.
- `liftIO (throwIO UserInterrupt)` escapes `runShikiMain` (assert with `try`).

A `renderShikiError` table test lists every constructor and its expected line. In
`EnvRoutingSpec`, run `resolveConnectionString` with `runEff . runErrorNoCallStack` and assert
`Left (ShikiConfigError NoConnectionString)`.

Acceptance: build warning-free, tests green, rows 1–6 of the acceptance matrix.

### Milestone 3 — The `RunStore` effect

Scope: put every read and write of the `runs` table behind one effect with a PostgreSQL
interpreter, remove the four private `error`-raising helpers, and give SQL failures a typed
message. At the end, rows 7–9 hold and `grep -rn "Pool.use" shiki-cli/src` returns nothing.

**File `shiki-core/src/Shiki/Effect/RunStore.hs` (new, exposed).**

```haskell
data RunStore :: Effect where
  InsertRun :: NewRun -> RunStore m ()
  MarkRunRunning :: RunId -> RunStore m ()
  CompleteRun :: RunCompletion -> RunStore m ()
  CompleteUnfinishedRun :: RunCompletion -> RunStore m Bool
  UpdateErrorSummary :: RunId -> Maybe Text -> Text -> RunStore m ()
  TouchRunWatched :: RunId -> RunStore m ()
  DatabaseNow :: RunStore m UTCTime
  ListRecentRuns :: Maybe Text -> Int -> RunStore m [RunRecord]   -- optional service filter
  FindRunsByPrefix :: Text -> RunStore m [RunRecord]
  ListUnfinishedRuns :: RunStore m [RunRecord]
  GetRun :: RunId -> RunStore m (Maybe RunRecord)

type instance DispatchOf RunStore = Dynamic

insertRun :: (RunStore :> es) => NewRun -> Eff es ()
insertRun = send . InsertRun
-- …one hand-written smart constructor per operation, same pattern
```

Check `getRunStatement`'s result type and the parameter tuple of
`updateErrorSummaryStatement` in `shiki-core/src/Shiki/Persistence/Run.hs` and match them.

**File `shiki-core/src/Shiki/Effect/RunStore/Postgres.hs` (new, exposed).**

```haskell
-- | Interpret 'RunStore' against a pool. A failed statement becomes
--   'StatementFailed' naming the operation.
runRunStorePostgres ::
  (IOE :> es, Error ShikiError :> es) => Pool.Pool -> Eff (RunStore : es) a -> Eff es a
runRunStorePostgres pool = interpret_ $ \case
  InsertRun r -> stmt "insert run" insertRunStatement r
  …
  where
    stmt op s input =
      liftIO (Pool.use pool (Session.statement input s)) >>= \case
        Left e -> throwError (ShikiStoreError (StatementFailed op (renderUsageError e)))
        Right b -> pure b

-- | Acquire a pool for the schema, apply migrations, run the action with
--   'RunStore' interpreted, and release the pool.
withRunStore ::
  (IOE :> es, Error ShikiError :> es) =>
  ConnectionString -> Schema -> Eff (RunStore : es) a -> Eff es a
```

`withRunStore` uses `Effectful.Exception.bracket (liftIO (acquirePool cs schema)) (liftIO . releasePool)`,
runs `runMigrations` mapped as in Milestone 2, then `runRunStorePostgres pool action`.
`renderUsageError` renders hasql-pool's `UsageError` (connection, session, and acquisition
timeout cases) as readable text; if an acquisition or connection error occurs mid-command,
map it to `DatabaseUnavailable` instead of `StatementFailed`. Pool acquisition is lazy
(hasql-pool connects on first use), so the migration step is where an unreachable database
is first noticed.

**Conversions in shiki-cli.** Handlers take `RunStore :> es` (plus `IOE` for printing, and
`Error CliError` where they fail):

- `Shiki.Cli.Runs`: `doList`, `doShow`, `doLogs`, `doError`, and the store part of
  `doAnalyze` (the `UpdateErrorSummary` write; the analyzer call stays IO until Milestone 5).
  `failLookup` becomes `throwError (CliRunLookup failure)`. `runRuns` keeps deciding the
  target before acquiring the store: `withRun` calls `runTarget` first and only then
  `withRunStore cs schema (lookupRun … >>= handler)`. Pass the resolved connection string and
  schema instead of the old continuation, and resolve them (Milestone 2's functions) only
  after `runTarget` succeeds, so row 10 of plan 10's acceptance still holds.
- `Shiki.Cli.Fzf.Selector.Run.lookupRun` becomes
  `(RunStore :> es, IOE :> es) => UTCTime -> RunTarget -> Eff es (Either RunLookupFailure RunRecord)`.
  Delete its private `query` and the `RunLookupPersistenceError` constructor (a SQL failure is
  now `StatementFailed`); update `RunSpec` and `renderRunLookupFailure`.
- `Shiki.Cli.Agent.Context.gatherAgentContext` reads recent runs through `ListRecentRuns`.
  It currently catches failures to stay best-effort; keep that with `Exc.trySync` plus a
  nested `runErrorNoCallStack @ShikiError` around the read.
- `Shiki.Cli.Runs.Sync` and `Shiki.Cli.Run`: replace `runStmt` and `runSessionUnit` with
  `RunStore` operations. Their cluster calls stay IO through `CliEnv` until Milestone 4.
  In the sync loop, the per-run failure handling must still catch a typed `StatementFailed`
  for that run: wrap each run in `runErrorNoCallStack @ShikiError` and report `Left` the same
  way the `trySync` branch reports an exception.

`CliEnv` loses `pool` in this milestone; `withCliEnv` is renamed `withKubeClient` and only
loads the client (still used by `run` and `sync`).

**Tests.** New `shiki-core/test/Shiki/Effect/RunStoreSpec.hs` using `withSchemaPool`: insert,
mark running, find by prefix, complete, list unfinished, all through `runRunStorePostgres`;
and one failure case that drops the `runs` table in the test schema and asserts
`Left (ShikiStoreError (StatementFailed "list recent runs" _))`. New
`shiki-cli/test/Shiki/Cli/Effect/FakeRunStore.hs` (test helper, listed in `other-modules`):
an interpreter over an `IORef [RunRecord]` with a switch that makes every operation throw
`StatementFailed`, used by a `RunsSpec` case asserting that `runs show 3f` against a failing
store renders `shiki: database error during find runs by prefix: …` through `runShikiMain`.

Acceptance: build warning-free, tests green, rows 7–9.

### Milestone 4 — The `Kube` effect, `shiki run`, and Ctrl-C

Scope: put cluster access behind an effect whose interpreter loads the client, convert the
two commands that use the cluster, move the heartbeat onto effectful concurrency, and fix the
Ctrl-C behaviour. At the end, `Shiki.Cli.Env` no longer exists, rows 10–14 hold, and
`KUBECONFIG=/nonexistent shiki runs list` works.

**File `shiki-core/src/Shiki/Effect/Kube.hs` (new, exposed).**

```haskell
data Kube :: Effect where
  InspectDeployment :: Namespace -> DeploymentName -> Text -> Kube m DeploymentSnapshot
  DeploymentExists :: Namespace -> DeploymentName -> Kube m Bool
  SubmitJob :: ServiceConfig -> DeploymentSnapshot -> JobInputs -> Kube m ()
  AwaitJob :: ServiceConfig -> DeploymentSnapshot -> JobInputs -> Kube m JobOutcome
  ObserveJob :: Namespace -> Text -> Kube m JobObservation
  CollectOutcome :: Namespace -> Text -> UTCTime -> UTCTime -> JobPhase -> Kube m JobOutcome

type instance DispatchOf Kube = Dynamic
```

`AwaitJob` wraps `Shiki.K8s.Runner.runJob` with today's arguments (poll every 5 seconds,
give up after 345600 seconds); keep those two numbers as named constants in the interpreter.

**File `shiki-core/src/Shiki/Effect/Kube/Client.hs` (new, exposed).**

```haskell
-- | Load the default client config (KUBECONFIG, then ~/.kube/config) and
--   interpret 'Kube' with it. Loading happens here, so commands without 'Kube'
--   in their stack never read the kubeconfig.
runKubeDefault :: (IOE :> es, Error ShikiError :> es) => Eff (Kube : es) a -> Eff es a

runKubeWith :: (IOE :> es, Error ShikiError :> es) => ClientEnv -> Eff (Kube : es) a -> Eff es a
```

Each operation runs its `Shiki.K8s.*` IO function under `Exc.catchSync`: an
`InspectionError` becomes `DeploymentInspectionFailed`, an `ExecCredentialError` becomes
`KubeCredentialFailed`, anything else becomes `KubeRequestFailed op`. Export `RunnerError`
from `Shiki.K8s.Runner` so the interpreter can name it.

**File `shiki-cli/src/Shiki/Cli/Run.hs`.** `runRun` becomes
`(RunStore :> es, Kube :> es, Concurrent :> es, IOE :> es, Error ShikiError :> es, Error CliError :> es) => RunOptions -> Eff es ()`.
Load the service config through `Exc.catchSync` for now (Milestone 5 moves it to
`ConfigLoader`), throwing `ServiceConfigNotFound` when the file is absent and
`ServiceConfigInvalid` otherwise. The submit and wait branches:

```haskell
waitPath rid startedAt cfg snap inputs = do
  result <-
    Exc.withException
      ( Exc.trySync
          ( runErrorNoCallStack @ShikiError
              (withHeartbeat heartbeatInterval (touchRunWatched rid) (awaitJob cfg snap inputs))
          )
      )
      (interruptedHint inputs rid)
  case result of
    Left ex -> finalizeFailed rid startedAt (Text.pack (displayException ex))
    Right (Left err) -> finalizeFailed rid startedAt (renderShikiError err)
    Right (Right outcome) -> finalizeOutcome rid startedAt outcome

-- | Runs only while an 'AsyncException' propagates; 'withException' re-throws it.
interruptedHint :: (IOE :> es) => JobInputs -> RunId -> AsyncException -> Eff es ()
interruptedHint inputs rid = \case
  UserInterrupt ->
    liftIO . TIO.hPutStrLn stderr $
      "shiki: interrupted; job " <> inputs ^. #jobName
        <> " keeps running; record its outcome later with 'shiki runs sync "
        <> showRunId rid <> "'"
  _ -> pure ()
```

`AsyncException` and `UserInterrupt` come from `Control.Exception`. Because the handler's
argument type is `AsyncException`, `withException` ignores every other exception, including
effectful's error wrapper. `finalizeFailed` records the row as today, prints
`FAILED run <id>: <message>` on stdout as today, and ends with `throwError CommandFailed`
instead of `exitFailure`; `finalizeOutcome` does the same for a non-succeeded outcome. Apply
the same shape to `noWaitPath` (no heartbeat).

**File `shiki-cli/src/Shiki/Cli/Heartbeat.hs`.**

```haskell
withHeartbeat ::
  (Concurrent :> es, IOE :> es) => Int -> Eff es () -> Eff es a -> Eff es a
withHeartbeat interval beat body = do
  reported <- liftIO (newIORef False)
  safeBeat reported
  withAsync (forever (threadDelay interval >> safeBeat reported)) (const body)
```

using `Effectful.Concurrent.Async.withAsync` and `Effectful.Concurrent.threadDelay`
(`withAsync` cancels the loop when the body returns or throws). Add the constraint
`Error ShikiError :> es`. `safeBeat` runs the beat under both `Exc.trySync` and
`catchError @ShikiError` (from `Effectful.Error.Static`), so an exception and a typed
`StatementFailed` are each reported once with today's message
(`shiki: could not record run heartbeat: …; the run continues`) and then ignored.
Contract test 5 from Milestone 1 is what makes the forked loop's use of `RunStore` safe.
Update `HeartbeatSpec` to run through `runEff . runConcurrent . runErrorNoCallStack @ShikiError`
and keep its existing cases (beats run, failure reported once, body result returned).

**File `shiki-cli/src/Shiki/Cli/Runs/Sync.hs`.** `syncRuns` and `syncRun` take
`(RunStore :> es, Kube :> es, IOE :> es, Error CliError :> es)`. Replace the per-run
`try @SomeException` with `Exc.trySync` plus `runErrorNoCallStack @ShikiError`, and replace
`throwIO (userError …)` in `confirmSameCluster` with a small local error value rendered the
same way. The final `exitFailure` becomes `throwError CommandFailed`.

**File `shiki-cli/src/Shiki/Cli.hs`.** The `Run` branch becomes
`withRunStore cs schema . runKubeDefault $ runRun runOpts`, and `RunsSync` in `runRuns` adds
`runKubeDefault`. No other command gets `Kube`. Delete `shiki-cli/src/Shiki/Cli/Env.hs` and
its cabal entry.

Acceptance: build warning-free, tests green, rows 10–14.

### Milestone 5 — Config and analyzer effects, and the remaining exits

Scope: move Dhall loading and analysis behind effects, convert the remaining handlers, and
remove the remaining `exitFailure` calls. At the end, rows 15–21 hold and the audit grep
passes.

**File `shiki-core/src/Shiki/Effect/ConfigLoader.hs` (new, exposed)** with operations
`LoadServiceConfig :: FilePath -> ConfigLoader m ServiceConfig` and
`LoadProjectConfig :: FilePath -> ConfigLoader m ProjectConfig`, and an interpreter
`runConfigLoaderIO :: (IOE :> es, Error ShikiError :> es) => Eff (ConfigLoader : es) a -> Eff es a`
that checks `doesFileExist` first (`ServiceConfigNotFound` / `ProjectConfigInvalid path "file not found"`)
and maps any synchronous exception from Dhall to `ServiceConfigInvalid path (displayException e)`
or `ProjectConfigInvalid`. Use it from `runRun`, `serviceShowOne`, `effectiveBackend`,
`resolveActiveEnvironment`, and `runConfigShow`. `effectiveBackend` keeps its fallback: a
missing file still means `Heuristic`, but an invalid file is now reported instead of crashing.

**File `shiki-core/src/Shiki/Effect/Analyzer.hs` (new, exposed)** with one operation
`Analyze :: AnalyzerKind -> Text -> Analyzer m AnalyzerResult` and an interpreter written in
terms of baikai-effectful's `Baikai` effect:

```haskell
-- | 'Heuristic' and 'None' are handled here; a 'Baikai' model goes through the
--   'Baikai' effect. Every failure becomes 'ShikiAnalyzerError'.
runAnalyzerBaikai ::
  (Baikai :> es, Error ShikiError :> es) => Eff (Analyzer : es) a -> Eff es a
```

`Heuristic` calls the pure `Shiki.Analysis.Heuristic.summarizeFailure`; `None` throws
`AnalyzerBackendDisabled`; `Baikai modelId` looks the id up in shiki's allow-list (throwing
`AnalyzerUnknown` when it is absent, without calling the effect), builds the same context and
options as today, calls `Baikai.Effectful.complete` under `Exc.trySync`, and turns either a
thrown exception or a set `responseError` into `AnalyzerBaikaiError message`.

Refactor `shiki-core/src/Shiki/Analysis/Baikai.hs` so its pure parts are exported and reused
by the interpreter: `supportedModels`, `lookupModel` (now returning just the `Model`, with
provider registration separated out), the request context and options, `extractText`,
`capChars`, and `renderError`. Add `registerAnalyzerProviders :: IO ()`, which registers the
Claude and OpenAI API providers idempotently, as `lookupModel`'s `IO ()` action does per call
today. Delete the IO `runBaikai` and, if nothing else calls it,
`Shiki.Analysis.Backend.runAnalyzer`; check `Shiki.K8s.Runner.collectOutcome`, which
summarizes a failed Job's log on the inline path, and
`shiki-core/test/Shiki/Analysis/BackendSpec.hs` first, and keep whichever entry point they
still need.

In `Shiki.Cli`'s dispatch, the `RunsAnalyze` branch becomes
`liftIO registerAnalyzerProviders >> (runBaikai . runAnalyzerBaikai $ …)`, where `runBaikai`
is baikai-effectful's interpreter over the process-global registry. No other `runs` command
gains `Baikai`. The renderer's analyzer messages are the ones `renderAnalyzerError` prints
today (move that function into `Shiki.Error`).

**File `shiki-cli/src/Shiki/Cli/Agent/Launch.hs`.** In `runOneShotApi`, replace
`try @SomeException (completeRequest model ctx emptyOptions)` with
`Exc.trySync (complete model ctx emptyOptions)` from `Baikai.Effectful`, in a function with
`(Baikai :> es, IOE :> es, Error CliError :> es)`; a thrown exception or a set
`responseError` becomes `AgentRequestFailed message`, keeping today's
`shiki: agent api call failed: …` wording. Provider registration stays a `liftIO` call before
`complete`, and the `Agent` branch of the dispatch adds `runBaikai`. The interactive
`claude` and `codex` launchers are subprocesses, not `Baikai` calls, and keep the
`Exc.catchSync` wrapper described above.

**Analyzer tests.** New `shiki-core/test/Shiki/Effect/AnalyzerSpec.hs` interprets `Baikai`
without the network, either with a local `interpret`er returning a canned `Response` or with
`runBaikaiWith` over an isolated registry holding a stub provider, following
`baikai-effectful/test/StubProvider.hs` in the baikai repository (`mori registry show
shinzui/baikai --full` prints its path). Cases: a canned assistant text becomes the capped
summary; an error-shaped `Response` becomes
`Left (ShikiAnalyzerError (AnalyzerBaikaiError …))`; an unknown model id fails without
invoking `Baikai`; and `Heuristic` produces its summary without invoking `Baikai`.

**Remaining handlers.** Each `hPutStrLn stderr … >> exitFailure` pair becomes a `throwError`
of the matching `CliError` constructor, and the message moves into `renderCliError` with the
same wording:

- `Shiki.Cli.Help`: unknown topic becomes `UnknownHelpTopic`. The current output is several
  lines (the error plus the topic list); `renderCliError` may return multi-line text.
- `Shiki.Cli.ConfigInit`: the refused overwrite becomes `ConfigFileExists path`; wrap
  `openTempFile`/`renameFile` in `Exc.catchSync` and throw a new
  `ShikiConfigError (ConfigWriteFailed path message)` (add the constructor and its line
  `shiki: cannot write <path>: <message>`). Update `ConfigInitSpec` to assert
  `Left (ConfigFileExists path)`.
- `Shiki.Cli.Agent` and `Shiki.Cli.Agent.Launch`: a provider parse failure becomes
  `AgentProviderInvalid message`; a missing `claude` or `codex` becomes
  `AgentBinaryMissing name`; the prompt render error and API failures become
  `AgentRequestFailed message`. Wrap the interactive launch in `Exc.catchSync` and throw
  `AgentRequestFailed` with the exception's `displayException`. The child's own exit
  status keeps flowing through `liftIO (exitWith code)`, which `runShikiMain` passes through.
- `Shiki.Cli.serviceShowHandler`: `failService` becomes `throwError (CliServiceLookup failure)`.
- `Shiki.Cli.Runs.doAnalyze`: the analyzer error branch is now the effect's typed error.

**Audit.** Run from the repository root:

```bash
grep -rnE "exitFailure|exitWith|\berror \(|\berror \"|errorWithoutStackTrace|try @SomeException|\bfail \(" shiki-core/src shiki-cli/src
```

The allowed hits, each with a one-line comment at the site saying why:
`shiki-cli/app/Main.hs` (`exitWith` of the handler's code); the agent child exit
passthrough in `Shiki.Cli.Agent`; the invalid-embedded-plan `error` in
`Shiki.Persistence.Migration`; `fail` inside aeson `Parser` code in
`Shiki.K8s.ExecCredential` (pure parsing, becomes a Yaml decode error); and `try @SomeException`
in `Shiki.K8s.Runner` and `Shiki.Analysis.Baikai` only if they re-throw asynchronous
exceptions (otherwise switch them to `trySync`). Record the final list in Outcomes.

Acceptance: build warning-free, tests green, rows 15–21, audit list recorded.

### Milestone 6 — Documentation, ADRs, and retrospective

**File `docs/adr/5-use-effectful-with-a-single-top-level-error-handler.md` (new).** Status,
Date, Context (the banner problem, the scattered exits, the unsettled in-house conventions),
Decision (effectful 2.7 with dynamic, hand-written effects in `Shiki.Effect.*`, IO
interpreters in `Shiki.Effect.*.<Backend>` modules; `IOE` only in interpreters and in
shiki-cli handlers for terminal and process work; `Effectful.Error.Static` with `ShikiError`
and `CliError`; a library that publishes its own effectful binding (baikai-effectful) is used
through it, underneath shiki's high-level effect, the way an interpreter uses any library; one `runShikiMain` that renders on stderr and exits 1, re-throws `ExitCode`,
and never catches asynchronous exceptions; `trySync`/`catchSync` instead of
`try @SomeException`; interpreters that load resources are the only place resources are
loaded, so a command's effect list shows what it touches), and Consequences (how to add an
effect, how to add a failure, the contract tests guard library upgrades). Follow the format
of the existing ADRs.

**File `docs/adr/2-resolve-omitted-positionals-with-typed-early-resolvers.md`.** Add a
consequence bullet: resolution failures are now `CliError` values rendered by the shiki-wide
handler of ADR 5; the stderr, exit 1, and silent-cancel rules are unchanged.

**File `docs/user/commands.md`.** Add a section `## Errors and exit codes` after the global
options: every failure prints one `shiki: …` line on stderr and exits 1; a command's result
goes to stdout only; unexpected failures print `shiki: unexpected error: …` and should be
reported; `agent assist` exits with its child's status; Ctrl-C exits with the interrupt
status and, during `shiki run`, leaves the Job running (use `shiki runs sync`). List the
messages from Milestone 2. Update the file's `generated` stamp and add a line to
`docs/user/log.md`, then run `just user-documentation-validate`.

**File `CHANGELOG.md`.** Under `## [Unreleased]`: `### Changed` (failures print one line
instead of an exception dump; `runs list/show/logs/error/analyze` and `agent assist` no longer
read the kubeconfig; Ctrl-C during `shiki run` no longer records the run as failed) and
`### Fixed` (the thirteen banner paths, summarized).

Then run the full validation, fill in Outcomes & Retrospective, and record provenance.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/shiki` inside `nix develop`. Every
commit carries these trailers:

```text
ExecPlan: docs/plans/19-adopt-effectful-as-the-io-stack-with-a-shiki-wide-error-handler.md
Intention: intention_01m2kha3snextbxnejnkaq46c0
```

### Bootstrap

```bash
$ nix develop
$ cabal build all 2>&1 | grep -i warning     # expect no output
$ cabal test all                             # baseline: shiki-cli-test "All 108 tests passed"
$ just up                                    # local PostgreSQL for the manual rows
```

If `just up` fails because `db/db` was initialized by an older PostgreSQL, use a throwaway
cluster instead and pass it with `--db`:

```bash
$ initdb -D "$TMPDIR/shiki-pg" --auth=trust --no-locale --encoding=UTF8
$ pg_ctl -D "$TMPDIR/shiki-pg" -l "$TMPDIR/shiki-pg.log" start -o "-c listen_addresses=127.0.0.1 -p 54329"
$ createdb -h 127.0.0.1 -p 54329 shiki
$ export DB=postgresql://127.0.0.1:54329/shiki
```

### M1

```bash
$ nix flake update haskell-nix && nix eval --impure --raw -f "$TMPDIR/hs.nix"
$ $EDITOR shiki-core/shiki-core.cabal shiki-cli/shiki-cli.cabal nix/haskell-overlay.nix
$ $EDITOR shiki-core/test/Shiki/EffectfulContractSpec.hs shiki-core/test/Spec.hs
$ cabal build all 2>&1 | grep -i warning
$ cabal test shiki-core-test 2>&1 | grep -A8 EffectfulContract
$ nix build && ./result/bin/shiki --version
```

Expected excerpt:

```text
  Shiki.EffectfulContract
    trySync lets a typed error through:               OK
    trySync catches ExitCode:                         OK
    trySync does not catch UserInterrupt:             OK
    bracket cleanup runs under throwError:            OK
    a dynamic effect works inside withAsync:          OK
    throwError in a withAsync child reaches wait:     OK
    displayException has no backtrace:                OK
```

Commit `build(deps): EP-19 M1 — add effectful 2.7 and pin its contract in tests`.

### M2

```bash
$ $EDITOR shiki-core/src/Shiki/Error.hs shiki-core/src/Shiki/Persistence/Migration.hs
$ $EDITOR shiki-cli/src/Shiki/Cli/Error.hs shiki-cli/src/Shiki/Cli/Main.hs shiki-cli/app/Main.hs
$ $EDITOR shiki-cli/src/Shiki/Cli.hs shiki-cli/src/Shiki/Cli/{Config,Schema,Project,Env,ConfigShow,Runs}.hs
$ $EDITOR shiki-cli/test/Shiki/Cli/MainSpec.hs shiki-cli/test/Shiki/Cli/EnvRoutingSpec.hs
$ cabal build all 2>&1 | grep -i warning
$ cabal test all
$ bin="$(cabal list-bin shiki)"
$ env -u PG_CONNECTION_STRING -u SHIKI_DATABASE_URL "$bin" runs list; echo "exit=$?"
shiki: no Postgres connection string; pass --db, add a shiki.dhall, or set SHIKI_DATABASE_URL / PG_CONNECTION_STRING
exit=1
$ "$bin" --db postgresql://127.0.0.1:1/none runs show 3f; echo "exit=$?"
shiki: cannot connect to the database: connection to server at "127.0.0.1", port 1 failed: Connection refused
exit=1
```

(Run the first command from a directory without a `shiki.dhall`, for example `cd "$TMPDIR"`.)

Commit `feat(shiki-cli): EP-19 M2 — typed errors and one top-level error handler`.

### M3

```bash
$ $EDITOR shiki-core/src/Shiki/Effect/RunStore.hs shiki-core/src/Shiki/Effect/RunStore/Postgres.hs
$ $EDITOR shiki-cli/src/Shiki/Cli/Runs.hs shiki-cli/src/Shiki/Cli/Runs/Sync.hs shiki-cli/src/Shiki/Cli/Run.hs
$ $EDITOR shiki-cli/src/Shiki/Cli/Fzf/Selector/Run.hs shiki-cli/src/Shiki/Cli/Agent/Context.hs
$ $EDITOR shiki-core/test/Shiki/Effect/RunStoreSpec.hs shiki-cli/test/Shiki/Cli/Effect/FakeRunStore.hs
$ cabal build all 2>&1 | grep -i warning
$ cabal test all
$ grep -rn "Pool.use" shiki-cli/src          # expect no output
$ "$bin" --db "$DB" runs list -l 3; echo "exit=$?"
```

Commit `refactor: EP-19 M3 — put run storage behind the RunStore effect`.

### M4

```bash
$ $EDITOR shiki-core/src/Shiki/Effect/Kube.hs shiki-core/src/Shiki/Effect/Kube/Client.hs shiki-core/src/Shiki/K8s/Runner.hs
$ $EDITOR shiki-cli/src/Shiki/Cli/Run.hs shiki-cli/src/Shiki/Cli/Heartbeat.hs shiki-cli/src/Shiki/Cli/Runs/Sync.hs shiki-cli/src/Shiki/Cli.hs
$ git rm shiki-cli/src/Shiki/Cli/Env.hs && $EDITOR shiki-cli/shiki-cli.cabal shiki-cli/test/Shiki/Cli/HeartbeatSpec.hs
$ cabal build all 2>&1 | grep -i warning
$ cabal test all
$ KUBECONFIG=/nonexistent "$bin" --db "$DB" runs list -l 3; echo "exit=$?"     # table, exit=0
$ KUBECONFIG=/nonexistent "$bin" --db "$DB" run ingest -- echo hi; echo "exit=$?"
shiki: cannot load the Kubernetes config: …
exit=1
```

(The second command needs a `services/ingest.dhall`; use any existing service name, such as
`mls-service-v2` in this checkout.)

Commit `refactor: EP-19 M4 — cluster access behind the Kube effect; keep jobs on Ctrl-C`.

### M5

```bash
$ $EDITOR shiki-core/src/Shiki/Effect/ConfigLoader.hs shiki-core/src/Shiki/Effect/Analyzer.hs shiki-core/src/Shiki/Analysis/Baikai.hs
$ $EDITOR shiki-core/test/Shiki/Effect/AnalyzerSpec.hs shiki-core/test/Spec.hs shiki-core/shiki-core.cabal
$ $EDITOR shiki-cli/src/Shiki/Cli.hs shiki-cli/src/Shiki/Cli/{Help,ConfigInit,ConfigShow,Agent,Runs}.hs shiki-cli/src/Shiki/Cli/Agent/Launch.hs
$ cabal build all 2>&1 | grep -i warning
$ cabal test all
$ grep -rnE "exitFailure|exitWith|\berror \(|\berror \"|errorWithoutStackTrace|try @SomeException|\bfail \(" shiki-core/src shiki-cli/src
$ "$bin" help nope; echo "exit=$?"
$ "$bin" run no-such-service -- echo hi; echo "exit=$?"
shiki: no service config at services/no-such-service.dhall
exit=1
```

Commit `refactor: EP-19 M5 — config and analyzer effects; no handler exits on its own`.

### M6

```bash
$ $EDITOR docs/adr/5-use-effectful-with-a-single-top-level-error-handler.md docs/adr/2-resolve-omitted-positionals-with-typed-early-resolvers.md
$ $EDITOR docs/user/commands.md docs/user/log.md CHANGELOG.md
$ nix fmt && git status --short
$ just user-documentation-validate
$ cabal test all && nix build
```

Commit `docs: EP-19 M6 — record the effectful and error-handling conventions`.


## Validation and Acceptance

### Behavioural acceptance matrix (after M6)

Rows marked with a milestone first hold at the end of that milestone. "One line" means the
command prints exactly one line on stderr, nothing on stdout, and no `Uncaught exception` or
`HasCallStack` text anywhere.

| # | Inputs | Observed | Exit | From |
|---|--------|----------|------|------|
| 1 | Any DB command with no `--db`, no `shiki.dhall`, no `SHIKI_DATABASE_URL` or `PG_CONNECTION_STRING` | One line: `shiki: no Postgres connection string; …` | 1 | M2 |
| 2 | `shiki --db "$DB" --db-schema 'bad name' runs list` (schema names must match `[A-Za-z_][A-Za-z0-9_]*`) | One line: `shiki: invalid schema name: …` | 1 | M2 |
| 3 | `shiki --env typo runs list` in a project with `shiki.dhall` | One line: `shiki: environment typo is not declared in <path> (declared: …)` | 1 | M2 |
| 4 | `shiki runs list` with a syntax error in `shiki.dhall` | One message: `shiki: cannot load <path>: ` followed by Dhall's own diagnostic; no banner, no backtrace | 1 | M2 |
| 5 | `shiki --db postgresql://127.0.0.1:1/none runs show 3f` | One line: `shiki: cannot connect to the database: …` | 1 | M2 |
| 6 | `shiki help runs`, `shiki --version`, a successful `shiki runs list` | Unchanged output | 0 | M2 |
| 7 | `shiki runs list` / `show <id>` / `logs <id>` / `error <id>` on a working database | Unchanged output | 0 | M3 |
| 8 | A SQL failure (the `RunsSpec` fake store, or drop the `runs` table in a scratch schema and run `runs list`) | One line: `shiki: database error during <operation>: …` | 1 | M3 |
| 9 | `env PATH=/usr/bin shiki --db postgresql://127.0.0.1:1/none runs show </dev/null` | `shiki: no run id given and fzf is not available` (target still decided before connecting) | 1 | M3 |
| 10 | `KUBECONFIG=/nonexistent shiki runs list` | The table; no kubeconfig error | 0 | M4 |
| 11 | `KUBECONFIG=/nonexistent shiki run <svc> -- echo hi` | One line: `shiki: cannot load the Kubernetes config: …` | 1 | M4 |
| 12 | `shiki run <svc>` whose Deployment does not exist in the namespace | One line: `shiki: cannot inspect deployment <name>: …` | 1 | M4 |
| 13 | `shiki run <svc> -- sleep 600`, then Ctrl-C | stderr: `shiki: interrupted; job <name> keeps running; …`; the row stays `running` and shows `unwatched` after 5 minutes; `shiki runs sync <id>` later records the outcome | 130 | M4 |
| 14 | `shiki runs sync` with a failing run among several | Per-run `run <id>: sync failed: …` lines, others still sync | 1 | M4 |
| 15 | `shiki run no-such-service -- echo hi` | One line: `shiki: no service config at services/no-such-service.dhall` | 1 | M5 |
| 16 | `shiki run <svc>` / `service show <svc>` / `runs analyze <id>` with a syntax error in `services/<svc>.dhall` | One message: `shiki: cannot load services/<svc>.dhall: ` followed by Dhall's own diagnostic; no banner, no backtrace | 1 | M5 |
| 17 | `shiki help nope` | The existing unknown-topic text on stderr | 1 | M5 |
| 18 | `shiki config init` when `shiki.dhall` exists | The existing refusal message on stderr | 1 | M5 |
| 19 | `shiki config init --output /nonexistent/dir/shiki.dhall` | One line: `shiki: cannot write /nonexistent/dir/shiki.dhall: …` | 1 | M5 |
| 20 | `shiki agent assist` where the launched agent exits 3 | Agent's own output | 3 | M5 |
| 22 | `shiki runs analyze <id> --analyzer baikai:not_a_model` | One line with today's unknown-model wording; no network call | 1 | M5 |
| 23 | `shiki runs analyze <id> --analyzer baikai:anthropic_claude_haiku_4_5` with no API key set | One line: `shiki: baikai backend failed: …`; the stored summary is unchanged | 1 | M5 |
| 21 | All rows of `docs/plans/10-integrate-fzf-for-interactive-id-selection.md`'s acceptance matrix | Unchanged | as documented | M5 |

### Test commands

```bash
cd /Users/shinzui/Keikaku/bokuno/shiki
cabal test shiki-core-test   # includes Shiki.EffectfulContract and Shiki.Effect.RunStore
cabal test shiki-cli-test    # includes Shiki.Cli.Main and the fake-store RunsSpec case
cabal test all
nix build                    # the release build uses the pinned effectful packages
```

The unit tests cover the library contract, the renderers, the top-level handler's six
outcome kinds, the PostgreSQL interpreter against a throwaway database, and SQL failure
rendering through a fake store. Rows 5, 9–13, and 16–20 need the built binary; row 13 needs a
reachable cluster and a person at the terminal (or a detached `tmux` session sending `C-c`).


## Idempotence and Recovery

No database migrations and no data changes. Builds, tests, `nix fmt`, and the grep audit can
be repeated freely; the store tests use throwaway databases and schemas.

Each milestone is one commit and leaves the tree green, so the plan can stop after any
milestone and ship. Revert newest first (`git revert <M6> … <M1>`). Milestones 3–5 depend on
Milestone 2's error types and handler, and Milestone 4 deletes `Shiki.Cli.Env`, so reverting
Milestone 2 alone after later milestones does not compile.

If the Nix pin in Milestone 1 cannot be made to build, revert that milestone's overlay change
and stop (see the fallback rule there). If a later milestone's conversion becomes too large
for one commit, split it by command (for example `runs` before `run`) and record the split in
Progress; the error types make partial conversions safe because unconverted handlers still
run through `liftIO` and the top-level fallback.


## Interfaces and Dependencies

### Libraries

| Library | Version | Why |
|---------|---------|-----|
| `effectful-core` | `^>=2.7.1.1` (Nix pins 2.7.1.2) | `Eff`, `Error`, dynamic dispatch, `Effectful.Exception` |
| `effectful` | `^>=2.7.1.0` | `Effectful.Concurrent` and `Effectful.Concurrent.Async` for the heartbeat |
| `hasql`, `hasql-pool` (existing) | as today | the `RunStore` PostgreSQL interpreter |
| `kubernetes-api`, `kubernetes-api-client` (existing) | as today | the `Kube` interpreter |
| `dhall` (existing) | as today | the `ConfigLoader` interpreter |
| `baikai` (existing) | `^>=0.7` | models, request and response vocabulary, provider registration |
| `baikai-effectful` | `^>=0.4.0.2` | its `Baikai` effect is how the `Analyzer` interpreter and `agent assist` reach baikai; first release accepting `effectful-core >=2.7 && <2.8` |

No other new dependencies. `effectful-th` and `effectful-plugin` are not used.

### Module signatures at the end of the plan

`Shiki.Error` (shiki-core):

```haskell
data ShikiError = ShikiConfigError !ConfigError | ShikiStoreError !StoreError
                | ShikiKubeError !KubeError | ShikiAnalyzerError !AnalyzerError
data ConfigError = NoConnectionString | InvalidSchemaName !Text
                 | UndeclaredEnvironment !Text !FilePath ![Text]
                 | ProjectConfigInvalid !FilePath !Text | ServiceConfigNotFound !FilePath
                 | ServiceConfigInvalid !FilePath !Text | ConfigWriteFailed !FilePath !Text
data StoreError = DatabaseUnavailable !Text | MigrationFailed !Text !Text | StatementFailed !Text !Text
data KubeError = KubeConfigUnavailable !Text | KubeCredentialFailed !Text
               | DeploymentInspectionFailed !Text !Text | KubeRequestFailed !Text !Text
renderShikiError :: ShikiError -> Text
```

`Shiki.Persistence.Migration`:

```haskell
data MigrationFailure = …   -- the former MigrationBootstrapError, now exported
renderMigrationFailure :: MigrationFailure -> Text
runMigrations :: ConnectionString -> Schema -> IO (Either MigrationFailure ())
```

`Shiki.Effect.RunStore`, `Shiki.Effect.Kube`, `Shiki.Effect.ConfigLoader`,
`Shiki.Effect.Analyzer`: the GADTs above with `DispatchOf … = Dynamic` and one smart
constructor per operation (`insertRun`, `markRunRunning`, `completeRun`,
`completeUnfinishedRun`, `updateErrorSummary`, `touchRunWatched`, `databaseNow`,
`listRecentRuns`, `findRunsByPrefix`, `listUnfinishedRuns`, `getRun`; `inspectDeployment`,
`deploymentExists`, `submitJob`, `awaitJob`, `observeJob`, `collectOutcome`;
`loadServiceConfig`, `loadProjectConfig`; `analyze`). Where a smart constructor's name
collides with the existing IO function in `Shiki.K8s.*` or `Shiki.Service.Config.Dhall`,
import the IO module qualified inside the interpreter.

Interpreters:

```haskell
runRunStorePostgres :: (IOE :> es, Error ShikiError :> es) => Pool.Pool -> Eff (RunStore : es) a -> Eff es a
withRunStore :: (IOE :> es, Error ShikiError :> es) => ConnectionString -> Schema -> Eff (RunStore : es) a -> Eff es a
runKubeDefault :: (IOE :> es, Error ShikiError :> es) => Eff (Kube : es) a -> Eff es a
runKubeWith :: (IOE :> es, Error ShikiError :> es) => ClientEnv -> Eff (Kube : es) a -> Eff es a
runConfigLoaderIO :: (IOE :> es, Error ShikiError :> es) => Eff (ConfigLoader : es) a -> Eff es a
runAnalyzerBaikai :: (Baikai :> es, Error ShikiError :> es) => Eff (Analyzer : es) a -> Eff es a
registerAnalyzerProviders :: IO ()
-- from baikai-effectful (Baikai.Effectful):
complete :: (Baikai :> es) => Model -> Context -> Options -> Eff es Response
runBaikai :: (IOE :> es) => Eff (Baikai : es) a -> Eff es a
runBaikaiWith :: (IOE :> es) => ProviderRegistry -> Eff (Baikai : es) a -> Eff es a
```

`Shiki.Cli.Error` and `Shiki.Cli.Main` (shiki-cli):

```haskell
data CliError = CliCoreError !ShikiError | CliRunLookup !RunLookupFailure
              | CliServiceLookup !ServiceLookupFailure | UnknownHelpTopic !Text
              | ConfigFileExists !FilePath | AgentProviderInvalid !Text
              | AgentBinaryMissing !Text | AgentRequestFailed !Text | CommandFailed
renderCliError :: CliError -> Maybe Text

type CliEff = '[Error CliError, Error ShikiError, Concurrent, IOE]
runShikiMain :: Handle -> Eff CliEff () -> IO ExitCode
runCli :: IO ExitCode
```

`Shiki.Cli.Heartbeat.withHeartbeat :: (Concurrent :> es, IOE :> es, …) => Int -> Eff es () -> Eff es a -> Eff es a`.
`Shiki.Cli.Env` no longer exists. `Shiki.Cli.Fzf.Selector.Run.RunLookupFailure` no longer has
`RunLookupPersistenceError`.

### Reference material

- The effectful source and haddocks: `mori registry show effectful/effectful --full` gives the
  path; read `effectful-core/src/Effectful.hs` (the "integrating with IO libraries" section),
  `Effectful/Dispatch/Dynamic.hs` (defining and interpreting an effect),
  `Effectful/Error/Static.hs`, `Effectful/Exception.hs` (the `catchSync` guidance), and
  `effectful/CHANGELOG.md`.
- `mori://effectful/effectful/docs/error-guide` and `mori://effectful/effectful/docs/lift-unlift`
  are local notes, not written by the library maintainers, and partly describe deprecated
  2.6 APIs; prefer the haddocks where they disagree.
- In-house prior art, useful as examples but not as settled conventions:
  `mori://shinzui/notion-cli/plans/42-notion-client-effectful-wrapper` (hand-written dynamic
  effect over an IO client), `mori://shinzui/rei/plans/162-enforce-cli-failure-exit-contracts`
  (why a catch-all must re-throw `ExitCode`), and
  `mori://shinzui/shikumi/plans/1-shikumi-runtime-substrate-and-llm-effect-over-baikai`
  (an effect over baikai's IO API).


## Revision Notes

- 2026-09-15 — Adopted `baikai-effectful` 0.4.0.2, superseding the same-day decision to keep
  the `Analyzer` interpreter on baikai's IO API (commit `0e26de7`). Both layers stay: shiki's
  high-level `Analyzer` effect still holds the model allow-list, prompt, and caps, while its
  interpreter and `agent assist`'s API one-shot now call `Baikai.Effectful.complete`, which
  deletes shiki's two `try @SomeException (completeRequest …)` sites and lets analyzer tests
  run against a stub provider registry. Also corrected the Nix findings: the first check
  omitted the `haskell-nix` input's `haskellExtension`, and the real package set additionally
  lacks `strict-mutable-base` 2.x and `file-io` and pins baikai-effectful 0.4.0.1, so
  Milestone 1 now starts with `nix flake update haskell-nix` and includes the evaluation
  expression. Updated Progress, Surprises, the Decision Log, Milestones 1 and 5, the
  dependency table, Interfaces, ADR 5's scope, and added acceptance rows 22 and 23.
