-- | The @shiki agent@ family of subcommands. Today there is exactly
--   one verb: @assist@, which opens an interactive AI session preloaded
--   with shiki's view of the operator's services and recent runs.
module Shiki.Cli.Agent
  ( AgentCommand (..),
    AssistOptions (..),
    agentParser,
    runAgent,
  )
where

import Baikai.Effectful (Baikai)
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Effectful (Eff, IOE, type (:>))
import Effectful.Error.Static (Error, throwError)
import Options.Applicative (Parser, hsubparser, info)
import Options.Applicative qualified as Opt
import Shiki.Cli.Agent.Config (resolveAgentModelConfig)
import Shiki.Cli.Agent.Context (gatherAgentContext)
import Shiki.Cli.Agent.Launch
  ( AssistDispatch (..),
    runAssistSession,
  )
import Shiki.Cli.Agent.Prompt (renderAssistPrompt)
import Shiki.Cli.Error (CliError (..))
import Shiki.Effect.RunStore (RunStore)
import Shiki.Error (ShikiError)
import Shiki.Persistence.Schema (Schema)
import Shiki.Prelude
import System.Exit (exitWith)
import System.IO (stdout)

data AgentCommand
  = AgentAssist !AssistOptions
  deriving stock (Generic, Eq, Show)

data AssistOptions = AssistOptions
  { provider :: !(Maybe Text),
    model :: !(Maybe Text),
    prompt :: !(Maybe Text),
    service :: !(Maybe Text),
    runId :: !(Maybe Text),
    debug :: !Bool
  }
  deriving stock (Generic, Eq, Show)

agentParser :: Parser AgentCommand
agentParser =
  hsubparser
    ( Opt.command
        "assist"
        ( info
            (AgentAssist <$> assistOptionsParser)
            (Opt.progDesc "Open an interactive AI session preloaded with shiki context")
        )
    )

-- | The flags render under @Provider@ and @Session context@ headings in
--   @--help@; @--debug@ stays in the default options section.
assistOptionsParser :: Parser AssistOptions
assistOptionsParser =
  (\(prov, mdl) (prm, svc, rid) dbg -> AssistOptions prov mdl prm svc rid dbg)
    <$> Opt.parserOptionGroup "Provider" ((,) <$> providerOpt <*> modelOpt)
    <*> Opt.parserOptionGroup "Session context" ((,,) <$> promptOpt <*> serviceOpt <*> runOpt)
    <*> debugSwitch
  where
    providerOpt =
      Opt.optional
        ( Opt.strOption
            ( Opt.long "provider"
                <> Opt.metavar "PROVIDER"
                <> Opt.help "Agent provider: claude-cli, codex-cli, anthropic, openai"
            )
        )
    modelOpt =
      Opt.optional
        ( Opt.strOption
            ( Opt.long "model"
                <> Opt.metavar "MODEL"
                <> Opt.help "Agent model name or provider-specific model alias"
            )
        )
    promptOpt =
      Opt.optional
        ( Opt.strOption
            ( Opt.long "prompt"
                <> Opt.metavar "PROMPT"
                <> Opt.help "Initial user prompt to seed the session"
            )
        )
    serviceOpt =
      Opt.optional
        ( Opt.strOption
            ( Opt.long "service"
                <> Opt.metavar "NAME"
                <> Opt.help "Pre-seed the prompt with a reference to a service"
            )
        )
    runOpt =
      Opt.optional
        ( Opt.strOption
            ( Opt.long "run"
                <> Opt.metavar "ID"
                <> Opt.help "Pre-seed the prompt with a reference to a run id"
            )
        )
    debugSwitch =
      Opt.switch
        ( Opt.long "debug"
            <> Opt.help "Print the rendered system prompt and exit"
        )

-- | Dispatch a parsed 'AgentCommand'. Today this is exactly one verb
--   ('AgentAssist'); the case-of leaves room for siblings later.
runAgent ::
  ( RunStore :> es,
    Baikai :> es,
    IOE :> es,
    Error ShikiError :> es,
    Error CliError :> es
  ) =>
  Schema ->
  AgentCommand ->
  Eff es ()
runAgent schema = \case
  AgentAssist opts -> runAssist schema opts

runAssist ::
  ( RunStore :> es,
    Baikai :> es,
    IOE :> es,
    Error ShikiError :> es,
    Error CliError :> es
  ) =>
  Schema ->
  AssistOptions ->
  Eff es ()
runAssist schema opts = do
  cfgE <- liftIO (resolveAgentModelConfig (opts ^. #provider) (opts ^. #model))
  case cfgE of
    Left err -> throwError (AgentProviderInvalid err)
    Right cfg -> do
      ctx <- gatherAgentContext schema
      let hints = combineHints opts
          sys = renderAssistPrompt ctx hints
      code <-
        runAssistSession
          stdout
          cfg
          AssistDispatch
            { systemPrompt = sys,
              userPrompt = opts ^. #prompt,
              debug = opts ^. #debug
            }
      -- The child's own status is the command's status; 'runShikiMain' passes
      -- an 'ExitCode' through untouched.
      liftIO (exitWith code)

-- | Build the operator's "hints" block that lands inside the system
--   prompt. The three sources (@--service@, @--run@, @--prompt@) are
--   collected into one Markdown bullet list. If none of them are set,
--   return 'Nothing' so the renderer falls back to @(no hints)@.
combineHints :: AssistOptions -> Maybe Text
combineHints opts =
  let bullets =
        ["- Operator requested service `" <> svc <> "`." | Just svc <- [opts ^. #service]]
          <> ["- Operator referenced run `" <> rid <> "`." | Just rid <- [opts ^. #runId]]
          <> ["- Initial prompt: " <> p | Just p <- [opts ^. #prompt]]
   in if null bullets
        then Nothing
        else Just (Text.intercalate "\n" bullets)
