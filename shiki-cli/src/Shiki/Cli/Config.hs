-- | Resolve the Postgres connection string for @shiki@ subcommands.
--   Precedence: @--db@ flag, then the active environment's @databaseUrl@
--   from a project-local @shiki.dhall@ (see "Shiki.Cli.Project"), then
--   @SHIKI_DATABASE_URL@, then @PG_CONNECTION_STRING@ (the variable the
--   project's @nix develop@ shellHook exports).
module Shiki.Cli.Config
  ( resolveConnectionString,
    connectionForEnvironment,
  )
where

import Data.Generics.Labels ()
import Data.Text qualified as Text
import Effectful (Eff, IOE, type (:>))
import Effectful.Error.Static (Error, throwError)
import Shiki.Cli.Project (Environment, resolveActiveEnvironment)
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
  Nothing -> resolveActiveEnvironment mEnv >>= connectionForEnvironment Nothing . fmap snd

-- | Run dispatch already resolved the project to choose its cluster.
connectionForEnvironment ::
  (IOE :> es, Error ShikiError :> es) =>
  Maybe Text -> Maybe Environment -> Eff es ConnectionString
connectionForEnvironment override active =
  case override <|> (active >>= usableUrl) of
    Just url -> pure (ConnectionString url)
    Nothing -> do
      fallback <- liftIO (firstEnv ["SHIKI_DATABASE_URL", "PG_CONNECTION_STRING"])
      maybe (throwError (ShikiConfigError NoConnectionString)) (pure . ConnectionString) fallback
  where
    usableUrl env = do
      let url = env ^. #databaseUrl
      guard (not (Text.null url))
      pure url

firstEnv :: [String] -> IO (Maybe Text)
firstEnv [] = pure Nothing
firstEnv (n : rest) =
  lookupEnv n >>= \case
    Just v -> pure (Just (Text.pack v))
    Nothing -> firstEnv rest
