-- | Resolve a service config name from either a typed name or an @fzf@
--   picker. The candidate list is built by listing @services/*.dhall@ — the
--   same directory @shiki service show NAME@ resolves against — so a pick
--   followed by Enter is byte-for-byte equivalent to typing the bare name.
--
--   Like "Shiki.Cli.Fzf.Selector.Run", 'serviceTarget' decides between the
--   name and the picker first, 'resolveService' produces the name, and every
--   failure is a 'ServiceLookupFailure' rendered by
--   'renderServiceLookupFailure'.
module Shiki.Cli.Fzf.Selector.Service
  ( ServiceTarget (..),
    ServiceLookupFailure (..),
    serviceOpts,
    serviceTarget,
    pickerServiceTarget,
    serviceConfigPath,
    resolveService,
    resolveServiceIn,
    listServiceNames,
    fromServiceFzfResult,
    renderServiceLookupFailure,
  )
where

import Control.Exception (IOException, try)
import Data.List (sort)
import Data.Text qualified as Text
import Shiki.Cli.Fzf
  ( Candidate (..),
    FzfConfig,
    FzfOpts,
    FzfResult (..),
    detectFzfConfig,
    isFzfAvailable,
    runFzf,
    withHeight,
    withNoSort,
    withPrompt,
    withSelectOne,
  )
import Shiki.Prelude
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.FilePath (takeExtension, takeFileName, (-<.>), (</>))

-- | Hard-coded location for service configs, matching the existing
--   @serviceShowHandler@ in "Shiki.Cli".
serviceConfigDir :: FilePath
serviceConfigDir = "services"

-- | What the operator asked for: a service name, or the picker.
data ServiceTarget
  = ServiceByName !Text
  | ServiceByPicker !FzfConfig

-- | Every way turning a target into a service name can fail.
data ServiceLookupFailure
  = NoServiceConfigs
  | -- | a typed name with no config file at this path
    ServiceConfigNotFound !FilePath
  | ServicePickerNoMatch
  | ServicePickerCancelled
  | ServiceFzfUnavailable
  | ServicePickerFailed !Text
  deriving stock (Eq, Show)

-- | @service> @ prompt, 40% height, lexical order kept, a lone config picked
--   without asking (showing a config is read-only).
serviceOpts :: FzfOpts
serviceOpts = withPrompt "service> " <> withHeight "40%" <> withNoSort <> withSelectOne

-- | Decide the target. Probes for fzf only when no name was given.
serviceTarget :: Maybe Text -> IO (Either ServiceLookupFailure ServiceTarget)
serviceTarget (Just n) = pure (Right (ServiceByName n))
serviceTarget Nothing = pickerServiceTarget <$> detectFzfConfig

-- | The picker target, or 'ServiceFzfUnavailable' when fzf cannot run.
pickerServiceTarget :: FzfConfig -> Either ServiceLookupFailure ServiceTarget
pickerServiceTarget cfg
  | isFzfAvailable cfg = Right (ServiceByPicker cfg)
  | otherwise = Left ServiceFzfUnavailable

-- | The file @shiki service show NAME@ loads: @services/NAME.dhall@.
serviceConfigPath :: Text -> FilePath
serviceConfigPath = serviceConfigPathIn serviceConfigDir

serviceConfigPathIn :: FilePath -> Text -> FilePath
serviceConfigPathIn dir n = dir </> (Text.unpack n <> ".dhall")

-- | Resolve a target to a service name; the picker offers every
--   @services/*.dhall@ basename.
resolveService :: ServiceTarget -> IO (Either ServiceLookupFailure Text)
resolveService = resolveServiceIn serviceConfigDir

-- | 'resolveService' against an explicit directory, so tests need not change
--   the working directory. A typed name must name an existing file.
resolveServiceIn :: FilePath -> ServiceTarget -> IO (Either ServiceLookupFailure Text)
resolveServiceIn dir = \case
  ServiceByName n -> do
    let path = serviceConfigPathIn dir n
    exists <- doesFileExist path
    pure (if exists then Right n else Left (ServiceConfigNotFound path))
  ServiceByPicker cfg ->
    try @IOException (listServiceNames dir) >>= \case
      Left e -> pure (Left (ServicePickerFailed (Text.pack ("listDirectory failed: " <> show e))))
      Right [] -> pure (Left NoServiceConfigs)
      Right names ->
        fromServiceFzfResult
          <$> runFzf cfg serviceOpts [Candidate {display = n, value = n} | n <- names]

-- | Read @dir@, keep only @*.dhall@ entries, strip the extension, sort
--   lexically. Returns @[]@ if the directory does not exist.
listServiceNames :: FilePath -> IO [Text]
listServiceNames dir = do
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

fromServiceFzfResult :: FzfResult Text -> Either ServiceLookupFailure Text
fromServiceFzfResult = \case
  FzfSelected n -> Right n
  FzfNoMatch -> Left ServicePickerNoMatch
  FzfCancelled -> Left ServicePickerCancelled
  FzfError e -> Left (ServicePickerFailed e)

-- | The message for a failure, or 'Nothing' for a silent cancel. The caller
--   prints it on stderr and exits 1.
renderServiceLookupFailure :: ServiceLookupFailure -> Maybe Text
renderServiceLookupFailure = \case
  NoServiceConfigs -> Just ("shiki: no service configs found in " <> Text.pack serviceConfigDir <> "/")
  ServiceConfigNotFound path -> Just ("shiki: no service config at " <> Text.pack path)
  ServicePickerNoMatch -> Just "shiki: no service matches the picker query"
  ServicePickerCancelled -> Nothing
  ServiceFzfUnavailable -> Just "shiki: no service name given and fzf is not available"
  ServicePickerFailed e -> Just ("shiki: fzf: " <> e)
