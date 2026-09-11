module Shiki.Persistence.RunSpec (tests) where

import Data.Aeson qualified as Aeson
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (Statement)
import Shiki.Persistence.Run
  ( NewRun (..),
    RunCompletion (..),
    RunRecord,
    completeRunStatement,
    getRunStatement,
    insertRunStatement,
    listRecentRunsStatement,
    markRunRunningStatement,
    newRunId,
    updateErrorSummaryStatement,
  )
import Shiki.Persistence.RunStatus (RunStatus (Failed, Succeeded))
import Shiki.Persistence.TestPg (withSchemaPool)
import Shiki.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase)

tests :: TestTree
tests =
  testGroup
    "Shiki.Persistence.Run"
    [ testCase "insert / mark running / complete / list" $
        withSchemaPool $ \pool -> do
          now <- getCurrentTime
          rid <- newRunId

          useStmt
            pool
            insertRunStatement
            NewRun
              { runId = rid,
                serviceName = "mls-service-v2",
                command = ["subscription", "process"],
                namespace = "prod",
                jobName = "mls-service-v2-oneoff-20260526-123000-1234",
                image = Just "gcr.io/example/mls-service-v2:abc123",
                startedAt = now,
                serviceConfig =
                  Aeson.object [("name", Aeson.String "mls-service-v2")]
              }
          useStmt pool markRunRunningStatement rid
          useStmt
            pool
            completeRunStatement
            RunCompletion
              { runId = rid,
                status = Succeeded,
                exitCode = Just 0,
                endedAt = now,
                durationMs = 12345,
                logTail = Just "everything is fine\n",
                errorMessage = Nothing,
                errorSummary = Nothing,
                errorSummarySource = "heuristic"
              }

          mRow <- useStmt' pool getRunStatement rid
          case mRow of
            Nothing -> fail "expected row"
            Just r -> do
              assertEqual "status" Succeeded (r ^. #status)
              assertEqual "exitCode" (Just 0) (r ^. #exitCode)
              assertEqual "durationMs" (Just 12345) (r ^. #durationMs)
              assertEqual
                "logTail"
                (Just "everything is fine\n")
                (r ^. #logTail)
              assertEqual
                "errorSummary"
                Nothing
                (r ^. #errorSummary)
              assertEqual
                "errorSummarySource defaults to heuristic"
                ("heuristic" :: Text)
                (r ^. #errorSummarySource)

          recent <- useStmt' pool listRecentRunsStatement (10 :: Int)
          assertBool "one row recent" (length (recent :: [RunRecord]) == 1),
      testCase "Failed status round-trips" $
        withSchemaPool $ \pool -> do
          now <- getCurrentTime
          rid <- newRunId
          useStmt
            pool
            insertRunStatement
            NewRun
              { runId = rid,
                serviceName = "x",
                command = ["y"],
                namespace = "z",
                jobName = "j",
                image = Nothing,
                startedAt = now,
                serviceConfig = Aeson.object []
              }
          useStmt
            pool
            completeRunStatement
            RunCompletion
              { runId = rid,
                status = Failed,
                exitCode = Just 137,
                endedAt = now,
                durationMs = 0,
                logTail = Just "Traceback (most recent call last):\nRuntimeError: boom\n",
                errorMessage = Just "OOMKilled",
                errorSummary = Just "RuntimeError: boom",
                errorSummarySource = "heuristic"
              }
          mRow <- useStmt' pool getRunStatement rid
          case mRow of
            Nothing -> fail "expected row"
            Just r -> do
              assertEqual "status" Failed (r ^. #status)
              assertEqual "error" (Just "OOMKilled") (r ^. #errorMessage)
              assertEqual
                "errorSummary"
                (Just "RuntimeError: boom")
                (r ^. #errorSummary)
              assertEqual
                "errorSummarySource"
                ("heuristic" :: Text)
                (r ^. #errorSummarySource)

          -- updateErrorSummaryStatement rewrites the analyzer fields
          -- without touching the rest of the row.
          useStmt
            pool
            updateErrorSummaryStatement
            (rid, Just "model-derived summary", "baikai:test")
          mRow' <- useStmt' pool getRunStatement rid
          case mRow' of
            Nothing -> fail "expected row after analyzer rewrite"
            Just r -> do
              assertEqual
                "rewritten errorSummary"
                (Just "model-derived summary")
                (r ^. #errorSummary)
              assertEqual
                "rewritten errorSummarySource"
                ("baikai:test" :: Text)
                (r ^. #errorSummarySource)
              assertEqual "rest of row preserved" Failed (r ^. #status)
    ]

-- | Run a write-style 'Statement' (no result) against the pool and
--   collapse any pool error into a test failure.
useStmt :: Pool.Pool -> Statement a () -> a -> IO ()
useStmt pool stmt input =
  Pool.use pool (Session.statement input stmt) >>= either (fail . show) pure

-- | Run a read-style 'Statement' against the pool, returning the
--   decoded result.
useStmt' :: Pool.Pool -> Statement a b -> a -> IO b
useStmt' pool stmt input =
  Pool.use pool (Session.statement input stmt) >>= either (fail . show) pure
