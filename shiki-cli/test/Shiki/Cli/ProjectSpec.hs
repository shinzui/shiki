module Shiki.Cli.ProjectSpec (tests) where

import Control.Exception (bracket)
import Data.Map.Strict qualified as Map
import Shiki.Cli.Project
  ( EnvSelectionSource (..),
    discoverProjectConfigPath,
    resolveActiveEnvironmentName,
  )
import Shiki.Project.Config (Environment (..), ProjectConfig (..))
import System.Directory (createDirectory, getCurrentDirectory, setCurrentDirectory)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertEqual, testCase)

tests :: TestTree
tests =
  testGroup
    "Shiki.Cli.Project"
    [ testCase "discovers shiki.dhall in an ancestor directory" $
        withSystemTempDirectory "shiki-project" $ \root -> do
          let nested = root </> "a" </> "b"
          createDirectory (root </> "a")
          createDirectory nested
          writeFile (root </> "shiki.dhall") "{}"
          withCurrentDirectory' nested $ do
            found <- discoverProjectConfigPath
            assertEqual "config path" (Just (root </> "shiki.dhall")) found,
      testCase "resolves active environment by flag, env var, then default" $
        withCleanShikiEnv $ do
          flag <- resolveActiveEnvironmentName fixtureConfig (Just "prod")
          assertEqual "flag wins" ("prod", FromFlag) flag

          setEnv "SHIKI_ENV" "qa"
          fromEnv <- resolveActiveEnvironmentName fixtureConfig Nothing
          assertEqual "env var wins without flag" ("qa", FromEnvVar) fromEnv

          unsetEnv "SHIKI_ENV"
          fromDefault <- resolveActiveEnvironmentName fixtureConfig Nothing
          assertEqual "default fallback" ("staging", FromDefault) fromDefault
    ]

fixtureConfig :: ProjectConfig
fixtureConfig =
  ProjectConfig
    { environments =
        Map.fromList
          [ ("staging", Environment {databaseUrl = "postgresql://s/staging"}),
            ("prod", Environment {databaseUrl = "postgresql://s/prod"}),
            ("qa", Environment {databaseUrl = "postgresql://s/qa"})
          ],
      defaultEnvironment = "staging"
    }

withCurrentDirectory' :: FilePath -> IO a -> IO a
withCurrentDirectory' dir body =
  bracket getCurrentDirectory setCurrentDirectory $ \_ -> do
    setCurrentDirectory dir
    body

withCleanShikiEnv :: IO a -> IO a
withCleanShikiEnv body =
  bracket (lookupEnv "SHIKI_ENV") restore $ \_ -> do
    unsetEnv "SHIKI_ENV"
    body
  where
    restore = \case
      Just v -> setEnv "SHIKI_ENV" v
      Nothing -> unsetEnv "SHIKI_ENV"
