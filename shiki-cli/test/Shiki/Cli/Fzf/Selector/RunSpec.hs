module Shiki.Cli.Fzf.Selector.RunSpec
  ( tests,
  )
where

import Data.Generics.Labels ()
import Data.Text qualified as Text
import Shiki.Cli.Fixtures (fixtureRow, longServiceRow)
import Shiki.Cli.Fzf.Selector.Run (formatRunCandidates)
import Shiki.Prelude ((^.))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase)

tests :: TestTree
tests =
  testGroup
    "Shiki.Cli.Fzf.Selector.Run"
    [ testCase "formatRunCandidates produces single-line displays" $
        mapM_
          ( \d ->
              assertBool
                ("display must not contain embedded newlines: " <> show d)
                (not (Text.any (== '\n') d))
          )
          (titles : displays),
      testCase "formatRunCandidates embeds the 8-char id prefix" $
        assertBool
          ("expected id prefix in display: " <> show displays)
          (any (Text.isInfixOf "3f2c1a9d") (take 1 displays)),
      testCase "formatRunCandidates includes service name and command" $ do
        assertBool "service name appears" (any (Text.isInfixOf "ingest") (take 1 displays))
        assertBool "command appears" (any (Text.isInfixOf "reindex") (take 1 displays))
        assertBool "long service appears" (any (Text.isInfixOf "a-much-longer-service") (drop 1 displays)),
      testCase "formatRunCandidates keeps each record as the value" $
        assertEqual
          "values"
          [fixtureRow, longServiceRow]
          (map (^. #value) candidates),
      testCase "formatRunCandidates aligns rows under the title row" $ do
        let offsetOf needle line = Text.length (fst (Text.breakOn needle line))
        assertBool "titles start with ID" ("ID" `Text.isPrefixOf` titles)
        assertEqual
          "status column offsets"
          [offsetOf "STATUS" titles, offsetOf "STATUS" titles]
          (zipWith offsetOf ["succeeded", "failed"] displays)
    ]
  where
    (titles, candidates) = formatRunCandidates [fixtureRow, longServiceRow]
    displays = map (^. #display) candidates
