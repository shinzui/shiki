{-# LANGUAGE TemplateHaskell #-}

-- | The @shiki help@ subcommand. Bare @shiki help@ prints an index of
--   curated topic guides; @shiki help \<topic\>@ prints one topic
--   verbatim. Topic content lives under @shiki-cli/data/help/*.md@ and
--   is baked into the binary at compile time via 'embedStringFile', so
--   the executable remains a single self-contained file. Topic lookup
--   is case-insensitive and tolerant of leading/trailing whitespace;
--   unknown topics print an @Available:@ list to stderr and exit
--   non-zero.
module Shiki.Cli.Help
  ( HelpTopic (..)
  , HelpCommand (..)
  , helpTopics
  , helpParser
  , runHelp
  ) where

import Shiki.Prelude hiding (argument)

import "base" Data.Foldable (traverse_)
import "base" Data.List (find)
import "base" System.Exit (exitFailure)
import "base" System.IO (hPutStrLn, stderr)
import "file-embed" Data.FileEmbed (embedStringFile)
import "optparse-applicative"
  Options.Applicative
    ( Parser
    , argument
    , help
    , metavar
    , str
    )
import "text" Data.Text qualified as Text
import "text" Data.Text.IO qualified as TIO

data HelpTopic = HelpTopic
  { name        :: !Text
  , description :: !Text
  , content     :: !Text
  }
  deriving stock (Generic, Eq, Show)

data HelpCommand
  = ListTopics
  | ShowTopic !Text
  deriving stock (Generic, Eq, Show)

helpTopics :: [HelpTopic]
helpTopics =
  [ HelpTopic "services"  "Service configuration: services/*.dhall" servicesContent
  , HelpTopic "runs"      "Run lifecycle and the runs table"        runsContent
  , HelpTopic "analyzers" "Failure analysis backends"               analyzersContent
  , HelpTopic "agent"     "shiki agent assist"                      agentContent
  , HelpTopic "schema"    "Postgres schema configuration"           schemaContent
  , HelpTopic "env"       "Environment variables"                   envContent
  ]

servicesContent :: Text
servicesContent = $(embedStringFile "data/help/services.md")

runsContent :: Text
runsContent = $(embedStringFile "data/help/runs.md")

analyzersContent :: Text
analyzersContent = $(embedStringFile "data/help/analyzers.md")

agentContent :: Text
agentContent = $(embedStringFile "data/help/agent.md")

schemaContent :: Text
schemaContent = $(embedStringFile "data/help/schema.md")

envContent :: Text
envContent = $(embedStringFile "data/help/env.md")

helpParser :: Parser HelpCommand
helpParser =
  fmap ShowTopic topicArg <|> pure ListTopics
  where
    topicArg =
      argument str
        ( metavar "TOPIC"
            <> help ("Help topic (one of: " <> Text.unpack topicList <> ")")
        )
    topicList = Text.intercalate ", " (fmap (^. #name) helpTopics)

runHelp :: HelpCommand -> IO ()
runHelp = \case
  ListTopics      -> listTopics
  ShowTopic topic -> showTopic topic

listTopics :: IO ()
listTopics = do
  TIO.putStrLn "HELP TOPICS"
  TIO.putStrLn ""
  traverse_ printOne helpTopics
  TIO.putStrLn ""
  TIO.putStrLn "Use 'shiki help <topic>' for details."
  where
    nameColWidth =
      maximum (1 : fmap (Text.length . (^. #name)) helpTopics)
    printOne t =
      TIO.putStrLn
        ( "  "
            <> Text.justifyLeft nameColWidth ' ' (t ^. #name)
            <> "  "
            <> t ^. #description
        )

showTopic :: Text -> IO ()
showTopic raw =
  let key = Text.toLower (Text.strip raw)
   in case find (\t -> (t ^. #name) == key) helpTopics of
        Just t  -> TIO.putStr (t ^. #content)
        Nothing -> do
          hPutStrLn stderr ("Unknown topic: " <> Text.unpack raw)
          hPutStrLn stderr
            ( "Available: "
                <> Text.unpack
                  (Text.intercalate ", " (fmap (^. #name) helpTopics))
            )
          exitFailure
