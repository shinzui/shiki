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
import Shiki.Prelude
import System.Directory (doesFileExist, renameFile)
import System.Exit (exitFailure)
import System.FilePath (takeDirectory)
import System.IO (hClose, openTempFile, stderr)

data ConfigInitOptions = ConfigInitOptions
  { schemaRef :: !Text,
    outputPath :: !FilePath,
    defaultEnvironment :: !Text
  }
  deriving stock (Generic, Eq, Show)

-- | Temporary until release tooling injects a pushed tag or commit. Operators
--   can and should pass @--schema-ref@ to pin the generated URL explicitly.
defaultSchemaRef :: Text
defaultSchemaRef = "main"

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

runConfigInit :: ConfigInitOptions -> IO ()
runConfigInit opts = do
  let path = opts ^. #outputPath
  exists <- doesFileExist path
  when exists $ do
    TIO.hPutStrLn stderr ("shiki: " <> Text.pack path <> " already exists; refusing to overwrite")
    exitFailure
  let dir = takeDirectory path
  (tmp, h) <- openTempFile dir ".shiki.dhall.tmp"
  TIO.hPutStr h (renderProjectConfig opts)
  hClose h
  renameFile tmp path

schemaPackageUrl :: Text -> Text
schemaPackageUrl ref =
  "https://raw.githubusercontent.com/shinzui/shiki/"
    <> ref
    <> "/schema/package.dhall"
