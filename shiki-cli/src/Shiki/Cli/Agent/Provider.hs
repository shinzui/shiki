-- | Typed selector for the AI provider that backs
--   @shiki agent assist@. Four providers, two of them spawn a local
--   subprocess CLI (Claude Code, Codex) and two issue a one-shot HTTP
--   request to the hosted API (Anthropic Messages, OpenAI Chat
--   Completions). The 'AgentModelConfig' record pairs a provider with an
--   optional model id; the parsers here let the CLI flag and env-var
--   layers in "Shiki.Cli.Agent.Config" share one spelling vocabulary.
module Shiki.Cli.Agent.Provider
  ( AgentProvider (..)
  , AgentModelConfig (..)
  , defaultAgentModelConfig
  , providerFromText
  , providerToText
  ) where

import Shiki.Prelude

import "text" Data.Text qualified as Text

data AgentProvider
  = ClaudeCli
  | CodexCli
  | Anthropic
  | OpenAI
  deriving stock (Generic, Eq, Show)

data AgentModelConfig = AgentModelConfig
  { provider :: !AgentProvider
  , model    :: !(Maybe Text)
  }
  deriving stock (Generic, Eq, Show)

defaultAgentModelConfig :: AgentModelConfig
defaultAgentModelConfig =
  AgentModelConfig
    { provider = ClaudeCli
    , model    = Nothing
    }

providerFromText :: Text -> Either Text AgentProvider
providerFromText raw = case Text.toLower (Text.strip raw) of
  "claude-cli" -> Right ClaudeCli
  "codex-cli"  -> Right CodexCli
  "anthropic"  -> Right Anthropic
  "openai"     -> Right OpenAI
  other ->
    Left
      ( "unknown agent provider '"
          <> other
          <> "'. Expected one of: claude-cli, codex-cli, anthropic, openai."
      )

providerToText :: AgentProvider -> Text
providerToText = \case
  ClaudeCli -> "claude-cli"
  CodexCli  -> "codex-cli"
  Anthropic -> "anthropic"
  OpenAI    -> "openai"
