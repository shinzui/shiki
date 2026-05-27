-- | Loads the operator's kubeconfig and produces the @(Manager, Config)@
--   bundle that every other @Shiki.K8s.*@ module needs to talk to the
--   cluster. Centralised so callers do not have to know which kubeconfig
--   path or which auth handler is in play.
module Shiki.K8s.Client
  ( ClientEnv (..)
  , KubeConfigSource (..)
  , loadDefaultClientConfig
  , loadClientConfig
  ) where

import Shiki.Prelude

import "kubernetes-api" Kubernetes.OpenAPI qualified as K8s
import "kubernetes-api-client" Kubernetes.Client.Config
  ( KubeConfigSource (..)
  , mkKubeClientConfig
  )
import "stm" Control.Concurrent.STM (atomically, newTVar)
import "containers" Data.Map.Strict qualified as Map
import "base" System.Environment (lookupEnv)
import "filepath" System.FilePath ((</>))
import "directory" System.Directory (getHomeDirectory)
import "http-client" Network.HTTP.Client (Manager)

-- | A bundle of the HTTP connection 'Manager' and the typed
--   'K8s.KubernetesClientConfig' that every API call needs. Built once
--   per CLI invocation by 'loadDefaultClientConfig'.
data ClientEnv = ClientEnv
  { httpManager  :: !Manager
  , clientConfig :: !K8s.KubernetesClientConfig
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
    Just p  -> pure p
    Nothing -> do
      home <- getHomeDirectory
      pure (home </> ".kube" </> "config")
  loadClientConfig (KubeConfigFile path)

-- | Lower-level variant that takes an explicit 'KubeConfigSource'
--   (file path or @KubeConfigCluster@ for in-cluster service-account auth).
loadClientConfig :: KubeConfigSource -> IO ClientEnv
loadClientConfig src = do
  oidcCache <- atomically (newTVar Map.empty)
  (mgr, cfg) <- mkKubeClientConfig oidcCache src
  pure ClientEnv { httpManager = mgr, clientConfig = cfg }
