module Shiki.Persistence.RunSpec (tests) where

import Shiki.Prelude

import Shiki.Persistence.Connection
  ( ConnectionString (..)
  , acquirePool
  , releasePool
  )
import Shiki.Persistence.Migration (runMigrations)
import Shiki.Persistence.Run
  ( NewRun (..)
  , RunCompletion (..)
  , RunRecord
  , completeRunStatement
  , getRunStatement
  , insertRunStatement
  , listRecentRunsStatement
  , markRunRunningStatement
  , newRunId
  )
import Shiki.Persistence.RunStatus (RunStatus (Failed, Succeeded))

import "base" Control.Exception (bracket)
import "aeson" Data.Aeson qualified as Aeson
import "ephemeral-pg" EphemeralPg qualified as EpPg
import "hasql-pool" Hasql.Pool qualified as Pool
import "hasql" Hasql.Session qualified as Session
import "hasql" Hasql.Statement (Statement)
import "tasty" Test.Tasty (TestTree, testGroup)
import "tasty-hunit" Test.Tasty.HUnit (assertBool, assertEqual, testCase)

tests :: TestTree
tests =
  testGroup "Shiki.Persistence.Run"
    [ testCase "insert / mark running / complete / list" $
        withTempPg $ \pool -> do
          runMigrations pool
          now <- getCurrentTime
          rid <- newRunId

          useStmt pool insertRunStatement
            NewRun
              { runId = rid
              , serviceName = "mls-service-v2"
              , command = ["subscription", "process"]
              , namespace = "prod"
              , jobName = "mls-service-v2-oneoff-20260526-123000-1234"
              , image = Just "gcr.io/example/mls-service-v2:abc123"
              , startedAt = now
              , serviceConfig =
                  Aeson.object [("name", Aeson.String "mls-service-v2")]
              }
          useStmt pool markRunRunningStatement rid
          useStmt pool completeRunStatement
            RunCompletion
              { runId = rid
              , status = Succeeded
              , exitCode = Just 0
              , endedAt = now
              , durationMs = 12345
              , logTail = Just "everything is fine\n"
              , errorMessage = Nothing
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

          recent <- useStmt' pool listRecentRunsStatement (10 :: Int)
          assertBool "one row recent" (length (recent :: [RunRecord]) == 1)
    , testCase "Failed status round-trips" $
        withTempPg $ \pool -> do
          runMigrations pool
          now <- getCurrentTime
          rid <- newRunId
          useStmt pool insertRunStatement
            NewRun
              { runId = rid
              , serviceName = "x"
              , command = ["y"]
              , namespace = "z"
              , jobName = "j"
              , image = Nothing
              , startedAt = now
              , serviceConfig = Aeson.object []
              }
          useStmt pool completeRunStatement
            RunCompletion
              { runId = rid
              , status = Failed
              , exitCode = Just 137
              , endedAt = now
              , durationMs = 0
              , logTail = Nothing
              , errorMessage = Just "OOMKilled"
              }
          mRow <- useStmt' pool getRunStatement rid
          case mRow of
            Nothing -> fail "expected row"
            Just r -> do
              assertEqual "status" Failed (r ^. #status)
              assertEqual "error" (Just "OOMKilled") (r ^. #errorMessage)
    ]

-- | Spin up a throwaway PostgreSQL via 'ephemeral-pg', acquire a hasql
--   pool against it, hand both to the action, and tear everything down
--   regardless of failures.
withTempPg :: (Pool.Pool -> IO ()) -> IO ()
withTempPg action = do
  result <- EpPg.with $ \db ->
    bracket
      (acquirePool (ConnectionString (EpPg.connectionString db)))
      releasePool
      action
  case result of
    Right () -> pure ()
    Left err ->
      fail ("ephemeral-pg failed to start: " <> show (EpPg.renderStartError err))

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
