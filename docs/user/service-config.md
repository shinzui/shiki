# Service configuration

shiki reads one **Dhall file per service** from `services/<name>.dhall`
(or whatever you pass with `--config-dir`). The file is a declarative
description of the service and the Kubernetes Job shape shiki should
produce when running a one-off command against it.

The full type lives in `Shiki.Service.Config` — this page is the
operator-facing reference for the fields you actually write.

## Top-level fields

| Field                  | Type                                | Meaning                                                                                                                                                                  |
|------------------------|-------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `name`                 | `Text`                              | The canonical short name. Must match the filename: `services/my-svc.dhall` ⇒ `name = "my-svc"`.                                                                          |
| `defaultNamespace`     | `Text`                              | Namespace to introspect and submit Jobs into. Overridable per-run with `--namespace`.                                                                                    |
| `detectFromDeployment` | `Text`                              | Name of the live Deployment shiki should mirror. shiki reads its pod spec at run time to pick up the current image digest, ConfigMap names, Secret names, etc.            |
| `containerName`        | `Text`                              | Which container inside that Deployment to mirror. Needed when there is more than one (e.g. a `cloud-sql-proxy` sidecar alongside the application container).             |
| `commandPath`          | `Text`                              | Path to the binary inside the container image; becomes the Job container's `command[0]`.                                                                                  |
| `serviceAccount`       | `Text`                              | Kubernetes ServiceAccount to attach to the Job pod.                                                                                                                       |
| `nodeSelector`         | `Map Text Text`                     | Optional pod `nodeSelector`. `toMap { foo = "bar" }` builds an entry; the empty map disables.                                                                            |
| `initContainers`       | `[InitContainer]`                   | Init containers to attach to every run.                                                                                                                                   |
| `env`                  | `[EnvVar]`                          | Environment variables for the main container.                                                                                                                            |
| `resources`            | `Resources`                         | CPU / memory requests and limits for the main container.                                                                                                                  |
| `analyzer`             | `AnalyzerBackend`                   | Default analyzer for this service's runs. See [Error analysis](./error-analysis.md).                                                                                      |

Dynamic values (image digest, ConfigMap name, Secret name) are
deliberately **not** in the Dhall config — shiki reads them from the
live Deployment so you do not have to keep them in sync by hand.

## `EnvVar` and `EnvSource`

```dhall
let EnvSource =
      < ConfigMap : { key : Text }
      | Secret    : { key : Text }
      | Literal   : { value : Text }
      >

let EnvVar = { name : Text, source : EnvSource }
```

Three shapes:

- `ConfigMap { key = "PROJECT_ID" }` — read from the ConfigMap shiki
  detected on the live Deployment, by key.
- `Secret { key = "DATABASE_PASSWORD" }` — same, against the detected
  Secret.
- `Literal { value = "true" }` — a baked-in string. Supports the
  Kubernetes `$(VAR)` interpolation syntax for referencing other env
  vars already on the container.

The mls example uses helper builders to keep declarations terse:

```dhall
let mkConfigEnv =
      \(name : Text) -> { name = name, source = EnvSource.ConfigMap { key = name } }

let mkSecretEnv =
      \(name : Text) -> { name = name, source = EnvSource.Secret { key = name } }
```

## `InitContainer`

```dhall
{ name        : Text
, image       : Text
, args        : List Text
, env         : List EnvVar
, resources   : Resources
, restartable : Bool
}
```

The canonical example is `cloud-sql-proxy`: GKE-side database proxy that
needs to start before the application container and survive across
restarts of the main container. Set `restartable = True` for that
behavior; otherwise the init container runs once and exits.

## `Resources`

```dhall
{ cpuRequest    : Text   -- e.g. "500m"
, cpuLimit      : Text   -- e.g. "2"
, memoryRequest : Text   -- e.g. "512Mi"
, memoryLimit   : Text   -- e.g. "4096Mi"
}
```

shiki does not validate the strings — Kubernetes does. Pass anything
the apiserver accepts in `resources.requests` / `resources.limits`.

## `AnalyzerBackend`

```dhall
< Heuristic | Baikai : { model : Text } | None >
```

See [Error analysis → Declaring a default per service](./error-analysis.md#declaring-a-default-per-service).

## Worked example

The checked-in [`services/mls-service-v2.dhall`](../../services/mls-service-v2.dhall)
is the canonical worked example. It covers:

- `cloud-sql-proxy` init container with `restartable = True`,
- ConfigMap + Secret-sourced env vars,
- a literal env var built from `$(VAR)` interpolation,
- a `nodeSelector` requiring the GKE metadata server,
- the Heuristic analyzer set as the service default.

## Sanity-checking a config

```bash
shiki service show my-service
```

Parses `services/my-service.dhall` and prints the resulting
`ServiceConfig` as pretty JSON. Touches neither the database nor the
cluster, so it's safe to run on any change before submitting a real
`shiki run`.

Dhall parse errors and missing imports surface as exceptions from this
command — fix them here rather than discovering them in the middle of
`shiki run`.
