-- | Top-level CLI entry point for shiki.
--
--   The current scaffold ships two subcommands:
--
--   * @shiki hello [--name NAME]@ — a placeholder greeting carried over from
--     the initial project skeleton; later plans (EP-4) remove it.
--   * @shiki service show NAME@ — load
--     @services\/\<NAME\>.dhall@, decode it into a 'ServiceConfig', and
--     pretty-print the result as JSON to stdout. This proves end-to-end
--     that the typed configuration loader works without touching
--     Kubernetes or PostgreSQL.
module Shiki.Cli
  ( runCli
  ) where

import Shiki.Prelude hiding (Options, argument)

import Shiki.Service.Config (ServiceConfig)
import Shiki.Service.Config.Dhall (loadServiceConfig)

import "aeson-pretty" Data.Aeson.Encode.Pretty qualified as AesonPretty
import "bytestring" Data.ByteString.Lazy.Char8 qualified as BL8
import "text" Data.Text qualified as Text
import "text" Data.Text.IO qualified as TIO
import "optparse-applicative" Options.Applicative

data Command
  = Hello !(Maybe Text)
  | ServiceShow !Text
  deriving stock (Eq, Show)

newtype Options = Options
  { command :: Command
  }
  deriving stock (Generic, Eq, Show)

runCli :: IO ()
runCli = do
  opts <- execParser parserInfo
  runCommand (opts ^. #command)

parserInfo :: ParserInfo Options
parserInfo =
  info
    (optionsParser <**> helper)
    ( fullDesc
        <> progDesc
          "shiki conducts operational commands across Kubernetes services and records what ran, where it ran, and how long it took."
        <> header "shiki - one-off Kubernetes Jobs with durable run history"
    )

optionsParser :: Parser Options
optionsParser = Options <$> commandParser

commandParser :: Parser Command
commandParser =
  hsubparser
    ( Options.Applicative.command "hello"
        ( info
            ( Hello
                <$> optional
                      (strOption (long "name" <> metavar "NAME" <> help "Whom to greet"))
            )
            (progDesc "Print a greeting")
        )
        <> Options.Applicative.command
          "service"
          ( info
              serviceCommand
              (progDesc "Inspect microservice configuration files")
          )
    )

serviceCommand :: Parser Command
serviceCommand =
  hsubparser
    ( Options.Applicative.command
        "show"
        ( info
            (ServiceShow <$> argument str (metavar "NAME"))
            (progDesc "Pretty-print the parsed ServiceConfig for NAME")
        )
    )

runCommand :: Command -> IO ()
runCommand (Hello mName) =
  TIO.putStrLn ("Hello, " <> fromMaybe "shiki" mName <> "!")
runCommand (ServiceShow nm) = do
  let path = "services/" <> Text.unpack nm <> ".dhall"
  cfg <- loadServiceConfig path
  printConfig cfg

printConfig :: ServiceConfig -> IO ()
printConfig = BL8.putStrLn . AesonPretty.encodePretty
