module Shiki.Cli.Agent.PromptSpec
  ( tests,
  )
where

import Data.Aeson qualified as Aeson
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Data.UUID qualified as UUID
import Shiki.Cli.Agent.Context
  ( AgentContext (..),
    ServiceSummary (..),
  )
import Shiki.Cli.Agent.Prompt (renderAssistPrompt)
import Shiki.Persistence.Run (RunId (..), RunRecord (..))
import Shiki.Persistence.RunStatus (RunStatus (Failed, Succeeded))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase)

tests :: TestTree
tests =
  testGroup
    "Shiki.Cli.Agent.Prompt"
    [ testCase "renders services, runs, and structural headings" $ do
        let rendered = renderAssistPrompt sampleContext (Just "test prompt")
        assertContains "heading" "# shiki agent assist" rendered
        assertContains "services heading" "## Services declared on disk" rendered
        assertContains "runs heading" "## Recent runs (most recent first, up to 20)" rendered
        assertContains "operator hints heading" "## Operator hints" rendered
        assertContains "service foo" "foo" rendered
        assertContains "service bar" "bar" rendered
        assertContains "service-foo line" "- foo (namespace: default, analyzer: heuristic)" rendered
        assertContains
          "service-bar line"
          "- bar (namespace: ops, analyzer: baikai:anthropic_claude_haiku_4_5)"
          rendered
        assertContains "cwd" "/tmp/work" rendered
        assertContains "schema" "shiki" rendered
        assertContains "cluster" "unknown" rendered
        assertContains
          "run id prefix"
          (Text.take 8 (UUID.toText sampleUuid))
          rendered
        assertContains "user prompt body" "test prompt" rendered
        -- The {{...}} placeholders must all be substituted.
        assertBool
          "no curly placeholders left"
          (not (Text.isInfixOf "{{" rendered)),
      testCase "missing user prompt becomes (no hints)" $ do
        let rendered = renderAssistPrompt sampleContext Nothing
        assertContains "(no hints) fallback" "(no hints)" rendered,
      testCase "empty services and runs render empty placeholders" $ do
        let rendered =
              renderAssistPrompt
                sampleContext {services = [], recentRuns = []}
                Nothing
        assertContains "(none declared)" "(none declared)" rendered
        assertContains "(no runs yet)" "(no runs yet)" rendered
    ]

sampleContext :: AgentContext
sampleContext =
  AgentContext
    { cwd = "/tmp/work",
      servicesDir = "services",
      services =
        [ ServiceSummary "foo" "default" "heuristic",
          ServiceSummary "bar" "ops" "baikai:anthropic_claude_haiku_4_5"
        ],
      serviceLoadErrors = [],
      recentRuns =
        [ sampleRun Succeeded Nothing,
          sampleRun Failed (Just "RuntimeError: boom")
        ],
      schemaName = "shiki",
      cluster = "unknown"
    }

sampleUuid :: UUID.UUID
sampleUuid =
  -- A stable, hand-built UUID so the prefix assertion is reproducible.
  case UUID.fromText "12345678-1234-5678-1234-567812345678" of
    Just u -> u
    Nothing -> error "PromptSpec: sample UUID failed to parse"

sampleRun :: RunStatus -> Maybe Text -> RunRecord
sampleRun status mSummary =
  RunRecord
    { runId = RunId sampleUuid,
      serviceName = "foo",
      command = ["echo", "hi"],
      namespace = "default",
      jobName = "foo-oneoff",
      image = Nothing,
      status = status,
      exitCode = Just 0,
      startedAt = UTCTime (fromGregorian 2026 5 27) (secondsToDiffTime 0),
      endedAt = Nothing,
      durationMs = Nothing,
      logTail = Nothing,
      serviceConfig = Aeson.Null,
      errorMessage = Nothing,
      errorSummary = mSummary,
      errorSummarySource = "heuristic"
    }

assertContains :: String -> Text -> Text -> IO ()
assertContains label needle haystack =
  assertBool
    (label <> ": expected to find " <> show needle)
    (needle `Text.isInfixOf` haystack)
