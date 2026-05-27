-- | The @shiki agent@ family of subcommands. Today there is exactly
--   one verb: @assist@, which opens an interactive AI session preloaded
--   with shiki's view of the operator's services and recent runs.
module Shiki.Cli.Agent
  ( AgentCommand (..)
  , AssistOptions (..)
  , agentParser
  , runAgent
  ) where

import Shiki.Prelude

import Shiki.Cli.Agent.Config (resolveAgentModelConfig)
import Shiki.Cli.Agent.Context (gatherAgentContext)
import Shiki.Cli.Agent.Launch
  ( AssistDispatch (..)
  , runAssistSession
  )
import Shiki.Cli.Agent.Prompt (renderAssistPrompt)
import Shiki.Cli.Env (CliEnv (..))
import Shiki.Persistence.Schema (Schema)

import "base" System.Exit (exitFailure, exitWith)
import "base" System.IO (hPutStrLn, stderr)
import "optparse-applicative" Options.Applicative (Parser, hsubparser, info)
import "optparse-applicative" Options.Applicative qualified as Opt
import "text" Data.Text qualified as Text

data AgentCommand
  = AgentAssist !AssistOptions
  deriving stock (Generic, Eq, Show)

data AssistOptions = AssistOptions
  { provider :: !(Maybe Text)
  , model    :: !(Maybe Text)
  , prompt   :: !(Maybe Text)
  , service  :: !(Maybe Text)
  , runId    :: !(Maybe Text)
  , debug    :: !Bool
  }
  deriving stock (Generic, Eq, Show)

agentParser :: Parser AgentCommand
agentParser =
  hsubparser
    ( Opt.command "assist"
        ( info
            (AgentAssist <$> assistOptionsParser)
            (Opt.progDesc "Open an interactive AI session preloaded with shiki context")
        )
    )

assistOptionsParser :: Parser AssistOptions
assistOptionsParser =
  AssistOptions
    <$> Opt.optional
          ( Opt.strOption
              ( Opt.long "provider"
                  <> Opt.metavar "PROVIDER"
                  <> Opt.help "Agent provider: claude-cli, codex-cli, anthropic, openai"
              )
          )
    <*> Opt.optional
          ( Opt.strOption
              ( Opt.long "model"
                  <> Opt.metavar "MODEL"
                  <> Opt.help "Agent model name or provider-specific model alias"
              )
          )
    <*> Opt.optional
          ( Opt.strOption
              ( Opt.long "prompt"
                  <> Opt.metavar "PROMPT"
                  <> Opt.help "Initial user prompt to seed the session"
              )
          )
    <*> Opt.optional
          ( Opt.strOption
              ( Opt.long "service"
                  <> Opt.metavar "NAME"
                  <> Opt.help "Pre-seed the prompt with a reference to a service"
              )
          )
    <*> Opt.optional
          ( Opt.strOption
              ( Opt.long "run"
                  <> Opt.metavar "ID"
                  <> Opt.help "Pre-seed the prompt with a reference to a run id"
              )
          )
    <*> Opt.switch
          ( Opt.long "debug"
              <> Opt.help "Print the rendered system prompt and exit"
          )

-- | Dispatch a parsed 'AgentCommand'. Today this is exactly one verb
--   ('AgentAssist'); the case-of leaves room for siblings later.
runAgent :: CliEnv -> Schema -> AgentCommand -> IO ()
runAgent env schema = \case
  AgentAssist opts -> runAssist env schema opts

runAssist :: CliEnv -> Schema -> AssistOptions -> IO ()
runAssist env schema opts = do
  cfgE <- resolveAgentModelConfig (opts ^. #provider) (opts ^. #model)
  case cfgE of
    Left err -> do
      hPutStrLn stderr ("shiki: " <> Text.unpack err)
      exitFailure
    Right cfg -> do
      ctx <- gatherAgentContext (env ^. #pool) schema
      let hints = combineHints opts
          sys   = renderAssistPrompt ctx hints
      code <- runAssistSession cfg
        AssistDispatch
          { systemPrompt = sys
          , userPrompt   = opts ^. #prompt
          , debug        = opts ^. #debug
          }
      exitWith code

-- | Build the operator's "hints" block that lands inside the system
--   prompt. The three sources (@--service@, @--run@, @--prompt@) are
--   collected into one Markdown bullet list. If none of them are set,
--   return 'Nothing' so the renderer falls back to @(no hints)@.
combineHints :: AssistOptions -> Maybe Text
combineHints opts =
  let bullets =
        [ "- Operator requested service `" <> svc <> "`." | Just svc <- [opts ^. #service] ]
          <> [ "- Operator referenced run `" <> rid <> "`." | Just rid <- [opts ^. #runId] ]
          <> [ "- Initial prompt: " <> p | Just p <- [opts ^. #prompt] ]
   in if null bullets
        then Nothing
        else Just (Text.intercalate "\n" bullets)
