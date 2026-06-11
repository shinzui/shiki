-- | Resolve the Postgres connection string for @shiki@ subcommands.
--   Precedence: @--db@ flag, then the active environment's @databaseUrl@
--   from a project-local @shiki.dhall@ (see "Shiki.Cli.Project"), then
--   @SHIKI_DATABASE_URL@, then @PG_CONNECTION_STRING@ (the variable the
--   project's @nix develop@ shellHook exports).
module Shiki.Cli.Config
  ( resolveConnectionString,
  )
where

import Shiki.Cli.Project (resolveActiveEnvironment)
import Shiki.Persistence.Connection (ConnectionString (..))
import Shiki.Prelude
import "base" System.Environment (lookupEnv)
import "text" Data.Text qualified as Text

-- | Pick a 'ConnectionString' from the @--db@ flag, then the active
--   environment in @shiki.dhall@, then environment variables. Errors out
--   if none is set so a missing connection string can never silently fall
--   through to the cluster work.
resolveConnectionString :: Maybe Text -> Maybe Text -> IO ConnectionString
resolveConnectionString mDb mEnv = case mDb of
  Just t -> pure (ConnectionString t)
  Nothing -> do
    mActive <- resolveActiveEnvironment mEnv
    case mActive of
      Just (_name, e)
        | not (Text.null (e ^. #databaseUrl)) ->
            pure (ConnectionString (e ^. #databaseUrl))
      _ -> do
        fromEnv <- firstEnv ["SHIKI_DATABASE_URL", "PG_CONNECTION_STRING"]
        case fromEnv of
          Just s -> pure (ConnectionString s)
          Nothing ->
            error
              "shiki: no Postgres connection string. \
              \Pass --db, add a shiki.dhall, or set \
              \SHIKI_DATABASE_URL / PG_CONNECTION_STRING."

firstEnv :: [String] -> IO (Maybe Text)
firstEnv [] = pure Nothing
firstEnv (n : rest) =
  lookupEnv n >>= \case
    Just v -> pure (Just (Text.pack v))
    Nothing -> firstEnv rest
