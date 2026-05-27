-- | Resolve the Postgres connection string for @shiki@ subcommands.
--   Precedence: @--db@ flag, then @SHIKI_DATABASE_URL@, then
--   @PG_CONNECTION_STRING@ (the variable the project's @nix develop@
--   shellHook exports).
module Shiki.Cli.Config
  ( resolveConnectionString
  ) where

import Shiki.Prelude

import Shiki.Persistence.Connection (ConnectionString (..))

import "text" Data.Text qualified as Text
import "base" System.Environment (lookupEnv)

-- | Pick a 'ConnectionString' from the flag value, then the
--   @SHIKI_DATABASE_URL@ env var, then @PG_CONNECTION_STRING@. Errors
--   out if none of the three is set so a missing connection string can
--   never silently fall through to the cluster work.
resolveConnectionString :: Maybe Text -> IO ConnectionString
resolveConnectionString = \case
  Just t  -> pure (ConnectionString t)
  Nothing -> do
    fromEnv <- firstEnv ["SHIKI_DATABASE_URL", "PG_CONNECTION_STRING"]
    case fromEnv of
      Just s  -> pure (ConnectionString s)
      Nothing ->
        error
          "shiki: no Postgres connection string. \
          \Pass --db or set SHIKI_DATABASE_URL / PG_CONNECTION_STRING."

firstEnv :: [String] -> IO (Maybe Text)
firstEnv [] = pure Nothing
firstEnv (n : rest) =
  lookupEnv n >>= \case
    Just v  -> pure (Just (Text.pack v))
    Nothing -> firstEnv rest
