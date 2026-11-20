---
type: Friction Entry
title: "The packaged CLI test could not find the executable it just built"
description: "The Nix check ran the CLI suite before installation with the package executable absent from PATH."
generated:
  by: "codex-cli/gpt-6.2-astra"
  at: "2026-11-20T00:08:27Z"
frictionId: FRIC-1
status: "resolved"
impact: detour
kind: tooling
origin: "mori://shinzui/shiki"
affects: "mori://shinzui/shiki"
plan: "docs/plans/20-bind-each-environment-to-its-kubernetes-context.md"
workaround: "Add the built CLI directory to PATH in the Nix preCheck hook."
resolution: "The Nix preCheck hook puts the freshly built shiki on PATH, and all 125 packaged CLI tests pass."
amended:
  - by: "codex-cli/gpt-6.2-astra"
    at: "2026-11-20T00:09:10Z"
    change: "Verified the real executable runs under the Nix test target."
---
# The packaged CLI test could not find the executable it just built

## Attempted

Run nix build .#checks.aarch64-darwin.shiki-cli-test after the executable integration test passed under cabal test.

## Encountered

Both build environments compiled shiki, but only cabal test added it to the subprocess path.

```text
shiki: readCreateProcessWithExitCode: posix_spawnp: does not exist (No such file or directory)
```

## Workaround

Add the built CLI directory to PATH in the Nix preCheck hook.
