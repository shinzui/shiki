SHIKI AGENT ASSIST


'shiki agent assist' opens an interactive AI session whose system prompt
embeds a live snapshot of shiki's state — the working directory, the
PostgreSQL schema, the cluster context, every services/*.dhall, and the
last twenty rows from the 'runs' table — and whose tool access is scoped
to a hard-coded allow-list.


PROVIDERS

Four providers ship out of the box. The two CLI providers spawn a local
subprocess and hand the terminal over to it. The two API providers issue
a single non-interactive call and print the assistant's text.

  claude-cli   (default)  Spawns the 'claude' CLI (Claude Code). Uses
                          whatever 'claude' is logged in as.
  codex-cli               Spawns the 'codex' CLI. Sandbox mode is set to
                          'workspace-write' with approval-on-request.
  anthropic               One-shot Anthropic Messages API call. Default
                          model: claude-sonnet-4-6.
  openai                  One-shot OpenAI Chat Completions API call.
                          Default model: gpt-4o-mini.

The CLI providers have no shiki-side model default — they pass through
whatever the local CLI uses when --model is omitted.


FLAGS

  --provider PROVIDER     One of: claude-cli, codex-cli, anthropic, openai.
  --model MODEL           Provider-specific model id (e.g.
                          claude-sonnet-4-6, gpt-4o-mini).
  --prompt PROMPT         First user-role message sent to the model.
  --service NAME          Pre-seed the prompt with one service hint.
  --run ID                Pre-seed the prompt with one run id hint.
  --debug                 Render and print the system prompt, then exit 0.


ENVIRONMENT VARIABLES

  SHIKI_AGENT_PROVIDER    Default provider when --provider is not set.
  SHIKI_AGENT_MODEL       Default model when --model is not set.
  ANTHROPIC_API_KEY       Required for --provider anthropic.
  OPENAI_API_KEY          Required for --provider openai.

CLI flag > env var > hard-coded default (claude-cli, no model).


ALLOWED TOOLS

The agent's subprocess access is scoped to:

  Bash(shiki *)          All shiki subcommands.
  Bash(kubectl get *)    Read-only kubectl introspection.
  Bash(kubectl logs *)   Pod log fetching.
  Bash(pwd)              Working-directory checks.
  Bash(ls *)             Directory listing.
  Bash(cat *)            File reads.
  Read, Glob, Grep       Claude Code's built-in read primitives.

There is no escape hatch; the allow-list is hard-coded.


DRIVING LONG RUNS

Agent sessions are the worst place to block on a Job: the host may stop a
background process at any time, and a stopped 'shiki run' leaves its row
'running' with nothing to finish it. For anything that may take more than
a few minutes, submit with --no-wait, check back every 15-30 minutes with
'shiki runs sync <id>', and confirm the kube context first. The full rules
are in 'shiki help long-runs'.


Full reference: docs/user/agent-assist.md
See also: 'shiki help long-runs', 'shiki help analyzers', 'shiki help env'.
