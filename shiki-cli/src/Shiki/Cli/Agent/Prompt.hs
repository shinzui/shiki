{-# LANGUAGE TemplateHaskell #-}

-- | Render the @shiki agent assist@ system prompt from an
--   'AgentContext'. The template lives in
--   @shiki-cli/data/prompts/assist.md@ and is embedded into the binary
--   at compile time via 'embedFile'; the placeholders @{{cwd}}@,
--   @{{schema}}@, @{{cluster}}@, @{{services_dir}}@, @{{services}}@,
--   @{{recent_runs}}@, and @{{user_prompt}}@ are substituted with the
--   matching values. There is no template language; all formatting
--   happens in the helpers below before substitution.
module Shiki.Cli.Agent.Prompt
  ( renderAssistPrompt,
  )
where

import Data.FileEmbed (embedStringFile)
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Shiki.Cli.Agent.Context
  ( AgentContext (..),
    ServiceSummary (..),
  )
import Shiki.Cli.Runs.Format (displayStatus)
import Shiki.Persistence.Run (RunId (..), RunRecord)
import Shiki.Persistence.RunStatus (runStatusToText)
import Shiki.Prelude

-- | The raw markdown template baked into the binary.
defaultAssistPrompt :: Text
defaultAssistPrompt =
  TE.decodeUtf8 $(embedStringFile "data/prompts/assist.md")

-- | Render the system prompt for a session. The optional second
--   argument is the operator's @--prompt@ hint; 'Nothing' becomes the
--   placeholder @(no hints)@.
renderAssistPrompt :: AgentContext -> Maybe Text -> Text
renderAssistPrompt ctx mUserPrompt =
  substitute
    defaultAssistPrompt
    [ ("cwd", ctx ^. #cwd),
      ("schema", ctx ^. #schemaName),
      ("cluster", ctx ^. #cluster),
      ("services_dir", Text.pack (ctx ^. #servicesDir)),
      ("services", formatServices (ctx ^. #services)),
      ("recent_runs", formatRuns (ctx ^. #observedAt) (ctx ^. #recentRuns)),
      ("user_prompt", fromMaybe "(no hints)" mUserPrompt)
    ]

-- | Replace every @{{name}}@ token in the template with the matching
--   value. Tokens with no entry are left untouched (a typo in the
--   template surfaces in the rendered output rather than silently
--   evaluating to empty string).
substitute :: Text -> [(Text, Text)] -> Text
substitute tpl =
  foldl' (\t (k, v) -> Text.replace ("{{" <> k <> "}}") v t) tpl

formatServices :: [ServiceSummary] -> Text
formatServices = \case
  [] -> "(none declared)"
  xs -> Text.intercalate "\n" (map renderOne xs)
  where
    renderOne s =
      "- "
        <> s ^. #name
        <> " (namespace: "
        <> s ^. #defaultNamespace
        <> ", analyzer: "
        <> s ^. #analyzer
        <> ")"

formatRuns :: Maybe UTCTime -> [RunRecord] -> Text
formatRuns mObservedAt = \case
  [] -> "(no runs yet)"
  xs -> Text.intercalate "\n" (map renderOne xs)
  where
    renderOne r =
      "- "
        <> Text.take 8 (Text.pack (show (unRunId (r ^. #runId))))
        <> "  "
        <> r ^. #serviceName
        <> "  "
        <> maybe
          (runStatusToText (r ^. #status))
          (\observedAtDb -> displayStatus observedAtDb r)
          mObservedAt
        <> "  "
        <> fromMaybe "-" (r ^. #errorSummary)
