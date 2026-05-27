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
  ( runCli
  ) where

import Shiki.Prelude hiding (Options, argument)

import Shiki.Cli.Config (resolveConnectionString)
import Shiki.Cli.Env (CliEnv, withCliEnv)
import Shiki.Cli.Run (RunOptions, runOptionsParser, runRun)
import Shiki.Cli.Runs (RunsCommand, runRuns, runsParser)
import Shiki.Service.Config (ServiceConfig)
import Shiki.Service.Config.Dhall (loadServiceConfig)

import "aeson-pretty" Data.Aeson.Encode.Pretty qualified as AesonPretty
import "bytestring" Data.ByteString.Lazy.Char8 qualified as BL8
import "text" Data.Text qualified as Text
import "optparse-applicative" Options.Applicative (Parser, ParserInfo, (<**>))
import "optparse-applicative" Options.Applicative qualified as Opt

data Command
  = Run         !RunOptions
  | Runs        !RunsCommand
  | ServiceShow !Text
  deriving stock (Generic, Eq, Show)

data Options = Options
  { dbConnStr :: !(Maybe Text)
  , command   :: !Command
  }
  deriving stock (Generic, Eq, Show)

runCli :: IO ()
runCli = do
  opts <- Opt.execParser parserInfo
  case opts ^. #command of
    ServiceShow nm -> serviceShowHandler nm
    Run runOpts    ->
      withDbEnv (opts ^. #dbConnStr) $ \env -> runRun env runOpts
    Runs runsOpts  ->
      withDbEnv (opts ^. #dbConnStr) $ \env -> runRuns env runsOpts

withDbEnv :: Maybe Text -> (CliEnv -> IO a) -> IO a
withDbEnv mFlag k = do
  cs <- resolveConnectionString mFlag
  withCliEnv cs k

serviceShowHandler :: Text -> IO ()
serviceShowHandler nm = do
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
    <*> commandParser

commandParser :: Parser Command
commandParser =
  Opt.hsubparser
    ( Opt.command "run"
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
    )

serviceSubparser :: Parser Command
serviceSubparser =
  Opt.hsubparser
    ( Opt.command "show"
        ( Opt.info
            (ServiceShow <$> Opt.argument Opt.str (Opt.metavar "NAME"))
            (Opt.progDesc "Pretty-print the parsed ServiceConfig for NAME")
        )
    )
