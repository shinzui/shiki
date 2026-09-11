-- | Resolve the PostgreSQL schema for @shiki@ subcommands.
--   Precedence: @--db-schema@ flag, then @SHIKI_DB_SCHEMA@ env var, then
--   @defaultSchema@ (which is @"shiki"@).
module Shiki.Cli.Schema
  ( resolveSchema,
  )
where

import Data.Text qualified as Text
import Shiki.Persistence.Schema (Schema, defaultSchema, mkSchema)
import Shiki.Prelude
import System.Environment (lookupEnv)

resolveSchema :: Maybe Text -> IO Schema
resolveSchema = \case
  Just t -> liftEither (mkSchema t)
  Nothing ->
    lookupEnv "SHIKI_DB_SCHEMA" >>= \case
      Just s | not (null s) -> liftEither (mkSchema (Text.pack s))
      _ -> pure defaultSchema
  where
    liftEither = \case
      Right s -> pure s
      Left err -> error ("shiki: invalid schema name: " <> Text.unpack err)
