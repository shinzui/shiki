module Shiki.Cli.Agent.ProviderSpec
  ( tests,
  )
where

import Control.Exception (bracket)
import Shiki.Cli.Agent.Config
  ( modelEnvVar,
    providerEnvVar,
    resolveAgentModelConfig,
  )
import Shiki.Cli.Agent.Provider
  ( AgentModelConfig (..),
    AgentProvider (..),
    defaultAgentModelConfig,
    providerFromText,
    providerToText,
  )
import System.Environment (lookupEnv, setEnv, unsetEnv)
import Test.Tasty (DependencyType (..), TestTree, sequentialTestGroup, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase)

tests :: TestTree
tests =
  testGroup
    "Shiki.Cli.Agent.Provider"
    [ providerFromTextCases,
      roundTripCases,
      resolveCases
    ]

providerFromTextCases :: TestTree
providerFromTextCases =
  testGroup
    "providerFromText"
    [ testCase "claude-cli" $
        assertEqual "" (Right ClaudeCli) (providerFromText "claude-cli"),
      testCase "codex-cli" $
        assertEqual "" (Right CodexCli) (providerFromText "codex-cli"),
      testCase "anthropic" $
        assertEqual "" (Right Anthropic) (providerFromText "anthropic"),
      testCase "openai" $
        assertEqual "" (Right OpenAI) (providerFromText "openai"),
      testCase "case-insensitive" $
        assertEqual "" (Right ClaudeCli) (providerFromText "Claude-CLI"),
      testCase "strips whitespace" $
        assertEqual "" (Right OpenAI) (providerFromText "  openai\n"),
      testCase "unknown spelling" $
        case providerFromText "gemini" of
          Left _ -> pure ()
          Right _ -> assertBool "expected Left for unknown provider" False
    ]

roundTripCases :: TestTree
roundTripCases =
  testGroup "providerToText . providerFromText round-trips" $
    flip map [ClaudeCli, CodexCli, Anthropic, OpenAI] $ \p ->
      testCase (show p) $
        assertEqual "" (Right p) (providerFromText (providerToText p))

resolveCases :: TestTree
resolveCases =
  sequentialTestGroup
    "resolveAgentModelConfig"
    AllSucceed
    [ testCase "flag wins" $
        withCleanEnv $ do
          r <- resolveAgentModelConfig (Just "openai") Nothing
          assertEqual
            ""
            (Right AgentModelConfig {provider = OpenAI, model = Nothing})
            r,
      testCase "env-only fallback" $
        withCleanEnv $ do
          setEnv providerEnvVar "anthropic"
          setEnv modelEnvVar "claude-sonnet-4-6"
          r <- resolveAgentModelConfig Nothing Nothing
          assertEqual
            ""
            ( Right
                AgentModelConfig
                  { provider = Anthropic,
                    model = Just "claude-sonnet-4-6"
                  }
            )
            r,
      testCase "default when nothing set" $
        withCleanEnv $ do
          r <- resolveAgentModelConfig Nothing Nothing
          assertEqual "" (Right defaultAgentModelConfig) r,
      testCase "bad env returns Left" $
        withCleanEnv $ do
          setEnv providerEnvVar "bogus"
          r <- resolveAgentModelConfig Nothing Nothing
          case r of
            Left _ -> pure ()
            Right _ -> assertBool "expected Left for bad env provider" False,
      testCase "flag overrides bad env" $
        withCleanEnv $ do
          setEnv providerEnvVar "bogus"
          r <- resolveAgentModelConfig (Just "claude-cli") Nothing
          assertEqual
            ""
            (Right AgentModelConfig {provider = ClaudeCli, model = Nothing})
            r
    ]

-- | Snapshot, clear, restore the two env vars this module uses so each
--   case starts from a known-clean baseline.
withCleanEnv :: IO a -> IO a
withCleanEnv body =
  bracket snapshot restore $ \_ -> do
    unsetEnv providerEnvVar
    unsetEnv modelEnvVar
    body
  where
    snapshot = do
      p <- lookupEnv providerEnvVar
      m <- lookupEnv modelEnvVar
      pure (p, m)
    restore (p, m) = do
      restoreOne providerEnvVar p
      restoreOne modelEnvVar m
    restoreOne name = \case
      Just v -> setEnv name v
      Nothing -> unsetEnv name
