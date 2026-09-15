-- | The @shiki config show@ subcommand: discover the project-local
--   @shiki.dhall@, resolve the active environment, and print a human-readable
--   summary. Read-only: it never opens a database connection or contacts the
--   cluster. The @--env@ flag is the global one parsed in "Shiki.Cli".
module Shiki.Cli.ConfigShow
  ( runConfigShow,
  )
where

import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Text.IO qualified as TIO
import Effectful (Eff, IOE, type (:>))
import Effectful.Error.Static (Error)
import Shiki.Cli.Project
  ( EnvSelectionSource (..),
    discoverProjectConfigPath,
    loadProjectConfigChecked,
    resolveActiveEnvironmentName,
  )
import Shiki.Error (ShikiError)
import Shiki.Prelude

-- | Render a connection string with any password masked. Handles the URI
--   form (@scheme://user:PASSWORD@host/...@) by replacing the password run
--   between the first @':'@ after @"//"@ and the next @'@'@ with @****@.
--   Strings without that shape are returned unchanged. This is best-effort
--   display hygiene, not security.
maskPassword :: Text -> Text
maskPassword url =
  case Text.breakOn "://" url of
    (_, rest)
      | not (Text.null rest) ->
          let scheme = Text.take (Text.length url - Text.length rest) url
              afterSep = Text.drop 3 rest
           in case Text.breakOn "@" afterSep of
                (authority, hostPart)
                  | not (Text.null hostPart) ->
                      case Text.breakOn ":" authority of
                        (user, pwd)
                          | not (Text.null pwd) ->
                              scheme <> "://" <> user <> ":****" <> hostPart
                        _ -> url
                _ -> url
    _ -> url

runConfigShow ::
  (IOE :> es, Error ShikiError :> es) =>
  Maybe Text ->
  Eff es ()
runConfigShow mEnvFlag =
  liftIO discoverProjectConfigPath >>= \case
    Nothing ->
      liftIO $
        TIO.putStrLn
          "no shiki.dhall found (searched the current directory and its parents)"
    Just path -> do
      cfg <- loadProjectConfigChecked path
      (active, src) <- resolveActiveEnvironmentName cfg mEnvFlag
      let envNames = Text.intercalate ", " (Map.keys (cfg ^. #environments))
          srcLabel = case src of
            FromFlag -> "from --env"
            FromEnvVar -> "from SHIKI_ENV"
            FromDefault -> "from defaultEnvironment"
      liftIO $ do
        TIO.putStrLn ("config file:         " <> Text.pack path)
        TIO.putStrLn ("environments:        " <> envNames)
        TIO.putStrLn ("default environment: " <> cfg ^. #defaultEnvironment)
        TIO.putStrLn ("active environment:  " <> active <> "   (" <> srcLabel <> ")")
        case Map.lookup active (cfg ^. #environments) of
          Just e ->
            TIO.putStrLn ("database url:        " <> maskPassword (e ^. #databaseUrl))
          Nothing ->
            TIO.putStrLn
              ( "database url:        <environment "
                  <> active
                  <> " is not declared in this file>"
              )
