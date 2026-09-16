-- | The @shiki config init@ subcommand: write a portable project-local
--   @shiki.dhall@ that imports shiki's public schema package from GitHub.
module Shiki.Cli.ConfigInit
  ( ConfigInitOptions (..),
    defaultSchemaRef,
    renderProjectConfig,
    runConfigInit,
  )
where

import Data.Generics.Labels ()
import Data.Text qualified as Text
import Data.Text.IO qualified as TIO
import Effectful (Eff, IOE, type (:>))
import Effectful.Error.Static (Error, throwError)
import Effectful.Exception qualified as Exc
import Shiki.Cli.Error (CliError (..))
import Shiki.Error (ConfigError (..), ShikiError (..), collapseWhitespace)
import Shiki.Prelude
import System.Directory (doesFileExist, renameFile)
import System.FilePath (takeDirectory)
import System.IO (hClose, openTempFile)

data ConfigInitOptions = ConfigInitOptions
  { schemaRef :: !Text,
    outputPath :: !FilePath,
    defaultEnvironment :: !Text
  }
  deriving stock (Generic, Eq, Show)

-- | The repository's default branch. Temporary until release tooling injects a
--   pushed tag or commit. Operators can and should pass @--schema-ref@ to pin
--   the generated URL explicitly.
defaultSchemaRef :: Text
defaultSchemaRef = "master"

renderProjectConfig :: ConfigInitOptions -> Text
renderProjectConfig opts =
  Text.unlines
    [ "{- Project-local shiki configuration.",
      "",
      "   Replace the placeholder database URLs below with the databases for",
      "   this service repository. The schema import points at the public shiki",
      "   package so this file can live outside the shiki source checkout.",
      "-}",
      "let Schema =",
      "      " <> schemaPackageUrl (opts ^. #schemaRef),
      "",
      "let mkEnv = \\(url : Text) -> { databaseUrl = url } : Schema.Environment",
      "",
      "in    { environments =",
      "          toMap",
      "            { staging = mkEnv \"postgresql://replace-me/staging\"",
      "            , prod = mkEnv \"postgresql://replace-me/prod\"",
      "            }",
      "      , defaultEnvironment = \"" <> opts ^. #defaultEnvironment <> "\"",
      "      }",
      "    : Schema.ProjectConfig"
    ]

-- | Write the file, refusing to clobber one that is already there.
--
--   The write goes to a temporary file in the target directory and is then
--   renamed into place, so a failure half way through cannot leave a
--   truncated @shiki.dhall@ behind. A missing directory or a read-only one
--   fails as 'ConfigWriteFailed' rather than as an uncaught @openTempFile@.
runConfigInit ::
  (IOE :> es, Error ShikiError :> es, Error CliError :> es) =>
  ConfigInitOptions ->
  Eff es ()
runConfigInit opts = do
  let path = opts ^. #outputPath
  exists <- liftIO (doesFileExist path)
  when exists (throwError (ConfigFileExists path))
  let dir = takeDirectory path
  outcome <-
    Exc.trySync . liftIO $ do
      (tmp, h) <- openTempFile dir ".shiki.dhall.tmp"
      TIO.hPutStr h (renderProjectConfig opts)
      hClose h
      renameFile tmp path
  case outcome of
    Right () -> pure ()
    Left e ->
      throwError
        ( ShikiConfigError
            (ConfigWriteFailed path (collapseWhitespace (Text.pack (Exc.displayException e))))
        )

schemaPackageUrl :: Text -> Text
schemaPackageUrl ref =
  "https://raw.githubusercontent.com/shinzui/shiki/"
    <> ref
    <> "/schema/package.dhall"
