module Shiki.Cli.Agent.LaunchSpec
  ( tests,
  )
where

import Baikai.Effectful (Baikai)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TIO
import Effectful (Eff, runEff)
import Effectful.Dispatch.Dynamic (interpret_)
import Effectful.Error.Static (runErrorNoCallStack)
import Shiki.Cli.Agent.Launch (AssistDispatch (..), runAssistSession)
import Shiki.Cli.Agent.Provider (defaultAgentModelConfig)
import Shiki.Cli.Error (CliError)
import System.Exit (ExitCode (..))
import System.IO (Handle, IOMode (ReadMode), hClose, withFile)
import System.IO.Temp (withSystemTempFile)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertEqual, testCase)

tests :: TestTree
tests =
  testGroup
    "Shiki.Cli.Agent.Launch"
    [ testCase "debug path writes the prompt and exits success" $
        -- The session writes to the handle it is given, so this asserts on a
        -- temporary file rather than swapping the process's stdout. The old
        -- capture raced tasty's own reporter, which writes to stdout from
        -- another thread, and failed roughly one run in six.
        withSystemTempFile "shiki-assist-debug" $ \path h -> do
          code <-
            runEff
              . runErrorNoCallStack @CliError
              . runUnreachableBaikai
              $ runAssistSession
                h
                defaultAgentModelConfig
                AssistDispatch
                  { systemPrompt = "PROMPT",
                    userPrompt = Nothing,
                    debug = True
                  }
          hClose h
          written <- withFile path ReadMode readAll
          assertEqual "exit code" (Right ExitSuccess) code
          assertEqual "written output" "PROMPT" written
    ]

readAll :: Handle -> IO Text
readAll r = do
  t <- TIO.hGetContents r
  Text.length t `seq` pure t

-- | The debug path must not reach a provider.
runUnreachableBaikai :: Eff (Baikai : es) a -> Eff es a
runUnreachableBaikai = interpret_ $ \case
  _ -> error "Shiki.Cli.Agent.LaunchSpec: the debug path must not call a model"
