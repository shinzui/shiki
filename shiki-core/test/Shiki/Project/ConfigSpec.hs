module Shiki.Project.ConfigSpec (tests) where

import Shiki.Project.Config (Environment (..), ProjectConfig (..))
import Shiki.Project.Config.Dhall (loadProjectConfig)
import "containers" Data.Map.Strict qualified as Map
import "directory" System.Directory (canonicalizePath, createDirectory)
import "filepath" System.FilePath ((</>))
import "tasty" Test.Tasty (TestTree, testGroup)
import "tasty-hunit" Test.Tasty.HUnit (testCase, (@?=))
import "temporary" System.IO.Temp (withSystemTempDirectory)
import "text" Data.Text qualified as Text

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
          [ ("staging", Environment {databaseUrl = "postgresql://s/staging"}),
            ("prod", Environment {databaseUrl = "postgresql://s/prod"})
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
