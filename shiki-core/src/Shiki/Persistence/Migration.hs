{-# LANGUAGE TemplateHaskell #-}
{-# OPTIONS_GHC -fplugin=Database.PostgreSQL.Migrate.Embed.RecompilePlugin #-}

-- | Define and apply the SQL migrations shipped with @shiki-core@.
--
-- The ordered manifest and exact SQL bytes are embedded at compile time. Production
-- execution therefore does not depend on runtime file discovery, while
-- 'migrationsDirectory' remains available to integration tests that construct legacy
-- @hasql-migration@ ledgers from the released SQL files.
module Shiki.Persistence.Migration
  ( runMigrations,
    MigrationFailure (..),
    renderMigrationFailure,
    migrationsDirectory,
  )
where

import Control.Exception (bracket)
import Control.Monad.Except (ExceptT (..), runExceptT)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.Functor.Contravariant ((>$<))
import Data.Int (Int64)
import Data.List qualified as List
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as Text
import Database.PostgreSQL.Migrate
  ( ConnectionProvider,
    DefinitionError,
    EvidenceRequirement (Evidence),
    HistoryMapping,
    MigrationError,
    MigrationPlan,
    PayloadRelation (SamePayload),
    RunOptions,
    connectionProviderFromSettings,
    defaultImportOptions,
    defaultRunOptions,
    historyMapping,
    ledgerConfig,
    migrationComponentFromEmbeddedSql,
    migrationId,
    migrationPlan,
    runMigrationPlanWith,
    withImportRunOptions,
    withLedger,
  )
import Database.PostgreSQL.Migrate.Embed (embedMigrationManifest)
import Database.PostgreSQL.Migrate.History.HasqlMigration
  ( HasqlMigrationDefinitionError,
    HasqlMigrationImportError,
    HasqlMigrationSourceConfig,
    hasqlMigrationEvidenceKey,
    hasqlMigrationSourceConfig,
    importHasqlMigrationHistory,
    qualifiedTable,
  )
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Settings
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Errors qualified as Errors
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
import Paths_shiki_core qualified as Paths
import Shiki.Persistence.Connection (ConnectionString (..))
import Shiki.Persistence.Schema (Schema, quoteSchema, schemaText)
import Shiki.Prelude
import System.FilePath (dropExtension)

-- | Absolute path of the SQL migrations directory bundled with this package. The
-- production runner uses embedded bytes; this path exists for migration-transition tests.
migrationsDirectory :: IO FilePath
migrationsDirectory = Paths.getDataFileName "sql/migrations"

embeddedMigrationEntries :: NonEmpty (FilePath, ByteString)
embeddedMigrationEntries = $(embedMigrationManifest "sql/migrations/manifest")

shikiMigrationPlan :: MigrationPlan
shikiMigrationPlan =
  case migrationComponentFromEmbeddedSql "shiki" Set.empty embeddedMigrationEntries of
    Left definitionError -> invalidEmbeddedPlan definitionError
    Right component ->
      case migrationPlan (component :| []) of
        Left planError -> invalidEmbeddedPlan planError
        Right plan -> plan
  where
    invalidEmbeddedPlan err =
      error ("invalid embedded Shiki migration plan: " <> show err)

-- | Apply the embedded Shiki migration plan inside the selected schema.
--
-- A dedicated connection receives a right-precedence libpq @options@ setting so the
-- unchanged, unqualified SQL targets @<schema>,public@. Before the normal pg-migrate run,
-- a valid non-empty prefix in the predecessor @schema_migrations@ table is imported as
-- already applied. The predecessor table is retained as recovery evidence.
--
-- Every way this can fail comes back as @Left@ so the caller decides how to
-- report it; nothing here throws or exits. 'Shiki.Cli.Env.withCliEnv' turns a
-- 'BootstrapConnectionFailed' into @shiki: cannot connect to the database: …@
-- and anything else into @shiki: migration failed for schema …@.
runMigrations :: ConnectionString -> Schema -> IO (Either MigrationFailure ())
runMigrations cs schema = runExceptT $ do
  let settings = migrationSettings cs schema
      provider = connectionProviderFromSettings settings
  runOptions <- ExceptT (pure (migrationRunOptions schema))
  decision <- ExceptT (probeLegacyHistory settings schema)
  case decision of
    NoLegacyImport -> pure ()
    ImportLegacyHistory filenames ->
      ExceptT (importLegacyHistory provider runOptions schema filenames)
  void . ExceptT $
    first MigrationExecutionFailed
      <$> runMigrationPlanWith runOptions provider shikiMigrationPlan

migrationSettings :: ConnectionString -> Schema -> Settings.Settings
migrationSettings (ConnectionString cs) schema =
  Settings.connectionString cs
    <> Settings.other
      "options"
      ("-csearch_path=" <> schemaText schema <> ",public")

migrationRunOptions :: Schema -> Either MigrationFailure RunOptions
migrationRunOptions schema =
  case ledgerConfig (schemaText schema) 0x7368696B695F6D67 of
    Left definitionError -> Left (LedgerDefinitionFailed definitionError)
    Right config -> Right (withLedger config defaultRunOptions)

data LegacyHistoryDecision
  = NoLegacyImport
  | ImportLegacyHistory !(NonEmpty FilePath)

-- | Why 'runMigrations' could not bring a schema up to date. Exported so the
-- CLI can tell "the database is unreachable" ('BootstrapConnectionFailed')
-- apart from every other migration problem and word its message accordingly.
data MigrationFailure
  = BootstrapConnectionFailed !Errors.ConnectionError
  | BootstrapSessionFailed !Errors.SessionError
  | LegacyHistoryNotPrefix ![FilePath] ![FilePath]
  | LedgerDefinitionFailed !DefinitionError
  | LegacyImportDefinitionFailed !Text
  | LegacyImportFailed !HasqlMigrationImportError
  | MigrationExecutionFailed !MigrationError
  deriving stock (Generic, Show)

probeLegacyHistory ::
  Settings.Settings ->
  Schema ->
  IO (Either MigrationFailure LegacyHistoryDecision)
probeLegacyHistory settings schema = do
  acquired <- Connection.acquire settings
  case acquired of
    Left connectionError ->
      pure (Left (BootstrapConnectionFailed connectionError))
    Right connection ->
      bracket (pure connection) Connection.release $ \openConnection -> do
        Connection.use openConnection (legacyHistoryProbeSession schema) >>= \case
          Left sessionError -> pure (Left (BootstrapSessionFailed sessionError))
          Right Nothing -> pure (Right NoLegacyImport)
          Right (Just observed) -> pure (validateLegacyPrefix observed)

legacyHistoryProbeSession :: Schema -> Session.Session (Maybe [FilePath])
legacyHistoryProbeSession schema = do
  targetLedgerExists <-
    Session.statement
      (schemaText schema, "ledger_metadata")
      tableExistsStatement
  targetRowCount <-
    if targetLedgerExists
      then Session.statement () (targetMigrationCountStatement schema)
      else pure 0
  if targetRowCount > 0
    then pure Nothing
    else do
      sourceLedgerExists <-
        Session.statement
          (schemaText schema, "schema_migrations")
          tableExistsStatement
      if sourceLedgerExists
        then Just . fmap Text.unpack <$> Session.statement () (legacyFilenamesStatement schema)
        else pure Nothing

validateLegacyPrefix :: [FilePath] -> Either MigrationFailure LegacyHistoryDecision
validateLegacyPrefix [] = Right NoLegacyImport
validateLegacyPrefix observed
  | observed `List.isPrefixOf` expected =
      case NonEmpty.nonEmpty observed of
        Nothing -> Right NoLegacyImport
        Just filenames -> Right (ImportLegacyHistory filenames)
  | otherwise = Left (LegacyHistoryNotPrefix expected observed)
  where
    expected = fst <$> NonEmpty.toList embeddedMigrationEntries

importLegacyHistory ::
  ConnectionProvider ->
  RunOptions ->
  Schema ->
  NonEmpty FilePath ->
  IO (Either MigrationFailure ())
importLegacyHistory provider runOptions schema filenames =
  case legacyImportDefinition provider schema filenames of
    Left definitionError -> pure (Left definitionError)
    Right (sourceConfig, mappings) ->
      importHasqlMigrationHistory
        (withImportRunOptions runOptions defaultImportOptions)
        sourceConfig
        provider
        shikiMigrationPlan
        mappings
        >>= pure . either (Left . LegacyImportFailed) (const (Right ()))

legacyImportDefinition ::
  ConnectionProvider ->
  Schema ->
  NonEmpty FilePath ->
  Either MigrationFailure (HasqlMigrationSourceConfig, NonEmpty HistoryMapping)
legacyImportDefinition provider schema filenames = do
  sourceTable <-
    mapLegacyDefinition
      (qualifiedTable (schemaText schema <> ".schema_migrations"))
  sourceConfig <-
    mapLegacyDefinition
      ( hasqlMigrationSourceConfig
          provider
          sourceTable
          filenames
          True
          (Map.fromList (NonEmpty.toList embeddedMigrationEntries))
          []
          "Import verified Shiki hasql-migration history"
      )
  mappings <- traverse legacyMapping filenames
  pure (sourceConfig, mappings)

legacyMapping :: FilePath -> Either MigrationFailure HistoryMapping
legacyMapping filename = do
  target <-
    case migrationId "shiki" (Text.pack (dropExtension filename)) of
      Left definitionError ->
        Left (LegacyImportDefinitionFailed (Text.pack (show definitionError)))
      Right migration -> Right migration
  evidence <- mapLegacyDefinition (hasqlMigrationEvidenceKey filename)
  pure (historyMapping target (Evidence evidence) (SamePayload evidence))

mapLegacyDefinition ::
  Either HasqlMigrationDefinitionError value ->
  Either MigrationFailure value
mapLegacyDefinition = \case
  Left definitionError ->
    Left (LegacyImportDefinitionFailed (Text.pack (show definitionError)))
  Right value -> Right value

-- | A human-readable description of one migration failure. It carries no
-- @shiki: @ prefix and no schema name; 'Shiki.Error.renderShikiError' adds
-- both when the CLI reports it.
renderMigrationFailure :: MigrationFailure -> Text
renderMigrationFailure =
  Text.pack . \case
    BootstrapConnectionFailed connectionError ->
      "could not inspect migration history: " <> show connectionError
    BootstrapSessionFailed sessionError ->
      "could not inspect migration history: " <> show sessionError
    LegacyHistoryNotPrefix expected observed ->
      "legacy schema_migrations filenames are not an ordered prefix; expected prefix of "
        <> show expected
        <> ", observed "
        <> show observed
    LedgerDefinitionFailed definitionError ->
      "invalid pg-migrate ledger configuration: " <> show definitionError
    LegacyImportDefinitionFailed definitionError ->
      "invalid legacy-history import definition: " <> Text.unpack definitionError
    LegacyImportFailed importError ->
      "legacy-history import failed: " <> show importError
    MigrationExecutionFailed executionError ->
      "pg-migrate execution failed: " <> show executionError

tableExistsStatement :: Statement (Text, Text) Bool
tableExistsStatement = preparable sql encoder decoder
  where
    sql =
      "SELECT EXISTS (\
      \SELECT 1 FROM information_schema.tables \
      \WHERE table_schema = $1 AND table_name = $2)"
    encoder =
      (fst >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> (snd >$< Encoders.param (Encoders.nonNullable Encoders.text))
    decoder = Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.bool))

targetMigrationCountStatement :: Schema -> Statement () Int64
targetMigrationCountStatement schema =
  preparable
    ( "SELECT COUNT(*)::bigint FROM "
        <> quoteSchema schema
        <> ".migrations WHERE component = 'shiki'"
    )
    Encoders.noParams
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))

legacyFilenamesStatement :: Schema -> Statement () [Text]
legacyFilenamesStatement schema =
  preparable
    ( "SELECT filename FROM "
        <> quoteSchema schema
        <> ".schema_migrations ORDER BY executed_at, filename"
    )
    Encoders.noParams
    (Decoders.rowList (Decoders.column (Decoders.nonNullable Decoders.text)))
