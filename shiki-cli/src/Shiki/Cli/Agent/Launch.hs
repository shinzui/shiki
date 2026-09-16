-- | Dispatch a rendered system prompt to the right backend. Four
--   branches:
--
--     * @--debug@ short-circuits to the output handle and exits 0;
--     * 'ClaudeCli' and 'CodexCli' spawn the local interactive CLI
--       subprocess via 'launchClaudeInteractive' /
--       'launchCodexInteractive' from the @baikai-*@ vendor packages;
--     * 'Anthropic' and 'OpenAI' issue one non-interactive completion
--       through @baikai-effectful@'s @Baikai@ effect and print the
--       assistant text.
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
    emptyContext,
    emptyModel,
    emptyOptions,
    flattenAssistantBlocks,
    responseError,
  )
import Baikai.Agent (AgentRenderError, renderAgentRenderError)
import Baikai.Content (AssistantContent (..), TextContent (..))
import Baikai.Context qualified as Context
import Baikai.Effectful (Baikai, complete)
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
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Data.Text.IO qualified as TIO
import Data.Vector qualified as V
import Effectful (Eff, IOE, type (:>))
import Effectful.Error.Static (Error, throwError)
import Effectful.Exception qualified as Exc
import Shiki.Cli.Agent.Provider
  ( AgentModelConfig (..),
    AgentProvider (..),
  )
import Shiki.Cli.Error (CliError (..))
import Shiki.Prelude
import System.Directory (findExecutable, getCurrentDirectory)
import System.Exit (ExitCode (..))
import System.IO (Handle)

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
--
--   The handle is where this session's own output goes — the rendered prompt
--   under @--debug@, the assistant's reply on the API paths. Production passes
--   'System.IO.stdout'; a test passes a file, which is what lets it assert on
--   the output without swapping the process's file descriptors out from under
--   the test runner. An interactive CLI launch inherits the process's stdout
--   either way, because it is a child process.
runAssistSession ::
  (Baikai :> es, IOE :> es, Error CliError :> es) =>
  Handle ->
  AgentModelConfig ->
  AssistDispatch ->
  Eff es ExitCode
runAssistSession out cfg dispatch
  | dispatch ^. #debug = do
      liftIO (TIO.hPutStr out (dispatch ^. #systemPrompt))
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
          out
          ClaudeApi.register
          (anthropicModel cfg)
          (dispatch ^. #systemPrompt)
          (dispatch ^. #userPrompt)
      OpenAI ->
        runOneShotApi
          out
          OpenAIApi.register
          (openAiModel cfg)
          (dispatch ^. #systemPrompt)
          (dispatch ^. #userPrompt)

-- ── Interactive CLI launches ───────────────────────────────────────

launchClaude ::
  (IOE :> es, Error CliError :> es) =>
  Maybe Text ->
  Text ->
  Maybe Text ->
  Eff es ExitCode
launchClaude mModel sys mPrompt = do
  mExe <- liftIO (findExecutable "claude")
  case mExe of
    Nothing ->
      throwError
        ( AgentBinaryMissing
            "claude"
            "install: https://docs.anthropic.com/en/docs/claude-code"
        )
    Just _ -> do
      cwd <- liftIO getCurrentDirectory
      launchExitCode
        =<< spawn
          ( launchClaudeInteractive
              defaultClaudeInteractiveConfig
              (interactiveLaunchRequest (fromMaybe "" mPrompt))
                { Interactive.systemPrompt = Just sys,
                  Interactive.modelId = mModel,
                  Interactive.workingDir = Just cwd,
                  Interactive.safety = ClaudeAllowedTools assistAllowedTools
                }
          )

launchCodex ::
  (IOE :> es, Error CliError :> es) =>
  Maybe Text ->
  Text ->
  Maybe Text ->
  Eff es ExitCode
launchCodex mModel sys mPrompt = do
  mExe <- liftIO (findExecutable "codex")
  case mExe of
    Nothing ->
      throwError
        ( AgentBinaryMissing
            "codex"
            "install and authenticate Codex CLI, then retry"
        )
    Just _ -> do
      cwd <- liftIO getCurrentDirectory
      launchExitCode
        =<< spawn
          ( launchCodexInteractive
              defaultCodexInteractiveConfig
              (interactiveLaunchRequest (fromMaybe "" mPrompt))
                { Interactive.systemPrompt = Just sys,
                  Interactive.modelId = mModel,
                  Interactive.workingDir = Just cwd,
                  Interactive.safety = CodexSandbox CodexWorkspaceWrite CodexApprovalOnRequest
                }
          )

-- | Spawning the child is a subprocess call, not a 'Baikai' one, so an
--   exception from it is caught here and named rather than left to the
--   top-level handler's \"unexpected error\" fallback.
spawn ::
  (IOE :> es, Error CliError :> es) =>
  IO (Either AgentRenderError InteractiveLaunchResult) ->
  Eff es (Either AgentRenderError InteractiveLaunchResult)
spawn act =
  Exc.trySync (liftIO act) >>= \case
    Right outcome -> pure outcome
    Left e -> throwError (AgentPromptInvalid (Text.pack (Exc.displayException e)))

-- | The launchers refuse, without spawning anything, a request whose
--   safety policy the CLI cannot express.
launchExitCode ::
  (Error CliError :> es) =>
  Either AgentRenderError InteractiveLaunchResult ->
  Eff es ExitCode
launchExitCode = \case
  Left err -> throwError (AgentPromptInvalid (renderAgentRenderError err))
  Right InteractiveLaunchResult {exitCode} -> pure exitCode

-- ── API one-shot calls ─────────────────────────────────────────────

runOneShotApi ::
  (Baikai :> es, IOE :> es, Error CliError :> es) =>
  Handle ->
  IO () ->
  Model ->
  Text ->
  Maybe Text ->
  Eff es ExitCode
runOneShotApi out registerProvider model sys mPrompt = do
  liftIO registerProvider
  let ctx =
        emptyContext
          { Context.systemPrompt = Just sys,
            Context.messages = maybe V.empty (V.singleton . user) mPrompt
          }
  -- 'complete' reports provider failures in-band, but a transport that dies
  -- mid-request still throws; both read the same to an operator.
  Exc.trySync (complete model ctx emptyOptions) >>= \case
    Left e -> throwError (AgentRequestFailed (Text.pack (Exc.displayException e)))
    Right resp -> case responseError resp of
      Just err -> throwError (AgentRequestFailed (renderError err))
      Nothing -> do
        liftIO (TIO.hPutStrLn out (extractAssistantText resp))
        pure ExitSuccess

-- | baikai reports provider, transport, and unregistered-API failures
--   in-band as an error-shaped 'Response' rather than by throwing.
renderError :: BaikaiError -> Text
renderError err = Text.pack (show (err ^. #category)) <> ": " <> (err ^. #message)

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
