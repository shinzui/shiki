module Shiki.Cli.Agent.LaunchSpec
  ( tests,
  )
where

import Shiki.Cli.Agent.Launch (AssistDispatch (..), runAssistSession)
import Shiki.Cli.Agent.Provider (defaultAgentModelConfig)
import "base" GHC.IO.Handle (hDuplicate, hDuplicateTo)
import "base" System.Exit (ExitCode (..))
import "base" System.IO
  ( IOMode (ReadMode, WriteMode),
    hClose,
    hGetContents,
    openFile,
    stdout,
    withFile,
  )
import "tasty" Test.Tasty (TestTree, testGroup)
import "tasty-hunit" Test.Tasty.HUnit (assertEqual, testCase)
import "temporary" System.IO.Temp (withSystemTempFile)

tests :: TestTree
tests =
  testGroup
    "Shiki.Cli.Agent.Launch"
    [ testCase "debug path writes the prompt and exits success" $ do
        (captured, code) <-
          captureStdout $
            runAssistSession
              defaultAgentModelConfig
              AssistDispatch
                { systemPrompt = "PROMPT",
                  userPrompt = Nothing,
                  debug = True
                }
        assertEqual "exit code" ExitSuccess code
        assertEqual "captured stdout" "PROMPT" captured
    ]

-- | Redirect stdout to a temp file for the duration of the action.
--   Returns the captured contents alongside the action's result. Built
--   from primitive Handle operations so the test suite does not need
--   the 'silently' package.
captureStdout :: IO a -> IO (String, a)
captureStdout body =
  withSystemTempFile "shiki-launch-capture" $ \path h -> do
    hClose h
    saved <- hDuplicate stdout
    out <- openFile path WriteMode
    hDuplicateTo out stdout
    hClose out
    result <- body
    -- Restore stdout to its original handle before reading the file.
    hDuplicateTo saved stdout
    hClose saved
    contents <- withFile path ReadMode $ \r -> do
      s <- hGetContents r
      length s `seq` pure s
    pure (contents, result)
