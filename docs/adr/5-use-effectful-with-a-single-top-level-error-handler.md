# ADR 5: Describe IO with effectful, and report every failure from one handler

Status: Accepted

Date: 2026-09-15


## Context

Until September 2026 shiki's IO was ordinary `IO` and its failures were scattered. About
twenty handlers printed their own message and called `exitFailure`, four modules each carried
a private copy of "run this SQL statement or call `error`", and roughly a dozen paths
escaped to GHC's uncaught-exception banner. An unreachable database produced

```text
shiki: Uncaught exception ghc-internal:GHC.Internal.IO.Exception.IOException:

user error (shiki: migration failed for schema shiki: could not inspect migration history: NetworkingConnectionError "connection to server at \"127.0.0.1\", port 1 failed: Connection refused …")
```

with a doubled `shiki:` prefix and often a `HasCallStack backtrace:` block. Ctrl-C while
`shiki run` waited was caught as an ordinary exception and recorded the run as `failed` with
the message `user interrupt`, which was false — the Kubernetes Job kept running. And because
one function acquired the database pool *and* loaded the kubeconfig, `shiki runs list` failed
when the operator's kubeconfig was broken, although it never talks to a cluster.

[EP-19](../plans/19-adopt-effectful-as-the-io-stack-with-a-shiki-wide-error-handler.md)
addressed all of this at once, because each part makes the others cheap: typed errors need
somewhere to be caught, and the effect list is what makes "this command does not touch the
cluster" a fact the compiler enforces rather than a convention.

Best practice for `effectful` is not settled, and the author's own projects disagree with one
another, so the conventions below are anchored on the library's own documentation
(`Effectful.hs`, `Effectful/Dispatch/Dynamic.hs`, `Effectful/Error/Static.hs`,
`Effectful/Exception.hs`) rather than on any in-house precedent.


## Decision

**IO is described with `effectful` 2.7.** shiki-core defines the effects and their
interpreters; shiki-cli's handlers run in `Eff`. An effect is a GADT of high-level operations
named after what shiki does — `RunStore` (the `runs` table), `Kube` (the cluster),
`ConfigLoader` (the two Dhall files), `Analyzer` (failure summaries) — not a thin wrapper
over the library underneath. Effects live in `Shiki.Effect.<Name>`; their production
interpreters live in `Shiki.Effect.<Name>.<Backend>` (`RunStore.Postgres`, `Kube.Client`) or
beside the effect when there is only one. Dispatch is dynamic, the `send` smart constructors
are hand-written (no `effectful-th`), and `effectful-plugin` is not used: it only helps with
polymorphic effects such as `State Int`, which shiki does not have.

**Interpreters are the only place a resource is acquired**, so a command's effect list is an
honest inventory of what it touches. `runKubeDefault` is what reads the kubeconfig, so
`shiki runs list` — whose stack has no `Kube` — cannot fail because of one.

**`IOE` never appears in a shiki-core effect's interface**, only in its interpreters.
shiki-cli handlers may use `IOE` directly for the terminal and the local process: stdout and
stderr, terminal detection and size, environment variables, the clock, random job names and
run ids, the fzf subprocess, and launching `claude` or `codex`. None of these has a second
interpretation shiki needs, and effectful's bundled wrappers for them add nothing over
`liftIO`.

**Failures are values of two sum types.** `Shiki.Error.ShikiError` covers what shiki-core can
fail at (configuration, the store, the cluster, the analyzer); `Shiki.Cli.Error.CliError`
covers what a command can fail at (a run or service that could not be looked up, an unknown
help topic, a refused overwrite, an agent that could not be launched). They are separate
because shiki-core cannot mention CLI types. Both travel through
`Effectful.Error.Static`, never `Effectful.Error.Dynamic`.

**One function renders and exits.** `Shiki.Cli.Main.runShikiMain` discharges both error
types, prints one `shiki: …` line on stderr, and exits 1. A `CliError` may render as
`Nothing`, which prints nothing and still exits 1, for failures the handler has already
reported (a cancelled picker, a run that failed after its outcome was printed). An `ExitCode`
raised by a handler passes through unchanged, which is how `shiki agent assist` exits with
its child's status. Anything unclassified prints `shiki: unexpected error: <message>` — one
line, never a backtrace — because on GHC 9.12 `displayException` omits the exception context.
Asynchronous exceptions are not caught at all: Ctrl-C reaches GHC's handler and exits with
the shell's interrupt status.

**`trySync` and `catchSync`, never `try @SomeException`.** effectful's typed errors travel as
exceptions classified as *asynchronous*, so `try @SomeException` swallows an in-flight
`throwError` while `trySync` lets it pass. `ExitCode` is synchronous, so a catch-all must
re-throw it. The four remaining uses of `error`, `fail`, `exitWith`, and `try @SomeException`
in `shiki-core/src` and `shiki-cli/src` each carry a comment saying why.

**A typed error raised by an interpreter is caught with `catchError`, not with a nested
`runErrorNoCallStack`.** Each `runErrorNoCallStack` allocates a fresh handler id, and
effectful routes an interpreter's `throwError` to the handler that was in scope where the
*interpreter* was installed — which is further out than the caller. A nested handler
therefore never sees it. This is the single easiest mistake to make with this design; EP-19
made it three times, and two of the three were user-visible.

**A library that publishes its own effectful binding is used through it**, underneath shiki's
own effect. `Shiki.Effect.Analyzer` holds shiki's policy — the model allow-list, the system
prompt, the token and character caps — and its interpreter reaches the model through
`baikai-effectful`'s `Baikai` effect, exactly as `RunStore`'s interpreter reaches PostgreSQL
through hasql. Both layers earn their place: the high-level effect hides the backend from
commands, and the library's effect is how the interpreter gets there without IO.

**Every failure exits 1.** That contract, which
[ADR 2](./2-resolve-omitted-positionals-with-typed-early-resolvers.md) and
[the commands reference](../user/commands.md) already documented for the pickers, now holds
for every command. Exit classes can be added later without changing the error types.

**The library's behaviour is pinned by tests.** `shiki-core/test/Shiki/EffectfulContractSpec.hs`
asserts the seven facts the handler and the heartbeat depend on, so a library upgrade that
changes one fails the suite instead of quietly changing how shiki reports failures.


## Consequences

- **Adding an effect**: define the GADT in `Shiki.Effect.<Name>` with
  `type instance DispatchOf <Name> = Dynamic` and a `{-# LANGUAGE TypeFamilies #-}` pragma
  (GHC2024 does not enable it), write one hand-rolled `send` constructor per operation, and
  put the IO interpreter in a separate module that maps every failure to a `ShikiError`. Do
  not expose `IOE` in the effect's own signatures.
- **Adding a failure**: add a constructor to `ShikiError` or `CliError` and a line to its
  renderer. `shiki-cli/test/Shiki/Cli/MainSpec.hs` has a table of every `ShikiError`
  constructor and its expected line; a new constructor belongs there too. No handler prints
  or exits.
- **Library messages are for logs, not for operators.** hasql's `toDetailedText` repeats the
  whole SQL and its parameters, and `http-client`'s `Show` prints the entire `Request`
  record. `Shiki.Error` and the `Kube` interpreter render the one sentence that matters —
  PostgreSQL's message plus its SQLSTATE, the HTTP request line plus the reason — and
  `collapseWhitespace` folds a terminal-formatted message onto one line. A Dhall diagnostic
  is the exception: it keeps its caret, because that is the only thing that says where the
  typo is.
- **Commands that do not need the cluster no longer load a kubeconfig.** `runs
  list/show/logs/error/analyze` and `agent assist` work with `KUBECONFIG` pointed at nothing.
  Only `shiki run` and `runs sync` interpret `Kube`.
- **Ctrl-C during `shiki run` leaves the Job alone.** The row stays `running`, displays as
  `unwatched` after five minutes ([ADR 3](./3-model-run-watcher-liveness-as-a-display-only-heartbeat.md)),
  and `shiki runs sync` records the real outcome. shiki prints a one-line hint saying so.
- **Tests do not need the real backend.** An in-memory `RunStore`, a `Kube` that answers from
  fixtures, and a `Baikai` that returns a canned reply let the suite assert what an operator
  sees when a statement fails, when the cluster is unreachable, and when a model refuses —
  none of which a live dependency would reproduce on demand.
