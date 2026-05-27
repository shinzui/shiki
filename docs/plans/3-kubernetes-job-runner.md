---
id: 3
slug: kubernetes-job-runner
title: "Kubernetes Job Runner"
kind: exec-plan
created_at: 2026-05-27T04:46:53Z
master_plan: "docs/masterplans/1-microservice-job-runner-with-postgres-backed-run-history.md"
---


# Kubernetes Job Runner

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

`shiki` exists to launch one-off Kubernetes Jobs that mirror the configuration of a
service's long-running worker Deployment. The existing shell script at
`/Users/shinzui/Keikaku/work/microtan/mls-service-v2-master/scripts/infrastructure/run-oneoff-task.sh`
does this by shelling out to `kubectl` to read the worker Deployment, then templating a
Job YAML and `kubectl apply`-ing it. This plan replaces that pattern with a typed Haskell
module, `Shiki.K8s.Runner`, that uses the `kubernetes-api` and `kubernetes-api-client`
libraries directly. After this plan, a reader can call `runJob` from a `ghci` session
against a live cluster, give it a `ServiceConfig` (built or loaded via the loader from
`docs/plans/1-service-configuration-model-and-dhall-loader.md`) plus a command-line array,
and watch the runner submit a Job, wait for it to finish, and return a `JobOutcome` value
that includes the final phase, exit code, start/end times, and a tail of pod logs.

The user-visible verification, since this plan does not change the CLI binary, is a small
example program shipped under `shiki-core/example/RunOnce.hs` that exercises
`Shiki.K8s.Runner.runJob` end-to-end. Running it against the operator's `kubectl
current-context` cluster submits a Job that prints "hello from shiki" and exits, and the
example program prints the resulting `JobOutcome`.

The `JobOutcome` value produced here is consumed by
`docs/plans/4-run-cli-command-end-to-end.md` to translate cluster-side results into the
`RunCompletion` update written to the `runs` Postgres table (defined by
`docs/plans/2-postgresql-schema-migrations-and-run-persistence.md`). Like the other
shared types in this MasterPlan, `JobOutcome` is the canonical contract; downstream
consumers must not extend it locally.


## Progress

- [ ] Add the `kubernetes-api-1.34` and `kubernetes-api-client` dependencies via
  `cabal.project` source-repository-package entries (they are not on Hackage as a single
  unit — the `codedownio/kubernetes-api` repo bundles many version-specific packages).
- [ ] Add `Shiki.K8s.Client` exporting `loadDefaultClientConfig :: IO ClientEnv` (wraps
  kubeconfig loading from `~/.kube/config` plus auth handlers).
- [ ] Add `Shiki.K8s.Introspection` exporting `inspectDeployment :: ClientEnv ->
  Namespace -> DeploymentName -> IO DeploymentSnapshot` (returns image, configmap name,
  secret name, service account, node selector for the named container of the named
  deployment).
- [ ] Add `Shiki.K8s.JobBuilder` exporting `buildJob :: ServiceConfig ->
  DeploymentSnapshot -> JobInputs -> V1Job` (pure function from inputs to API model).
- [ ] Add `Shiki.K8s.Runner` exporting `JobOutcome`, `JobInputs`, `runJob`, and a
  helper `submitJob` that returns immediately without waiting (for `--no-wait`).
- [ ] Add `shiki-core/example/RunOnce.hs` and wire it as a cabal `executable` so an
  operator can run it against a real cluster.
- [ ] Add a hermetic unit test for `buildJob` that asserts on the generated `V1Job`'s
  structure (no cluster required).
- [ ] Optionally add an integration test gated on a `--shiki-k8s` tasty flag that runs
  against the operator's current kube context.
- [ ] `cabal build all` clean; `cabal test shiki-core` clean (unit-level only by
  default).


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Use `codedownio/kubernetes-api` (specifically `kubernetes-api-1.34` plus the
  hand-written `kubernetes-api-client`) instead of shelling out to `kubectl`.
  Rationale: A typed Haskell CLI replacing shell scripts is the entire point of the
  MasterPlan; relying on `kubectl` would only relocate the shell-script fragility. The
  library supports kubeconfig loading, GCP/OIDC auth (which the example service uses via
  `iam.gke.io`), and full Job CRUD, which is exactly what is needed.
  Date: 2026-05-26

- Decision: Pin the API to Kubernetes 1.34 (the highest version in the registry at the
  time of writing). Allow downstream `cabal.project` overrides to pin a different minor
  version if the cluster mismatches significantly.
  Rationale: Job v1 has been stable since 1.21; the schema differences across recent minor
  versions affect features `shiki` does not use. One pinned import set keeps the surface
  area small.
  Date: 2026-05-26

- Decision: `Shiki.K8s.JobBuilder.buildJob` is pure — it takes a `ServiceConfig`, a
  `DeploymentSnapshot`, and a `JobInputs` value and returns a `V1Job`. The runner is the
  only side-effectful component.
  Rationale: Lets us unit-test the YAML/Job structure without a cluster; mirrors the
  pattern of separating "decide" from "apply" used elsewhere in the user's projects.
  Date: 2026-05-26

- Decision: Wait for completion by polling `readNamespacedJobStatus` every 5 seconds with
  a default `--timeout 96h` (matching the existing shell script's
  `kubectl wait --timeout=345600s`). Use the same `JobInputs.timeout` field to override
  per-run.
  Rationale: The library's `Watch` support is async-iterator-style and adds a dependency
  graph (streaming-bytestring, oidc-client) that we can defer to a future change. Polling
  every 5 s is one HTTP call per 5 s of wall-clock and is more than sufficient for
  one-off jobs.
  Date: 2026-05-26

- Decision: Capture the log tail by calling `readNamespacedPodLog` on the Pod managed by
  the Job after completion, with `tailLines = 200` (~64 KiB at typical log sizes).
  Truncate to 64 KiB on the Haskell side before returning.
  Rationale: 200 lines/64 KiB matches the column size policy in
  `docs/plans/2-postgresql-schema-migrations-and-run-persistence.md`. The Job's Pod stays
  alive until `ttlSecondsAfterFinished` expires (we set 1 hour, matching the shell
  script), so logs are reliably retrievable in normal cases.
  Date: 2026-05-26


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

### Project layout

`shiki` is laid out as two cabal packages — `shiki-core` (library) and `shiki-cli`
(library + `shiki` executable) — under
`/Users/shinzui/Keikaku/bokuno/shiki/`. GHC 9.12.4 is supplied by the Nix flake's dev
shell (`nix develop`). The Haskell standards adopted by this project are in
`/Users/shinzui/Keikaku/bokuno/haskell-jitsurei` and condensed in the MasterPlan's
Decision Log; the most relevant rules for this plan:

- All modules import `Shiki.Prelude` (extended by EP-1 to re-export `Generic`, `Text`,
  `UTCTime`, `MonadIO`, `FromJSON`/`ToJSON`, and `Control.Lens`).
- Postpositive `qualified` imports
  (`import Kubernetes.OpenAPI.Model qualified as K8s`).
- Records: no field prefixes, strict `!`, explicit deriving strategies, `#fieldName` lens
  access (`r ^. #field`, `r & #field .~ v`).
- `MultilineStrings` `"""..."""` for any embedded text literal of more than two lines.

### `kubernetes-api` orientation

The `codedownio/kubernetes-api` repository at
`/Users/shinzui/Keikaku/hub/haskell/kubernetes-api-project/` ships two relevant cabal
packages:

- `kubernetes-api-1.34` (in `kubernetes-api/kubernetes-api-1.34/`) — auto-generated from
  the OpenAPI spec. Module roots: `Kubernetes.OpenAPI`,
  `Kubernetes.OpenAPI.Model`, `Kubernetes.OpenAPI.API.BatchV1`,
  `Kubernetes.OpenAPI.API.CoreV1`, `Kubernetes.OpenAPI.API.AppsV1`. Each API call is a
  function that takes a `KubernetesRequest` parameterised by an operation type and
  returns a `KubernetesResponse`.
- `kubernetes-api-client` (in `kubernetes-api/kubernetes-api-client/`) — hand-written
  helpers. Module roots: `Kubernetes.Client`, `Kubernetes.Client.Config`,
  `Kubernetes.Client.KubeConfig`, `Kubernetes.Client.Auth.*`,
  `Kubernetes.Client.Watch`. Notable: `Kubernetes.Client.Config.mkKubeClientConfig`
  parses `~/.kube/config` and wires auth handlers.

For our purposes:

- Job CRUD lives in `Kubernetes.OpenAPI.API.BatchV1`. Relevant ops:
  `createNamespacedJob`, `readNamespacedJob`, `readNamespacedJobStatus`,
  `deleteNamespacedJob`.
- Deployment inspection lives in `Kubernetes.OpenAPI.API.AppsV1`. Relevant op:
  `readNamespacedDeployment`.
- Pod listing and log fetching live in `Kubernetes.OpenAPI.API.CoreV1`. Relevant ops:
  `listNamespacedPod` (with label selector
  `controller-uid=<uid>` to find the Job's Pod), `readNamespacedPodLog`.

The data model lives in `Kubernetes.OpenAPI.Model` — `V1Job`, `V1JobSpec`,
`V1PodTemplateSpec`, `V1PodSpec`, `V1Container`, `V1EnvVar`, `V1EnvVarSource`,
`V1ConfigMapKeySelector`, `V1SecretKeySelector`, `V1ResourceRequirements`,
`V1ObjectMeta`, etc.

The handwritten `kubernetes-api-client` package depends on `http-client`,
`http-client-tls`, `crypton-x509-*`, `hoauth2`, `oidc-client`, `jose-jwt`, and friends —
all of which the Nix devshell already provides through `haskellPackages`. If the build
fails because one of these is missing, add it to `cabal.project` as a
`source-repository-package` from the upstream Git location pinned to a known-good
commit.

### Existing shell script reference

The Job structure we produce mirrors the YAML emitted by
`/Users/shinzui/Keikaku/work/microtan/mls-service-v2-master/scripts/infrastructure/run-oneoff-task.sh`
one-for-one. The key fields are:

- `metadata.name` — generated as `<service-name>-oneoff-<YYYYMMDD-HHMMSS>-<pid>` (we
  substitute a 6-character random suffix for `pid`).
- `metadata.namespace` — from `JobInputs.namespace`.
- `spec.backoffLimit: 0`, `spec.ttlSecondsAfterFinished: 3600`.
- `spec.template.metadata.labels.app: <service-name>-oneoff`.
- `spec.template.spec.restartPolicy: Never`, `serviceAccount`, `serviceAccountName`,
  `nodeSelector`.
- `spec.template.spec.initContainers` — built from `ServiceConfig.initContainers`. Each
  entry that has `restartable = True` gets `restartPolicy: Always` (Kubernetes 1.28+
  sidecar pattern).
- `spec.template.spec.containers[0]` — built from
  `ServiceConfig.{containerName, commandPath}` plus `JobInputs.args` and the env-var
  wiring derived from `ServiceConfig.env` and the live `DeploymentSnapshot`.

### Cross-plan contract

From the MasterPlan's Integration Points:

> **`Shiki.K8s.Runner.JobOutcome`** (Haskell record returned by the runner, module
> `Shiki.K8s.Runner` in `shiki-core/src/Shiki/K8s/Runner.hs`). Defined by EP-3. Consumed
> by EP-4 to translate cluster-side results into the `RunRecord` finalization update.
> Contains job name, final phase, exit code, start/end timestamps as observed from the
> cluster, and a truncated log tail.

The `ServiceConfig` type consumed by `buildJob` is defined in
`shiki-core/src/Shiki/Service/Config.hs` per
`docs/plans/1-service-configuration-model-and-dhall-loader.md`. The relevant fields are
repeated here for self-containment:

```haskell
data ServiceConfig = ServiceConfig
  { name                 :: !ServiceName     -- newtype Text
  , defaultNamespace     :: !Text
  , detectFromDeployment :: !Text
  , containerName        :: !Text
  , commandPath          :: !Text
  , serviceAccount       :: !Text
  , nodeSelector         :: !(Map Text Text)
  , initContainers       :: ![InitContainer]
  , env                  :: ![EnvVar]
  , resources            :: !Resources
  }
```


## Plan of Work

### Milestone 1 — Dependency wiring and bare ghci import

Scope: extend `cabal.project` and `shiki-core.cabal` to depend on the Kubernetes packages
without yet writing any logic. Verify they compile in our toolchain.

Edit `cabal.project` to add:

```text
source-repository-package
  type: git
  location: https://github.com/codedownio/kubernetes-api
  tag: <pinned commit sha>
  subdir: kubernetes-api/kubernetes-api-1.34
          kubernetes-api/kubernetes-api-client
```

Discover the commit by reading
`/Users/shinzui/Keikaku/hub/haskell/kubernetes-api-project/kubernetes-api/kubernetes-api-1.34/`
and noting the HEAD of its mori-tracked checkout; pin to that sha.

Edit `shiki-core/shiki-core.cabal` library `build-depends`:

```cabal
    , kubernetes-api ^>= 0.5
    , kubernetes-api-client ^>= 0.6
    , http-client ^>= 0.7
    , http-client-tls
```

Acceptance: `cabal build shiki-core` succeeds. `cabal repl shiki-core` and
`:m + Kubernetes.OpenAPI.Model` works, then `:t (undefined :: V1Job)` returns `V1Job`.

### Milestone 2 — `Shiki.K8s.Client`: load kubeconfig and produce a `ClientEnv`

Scope: a thin wrapper that abstracts the kubeconfig loading + manager construction. After
this milestone, callers can hand back a `(Manager, KubernetesClientConfig)` pair (the
"`ClientEnv`") that subsequent API calls consume.

Add `shiki-core/src/Shiki/K8s/Client.hs`:

```haskell
module Shiki.K8s.Client
  ( ClientEnv (..)
  , loadDefaultClientConfig
  ) where

import Shiki.Prelude

import Kubernetes.OpenAPI qualified as K8s
import Kubernetes.Client.Config qualified as KC
import Network.HTTP.Client (Manager)

-- | A bundle of the HTTP 'Manager' and the typed Kubernetes client config
-- used by every API call.
data ClientEnv = ClientEnv
  { httpManager  :: !Manager
  , clientConfig :: !K8s.KubernetesClientConfig
  }
  deriving stock (Generic)

-- | Load the operator's current kube context from @~/.kube/config@.
-- Honors the @KUBECONFIG@ env var if set. Resolves the current-context
-- cluster, user, and namespace; wires GCP / OIDC / token auth as appropriate.
loadDefaultClientConfig :: IO ClientEnv
loadDefaultClientConfig = do
  (mgr, cfg) <- KC.mkKubeClientConfig Nothing Nothing
  pure ClientEnv { httpManager = mgr, clientConfig = cfg }
```

> Verify `KC.mkKubeClientConfig`'s exact signature against
> `/Users/shinzui/Keikaku/hub/haskell/kubernetes-api-project/kubernetes-api/kubernetes-api-client/src/Kubernetes/Client/Config.hs`.
> The two `Nothing`s above stand in for "no kubeconfig path override" and
> "no context override"; adjust to whatever the actual API expects.

Add `Shiki.K8s.Client` to `exposed-modules` in `shiki-core.cabal`.

Acceptance: `cabal repl shiki-core`; `:t loadDefaultClientConfig` returns
`IO ClientEnv`.

### Milestone 3 — `Shiki.K8s.Introspection`: read a Deployment, return a snapshot

Scope: implement `inspectDeployment` returning the dynamic values needed to build a Job.

Add `shiki-core/src/Shiki/K8s/Introspection.hs`:

```haskell
module Shiki.K8s.Introspection
  ( DeploymentSnapshot (..)
  , DeploymentName (..)
  , Namespace (..)
  , InspectionError (..)
  , inspectDeployment
  ) where

import Shiki.Prelude

import Shiki.K8s.Client (ClientEnv (..))

import Control.Exception (Exception, throwIO)
import Data.List qualified as List
import Data.Text qualified as Text
import Kubernetes.OpenAPI qualified as K8s
import Kubernetes.OpenAPI.API.AppsV1 qualified as AppsV1
import Kubernetes.OpenAPI.Model qualified as K8sModel

newtype Namespace      = Namespace      { unNamespace      :: Text }
  deriving stock (Generic, Eq, Show)
  deriving newtype (FromJSON, ToJSON)

newtype DeploymentName = DeploymentName { unDeploymentName :: Text }
  deriving stock (Generic, Eq, Show)
  deriving newtype (FromJSON, ToJSON)

-- | The dynamic values we read from the running Deployment to fill in
-- a one-off Job.
data DeploymentSnapshot = DeploymentSnapshot
  { image         :: !Text
  , configMapName :: !Text
  , secretName    :: !Text
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data InspectionError
  = DeploymentNotFound !Namespace !DeploymentName
  | ContainerNotFound  !Text
  | NoConfigMapBinding
  | NoSecretBinding
  deriving stock (Generic, Eq, Show)
  deriving anyclass (Exception)

-- | Read the named Deployment, find the container whose name matches
-- 'containerName', and extract its image plus the first ConfigMap and
-- Secret env-var sources.
inspectDeployment
  :: ClientEnv
  -> Namespace
  -> DeploymentName
  -> Text          -- ^ container name in the deployment
  -> IO DeploymentSnapshot
inspectDeployment env ns dep containerName = do
  let req = AppsV1.readNamespacedDeployment
              (K8s.Accept K8s.MimeJSON)
              (K8s.Name (unDeploymentName dep))
              (K8s.Namespace (unNamespace ns))
  resp <- K8s.dispatchMime (env ^. #httpManager) (env ^. #clientConfig) req
  deployment <- case K8s.mimeResult resp of
    Left err -> throwIO err
    Right d  -> pure d

  containers <-
    case deployment ^. #specL . #templateL . #specL . #containersL of
      Nothing -> throwIO (ContainerNotFound containerName)
      Just cs -> pure cs

  container <-
    case List.find (\c -> (c ^. #nameL) == Just containerName) containers of
      Nothing -> throwIO (ContainerNotFound containerName)
      Just c  -> pure c

  image <- case container ^. #imageL of
    Nothing -> throwIO (ContainerNotFound containerName)
    Just i  -> pure i

  -- Find first ConfigMap and first Secret env source on this container.
  let envs = fromMaybe [] (container ^. #envL)
      configMapNames = [ cm
                       | e <- envs
                       , Just src <- [e ^. #valueFromL]
                       , Just cmRef <- [src ^. #configMapKeyRefL]
                       , Just cm <- [cmRef ^. #nameL]
                       ]
      secretNames    = [ s
                       | e <- envs
                       , Just src <- [e ^. #valueFromL]
                       , Just sRef <- [src ^. #secretKeyRefL]
                       , Just s <- [sRef ^. #nameL]
                       ]

  cm <- case configMapNames of
    (n : _) -> pure n
    []      -> throwIO NoConfigMapBinding
  sec <- case secretNames of
    (n : _) -> pure n
    []      -> throwIO NoSecretBinding

  pure DeploymentSnapshot
    { image         = image
    , configMapName = cm
    , secretName    = sec
    }
```

> Field-lens names like `#specL`, `#templateL` are illustrative — the
> generated OpenAPI models use plain field-name labels (`#spec`, `#template`,
> `#containers`). Read
> `/Users/shinzui/Keikaku/hub/haskell/kubernetes-api-project/kubernetes-api/kubernetes-api-1.34/lib/Kubernetes/OpenAPI/Model.hs`
> to confirm. Adjust the labels to match what the generated `HasField`
> instances export.

Add `Shiki.K8s.Introspection` to `exposed-modules`.

Acceptance: `cabal build shiki-core` succeeds. Manual: in `cabal repl shiki-core`
against a cluster where `kubectl get deployments -n prod mls-service-v2-worker` works,

```haskell
env <- loadDefaultClientConfig
inspectDeployment env (Namespace "prod") (DeploymentName "mls-service-v2-worker") "mls-service-v2"
```

returns a `DeploymentSnapshot` whose `image` field starts with `gcr.io/...`.

### Milestone 4 — `Shiki.K8s.JobBuilder`: pure `V1Job` construction

Scope: turn `(ServiceConfig, DeploymentSnapshot, JobInputs)` into a `V1Job`. No I/O.

Add `shiki-core/src/Shiki/K8s/JobBuilder.hs`:

```haskell
module Shiki.K8s.JobBuilder
  ( JobInputs (..)
  , buildJob
  , generateJobName
  ) where

import Shiki.Prelude

import Shiki.Service.Config
  ( EnvSource (..), EnvVar, InitContainer, Resources, ServiceConfig
  , ServiceName (..)
  )
import Shiki.K8s.Introspection (DeploymentSnapshot, Namespace (..))

import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Time.Format qualified as TimeFmt
import Kubernetes.OpenAPI.Model qualified as K8s
import System.Random qualified as Random

-- | Per-invocation inputs that are not part of the static service config.
data JobInputs = JobInputs
  { namespace :: !Namespace
  , args      :: ![Text]
  , jobName   :: !Text         -- ^ generated up-front so callers can record it
  }
  deriving stock (Generic, Eq, Show)

-- | Generate @<service>-oneoff-YYYYMMDD-HHMMSS-XXXXXX@. The random suffix
-- replaces the @$$@ pid in the original shell script and need not be
-- cryptographically strong.
generateJobName :: ServiceName -> UTCTime -> IO Text
generateJobName (ServiceName svc) now = do
  let stamp = Text.pack (TimeFmt.formatTime TimeFmt.defaultTimeLocale "%Y%m%d-%H%M%S" now)
  suffix <- Text.pack <$> replicateM 6 (Random.randomRIO ('a', 'z'))
  pure (svc <> "-oneoff-" <> stamp <> "-" <> suffix)

-- | Pure construction of a @batch/v1@ 'V1Job' matching the structure
-- emitted by run-oneoff-task.sh.
buildJob :: ServiceConfig -> DeploymentSnapshot -> JobInputs -> K8s.V1Job
buildJob svc snap inputs =
  K8s.mkV1Job
    & #metadata .~ Just metadata
    & #spec     .~ Just spec
  where
    metadata = K8s.mkV1ObjectMeta
      & #name      .~ Just (inputs ^. #jobName)
      & #namespace .~ Just (unNamespace (inputs ^. #namespace))

    spec = K8s.mkV1JobSpec
      & #backoffLimit            .~ Just 0
      & #ttlSecondsAfterFinished .~ Just 3600
      & #template                .~ podTemplate

    podTemplate = K8s.mkV1PodTemplateSpec
      & #metadata .~ Just
          ( K8s.mkV1ObjectMeta
              & #labels .~ Just (Map.fromList [("app", unServiceName (svc ^. #name) <> "-oneoff")])
          )
      & #spec .~ Just podSpec

    podSpec = K8s.mkV1PodSpec [mainContainer]
      & #restartPolicy      .~ Just "Never"
      & #serviceAccount     .~ Just (svc ^. #serviceAccount)
      & #serviceAccountName .~ Just (svc ^. #serviceAccount)
      & #nodeSelector       .~ Just (svc ^. #nodeSelector)
      & #initContainers     .~ Just (map (mkInitContainer snap) (svc ^. #initContainers))

    mainContainer =
      K8s.mkV1Container (svc ^. #containerName)
        & #image     .~ Just (snap ^. #image)
        & #command   .~ Just [svc ^. #commandPath]
        & #args      .~ Just (inputs ^. #args)
        & #env       .~ Just (map (toV1EnvVar snap) (svc ^. #env))
        & #resources .~ Just (toResourceRequirements (svc ^. #resources))

mkInitContainer :: DeploymentSnapshot -> InitContainer -> K8s.V1Container
mkInitContainer snap ic =
  K8s.mkV1Container (ic ^. #name)
    & #image         .~ Just (ic ^. #image)
    & #args          .~ Just (ic ^. #args)
    & #env           .~ Just (map (toV1EnvVar snap) (ic ^. #env))
    & #resources     .~ Just (toResourceRequirements (ic ^. #resources))
    & #restartPolicy .~ (if ic ^. #restartable then Just "Always" else Nothing)

toV1EnvVar :: DeploymentSnapshot -> EnvVar -> K8s.V1EnvVar
toV1EnvVar snap ev = case ev ^. #source of
  ConfigMap k ->
    K8s.mkV1EnvVar (ev ^. #name)
      & #valueFrom .~ Just
          ( K8s.mkV1EnvVarSource
              & #configMapKeyRef .~ Just
                  ( K8s.mkV1ConfigMapKeySelector k
                      & #name .~ Just (snap ^. #configMapName)
                  )
          )
  Secret k ->
    K8s.mkV1EnvVar (ev ^. #name)
      & #valueFrom .~ Just
          ( K8s.mkV1EnvVarSource
              & #secretKeyRef .~ Just
                  ( K8s.mkV1SecretKeySelector k
                      & #name .~ Just (snap ^. #secretName)
                  )
          )
  Literal v ->
    K8s.mkV1EnvVar (ev ^. #name)
      & #value .~ Just v

toResourceRequirements :: Resources -> K8s.V1ResourceRequirements
toResourceRequirements r =
  K8s.mkV1ResourceRequirements
    & #requests .~ Just (Map.fromList
        [ ("cpu",    r ^. #cpuRequest)
        , ("memory", r ^. #memoryRequest)
        ])
    & #limits   .~ Just (Map.fromList
        [ ("cpu",    r ^. #cpuLimit)
        , ("memory", r ^. #memoryLimit)
        ])
```

> The `mkV1*` smart-constructor names follow the convention used by the
> generated `kubernetes-api` modules. Verify the exact constructor names
> against `Kubernetes.OpenAPI.Model`. The lens labels (`#metadata`, `#spec`,
> etc.) match the OpenAPI field names; if the generated record uses prefixed
> labels (e.g., `v1JobMetadata`), use `#v1JobMetadata` instead.

Add `Shiki.K8s.JobBuilder` to `exposed-modules`. Add `random ^>= 1.2` to `build-depends`
in `shiki-core.cabal`.

### Milestone 5 — `Shiki.K8s.Runner`: submit + wait + collect logs

Scope: tie everything together. `runJob` submits the Job, polls until completion or
timeout, fetches the pod log tail, and returns a `JobOutcome`. `submitJob` does the
same but returns immediately after submission (no waiting).

Add `shiki-core/src/Shiki/K8s/Runner.hs`:

```haskell
module Shiki.K8s.Runner
  ( JobOutcome (..)
  , JobPhase (..)
  , JobInputs (..)
  , submitJob
  , runJob
  ) where

import Shiki.Prelude

import Shiki.K8s.Client (ClientEnv (..))
import Shiki.K8s.Introspection
  ( DeploymentName, DeploymentSnapshot, Namespace (..)
  , inspectDeployment
  )
import Shiki.K8s.JobBuilder (JobInputs (..), buildJob)
import Shiki.Service.Config (ServiceConfig)

import Control.Concurrent (threadDelay)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import Kubernetes.OpenAPI qualified as K8s
import Kubernetes.OpenAPI.API.BatchV1 qualified as BatchV1
import Kubernetes.OpenAPI.API.CoreV1  qualified as CoreV1

data JobPhase
  = JobSucceeded
  | JobFailed   !Text     -- reason
  | JobTimedOut
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data JobOutcome = JobOutcome
  { jobName     :: !Text
  , namespace   :: !Text
  , phase       :: !JobPhase
  , exitCode    :: !(Maybe Int)
  , startedAt   :: !UTCTime
  , endedAt     :: !UTCTime
  , logTail     :: !(Maybe Text)
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

-- | Build the Job, submit it, and return immediately. Used for --no-wait.
submitJob
  :: ClientEnv
  -> ServiceConfig
  -> DeploymentSnapshot
  -> JobInputs
  -> IO ()      -- ^ throws on API error
submitJob env svc snap inputs = do
  let job = buildJob svc snap inputs
      req = BatchV1.createNamespacedJob
              (K8s.ContentType K8s.MimeJSON)
              (K8s.Accept K8s.MimeJSON)
              job
              (K8s.Namespace (unNamespace (inputs ^. #namespace)))
  resp <- K8s.dispatchMime (env ^. #httpManager) (env ^. #clientConfig) req
  case K8s.mimeResult resp of
    Left err -> error ("shiki: createNamespacedJob failed: " <> show err)
    Right _  -> pure ()

-- | Submit and wait. Returns a 'JobOutcome' that EP-4 can translate into a
-- 'RunCompletion'.
runJob
  :: ClientEnv
  -> ServiceConfig
  -> DeploymentSnapshot
  -> JobInputs
  -> Int             -- ^ poll interval, seconds (default 5)
  -> Int             -- ^ overall timeout, seconds (default 345600 = 96 h)
  -> IO JobOutcome
runJob env svc snap inputs pollSec timeoutSec = do
  startedAt <- getCurrentTime
  submitJob env svc snap inputs
  phase <- waitForCompletion env inputs startedAt pollSec timeoutSec
  endedAt <- getCurrentTime
  logs <- fetchLogTail env inputs
  pure JobOutcome
    { jobName   = inputs ^. #jobName
    , namespace = unNamespace (inputs ^. #namespace)
    , phase     = phase
    , exitCode  = exitCodeForPhase phase
    , startedAt = startedAt
    , endedAt   = endedAt
    , logTail   = logs
    }

exitCodeForPhase :: JobPhase -> Maybe Int
exitCodeForPhase = \case
  JobSucceeded   -> Just 0
  JobFailed _    -> Just 1
  JobTimedOut    -> Nothing

-- | Poll readNamespacedJobStatus until the Job reports succeeded != 0
-- or failed != 0, or the timeout elapses.
waitForCompletion
  :: ClientEnv -> JobInputs -> UTCTime -> Int -> Int -> IO JobPhase
waitForCompletion env inputs startedAt pollSec timeoutSec =
  go
  where
    go = do
      now <- getCurrentTime
      if realToFrac (diffUTCTime now startedAt) > fromIntegral timeoutSec
        then pure JobTimedOut
        else do
          status <- readJobStatus env inputs
          case interpret status of
            Nothing  -> threadDelay (pollSec * 1_000_000) >> go
            Just phs -> pure phs

    interpret :: K8s.V1JobStatus -> Maybe JobPhase
    interpret s = case (s ^. #succeeded, s ^. #failed) of
      (Just n, _) | n > 0 -> Just JobSucceeded
      (_, Just n) | n > 0 -> Just (JobFailed (firstFailureReason s))
      _                   -> Nothing

    firstFailureReason :: K8s.V1JobStatus -> Text
    firstFailureReason s =
      case s ^. #conditions of
        Just (c : _) -> fromMaybe "Failed" (c ^. #reason)
        _            -> "Failed"

readJobStatus :: ClientEnv -> JobInputs -> IO K8s.V1JobStatus
readJobStatus env inputs = do
  let req = BatchV1.readNamespacedJobStatus
              (K8s.Accept K8s.MimeJSON)
              (K8s.Name    (inputs ^. #jobName))
              (K8s.Namespace (unNamespace (inputs ^. #namespace)))
  resp <- K8s.dispatchMime (env ^. #httpManager) (env ^. #clientConfig) req
  job <- case K8s.mimeResult resp of
    Left err -> error ("shiki: readNamespacedJobStatus failed: " <> show err)
    Right j  -> pure j
  pure (fromMaybe (K8s.mkV1JobStatus) (job ^. #status))

-- | Fetch the last 200 lines of stdout/stderr from the Pod that the Job
-- created, then truncate to 64 KiB before returning.
fetchLogTail :: ClientEnv -> JobInputs -> IO (Maybe Text)
fetchLogTail env inputs = do
  -- Find the Pod by label selector job-name=<jobName>; take the first match.
  let listReq = CoreV1.listNamespacedPod
                  (K8s.Accept K8s.MimeJSON)
                  (K8s.Namespace (unNamespace (inputs ^. #namespace)))
                & K8s.applyOptionalParam
                    (K8s.LabelSelector ("job-name=" <> inputs ^. #jobName))
  listResp <- K8s.dispatchMime (env ^. #httpManager) (env ^. #clientConfig) listReq
  podList <- case K8s.mimeResult listResp of
    Left _   -> pure Nothing
    Right ps -> pure (Just ps)
  case podList >>= fmap (^. #items) of
    Just (pod : _) | Just nm <- pod ^. #metadata . _Just . #name -> do
      let logReq = CoreV1.readNamespacedPodLog
                     (K8s.Accept K8s.MimeJSON)
                     (K8s.Name nm)
                     (K8s.Namespace (unNamespace (inputs ^. #namespace)))
                   & K8s.applyOptionalParam (K8s.TailLines 200)
      logResp <- K8s.dispatchMime (env ^. #httpManager) (env ^. #clientConfig) logReq
      case K8s.mimeResult logResp of
        Left _    -> pure Nothing
        Right txt -> pure (Just (truncate64K txt))
    _ -> pure Nothing
  where
    truncate64K t
      | Text.lengthWord8 t <= 65536 = t
      | otherwise = Text.takeEnd 65536 t
```

> Several `kubernetes-api` API call signatures and parameter-application
> helpers (e.g., `K8s.applyOptionalParam`, `K8s.LabelSelector`,
> `K8s.TailLines`) are illustrative. Read
> `/Users/shinzui/Keikaku/hub/haskell/kubernetes-api-project/kubernetes-api/kubernetes-api-1.34/lib/Kubernetes/OpenAPI/API/CoreV1.hs`
> for the actual names and adjust. The semantics are unchanged: list pods
> with `job-name=<X>` label, take the first, read its tail.

Add `Shiki.K8s.Runner` to `exposed-modules`.

Acceptance: `cabal build shiki-core` succeeds.

### Milestone 6 — `shiki-core/example/RunOnce.hs`: end-to-end live verification

Scope: an example executable that an operator can run against their current kube context
to verify the runner works end-to-end.

Add `shiki-core/example/RunOnce.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Shiki.Prelude

import Shiki.K8s.Client (loadDefaultClientConfig)
import Shiki.K8s.Introspection (DeploymentName (..), Namespace (..), inspectDeployment)
import Shiki.K8s.JobBuilder (JobInputs (..), generateJobName)
import Shiki.K8s.Runner (runJob)
import Shiki.Service.Config (ServiceName (..))
import Shiki.Service.Config.Dhall (loadServiceConfig)

import Data.Time.Clock (getCurrentTime)
import System.Environment (getArgs)

-- usage: shiki-run-once <service-name> -- <command args...>
main :: IO ()
main = do
  args <- getArgs
  (svcName, cmd) <- case args of
    (s : "--" : rest) -> pure (s, rest)
    _ -> error "usage: shiki-run-once <service-name> -- <args...>"
  cfg  <- loadServiceConfig ("services/" <> svcName <> ".dhall")
  env  <- loadDefaultClientConfig
  snap <- inspectDeployment env
            (Namespace (cfg ^. #defaultNamespace))
            (DeploymentName (cfg ^. #detectFromDeployment))
            (cfg ^. #containerName)
  now  <- getCurrentTime
  nm   <- generateJobName (cfg ^. #name) now
  let inputs = JobInputs
        { namespace = Namespace (cfg ^. #defaultNamespace)
        , args      = fromString <$> cmd
        , jobName   = nm
        }
  outcome <- runJob env cfg snap inputs 5 345600
  print outcome
```

Edit `shiki-core/shiki-core.cabal`:

```cabal
executable shiki-run-once
  import: common-options
  main-is: RunOnce.hs
  hs-source-dirs: example
  build-depends:
    base >=4.20 && <5,
    shiki-core,
    time,
```

Acceptance: `cabal build shiki-run-once` succeeds.

### Milestone 7 — Unit test for `buildJob`

Scope: assert that the pure Job builder produces the expected structure without contacting
a cluster.

Add `shiki-core/test/Shiki/K8s/JobBuilderSpec.hs`:

```haskell
module Shiki.K8s.JobBuilderSpec (tests) where

import Shiki.Prelude

import Shiki.K8s.Introspection (DeploymentSnapshot (..), Namespace (..))
import Shiki.K8s.JobBuilder    (JobInputs (..), buildJob)
import Shiki.Service.Config.Dhall (loadServiceConfig)

import Kubernetes.OpenAPI.Model qualified as K8s
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase)

tests :: TestTree
tests = testGroup "Shiki.K8s.JobBuilder"
  [ testCase "buildJob produces a Job whose container name and command match the config" $ do
      svc <- loadServiceConfig "services/mls-service-v2.dhall"
      let snap = DeploymentSnapshot
            { image         = "gcr.io/example/mls-service-v2:abc"
            , configMapName = "mls-cm"
            , secretName    = "mls-sec"
            }
          inputs = JobInputs
            { namespace = Namespace "prod"
            , args      = ["subscription", "process"]
            , jobName   = "mls-service-v2-oneoff-test"
            }
          job   = buildJob svc snap inputs
          spec  = fromJust (job ^. #spec)
          tmpl  = fromJust (spec ^. #template)
          pspec = fromJust (tmpl ^. #spec)
          containers = fromJust (pspec ^. #containers)
      assertEqual "container count" 1 (length containers)
      let c = head containers
      assertEqual "container name" "mls-service-v2" (fromJust (c ^. #name))
      assertEqual "image"          "gcr.io/example/mls-service-v2:abc"
                                   (fromJust (c ^. #image))
      assertEqual "command"        (Just ["/app/mls-service-v2"])
                                   (c ^. #command)
      assertEqual "args"           (Just ["subscription", "process"])
                                   (c ^. #args)
      assertBool  "has init container"
        (not (null (fromJust (pspec ^. #initContainers))))
  ]

fromJust :: HasCallStack => Maybe a -> a
fromJust = \case
  Just x  -> x
  Nothing -> error "fromJust: Nothing"
```

Wire `Shiki.K8s.JobBuilderSpec` into `shiki-core/test/Spec.hs`:

```haskell
import Shiki.K8s.JobBuilderSpec qualified as JobBuilderSpec
...
main = defaultMain $ testGroup "shiki-core"
  [ ConfigSpec.tests
  , RunSpec.tests
  , JobBuilderSpec.tests
  ]
```

Acceptance: `cabal test shiki-core` passes the new assertions.


## Concrete Steps

All commands assume the working directory is `/Users/shinzui/Keikaku/bokuno/shiki` and the
dev shell is active.

```bash
cabal build shiki-core
cabal build shiki-run-once
```

After Milestone 7:

```bash
cabal test shiki-core
```

Expected (truncated):

```text
shiki-core
  Shiki.Service.Config            (2 tests)  OK
  Shiki.Persistence.Run           (2 tests)  OK
  Shiki.K8s.JobBuilder
    buildJob produces a Job whose container name and command match the config: OK

All 5 tests passed
```

Live integration smoke (manual, against the operator's current kube context):

```bash
cabal run shiki-run-once -- mls-service-v2 -- subscription process --batch-size 1
```

Expected (truncated):

```text
JobOutcome
  { jobName   = "mls-service-v2-oneoff-20260526-153012-abcdef"
  , namespace = "prod"
  , phase     = JobSucceeded
  , exitCode  = Just 0
  , startedAt = 2026-05-26 22:30:12 UTC
  , endedAt   = 2026-05-26 22:31:05 UTC
  , logTail   = Just "...processed 1 subscription...\n"
  }
```


## Validation and Acceptance

After all seven milestones:

1. `cabal build all` succeeds, including `shiki-run-once`.
2. `cabal test shiki-core` passes including the new `JobBuilderSpec` assertions.
3. Manual: `cabal run shiki-run-once -- mls-service-v2 -- <some command>` against a real
   cluster produces a Job (`kubectl get jobs -n prod | grep oneoff` shows it) and the
   binary returns a `JobOutcome` whose `phase` is `JobSucceeded` for a known-good command
   or `JobFailed` for a known-bad one.
4. `kubectl describe job <name> -n prod` shows the same env-var sources, init containers,
   and resources as the existing shell script's emitted YAML.


## Idempotence and Recovery

- `buildJob` is pure and deterministic given its inputs.
- `submitJob` against an existing job name returns an "AlreadyExists" error from
  `kubernetes-api`. The caller decides whether to retry with a fresh name.
- `runJob` polls every `pollSec` seconds and is safe to re-invoke; it allocates a new
  job name per call via `generateJobName`.
- If `runJob` is interrupted (Ctrl-C), the Job continues running in the cluster. Recovery
  is `kubectl delete job <name> -n <ns>` or waiting for `ttlSecondsAfterFinished` (1 h)
  to clean it up.
- If log fetch fails (Pod GC'd), `logTail` is `Nothing` — the rest of the outcome is
  still valid.


## Interfaces and Dependencies

Libraries:

- `kubernetes-api ^>= 0.5` (specifically the `kubernetes-api-1.34` subdirectory of
  `codedownio/kubernetes-api`).
- `kubernetes-api-client ^>= 0.6` (the `kubernetes-api-client` subdirectory of
  `codedownio/kubernetes-api`).
- `http-client`, `http-client-tls` — transitively required.
- `random ^>= 1.2` — `generateJobName` suffix.
- `time ^>= 1.12` — already a `Shiki.Prelude` dependency.

Module surface at end of plan:

- `Shiki.K8s.Client`

  ```haskell
  data ClientEnv = ClientEnv
    { httpManager  :: !Manager
    , clientConfig :: !KubernetesClientConfig
    }
  loadDefaultClientConfig :: IO ClientEnv
  ```

- `Shiki.K8s.Introspection`

  ```haskell
  newtype Namespace      = Namespace      { unNamespace      :: Text }
  newtype DeploymentName = DeploymentName { unDeploymentName :: Text }

  data DeploymentSnapshot = DeploymentSnapshot
    { image         :: !Text
    , configMapName :: !Text
    , secretName    :: !Text
    }

  inspectDeployment :: ClientEnv -> Namespace -> DeploymentName -> Text -> IO DeploymentSnapshot
  ```

- `Shiki.K8s.JobBuilder`

  ```haskell
  data JobInputs = JobInputs
    { namespace :: !Namespace
    , args      :: ![Text]
    , jobName   :: !Text
    }

  generateJobName :: ServiceName -> UTCTime -> IO Text
  buildJob :: ServiceConfig -> DeploymentSnapshot -> JobInputs -> V1Job
  ```

- `Shiki.K8s.Runner`

  ```haskell
  data JobPhase = JobSucceeded | JobFailed Text | JobTimedOut
  data JobOutcome = JobOutcome { jobName, namespace :: !Text, phase :: !JobPhase
                              , exitCode :: !(Maybe Int)
                              , startedAt, endedAt :: !UTCTime
                              , logTail :: !(Maybe Text)
                              }
  submitJob :: ClientEnv -> ServiceConfig -> DeploymentSnapshot -> JobInputs -> IO ()
  runJob    :: ClientEnv -> ServiceConfig -> DeploymentSnapshot -> JobInputs
            -> Int -> Int -> IO JobOutcome
  ```

Downstream consumer:

- `docs/plans/4-run-cli-command-end-to-end.md` — calls `runJob`/`submitJob` and maps the
  returned `JobOutcome` into a `RunCompletion` written via
  `Shiki.Persistence.Run.completeRunStatement`.
