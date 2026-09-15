module Shiki.Persistence.RestrictedRoleSpec (tests) where

import Control.Exception (bracket)
import Data.Aeson qualified as Aeson
import EphemeralPg qualified as EpPg
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Shiki.Persistence.Connection
  ( ConnectionString (..),
    acquirePool,
    releasePool,
  )
import Shiki.Persistence.Migration (runMigrations)
import Shiki.Persistence.Run
  ( NewRun (..),
    RunId,
    insertRunStatement,
    newRunId,
    touchRunWatchedStatement,
  )
import Shiki.Persistence.Schema (Schema, quoteSchema)
import Shiki.Persistence.TestPg (freshSchema)
import Shiki.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase)

tests :: TestTree
tests =
  testGroup
    "Shiki.Persistence.Migration (restricted role)"
    [ testCase "a role with only DML grants can use a bootstrapped schema" $ do
        schema <- freshSchema
        result <- EpPg.with $ \db -> do
          let owner = ConnectionString (EpPg.connectionString db)
              -- libpq keeps the last occurrence of a keyword, so this
              -- overrides the ephemeral superuser.
              restricted =
                ConnectionString (EpPg.connectionString db <> " user=shiki_restricted")
          withPool owner schema $ \pool -> do
            runMigrations pool schema
            exec pool (restrictedRoleGrants schema)
          withPool restricted schema $ \pool -> do
            -- Guard against a vacuous pass: the role must really lack
            -- database-level CREATE, which is what the old unconditional
            -- CREATE SCHEMA IF NOT EXISTS tripped over.
            Pool.use pool (Session.script "CREATE SCHEMA shiki_probe;") >>= \case
              Left _ -> pure ()
              Right () -> assertFailure "restricted role unexpectedly has CREATE on the database"
            runMigrations pool schema
            rid <- insertOneRun pool
            Pool.use pool (Session.statement rid touchRunWatchedStatement)
              >>= either (fail . show) pure
        case result of
          Right () -> pure ()
          Left err ->
            fail ("ephemeral-pg failed to start: " <> show (EpPg.renderStartError err))
    ]

-- | The grants an operator gives a role that should only record runs in
--   an already-bootstrapped schema.
restrictedRoleGrants :: Schema -> Text
restrictedRoleGrants schema =
  mconcat
    [ "CREATE ROLE shiki_restricted LOGIN;",
      "GRANT USAGE ON SCHEMA " <> s <> " TO shiki_restricted;",
      "GRANT SELECT ON " <> s <> ".schema_migrations TO shiki_restricted;",
      "GRANT SELECT, INSERT, UPDATE ON " <> s <> ".runs TO shiki_restricted;"
    ]
  where
    s = quoteSchema schema

withPool :: ConnectionString -> Schema -> (Pool.Pool -> IO a) -> IO a
withPool cs schema = bracket (acquirePool cs schema) releasePool

exec :: Pool.Pool -> Text -> IO ()
exec pool sql = Pool.use pool (Session.script sql) >>= either (fail . show) pure

insertOneRun :: Pool.Pool -> IO RunId
insertOneRun pool = do
  now <- getCurrentTime
  rid <- newRunId
  let r =
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
  Pool.use pool (Session.statement r insertRunStatement)
    >>= either (fail . show) pure
  pure rid
