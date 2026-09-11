---
okf_version: "0.2"
---

# Explanation

- [Error analysis](error-analysis.md) - Explain the difference between a run's Kubernetes error and its log-derived error summary, and how to choose between the Heuristic, Baikai, and None analyzers.

# Navigation

- [shiki user guide](README.md) - Route operators to the shiki getting-started tutorial, command reference, configuration pages, and analysis guides.

# Reference

- [Agent assist](agent-assist.md) - Reference the shiki agent assist providers, preloaded session context, per-provider safety policy, flags, and exit behavior.
- [Commands reference](commands.md) - Reference every shiki subcommand, its flags, the global database and environment options, the fzf pickers, and the environment variables shiki reads.
- [Help command](help.md) - Reference the in-terminal shiki help reader: usage, width fitting, piped output, topic lookup rules, and the shipped topic catalog.
- [Project Configuration](project-config.md) - Reference the project-local shiki.dhall file format, named environments, environment selection order, and database connection precedence.
- [Database schema](schema.md) - Reference shiki's PostgreSQL runs table, its indexes, migration bookkeeping, restricted-role grants, schema-name overrides, and the migration out of public.
- [Service configuration](service-config.md) - Reference every field of a services/<name>.dhall service configuration and how shiki turns it into a one-off Kubernetes Job.

# Tutorial

- [Getting started](getting-started.md) - Take a fresh checkout to a first recorded shiki run: prerequisites, the dev shell, local Postgres, cluster authentication, a service config, and run inspection.

