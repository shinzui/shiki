-- | Resolve the final 'AgentModelConfig' for a @shiki agent assist@
--   invocation by layering CLI flag → environment variable → built-in
--   default. The env-var spellings are 'SHIKI_AGENT_PROVIDER' and
--   'SHIKI_AGENT_MODEL'.
module Shiki.Cli.Agent.Config
  ( resolveAgentModelConfig,
    providerEnvVar,
    modelEnvVar,
  )
where

import Data.Text qualified as Text
import Shiki.Cli.Agent.Provider
  ( AgentModelConfig (..),
    AgentProvider,
    defaultAgentModelConfig,
    providerFromText,
  )
import Shiki.Prelude
import System.Environment (lookupEnv)

providerEnvVar :: String
providerEnvVar = "SHIKI_AGENT_PROVIDER"

modelEnvVar :: String
modelEnvVar = "SHIKI_AGENT_MODEL"

-- | Resolve a model config from the CLI argument (if any) and the
--   environment, falling back to 'defaultAgentModelConfig'. Returns
--   'Left' iff a provider spelling could not be parsed (either the CLI
--   flag value or the env-var value).
resolveAgentModelConfig ::
  Maybe Text ->
  Maybe Text ->
  IO (Either Text AgentModelConfig)
resolveAgentModelConfig mProviderFlag mModelFlag = do
  envProvider <- lookupEnvText providerEnvVar
  envModel <- lookupEnvText modelEnvVar
  pure $ do
    prov <- resolveProvider mProviderFlag envProvider
    let mdl = mModelFlag <|> envModel
    Right AgentModelConfig {provider = prov, model = mdl}

resolveProvider ::
  Maybe Text ->
  Maybe Text ->
  Either Text AgentProvider
resolveProvider mFlag mEnv = case mFlag <|> mEnv of
  Nothing -> Right (defaultAgentModelConfig ^. #provider)
  Just raw -> providerFromText raw

lookupEnvText :: String -> IO (Maybe Text)
lookupEnvText name = do
  m <- lookupEnv name
  pure $ case m of
    Just s | not (null s) -> Just (Text.pack s)
    _ -> Nothing
