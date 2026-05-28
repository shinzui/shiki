SHIKI ENVIRONMENT VARIABLES


CLI flags always win over environment variables. When no flag is set,
shiki reads the listed variable; if it is unset or empty, the hard-coded
default applies.


DATABASE

  SHIKI_DATABASE_URL      Postgres connection string. Read by every
                          subcommand that touches the database (run,
                          runs, agent). Falls back to:

  PG_CONNECTION_STRING    Compatibility alias for SHIKI_DATABASE_URL.

  SHIKI_DB_SCHEMA         Postgres schema name. Default: 'shiki'.
                          Override per-invocation with --db-schema=NAME.


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
