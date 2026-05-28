module Shiki.Cli.Fzf.Selector.RunSpec
  ( tests
  ) where

import Shiki.Cli.Fzf (Candidate (..))
import Shiki.Cli.Fzf.Selector.Run (formatRunCandidate)
import Shiki.Persistence.Run (RunId (..), RunRecord (..))
import Shiki.Persistence.RunStatus (RunStatus (..))

import "aeson" Data.Aeson qualified as Aeson
import "tasty" Test.Tasty (TestTree, testGroup)
import "tasty-hunit" Test.Tasty.HUnit (assertBool, testCase)
import "text" Data.Text qualified as Text
import "time" Data.Time qualified as Time
import "uuid" Data.UUID qualified as UUID

tests :: TestTree
tests =
  testGroup
    "Shiki.Cli.Fzf.Selector.Run"
    [ testCase "formatRunCandidate produces single-line display" $ do
        let c = formatRunCandidate fixtureRow
        assertBool
          "display must not contain embedded newlines"
          (not (Text.any (== '\n') (candidateDisplay c)))
    , testCase "formatRunCandidate embeds the 8-char id prefix" $ do
        let c = formatRunCandidate fixtureRow
        assertBool
          ("expected id prefix in display: " <> Text.unpack (candidateDisplay c))
          (Text.isInfixOf "3f2c1a9d" (candidateDisplay c))
    , testCase "formatRunCandidate includes service name and command" $ do
        let c = formatRunCandidate fixtureRow
        assertBool "service name appears"
          (Text.isInfixOf "ingest" (candidateDisplay c))
        assertBool "command appears"
          (Text.isInfixOf "reindex" (candidateDisplay c))
    ]

fixtureRow :: RunRecord
fixtureRow =
  RunRecord
    { runId              = RunId (UUID.fromWords 0x3f2c1a9d 0x00000000 0x00000000 0x00000001)
    , serviceName        = "ingest"
    , command            = ["reindex", "--batch", "100"]
    , namespace          = "data"
    , jobName            = "shiki-ingest-3f2c1a9d"
    , image              = Just "registry.example.com/ingest:latest"
    , status             = Succeeded
    , exitCode           = Just 0
    , startedAt          = Time.UTCTime (Time.fromGregorian 2026 5 27)
                                        (Time.secondsToDiffTime (17 * 3600 + 22 * 60 + 11))
    , endedAt            = Nothing
    , durationMs         = Just 12_000
    , logTail            = Nothing
    , serviceConfig      = Aeson.Null
    , errorMessage       = Nothing
    , errorSummary       = Nothing
    , errorSummarySource = "none"
    }
