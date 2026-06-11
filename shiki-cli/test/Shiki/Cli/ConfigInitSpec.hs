module Shiki.Cli.ConfigInitSpec (tests) where

import Shiki.Cli.ConfigInit
  ( ConfigInitOptions (..),
    renderProjectConfig,
    runConfigInit,
  )
import Shiki.Project.Config (Environment (..), ProjectConfig (..))
import Shiki.Project.Config.Dhall (loadProjectConfig)
import "base" Control.Exception (try)
import "base" System.Exit (ExitCode (..))
import "containers" Data.Map.Strict qualified as Map
import "directory" System.Directory (canonicalizePath, createDirectory)
import "filepath" System.FilePath ((</>))
import "tasty" Test.Tasty (TestTree, testGroup)
import "tasty-hunit" Test.Tasty.HUnit (assertBool, assertEqual, testCase, (@?=))
import "temporary" System.IO.Temp (withSystemTempDirectory)
import "text" Data.Text qualified as Text
import "text" Data.Text.IO qualified as TIO

tests :: TestTree
tests =
  testGroup
    "Shiki.Cli.ConfigInit"
    [ testCase "renders a GitHub raw schema package import" $
        renderProjectConfig fixtureOptions @?= expectedRendered,
      testCase "generated config type-checks from a separate service directory" $
        withSystemTempDirectory "shiki-config-init-load" $ \root -> do
          let schemaDir = root </> "schema"
              serviceDir = root </> "service"
          createDirectory schemaDir
          createDirectory serviceDir
          writeFile (schemaDir </> "Environment.dhall") environmentSchema
          writeFile (schemaDir </> "ProjectConfig.dhall") projectConfigSchema
          writeFile (schemaDir </> "package.dhall") packageSchema
          packagePath <- canonicalizePath (schemaDir </> "package.dhall")
          let renderedWithLocalSchema =
                Text.replace
                  "https://raw.githubusercontent.com/shinzui/shiki/test-ref/schema/package.dhall"
                  (Text.pack packagePath)
                  expectedRendered
              configPath = serviceDir </> "shiki.dhall"
          TIO.writeFile configPath renderedWithLocalSchema
          cfg <- loadProjectConfig configPath
          cfg @?= expectedConfig,
      testCase "writes shiki.dhall without overwriting an existing file" $
        withSystemTempDirectory "shiki-config-init" $ \dir -> do
          let path = dir </> "shiki.dhall"
              opts = fixtureOptions {outputPath = path}
          runConfigInit opts
          written <- TIO.readFile path
          written @?= expectedRendered

          result <- try (runConfigInit opts)
          case result of
            Left ExitFailure {} -> pure ()
            Left ExitSuccess -> assertBool "expected overwrite refusal to fail" False
            Right () -> assertBool "expected overwrite refusal to fail" False

          afterRefusal <- TIO.readFile path
          assertEqual "existing file unchanged" written afterRefusal
    ]

fixtureOptions :: ConfigInitOptions
fixtureOptions =
  ConfigInitOptions
    { schemaRef = "test-ref",
      outputPath = "shiki.dhall",
      defaultEnvironment = "staging"
    }

expectedRendered :: Text.Text
expectedRendered =
  Text.unlines
    [ "{- Project-local shiki configuration.",
      "",
      "   Replace the placeholder database URLs below with the databases for",
      "   this service repository. The schema import points at the public shiki",
      "   package so this file can live outside the shiki source checkout.",
      "-}",
      "let Schema =",
      "      https://raw.githubusercontent.com/shinzui/shiki/test-ref/schema/package.dhall",
      "",
      "let mkEnv = \\(url : Text) -> { databaseUrl = url } : Schema.Environment",
      "",
      "in    { environments =",
      "          toMap",
      "            { staging = mkEnv \"postgresql://replace-me/staging\"",
      "            , prod = mkEnv \"postgresql://replace-me/prod\"",
      "            }",
      "      , defaultEnvironment = \"staging\"",
      "      }",
      "    : Schema.ProjectConfig"
    ]

expectedConfig :: ProjectConfig
expectedConfig =
  ProjectConfig
    { environments =
        Map.fromList
          [ ("staging", Environment {databaseUrl = "postgresql://replace-me/staging"}),
            ("prod", Environment {databaseUrl = "postgresql://replace-me/prod"})
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
