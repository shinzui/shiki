-- | The pieces of shiki's LLM-backed analyzer that are not IO: which models
--   it will talk to, the prompt and request options it sends, and how it
--   reads a reply back.
--
--   The call itself lives in "Shiki.Effect.Analyzer", which issues it through
--   @baikai-effectful@'s @Baikai@ effect. Everything here is a value or a
--   pure function, so a test can assert on the prompt and the caps without a
--   network.
module Shiki.Analysis.Baikai
  ( supportedModels,
    lookupModel,
    registerAnalyzerProviders,
    analyzerContext,
    analyzerOptions,
    extractText,
    capChars,
    renderError,
    summaryCharCap,
  )
where

import Baikai
  ( BaikaiError,
    Context,
    Options,
    Response,
    emptyContext,
    emptyOptions,
    flattenAssistantBlocks,
    maxTokens,
    messages,
    systemPrompt,
    temperature,
  )
import Baikai.Content (AssistantContent (..), TextContent (..))
import Baikai.Message (user)
import Baikai.Model (Model)
import Baikai.Models.Generated qualified as Models
import Baikai.Provider.Claude.Api qualified as ClaudeApi
import Baikai.Provider.OpenAI.Api qualified as OpenAIApi
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Data.Vector qualified as V
import Shiki.Prelude hiding (Context, Options)

-- | Hand-curated list of baikai catalog ids this build of shiki knows
--   how to dispatch. Extend by adding a case to 'lookupModel' below;
--   the registry is intentionally narrow so a typo in the operator's
--   @--analyzer=baikai:...@ argument fails loudly instead of falling
--   through to a default model.
supportedModels :: [Text]
supportedModels =
  [ "anthropic_claude_haiku_4_5",
    "anthropic_claude_sonnet_4_6",
    "openai_gpt_4o_mini"
  ]

-- | The model behind a catalog id, or 'Nothing' if shiki does not know it.
lookupModel :: Text -> Maybe Model
lookupModel = \case
  "anthropic_claude_haiku_4_5" -> Just Models.anthropic_claude_haiku_4_5
  "anthropic_claude_sonnet_4_6" -> Just Models.anthropic_claude_sonnet_4_6
  "openai_gpt_4o_mini" -> Just Models.openai_gpt_4o_mini
  _ -> Nothing

-- | Register the API providers behind 'supportedModels' in baikai's
--   process-global registry. Idempotent, and cheap enough to call once per
--   command that might analyze.
registerAnalyzerProviders :: IO ()
registerAnalyzerProviders = do
  ClaudeApi.register
  OpenAIApi.register

systemPromptText :: Text
systemPromptText =
  "You are a release-engineering assistant. Given the tail of a failed \
  \Kubernetes Job's container logs, return a one-sentence summary of the \
  \root cause. Reply with the summary text only, no preamble."

summaryCharCap :: Int
summaryCharCap = 512

-- | The one-turn request: shiki's system prompt, and the log tail as the
--   user's only message.
analyzerContext :: Text -> Context
analyzerContext logTail =
  emptyContext
    { systemPrompt = Just systemPromptText,
      messages = V.singleton (user logTail)
    }

-- | A short, deterministic reply: this is a summary, not a conversation.
analyzerOptions :: Options
analyzerOptions =
  emptyOptions
    { maxTokens = Just 256,
      temperature = Just 0.0
    }

extractText :: Response -> Text
extractText resp =
  Text.strip $
    Text.concat
      [ text tc
      | AssistantText tc <- V.toList (flattenAssistantBlocks resp)
      ]

-- | baikai reports provider, transport, and unregistered-API failures
--   in-band as an error-shaped 'Response' rather than by throwing; this is
--   how that error reads.
renderError :: BaikaiError -> Text
renderError err = Text.pack (show (err ^. #category)) <> ": " <> err ^. #message

capChars :: Text -> Text
capChars t
  | Text.length t <= summaryCharCap = t
  | otherwise = Text.take summaryCharCap t
