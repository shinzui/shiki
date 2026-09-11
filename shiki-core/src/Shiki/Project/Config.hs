-- | Project-local configuration loaded from a @shiki.dhall@ file at (or
--   above) the working directory. Models a set of named "environments"
--   (e.g. @staging@, @prod@), each carrying its own PostgreSQL connection
--   string, plus which environment is the default. The Dhall type
--   definitions live in @schema\/ProjectConfig.dhall@ and
--   @schema\/Environment.dhall@; the loader lives in
--   "Shiki.Project.Config.Dhall".
module Shiki.Project.Config
  ( EnvironmentName (..),
    Environment (..),
    ProjectConfig (..),
  )
where

import Data.Map.Strict (Map)
import Shiki.Prelude

-- | The name of a shiki environment (e.g. @"staging"@). Wrapped so it
--   cannot be confused with a Kubernetes namespace or any other free-form
--   identifier.
newtype EnvironmentName = EnvironmentName {unEnvironmentName :: Text}
  deriving stock (Generic, Eq, Ord, Show)
  deriving newtype (FromJSON, ToJSON)

-- | The settings that vary per environment. Currently just a libpq-style
--   PostgreSQL connection string. Add fields here as future features need
--   them, and mirror the addition in @schema\/Environment.dhall@.
data Environment = Environment
  { databaseUrl :: !Text
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

-- | The whole parsed @shiki.dhall@ file. @environments@ is keyed by
--   environment name; @defaultEnvironment@ names the one used when neither
--   @--env@ nor @SHIKI_ENV@ is given.
data ProjectConfig = ProjectConfig
  { environments :: !(Map Text Environment),
    defaultEnvironment :: !Text
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)
