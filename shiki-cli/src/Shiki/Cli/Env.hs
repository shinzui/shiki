-- | The "context" bundle threaded through every @shiki@ subcommand
--   handler. Built once per invocation by 'withCliEnv': it acquires the
--   Postgres connection pool, applies any pending migrations, and loads
--   the operator's Kubernetes client config. The pool is released on
--   exit. Subcommands take a 'CliEnv' rather than the individual
--   resources so a future plan can extend the bundle without touching
--   every handler.
module Shiki.Cli.Env
  ( CliEnv (..)
  , withCliEnv
  ) where

import Shiki.Prelude

import Shiki.K8s.Client (ClientEnv, loadDefaultClientConfig)
import Shiki.Persistence.Connection (ConnectionString, acquirePool, releasePool)
import Shiki.Persistence.Migration (runMigrations)
import Shiki.Persistence.Schema (Schema)

import "base" Control.Exception (bracket)
import "hasql-pool" Hasql.Pool qualified as Pool

data CliEnv = CliEnv
  { pool   :: !Pool.Pool
  , client :: !ClientEnv
  }
  deriving stock (Generic)

-- | Acquire the database pool, run migrations, load the default
--   Kubernetes client config, hand the bundle to the continuation, and
--   release the pool on exit. The Kubernetes 'ClientEnv' owns an
--   @http-client@ 'Network.HTTP.Client.Manager' that does not require
--   explicit teardown.
withCliEnv :: ConnectionString -> Schema -> (CliEnv -> IO a) -> IO a
withCliEnv cs schema action =
  bracket (acquirePool cs schema) releasePool $ \p -> do
    runMigrations p schema
    cl <- loadDefaultClientConfig
    action CliEnv { pool = p, client = cl }
