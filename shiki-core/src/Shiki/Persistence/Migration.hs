-- | Apply the SQL migrations shipped with @shiki-core@. Loads every
--   script from @sql\/migrations\/@ (located at runtime via the
--   @Paths_shiki_core@ data-files mechanism) and runs each through
--   @hasql-migration@, which tracks applied scripts in a
--   @schema_migrations@ table keyed by filename + MD5 checksum.
module Shiki.Persistence.Migration
  ( runMigrations
  , migrationsDirectory
  ) where

import "hasql-migration" Hasql.Migration qualified as Migration
import "hasql-pool" Hasql.Pool qualified as Pool
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

-- | Apply every unapplied migration script in 'migrationsDirectory'.
--   Throws 'error' on pool/transaction failure; 'hasql-migration' also
--   throws if a previously-applied script's checksum no longer matches
--   what was recorded.
runMigrations :: Pool.Pool -> IO ()
runMigrations pool = do
  dir <- migrationsDirectory
  scripts <- Migration.loadMigrationsFromDirectory dir
  let cmds = Migration.MigrationInitialization : scripts
  result <- Pool.use pool (migrationSession cmds)
  case result of
    Left poolErr ->
      error ("shiki: migration pool error: " <> show poolErr)
    Right Nothing -> pure ()
    Right (Just merr) ->
      error ("shiki: migration failed: " <> show merr)

migrationSession
  :: [Migration.MigrationCommand]
  -> Session.Session (Maybe Migration.MigrationError)
migrationSession scripts =
  transaction Serializable Write (runFirstError scripts)
  where
    runFirstError [] = pure Nothing
    runFirstError (c : cs) =
      Migration.runMigration c >>= \case
        Just err -> pure (Just err)
        Nothing -> runFirstError cs

