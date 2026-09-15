module Shiki.Cli.Fzf.Selector.RunSpec
  ( tests,
  )
where

import Data.Generics.Labels ()
import Data.Text qualified as Text
import Data.Time.Clock (addUTCTime)
import Shiki.Cli.Fixtures (fixtureRow, longServiceRow)
import Shiki.Cli.Fzf (FzfConfig (..), FzfResult (..))
import Shiki.Cli.Fzf.Selector.Run
  ( RunLookupFailure (..),
    RunTarget (..),
    analyzeRunOpts,
    formatRunCandidates,
    fromPrefixMatches,
    fromRunFzfResult,
    pickerRunTarget,
    readRunOpts,
    renderRunLookupFailure,
  )
import Shiki.Persistence.Run (RunRecord (..))
import Shiki.Persistence.RunStatus (RunStatus (Running))
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
          (zipWith offsetOf ["succeeded", "failed"] displays),
      testCase "formatRunCandidates displays an unwatched unfinished row" $ do
        let (_, unwatchedCandidates) =
              formatRunCandidates observedAt [fixtureRow {status = Running, lastWatchedAt = Nothing}]
        case unwatchedCandidates of
          [candidate] ->
            assertBool "unwatched status appears" ("unwatched" `Text.isInfixOf` (candidate ^. #display))
          other -> fail ("expected one candidate, got " <> show (length other)),
      testCase "fromPrefixMatches: none, one, or ambiguous" $ do
        assertEqual "none" (Left (NoRunMatching "3f")) (fromPrefixMatches "3f" [])
        assertEqual "one" (Right fixtureRow) (fromPrefixMatches "3f" [fixtureRow])
        assertEqual
          "two"
          (Left (AmbiguousRunPrefix "3f"))
          (fromPrefixMatches "3f" [fixtureRow, longServiceRow]),
      testCase "fromRunFzfResult maps each fzf outcome" $ do
        assertEqual "selected" (Right fixtureRow) (fromRunFzfResult (FzfSelected fixtureRow))
        assertEqual "cancelled" (Left RunPickerCancelled) (fromRunFzfResult FzfCancelled)
        assertEqual "error" (Left (RunPickerFailed "boom")) (fromRunFzfResult (FzfError "boom")),
      -- Regression: a query matching nothing used to be reported as an empty table.
      testCase "a picker query matching nothing is RunPickerNoMatch, not NoRunsRecorded" $
        assertEqual "no match" (Left RunPickerNoMatch) (fromRunFzfResult FzfNoMatch),
      testCase "renderRunLookupFailure messages" $
        assertEqual
          "messages"
          [ Just "no run matching 3f",
            Just "ambiguous id prefix 3f",
            Just "shiki: no runs recorded yet",
            Just "shiki: no run matches the picker query",
            Nothing,
            Just "shiki: no run id given and fzf is not available",
            Just "shiki: fzf: boom",
            Just "shiki: persistence error: down"
          ]
          ( map
              renderRunLookupFailure
              [ NoRunMatching "3f",
                AmbiguousRunPrefix "3f",
                NoRunsRecorded,
                RunPickerNoMatch,
                RunPickerCancelled,
                RunFzfUnavailable,
                RunPickerFailed "boom",
                RunLookupPersistenceError "down"
              ]
          ),
      testCase "pickerRunTarget needs a usable fzf" $ do
        let cfg a t = FzfConfig {binary = "fzf", available = a, ttyAvailable = t}
            isUnavailable = \case
              Left RunFzfUnavailable -> True
              _ -> False
            isPicker = \case
              Right (RunByPicker _ _) -> True
              _ -> False
        assertBool "available" (isPicker (pickerRunTarget readRunOpts (cfg True True)))
        assertBool
          "unavailable"
          (all (isUnavailable . pickerRunTarget readRunOpts) [cfg True False, cfg False True, cfg False False]),
      testCase "read pickers auto-select a lone run; analyze always asks" $ do
        assertBool "read selectOne" (readRunOpts ^. #selectOne)
        assertBool "analyze never selectOne" (not (analyzeRunOpts ^. #selectOne))
        assertEqual
          "analyze header"
          (Just "Enter re-runs analysis on the selected run and overwrites its stored error summary")
          (analyzeRunOpts ^. #header)
    ]
  where
    observedAt = addUTCTime 600 (fixtureRow ^. #startedAt)
    (titles, candidates) = formatRunCandidates observedAt [fixtureRow, longServiceRow]
    displays = map (^. #display) candidates
