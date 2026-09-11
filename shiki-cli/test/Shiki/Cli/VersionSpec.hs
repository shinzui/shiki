module Shiki.Cli.VersionSpec
  ( tests,
  )
where

import Data.List (isInfixOf)
import Options.Applicative qualified as Opt
import Shiki.Cli (parserInfo)
import Shiki.Cli.Version (formatVersionWithGit)
import System.Exit (ExitCode (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase)

tests :: TestTree
tests =
  testGroup
    "Shiki.Cli.Version"
    [ testCase "formatVersionWithGit omits missing commit" $
        assertEqual "" "shiki v0.1.0.0" (formatVersionWithGit "0.1.0.0" Nothing),
      testCase "formatVersionWithGit includes provided commit" $
        assertEqual "" "shiki v0.1.0.0 (a1b2c3d)" (formatVersionWithGit "0.1.0.0" (Just "a1b2c3d")),
      testCase "formatVersionWithGit omits empty commit" $
        assertEqual "" "shiki v0.1.0.0" (formatVersionWithGit "0.1.0.0" (Just "")),
      testCase "parser renders top-level version as informational success" $
        case Opt.execParserPure Opt.defaultPrefs parserInfo ["--version"] of
          Opt.Failure failure -> do
            let (rendered, exitCode) = Opt.renderFailure failure "shiki"
            assertEqual "version exits successfully" ExitSuccess exitCode
            assertBool
              ("expected rendered version to contain program version, got: " <> rendered)
              ("shiki v0.1.0.0" `isInfixOf` rendered)
          other ->
            assertBool ("expected informational parser failure, got: " <> show other) False
    ]
