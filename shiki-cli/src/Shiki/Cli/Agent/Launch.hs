-- | Dispatch a rendered system prompt to the right backend. Four
--   branches:
--
--     * @--debug@ short-circuits to stdout and exits 0;
--     * 'ClaudeCli' and 'CodexCli' spawn the local interactive CLI
--       subprocess via 'launchClaudeInteractive' /
--       'launchCodexInteractive' from the @baikai-*@ vendor packages;
--     * 'Anthropic' and 'OpenAI' issue one non-interactive
--       'Baikai.completeRequest' and print the assistant text.
--
--   The allowed-tool list is hard-coded here (see the EP-8 Decision
--   Log entry) so each session ships with the same defense-in-depth.
module Shiki.Cli.Agent.Launch
  ( AssistDispatch (..),
    runAssistSession,
    assistAllowedTools,
  )
where

import Baikai
  ( Api (..),
    BaikaiError,
    Model,
    Response,
    completeRequest,
    emptyContext,
    emptyModel,
    emptyOptions,
    flattenAssistantBlocks,
    responseError,
  )
import Baikai.Agent (AgentRenderError, renderAgentRenderError)
import Baikai.Content (AssistantContent (..), TextContent (..))
import Baikai.Context qualified as Context
import Baikai.Interactive
  ( CodexApprovalPolicy (CodexApprovalOnRequest),
    CodexSandboxMode (CodexWorkspaceWrite),
    InteractiveLaunchResult (..),
    InteractiveSafety (ClaudeAllowedTools, CodexSandbox),
    interactiveLaunchRequest,
  )
import Baikai.Interactive qualified as Interactive
import Baikai.Message (user)
import Baikai.Model qualified as Model
import Baikai.Provider.Claude.Api qualified as ClaudeApi
import Baikai.Provider.Claude.Interactive
  ( defaultClaudeInteractiveConfig,
    launchClaudeInteractive,
  )
import Baikai.Provider.OpenAI.Api qualified as OpenAIApi
import Baikai.Provider.OpenAI.Interactive
  ( defaultCodexInteractiveConfig,
    launchCodexInteractive,
  )
import Control.Exception (SomeException, try)
import Data.Text qualified as Text
import Data.Text.IO qualified as TIO
import Data.Vector qualified as V
import Shiki.Cli.Agent.Provider
  ( AgentModelConfig (..),
    AgentProvider (..),
  )
import Shiki.Prelude
import System.Directory (findExecutable, getCurrentDirectory)
import System.Exit (ExitCode (..), exitFailure)
import System.IO (hPutStrLn, stderr)

-- | Inputs to one assist-session dispatch.
data AssistDispatch = AssistDispatch
  { systemPrompt :: !Text,
    userPrompt :: !(Maybe Text),
    debug :: !Bool
  }
  deriving stock (Generic, Eq, Show)

-- | The hard-coded allowed-tool list every Claude Code assist session
--   ships with. Scoped to the verbs an operator would not be surprised
--   to see issued on their behalf.
assistAllowedTools :: [Text]
assistAllowedTools =
  [ "Bash(shiki *)",
    "Bash(kubectl get *)",
    "Bash(kubectl logs *)",
    "Bash(pwd)",
    "Bash(ls *)",
    "Bash(cat *)",
    "Read",
    "Glob",
    "Grep"
  ]

-- | Run one assist-session dispatch and return its exit code (or
--   'ExitSuccess' for the debug and API paths).
runAssistSession :: AgentModelConfig -> AssistDispatch -> IO ExitCode
runAssistSession cfg dispatch
  | dispatch ^. #debug = do
      TIO.putStr (dispatch ^. #systemPrompt)
      pure ExitSuccess
  | otherwise = case cfg ^. #provider of
      ClaudeCli ->
        launchClaude
          (cfg ^. #model)
          (dispatch ^. #systemPrompt)
          (dispatch ^. #userPrompt)
      CodexCli ->
        launchCodex
          (cfg ^. #model)
          (dispatch ^. #systemPrompt)
          (dispatch ^. #userPrompt)
      Anthropic ->
        runOneShotApi
          ClaudeApi.register
          (anthropicModel cfg)
          (dispatch ^. #systemPrompt)
          (dispatch ^. #userPrompt)
      OpenAI ->
        runOneShotApi
          OpenAIApi.register
          (openAiModel cfg)
          (dispatch ^. #systemPrompt)
          (dispatch ^. #userPrompt)

-- ── Interactive CLI launches ───────────────────────────────────────

launchClaude :: Maybe Text -> Text -> Maybe Text -> IO ExitCode
launchClaude mModel sys mPrompt = do
  mExe <- findExecutable "claude"
  case mExe of
    Nothing -> do
      hPutStrLn
        stderr
        "shiki: 'claude' CLI not found on PATH (install: https://docs.anthropic.com/en/docs/claude-code)"
      exitFailure
    Just _ -> do
      cwd <- getCurrentDirectory
      launchExitCode
        =<< launchClaudeInteractive
          defaultClaudeInteractiveConfig
          (interactiveLaunchRequest (fromMaybe "" mPrompt))
            { Interactive.systemPrompt = Just sys,
              Interactive.modelId = mModel,
              Interactive.workingDir = Just cwd,
              Interactive.safety = ClaudeAllowedTools assistAllowedTools
            }

launchCodex :: Maybe Text -> Text -> Maybe Text -> IO ExitCode
launchCodex mModel sys mPrompt = do
  mExe <- findExecutable "codex"
  case mExe of
    Nothing -> do
      hPutStrLn
        stderr
        "shiki: 'codex' CLI not found on PATH (install and authenticate Codex CLI, then retry)"
      exitFailure
    Just _ -> do
      cwd <- getCurrentDirectory
      launchExitCode
        =<< launchCodexInteractive
          defaultCodexInteractiveConfig
          (interactiveLaunchRequest (fromMaybe "" mPrompt))
            { Interactive.systemPrompt = Just sys,
              Interactive.modelId = mModel,
              Interactive.workingDir = Just cwd,
              Interactive.safety = CodexSandbox CodexWorkspaceWrite CodexApprovalOnRequest
            }

-- | The launchers refuse, without spawning anything, a request whose
--   safety policy the CLI cannot express.
launchExitCode :: Either AgentRenderError InteractiveLaunchResult -> IO ExitCode
launchExitCode = \case
  Left err -> do
    hPutStrLn stderr ("shiki: " <> Text.unpack (renderAgentRenderError err))
    exitFailure
  Right InteractiveLaunchResult {exitCode} -> pure exitCode

-- ── API one-shot calls ─────────────────────────────────────────────

runOneShotApi :: IO () -> Model -> Text -> Maybe Text -> IO ExitCode
runOneShotApi registerProvider model sys mPrompt = do
  registerProvider
  let ctx =
        emptyContext
          { Context.systemPrompt = Just sys,
            Context.messages = maybe V.empty (V.singleton . user) mPrompt
          }
  result <- try @SomeException (completeRequest model ctx emptyOptions)
  case result of
    Left e -> do
      hPutStrLn stderr ("shiki: agent api call failed: " <> show e)
      exitFailure
    Right resp -> case responseError resp of
      Just err -> do
        hPutStrLn stderr ("shiki: agent api call failed: " <> renderError err)
        exitFailure
      Nothing -> do
        TIO.putStrLn (extractAssistantText resp)
        pure ExitSuccess

-- | baikai reports provider, transport, and unregistered-API failures
--   in-band as an error-shaped 'Response' rather than by throwing.
renderError :: BaikaiError -> String
renderError err = show (err ^. #category) <> ": " <> Text.unpack (err ^. #message)

extractAssistantText :: Response -> Text
extractAssistantText resp =
  Text.strip $
    Text.concat
      [ text tc
      | AssistantText tc <- V.toList (flattenAssistantBlocks resp)
      ]

anthropicModel :: AgentModelConfig -> Model
anthropicModel cfg =
  emptyModel
    { Model.modelId = fromMaybe "claude-sonnet-4-6" (cfg ^. #model),
      Model.name = fromMaybe "Claude Sonnet 4.6" (cfg ^. #model),
      Model.api = AnthropicMessages,
      Model.provider = "anthropic",
      Model.baseUrl = "https://api.anthropic.com"
    }

openAiModel :: AgentModelConfig -> Model
openAiModel cfg =
  emptyModel
    { Model.modelId = fromMaybe "gpt-4o-mini" (cfg ^. #model),
      Model.name = fromMaybe "GPT-4o Mini" (cfg ^. #model),
      Model.api = OpenAIChatCompletions,
      Model.provider = "openai",
      Model.baseUrl = "https://api.openai.com"
    }
