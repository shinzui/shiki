module Shiki.Persistence.SchemaIsolationSpec (tests) where

import Control.Exception (bracket)
import Data.Aeson qualified as Aeson
import Data.Int (Int32)
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
import Shiki.Persistence.Migration (runMigrations)
import Shiki.Persistence.Run
  ( NewRun (..),
    insertRunStatement,
    newRunId,
  )
import Shiki.Persistence.Schema (Schema, mkSchema, schemaText)
import Shiki.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertEqual, testCase)

tests :: TestTree
tests =
  testGroup
    "Shiki.Persistence.Schema (isolation)"
    [ testCase "two schemas in one database stay separate" $ do
        Right alpha <- pure (mkSchema "alpha")
        Right beta <- pure (mkSchema "beta")
        result <- EpPg.with $ \db -> do
          let cs = ConnectionString (EpPg.connectionString db)
          runOnePool cs alpha
          runOnePool cs beta
          verifyCount cs alpha 1
          verifyCount cs beta 1
          verifyLedgerCount cs alpha 3
          verifyLedgerCount cs beta 3
          verifyMissingFromPublic cs
        case result of
          Right () -> pure ()
          Left err ->
            fail ("ephemeral-pg failed to start: " <> show (EpPg.renderStartError err))
    ]

-- | Acquire a pool for the given schema, run migrations, insert one row.
runOnePool :: ConnectionString -> Schema -> IO ()
runOnePool cs schema =
  bracket (acquirePool cs schema) releasePool $ \pool -> do
    runMigrations cs schema
    now <- getCurrentTime
    rid <- newRunId
    let r =
          NewRun
            { runId = rid,
              serviceName = "svc-" <> schemaText schema,
              command = ["x"],
              namespace = "ns",
              jobName = "job",
              image = Nothing,
              startedAt = now,
              serviceConfig = Aeson.object []
            }
    Pool.use pool (Session.statement r insertRunStatement)
      >>= either (fail . show) pure

-- | Acquire a pool for the schema and assert that an unqualified
--   @SELECT COUNT(*) FROM runs@ (which the pool's initSession hook
--   resolves into @\<schema\>.runs@) returns the expected row count.
verifyCount :: ConnectionString -> Schema -> Int32 -> IO ()
verifyCount cs schema expected =
  bracket (acquirePool cs schema) releasePool $ \pool -> do
    n <-
      Pool.use pool (Session.statement () countRuns)
        >>= either (fail . show) pure
    assertEqual ("rows in " <> show (schemaText schema)) expected n

countRuns :: Statement () Int32
countRuns =
  preparable
    "SELECT COUNT(*)::int FROM runs"
    Encoders.noParams
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int4)))

verifyLedgerCount :: ConnectionString -> Schema -> Int32 -> IO ()
verifyLedgerCount cs schema expected =
  bracket (acquirePool cs schema) releasePool $ \pool -> do
    n <-
      Pool.use pool (Session.statement () countMigrations)
        >>= either (fail . show) pure
    assertEqual ("migration rows in " <> show (schemaText schema)) expected n

countMigrations :: Statement () Int32
countMigrations =
  preparable
    "SELECT COUNT(*)::int FROM migrations WHERE component = 'shiki'"
    Encoders.noParams
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int4)))

-- | Assert that @public@ has no @runs@ table. Acquires a pool whose
--   search_path is @"public", public@ (effectively just @public@) so
--   that an unqualified @runs@ reference would resolve there if it
--   existed. We query @information_schema.tables@ rather than @runs@
--   directly so a non-error empty count is the cleanest signal.
verifyMissingFromPublic :: ConnectionString -> IO ()
verifyMissingFromPublic cs = do
  Right pub <- pure (mkSchema "public")
  bracket (acquirePool cs pub) releasePool $ \pool -> do
    res <- Pool.use pool (Session.statement () existsRunsInPublic)
    case res of
      Left e -> fail ("information_schema probe failed: " <> show e)
      Right 0 -> pure ()
      Right n ->
        fail ("public.runs unexpectedly present (" <> show n <> " info-schema row(s))")

existsRunsInPublic :: Statement () Int32
existsRunsInPublic =
  preparable
    "SELECT COUNT(*)::int FROM information_schema.tables \
    \WHERE table_schema = 'public' AND table_name = 'runs'"
    Encoders.noParams
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int4)))
