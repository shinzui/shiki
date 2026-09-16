module Shiki.Cli.ConfigInitSpec (tests) where

import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Text.IO qualified as TIO
import Effectful (runEff)
import Effectful.Error.Static (runErrorNoCallStack)
import Shiki.Cli.ConfigInit
  ( ConfigInitOptions (..),
    renderProjectConfig,
    runConfigInit,
  )
import Shiki.Cli.Error (CliError (..))
import Shiki.Error (ConfigError (..), ShikiError (..))
import Shiki.Project.Config (Environment (..), ProjectConfig (..))
import Shiki.Project.Config.Dhall (loadProjectConfig)
import System.Directory (canonicalizePath, createDirectory)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase, (@?=))

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
          first <- runInit opts
          assertEqual "the first write succeeds" (Right (Right ())) first
          written <- TIO.readFile path
          written @?= expectedRendered

          refusal <- runInit opts
          assertEqual
            "the second write is refused as a typed error"
            (Right (Left (ConfigFileExists path)))
            refusal

          afterRefusal <- TIO.readFile path
          assertEqual "existing file unchanged" written afterRefusal,
      testCase "a directory that does not exist is a typed write failure" $
        withSystemTempDirectory "shiki-config-init-missing" $ \dir -> do
          let path = dir </> "nope" </> "shiki.dhall"
          outcome <- runInit fixtureOptions {outputPath = path}
          case outcome of
            Left (ShikiConfigError (ConfigWriteFailed failedPath _)) ->
              assertEqual "the failing path is named" path failedPath
            other -> assertBool ("expected ConfigWriteFailed, got " <> show other) False
    ]

-- | Run @config init@ through both error handlers, the way
--   'Shiki.Cli.Main.runShikiMain' does.
runInit ::
  ConfigInitOptions ->
  IO (Either ShikiError (Either CliError ()))
runInit opts =
  runEff
    . runErrorNoCallStack @ShikiError
    . runErrorNoCallStack @CliError
    $ runConfigInit opts

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
