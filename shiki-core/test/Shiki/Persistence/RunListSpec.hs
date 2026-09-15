module Shiki.Persistence.RunListSpec (tests) where

import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.Time.Clock (addUTCTime)
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (Statement)
import Shiki.Persistence.Run
  ( NewRun (..),
    RunCompletion (..),
    RunRecord,
    completeRunStatement,
    completeUnfinishedRunStatement,
    insertRunStatement,
    listRecentRunsByServiceStatement,
    listRecentRunsStatement,
    listUnfinishedRunsStatement,
    markRunRunningStatement,
    newRunId,
  )
import Shiki.Persistence.RunStatus (RunStatus (Failed, Succeeded))
import Shiki.Persistence.TestPg (withSchemaPool)
import Shiki.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase)

tests :: TestTree
tests =
  testGroup
    "Shiki.Persistence.Run (list)"
    [ testCase "listRecentRunsStatement returns rows newest-first" $
        withSchemaPool $ \pool -> do
          t0 <- getCurrentTime
          let mkRow svc offsetSec = do
                rid <- newRunId
                useStmt
                  pool
                  insertRunStatement
                  NewRun
                    { runId = rid,
                      serviceName = svc,
                      command = ["x"],
                      namespace = "ns",
                      jobName = "j",
                      image = Nothing,
                      startedAt = addUTCTime (fromIntegral (offsetSec :: Int)) t0,
                      serviceConfig = Aeson.object []
                    }
          mkRow "svc-a" 0
          mkRow "svc-b" 5
          mkRow "svc-a" 10

          all3 <- useStmtRead pool listRecentRunsStatement (10 :: Int)
          assertEqual "row count" 3 (length (all3 :: [RunRecord]))
          let services = map (^. #serviceName) all3
          assertEqual
            "ordered newest first"
            ["svc-a", "svc-b", "svc-a"]
            services

          aOnly <-
            useStmtRead pool listRecentRunsByServiceStatement ("svc-a", 10)
          assertEqual "service filter" 2 (length (aOnly :: [RunRecord]))
          assertBool
            "all rows are svc-a"
            (all (\r -> r ^. #serviceName == "svc-a") aOnly),
      testCase "sync sees only unfinished runs and never overwrites a finished one" $
        withSchemaPool $ \pool -> do
          t0 <- getCurrentTime
          let mkRow offsetSec = do
                rid <- newRunId
                useStmt
                  pool
                  insertRunStatement
                  NewRun
                    { runId = rid,
                      serviceName = "svc",
                      command = ["x"],
                      namespace = "ns",
                      jobName = "j",
                      image = Nothing,
                      startedAt = addUTCTime (fromIntegral (offsetSec :: Int)) t0,
                      serviceConfig = Aeson.object []
                    }
                pure rid
              completion rid st =
                RunCompletion
                  { runId = rid,
                    status = st,
                    exitCode = Nothing,
                    endedAt = t0,
                    durationMs = 0,
                    logTail = Nothing,
                    errorMessage = Nothing,
                    errorSummary = Nothing,
                    errorSummarySource = "heuristic"
                  }
          pendingId <- mkRow 0
          runningId <- mkRow 5
          doneId <- mkRow 10
          useStmt pool markRunRunningStatement runningId
          useStmt pool completeRunStatement (completion doneId Succeeded)

          unfinished <- useStmtRead pool listUnfinishedRunsStatement ()
          assertEqual
            "pending and running, oldest first"
            [pendingId, runningId]
            (map (^. #runId) unfinished)

          updated <- useStmtRead pool completeUnfinishedRunStatement (completion runningId Failed)
          assertBool "unfinished run is finalized" updated
          overwrote <- useStmtRead pool completeUnfinishedRunStatement (completion doneId Failed)
          assertBool "finished run is left unchanged" (not overwrote)
          rows <- useStmtRead pool listRecentRunsStatement (10 :: Int)
          assertEqual
            "statuses"
            [(doneId, Succeeded), (runningId, Failed)]
            [(r ^. #runId, r ^. #status) | r <- rows, r ^. #runId /= pendingId]
    ]

useStmt :: Pool.Pool -> Statement a () -> a -> IO ()
useStmt pool stmt input =
  Pool.use pool (Session.statement input stmt) >>= either (fail . show) pure

useStmtRead :: Pool.Pool -> Statement a b -> a -> IO b
useStmtRead pool stmt input =
  Pool.use pool (Session.statement input stmt) >>= either (fail . show) pure
