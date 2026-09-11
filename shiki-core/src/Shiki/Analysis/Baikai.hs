-- | LLM-backed analyzer: hands the captured log tail to a baikai model
--   and returns the model's one-sentence root-cause summary. Used by
--   the @shiki runs analyze --analyzer=baikai:\<id\>@ post-hoc path; never
--   reached by the inline @shiki run@ path.
module Shiki.Analysis.Baikai
  ( runBaikai,
    supportedModels,
  )
where

import Shiki.Prelude
import "baikai" Baikai
  ( BaikaiError,
    Response,
    completeRequest,
    emptyContext,
    emptyOptions,
    flattenAssistantBlocks,
    maxTokens,
    messages,
    responseError,
    systemPrompt,
    temperature,
  )
import "baikai" Baikai.Content (AssistantContent (..), TextContent (..))
import "baikai" Baikai.Message (user)
import "baikai" Baikai.Model (Model)
import "baikai" Baikai.Models.Generated qualified as Models
import "baikai-claude" Baikai.Provider.Claude.Api qualified as ClaudeApi
import "baikai-openai" Baikai.Provider.OpenAI.Api qualified as OpenAIApi
import "base" Control.Exception (SomeException, try)
import "text" Data.Text qualified as Text
import "vector" Data.Vector qualified as V

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

systemPromptText :: Text
systemPromptText =
  "You are a release-engineering assistant. Given the tail of a failed \
  \Kubernetes Job's container logs, return a one-sentence summary of the \
  \root cause. Reply with the summary text only, no preamble."

summaryCharCap :: Int
summaryCharCap = 512

-- | Dispatch a one-shot summarization request through the named baikai
--   model. The first argument is a baikai catalog id (one of
--   'supportedModels'); the second is the captured log tail. The
--   matching provider is registered lazily and idempotently per call.
runBaikai :: Text -> Text -> IO (Either Text Text)
runBaikai modelId logTail = case lookupModel modelId of
  Nothing -> pure (Left ("unknown baikai model: " <> modelId))
  Just (model, registerProvider) -> do
    registerProvider
    let ctx =
          emptyContext
            { systemPrompt = Just systemPromptText,
              messages = V.singleton (user logTail)
            }
        opts =
          emptyOptions
            { maxTokens = Just 256,
              temperature = Just 0.0
            }
    result <- try @SomeException (completeRequest model ctx opts)
    case result of
      Left e -> pure (Left (Text.pack (show e)))
      Right resp -> case responseError resp of
        Just err -> pure (Left (renderError err))
        Nothing -> pure (Right (capChars (extractText resp)))

lookupModel :: Text -> Maybe (Model, IO ())
lookupModel = \case
  "anthropic_claude_haiku_4_5" -> Just (Models.anthropic_claude_haiku_4_5, ClaudeApi.register)
  "anthropic_claude_sonnet_4_6" -> Just (Models.anthropic_claude_sonnet_4_6, ClaudeApi.register)
  "openai_gpt_4o_mini" -> Just (Models.openai_gpt_4o_mini, OpenAIApi.register)
  _ -> Nothing

extractText :: Response -> Text
extractText resp =
  Text.strip $
    Text.concat
      [ text tc
      | AssistantText tc <- V.toList (flattenAssistantBlocks resp)
      ]

-- | baikai reports provider, transport, and unregistered-API failures
--   in-band as an error-shaped 'Response' rather than by throwing.
renderError :: BaikaiError -> Text
renderError err = Text.pack (show (err ^. #category)) <> ": " <> err ^. #message

capChars :: Text -> Text
capChars t
  | Text.length t <= summaryCharCap = t
  | otherwise = Text.take summaryCharCap t
