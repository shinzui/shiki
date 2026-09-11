{-# OPTIONS_GHC -Wno-partial-fields #-}

-- | Declarative description of a microservice and the Kubernetes Job shape
--   that should be produced when running a one-off command against it. The
--   loader in "Shiki.Service.Config.Dhall" reads one file per service from
--   @services\/\<name\>.dhall@; the Kubernetes job runner consumes the
--   resulting 'ServiceConfig' and combines it with a live Deployment
--   snapshot to produce a @V1Job@.
module Shiki.Service.Config
  ( ServiceName (..),
    ServiceConfig (..),
    InitContainer (..),
    ContainerImageSource (..),
    EnvVar (..),
    EnvSource (..),
    Resources (..),
    AnalyzerBackend (..),
  )
where

import Data.Map.Strict (Map)
import Shiki.Prelude

-- | The canonical short name of a microservice (e.g. @"mls-service-v2"@).
--   Wrapped in a newtype so it cannot be confused with a Kubernetes
--   namespace, container name, or any other free-form 'Text' identifier
--   that appears alongside it.
newtype ServiceName = ServiceName {unServiceName :: Text}
  deriving stock (Generic, Eq, Ord, Show)
  deriving newtype (FromJSON, ToJSON)

-- | Everything @shiki@ needs to know about a service in order to construct
--   an equivalent one-off Kubernetes Job. Dynamic values (image digest,
--   ConfigMap name, Secret name, etc.) are not modelled here; they are
--   read from the live Deployment at run time.
data ServiceConfig = ServiceConfig
  { name :: !ServiceName,
    defaultNamespace :: !Text,
    detectFromDeployment :: !Text,
    containerName :: !Text,
    commandPath :: !Text,
    serviceAccount :: !Text,
    nodeSelector :: !(Map Text Text),
    initContainers :: ![InitContainer],
    env :: ![EnvVar],
    resources :: !Resources,
    analyzer :: !AnalyzerBackend
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

-- | Which analyzer backend should be used for runs of this service. The
--   constructors mirror "Shiki.Analysis.Backend.AnalyzerKind" verbatim so
--   the Dhall union (see @shiki-core\/dhall\/AnalyzerBackend.dhall@) can
--   line up generically, and so the two types convert with a single
--   value-level rename. The duplication is deliberate: keeping the
--   analyzer module out of "Shiki.Service.Config" preserves the
--   one-way dependency arrow @Analysis -> Service@.
data AnalyzerBackend
  = Heuristic
  | Baikai {model :: !Text}
  | None
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

-- | A single init container to attach to the Job pod. The canonical
--   example is @cloud-sql-proxy@.
data InitContainer = InitContainer
  { name :: !Text,
    image :: !ContainerImageSource,
    args :: ![Text],
    env :: ![EnvVar],
    resources :: !Resources,
    restartable :: !Bool
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

-- | Where an init container image comes from.
data ContainerImageSource
  = StaticImage {value :: !Text}
  | DeploymentInitImage {name :: !Text}
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

-- | A single environment variable binding: a name plus the source it
--   should be filled from.
data EnvVar = EnvVar
  { name :: !Text,
    source :: !EnvSource
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

-- | Where the value of an 'EnvVar' comes from.
data EnvSource
  = ConfigMap {key :: !Text}
  | Secret {key :: !Text}
  | Literal {value :: !Text}
  | DeploymentEnv {name :: !Text}
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

-- | Resource requests and limits attached to a container.
data Resources = Resources
  { cpuRequest :: !Text,
    cpuLimit :: !Text,
    memoryRequest :: !Text,
    memoryLimit :: !Text
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)
