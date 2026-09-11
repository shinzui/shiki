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

import Shiki.Cli.Agent.Provider
  ( AgentModelConfig (..),
    AgentProvider (..),
  )
import Shiki.Prelude
import "baikai" Baikai
  ( Api (..),
    Context (..),
    Model (..),
    Response,
    completeRequest,
    flattenAssistantBlocks,
    _Context,
    _Model,
    _Options,
  )
import "baikai" Baikai.Content (AssistantContent (..), TextContent (..))
import "baikai" Baikai.Interactive
  ( CodexApprovalPolicy (CodexApprovalOnRequest),
    CodexSandboxMode (CodexWorkspaceWrite),
    InteractiveLaunchRequest (..),
    InteractiveLaunchResult (..),
    InteractiveSafety (ClaudeAllowedTools, CodexSandbox),
  )
import "baikai" Baikai.Message (user)
import "baikai-claude" Baikai.Provider.Claude.Api qualified as ClaudeApi
import "baikai-claude" Baikai.Provider.Claude.Interactive
  ( defaultClaudeInteractiveConfig,
    launchClaudeInteractive,
  )
import "baikai-openai" Baikai.Provider.OpenAI.Api qualified as OpenAIApi
import "baikai-openai" Baikai.Provider.OpenAI.Interactive
  ( defaultCodexInteractiveConfig,
    launchCodexInteractive,
  )
import "base" Control.Exception (SomeException, try)
import "base" System.Exit (ExitCode (..), exitFailure)
import "base" System.IO (hPutStrLn, stderr)
import "directory" System.Directory (findExecutable, getCurrentDirectory)
import "text" Data.Text qualified as Text
import "text" Data.Text.IO qualified as TIO
import "vector" Data.Vector qualified as V

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
      InteractiveLaunchResult {exitCode} <-
        launchClaudeInteractive
          defaultClaudeInteractiveConfig
          InteractiveLaunchRequest
            { systemPrompt = Just sys,
              userPrompt = fromMaybe "" mPrompt,
              model = mModel,
              workingDir = Just cwd,
              extraDirs = [],
              safety = ClaudeAllowedTools assistAllowedTools,
              extraArgs = []
            }
      pure exitCode

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
      InteractiveLaunchResult {exitCode} <-
        launchCodexInteractive
          defaultCodexInteractiveConfig
          InteractiveLaunchRequest
            { systemPrompt = Just sys,
              userPrompt = fromMaybe "" mPrompt,
              model = mModel,
              workingDir = Just cwd,
              extraDirs = [],
              safety = CodexSandbox CodexWorkspaceWrite CodexApprovalOnRequest,
              extraArgs = []
            }
      pure exitCode

-- ── API one-shot calls ─────────────────────────────────────────────

runOneShotApi :: IO () -> Model -> Text -> Maybe Text -> IO ExitCode
runOneShotApi registerProvider model sys mPrompt = do
  registerProvider
  let ctx =
        _Context
          { systemPrompt = Just sys,
            messages = maybe V.empty (V.singleton . user) mPrompt
          }
  result <- try @SomeException (completeRequest model ctx _Options)
  case result of
    Left e -> do
      hPutStrLn stderr ("shiki: agent api call failed: " <> show e)
      exitFailure
    Right resp -> do
      TIO.putStrLn (extractAssistantText resp)
      pure ExitSuccess

extractAssistantText :: Response -> Text
extractAssistantText resp =
  Text.strip $
    Text.concat
      [ text tc
      | AssistantText tc <- V.toList (flattenAssistantBlocks resp)
      ]

anthropicModel :: AgentModelConfig -> Model
anthropicModel cfg =
  _Model
    { modelId = fromMaybe "claude-sonnet-4-6" (cfg ^. #model),
      name = fromMaybe "Claude Sonnet 4.6" (cfg ^. #model),
      api = AnthropicMessages,
      provider = "anthropic",
      baseUrl = "https://api.anthropic.com"
    }

openAiModel :: AgentModelConfig -> Model
openAiModel cfg =
  _Model
    { modelId = fromMaybe "gpt-4o-mini" (cfg ^. #model),
      name = fromMaybe "GPT-4o Mini" (cfg ^. #model),
      api = OpenAIChatCompletions,
      provider = "openai",
      baseUrl = "https://api.openai.com"
    }
