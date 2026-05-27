-- | Apply the SQL migrations shipped with @shiki-core@. Loads every
--   script from @sql\/migrations\/@ (located at runtime via the
--   @Paths_shiki_core@ data-files mechanism) and runs each through
--   @hasql-migration@, which tracks applied scripts in a
--   @schema_migrations@ table keyed by filename + MD5 checksum.
module Shiki.Persistence.Migration
  ( runMigrations
  , migrationsDirectory
  ) where

import Shiki.Persistence.Schema (Schema, quoteSchema)

import "text" Data.Text.Encoding qualified as Text.Encoding
import "hasql-migration" Hasql.Migration qualified as Migration
import "hasql-pool" Hasql.Pool qualified as Pool
import "hasql-transaction" Hasql.Transaction qualified as Transaction
import "hasql-transaction" Hasql.Transaction.Sessions
  ( IsolationLevel (Serializable)
  , Mode (Write)
  , transaction
  )
import Paths_shiki_core qualified as Paths
import "hasql" Hasql.Session qualified as Session

-- | Absolute path of the SQL migrations directory bundled with this
--   package, resolved via cabal's @data-files@ machinery.
migrationsDirectory :: IO FilePath
migrationsDirectory = Paths.getDataFileName "sql/migrations"

-- | Apply every unapplied migration script in 'migrationsDirectory'
--   inside the given 'Schema'. The first thing the migration transaction
--   does is @CREATE SCHEMA IF NOT EXISTS \"\<schema\>\"@ so the
--   @schema_migrations@ table that @hasql-migration@ subsequently creates
--   lands inside the configured schema rather than @public@. The pool's
--   @initSession@ hook (see "Shiki.Persistence.Connection") has already
--   set @search_path@ on the connection, so unqualified table references
--   in the migration scripts resolve correctly.
--
--   Throws 'error' on pool/transaction failure; 'hasql-migration' also
--   throws if a previously-applied script's checksum no longer matches
--   what was recorded.
runMigrations :: Pool.Pool -> Schema -> IO ()
runMigrations pool schema = do
  dir <- migrationsDirectory
  scripts <- Migration.loadMigrationsFromDirectory dir
  let cmds = Migration.MigrationInitialization : scripts
  result <- Pool.use pool (migrationSession schema cmds)
  case result of
    Left poolErr ->
      error ("shiki: migration pool error: " <> show poolErr)
    Right Nothing -> pure ()
    Right (Just merr) ->
      error ("shiki: migration failed: " <> show merr)

migrationSession
  :: Schema
  -> [Migration.MigrationCommand]
  -> Session.Session (Maybe Migration.MigrationError)
migrationSession schema scripts =
  transaction Serializable Write $ do
    Transaction.sql
      ( Text.Encoding.encodeUtf8
          ("CREATE SCHEMA IF NOT EXISTS " <> quoteSchema schema <> ";")
      )
    runFirstError scripts
  where
    runFirstError [] = pure Nothing
    runFirstError (c : cs) =
      Migration.runMigration c >>= \case
        Just err -> pure (Just err)
        Nothing -> runFirstError cs
