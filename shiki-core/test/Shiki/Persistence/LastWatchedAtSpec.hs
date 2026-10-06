module Shiki.Persistence.LastWatchedAtSpec (tests) where

import Control.Exception (bracket)
import Data.Aeson qualified as Aeson
import Data.Functor.Contravariant ((>$<))
import Data.Generics.Labels ()
import Data.Int (Int32)
import Data.Monoid qualified as EphemeralMonoid
import EphemeralPg qualified as EpPg
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
import Shiki.Persistence.Connection
  ( ConnectionString (..),
    acquirePool,
    releasePool,
  )
import Shiki.Persistence.Run
  ( NewRun (..),
    RunCompletion (..),
    RunId (..),
    completeRunStatement,
    databaseNowStatement,
    getRunStatement,
    insertRunStatement,
    markRunRunningStatement,
    newRunId,
    touchRunWatchedStatement,
  )
import Shiki.Persistence.RunStatus (RunStatus (Succeeded))
import Shiki.Persistence.Schema (schemaText)
import Shiki.Persistence.TestPg (freshSchema, migrateOrFail, withSchemaPool)
import Shiki.Prelude
import System.Directory qualified as EphemeralDirectory
import System.Posix.User qualified as EphemeralUser
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase)

tests :: TestTree
tests =
  testGroup
    "Shiki.Persistence (last_watched_at)"
    [ testCase "migration creates last_watched_at in the configured schema" $ do
        schema <- freshSchema
        result <- withEphemeralPg $ \db -> do
          let cs = ConnectionString (EpPg.connectionString db)
          bracket (acquirePool cs schema) releasePool $ \pool -> do
            migrateOrFail cs schema
            n <-
              Pool.use pool (Session.statement (schemaText schema) lastWatchedAtColumnCount)
                >>= either (fail . show) pure
            assertEqual "last_watched_at column present" 1 n
        case result of
          Right () -> pure ()
          Left err ->
            fail ("ephemeral-pg failed to start: " <> show (EpPg.renderStartError err)),
      testCase "touch records database time without changing updated_at" $
        withSchemaPool $ \pool -> do
          rid <- insertOneRun pool
          runStatement pool markRunRunningStatement rid
          updatedBefore <- runStatement pool updatedAtStatement rid
          observedBefore <- runStatement pool databaseNowStatement ()
          runStatement pool touchRunWatchedStatement rid
          row <- runStatement pool getRunStatement rid >>= maybe (fail "expected row") pure
          updatedAfter <- runStatement pool updatedAtStatement rid
          assertBool
            "heartbeat is at or after the preceding database timestamp"
            (maybe False (>= observedBefore) (row ^. #lastWatchedAt))
          assertEqual "updated_at is unchanged" updatedBefore updatedAfter,
      testCase "touch ignores a succeeded run" $
        withSchemaPool $ \pool -> do
          rid <- insertOneRun pool
          now <- getCurrentTime
          runStatement
            pool
            completeRunStatement
            RunCompletion
              { runId = rid,
                status = Succeeded,
                exitCode = Just 0,
                endedAt = now,
                durationMs = 0,
                logTail = Nothing,
                errorMessage = Nothing,
                errorSummary = Nothing,
                errorSummarySource = "heuristic"
              }
          runStatement pool touchRunWatchedStatement rid
          row <- runStatement pool getRunStatement rid >>= maybe (fail "expected row") pure
          assertEqual "finished row remains untouched" Nothing (row ^. #lastWatchedAt)
    ]

lastWatchedAtColumnCount :: Statement Text Int32
lastWatchedAtColumnCount =
  preparable sql encoder decoder
  where
    sql =
      "SELECT COUNT(*)::int FROM information_schema.columns \
      \WHERE table_schema = $1 AND table_name = 'runs' \
      \  AND column_name = 'last_watched_at'"
    encoder = id >$< Encoders.param (Encoders.nonNullable Encoders.text)
    decoder = Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int4))

updatedAtStatement :: Statement RunId UTCTime
updatedAtStatement =
  preparable
    "SELECT updated_at FROM runs WHERE id = $1"
    (unRunId >$< Encoders.param (Encoders.nonNullable Encoders.uuid))
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.timestamptz)))

insertOneRun :: Pool.Pool -> IO RunId
insertOneRun pool = do
  now <- getCurrentTime
  rid <- newRunId
  runStatement
    pool
    insertRunStatement
    NewRun
      { runId = rid,
        serviceName = "svc",
        command = ["x"],
        namespace = "ns",
        jobName = "job",
        image = Nothing,
        startedAt = now,
        serviceConfig = Aeson.object []
      }
  pure rid

runStatement :: Pool.Pool -> Statement a b -> a -> IO b
runStatement pool statement input =
  Pool.use pool (Session.statement input statement) >>= either (fail . show) pure

-- | Stable per-user root lets the next invocation reap abandoned clusters.
-- See mori://shinzui/ephemeral-pg/docs/guides (temporary-roots-and-stale-cleanup.md; artifact URI pending).
withEphemeralPg :: (EpPg.Database -> IO a) -> IO (Either EpPg.StartError a)
withEphemeralPg action = do
  uid <- EphemeralUser.getEffectiveUserID
  let root = "/tmp/ephpg-shiki-" <> show uid
  EphemeralDirectory.createDirectoryIfMissing True root
  let config = EpPg.defaultConfig {EpPg.temporaryRoot = EphemeralMonoid.Last (Just root)}
  EpPg.withConfig config action
