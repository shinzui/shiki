-- | Read the live Deployment that a service's Job should mirror, and
--   extract the dynamic values (image tag, ConfigMap name, Secret name)
--   that the static @ServiceConfig@ does not know.
module Shiki.K8s.Introspection
  ( DeploymentSnapshot (..),
    EnvBinding (..),
    DeploymentName (..),
    Namespace (..),
    InspectionError (..),
    inspectDeployment,
  )
where

import Control.Exception (Exception, throwIO)
import Data.List qualified as List
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Kubernetes.OpenAPI qualified as K8s
import Kubernetes.OpenAPI.API.AppsV1 qualified as AppsV1
import Kubernetes.OpenAPI.ModelLens qualified as K8sLens
import Shiki.K8s.Client (ClientEnv (..))
import Shiki.Prelude hiding (Strict)

-- | A Kubernetes namespace, wrapped so it can't be confused with a
--   deployment name or container name in argument lists.
newtype Namespace = Namespace {unNamespace :: Text}
  deriving stock (Generic, Eq, Show)
  deriving newtype (FromJSON, ToJSON)

-- | The name of a @Deployment@ resource.
newtype DeploymentName = DeploymentName {unDeploymentName :: Text}
  deriving stock (Generic, Eq, Show)
  deriving newtype (FromJSON, ToJSON)

-- | The dynamic values lifted off a live Deployment that the runner
--   needs to fill in a one-off Job: the same container image the worker
--   is running, plus the first ConfigMap and Secret env-var sources
--   (which are the two bindings the operator wants the Job to share).
data DeploymentSnapshot = DeploymentSnapshot
  { image :: !Text,
    configMapName :: !Text,
    secretName :: !Text,
    envByName :: !(Map Text EnvBinding),
    initImages :: !(Map Text Text)
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data EnvBinding
  = EnvLiteral !Text
  | EnvConfigMapKeyRef !Text !Text
  | EnvSecretKeyRef !Text !Text
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
inspectDeployment ::
  ClientEnv ->
  Namespace ->
  DeploymentName ->
  -- | container name in the deployment
  Text ->
  IO DeploymentSnapshot
inspectDeployment env ns dep containerName = do
  let req =
        AppsV1.readNamespacedDeployment
          (K8s.Accept K8s.MimeJSON)
          (K8s.Name (unDeploymentName dep))
          (K8s.Namespace (unNamespace ns))
  resp <- K8s.dispatchMime (env ^. #httpManager) (env ^. #clientConfig) req
  deployment <- case K8s.mimeResult resp of
    Left err -> throwIO (DeploymentReadFailed ns dep (show err))
    Right d -> pure d

  spec <- case deployment ^. K8sLens.v1DeploymentSpecL of
    Nothing -> throwIO (DeploymentMissingSpec ns dep)
    Just s -> pure s

  podSpec <- case spec ^. K8sLens.v1DeploymentSpecTemplateL . K8sLens.v1PodTemplateSpecSpecL of
    Nothing -> throwIO (DeploymentMissingPodSpec ns dep)
    Just ps -> pure ps

  let containers = podSpec ^. K8sLens.v1PodSpecContainersL
  container <-
    case List.find (\c -> c ^. K8sLens.v1ContainerNameL == containerName) containers of
      Nothing -> throwIO (ContainerNotFound containerName)
      Just c -> pure c

  image <- case container ^. K8sLens.v1ContainerImageL of
    Nothing -> throwIO (ContainerMissingImage containerName)
    Just i -> pure i

  let envs = fromMaybe [] (container ^. K8sLens.v1ContainerEnvL)
      initContainers = fromMaybe [] (podSpec ^. K8sLens.v1PodSpecInitContainersL)
      configMapNames =
        [ cm
        | e <- envs,
          Just src <- [e ^. K8sLens.v1EnvVarValueFromL],
          Just ref <- [src ^. K8sLens.v1EnvVarSourceConfigMapKeyRefL],
          Just cm <- [ref ^. K8sLens.v1ConfigMapKeySelectorNameL]
        ]
      secretNames =
        [ s
        | e <- envs,
          Just src <- [e ^. K8sLens.v1EnvVarValueFromL],
          Just ref <- [src ^. K8sLens.v1EnvVarSourceSecretKeyRefL],
          Just s <- [ref ^. K8sLens.v1SecretKeySelectorNameL]
        ]
      initImages =
        Map.fromList
          [ (ic ^. K8sLens.v1ContainerNameL, image')
          | ic <- initContainers,
            Just image' <- [ic ^. K8sLens.v1ContainerImageL]
          ]

  cm <- case configMapNames of
    (n : _) -> pure n
    [] -> throwIO (NoConfigMapBinding containerName)
  sec <- case secretNames of
    (n : _) -> pure n
    [] -> throwIO (NoSecretBinding containerName)

  pure
    DeploymentSnapshot
      { image = image,
        configMapName = cm,
        secretName = sec,
        envByName = Map.fromList (mapMaybe envBinding envs),
        initImages = initImages
      }

envBinding :: K8s.V1EnvVar -> Maybe (Text, EnvBinding)
envBinding env = do
  binding <- case env ^. K8sLens.v1EnvVarValueL of
    Just v -> Just (EnvLiteral v)
    Nothing -> case env ^. K8sLens.v1EnvVarValueFromL of
      Just src
        | Just ref <- src ^. K8sLens.v1EnvVarSourceConfigMapKeyRefL,
          Just refName <- ref ^. K8sLens.v1ConfigMapKeySelectorNameL ->
            Just (EnvConfigMapKeyRef refName (ref ^. K8sLens.v1ConfigMapKeySelectorKeyL))
        | Just ref <- src ^. K8sLens.v1EnvVarSourceSecretKeyRefL,
          Just refName <- ref ^. K8sLens.v1SecretKeySelectorNameL ->
            Just (EnvSecretKeyRef refName (ref ^. K8sLens.v1SecretKeySelectorKeyL))
      _ -> Nothing
  pure (env ^. K8sLens.v1EnvVarNameL, binding)
