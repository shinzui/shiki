-- | The "context" bundle threaded through every @shiki@ subcommand
--   handler. Built once per invocation by 'withCliEnv': it acquires the
--   Postgres connection pool, applies any pending migrations, and loads
--   the operator's Kubernetes client config. The pool is released on
--   exit. Subcommands take a 'CliEnv' rather than the individual
--   resources so a future plan can extend the bundle without touching
--   every handler.
module Shiki.Cli.Env
  ( CliEnv (..),
    withCliEnv,
  )
where

import Data.Text qualified as Text
import Effectful (Eff, IOE, type (:>))
import Effectful.Error.Static (Error, throwError)
import Effectful.Exception qualified as Exc
import Hasql.Pool qualified as Pool
import Shiki.Error
  ( KubeError (..),
    ShikiError (..),
    StoreError (..),
    collapseWhitespace,
    renderConnectionError,
  )
import Shiki.K8s.Client (ClientEnv, loadDefaultClientConfig)
import Shiki.K8s.ExecCredential (ExecCredentialError)
import Shiki.Persistence.Connection (ConnectionString, acquirePool, releasePool)
import Shiki.Persistence.Migration
  ( MigrationFailure (..),
    renderMigrationFailure,
    runMigrations,
  )
import Shiki.Persistence.Schema (Schema, schemaText)
import Shiki.Prelude

data CliEnv = CliEnv
  { pool :: !Pool.Pool,
    client :: !ClientEnv
  }
  deriving stock (Generic)

-- | Acquire the database pool, run migrations, load the default
--   Kubernetes client config, hand the bundle to the continuation, and
--   release the pool on exit. The Kubernetes 'ClientEnv' owns an
--   @http-client@ 'Network.HTTP.Client.Manager' that does not require
--   explicit teardown.
--
--   Everything that can go wrong on the way in becomes a typed 'ShikiError':
--   an unreachable server is 'DatabaseUnavailable', any other migration
--   problem is 'MigrationFailed', a failing credential plugin is
--   'KubeCredentialFailed', and an unreadable kubeconfig is
--   'KubeConfigUnavailable'. Pool acquisition itself is lazy — hasql-pool
--   connects on first use — so the migration step is where an unreachable
--   database is first noticed.
withCliEnv ::
  (IOE :> es, Error ShikiError :> es) =>
  ConnectionString ->
  Schema ->
  (CliEnv -> IO a) ->
  Eff es a
withCliEnv cs schema action =
  Exc.bracket (liftIO (acquirePool cs schema)) (liftIO . releasePool) $ \p -> do
    migrate
    cl <- loadClient
    liftIO (action CliEnv {pool = p, client = cl})
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
    loadClient =
      Exc.trySync (liftIO loadDefaultClientConfig) >>= \case
        Right cl -> pure cl
        Left e
          | Just credentialError <- Exc.fromException @ExecCredentialError e ->
              throwError
                ( ShikiKubeError
                    (KubeCredentialFailed (kubeMessage credentialError))
                )
          | otherwise ->
              throwError
                ( ShikiKubeError
                    (KubeConfigUnavailable (kubeMessage e))
                )
    kubeMessage :: (Exc.Exception e) => e -> Text
    kubeMessage = collapseWhitespace . Text.pack . Exc.displayException
