-- | Apply the SQL migrations shipped with @shiki-core@. Loads every
--   script from @sql\/migrations\/@ (located at runtime via the
--   @Paths_shiki_core@ data-files mechanism) and runs each through
--   @hasql-migration@, which tracks applied scripts in a
--   @schema_migrations@ table keyed by filename + MD5 checksum.
module Shiki.Persistence.Migration
  ( runMigrations,
    migrationsDirectory,
  )
where

import Data.Text.Encoding qualified as Text.Encoding
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Migration qualified as Migration
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction qualified as Transaction
import Hasql.Transaction.Sessions
  ( IsolationLevel (Serializable),
    Mode (Write),
    transaction,
  )
import Paths_shiki_core qualified as Paths
import Shiki.Persistence.Schema (Schema, quoteSchema, schemaText)
import Shiki.Prelude

-- | Absolute path of the SQL migrations directory bundled with this
--   package, resolved via cabal's @data-files@ machinery.
migrationsDirectory :: IO FilePath
migrationsDirectory = Paths.getDataFileName "sql/migrations"

-- | Apply every unapplied migration script in 'migrationsDirectory'
--   inside the given 'Schema'. The pool's @initSession@ hook (see
--   "Shiki.Persistence.Connection") has already set @search_path@ on the
--   connection, so the @schema_migrations@ table and the unqualified table
--   references in the migration scripts resolve into the configured schema
--   rather than @public@.
--
--   The schema and the @schema_migrations@ table are only created when
--   they are missing. PostgreSQL checks creation privileges before it
--   checks existence, so an unconditional @CREATE SCHEMA IF NOT EXISTS@
--   fails for a role without @CREATE@ on the database even when the schema
--   is already there, and @create table if not exists@ likewise fails
--   without @CREATE@ on the schema. Skipping them lets a restricted role
--   use an already-bootstrapped schema with only @USAGE@ on the schema,
--   @SELECT@ on @schema_migrations@, and @SELECT, INSERT, UPDATE@ on
--   @runs@. Such a role still cannot apply a new migration script (that
--   needs the table owner), so after upgrading shiki run it once as the
--   owning role.
--
--   Throws 'error' on pool/transaction failure; 'hasql-migration' also
--   throws if a previously-applied script's checksum no longer matches
--   what was recorded.
runMigrations :: Pool.Pool -> Schema -> IO ()
runMigrations pool schema = do
  dir <- migrationsDirectory
  scripts <- Migration.loadMigrationsFromDirectory dir
  result <- Pool.use pool (migrationSession schema scripts)
  case result of
    Left poolErr ->
      error ("shiki: migration pool error: " <> show poolErr)
    Right Nothing -> pure ()
    Right (Just merr) ->
      error ("shiki: migration failed: " <> show merr)

migrationSession ::
  Schema ->
  [Migration.MigrationCommand] ->
  Session.Session (Maybe Migration.MigrationError)
migrationSession schema scripts =
  transaction Serializable Write $ do
    (schemaExists, ledgerExists) <-
      Transaction.statement (schemaText schema) bootstrapStateStatement
    unless schemaExists $
      Transaction.sql
        ( Text.Encoding.encodeUtf8
            ("CREATE SCHEMA IF NOT EXISTS " <> quoteSchema schema <> ";")
        )
    let initialization = [Migration.MigrationInitialization | not ledgerExists]
    runFirstError (initialization <> scripts)
  where
    runFirstError [] = pure Nothing
    runFirstError (c : cs) =
      Migration.runMigration c >>= \case
        Just err -> pure (Just err)
        Nothing -> runFirstError cs

-- | Whether the schema, and the @schema_migrations@ table inside it,
--   already exist. Both lookups are qualified by the schema name so a
--   @schema_migrations@ table in another schema of the same database does
--   not count.
bootstrapStateStatement :: Statement Text (Bool, Bool)
bootstrapStateStatement = preparable sql encoder decoder
  where
    sql =
      """
      SELECT
        EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = $1),
        EXISTS (
          SELECT 1 FROM pg_tables
          WHERE schemaname = $1 AND tablename = 'schema_migrations'
        )
      """
    encoder = Encoders.param (Encoders.nonNullable Encoders.text)
    decoder =
      Decoders.singleRow
        ( (,)
            <$> Decoders.column (Decoders.nonNullable Decoders.bool)
            <*> Decoders.column (Decoders.nonNullable Decoders.bool)
        )
