-- | Command-level failures, and their one renderer.
--
--   "Shiki.Error" covers what shiki-core can fail at: configuration, the
--   database, the cluster, the analyzer. This module covers what a /command/
--   can fail at: a run or a service that could not be looked up, an unknown
--   help topic, a refused overwrite, an agent that could not be launched, and
--   a command whose work did not succeed. shiki-core cannot mention these
--   types, which is why there are two error types rather than one; the
--   top-level handler in "Shiki.Cli.Main" discharges both and renders either.
--
--   'renderCliError' returns 'Maybe' 'Text' because some failures have already
--   said everything they have to say. An fzf picker the operator cancelled
--   prints nothing (ADR 2), and @shiki run@ prints the run's outcome on stdout
--   before it fails. Those render as 'Nothing'; the top level still exits 1.
module Shiki.Cli.Error
  ( CliError (..),
    renderCliError,
  )
where

import Data.Text qualified as Text
import Shiki.Cli.Fzf.Selector.Run (RunLookupFailure, renderRunLookupFailure)
import Shiki.Cli.Fzf.Selector.Service (ServiceLookupFailure, renderServiceLookupFailure)
import Shiki.Error (ShikiError, renderShikiError)
import Shiki.Prelude

data CliError
  = -- | a core failure raised where only @Error CliError@ is in scope.
    --   Handlers normally throw 'ShikiError' directly; this constructor
    --   exists so 'renderCliError' covers both types.
    CliCoreError !ShikiError
  | CliRunLookup !RunLookupFailure
  | CliServiceLookup !ServiceLookupFailure
  | -- | the topic the operator asked for, and the topics that do exist
    UnknownHelpTopic !Text ![Text]
  | ConfigFileExists !FilePath
  | AgentProviderInvalid !Text
  | -- | binary name, and how to install it
    AgentBinaryMissing !Text !Text
  | AgentPromptInvalid !Text
  | AgentRequestFailed !Text
  | -- | the handler already printed why; exit 1 without another line
    CommandFailed
  deriving stock (Generic, Eq, Show)

-- | What to print on stderr, or 'Nothing' to print nothing. The text may span
--   several lines: @shiki help \<unknown\>@ prints the topic list too.
renderCliError :: CliError -> Maybe Text
renderCliError = \case
  CliCoreError e -> Just (renderShikiError e)
  CliRunLookup failure -> renderRunLookupFailure failure
  CliServiceLookup failure -> renderServiceLookupFailure failure
  UnknownHelpTopic topic available ->
    Just
      ( "Unknown topic: "
          <> topic
          <> "\nAvailable: "
          <> Text.intercalate ", " available
      )
  ConfigFileExists path ->
    Just ("shiki: " <> Text.pack path <> " already exists; refusing to overwrite")
  AgentProviderInvalid message -> Just ("shiki: " <> message)
  AgentBinaryMissing name installHint ->
    Just ("shiki: '" <> name <> "' CLI not found on PATH (" <> installHint <> ")")
  AgentPromptInvalid message -> Just ("shiki: " <> message)
  AgentRequestFailed message -> Just ("shiki: agent api call failed: " <> message)
  CommandFailed -> Nothing
