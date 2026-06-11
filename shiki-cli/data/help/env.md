SHIKI ENVIRONMENT VARIABLES


CLI flags always win over environment variables and project-local
defaults.


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

shiki uses the standard kube client search path:

  KUBECONFIG              Path(s) to kubeconfig file(s). When unset,
                          shiki reads ~/.kube/config.


Full reference: docs/user/commands.md (environment variable summary)
See also: 'shiki help schema', 'shiki help agent'.
