module Shiki.Cli.Runs.FormatSpec
  ( tests,
  )
where

import Data.Generics.Labels ()
import Data.Text qualified as Text
import Data.Time.Clock (addUTCTime)
import Shiki.Cli.Fixtures (fixtureRow, longServiceRow)
import Shiki.Cli.Runs.Format
  ( computeWidths,
    displayStatus,
    humanDuration,
    renderTable,
  )
import Shiki.Persistence.Run (RunRecord (..))
import Shiki.Persistence.RunStatus (RunStatus (Running))
import Shiki.Prelude ((^.))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase)

tests :: TestTree
tests =
  testGroup
    "Shiki.Cli.Runs.Format"
    [ testCase "humanDuration formats seconds, minutes, and hours" $
        assertEqual
          "durations"
          ["12s", "2m5s", "1h1m1s"]
          (map humanDuration [12_000, 125_000, 3_661_000]),
      testCase "computeWidths is the widest cell per column" $
        assertEqual
          "widths"
          [3, 6, 1]
          (computeWidths [["ab", "cdefgh"], ["abc", "d", "e"]]),
      testCase "displayStatus classifies watcher heartbeat age" $ do
        assertEqual "missing heartbeat" "unwatched" (displayStatus observedAt running)
        assertEqual
          "recent heartbeat"
          "running"
          (displayStatus observedAt running {lastWatchedAt = Just (addUTCTime (-30) observedAt)})
        assertEqual
          "exactly five minutes is fresh"
          "running"
          (displayStatus observedAt running {lastWatchedAt = Just (addUTCTime (-300) observedAt)})
        assertEqual
          "older than five minutes is stale"
          "unwatched"
          (displayStatus observedAt running {lastWatchedAt = Just (addUTCTime (-301) observedAt)})
        assertEqual "terminal status is preserved" "succeeded" (displayStatus observedAt fixtureRow),
      -- Regression: folding from @repeat 0@ made this diverge for any row.
      testCase "renderTable terminates with a title line and one line per run" $ do
        let ls = Text.lines (renderTable observedAt [fixtureRow])
        assertEqual "line count" 2 (length ls)
        assertBool "title line starts with ID" (any (Text.isPrefixOf "ID") (take 1 ls)),
      testCase "renderTable aligns each column under its title" $ do
        let ls = Text.lines (renderTable observedAt [running, longServiceRow])
            offsetOf needle line = Text.length (fst (Text.breakOn needle line))
        case ls of
          [titles, row1, row2] -> do
            assertEqual "unwatched under STATUS" (offsetOf "STATUS" titles) (offsetOf "unwatched" row1)
            assertEqual "failed under STATUS" (offsetOf "STATUS" titles) (offsetOf "failed" row2)
          _ -> assertBool ("expected three lines, got " <> show ls) False
    ]
  where
    observedAt = addUTCTime 600 (fixtureRow ^. #startedAt)
    running :: RunRecord
    running = fixtureRow {status = Running, exitCode = Nothing, durationMs = Nothing}
