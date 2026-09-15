-- | Shared per-test ephemeral-Postgres helper. Each call to
--   'withSchemaPool' allocates a fresh, randomly-named schema so that
--   concurrent test runs do not collide and so the M6 isolation test can
--   trust that the existing tests no longer hardcode the default schema.
module Shiki.Persistence.TestPg
  ( freshSchema,
    migrateOrFail,
    withSchemaPool,
  )
where

import Control.Exception (bracket)
import Data.Text qualified as Text
import Data.UUID qualified as UUID
import Data.UUID.V4 qualified as UUIDv4
import EphemeralPg qualified as EpPg
import Hasql.Pool qualified as Pool
import Shiki.Persistence.Connection
  ( ConnectionString (..),
    acquirePool,
    releasePool,
  )
import Shiki.Persistence.Migration (renderMigrationFailure, runMigrations)
import Shiki.Persistence.Schema (Schema, mkSchema)

-- | A fresh, randomly-named schema each call. Useful for test isolation.
--   The name is always prefixed with @shiki_test_@ so a leftover schema
--   is obviously test detritus, and the hyphens in the UUID text are
--   stripped because 'mkSchema' rejects them.
freshSchema :: IO Schema
freshSchema = do
  u <- UUIDv4.nextRandom
  let raw = "shiki_test_" <> Text.filter (/= '-') (UUID.toText u)
  case mkSchema raw of
    Right s -> pure s
    Left e -> error ("freshSchema: unexpectedly invalid schema: " <> Text.unpack e)

-- | Spin up an ephemeral Postgres, allocate a fresh schema, acquire a
--   pool, run migrations, hand the pool to the action.
withSchemaPool :: (Pool.Pool -> IO ()) -> IO ()
withSchemaPool action = do
  schema <- freshSchema
  result <- EpPg.with $ \db ->
    bracket
      (acquirePool (ConnectionString (EpPg.connectionString db)) schema)
      releasePool
      (\pool -> migrateOrFail (ConnectionString (EpPg.connectionString db)) schema *> action pool)
  case result of
    Right () -> pure ()
    Left err ->
      fail ("ephemeral-pg failed to start: " <> show (EpPg.renderStartError err))

-- | 'runMigrations' where the test expects success: a 'Left' aborts the case
--   with the rendered failure instead of being silently ignored.
migrateOrFail :: ConnectionString -> Schema -> IO ()
migrateOrFail cs schema =
  runMigrations cs schema
    >>= either (fail . Text.unpack . renderMigrationFailure) pure
