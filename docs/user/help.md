# Help command

`shiki help` is the in-terminal index and reader for curated topic guides
that ship inside the `shiki` binary. It is the fastest way to look up
"what is a service config?", "what does an analyzer do?", or "which
environment variables does shiki read?" without leaving the terminal.

The topic content is baked into the binary at compile time, so help
works offline and there are no companion files to ship alongside
`shiki`.

## Usage

```text
shiki help                  # print the topic index
shiki help <TOPIC>          # print one topic verbatim
```

Topic lookup is case-insensitive and tolerant of leading/trailing
whitespace — `shiki help SERVICES` and `shiki help "  services  "` both
match the `services` topic. An unknown topic name exits with code `1`
after printing `Unknown topic: <name>` and an `Available: …` list on
stderr.

`shiki help` with no argument exits `0`. There is no pager; for paging,
pipe through `less`:

```bash
shiki help services | less
```

## Topics

The shipped catalog mirrors the operator-guide pages under `docs/user/`
one-to-one. Each in-terminal topic is a condensed restatement of one
user-guide page; `docs/user/<page>.md` remains the canonical reference,
and every topic ends with a `Full reference:` line pointing back to it.

| Topic       | Description                              | Full reference                          |
|-------------|------------------------------------------|-----------------------------------------|
| `services`  | Service configuration: `services/*.dhall`| [service-config.md](./service-config.md)|
| `runs`      | Run lifecycle and the `runs` table       | [getting-started.md](./getting-started.md), [commands.md](./commands.md) |
| `analyzers` | Failure analysis backends                | [error-analysis.md](./error-analysis.md)|
| `agent`     | `shiki agent assist`                     | [agent-assist.md](./agent-assist.md)    |
| `schema`    | Postgres schema configuration            | [schema.md](./schema.md)                |
| `env`       | Environment variables                    | [commands.md](./commands.md)            |

## Example

```text
$ shiki help
HELP TOPICS

  services   Service configuration: services/*.dhall
  runs       Run lifecycle and the runs table
  analyzers  Failure analysis backends
  agent      shiki agent assist
  schema     Postgres schema configuration
  env        Environment variables

Use 'shiki help <topic>' for details.
```

```text
$ shiki help services
SHIKI SERVICES


A "service" in shiki is a Kubernetes workload that shiki can submit one-off
Jobs against. Each service is described by one Dhall configuration file
under the services/ directory at the operator's working directory:

…
```
