module Shiki.Service.ConfigSpec (tests) where

import Data.Generics.Labels ()
import Data.Text qualified as Text
import Data.Text.IO qualified as TIO
import Shiki.Prelude
import Shiki.Service.Config
  ( AnalyzerBackend (..),
    ServiceName (..),
    defaultTtlSecondsAfterFinished,
    effectiveTtlSecondsAfterFinished,
  )
import Shiki.Service.Config.Dhall (loadServiceConfig)
import System.Directory (doesDirectoryExist, getCurrentDirectory)
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertEqual, testCase)

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
    [ testCase "a service file without ttlSecondsAfterFinished gets the 7-day default" $ do
        path <- serviceConfigPath "mls-service-v2"
        cfg <- loadServiceConfig path
        assertEqual "field" Nothing (cfg ^. #ttlSecondsAfterFinished)
        assertEqual "effective" (7 * 24 * 60 * 60) (effectiveTtlSecondsAfterFinished cfg)
        assertEqual "default" defaultTtlSecondsAfterFinished (effectiveTtlSecondsAfterFinished cfg),
      testCase "a service file that sets ttlSecondsAfterFinished keeps its value" $ do
        base <- serviceConfigPath "mls-service-v2"
        withSystemTempDirectory "shiki-ttl" $ \dir -> do
          let path = dir </> "mls-service-v2.dhall"
          TIO.writeFile
            path
            ("(" <> Text.pack base <> ") // { ttlSecondsAfterFinished = Some 86400 }")
          cfg <- loadServiceConfig path
          assertEqual "field" (Just 86400) (cfg ^. #ttlSecondsAfterFinished)
          assertEqual "effective" 86400 (effectiveTtlSecondsAfterFinished cfg),
      testCase "loadServiceConfig parses mls-service-v2.dhall" $ do
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
