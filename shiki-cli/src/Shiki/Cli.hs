-- | Top-level CLI entry point for shiki.
--
--   This is a starter scaffold: it wires up `optparse-applicative` with a
--   single `hello` subcommand. Replace `runCommand` with your real
--   subcommand parser when you grow past the bootstrap.
module Shiki.Cli
  ( runCli
  ) where

import Data.Foldable (traverse_)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Options.Applicative

-- | A subcommand of the shiki CLI.
data Command
  = Hello (Maybe T.Text)
  deriving stock (Show, Eq)

-- | Top-level CLI options, parsed from argv.
data Options = Options
  { command :: Command
  }
  deriving stock (Show, Eq)

-- | Parse argv and dispatch to the chosen subcommand.
runCli :: IO ()
runCli = do
  opts <- execParser parserInfo
  runCommand opts.command

parserInfo :: ParserInfo Options
parserInfo =
  info
    (optionsParser <**> helper)
    ( fullDesc
        <> progDesc "hiki conducts operational commands across Kubernetes services and records what ran, where it ran, and how long it took."
        <> header "shiki - hiki conducts operational commands across Kubernetes services and records what ran, where it ran, and how long it took."
    )

optionsParser :: Parser Options
optionsParser = Options <$> commandParser

commandParser :: Parser Command
commandParser =
  hsubparser
    ( command
        "hello"
        ( info
            (Hello <$> optional (strOption (long "name" <> metavar "NAME" <> help "Whom to greet")))
            (progDesc "Print a greeting")
        )
    )

runCommand :: Command -> IO ()
runCommand (Hello mName) =
  let target = maybe (T.pack "shiki") id mName
   in traverse_ TIO.putStrLn [T.pack "Hello, " <> target <> T.pack "!"]
