-- | Thin wrapper around "Hasql.Pool" for acquiring a connection pool
--   from a libpq-style connection string. EP-4 ('shiki run') and EP-5
--   ('shiki runs ...') call 'acquirePool' once at the top of @runCli@
--   and 'releasePool' at the bottom.
module Shiki.Persistence.Connection
  ( ConnectionString (..)
  , acquirePool
  , releasePool
  ) where

import Shiki.Prelude

import Shiki.Persistence.Schema (Schema, quoteSchema)

import "time" Data.Time.Clock (DiffTime)
import "hasql" Hasql.Connection.Settings qualified as ConnSettings
import "hasql" Hasql.Session qualified as Session
import "hasql-pool" Hasql.Pool qualified as Pool
import "hasql-pool" Hasql.Pool.Config qualified as PoolConfig

newtype ConnectionString = ConnectionString { unConnectionString :: Text }
  deriving stock (Generic, Eq, Show)
  deriving newtype (FromJSON, ToJSON)

-- | Acquire a 5-connection pool with a 10-second acquisition timeout and
--   1-hour idle and aging timeouts. Sized for a short-lived CLI; raise
--   the pool size if 'shiki' grows long-running responsibilities.
--
--   Every connection handed out by the pool first runs
--   @SET search_path TO "\<schema\>", public;@ via @hasql-pool@'s
--   @initSession@ hook, so unqualified table references in 'Hasql.Statement'
--   values resolve into the configured 'Schema'.
acquirePool :: ConnectionString -> Schema -> IO Pool.Pool
acquirePool (ConnectionString cs) schema =
  Pool.acquire
    ( PoolConfig.settings
        [ PoolConfig.size 5
        , PoolConfig.acquisitionTimeout (10 :: DiffTime)
        , PoolConfig.idlenessTimeout (3600 :: DiffTime)
        , PoolConfig.agingTimeout (3600 :: DiffTime)
        , PoolConfig.staticConnectionSettings (ConnSettings.connectionString cs)
        , PoolConfig.initSession (setSearchPath schema)
        ]
    )

setSearchPath :: Schema -> Session.Session ()
setSearchPath schema =
  Session.script ("SET search_path TO " <> quoteSchema schema <> ", public;")

releasePool :: Pool.Pool -> IO ()
releasePool = Pool.release
