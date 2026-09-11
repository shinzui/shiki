module Shiki.Analysis.HeuristicSpec (tests) where

import Data.Text qualified as Text
import Shiki.Analysis.Heuristic (summarizeFailure)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase)

tests :: TestTree
tests =
  testGroup
    "Shiki.Analysis.Heuristic"
    [ testCase "recognises a Python traceback's final exception line" $ do
        let logs =
              Text.unlines
                [ "preamble line",
                  "Traceback (most recent call last):",
                  "  File \"/app/main.py\", line 42, in <module>",
                  "    raise RuntimeError('boom')",
                  "RuntimeError: boom",
                  "",
                  "trailing chatter"
                ]
        assertEqual
          "summary"
          (Just "RuntimeError: boom")
          (summarizeFailure logs),
      testCase "recognises a JVM Exception in thread / Caused by chain" $ do
        let logs =
              Text.unlines
                [ "Exception in thread \"main\" java.lang.RuntimeException: top",
                  "\tat com.example.A.foo(A.java:10)",
                  "Caused by: java.io.IOException: disk on fire",
                  "\tat com.example.A.bar(A.java:20)"
                ]
        assertEqual
          "summary"
          (Just "Exception in thread \"main\" java.lang.RuntimeException: top / Caused by: java.io.IOException: disk on fire")
          (summarizeFailure logs),
      testCase "recognises a Go panic header" $ do
        let logs =
              Text.unlines
                [ "2026/05/27 12:00:00 starting",
                  "goroutine 1 [running]:",
                  "panic: runtime error: invalid memory address",
                  "  /app/main.go:12 +0x1a"
                ]
        case summarizeFailure logs of
          Just t -> do
            assertBool
              "contains goroutine context"
              ("goroutine 1 [running]:" `Text.isInfixOf` t)
            assertBool
              "contains panic header"
              ("panic: runtime error:" `Text.isInfixOf` t)
          Nothing -> fail "expected summary, got Nothing",
      testCase "recognises a Rust 'thread X panicked at' line" $ do
        let logs =
              Text.unlines
                [ "starting up...",
                  "thread 'main' panicked at src/main.rs:7:5:",
                  "assertion failed: false"
                ]
        assertEqual
          "summary"
          (Just "thread 'main' panicked at src/main.rs:7:5:")
          (summarizeFailure logs),
      testCase "recognises a line-prefixed ERROR" $ do
        let logs =
              Text.unlines
                [ "INFO  starting up",
                  "DEBUG  loaded config",
                  "ERROR  could not connect to upstream",
                  "  retrying..."
                ]
        case summarizeFailure logs of
          Just t ->
            assertBool
              "contains ERROR line"
              ("ERROR" `Text.isInfixOf` t && "could not connect" `Text.isInfixOf` t)
          Nothing -> fail "expected summary",
      testCase "falls back to the last non-blank line when nothing matches" $ do
        let logs = "step 1\nstep 2\nstep 3\n"
        assertEqual
          "summary"
          (Just "step 3")
          (summarizeFailure logs),
      testCase "returns Nothing on empty input" $ do
        assertEqual "empty" Nothing (summarizeFailure "")
        assertEqual "whitespace" Nothing (summarizeFailure "   \n\t\n  \n"),
      testCase "truncates summaries longer than 512 characters" $ do
        let long = Text.replicate 1000 "x"
        case summarizeFailure long of
          Just t -> assertEqual "length cap" 512 (Text.length t)
          Nothing -> fail "expected Just"
    ]
