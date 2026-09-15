-- | Resolve the Postgres connection string for @shiki@ subcommands.
--   Precedence: @--db@ flag, then the active environment's @databaseUrl@
--   from a project-local @shiki.dhall@ (see "Shiki.Cli.Project"), then
--   @SHIKI_DATABASE_URL@, then @PG_CONNECTION_STRING@ (the variable the
--   project's @nix develop@ shellHook exports).
module Shiki.Cli.Config
  ( resolveConnectionString,
  )
where

import Data.Generics.Labels ()
import Data.Text qualified as Text
import Effectful (Eff, IOE, type (:>))
import Effectful.Error.Static (Error, throwError)
import Shiki.Cli.Project (resolveActiveEnvironment)
import Shiki.Error (ConfigError (..), ShikiError (..))
import Shiki.Persistence.Connection (ConnectionString (..))
import Shiki.Prelude
import System.Environment (lookupEnv)

-- | Pick a 'ConnectionString' from the @--db@ flag, then the active
--   environment in @shiki.dhall@, then environment variables. Throws
--   'NoConnectionString' if none is set, so a missing connection string can
--   never silently fall through to the cluster work.
resolveConnectionString ::
  (IOE :> es, Error ShikiError :> es) =>
  Maybe Text ->
  Maybe Text ->
  Eff es ConnectionString
resolveConnectionString mDb mEnv = case mDb of
  Just t -> pure (ConnectionString t)
  Nothing -> do
    mActive <- resolveActiveEnvironment mEnv
    case mActive of
      Just (_name, e)
        | not (Text.null (e ^. #databaseUrl)) ->
            pure (ConnectionString (e ^. #databaseUrl))
      _ -> do
        fromEnv <- liftIO (firstEnv ["SHIKI_DATABASE_URL", "PG_CONNECTION_STRING"])
        case fromEnv of
          Just s -> pure (ConnectionString s)
          Nothing -> throwError (ShikiConfigError NoConnectionString)

firstEnv :: [String] -> IO (Maybe Text)
firstEnv [] = pure Nothing
firstEnv (n : rest) =
  lookupEnv n >>= \case
    Just v -> pure (Just (Text.pack v))
    Nothing -> firstEnv rest
