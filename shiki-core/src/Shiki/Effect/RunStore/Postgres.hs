-- | The production interpreter for "Shiki.Effect.RunStore": hasql statements
--   against a connection pool.
--
--   Every operation names itself, so a failed statement becomes
--   @shiki: database error during \<operation\>: \<message\>@ instead of the
--   @error@ call four different modules used to make. A pool-level connection
--   or acquisition failure is reported as 'DatabaseUnavailable' instead,
--   because that is not a problem with the statement.
module Shiki.Effect.RunStore.Postgres
  ( runRunStorePostgres,
    withRunStore,
  )
where

import Effectful (Eff, IOE, type (:>))
import Effectful.Dispatch.Dynamic (interpret_)
import Effectful.Error.Static (Error, throwError)
import Effectful.Exception qualified as Exc
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (Statement)
import Shiki.Effect.RunStore (RunStore (..))
import Shiki.Error
  ( ShikiError (..),
    StoreError (..),
    renderConnectionError,
    renderUsageError,
  )
import Shiki.Persistence.Connection (ConnectionString, acquirePool, releasePool)
import Shiki.Persistence.Migration
  ( MigrationFailure (..),
    renderMigrationFailure,
    runMigrations,
  )
import Shiki.Persistence.Run
  ( completeRunStatement,
    completeUnfinishedRunStatement,
    databaseNowStatement,
    findRunByPrefixStatement,
    getRunStatement,
    insertRunStatement,
    listRecentRunsByServiceStatement,
    listRecentRunsStatement,
    listUnfinishedRunsStatement,
    markRunRunningStatement,
    touchRunWatchedStatement,
    updateErrorSummaryStatement,
  )
import Shiki.Persistence.Schema (Schema, schemaText)
import Shiki.Prelude

-- | Interpret 'RunStore' against an already-acquired pool.
runRunStorePostgres ::
  (IOE :> es, Error ShikiError :> es) =>
  Pool.Pool ->
  Eff (RunStore : es) a ->
  Eff es a
runRunStorePostgres pool = interpret_ $ \case
  InsertRun r -> stmt "insert run" insertRunStatement r
  MarkRunRunning rid -> stmt "mark run running" markRunRunningStatement rid
  CompleteRun completion -> stmt "complete run" completeRunStatement completion
  CompleteUnfinishedRun completion ->
    stmt "complete unfinished run" completeUnfinishedRunStatement completion
  UpdateErrorSummary rid summary source ->
    stmt "update error summary" updateErrorSummaryStatement (rid, summary, source)
  TouchRunWatched rid -> stmt "record run heartbeat" touchRunWatchedStatement rid
  DatabaseNow -> stmt "read the database clock" databaseNowStatement ()
  ListRecentRuns Nothing limit ->
    stmt "list recent runs" listRecentRunsStatement limit
  ListRecentRuns (Just service) limit ->
    stmt "list recent runs" listRecentRunsByServiceStatement (service, limit)
  FindRunsByPrefix prefix ->
    stmt "find runs by prefix" findRunByPrefixStatement prefix
  ListUnfinishedRuns -> stmt "list unfinished runs" listUnfinishedRunsStatement ()
  GetRun rid -> stmt "get run" getRunStatement rid
  where
    stmt ::
      (IOE :> es, Error ShikiError :> es) =>
      Text ->
      Statement input output ->
      input ->
      Eff es output
    stmt operation statement input =
      liftIO (Pool.use pool (Session.statement input statement)) >>= \case
        Right output -> pure output
        Left (Pool.ConnectionUsageError connectionError) ->
          throwError
            ( ShikiStoreError
                (DatabaseUnavailable (renderConnectionError connectionError))
            )
        Left Pool.AcquisitionTimeoutUsageError ->
          throwError
            ( ShikiStoreError
                (DatabaseUnavailable (renderUsageError Pool.AcquisitionTimeoutUsageError))
            )
        Left usageError ->
          throwError
            (ShikiStoreError (StatementFailed operation (renderUsageError usageError)))

-- | Acquire a pool for the schema, apply migrations, run the action with
--   'RunStore' interpreted, and release the pool on the way out.
--
--   Pool acquisition is lazy — hasql-pool connects on first use — so the
--   migration step is where an unreachable database is first noticed, and it
--   is reported as 'DatabaseUnavailable' rather than as a migration problem.
withRunStore ::
  (IOE :> es, Error ShikiError :> es) =>
  ConnectionString ->
  Schema ->
  Eff (RunStore : es) a ->
  Eff es a
withRunStore cs schema action =
  Exc.bracket (liftIO (acquirePool cs schema)) (liftIO . releasePool) $ \pool -> do
    migrate
    runRunStorePostgres pool action
  where
    migrate =
      liftIO (runMigrations cs schema) >>= \case
        Right () -> pure ()
        Left (BootstrapConnectionFailed connectionError) ->
          throwError
            ( ShikiStoreError
                (DatabaseUnavailable (renderConnectionError connectionError))
            )
        Left failure ->
          throwError
            ( ShikiStoreError
                (MigrationFailed (schemaText schema) (renderMigrationFailure failure))
            )
