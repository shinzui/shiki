-- | Read the live Deployment that a service's Job should mirror, and
--   extract the dynamic values (image tag, ConfigMap name, Secret name)
--   that the static @ServiceConfig@ does not know.
module Shiki.K8s.Introspection
  ( DeploymentSnapshot (..)
  , DeploymentName (..)
  , Namespace (..)
  , InspectionError (..)
  , inspectDeployment
  ) where

import Shiki.Prelude hiding (Strict)

import Shiki.K8s.Client (ClientEnv (..))

import "base" Control.Exception (Exception, throwIO)
import "base" Data.List qualified as List
import "kubernetes-api" Kubernetes.OpenAPI qualified as K8s
import "kubernetes-api" Kubernetes.OpenAPI.API.AppsV1 qualified as AppsV1
import "kubernetes-api" Kubernetes.OpenAPI.ModelLens qualified as K8sLens

-- | A Kubernetes namespace, wrapped so it can't be confused with a
--   deployment name or container name in argument lists.
newtype Namespace = Namespace { unNamespace :: Text }
  deriving stock (Generic, Eq, Show)
  deriving newtype (FromJSON, ToJSON)

-- | The name of a @Deployment@ resource.
newtype DeploymentName = DeploymentName { unDeploymentName :: Text }
  deriving stock (Generic, Eq, Show)
  deriving newtype (FromJSON, ToJSON)

-- | The dynamic values lifted off a live Deployment that the runner
--   needs to fill in a one-off Job: the same container image the worker
--   is running, plus the first ConfigMap and Secret env-var sources
--   (which are the two bindings the operator wants the Job to share).
data DeploymentSnapshot = DeploymentSnapshot
  { image         :: !Text
  , configMapName :: !Text
  , secretName    :: !Text
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data InspectionError
  = DeploymentReadFailed !Namespace !DeploymentName !String
  | DeploymentMissingSpec !Namespace !DeploymentName
  | DeploymentMissingPodSpec !Namespace !DeploymentName
  | ContainerNotFound !Text
  | ContainerMissingImage !Text
  | NoConfigMapBinding !Text
  | NoSecretBinding !Text
  deriving stock (Generic, Eq, Show)
  deriving anyclass (Exception)

-- | Fetch the named Deployment, walk its pod template down to the named
--   container, and return a 'DeploymentSnapshot'. Throws
--   'InspectionError' on any missing piece.
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
    Left err -> throwIO (DeploymentReadFailed ns dep (show err))
    Right d  -> pure d

  spec <- case deployment ^. K8sLens.v1DeploymentSpecL of
    Nothing -> throwIO (DeploymentMissingSpec ns dep)
    Just s  -> pure s

  podSpec <- case spec ^. K8sLens.v1DeploymentSpecTemplateL . K8sLens.v1PodTemplateSpecSpecL of
    Nothing -> throwIO (DeploymentMissingPodSpec ns dep)
    Just ps -> pure ps

  let containers = podSpec ^. K8sLens.v1PodSpecContainersL
  container <-
    case List.find (\c -> c ^. K8sLens.v1ContainerNameL == containerName) containers of
      Nothing -> throwIO (ContainerNotFound containerName)
      Just c  -> pure c

  image <- case container ^. K8sLens.v1ContainerImageL of
    Nothing -> throwIO (ContainerMissingImage containerName)
    Just i  -> pure i

  let envs = fromMaybe [] (container ^. K8sLens.v1ContainerEnvL)
      configMapNames =
        [ cm
        | e <- envs
        , Just src <- [e ^. K8sLens.v1EnvVarValueFromL]
        , Just ref <- [src ^. K8sLens.v1EnvVarSourceConfigMapKeyRefL]
        , Just cm  <- [ref ^. K8sLens.v1ConfigMapKeySelectorNameL]
        ]
      secretNames =
        [ s
        | e <- envs
        , Just src <- [e ^. K8sLens.v1EnvVarValueFromL]
        , Just ref <- [src ^. K8sLens.v1EnvVarSourceSecretKeyRefL]
        , Just s   <- [ref ^. K8sLens.v1SecretKeySelectorNameL]
        ]

  cm <- case configMapNames of
    (n : _) -> pure n
    []      -> throwIO (NoConfigMapBinding containerName)
  sec <- case secretNames of
    (n : _) -> pure n
    []      -> throwIO (NoSecretBinding containerName)

  pure DeploymentSnapshot
    { image         = image
    , configMapName = cm
    , secretName    = sec
    }
