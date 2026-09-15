-- | Discover and resolve project-local configuration from @shiki.dhall@.
--   "Project-local" means the file is found by walking up from the current
--   working directory to the filesystem root and taking the first match.
module Shiki.Cli.Project
  ( -- re-exports so CLI callers need one import
    ProjectConfig (..),
    Environment (..),
    discoverProjectConfigPath,
    loadProjectConfig,
    loadProjectConfigChecked,
    resolveActiveEnvironmentName,
    resolveActiveEnvironment,
    EnvSelectionSource (..),
  )
where

import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Effectful (Eff, IOE, type (:>))
import Effectful.Error.Static (Error, throwError)
import Effectful.Exception qualified as Exc
import Shiki.Error (ConfigError (..), ShikiError (..))
import Shiki.Prelude
import Shiki.Project.Config (Environment (..), ProjectConfig (..))
import Shiki.Project.Config.Dhall (loadProjectConfig)
import System.Directory (doesFileExist, getCurrentDirectory)
import System.Environment (lookupEnv)
import System.FilePath (takeDirectory, (</>))

-- | Where the active environment name came from. Used by @config show@ to
--   tell the operator why a particular environment is active.
data EnvSelectionSource
  = FromFlag
  | FromEnvVar
  | FromDefault
  deriving stock (Generic, Eq, Show)

-- | Walk up from the current working directory looking for a file named
--   @shiki.dhall@. Returns its absolute path on the first match, or
--   'Nothing' if the filesystem root is reached without finding one.
discoverProjectConfigPath :: IO (Maybe FilePath)
discoverProjectConfigPath = getCurrentDirectory >>= go
  where
    go dir = do
      let candidate = dir </> "shiki.dhall"
      found <- doesFileExist candidate
      if found
        then pure (Just candidate)
        else
          let parent = takeDirectory dir
           in if parent == dir
                then pure Nothing
                else go parent

-- | Resolve the active environment NAME and where it came from, given the
--   loaded config and the optional @--env@ flag value. Precedence:
--   @--env@ flag, then @SHIKI_ENV@ env var, then @defaultEnvironment@.
resolveActiveEnvironmentName ::
  (IOE :> es) =>
  ProjectConfig ->
  Maybe Text ->
  Eff es (Text, EnvSelectionSource)
resolveActiveEnvironmentName cfg mFlag =
  case mFlag of
    Just name | not (Text.null name) -> pure (name, FromFlag)
    _ -> do
      mEnv <- liftIO (lookupEnv "SHIKI_ENV")
      pure $ case mEnv of
        Just s | not (null s) -> (Text.pack s, FromEnvVar)
        _ -> (cfg ^. #defaultEnvironment, FromDefault)

-- | 'loadProjectConfig' with Dhall's exceptions turned into a typed
--   'ProjectConfigInvalid'. Dhall reports a syntax error, a failed import, and
--   a type mismatch by throwing; catching them here is what turns
--   @shiki runs list@ against a broken @shiki.dhall@ into one
--   @shiki: cannot load \<path\>: \<message\>@ line instead of a banner.
loadProjectConfigChecked ::
  (IOE :> es, Error ShikiError :> es) =>
  FilePath ->
  Eff es ProjectConfig
loadProjectConfigChecked path =
  Exc.trySync (liftIO (loadProjectConfig path)) >>= \case
    Right cfg -> pure cfg
    Left e ->
      throwError
        ( ShikiConfigError
            (ProjectConfigInvalid path (Text.strip (Text.pack (Exc.displayException e))))
        )

-- | Discover, load, and resolve in one step. Returns 'Nothing' when no
--   @shiki.dhall@ is discovered (callers fall back to legacy behavior).
--   When a config IS found but the resolved environment name is not one of
--   its declared environments, this throws 'UndeclaredEnvironment' (an
--   explicit @--env typo@ should fail loudly, not silently fall back).
resolveActiveEnvironment ::
  (IOE :> es, Error ShikiError :> es) =>
  Maybe Text ->
  Eff es (Maybe (Text, Environment))
resolveActiveEnvironment mFlag =
  liftIO discoverProjectConfigPath >>= \case
    Nothing -> pure Nothing
    Just path -> do
      cfg <- loadProjectConfigChecked path
      (name, _src) <- resolveActiveEnvironmentName cfg mFlag
      case Map.lookup name (cfg ^. #environments) of
        Just e -> pure (Just (name, e))
        Nothing ->
          throwError
            ( ShikiConfigError
                ( UndeclaredEnvironment
                    name
                    path
                    (Map.keys (cfg ^. #environments))
                )
            )
