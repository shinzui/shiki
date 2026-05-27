module Shiki.Persistence.RunListSpec (tests) where

import Shiki.Prelude

import Shiki.Persistence.Connection
  ( ConnectionString (..)
  , acquirePool
  , releasePool
  )
import Shiki.Persistence.Migration (runMigrations)
import Shiki.Persistence.Run
  ( NewRun (..)
  , RunRecord
  , insertRunStatement
  , listRecentRunsByServiceStatement
  , listRecentRunsStatement
  , newRunId
  )

import "base" Control.Exception (bracket)
import "aeson" Data.Aeson qualified as Aeson
import "time" Data.Time.Clock (addUTCTime)
import "ephemeral-pg" EphemeralPg qualified as EpPg
import "hasql-pool" Hasql.Pool qualified as Pool
import "hasql" Hasql.Session qualified as Session
import "hasql" Hasql.Statement (Statement)
import "tasty" Test.Tasty (TestTree, testGroup)
import "tasty-hunit" Test.Tasty.HUnit (assertBool, assertEqual, testCase)

tests :: TestTree
tests =
  testGroup "Shiki.Persistence.Run (list)"
    [ testCase "listRecentRunsStatement returns rows newest-first" $
        withTempPg $ \pool -> do
          runMigrations pool
          t0 <- getCurrentTime
          let mkRow svc offsetSec = do
                rid <- newRunId
                useStmt pool insertRunStatement
                  NewRun
                    { runId = rid
                    , serviceName = svc
                    , command = ["x"]
                    , namespace = "ns"
                    , jobName = "j"
                    , image = Nothing
                    , startedAt = addUTCTime (fromIntegral (offsetSec :: Int)) t0
                    , serviceConfig = Aeson.object []
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
            (all (\r -> r ^. #serviceName == "svc-a") aOnly)
    ]

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

useStmt :: Pool.Pool -> Statement a () -> a -> IO ()
useStmt pool stmt input =
  Pool.use pool (Session.statement input stmt) >>= either (fail . show) pure

useStmtRead :: Pool.Pool -> Statement a b -> a -> IO b
useStmtRead pool stmt input =
  Pool.use pool (Session.statement input stmt) >>= either (fail . show) pure
