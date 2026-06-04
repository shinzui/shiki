-- | Pure construction of a @batch/v1@ 'V1Job' from a 'ServiceConfig'
--   plus a live 'DeploymentSnapshot' plus the per-invocation 'JobInputs'.
--   No I/O — the runner module is the only side-effectful component.
module Shiki.K8s.JobBuilder
  ( JobInputs (..),
    buildJob,
    generateJobName,
  )
where

import Shiki.K8s.Introspection (DeploymentSnapshot, EnvBinding (..), Namespace (..))
import Shiki.Prelude
import Shiki.Service.Config
  ( ContainerImageSource (..),
    EnvSource (..),
    EnvVar,
    InitContainer,
    Resources,
    ServiceConfig,
    ServiceName (..),
  )
import "base" Control.Monad (replicateM)
import "containers" Data.Map.Strict (Map)
import "containers" Data.Map.Strict qualified as Map
import "kubernetes-api" Kubernetes.OpenAPI.CustomTypes (Quantity (..))
import "kubernetes-api" Kubernetes.OpenAPI.Model qualified as K8s
import "random" System.Random qualified as Random
import "text" Data.Text qualified as Text
import "time" Data.Time.Format qualified as TimeFmt

-- | Per-invocation inputs that are not part of the static service
--   config: the cluster namespace to target, the CLI args to hand to
--   the container, and the pre-generated job name (callers generate it
--   up-front via 'generateJobName' so they can record it before the
--   API submit).
data JobInputs = JobInputs
  { namespace :: !Namespace,
    args :: ![Text],
    jobName :: !Text
  }
  deriving stock (Generic, Eq, Show)

-- | Generate @\<service\>-oneoff-YYYYMMDD-HHMMSS-XXXXXX@. The random
--   suffix substitutes for the @$$@ pid in the original shell script
--   and does not need to be cryptographically strong.
generateJobName :: ServiceName -> UTCTime -> IO Text
generateJobName (ServiceName svc) now = do
  let stamp = Text.pack (TimeFmt.formatTime TimeFmt.defaultTimeLocale "%Y%m%d-%H%M%S" now)
  suffix <- Text.pack <$> replicateM 6 (Random.randomRIO ('a', 'z'))
  pure (svc <> "-oneoff-" <> stamp <> "-" <> suffix)

-- | Turn a service config + live deployment snapshot + per-run inputs
--   into a fully-populated 'V1Job'. Mirrors the YAML structure emitted
--   by the legacy @run-oneoff-task.sh@ shell script.
buildJob :: ServiceConfig -> DeploymentSnapshot -> JobInputs -> K8s.V1Job
buildJob svc snap inputs =
  K8s.mkV1Job
    { K8s.v1JobMetadata = Just metadata,
      K8s.v1JobSpec = Just spec
    }
  where
    serviceName = unServiceName (svc ^. #name)

    metadata =
      K8s.mkV1ObjectMeta
        { K8s.v1ObjectMetaName = Just (inputs ^. #jobName),
          K8s.v1ObjectMetaNamespace = Just (unNamespace (inputs ^. #namespace))
        }

    spec =
      (K8s.mkV1JobSpec podTemplate)
        { K8s.v1JobSpecBackoffLimit = Just 0,
          K8s.v1JobSpecTtlSecondsAfterFinished = Just 3600
        }

    podTemplate =
      K8s.mkV1PodTemplateSpec
        { K8s.v1PodTemplateSpecMetadata = Just templateMetadata,
          K8s.v1PodTemplateSpecSpec = Just podSpec
        }

    templateMetadata =
      K8s.mkV1ObjectMeta
        { K8s.v1ObjectMetaLabels =
            Just (Map.singleton "app" (serviceName <> "-oneoff"))
        }

    podSpec =
      (K8s.mkV1PodSpec [mainContainer])
        { K8s.v1PodSpecRestartPolicy = Just "Never",
          K8s.v1PodSpecServiceAccount = Just (svc ^. #serviceAccount),
          K8s.v1PodSpecServiceAccountName = Just (svc ^. #serviceAccount),
          K8s.v1PodSpecNodeSelector = Just (textMapToStringMap (svc ^. #nodeSelector)),
          K8s.v1PodSpecInitContainers =
            Just (map (mkInitContainer snap) (svc ^. #initContainers))
        }

    mainContainer =
      (K8s.mkV1Container (svc ^. #containerName))
        { K8s.v1ContainerImage = Just (snap ^. #image),
          K8s.v1ContainerCommand = Just [svc ^. #commandPath],
          K8s.v1ContainerArgs = Just (inputs ^. #args),
          K8s.v1ContainerEnv = Just (map (toV1EnvVar snap) (svc ^. #env)),
          K8s.v1ContainerResources = Just (toResourceRequirements (svc ^. #resources))
        }

mkInitContainer :: DeploymentSnapshot -> InitContainer -> K8s.V1Container
mkInitContainer snap ic =
  (K8s.mkV1Container (ic ^. #name))
    { K8s.v1ContainerImage = resolveImage snap (ic ^. #image),
      K8s.v1ContainerArgs = Just (ic ^. #args),
      K8s.v1ContainerEnv = Just (map (toV1EnvVar snap) (ic ^. #env)),
      K8s.v1ContainerResources = Just (toResourceRequirements (ic ^. #resources)),
      K8s.v1ContainerRestartPolicy =
        if ic ^. #restartable then Just "Always" else Nothing
    }

resolveImage :: DeploymentSnapshot -> ContainerImageSource -> Maybe Text
resolveImage snap = \case
  StaticImage v -> Just v
  DeploymentInitImage n -> Map.lookup n (snap ^. #initImages)

toV1EnvVar :: DeploymentSnapshot -> EnvVar -> K8s.V1EnvVar
toV1EnvVar snap ev = case ev ^. #source of
  ConfigMap k ->
    (K8s.mkV1EnvVar (ev ^. #name))
      { K8s.v1EnvVarValueFrom =
          Just
            K8s.mkV1EnvVarSource
              { K8s.v1EnvVarSourceConfigMapKeyRef =
                  Just
                    (K8s.mkV1ConfigMapKeySelector k)
                      { K8s.v1ConfigMapKeySelectorName = Just (snap ^. #configMapName)
                      }
              }
      }
  Secret k ->
    (K8s.mkV1EnvVar (ev ^. #name))
      { K8s.v1EnvVarValueFrom =
          Just
            K8s.mkV1EnvVarSource
              { K8s.v1EnvVarSourceSecretKeyRef =
                  Just
                    (K8s.mkV1SecretKeySelector k)
                      { K8s.v1SecretKeySelectorName = Just (snap ^. #secretName)
                      }
              }
      }
  Literal v ->
    (K8s.mkV1EnvVar (ev ^. #name)) {K8s.v1EnvVarValue = Just v}
  DeploymentEnv n ->
    case Map.lookup n (snap ^. #envByName) of
      Just (EnvLiteral v) ->
        (K8s.mkV1EnvVar (ev ^. #name)) {K8s.v1EnvVarValue = Just v}
      Just (EnvConfigMapKeyRef cm k) ->
        (K8s.mkV1EnvVar (ev ^. #name))
          { K8s.v1EnvVarValueFrom =
              Just
                K8s.mkV1EnvVarSource
                  { K8s.v1EnvVarSourceConfigMapKeyRef =
                      Just
                        (K8s.mkV1ConfigMapKeySelector k)
                          { K8s.v1ConfigMapKeySelectorName = Just cm
                          }
                  }
          }
      Just (EnvSecretKeyRef sec k) ->
        (K8s.mkV1EnvVar (ev ^. #name))
          { K8s.v1EnvVarValueFrom =
              Just
                K8s.mkV1EnvVarSource
                  { K8s.v1EnvVarSourceSecretKeyRef =
                      Just
                        (K8s.mkV1SecretKeySelector k)
                          { K8s.v1SecretKeySelectorName = Just sec
                          }
                  }
          }
      Nothing ->
        K8s.mkV1EnvVar (ev ^. #name)

toResourceRequirements :: Resources -> K8s.V1ResourceRequirements
toResourceRequirements r =
  K8s.mkV1ResourceRequirements
    { K8s.v1ResourceRequirementsRequests =
        Just
          ( Map.fromList
              [ ("cpu", Quantity (r ^. #cpuRequest)),
                ("memory", Quantity (r ^. #memoryRequest))
              ]
          ),
      K8s.v1ResourceRequirementsLimits =
        Just
          ( Map.fromList
              [ ("cpu", Quantity (r ^. #cpuLimit)),
                ("memory", Quantity (r ^. #memoryLimit))
              ]
          )
    }

textMapToStringMap :: Map Text Text -> Map String Text
textMapToStringMap = Map.mapKeys Text.unpack
