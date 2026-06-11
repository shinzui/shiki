module Shiki.Project.ConfigSpec (tests) where

import Shiki.Project.Config (Environment (..), ProjectConfig (..))
import Shiki.Project.Config.Dhall (loadProjectConfig)
import "containers" Data.Map.Strict qualified as Map
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
