-- | Loads the operator's kubeconfig and produces the @(Manager, Config)@
--   bundle that every other @Shiki.K8s.*@ module needs to talk to the
--   cluster. Centralised so callers do not have to know which kubeconfig
--   path or which auth handler is in play.
module Shiki.K8s.Client
  ( ClientEnv (..),
    KubeConfigSource (..),
    loadDefaultClientConfig,
    loadClientConfig,
  )
where

import Control.Concurrent.STM (atomically, newTVar)
import Control.Exception (try)
import Data.Generics.Labels ()
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
import Network.HTTP.Client (Manager)
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
data ClientEnv = ClientEnv
  { httpManager :: !Manager,
    clientConfig :: !K8s.KubernetesClientConfig
  }
  deriving stock (Generic)

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
        token <- runExecCredential execAuth (rc ^. #cluster)
        kubeCfg <- Yaml.decodeFileThrow path
        mkFromToken kubeCfg (takeDirectory path) token
loadClientConfig src@KubeConfigCluster = mkFromLibrary src

-- | The original behavior: decode the kubeconfig and install whichever auth
--   handler the library recognizes (token, client cert, GCP, OIDC), using a
--   fresh OIDC cache.
mkFromLibrary :: KubeConfigSource -> IO ClientEnv
mkFromLibrary src = do
  oidcCache <- atomically (newTVar Map.empty)
  (mgr, cfg) <- mkKubeClientConfig oidcCache src
  pure ClientEnv {httpManager = mgr, clientConfig = cfg}

-- | Build the client exactly as the library's own @mkKubeClientConfig@ does
--   for the current context — same master URI and same TLS CA selection — but
--   install a bearer-token auth handler from the exec-plugin token instead of
--   running @applyAuthSettings@ (which has no exec handler). @kubeCfg@ is the
--   library's @Config@; @dir@ is the kubeconfig's directory, against which a
--   relative @certificate-authority@ file is resolved by 'addCACertFile'.
mkFromToken :: KC.Config -> FilePath -> Text -> IO ClientEnv
mkFromToken kubeCfg dir token = do
  let masterURI = either (const "localhost:8080") KC.server (KC.getCluster kubeCfg)
  base <- defaultTLSClientParams
  withCAData <- addCACertData kubeCfg base
  withCAFile <- addCACertFile kubeCfg dir withCAData
  let tlsParams = tlsValidation kubeCfg withCAFile
  mgr <- newManager tlsParams
  cfg <- (setMasterURI masterURI . setTokenAuth token) <$> K8s.newConfig
  pure ClientEnv {httpManager = mgr, clientConfig = cfg}
