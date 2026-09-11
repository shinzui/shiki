-- | Discover and resolve project-local configuration from @shiki.dhall@.
--   "Project-local" means the file is found by walking up from the current
--   working directory to the filesystem root and taking the first match.
module Shiki.Cli.Project
  ( -- re-exports so CLI callers need one import
    ProjectConfig (..),
    Environment (..),
    discoverProjectConfigPath,
    loadProjectConfig,
    resolveActiveEnvironmentName,
    resolveActiveEnvironment,
    EnvSelectionSource (..),
  )
where

import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
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
  ProjectConfig ->
  Maybe Text ->
  IO (Text, EnvSelectionSource)
resolveActiveEnvironmentName cfg mFlag =
  case mFlag of
    Just name | not (Text.null name) -> pure (name, FromFlag)
    _ -> do
      mEnv <- lookupEnv "SHIKI_ENV"
      pure $ case mEnv of
        Just s | not (null s) -> (Text.pack s, FromEnvVar)
        _ -> (cfg ^. #defaultEnvironment, FromDefault)

-- | Discover, load, and resolve in one step. Returns 'Nothing' when no
--   @shiki.dhall@ is discovered (callers fall back to legacy behavior).
--   When a config IS found but the resolved environment name is not one of
--   its declared environments, this calls 'error' with a clear message
--   (an explicit @--env typo@ should fail loudly, not silently fall back).
resolveActiveEnvironment :: Maybe Text -> IO (Maybe (Text, Environment))
resolveActiveEnvironment mFlag =
  discoverProjectConfigPath >>= \case
    Nothing -> pure Nothing
    Just path -> do
      cfg <- loadProjectConfig path
      (name, _src) <- resolveActiveEnvironmentName cfg mFlag
      case Map.lookup name (cfg ^. #environments) of
        Just e -> pure (Just (name, e))
        Nothing ->
          error
            ( "shiki: environment "
                <> Text.unpack name
                <> " is not declared in "
                <> path
                <> " (declared: "
                <> Text.unpack (Text.intercalate ", " (Map.keys (cfg ^. #environments)))
                <> ")"
            )
