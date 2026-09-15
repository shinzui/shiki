module Shiki.Persistence.MigrationSpec (tests) where

import Control.Exception (bracket)
import Data.Functor.Contravariant ((>$<))
import Data.Int (Int32, Int64)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.IO qualified as Text.IO
import Database.PostgreSQL.Migrate
  ( connectionProviderFromSettings,
    defaultRunOptions,
    ledgerConfig,
    migrationComponentFromEmbeddedSql,
    migrationPlan,
    runMigrationPlanWith,
    withLedger,
  )
import EphemeralPg qualified as EpPg
import Hasql.Connection.Settings qualified as Settings
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
import Shiki.Persistence.Migration
  ( MigrationFailure,
    migrationsDirectory,
    renderMigrationFailure,
    runMigrations,
  )
import Shiki.Persistence.Schema (Schema, mkSchema, quoteSchema, schemaText)
import Shiki.Prelude
import System.FilePath (dropExtension, (</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit
  ( assertBool,
    assertEqual,
    assertFailure,
    testCase,
  )

tests :: TestTree
tests =
  testGroup
    "Shiki.Persistence.Migration"
    [ testCase "fresh installation and repeat execution are idempotent" testFreshInstall,
      testCase "imports each valid legacy prefix and applies only its suffix" testLegacyPrefixes,
      testCase "recovers when the pg-migrate ledger was initialized but stayed empty" testInitializedEmptyLedger,
      testCase "rejects a legacy checksum mismatch before trusting target history" testChecksumMismatch,
      testCase "rejects unknown, gapped, and reordered legacy histories" testInvalidPrefixes
    ]

testFreshInstall :: IO ()
testFreshInstall =
  withEphemeralDatabase $ \cs -> do
    schema <- requireSchema "shiki_migration_fresh"
    migrateOrFail cs schema
    withPool cs schema $ \pool -> do
      assertCurrentLedger pool
      tableCount <- query pool ledgerTableCountStatement ()
      assertEqual "all four pg-migrate ledger tables exist" 4 tableCount
      sourceExists <- query pool tableExistsStatement "schema_migrations"
      assertEqual "fresh install has no predecessor ledger" False sourceExists
      before <- query pool finishedAtStatement ()
      migrateOrFail cs schema
      after <- query pool finishedAtStatement ()
      assertEqual "repeat run preserves applied timestamps" before after

testLegacyPrefixes :: IO ()
testLegacyPrefixes =
  withEphemeralDatabase $ \cs ->
    mapM_ (exercisePrefix cs) [1 .. length legacyMigrations]
  where
    exercisePrefix cs prefixLength = do
      schema <- requireSchema ("shiki_migration_prefix_" <> Text.pack (show prefixLength))
      prepareLegacyHistory cs schema (take prefixLength legacyMigrations) True
      migrateOrFail cs schema
      withPool cs schema $ \pool -> do
        assertCurrentLedger pool
        imported <- query pool importedMigrationsStatement ()
        assertEqual
          ("imported prefix length " <> show prefixLength)
          (Text.pack . dropExtension . fst <$> take prefixLength legacyMigrations)
          imported
        sourceExists <- query pool tableExistsStatement "schema_migrations"
        assertEqual "predecessor evidence is retained" True sourceExists
        before <- query pool finishedAtStatement ()
        migrateOrFail cs schema
        after <- query pool finishedAtStatement ()
        assertEqual "repeat conversion preserves applied timestamps" before after

testInitializedEmptyLedger :: IO ()
testInitializedEmptyLedger =
  withEphemeralDatabase $ \cs -> do
    schema <- requireSchema "shiki_migration_interrupted"
    prepareLegacyHistory cs schema (take 2 legacyMigrations) True
    initializeEmptyLedger cs schema
    withPool cs schema $ \pool -> do
      before <- targetMigrationCount pool
      assertEqual "failed bootstrap left no target rows" 0 before
    migrateOrFail cs schema
    withPool cs schema $ \pool -> do
      assertCurrentLedger pool
      imported <- query pool importedMigrationsStatement ()
      assertEqual
        "the retained legacy prefix was imported on retry"
        ["001-create-runs", "002-add-error-summary"]
        imported

testChecksumMismatch :: IO ()
testChecksumMismatch =
  withEphemeralDatabase $ \cs -> do
    schema <- requireSchema "shiki_migration_bad_checksum"
    let (firstFilename, _) = firstLegacyMigration
    prepareLegacyHistory cs schema [(firstFilename, "not-the-real-md5")] True
    expectFailureContaining "HasqlMigrationChecksumMismatch" (runMigrations cs schema)
    withPool cs schema $ \pool -> do
      targetRows <- targetMigrationCount pool
      assertEqual "checksum rejection writes no trusted target rows" 0 targetRows

testInvalidPrefixes :: IO ()
testInvalidPrefixes =
  withEphemeralDatabase $ \cs -> do
    let invalidCases =
          [ ("unknown", [("999-unknown.sql", "irrelevant")]),
            ("gap", [firstLegacyMigration, thirdLegacyMigration]),
            ("reordered", [secondLegacyMigration, firstLegacyMigration])
          ]
    mapM_
      ( \(caseName, rows) -> do
          schema <- requireSchema ("shiki_migration_" <> caseName)
          prepareLegacyHistory cs schema rows False
          expectFailureContaining "not an ordered prefix" (runMigrations cs schema)
          withPool cs schema $ \pool -> do
            targetRows <- targetMigrationCount pool
            assertEqual (Text.unpack caseName <> " writes no target history") 0 targetRows
      )
      invalidCases

legacyMigrations :: [(FilePath, Text)]
legacyMigrations =
  [firstLegacyMigration, secondLegacyMigration, thirdLegacyMigration]

firstLegacyMigration, secondLegacyMigration, thirdLegacyMigration :: (FilePath, Text)
firstLegacyMigration = ("001-create-runs.sql", "7Hetr6wmYoX7OrfnnzmURg==")
secondLegacyMigration = ("002-add-error-summary.sql", "7hHk4MldKAU/1OSXG9HWGA==")
thirdLegacyMigration = ("003-add-last-watched-at.sql", "OhHriiHjXU2+wmEZULMyRg==")

prepareLegacyHistory ::
  ConnectionString ->
  Schema ->
  [(FilePath, Text)] ->
  Bool ->
  IO ()
prepareLegacyHistory cs schema rows executeSql = do
  directory <- migrationsDirectory
  withPool cs schema $ \pool -> do
    exec
      pool
      ( "CREATE SCHEMA "
          <> quoteSchema schema
          <> "; CREATE TABLE schema_migrations ("
          <> "filename text NOT NULL, checksum text NOT NULL, "
          <> "executed_at timestamp without time zone NOT NULL DEFAULT now());"
      )
    mapM_
      ( \(position, (filename, checksum)) -> do
          when executeSql $ Text.IO.readFile (directory </> filename) >>= exec pool
          query
            pool
            insertLegacyMigrationStatement
            (Text.pack filename, checksum, position)
      )
      (zip [1 ..] rows)

initializeEmptyLedger :: ConnectionString -> Schema -> IO ()
initializeEmptyLedger cs schema = do
  let settings = migrationSettings cs schema
      provider = connectionProviderFromSettings settings
      component =
        requireRight
          ( migrationComponentFromEmbeddedSql
              "shiki-bootstrap-probe"
              Set.empty
              (("001-deliberate-failure.sql", "SELECT * FROM shiki_table_that_does_not_exist;") :| [])
          )
      plan = requireRight (migrationPlan (component :| []))
      config = requireRight (ledgerConfig (schemaText schema) 0x7368696B695F6D67)
  runMigrationPlanWith (withLedger config defaultRunOptions) provider plan >>= \case
    Left _ -> pure ()
    Right _ -> assertFailure "deliberately failing bootstrap migration unexpectedly succeeded"

migrationSettings :: ConnectionString -> Schema -> Settings.Settings
migrationSettings (ConnectionString cs) schema =
  Settings.connectionString cs
    <> Settings.other "options" ("-csearch_path=" <> schemaText schema <> ",public")

assertCurrentLedger :: Pool.Pool -> IO ()
assertCurrentLedger pool = do
  actual <- query pool migrationFactsStatement ()
  assertEqual
    "all Shiki migrations are applied in manifest order"
    [ ("001-create-runs", "applied"),
      ("002-add-error-summary", "applied"),
      ("003-add-last-watched-at", "applied")
    ]
    actual

targetMigrationCount :: Pool.Pool -> IO Int64
targetMigrationCount pool = do
  exists <- query pool tableExistsStatement "migrations"
  if exists then query pool targetMigrationCountStatement () else pure 0

withEphemeralDatabase :: (ConnectionString -> IO ()) -> IO ()
withEphemeralDatabase action = do
  result <- EpPg.with (action . ConnectionString . EpPg.connectionString)
  case result of
    Right () -> pure ()
    Left startError ->
      fail ("ephemeral-pg failed to start: " <> show (EpPg.renderStartError startError))

withPool :: ConnectionString -> Schema -> (Pool.Pool -> IO a) -> IO a
withPool cs schema = bracket (acquirePool cs schema) releasePool

requireSchema :: Text -> IO Schema
requireSchema name =
  case mkSchema name of
    Left validationError -> fail (Text.unpack validationError)
    Right schema -> pure schema

requireRight :: (Show error) => Either error value -> value
requireRight = either (error . show) id

-- | 'runMigrations' where the test expects failure: assert on the rendered
--   'MigrationFailure' rather than on the text of a thrown exception.
expectFailureContaining :: Text -> IO (Either MigrationFailure ()) -> IO ()
expectFailureContaining expected action =
  action >>= \case
    Left actual ->
      assertBool
        ( "expected failure containing "
            <> show expected
            <> ", got "
            <> show (renderMigrationFailure actual)
        )
        (expected `Text.isInfixOf` renderMigrationFailure actual)
    Right () -> assertFailure ("expected failure containing " <> show expected)

-- | 'runMigrations' where the test expects success.
migrateOrFail :: ConnectionString -> Schema -> IO ()
migrateOrFail cs schema =
  runMigrations cs schema
    >>= either (fail . Text.unpack . renderMigrationFailure) pure

exec :: Pool.Pool -> Text -> IO ()
exec pool sql =
  Pool.use pool (Session.script sql) >>= either (fail . show) pure

query :: Pool.Pool -> Statement params result -> params -> IO result
query pool statement params =
  Pool.use pool (Session.statement params statement) >>= either (fail . show) pure

insertLegacyMigrationStatement :: Statement (Text, Text, Int32) ()
insertLegacyMigrationStatement = preparable sql encoder Decoders.noResult
  where
    sql =
      "INSERT INTO schema_migrations (filename, checksum, executed_at) "
        <> "VALUES ($1, $2, TIMESTAMP '2026-01-01 00:00:00' + $3 * INTERVAL '1 second')"
    encoder =
      ((\(filename, _, _) -> filename) >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> ((\(_, checksum, _) -> checksum) >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> ((\(_, _, position) -> position) >$< Encoders.param (Encoders.nonNullable Encoders.int4))

migrationFactsStatement :: Statement () [(Text, Text)]
migrationFactsStatement =
  preparable
    "SELECT migration, status FROM migrations WHERE component = 'shiki' ORDER BY position"
    Encoders.noParams
    ( Decoders.rowList
        ( (,)
            <$> Decoders.column (Decoders.nonNullable Decoders.text)
            <*> Decoders.column (Decoders.nonNullable Decoders.text)
        )
    )

importedMigrationsStatement :: Statement () [Text]
importedMigrationsStatement =
  preparable
    "SELECT migration FROM history_imports WHERE component = 'shiki' ORDER BY migration"
    Encoders.noParams
    (Decoders.rowList (Decoders.column (Decoders.nonNullable Decoders.text)))

finishedAtStatement :: Statement () [(Text, UTCTime)]
finishedAtStatement =
  preparable
    "SELECT migration, finished_at FROM migrations WHERE component = 'shiki' ORDER BY position"
    Encoders.noParams
    ( Decoders.rowList
        ( (,)
            <$> Decoders.column (Decoders.nonNullable Decoders.text)
            <*> Decoders.column (Decoders.nonNullable Decoders.timestamptz)
        )
    )

ledgerTableCountStatement :: Statement () Int32
ledgerTableCountStatement =
  preparable
    ( "SELECT COUNT(*)::int FROM information_schema.tables "
        <> "WHERE table_schema = current_schema() "
        <> "AND table_name IN ('ledger_metadata', 'migrations', 'history_imports', 'repairs')"
    )
    Encoders.noParams
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int4)))

tableExistsStatement :: Statement Text Bool
tableExistsStatement =
  preparable
    ( "SELECT EXISTS (SELECT 1 FROM information_schema.tables "
        <> "WHERE table_schema = current_schema() AND table_name = $1)"
    )
    (Encoders.param (Encoders.nonNullable Encoders.text))
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.bool)))

targetMigrationCountStatement :: Statement () Int64
targetMigrationCountStatement =
  preparable
    "SELECT COUNT(*)::bigint FROM migrations WHERE component = 'shiki'"
    Encoders.noParams
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))
