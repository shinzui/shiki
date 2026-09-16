-- | @shiki runs@ end to end through the top-level handler, with the store
--   faked in memory: what an operator sees when a statement fails, and when a
--   typed id prefix matches nothing.
module Shiki.Cli.RunsSpec (tests) where

import Data.IORef (newIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TIO
import Shiki.Cli.Effect.FakeRunStore (healthy, runFakeRunStore)
import Shiki.Cli.Fixtures (fixtureRow)
import Shiki.Cli.Main (runShikiMain)
import Shiki.Cli.Runs (RunsCommand (..), runRuns)
import Shiki.Persistence.Run (RunRecord)
import System.Exit (ExitCode (..))
import System.IO (Handle, IOMode (ReadMode), hClose, withFile)
import System.IO.Temp (withSystemTempFile)
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
        assertEqual "stderr" "no run matching nope\n" out
    ]

-- | Run one @runs@ subcommand against an in-memory store, through the real
--   top-level handler, and return what it wrote on its error handle.
capture :: [RunRecord] -> (Text -> Bool) -> RunsCommand -> IO (Text, ExitCode)
capture rows failing command =
  withSystemTempFile "shiki-runs" $ \path h -> do
    ref <- newIORef rows
    code <- runShikiMain h (runRuns (runFakeRunStore ref failing) command)
    hClose h
    contents <- withFile path ReadMode readAll
    pure (contents, code)
  where
    readAll :: Handle -> IO Text
    readAll r = do
      t <- TIO.hGetContents r
      Text.length t `seq` pure t
