-- | Selector that lets the operator pick a service config by name via
--   @fzf@. The candidate list is built by listing
--   @services/*.dhall@ — the same directory the existing
--   @shiki service show NAME@ handler resolves against — so a pick
--   followed by Enter is byte-for-byte equivalent to typing the bare
--   name.
module Shiki.Cli.Fzf.Selector.Service
  ( ServiceSelection (..),
    defaultServiceOpts,
    selectService,
    resolveServiceName,
  )
where

import Shiki.Cli.Fzf
  ( Candidate (..),
    FzfConfig,
    FzfOpts,
    FzfResult (..),
    isFzfAvailable,
    runFzf,
    withHeight,
    withNoSort,
    withPrompt,
  )
import Shiki.Prelude
import "base" Control.Exception (IOException, try)
import "base" Data.List (sort)
import "base" System.IO (hPutStrLn, stderr)
import "directory" System.Directory (doesDirectoryExist, listDirectory)
import "filepath" System.FilePath (takeExtension, takeFileName, (-<.>))
import "text" Data.Text qualified as Text
import "text" Data.Text.IO qualified as TIO

-- | Hard-coded location for service configs, matching the existing
--   @serviceShowHandler@ in "Shiki.Cli".
serviceConfigDir :: FilePath
serviceConfigDir = "services"

data ServiceSelection
  = ServiceChosen !Text -- bare service name, sans @.dhall@
  | ServiceNoneFound
  | ServiceSelectionCancelled
  | ServiceFzfUnavailable
  | ServiceSelectionError !Text

defaultServiceOpts :: FzfOpts
defaultServiceOpts =
  withPrompt "service> " <> withHeight "40%" <> withNoSort

-- | Enumerate @services/*.dhall@ in lexical order and hand the basenames
--   (minus the @.dhall@ extension) to fzf.
selectService :: FzfConfig -> IO ServiceSelection
selectService cfg
  | not (isFzfAvailable cfg) = pure ServiceFzfUnavailable
  | otherwise = do
      eEntries <- try @IOException (listEntries serviceConfigDir)
      case eEntries of
        Left e ->
          pure (ServiceSelectionError (Text.pack ("listDirectory failed: " <> show e)))
        Right [] -> pure ServiceNoneFound
        Right entries -> do
          let candidates =
                [ Candidate {candidateDisplay = n, candidateValue = n}
                | n <- entries
                ]
          res <- runFzf cfg defaultServiceOpts candidates
          pure $ case res of
            FzfSelected n -> ServiceChosen n
            FzfNoMatch -> ServiceNoneFound
            FzfCancelled -> ServiceSelectionCancelled
            FzfError msg -> ServiceSelectionError msg

-- | Read @services/@, keep only @*.dhall@ entries, strip the extension,
--   sort lexically. Returns @[]@ if the directory does not exist.
listEntries :: FilePath -> IO [Text]
listEntries dir = do
  exists <- doesDirectoryExist dir
  if not exists
    then pure []
    else do
      raw <- listDirectory dir
      let dhalls =
            [ takeFileName (e -<.> "")
            | e <- raw,
              takeExtension e == ".dhall"
            ]
      pure (map Text.pack (sort dhalls))

-- | Public entry point for @service show@. 'Nothing' return means the
--   caller should exit non-zero (any user-visible message has already
--   been printed).
resolveServiceName :: FzfConfig -> IO (Maybe Text)
resolveServiceName cfg
  | not (isFzfAvailable cfg) = do
      hPutStrLn stderr "shiki: no service name given and fzf is not available"
      pure Nothing
  | otherwise = do
      sel <- selectService cfg
      case sel of
        ServiceChosen n -> pure (Just n)
        ServiceNoneFound -> do
          TIO.putStrLn ("(no service configs found in " <> Text.pack serviceConfigDir <> "/)")
          pure Nothing
        ServiceSelectionCancelled -> pure Nothing
        ServiceFzfUnavailable -> do
          hPutStrLn stderr "shiki: no service name given and fzf is not available"
          pure Nothing
        ServiceSelectionError e -> do
          TIO.hPutStrLn stderr ("shiki: fzf: " <> e)
          pure Nothing
