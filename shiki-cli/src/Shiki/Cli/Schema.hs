-- | Resolve the PostgreSQL schema for @shiki@ subcommands.
--   Precedence: @--db-schema@ flag, then @SHIKI_DB_SCHEMA@ env var, then
--   @defaultSchema@ (which is @"shiki"@).
module Shiki.Cli.Schema
  ( resolveSchema,
  )
where

import Data.Text qualified as Text
import Effectful (Eff, IOE, type (:>))
import Effectful.Error.Static (Error, throwError)
import Shiki.Error (ConfigError (..), ShikiError (..))
import Shiki.Persistence.Schema (Schema, defaultSchema, mkSchema)
import Shiki.Prelude
import System.Environment (lookupEnv)

-- | A rejected name is an operator mistake, not a bug, so it becomes a typed
--   error the top-level handler renders as
--   @shiki: invalid schema name: \<reason\>@.
resolveSchema ::
  (IOE :> es, Error ShikiError :> es) =>
  Maybe Text ->
  Eff es Schema
resolveSchema = \case
  Just t -> liftEither (mkSchema t)
  Nothing ->
    liftIO (lookupEnv "SHIKI_DB_SCHEMA") >>= \case
      Just s | not (null s) -> liftEither (mkSchema (Text.pack s))
      _ -> pure defaultSchema
  where
    liftEither = \case
      Right s -> pure s
      Left err -> throwError (ShikiConfigError (InvalidSchemaName err))
