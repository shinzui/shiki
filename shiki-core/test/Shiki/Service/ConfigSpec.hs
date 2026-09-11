module Shiki.Service.ConfigSpec (tests) where

import Shiki.Prelude
import Shiki.Service.Config (AnalyzerBackend (..), ServiceName (..))
import Shiki.Service.Config.Dhall (loadServiceConfig)
import "directory" System.Directory (doesDirectoryExist, getCurrentDirectory)
import "filepath" System.FilePath (takeDirectory, (</>))
import "tasty" Test.Tasty (TestTree, testGroup)
import "tasty-hunit" Test.Tasty.HUnit (assertEqual, testCase)

-- | Walk up from cwd until we find a directory containing @services\/@,
--   then return @\<that dir\>\/services\/\<name\>.dhall@. The test suite is
--   executed by @cabal test@ with cwd set to @shiki-core\/@, so a bare
--   @services\/...@ relative path would not resolve; this helper makes the
--   test work whether invoked from the package directory or the repo root.
serviceConfigPath :: FilePath -> IO FilePath
serviceConfigPath name = do
  start <- getCurrentDirectory
  root <- locate start
  pure (root </> "services" </> name <> ".dhall")
  where
    locate dir = do
      hit <- doesDirectoryExist (dir </> "services")
      if hit
        then pure dir
        else
          let parent = takeDirectory dir
           in if parent == dir
                then ioError (userError "no `services/` directory found above cwd")
                else locate parent

tests :: TestTree
tests =
  testGroup
    "Shiki.Service.Config"
    [ testCase "loadServiceConfig parses mls-service-v2.dhall" $ do
        path <- serviceConfigPath "mls-service-v2"
        cfg <- loadServiceConfig path
        assertEqual
          "name"
          (ServiceName "mls-service-v2")
          (cfg ^. #name)
        assertEqual
          "defaultNamespace"
          ("prod" :: Text)
          (cfg ^. #defaultNamespace),
      testCase "first init container is cloud-sql-proxy" $ do
        path <- serviceConfigPath "mls-service-v2"
        cfg <- loadServiceConfig path
        case cfg ^. #initContainers of
          (ic : _) ->
            assertEqual
              "init container name"
              ("cloud-sql-proxy" :: Text)
              (ic ^. #name)
          [] ->
            fail "expected at least one init container",
      testCase "analyzer field decodes to Heuristic" $ do
        path <- serviceConfigPath "mls-service-v2"
        cfg <- loadServiceConfig path
        assertEqual "analyzer" Heuristic (cfg ^. #analyzer)
    ]
