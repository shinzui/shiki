module Shiki.Analysis.BackendSpec (tests) where

import Data.Generics.Labels ()
import Data.Text qualified as Text
import Shiki.Analysis.Backend
  ( AnalyzerError (..),
    AnalyzerKind (..),
    runAnalyzer,
  )
import Shiki.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase)

tests :: TestTree
tests =
  testGroup
    "Shiki.Analysis.Backend"
    [ testCase "None returns Left AnalyzerBackendDisabled" $ do
        r <- runAnalyzer None "irrelevant"
        case r of
          Left AnalyzerBackendDisabled -> pure ()
          other -> fail ("expected AnalyzerBackendDisabled, got " <> show other),
      testCase "Baikai with an unknown model id returns AnalyzerBaikaiError" $ do
        r <- runAnalyzer (Baikai "no-such-model") "x"
        case r of
          Left (AnalyzerBaikaiError msg) ->
            assertBool
              "error mentions the offending id"
              ("no-such-model" `Text.isInfixOf` msg)
          other -> fail ("expected AnalyzerBaikaiError, got " <> show other),
      testCase "Heuristic on a Python traceback returns Right with source = \"heuristic\"" $ do
        let logs =
              Text.unlines
                [ "Traceback (most recent call last):",
                  "  File \"/app/main.py\", line 1, in <module>",
                  "    raise RuntimeError('boom')",
                  "RuntimeError: boom"
                ]
        r <- runAnalyzer Heuristic logs
        case r of
          Right res -> do
            assertEqual "source" "heuristic" (res ^. #source)
            case res ^. #summary of
              Just t ->
                assertBool
                  "summary mentions exception"
                  ("RuntimeError: boom" `Text.isInfixOf` t)
              Nothing -> fail "expected Just summary"
          Left e -> fail ("expected Right, got " <> show e)
    ]
