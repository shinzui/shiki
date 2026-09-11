-- | Loads the operator's kubeconfig and produces the @(Manager, Config)@
--   bundle that every other @Shiki.K8s.*@ module needs to talk to the
--   cluster. Centralised so callers do not have to know which kubeconfig
--   path or which auth handler is in play.
module Shiki.K8s.Client
  ( ClientEnv (..),
    KubeConfigSource (..),
    loadDefaultClientConfig,
    loadClientConfig,
    dispatchK8s,
    retryOnUnauthorized,
  )
where

import Control.Concurrent.STM (atomically, newTVar)
import Control.Exception (try)
import Data.Generics.Labels ()
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Yaml qualified as Yaml
import Kubernetes.Client.Config
  ( KubeConfigSource (..),
    addCACertData,
    addCACertFile,
    defaultTLSClientParams,
    mkKubeClientConfig,
    newManager,
    setMasterURI,
    setTokenAuth,
    tlsValidation,
  )
import Kubernetes.Client.KubeConfig qualified as KC
import Kubernetes.OpenAPI qualified as K8s
import Network.HTTP.Client (Manager, responseStatus)
import Network.HTTP.Types.Status (statusCode)
import Shiki.K8s.ExecCredential
  ( KubeConfigError (..),
    readKubeConfigExecAuth,
    runExecCredential,
  )
import Shiki.Prelude
import System.Directory (getHomeDirectory)
import System.Environment (lookupEnv)
import System.FilePath (takeDirectory, (</>))

-- | A bundle of the HTTP connection 'Manager' and the typed
--   'K8s.KubernetesClientConfig' that every API call needs. Built once
--   per CLI invocation by 'loadDefaultClientConfig'.
--
--   The config is held in an 'IORef' because a credential can expire while
--   the process is still running: an exec-plugin token (GKE\'s
--   @gke-gcloud-auth-plugin@ hands out what is left of a one-hour token)
--   routinely dies mid-wait under @shiki run@, whose polling loop is meant
--   to outlive it. 'renewAuth' mints a replacement; 'dispatchK8s' installs
--   it on a 401 and every later call picks it up from the ref.
data ClientEnv = ClientEnv
  { httpManager :: !Manager,
    clientConfigRef :: !(IORef K8s.KubernetesClientConfig),
    -- | Mint a fresh config, or 'Nothing' for auth methods whose credential
    --   shiki does not own (client cert, OIDC, in-cluster service account).
    renewAuth :: !(Maybe (IO K8s.KubernetesClientConfig))
  }
  deriving stock (Generic)

-- | Dispatch a Kubernetes request, re-minting the credential once and
--   retrying if the API server answers @401 Unauthorized@.
--
--   Every @Shiki.K8s.*@ call goes through here rather than calling
--   @dispatchMime@ directly, so a token that expires mid-run costs one
--   retried request instead of failing the run.
dispatchK8s ::
  (K8s.Produces req accept, K8s.MimeUnrender accept res, K8s.MimeType contentType) =>
  ClientEnv ->
  K8s.KubernetesRequest req contentType res accept ->
  IO (K8s.MimeResult res)
dispatchK8s env req =
  retryOnUnauthorized
    isUnauthorized
    (env ^. #renewAuth)
    (writeIORef (env ^. #clientConfigRef))
    (\cfg -> K8s.dispatchMime (env ^. #httpManager) cfg req)
    =<< readIORef (env ^. #clientConfigRef)

-- | Run @perform@; if its result looks unauthorized and a @renew@ action is
--   available, mint a new credential, hand it to @store@, and run @perform@
--   once more with it. Retries at most once: a second 401 is a real answer
--   (the identity genuinely lacks access) rather than an expired token.
retryOnUnauthorized ::
  (Monad m) =>
  -- | Does this result mean \"unauthorized\"?
  (resp -> Bool) ->
  -- | Mint a fresh credential.
  Maybe (m cfg) ->
  -- | Remember the fresh credential for later calls.
  (cfg -> m ()) ->
  -- | Perform the request with a given credential.
  (cfg -> m resp) ->
  cfg ->
  m resp
retryOnUnauthorized unauthorized renew store perform cfg = do
  resp <- perform cfg
  case renew of
    Just mint | unauthorized resp -> do
      cfg' <- mint
      store cfg'
      perform cfg'
    _ -> pure resp

isUnauthorized :: K8s.MimeResult a -> Bool
isUnauthorized r = statusCode (responseStatus (K8s.mimeResultResponse r)) == 401

-- | Resolve the operator's current kube context from the standard locations:
--   honor @KUBECONFIG@ if set, otherwise read @\$HOME/.kube/config@. Wires
--   the auth handlers registered by @kubernetes-api-client@ (token, client
--   cert, GCP, OIDC) by passing a fresh OIDC cache.
loadDefaultClientConfig :: IO ClientEnv
loadDefaultClientConfig = do
  envPath <- lookupEnv "KUBECONFIG"
  path <- case envPath of
    Just p -> pure p
    Nothing -> do
      home <- getHomeDirectory
      pure (home </> ".kube" </> "config")
  loadClientConfig (KubeConfigFile path)

-- | Lower-level variant that takes an explicit 'KubeConfigSource'
--   (file path or @KubeConfigCluster@ for in-cluster service-account auth).
--
--   For a file source we first ask 'Shiki.K8s.ExecCredential' whether the
--   current context's user authenticates via an __exec credential plugin__
--   (e.g. GKE's @gke-gcloud-auth-plugin@). If so — the case the upstream
--   library cannot handle — we mint a bearer token by running the plugin and
--   build the client from it. Otherwise (plain token, client-cert, OIDC, GCP,
--   in-cluster, or a kubeconfig we cannot resolve) we defer to the library's
--   'mkKubeClientConfig' exactly as before.
loadClientConfig :: KubeConfigSource -> IO ClientEnv
loadClientConfig src@(KubeConfigFile path) = do
  resolved <- try (readKubeConfigExecAuth path Nothing)
  case resolved of
    -- Could not resolve a context/cluster/user — let the library try; it has
    -- the same inputs and fails (or falls back) identically to today.
    Left (KubeConfigError _) -> mkFromLibrary src
    Right rc -> case rc ^. #exec of
      Nothing -> mkFromLibrary src
      Just execAuth -> do
        kubeCfg <- Yaml.decodeFileThrow path
        let mintConfig = do
              token <- runExecCredential execAuth (rc ^. #cluster)
              configFromToken kubeCfg token
        mkFromToken kubeCfg (takeDirectory path) mintConfig
loadClientConfig src@KubeConfigCluster = mkFromLibrary src

-- | The original behavior: decode the kubeconfig and install whichever auth
--   handler the library recognizes (token, client cert, GCP, OIDC), using a
--   fresh OIDC cache.
mkFromLibrary :: KubeConfigSource -> IO ClientEnv
mkFromLibrary src = do
  oidcCache <- atomically (newTVar Map.empty)
  (mgr, cfg) <- mkKubeClientConfig oidcCache src
  ref <- newIORef cfg
  pure ClientEnv {httpManager = mgr, clientConfigRef = ref, renewAuth = Nothing}

-- | Build the client exactly as the library's own @mkKubeClientConfig@ does
--   for the current context — same master URI and same TLS CA selection — but
--   install a bearer-token auth handler from the exec-plugin token instead of
--   running @applyAuthSettings@ (which has no exec handler). @kubeCfg@ is the
--   library's @Config@; @dir@ is the kubeconfig's directory, against which a
--   relative @certificate-authority@ file is resolved by 'addCACertFile'.
--   @mintConfig@ mints a config from a freshly run plugin; it is kept on the
--   'ClientEnv' as 'renewAuth' so an expired token can be replaced in place.
--   The TLS 'Manager' is built once and reused: only the bearer token expires.
mkFromToken :: KC.Config -> FilePath -> IO K8s.KubernetesClientConfig -> IO ClientEnv
mkFromToken kubeCfg dir mintConfig = do
  base <- defaultTLSClientParams
  withCAData <- addCACertData kubeCfg base
  withCAFile <- addCACertFile kubeCfg dir withCAData
  let tlsParams = tlsValidation kubeCfg withCAFile
  mgr <- newManager tlsParams
  cfg <- mintConfig
  ref <- newIORef cfg
  pure ClientEnv {httpManager = mgr, clientConfigRef = ref, renewAuth = Just mintConfig}

-- | The typed client config for one exec-plugin token: the library's own
--   master URI for the current context plus a bearer-token auth handler.
configFromToken :: KC.Config -> Text -> IO K8s.KubernetesClientConfig
configFromToken kubeCfg token = do
  let masterURI = either (const "localhost:8080") KC.server (KC.getCluster kubeCfg)
  (setMasterURI masterURI . setTokenAuth token) <$> K8s.newConfig
