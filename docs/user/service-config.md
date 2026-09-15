---
type: Reference
title: "Service configuration"
description: "Reference every field of a services/<name>.dhall service configuration and how shiki turns it into a one-off Kubernetes Job."
docId: DOC-9
tags: [shiki, configuration, dhall, kubernetes]
generated:
  by: human:nadeem
  at: 2026-06-04T22:36:40Z
---

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
| `name`                 | `Text`                              | The canonical short name, recorded as the run's `service_name` and used in the Job name. Keep it equal to the filename (`services/my-svc.dhall` ⇒ `name = "my-svc"`); shiki does not enforce this, but `runs analyze` finds a run's service file by this name. |
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
| `ttlSecondsAfterFinished` | `Optional Natural` (may be omitted) | Seconds a finished Job, its pod, and its logs stay in the cluster. Omitted or `None Natural` means 7 days. `shiki runs sync` needs the Job to exist to record the real outcome. |

`ttlSecondsAfterFinished` is the one field a service file may leave out:
the loader fills in `None Natural`, so files written before the field
existed keep loading.

Dynamic values (image digest, ConfigMap name, Secret name) are
deliberately **not** in the Dhall config — shiki reads them from the
live Deployment so you do not have to keep them in sync by hand.

## `EnvVar` and `EnvSource`

```dhall
let EnvSource =
      < ConfigMap : { key : Text }
      | Secret    : { key : Text }
      | Literal   : { value : Text }
      | DeploymentEnv : { name : Text }
      >

let EnvVar = { name : Text, source : EnvSource }
```

Four shapes:

- `ConfigMap { key = "PROJECT_ID" }` — read from the ConfigMap shiki
  detected on the live Deployment, by key.
- `Secret { key = "DATABASE_PASSWORD" }` — same, against the detected
  Secret.
- `Literal { value = "true" }` — a baked-in string. Supports the
  Kubernetes `$(VAR)` interpolation syntax for referencing other env
  vars already on the container.
- `DeploymentEnv { name = "KAFKA_BROKERS" }` — copy the named env var's
  literal, ConfigMap source, or Secret source from the live Deployment.
  This is useful when a service has a second ConfigMap/Secret that should
  stay dynamic rather than being modelled as the primary app ConfigMap.

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
, image       : ContainerImageSource
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

`ContainerImageSource` is:

```dhall
< StaticImage : { value : Text } | DeploymentInitImage : { name : Text } >
```

Use `StaticImage` for a fixed image such as `cloud-sql-proxy`. Use
`DeploymentInitImage` to copy an init container image from the live
Deployment, for example a sidecar whose image tag is controlled by the
service deployment pipeline.

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

- `cloud-sql-proxy` init container with `restartable = True`, whose
  `args` use `$(VAR)` interpolation to reference its own env vars,
- a `kafka-auth-server` init container whose image is copied from the
  live Deployment with `DeploymentInitImage`,
- ConfigMap + Secret-sourced env vars, and `DeploymentEnv` vars copied
  from the live Deployment,
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
