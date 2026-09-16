-- | Sample 'RunRecord' values shared by the run formatting and run selector
--   specs.
module Shiki.Cli.Fixtures
  ( fixtureRow,
    longServiceRow,
    minimalServiceDhall,
  )
where

import Data.Aeson qualified as Aeson
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time qualified as Time
import Data.UUID qualified as UUID
import Shiki.Persistence.Run (RunId (..), RunRecord (..))
import Shiki.Persistence.RunStatus (RunStatus (..))

-- | Id starting @3f2c1a9d@, service @ingest@, command @reindex --batch 100@,
--   status 'Succeeded', 12 seconds, exit 0.
fixtureRow :: RunRecord
fixtureRow =
  RunRecord
    { runId = RunId (UUID.fromWords 0x3f2c1a9d 0x00000000 0x00000000 0x00000001),
      serviceName = "ingest",
      command = ["reindex", "--batch", "100"],
      namespace = "data",
      jobName = "shiki-ingest-3f2c1a9d",
      image = Just "registry.example.com/ingest:latest",
      status = Succeeded,
      exitCode = Just 0,
      startedAt =
        Time.UTCTime
          (Time.fromGregorian 2026 5 27)
          (Time.secondsToDiffTime (17 * 3600 + 22 * 60 + 11)),
      endedAt = Nothing,
      durationMs = Just 12_000,
      logTail = Nothing,
      serviceConfig = Aeson.Null,
      errorMessage = Nothing,
      errorSummary = Nothing,
      errorSummarySource = "none",
      lastWatchedAt = Nothing
    }

-- | Id starting @7a01bc22@, service @a-much-longer-service@, command
--   @migrate@, status 'Failed', 2m5s, exit 2.
longServiceRow :: RunRecord
longServiceRow =
  fixtureRow
    { runId = RunId (UUID.fromWords 0x7a01bc22 0x00000000 0x00000000 0x00000002),
      serviceName = "a-much-longer-service",
      command = ["migrate"],
      jobName = "shiki-long-7a01bc22",
      status = Failed,
      exitCode = Just 2,
      durationMs = Just 125_000
    }

-- | A minimal Dhall record that satisfies 'ServiceConfig', under the given
--   service name. Inlined rather than reading the repository's @services/@ so
--   a test does not depend on that path resolving from a temporary directory.
minimalServiceDhall :: Text -> Text
minimalServiceDhall serviceName =
  Text.unlines
    [ "let EnvSource =",
      "      < ConfigMap : { key : Text }",
      "      | Secret : { key : Text }",
      "      | Literal : { value : Text }",
      "      | DeploymentEnv : { name : Text }",
      "      >",
      "",
      "let EnvVar = { name : Text, source : EnvSource }",
      "",
      "let ContainerImageSource =",
      "      < StaticImage : { value : Text }",
      "      | DeploymentInitImage : { name : Text }",
      "      >",
      "",
      "let InitContainer =",
      "      { name : Text",
      "      , image : ContainerImageSource",
      "      , args : List Text",
      "      , env : List EnvVar",
      "      , resources :",
      "          { cpuRequest : Text",
      "          , cpuLimit : Text",
      "          , memoryRequest : Text",
      "          , memoryLimit : Text",
      "          }",
      "      , restartable : Bool",
      "      }",
      "",
      "let AnalyzerBackend =",
      "      < Heuristic | Baikai : { model : Text } | None >",
      "",
      "in  { name = \"" <> serviceName <> "\"",
      "    , defaultNamespace = \"default\"",
      "    , detectFromDeployment = \"" <> serviceName <> "\"",
      "    , containerName = \"" <> serviceName <> "\"",
      "    , commandPath = \"/foo\"",
      "    , serviceAccount = \"foo\"",
      "    , nodeSelector = toMap {=} : List { mapKey : Text, mapValue : Text }",
      "    , initContainers = [] : List InitContainer",
      "    , env = [] : List EnvVar",
      "    , resources =",
      "        { cpuRequest = \"100m\"",
      "        , cpuLimit = \"500m\"",
      "        , memoryRequest = \"128Mi\"",
      "        , memoryLimit = \"256Mi\"",
      "        }",
      "    , analyzer = AnalyzerBackend.Heuristic",
      "    }"
    ]
