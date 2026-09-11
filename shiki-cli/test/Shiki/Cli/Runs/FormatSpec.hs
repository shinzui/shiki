module Shiki.Cli.Runs.FormatSpec
  ( tests,
  )
where

import Data.Text qualified as Text
import Shiki.Cli.Fixtures (fixtureRow, longServiceRow)
import Shiki.Cli.Runs.Format (computeWidths, humanDuration, renderTable)
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
      -- Regression: folding from @repeat 0@ made this diverge for any row.
      testCase "renderTable terminates with a title line and one line per run" $ do
        let ls = Text.lines (renderTable [fixtureRow])
        assertEqual "line count" 2 (length ls)
        assertBool "title line starts with ID" (any (Text.isPrefixOf "ID") (take 1 ls)),
      testCase "renderTable aligns each column under its title" $ do
        let ls = Text.lines (renderTable [fixtureRow, longServiceRow])
            offsetOf needle line = Text.length (fst (Text.breakOn needle line))
        case ls of
          [titles, row1, row2] -> do
            assertEqual "succeeded under STATUS" (offsetOf "STATUS" titles) (offsetOf "succeeded" row1)
            assertEqual "failed under STATUS" (offsetOf "STATUS" titles) (offsetOf "failed" row2)
          _ -> assertBool ("expected three lines, got " <> show ls) False
    ]
