-- | Top-level CLI entry point for @shiki@.
--
--   Canonical owner of the top-level 'Command' sum type per the
--   MasterPlan's Integration Points; EP-4 added 'Run' (the
--   user-visible @shiki run \<service\> -- \<args\>@ command), EP-5
--   adds 'Runs' for the @runs list / show / logs@ read subcommands.
--
--   Subcommands today:
--
--   * @shiki run SERVICE [--namespace NS] [--no-wait] [--config-dir DIR] -- ARG...@
--     — submit a one-off Kubernetes Job and record the run in Postgres.
--   * @shiki runs list [--service NAME] [--limit N]@ — recent runs as a table.
--   * @shiki runs show ID@ — one row as pretty JSON (prefix-matched).
--   * @shiki runs logs ID@ — print the captured log tail verbatim.
--   * @shiki service show NAME@ — pretty-print the parsed 'ServiceConfig'
--     for NAME as JSON. Useful for debugging service config files
--     without touching the database or the cluster.
module Shiki.Cli
  ( runCli,
  )
where

import Shiki.Cli.Agent (AgentCommand, agentParser, runAgent)
import Shiki.Cli.Config (resolveConnectionString)
import Shiki.Cli.ConfigShow (runConfigShow)
import Shiki.Cli.Env (CliEnv, withCliEnv)
import Shiki.Cli.Fzf (detectFzfConfig)
import Shiki.Cli.Fzf.Selector.Service (resolveServiceName)
import Shiki.Cli.Help (HelpCommand, helpParser, runHelp)
import Shiki.Cli.Run (RunOptions, runOptionsParser, runRun)
import Shiki.Cli.Runs (RunsCommand, runRuns, runsParser)
import Shiki.Cli.Schema (resolveSchema)
import Shiki.Persistence.Schema qualified
import Shiki.Prelude hiding (Options, argument)
import Shiki.Service.Config (ServiceConfig)
import Shiki.Service.Config.Dhall (loadServiceConfig)
import "aeson-pretty" Data.Aeson.Encode.Pretty qualified as AesonPretty
import "base" System.Exit (exitFailure)
import "bytestring" Data.ByteString.Lazy.Char8 qualified as BL8
import "optparse-applicative" Options.Applicative (Parser, ParserInfo, (<**>))
import "optparse-applicative" Options.Applicative qualified as Opt
import "text" Data.Text qualified as Text

data Command
  = Run !RunOptions
  | Runs !RunsCommand
  | ServiceShow !(Maybe Text)
  | Agent !AgentCommand
  | Help !HelpCommand
  | Config !ConfigCommand
  deriving stock (Generic, Eq, Show)

data ConfigCommand
  = ConfigShow
  deriving stock (Generic, Eq, Show)

data Options = Options
  { dbConnStr :: !(Maybe Text),
    dbSchema :: !(Maybe Text),
    envName :: !(Maybe Text),
    command :: !Command
  }
  deriving stock (Generic, Eq, Show)

runCli :: IO ()
runCli = do
  opts <- Opt.execParser parserInfo
  case opts ^. #command of
    ServiceShow nm -> serviceShowHandler nm
    Help helpOpts -> runHelp helpOpts
    Config ConfigShow ->
      runConfigShow (opts ^. #envName)
    Run runOpts ->
      withDbEnv (opts ^. #dbConnStr) (opts ^. #dbSchema) (opts ^. #envName) $ \_ env ->
        runRun env runOpts
    Runs runsOpts ->
      withDbEnv (opts ^. #dbConnStr) (opts ^. #dbSchema) (opts ^. #envName) $ \_ env ->
        runRuns env runsOpts
    Agent agentOpts ->
      withDbEnv (opts ^. #dbConnStr) (opts ^. #dbSchema) (opts ^. #envName) $ \schema env ->
        runAgent env schema agentOpts

withDbEnv ::
  Maybe Text ->
  Maybe Text ->
  Maybe Text ->
  (Shiki.Persistence.Schema.Schema -> CliEnv -> IO a) ->
  IO a
withDbEnv mConn mSchema mEnv k = do
  cs <- resolveConnectionString mConn mEnv
  schema <- resolveSchema mSchema
  withCliEnv cs schema (k schema)

serviceShowHandler :: Maybe Text -> IO ()
serviceShowHandler (Just nm) = serviceShowOne nm
serviceShowHandler Nothing = do
  fzfCfg <- detectFzfConfig
  resolveServiceName fzfCfg >>= \case
    Just nm -> serviceShowOne nm
    Nothing -> exitFailure

serviceShowOne :: Text -> IO ()
serviceShowOne nm = do
  let path = "services/" <> Text.unpack nm <> ".dhall"
  cfg <- loadServiceConfig path
  printConfig cfg

printConfig :: ServiceConfig -> IO ()
printConfig = BL8.putStrLn . AesonPretty.encodePretty

parserInfo :: ParserInfo Options
parserInfo =
  Opt.info
    (optionsParser <**> Opt.helper)
    ( Opt.fullDesc
        <> Opt.progDesc
          "shiki conducts operational commands across Kubernetes services and records what ran, where it ran, and how long it took."
        <> Opt.header "shiki - one-off Kubernetes Jobs with durable run history"
    )

optionsParser :: Parser Options
optionsParser =
  Options
    <$> Opt.optional
      ( Opt.strOption
          ( Opt.long "db"
              <> Opt.metavar "CONNSTR"
              <> Opt.help
                "Postgres connection string (overrides SHIKI_DATABASE_URL / PG_CONNECTION_STRING)"
          )
      )
    <*> Opt.optional
      ( Opt.strOption
          ( Opt.long "db-schema"
              <> Opt.metavar "SCHEMA"
              <> Opt.help
                "Postgres schema for shiki tables (default: shiki, overrides SHIKI_DB_SCHEMA)"
          )
      )
    <*> Opt.optional
      ( Opt.strOption
          ( Opt.long "env"
              <> Opt.metavar "NAME"
              <> Opt.help
                "shiki environment from shiki.dhall (overrides SHIKI_ENV / defaultEnvironment)"
          )
      )
    <*> commandParser

commandParser :: Parser Command
commandParser =
  Opt.hsubparser
    ( Opt.command
        "run"
        ( Opt.info
            (Run <$> runOptionsParser)
            (Opt.progDesc "Submit a one-off Job and record the run in Postgres")
        )
        <> Opt.command
          "runs"
          ( Opt.info
              (Runs <$> runsParser)
              (Opt.progDesc "Inspect recorded runs")
          )
        <> Opt.command
          "service"
          ( Opt.info
              serviceSubparser
              (Opt.progDesc "Inspect microservice configuration files")
          )
        <> Opt.command
          "agent"
          ( Opt.info
              (Agent <$> agentParser)
              (Opt.progDesc "Agentic helpers for driving shiki")
          )
        <> Opt.command
          "config"
          ( Opt.info
              (Config <$> configSubparser)
              (Opt.progDesc "Inspect project-local shiki.dhall configuration")
          )
        <> Opt.command
          "help"
          ( Opt.info
              (Help <$> helpParser)
              (Opt.progDesc "Show curated guides for shiki concepts")
          )
    )

configSubparser :: Parser ConfigCommand
configSubparser =
  Opt.hsubparser
    ( Opt.command
        "show"
        ( Opt.info
            (pure ConfigShow)
            (Opt.progDesc "Show the resolved project configuration and active environment")
        )
    )

serviceSubparser :: Parser Command
serviceSubparser =
  Opt.hsubparser
    ( Opt.command
        "show"
        ( Opt.info
            ( ServiceShow
                <$> Opt.optional
                  ( Opt.argument
                      Opt.str
                      ( Opt.metavar "NAME"
                          <> Opt.help
                            "Service name (basename of services/<NAME>.dhall); opens an fzf picker if omitted"
                      )
                  )
            )
            (Opt.progDesc "Pretty-print the parsed ServiceConfig for NAME (uses fzf if omitted)")
        )
    )
