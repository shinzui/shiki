-- | @shiki run@ through the top-level handler, with both the store and the
--   cluster faked: what a Ctrl-C during the wait does to the run row.
module Shiki.Cli.RunSpec (tests) where

import Control.Exception qualified as E
import Data.Text qualified as Text
import Effectful (liftIO)
import Shiki.Cli.Effect.FakeKube (runFakeKube)
import Shiki.Cli.Effect.FakeRunStore
  ( healthy,
    newFakeStore,
    recordedCompletions,
    runFakeRunStore,
  )
import Shiki.Cli.Fixtures (minimalServiceDhall)
import Shiki.Cli.Main (runShikiMain)
import Shiki.Cli.Run (RunOptions (..), runRun)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory, withSystemTempFile)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertEqual, assertFailure, testCase)

tests :: TestTree
tests =
  testGroup
    "Shiki.Cli.Run"
    [ -- ADR 3: the Job outlives the process, so an interrupted watcher must
      -- not claim the run failed. Before EP-19 the run path caught every
      -- exception, including 'UserInterrupt', and wrote a @failed@ row saying
      -- @user interrupt@ while the Job carried on in the cluster.
      testCase "Ctrl-C while waiting writes no completion and propagates" $
        withSystemTempDirectory "shiki-run-spec" $ \tmp -> do
          let svcDir = tmp </> "services"
          createDirectoryIfMissing True svcDir
          writeFile (svcDir </> "foo.dhall") (Text.unpack (minimalServiceDhall "foo"))
          store <- newFakeStore []
          outcome <-
            E.try @E.AsyncException $
              withSystemTempFile "shiki-run-spec-err" $ \_ h ->
                runShikiMain h $
                  runFakeRunStore store healthy $
                    runFakeKube (liftIO (E.throwIO E.UserInterrupt)) $
                      runRun (runOptions svcDir)
          case outcome of
            Left E.UserInterrupt -> pure ()
            Left other -> assertFailure ("unexpected async exception: " <> show other)
            Right code -> assertFailure ("the interrupt was swallowed, got " <> show code)
          completions <- recordedCompletions store
          assertEqual "the run was left unfinished" [] completions
    ]

runOptions :: FilePath -> RunOptions
runOptions svcDir =
  RunOptions
    { service = "foo",
      overrideNs = Nothing,
      noWait = False,
      configDir = svcDir,
      commandArgs = ["echo", "hi"]
    }
