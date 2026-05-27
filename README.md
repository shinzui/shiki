# shiki

> hiki conducts operational commands across Kubernetes services and records what ran, where it ran, and how long it took.

Shiki is a CLI for conducting operational commands across Kubernetes services with a durable execution history. It helps operators run service-specific commands against the right cluster and environment, while recording each run in PostgreSQL with metadata such as the service, command, status, timing, and duration. The goal is to make ad hoc operational work safer, easier to audit, and easier to understand after the fact.

## Layout

This project is split into two cabal packages:

- **`shiki-core`** — the library. Domain types, business logic, and
  the project-wide `Shiki.Prelude` that re-exports
  [`lens`](https://hackage.haskell.org/package/lens) and
  [`generic-lens`](https://hackage.haskell.org/package/generic-lens).
- **`shiki-cli`** — the command-line interface. Exposes
  `Shiki.Cli.runCli` and ships an executable named
  **`shiki`** that just calls it.

Both packages target **GHC `ghc9124`** with `default-language: GHC2024`
and the same warning set + default extensions
(`DeriveAnyClass`, `DuplicateRecordFields`, `OverloadedLabels`, `OverloadedStrings`).

## Develop

The project ships a Nix flake (`nix-haskell-flake`) that pins GHC and provides
the dev shell. Enter the shell with:

```bash
nix develop      # or: direnv allow, if you use direnv
```

Then build and run:

```bash
cabal build all
cabal run shiki -- hello --name world
```

## License

[BSD-3-Clause](./LICENSE) — (c) 2026 Nadeem Bitar.
