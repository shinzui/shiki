SHIKI ENVIRONMENT VARIABLES


CLI flags always win over environment variables and project-local
defaults.

PROJECT CONFIG

  shiki config init --schema-ref <tag-or-commit>

      Create a project-local shiki.dhall that imports the public schema
      package from:

        https://raw.githubusercontent.com/shinzui/shiki/<ref>/schema/package.dhall

      The command refuses to overwrite an existing shiki.dhall.

  shiki config show

      Print the discovered config path, declared environments, selected
      environment, and masked database URL without opening a database.


DATABASE

  Database-backed subcommands (run, runs, agent) resolve their
  connection string in this order:

    1. --db CONNSTR
    2. active shiki.dhall environment databaseUrl
    3. SHIKI_DATABASE_URL
    4. PG_CONNECTION_STRING

  SHIKI_DATABASE_URL      Legacy Postgres connection string fallback.

  PG_CONNECTION_STRING    Final fallback. The nix develop shell hook
                          exports this for the project-local database.

  SHIKI_DB_SCHEMA         Postgres schema name. Default: 'shiki'.
                          Override per-invocation with --db-schema=NAME.

  SHIKI_ENV               Active project environment when --env is not
                          supplied. If unset, shiki uses
                          defaultEnvironment from shiki.dhall.


AGENT ASSIST

  SHIKI_AGENT_PROVIDER    Default agent provider. One of:
                          claude-cli, codex-cli, anthropic, openai.

  SHIKI_AGENT_MODEL       Default model name. Provider-specific.

  ANTHROPIC_API_KEY       Required for 'shiki agent assist --provider
                          anthropic' and for 'shiki runs analyze
                          --analyzer=baikai:anthropic_*'.

  OPENAI_API_KEY          Required for 'shiki agent assist --provider
                          openai' and for 'shiki runs analyze
                          --analyzer=baikai:openai_*'.


KUBERNETES

shiki reads one kubeconfig file and uses its current-context:

  KUBECONFIG              Path to a single kubeconfig file. When unset,
                          shiki reads ~/.kube/config. Unlike kubectl,
                          shiki does not merge a colon-separated list.

There is no --context flag. Check 'kubectl config current-context' before
'shiki run'; to target another context without changing the global one,
point KUBECONFIG at a one-context copy (see 'shiki help long-runs').


Full reference: docs/user/commands.md (environment variable summary)
See also: 'shiki help schema', 'shiki help agent', 'shiki help long-runs'.
