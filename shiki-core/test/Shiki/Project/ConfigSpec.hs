module Shiki.Project.ConfigSpec (tests) where

import Control.Exception (SomeException, try)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Shiki.Project.Config (Environment (..), ProjectConfig (..))
import Shiki.Project.Config.Dhall (loadProjectConfig)
import System.Directory (canonicalizePath, createDirectory)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Shiki.Project.Config"
    [ testCase "round-trips a two-environment shiki.dhall" $
        withSystemTempDirectory "shiki-cfg" $ \dir -> do
          let path = dir <> "/shiki.dhall"
          writeFile path sample
          cfg <- loadProjectConfig path
          cfg @?= expected,
      testCase "loads context-aware environments from a relative import" $
        withSystemTempDirectory "shiki-context" $ \dir -> do
          let path = dir </> "shiki.dhall"
          writeFile (dir </> "prod.dhall") "{ databaseUrl = \"prod-db\", kubernetesContext = Some \"sennari\" }"
          writeFile path "{ environments = toMap { prod = ./prod.dhall, staging = { databaseUrl = \"local-db\", kubernetesContext = None Text } }, defaultEnvironment = \"prod\" }"
          cfg <- loadProjectConfig path
          environments cfg @?= Map.fromList [("prod", Environment "prod-db" (Just "sennari")), ("staging", Environment "local-db" Nothing)],
      testCase "rejects a present binding with the wrong type" $
        withSystemTempDirectory "shiki-invalid" $ \dir -> do
          let path = dir </> "shiki.dhall"
          writeFile path "{ environments = toMap { prod = { databaseUrl = \"db\", kubernetesContext = 3 } }, defaultEnvironment = \"prod\" }"
          try @SomeException (loadProjectConfig path) >>= \case
            Left _ -> pure ()
            Right cfg -> assertFailure ("accepted malformed binding: " <> show cfg),
      testCase "loads a service-local config through an external schema package import" $
        withSystemTempDirectory "shiki-schema-package" $ \root -> do
          let schemaDir = root </> "schema"
              serviceDir = root </> "service"
          createDirectory schemaDir
          createDirectory serviceDir
          writeFile (schemaDir </> "Environment.dhall") environmentSchema
          writeFile (schemaDir </> "ProjectConfig.dhall") projectConfigSchema
          writeFile (schemaDir </> "package.dhall") packageSchema
          packagePath <- canonicalizePath (schemaDir </> "package.dhall")
          let path = serviceDir </> "shiki.dhall"
          writeFile path (externalPackageSample packagePath)
          cfg <- loadProjectConfig path
          cfg @?= expected
    ]

sample :: String
sample =
  Text.unpack $
    Text.unlines
      [ "{ environments =",
        "    [ { mapKey = \"staging\"",
        "      , mapValue = { databaseUrl = \"postgresql://s/staging\" }",
        "      }",
        "    , { mapKey = \"prod\"",
        "      , mapValue = { databaseUrl = \"postgresql://s/prod\" }",
        "      }",
        "    ]",
        ", defaultEnvironment = \"staging\"",
        "}"
      ]

expected :: ProjectConfig
expected =
  ProjectConfig
    { environments =
        Map.fromList
          [ ("staging", Environment {databaseUrl = "postgresql://s/staging", kubernetesContext = Nothing}),
            ("prod", Environment {databaseUrl = "postgresql://s/prod", kubernetesContext = Nothing})
          ],
      defaultEnvironment = "staging"
    }

environmentSchema :: String
environmentSchema =
  Text.unpack $
    Text.unlines
      [ "{ databaseUrl : Text }"
      ]

projectConfigSchema :: String
projectConfigSchema =
  Text.unpack $
    Text.unlines
      [ "let Environment = ./Environment.dhall",
        "",
        "in  { environments : List { mapKey : Text, mapValue : Environment }",
        "    , defaultEnvironment : Text",
        "    }"
      ]

packageSchema :: String
packageSchema =
  Text.unpack $
    Text.unlines
      [ "{ Environment = ./Environment.dhall",
        ", ProjectConfig = ./ProjectConfig.dhall",
        "}"
      ]

externalPackageSample :: FilePath -> String
externalPackageSample packagePath =
  Text.unpack $
    Text.unlines
      [ "let Schema = " <> Text.pack packagePath,
        "",
        "let mkEnv = \\(url : Text) -> { databaseUrl = url } : Schema.Environment",
        "",
        "in    { environments =",
        "          toMap",
        "            { staging = mkEnv \"postgresql://s/staging\"",
        "            , prod = mkEnv \"postgresql://s/prod\"",
        "            }",
        "      , defaultEnvironment = \"staging\"",
        "      }",
        "    : Schema.ProjectConfig"
      ]
