---
id: 11
slug: support-gke-exec-credential-plugin-authentication
title: "Support GKE exec credential plugin authentication"
kind: exec-plan
created_at: 2026-06-05T19:14:35Z
intention: "intention_01ktckajyxe068whbgk34zy152"
---

# Support GKE exec credential plugin authentication

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

`shiki` cannot currently talk to a GKE cluster whose kubeconfig authenticates with an
**exec credential plugin** — the now-standard `gke-gcloud-auth-plugin` mechanism. Every
`shiki run`, `shiki runs`, or any other subcommand that touches Kubernetes dies before
making a single API call with:

```text
shiki: Uncaught exception kubernetes-api-...:Kubernetes.OpenAPI.Core.AuthMethodException:
AuthMethodException "AuthMethod not configured: AuthApiKeyBearerToken"
```

After this change, an operator whose `kubectl` already works against GKE can run `shiki`
with their normal kubeconfig — no manual token juggling — and shiki will mint a bearer
token by invoking the same credential plugin `kubectl` uses, attach it to its Kubernetes
client, and submit/track the Job as usual.

Concretely, after this plan the following works end-to-end against a live GKE cluster
using the operator's unmodified `~/.kube/config` (an `exec:` user, no static token):

```bash
shiki run mls-service-v2 --config-dir services --namespace test -- --help
# ... submits Job, waits, records a `completed` run in shiki.runs
```

Today that same command fails with the `AuthApiKeyBearerToken` exception above; the only
workaround is to hand-build a throwaway kubeconfig containing a static
`gcloud auth print-access-token` bearer token and point `KUBECONFIG` at it. This plan
removes that workaround.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] **M1** — Add `Shiki.K8s.ExecCredential` with kubeconfig parsing types and the
  current-context resolver (user `exec` stanza + referenced cluster). Unit tests against a
  fixture kubeconfig. _(done 2026-06-05; `Shiki.K8s.ExecCredential` with `InteractiveMode`,
  `ExecAuth`, `ClusterRef`, `ResolvedContext`, `KubeConfigDoc`, `execAuthForContext`,
  `readKubeConfigExecAuth`; fixtures `kubeconfig-exec.yaml` / `kubeconfig-token.yaml`; two
  resolver tests green.)_
- [x] **M2** — Add the exec-plugin runner: build `KUBERNETES_EXEC_INFO`, spawn the plugin,
  parse the returned `ExecCredential`, return the bearer token (and expiry). Unit test with
  a fake plugin script. _(done 2026-06-05; `runExecCredential`, `ExecCredentialStatus`,
  `ExecCredentialError`; fixtures `fake-exec-plugin{,-fail,-cert}.sh`; four runner tests green
  — token mint, `KUBERNETES_EXEC_INFO` visibility, non-zero-exit, cert-only rejection.)_
- [ ] **M3** — Wire detection into `Shiki.K8s.Client.loadClientConfig`: when the selected
  user has an `exec` block, mint the token and build the client by reusing the library `Config`
  + its TLS helpers (`addCACertData`/`addCACertFile`/`tlsValidation`) with `setTokenAuth`;
  otherwise fall back to the existing `mkKubeClientConfig` path unchanged.
- [ ] **M4** — Verify end-to-end against the live GKE `test` namespace with the operator's
  real exec-plugin kubeconfig; update shiki docs.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The upstream `kubernetes-api-client` cannot represent exec auth **at all**. Its
  `AuthInfo` record (`Kubernetes.Client.KubeConfig`,
  `/Users/shinzui/Keikaku/hub/haskell/kubernetes-api-project/kubernetes-api/kubernetes-api-client/src/Kubernetes/Client/KubeConfig.hs:121`)
  has fields `clientCertificate`, `clientCertificateData`, `clientKey`, `clientKeyData`,
  `token`, `tokenFile`, `impersonate*`, `username`, `password`, `authProvider` — **no
  `exec` field**. So the exec stanza is silently dropped during YAML decode, and
  `applyAuthSettings` (`.../Config.hs:163`) only chains
  `clientCertFileAuth <|> clientCertDataAuth <|> tokenAuth <|> tokenFileAuth <|> gcpAuth
  <|> cachedOIDCAuth <|> basicAuth`. None match, so no auth handler is installed and the
  request layer later throws `AuthApiKeyBearerToken`. This is why the fix must live in
  shiki and parse the kubeconfig itself rather than extend `AuthInfo` consumption.

- The library's CA helpers operate on the **whole `Config`**, not on extracted CA strings:
  `addCACertData :: MonadThrow m => Config -> TLS.ClientParams -> m TLS.ClientParams`
  (`.../Config.hs:132`) and
  `addCACertFile :: Config -> FilePath -> TLS.ClientParams -> IO TLS.ClientParams`
  (`.../Config.hs:149`). An earlier draft of this plan assumed
  `addCACertData :: Text -> ...` / `addCACertFile :: FilePath -> ...` and a hand-rolled
  `applyClusterCA` over shiki's own `ClusterRef`; that would not type-check, and worse it
  would have dropped the kubeconfig-relative resolution of a `certificate-authority` file
  (the library does `dir </> certFile`). M3 now reuses the library `Config` plus these
  helpers instead of re-deriving CA params (see Decision Log).

- `setTokenAuth` (`.../Auth/Token.hs:30`) is pure and sets
  `configAuthMethods = [AnyAuthMethod (AuthApiKeyBearerToken ("Bearer " <> t))]` — precisely
  the `AuthApiKeyBearerToken` method whose absence throws today. This confirms the whole fix
  reduces to "decode → run plugin → `setTokenAuth`"; no other auth plumbing is required.

- The library's `getCluster`/`getContext`/`getAuthInfo` resolvers (`KubeConfig.hs:198`,
  `:181`, `:189`) only honor `current-context` — there is no explicit-context variant. shiki's
  own `execAuthForContext :: Maybe Text -> ...` therefore carries a capability the library
  lacks; M3 passes `Nothing`, so the override is presently exercised only by unit tests. Kept
  as harmless forward-compatibility, not a requirement.


## Decision Log

Record every decision made while working on the plan.

- Decision: Fix this in shiki rather than patch/upgrade the vendored `kubernetes-api-client`.
  Rationale: The library's `AuthInfo` type does not model `exec` and threading a new auth
  handler through `applyAuthSettings` would mean carrying a fork of a third-party package.
  shiki already owns `Shiki.K8s.Client` as the single chokepoint for building the client,
  and the library exports exactly the lower-level pieces needed (`setMasterURI`,
  `setTokenAuth`, `defaultTLSClientParams`, `addCACertData`, `disableServerCertValidation`,
  `newManager`). Keeping the change shiki-side is smaller and upgrade-safe.
  Date: 2026-06-05

- Decision: Resolve a fresh credential on every CLI invocation; do not implement a
  persistent on-disk token cache keyed by `expirationTimestamp`.
  Rationale: shiki is a short-lived CLI — one process per operator command. `kubectl`'s
  cache exists to avoid re-running the plugin across many rapid calls; shiki makes a handful
  of calls inside one process. Running the plugin once per invocation is correct and simple.
  We still *parse* `expirationTimestamp` so a future long-running mode can cache. Recorded
  as a non-goal below.
  Date: 2026-06-05

- Decision: Support the **token** form of `ExecCredential.status` first
  (`status.token`). Treat the client-cert form (`status.clientCertificateData` +
  `status.clientKeyData`) as out of scope for this plan (GKE's plugin returns a token).
  Rationale: GKE's `gke-gcloud-auth-plugin` returns a bearer token; covering it unblocks the
  real use case. Cert-mode is a clean follow-up that reuses the same runner. The runner will
  detect cert-mode and fail with a clear "not yet supported" error rather than silently
  mis-authenticating.
  Date: 2026-06-05

- Decision: In M3, decode the kubeconfig a second time into the library's `Config`
  (`Kubernetes.Client.KubeConfig`) and build the master URI + TLS with the library's own
  exported helpers (`getCluster`, `addCACertData`, `addCACertFile`, `tlsValidation`), instead
  of re-deriving CA params from shiki's `ClusterRef`.
  Rationale: those helpers take the whole `Config` (verified in source — see Surprises),
  resolve a `certificate-authority` file relative to the kubeconfig directory, and honor
  `insecure-skip-tls-verify`. Reusing them gives the exec path TLS behavior identical to the
  non-exec `mkKubeClientConfig` path for free, and avoids a hand-rolled re-implementation that
  an earlier draft got wrong. shiki's own `ExecAuth`/`ClusterRef` parsing remains the M1/M2
  exec detector and the source of the `KUBERNETES_EXEC_INFO` payload (cluster `server` + CA
  data), keeping those milestones unit-testable without the library types or a live cluster.
  Decoding one small YAML file twice per invocation is negligible.
  Date: 2026-06-05


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

**What shiki does with Kubernetes auth today.** Every subcommand handler receives a
`CliEnv` built once per invocation by `withCliEnv`
(`shiki-cli/src/Shiki/Cli/Env.hs`). `withCliEnv` acquires the Postgres pool, runs shiki's
own migrations, then calls `loadDefaultClientConfig` to produce a `ClientEnv`
(`shiki-core/src/Shiki/K8s/Client.hs`):

```haskell
-- shiki-core/src/Shiki/K8s/Client.hs (current)
data ClientEnv = ClientEnv
  { httpManager  :: !Manager
  , clientConfig :: !K8s.KubernetesClientConfig
  }

loadDefaultClientConfig :: IO ClientEnv
loadDefaultClientConfig = do
  envPath <- lookupEnv "KUBECONFIG"
  path <- case envPath of
    Just p  -> pure p
    Nothing -> (</> ".kube" </> "config") <$> getHomeDirectory
  loadClientConfig (KubeConfigFile path)

loadClientConfig :: KubeConfigSource -> IO ClientEnv
loadClientConfig src = do
  oidcCache <- atomically (newTVar Map.empty)
  (mgr, cfg) <- mkKubeClientConfig oidcCache src   -- <-- the part that can't do exec auth
  pure ClientEnv { httpManager = mgr, clientConfig = cfg }
```

`mkKubeClientConfig` (from package `kubernetes-api-client`, module
`Kubernetes.Client.Config`) decodes the kubeconfig, resolves the master URI and TLS CA from
the current context's cluster, then installs an auth handler from the current context's
user via `applyAuthSettings`. For an exec-plugin user there is no matching handler (see
Surprises), so the returned `KubernetesClientConfig` carries no bearer token and the first
API request throws `AuthMethodException "AuthMethod not configured: AuthApiKeyBearerToken"`.

**The exec credential plugin contract** (Kubernetes client-go; apiVersion
`client.authentication.k8s.io/v1beta1` or `/v1`). A kubeconfig user can declare:

```yaml
users:
- name: gke_tan-cluster_us-west1-a_sennari
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1beta1
      command: gke-gcloud-auth-plugin
      args: null
      env: null
      provideClusterInfo: true
      interactiveMode: IfAvailable
```

To authenticate, a client:

1. Spawns `command` with `args`, with the process environment augmented by the `env`
   list (each entry `{name, value}`), and — **when `provideClusterInfo: true`** — an extra
   environment variable `KUBERNETES_EXEC_INFO` whose value is the JSON of an
   `ExecCredential` *request*:

   ```json
   {
     "apiVersion": "client.authentication.k8s.io/v1beta1",
     "kind": "ExecCredential",
     "spec": {
       "cluster": {
         "server": "https://34.x.y.z",
         "certificate-authority-data": "<base64 PEM>",
         "config": null
       },
       "interactive": false
     }
   }
   ```

2. Reads the plugin's stdout, which is an `ExecCredential` *response*:

   ```json
   {
     "apiVersion": "client.authentication.k8s.io/v1beta1",
     "kind": "ExecCredential",
     "status": {
       "token": "ya29.a0Af...",
       "expirationTimestamp": "2026-06-05T20:14:35Z"
     }
   }
   ```

3. Uses `status.token` as a bearer token on every API request. (Alternatively
   `status.clientCertificateData` + `status.clientKeyData` for mTLS — out of scope here.)

`interactiveMode` governs whether the plugin may prompt: `Never`, `IfAvailable` (GKE's
default), or `Always`. shiki runs non-interactively (it may be invoked from CI/cron), so it
sets `spec.interactive = false` and never attaches a TTY. With `IfAvailable` the plugin
proceeds non-interactively; with `Always` the contract requires the client to refuse when
no TTY is present — shiki will surface a clear error in that case.

**Key files this plan touches:**

- `shiki-core/src/Shiki/K8s/Client.hs` — the wiring chokepoint (modified in M3).
- `shiki-core/src/Shiki/K8s/ExecCredential.hs` — **new** module (M1–M2): kubeconfig exec
  parsing + plugin runner.
- `shiki-core/shiki-core.cabal` — register the new module and add `process` + `yaml`
  dependencies to the library, and the test module to the test-suite.
- `shiki-core/test/Shiki/K8s/ExecCredentialSpec.hs` — **new** tests (M1–M2).
- `shiki-core/test/Spec.hs` — aggregate the new `tests :: TestTree`.

**Library building blocks available (already exported). Signatures below were verified
against the vendored source at
`/Users/shinzui/Keikaku/hub/haskell/kubernetes-api-project/kubernetes-api/kubernetes-api-client/src/Kubernetes/Client/Config.hs`
and `.../KubeConfig.hs`.**

From `Kubernetes.Client.Config`:

- `KubeConfigSource(..)`, `mkKubeClientConfig` — current fallback path.
- `setMasterURI :: Text -> KubernetesClientConfig -> KubernetesClientConfig` (pure).
- `setTokenAuth :: Text -> KubernetesClientConfig -> KubernetesClientConfig` (pure) —
  installs exactly the missing handler. Its body sets
  `configAuthMethods = [AnyAuthMethod (AuthApiKeyBearerToken ("Bearer " <> t))]`, i.e. the
  `AuthApiKeyBearerToken` method the request layer reports as "not configured" today.
- `defaultTLSClientParams :: IO TLS.ClientParams`.
- `addCACertData :: MonadThrow m => Config -> TLS.ClientParams -> m TLS.ClientParams` —
  **takes the whole kubeconfig `Config`**, not a CA string. Internally runs `getCluster`
  (current context) and base64-decodes that cluster's `certificate-authority-data`; a cluster
  with no CA data is returned unchanged.
- `addCACertFile :: Config -> FilePath -> TLS.ClientParams -> IO TLS.ClientParams` — also
  takes the `Config`; the `FilePath` argument is the **kubeconfig's directory**, against which
  it resolves a relative `certificate-authority` file (`dir </> certFile`).
- `tlsValidation :: Config -> TLS.ClientParams -> TLS.ClientParams` — applies
  `disableServerCertValidation` when the cluster has `insecure-skip-tls-verify: true`.
- `disableServerCertValidation :: TLS.ClientParams -> TLS.ClientParams`,
  `newManager :: TLS.ClientParams -> IO Manager`.

From `Kubernetes.Client.KubeConfig` (a fully-exported module — `module ... where`, so every
type and helper is in scope): the kubeconfig model `Config(..)` (has a `FromJSON` instance),
`Cluster(..)` (fields `server`, `insecureSkipTLSVerify`, `certificateAuthority`,
`certificateAuthorityData`), and the current-context resolvers
`getCluster :: Config -> Either String Cluster`, `getContext`, `getAuthInfo`.

From `Kubernetes.OpenAPI`: `K.newConfig :: IO KubernetesClientConfig`.

The key consequence for M3: shiki does **not** hand-roll CA selection. It decodes the
kubeconfig into the library `Config` and calls these helpers directly, so the exec path's TLS
is byte-for-byte what `mkKubeClientConfig` builds for the same context — only the auth handler
differs (`setTokenAuth token` in place of `applyAuthSettings`). Because `getCluster` resolves
the cluster from `current-context`, importing the library's `server`/`Config` names alongside
shiki's own may need a qualified import (e.g. `KC.server`, `KC.Config`) to avoid clashes.

**Test framework.** shiki uses `tasty` + `tasty-hunit`. Each `*Spec` module exports
`tests :: TestTree`; `shiki-core/test/Spec.hs` combines them; `just test` runs
`cabal test all`.


## Plan of Work

### M1 — Kubeconfig exec-stanza parser

**Scope.** A new module `Shiki.K8s.ExecCredential` that decodes a kubeconfig YAML file far
enough to answer one question: "for the current (or named) context, does the user
authenticate via an exec plugin, and if so, what is the plugin spec and the referenced
cluster's server/CA?" This is independent of running anything.

**At the end of M1 there will exist:**

```haskell
module Shiki.K8s.ExecCredential
  ( ExecAuth (..)
  , ClusterRef (..)
  , ResolvedContext (..)
  , execAuthForContext      -- pure resolver over a decoded kubeconfig
  , readKubeConfigExecAuth   -- IO: read file, resolve current/explicit context
  ) where

-- | The user.exec stanza, modelling the client.authentication.k8s.io contract.
data ExecAuth = ExecAuth
  { execApiVersion       :: !Text             -- e.g. "client.authentication.k8s.io/v1beta1"
  , execCommand          :: !Text
  , execArgs             :: ![Text]
  , execEnv              :: ![(Text, Text)]    -- name/value pairs to add to the environment
  , execProvideClusterInfo :: !Bool
  , execInteractiveMode  :: !InteractiveMode   -- Never | IfAvailable | Always (default IfAvailable)
  }
  deriving stock (Eq, Show, Generic)

-- | The cluster the context points at — needed for master URI, TLS, and (when
--   provideClusterInfo is set) the KUBERNETES_EXEC_INFO payload.
data ClusterRef = ClusterRef
  { clusterServer            :: !Text
  , clusterCAData            :: !(Maybe Text)      -- base64 PEM (certificate-authority-data)
  , clusterCAFile            :: !(Maybe FilePath)  -- certificate-authority
  , clusterInsecureSkipTLS   :: !Bool
  }
  deriving stock (Eq, Show, Generic)

data ResolvedContext = ResolvedContext
  { resolvedCluster :: !ClusterRef
  , resolvedExec    :: !(Maybe ExecAuth)  -- Nothing => not an exec user; caller falls back
  }
  deriving stock (Eq, Show, Generic)
```

**How.** Decode the kubeconfig with `Data.Yaml.decodeFileThrow` into a small set of
`FromJSON` records that mirror only the fields we need (`current-context`, `contexts[]`
with `name` + `context.{cluster,user}`, `clusters[]` with `name` + `cluster.{server,
certificate-authority-data, certificate-authority, insecure-skip-tls-verify}`, `users[]`
with `name` + `user.exec.{apiVersion,command,args,env,provideClusterInfo,interactiveMode}`).
Note the kebab-case JSON keys (`current-context`, `certificate-authority-data`) — give each
field an explicit `FromJSON` mapping or a field-label modifier. Unknown fields are ignored
by aeson's record parsing, so we tolerate the rest of a real kubeconfig.

`execAuthForContext :: Maybe Text -> KubeConfigDoc -> Either Text ResolvedContext` selects
the context (explicit name, else `current-context`), looks up its cluster and user by name,
and assembles `ResolvedContext`. Missing context/cluster/user yields a descriptive `Left`.

`readKubeConfigExecAuth :: FilePath -> Maybe Text -> IO ResolvedContext` is the IO wrapper.

**Acceptance.** `cabal test all` passes a new `ExecCredentialSpec` that, against a fixture
kubeconfig containing one exec user and one cluster (committed under
`shiki-core/test/fixtures/`), asserts the resolver returns `resolvedExec = Just ExecAuth{..}`
with the expected command/args and `resolvedCluster` with the expected server and CA data;
and that a fixture with a plain token user resolves to `resolvedExec = Nothing`.

### M2 — Exec plugin runner

**Scope.** Given a `ResolvedContext` whose `resolvedExec` is `Just`, run the plugin and
return a bearer token. No Kubernetes client construction yet.

**At the end of M2 there will exist (same module):**

```haskell
data ExecCredentialStatus = ExecCredentialStatus
  { statusToken               :: !(Maybe Text)
  , statusClientCertData      :: !(Maybe Text)
  , statusClientKeyData       :: !(Maybe Text)
  , statusExpirationTimestamp :: !(Maybe Text)
  }

-- | Run the plugin per the client.authentication.k8s.io contract and return its status.
--   Throws 'ExecCredentialError' on non-zero exit, unparseable stdout, interactive-mode
--   refusal, or a cert-only status (unsupported in this plan).
runExecCredential :: ExecAuth -> ClusterRef -> IO Text   -- returns the bearer token
```

**How.**

1. Build the child environment: start from the parent process environment
   (`System.Environment.getEnvironment`), overlay each `execEnv` pair, and — when
   `execProvideClusterInfo` — add `KUBERNETES_EXEC_INFO` set to the encoded
   `ExecCredential` *request* (apiVersion echoing `execApiVersion`, `kind = "ExecCredential"`,
   `spec.cluster = {server, certificate-authority-data?}`, `spec.interactive = false`).
2. Guard `interactiveMode`: if `Always`, fail fast with a clear error (shiki has no TTY).
   `Never`/`IfAvailable` proceed.
3. Spawn with `System.Process` (`readCreateProcessWithExitCode (proc command args){ env = Just childEnv }` and **empty stdin**). On `ExitFailure n`, throw including the captured
   stderr — this is where "plugin not installed" / "gcloud not logged in" surface.
4. Parse stdout as `ExecCredential` (aeson). Reject if `kind`/`apiVersion` are absent or the
   apiVersion disagrees with the request. If `status.token` is present, return it. If only
   `status.clientCertificateData`/`clientKeyData` are present, throw the explicit
   "client-certificate exec credentials are not yet supported by shiki" error (see Decision
   Log). `expirationTimestamp` is parsed and currently ignored.

Define an `ExecCredentialError` exception type (deriving `Show`, instance `Exception`) so
callers and tests can pattern-match failures.

**Acceptance.** `ExecCredentialSpec` gains cases driven by a committed fake plugin script
(`shiki-core/test/fixtures/fake-exec-plugin.sh`, `chmod +x`) that echoes a canned
`ExecCredential` JSON with a known token and asserts `runExecCredential` returns it; a second
fixture script that exits non-zero asserts an `ExecCredentialError` is thrown carrying the
stderr; a third that emits cert-only status asserts the unsupported-mode error. The test
sets `execCommand` to the fixture script path. A case also asserts that when
`provideClusterInfo` is true the script can see `KUBERNETES_EXEC_INFO` (the script echoes a
token only if that variable is non-empty).

### M3 — Wire detection into the client builder

**Scope.** Make `Shiki.K8s.Client.loadClientConfig` use the exec path when applicable, and
otherwise behave exactly as today.

**How.** Rewrite `loadClientConfig` (and have `loadDefaultClientConfig` keep resolving the
kubeconfig path, but now also pass that path down so we can parse it):

```haskell
loadClientConfig :: KubeConfigSource -> IO ClientEnv
loadClientConfig src@(KubeConfigFile path) = do
  resolved <- readKubeConfigExecAuth path Nothing
  case resolvedExec resolved of
    Nothing   -> mkFromLibrary src                       -- unchanged fallback
    Just exec -> do
      token   <- runExecCredential exec (resolvedCluster resolved)
      kubeCfg <- Yaml.decodeFileThrow path               -- library Config (Kubernetes.Client.KubeConfig)
      mkFromToken kubeCfg (takeDirectory path) token
loadClientConfig src@KubeConfigCluster = mkFromLibrary src   -- in-cluster: unchanged

mkFromLibrary :: KubeConfigSource -> IO ClientEnv  -- the existing oidcCache + mkKubeClientConfig body

-- | Build the client exactly as the library's own 'mkKubeClientConfig' does for the current
--   context — same master URI and same TLS CA selection — but install a bearer-token auth
--   handler from the exec-plugin token instead of running 'applyAuthSettings' (which has no
--   exec handler). 'kubeCfg' is the library's 'Config'; 'dir' is the kubeconfig's directory,
--   needed by 'addCACertFile' to resolve a relative 'certificate-authority' file.
mkFromToken :: Config -> FilePath -> Text -> IO ClientEnv
mkFromToken kubeCfg dir token = do
  let masterURI = either (const "localhost:8080") server (getCluster kubeCfg)  -- mirrors library fallback
  base     <- defaultTLSClientParams
  withData <- addCACertData kubeCfg base          -- MonadThrow IO; base64 CA data
  withFile <- addCACertFile kubeCfg dir withData  -- relative CA file resolved against `dir`
  let tls = tlsValidation kubeCfg withFile        -- honors insecure-skip-tls-verify
  mgr <- newManager tls
  cfg <- (setMasterURI masterURI . setTokenAuth token) <$> K.newConfig
  pure ClientEnv { httpManager = mgr, clientConfig = cfg }
```

`mkFromToken` deliberately reuses the library's own TLS pipeline rather than re-implementing
it. The exported helpers `addCACertData`, `addCACertFile`, and `tlsValidation` each take the
whole `Config` (verified in source — see Surprises): `addCACertData` base64-decodes the
current cluster's `certificate-authority-data`, `addCACertFile` resolves a relative
`certificate-authority` file against the kubeconfig directory, and `tlsValidation` applies
`disableServerCertValidation` when `insecure-skip-tls-verify` is set. This is exactly the
sequence inside the library's internal `configureTLSParams`, so the exec path's TLS is
identical to the non-exec path for the same cluster — the only difference is `setTokenAuth`
in place of `applyAuthSettings`. shiki's `resolvedCluster :: ClusterRef` is still used, but
only to feed `runExecCredential` the cluster `server`/CA data for the `KUBERNETES_EXEC_INFO`
request payload — not to build TLS.

**Acceptance.** Builds clean (`just build` / `cabal build all`). Existing tests still pass.
The real-cluster behavior is verified in M4 (it needs a live GKE endpoint, so it is not a
unit test).

### M4 — End-to-end verification + docs

**Scope.** Prove the original failure is gone using the operator's real exec-plugin
kubeconfig, and document the now-supported auth mode.

**How.** Run a known-succeeding command (`-- --help`, which the target binary prints and
exits 0) against the live GKE `test` namespace using the *unmodified* kubeconfig (the
`exec:` user — do **not** set `KUBECONFIG` to a static-token file). Confirm a `completed`
run is recorded. Then add a short "Authentication" section to shiki's docs (README or the
relevant `docs/` guide) describing exec-plugin support and the `gke-gcloud-auth-plugin`
requirement.


## Concrete Steps

All commands run from the shiki repo root unless noted:

```bash
cd /Users/shinzui/Keikaku/bokuno/shiki
```

**M1 / M2 — create the module and tests, register in cabal.**

1. Create `shiki-core/src/Shiki/K8s/ExecCredential.hs` with the types and functions above.
2. Create `shiki-core/test/Shiki/K8s/ExecCredentialSpec.hs` exporting `tests :: TestTree`,
   plus fixtures under `shiki-core/test/fixtures/` (`kubeconfig-exec.yaml`,
   `kubeconfig-token.yaml`, `fake-exec-plugin.sh`, `fake-exec-plugin-fail.sh`,
   `fake-exec-plugin-cert.sh`; make the `.sh` files executable with `chmod +x`).
3. Edit `shiki-core/shiki-core.cabal`:
   - In the library stanza `exposed-modules:` add `Shiki.K8s.ExecCredential`.
   - In the library `build-depends:` add `process ^>=1.6` and `yaml ^>=0.11`.
   - In `test-suite shiki-core-test` `other-modules:` add `Shiki.K8s.ExecCredentialSpec`,
     and add `process`, `yaml` to its `build-depends` if the tests need them directly.
4. Edit `shiki-core/test/Spec.hs` to import `Shiki.K8s.ExecCredentialSpec` and include its
   `tests` in the aggregate `TestTree`.
5. Build and test:

   ```bash
   just build
   cabal test all 2>&1 | tail -20
   ```

   Expected: the new `ExecCredential` group passes, e.g.

   ```text
   ExecCredential
     resolves exec user from current-context:      OK
     resolves token user to Nothing:               OK
     runExecCredential returns the plugin token:    OK
     non-zero plugin exit raises ExecCredentialError: OK
     cert-only status is rejected as unsupported:   OK
   All N tests passed
   ```

**M3 — wire it in.**

6. Edit `shiki-core/src/Shiki/K8s/Client.hs` per the Plan of Work: add `mkFromLibrary` (the
   existing `oidcCache` + `mkKubeClientConfig` body, unchanged) and `mkFromToken`; branch in
   `loadClientConfig` on `resolvedExec`; in the exec branch decode the kubeconfig into the
   library `Config` with `Data.Yaml.decodeFileThrow` and pass `takeDirectory path` to
   `mkFromToken`. New imports: from `Kubernetes.Client.Config`
   (`defaultTLSClientParams`, `addCACertData`, `addCACertFile`, `tlsValidation`, `newManager`,
   `setMasterURI`, `setTokenAuth`), from `Kubernetes.Client.KubeConfig` (`Config`, `getCluster`,
   and the `server` field — qualify to avoid name clashes), `System.FilePath (takeDirectory)`,
   `Data.Yaml (decodeFileThrow)`, and `Shiki.K8s.ExecCredential`.
7. Rebuild and re-run the suite:

   ```bash
   just build && cabal test all 2>&1 | tail -5
   ```

**M4 — live verification (requires GKE access + `gke-gcloud-auth-plugin` on PATH).**

8. Confirm the active kubeconfig context uses an exec plugin (not a static token):

   ```bash
   kubectl config view --minify -o jsonpath='{.users[0].user.exec.command}'; echo
   # expected: gke-gcloud-auth-plugin
   ```

9. Run shiki with the **normal** kubeconfig (no `KUBECONFIG` override to a token file):

   ```bash
   shiki run mls-service-v2 --config-dir services --namespace test -- --help
   ```

   Expected: shiki submits a Job, waits, and prints a completed run, e.g.
   `run <uuid> Completed job=mls-service-v2-oneoff-...`. Cross-check:

   ```bash
   psql "$PG_CONNECTION_STRING" -x -c \
     "SELECT left(id::text,8) id, status, exit_code, namespace FROM shiki.runs ORDER BY created_at DESC LIMIT 1;"
   # status = completed, exit_code = 0, namespace = test
   ```

10. Add the docs section and commit.

Each commit must carry both trailers:

```text
ExecPlan: docs/plans/11-support-gke-exec-credential-plugin-authentication.md
Intention: intention_01ktckajyxe068whbgk34zy152
```


## Validation and Acceptance

- **Unit (M1–M2):** `cabal test all` passes, including the new `ExecCredential` tests:
  current-context exec resolution, token-user → `Nothing`, successful token mint from a fake
  plugin, non-zero-exit → `ExecCredentialError` carrying stderr, cert-only → explicit
  unsupported error, and `KUBERNETES_EXEC_INFO` visibility when `provideClusterInfo` is true.
- **Build (M3):** `just build` is clean; pre-existing tests still pass (no regression to the
  non-exec path — a plain-token or client-cert kubeconfig still flows through
  `mkKubeClientConfig`).
- **End-to-end (M4):** With a real GKE exec-plugin kubeconfig and **no** static-token
  override, `shiki run ... --namespace test -- --help` records a `completed` run. The
  original symptom — `AuthMethodException "AuthMethod not configured: AuthApiKeyBearerToken"` —
  no longer occurs. This is the precise scenario that fails today (captured in Surprises),
  so its success is the acceptance signal.

The change is effective beyond compilation because M4 exercises a real authenticated round
trip to the API server (Job create + status polls + log fetch), none of which can succeed
without a valid bearer token minted by the plugin.


## Idempotence and Recovery

- M1–M3 are pure code/cabal edits — safe to repeat; re-running `just build` / `cabal test
  all` is idempotent.
- `runExecCredential` is read-only with respect to the cluster (it only runs the local
  credential plugin) and is naturally idempotent; the plugin itself is responsible for any
  token caching it does (e.g. gcloud's own cache).
- M4 submits a real Job to the `test` namespace. Jobs carry `backoffLimit = 0` and
  `ttlSecondsAfterFinished = 3600`, so a verification Job self-deletes within an hour; to
  remove one immediately: `kubectl delete job <job-name> -n test`. Using `-- --help` (a
  no-op that prints usage) keeps the verification side-effect-free inside the app.
- Rollback: the feature is additive and gated on the presence of an `exec` block. Reverting
  the `Shiki.K8s.Client` branch restores the prior behavior exactly; no migrations, schema,
  or data changes are involved.


## Interfaces and Dependencies

**New dependencies (library `shiki-core`):**

- `process ^>=1.6` — spawn the credential plugin (`System.Process.readCreateProcessWithExitCode`).
- `yaml ^>=0.11` — decode the kubeconfig exec/cluster stanzas (the transitive
  `Data.Yaml` from `kubernetes-api-client` is the same package; declare it explicitly).
- `aeson` (already a dep) — encode `KUBERNETES_EXEC_INFO`, decode `ExecCredential` status.
- `bytestring`, `text`, `containers`, `directory`, `filepath`, `time` — already present.

**Reused from `kubernetes-api-client`:** from `Kubernetes.Client.Config` — `setMasterURI`,
`setTokenAuth`, `defaultTLSClientParams`, `addCACertData :: Config -> ...`,
`addCACertFile :: Config -> FilePath -> ...`, `tlsValidation :: Config -> ...`,
`disableServerCertValidation`, `newManager`, `KubeConfigSource(..)`, `mkKubeClientConfig`
(fallback); from `Kubernetes.Client.KubeConfig` — `Config(..)`, `Cluster(..)`, `getCluster`
(current-context cluster, supplying both the master URI and the `Config` the CA helpers
consume); and `Kubernetes.OpenAPI.newConfig`. Because `addCACertData`/`addCACertFile`/
`tlsValidation` consume the whole `Config`, M3 decodes the kubeconfig into `Config` via
`Data.Yaml.decodeFileThrow` rather than passing shiki's own `ClusterRef`.

**Types/signatures that must exist at each milestone:**

- After **M1**: `Shiki.K8s.ExecCredential.{ExecAuth(..), ClusterRef(..), ResolvedContext(..),
  InteractiveMode(..), execAuthForContext, readKubeConfigExecAuth}`.
- After **M2**: `Shiki.K8s.ExecCredential.{ExecCredentialStatus(..), ExecCredentialError(..),
  runExecCredential :: ExecAuth -> ClusterRef -> IO Text}`.
- After **M3**: `Shiki.K8s.Client.loadClientConfig :: KubeConfigSource -> IO ClientEnv`
  (signature unchanged) now honoring exec users; `loadDefaultClientConfig :: IO ClientEnv`
  unchanged in signature. `ClientEnv` is unchanged. Internally, a new
  `mkFromToken :: Config -> FilePath -> Text -> IO ClientEnv` consumes the library's `Config`
  (not shiki's `ClusterRef`) so it can reuse the library TLS helpers.

**Non-goals (explicitly out of scope):**

- Persistent on-disk token caching keyed by `expirationTimestamp` (shiki is short-lived;
  see Decision Log).
- Client-certificate exec credentials (`status.clientCertificateData`/`clientKeyData`); the
  runner detects and rejects these with a clear error for a later plan.
- Any change to the vendored `kubernetes-api-client` package.
- The legacy `authProvider: { name: gcp }` flow (already handled by the library's `gcpAuth`).


## Revision Notes

- **2026-06-05 — Validation pass against the vendored library source.** Reviewed the plan
  end-to-end against
  `/Users/shinzui/Keikaku/hub/haskell/kubernetes-api-project/.../Config.hs` and `.../KubeConfig.hs`
  (located via `mori registry`). The overall approach — fix in shiki, parse the `exec` stanza
  the library drops, mint a token, install it with `setTokenAuth` — was confirmed sound and is
  the best option: `AuthInfo` genuinely has no `exec` field, and `setTokenAuth` sets precisely
  the `AuthApiKeyBearerToken` method the runtime reports as missing.

  One correction was material. The earlier draft cited
  `addCACertData :: Text -> TLS.ClientParams -> Either String TLS.ClientParams` and
  `addCACertFile :: FilePath -> TLS.ClientParams -> IO TLS.ClientParams` and built M3 around a
  hand-rolled `applyClusterCA` over shiki's `ClusterRef`. The real helpers take the whole
  library `Config` (`addCACertData :: MonadThrow m => Config -> ...`,
  `addCACertFile :: Config -> FilePath -> ...`) and resolve a relative `certificate-authority`
  file against the kubeconfig directory. The hand-rolled version would not have compiled and
  would have silently dropped that relative-path handling. M3 now decodes the kubeconfig into
  the library `Config` and reuses `addCACertData`/`addCACertFile`/`tlsValidation` directly, so
  the exec path's TLS is identical to the non-exec `mkKubeClientConfig` path — strictly less
  code and lower risk. Updated: Surprises (signature + relative-path + `setTokenAuth` findings,
  plus the current-context-only resolver note), Decision Log (new decision to reuse the library
  `Config` for TLS), Context/Orientation building-blocks list (corrected signatures, added the
  `KubeConfig` exports), M3 Plan of Work (rewrote `mkFromToken`, removed `applyClusterCA`),
  Concrete Steps step 6, Progress M3, and Interfaces/Dependencies. No milestone count or scope
  change.
