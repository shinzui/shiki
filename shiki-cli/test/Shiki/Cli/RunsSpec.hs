-- | @shiki runs@ end to end through the top-level handler, with the store
--   faked in memory: what an operator sees when a statement fails, and when a
--   typed id prefix matches nothing.
module Shiki.Cli.RunsSpec (tests) where

import Baikai.Effectful (Baikai)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TIO
import Effectful (Eff, IOE, inject, type (:>))
import Effectful.Dispatch.Dynamic (interpret_)
import Effectful.Error.Static (Error)
import Shiki.Cli.Effect.FakeRunStore (healthy, newFakeStore, runFakeRunStore)
import Shiki.Cli.Fixtures (fixtureRow)
import Shiki.Cli.Main (runShikiMain)
import Shiki.Cli.Runs (RunsCommand (..), runRuns)
import Shiki.Effect.Analyzer (Analyzer, runAnalyzerBaikai)
import Shiki.Effect.ConfigLoader (ConfigLoader, runConfigLoaderIO)
import Shiki.Effect.RunStore (RunStore)
import Shiki.Error (ShikiError)
import Shiki.Persistence.Run (RunRecord (..))
import Shiki.Prelude ((&), (.~))
import System.Directory (withCurrentDirectory)
import System.Exit (ExitCode (..))
import System.IO (Handle, IOMode (ReadMode), hClose, withFile)
import System.IO.Temp (withSystemTempDirectory, withSystemTempFile)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertEqual, testCase)

tests :: TestTree
tests =
  testGroup
    "Shiki.Cli.Runs"
    [ testCase "a failed statement is one typed line naming the operation" $ do
        (out, code) <-
          capture [fixtureRow] (== "find runs by prefix") (RunsShow (Just "3f"))
        assertEqual "exit code" (ExitFailure 1) code
        assertEqual
          "stderr"
          "shiki: database error during find runs by prefix: relation \"runs\" does not exist\n"
          out,
      testCase "a prefix matching no run keeps its own message" $ do
        (out, code) <- capture [fixtureRow] healthy (RunsShow (Just "nope"))
        assertEqual "exit code" (ExitFailure 1) code
        assertEqual "stderr" "no run matching nope\n" out,
      -- A run can outlive the service file that produced it, so a missing
      -- config still analyzes heuristically. Regression: routing the load
      -- through 'ConfigLoader' briefly turned the fallback into a failure,
      -- because the interpreter throws to the handler that was in scope where
      -- it was installed, not to one nested inside the caller.
      testCase "analyze falls back to the heuristic when the config is gone" $
        withSystemTempDirectory "shiki-runs-spec" $ \tmp -> do
          (out, code) <-
            withCurrentDirectory tmp $
              capture [analyzableRow] healthy (RunsAnalyze (Just "3f2c1a9d") Nothing)
          assertEqual "stderr" "" out
          assertEqual "exit code" ExitSuccess code
    ]

-- | 'fixtureRow' with a log tail the heuristic can summarize.
analyzableRow :: RunRecord
analyzableRow =
  fixtureRow
    & #logTail
    .~ Just "Traceback (most recent call last):\nRuntimeError: boom\n"

-- | Run one @runs@ subcommand against an in-memory store, through the real
--   top-level handler, and return what it wrote on its error handle.
capture :: [RunRecord] -> (Text -> Bool) -> RunsCommand -> IO (Text, ExitCode)
capture rows failing command =
  withSystemTempFile "shiki-runs" $ \path h -> do
    store <- newFakeStore rows
    code <-
      runShikiMain h $
        runRuns
          (runFakeRunStore store failing)
          (\_ -> unreachableKube)
          withAnalyzer
          command
    hClose h
    contents <- withFile path ReadMode readAll
    pure (contents, code)
  where
    readAll :: Handle -> IO Text
    readAll r = do
      t <- TIO.hGetContents r
      Text.length t `seq` pure t

    -- No case here runs @runs sync@, the only subcommand that asks for a
    -- cluster, so the Kube interpreter is never entered. Naming that fact
    -- is better than wiring up a fake nothing exercises.
    unreachableKube =
      error "Shiki.Cli.RunsSpec: no case in this module reaches the cluster"

-- | The analyzer is interpreted for real — 'ConfigLoader' reads the (absent)
--   file from disk and the heuristic runs in process — but no case here names
--   a model, so reaching baikai would be a bug. Mirrors the composition in
--   "Shiki.Cli".
withAnalyzer ::
  (IOE :> es, Error ShikiError :> es) =>
  Eff (Analyzer : ConfigLoader : RunStore : es) () ->
  Eff (RunStore : es) ()
withAnalyzer action =
  runConfigLoaderIO (runUnreachableBaikai (runAnalyzerBaikai (inject action)))

runUnreachableBaikai :: Eff (Baikai : es) a -> Eff es a
runUnreachableBaikai = interpret_ $ \case
  _ -> error "Shiki.Cli.RunsSpec: no case in this module calls a model"
