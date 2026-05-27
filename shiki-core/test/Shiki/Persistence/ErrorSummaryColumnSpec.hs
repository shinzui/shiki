-- | Assert that migration @002-add-error-summary.sql@ lands the two new
--   columns in the configured (test-private) schema, not in @public@ and
--   not silently dropped.
module Shiki.Persistence.ErrorSummaryColumnSpec (tests) where

import Shiki.Prelude

import Shiki.Persistence.Connection
  ( ConnectionString (..)
  , acquirePool
  , releasePool
  )
import Shiki.Persistence.Migration (runMigrations)
import Shiki.Persistence.Schema (schemaText)
import Shiki.Persistence.TestPg (freshSchema)

import "base" Control.Exception (bracket)
import "base" Data.Functor.Contravariant ((>$<))
import "base" Data.Int (Int32)
import "ephemeral-pg" EphemeralPg qualified as EpPg
import "hasql" Hasql.Decoders qualified as Decoders
import "hasql" Hasql.Encoders qualified as Encoders
import "hasql" Hasql.Session qualified as Session
import "hasql" Hasql.Statement (Statement, preparable)
import "hasql-pool" Hasql.Pool qualified as Pool
import "tasty" Test.Tasty (TestTree, testGroup)
import "tasty-hunit" Test.Tasty.HUnit (assertEqual, testCase)

tests :: TestTree
tests =
  testGroup "Shiki.Persistence (error_summary migration)"
    [ testCase "error_summary and error_summary_source land in the configured schema" $ do
        schema <- freshSchema
        result <- EpPg.with $ \db -> do
          let cs = ConnectionString (EpPg.connectionString db)
          bracket (acquirePool cs schema) releasePool $ \pool -> do
            runMigrations pool schema
            n <-
              Pool.use pool (Session.statement (schemaText schema) errorSummaryColumnCount)
                >>= either (fail . show) pure
            assertEqual "two error_summary columns present" 2 n
        case result of
          Right () -> pure ()
          Left err ->
            fail ("ephemeral-pg failed to start: " <> show (EpPg.renderStartError err))
    ]

errorSummaryColumnCount :: Statement Text Int32
errorSummaryColumnCount =
  preparable sql encoder decoder
  where
    sql =
      "SELECT COUNT(*)::int FROM information_schema.columns \
      \WHERE table_schema = $1 AND table_name = 'runs' \
      \  AND column_name IN ('error_summary', 'error_summary_source')"
    encoder = id >$< Encoders.param (Encoders.nonNullable Encoders.text)
    decoder = Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int4))
