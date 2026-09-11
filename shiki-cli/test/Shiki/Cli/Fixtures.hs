-- | Sample 'RunRecord' values shared by the run formatting and run selector
--   specs.
module Shiki.Cli.Fixtures
  ( fixtureRow,
    longServiceRow,
  )
where

import Data.Aeson qualified as Aeson
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
      errorSummarySource = "none"
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
