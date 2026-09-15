{-# LANGUAGE TemplateHaskell #-}

-- | The @shiki help@ subcommand. Bare @shiki help@ prints an index of
--   curated topic guides; @shiki help \<topic\>@ prints one topic.
--   Topic content lives under @shiki-cli/data/help/*.md@ and is baked
--   into the binary at compile time via 'embedStringFile', so the
--   executable remains a single self-contained file. Topic lookup is
--   case-insensitive and tolerant of leading/trailing whitespace;
--   unknown topics print an @Available:@ list to stderr and exit
--   non-zero.
--
--   On a terminal, topic prose is re-flowed to the terminal width,
--   capped at 'maxAutoWidth' columns; @--width@ sets the width
--   explicitly. When stdout is not a terminal the topic is printed
--   verbatim, so piped output is byte-identical to the source file.
--   Indented blocks (tables, examples, transcripts) are never re-flowed.
module Shiki.Cli.Help
  ( HelpTopic (..),
    HelpCommand (..),
    helpTopics,
    helpParser,
    runHelp,

    -- * Width-aware rendering
    maxAutoWidth,
    resolveWidth,
    renderTopic,
    rewrap,
  )
where

import Data.FileEmbed (embedStringFile)
import Data.Foldable (traverse_)
import Data.Generics.Labels ()
import Data.List (find)
import Data.Text qualified as Text
import Data.Text.IO qualified as TIO
import Options.Applicative
  ( Parser,
    argument,
    auto,
    help,
    long,
    metavar,
    option,
    optional,
    short,
    str,
  )
import Shiki.Prelude hiding (argument)
import System.Console.Terminal.Size qualified as TermSize
import System.Exit (exitFailure)
import System.IO (hIsTerminalDevice, hPutStrLn, stderr, stdout)

data HelpTopic = HelpTopic
  { name :: !Text,
    description :: !Text,
    content :: !Text
  }
  deriving stock (Generic, Eq, Show)

data HelpCommand
  = ListTopics
  | -- | The topic name, and the @--width@ override if one was given.
    ShowTopic !Text !(Maybe Int)
  deriving stock (Generic, Eq, Show)

helpTopics :: [HelpTopic]
helpTopics =
  [ HelpTopic "services" "Service configuration: services/*.dhall" servicesContent,
    HelpTopic "runs" "Run lifecycle and the runs table" runsContent,
    HelpTopic "long-runs" "Running, watching, and recording long Jobs" longRunsContent,
    HelpTopic "analyzers" "Failure analysis backends" analyzersContent,
    HelpTopic "agent" "shiki agent assist" agentContent,
    HelpTopic "schema" "Postgres schema configuration" schemaContent,
    HelpTopic "env" "Environment variables" envContent
  ]

servicesContent :: Text
servicesContent = $(embedStringFile "data/help/services.md")

runsContent :: Text
runsContent = $(embedStringFile "data/help/runs.md")

longRunsContent :: Text
longRunsContent = $(embedStringFile "data/help/long-runs.md")

analyzersContent :: Text
analyzersContent = $(embedStringFile "data/help/analyzers.md")

agentContent :: Text
agentContent = $(embedStringFile "data/help/agent.md")

schemaContent :: Text
schemaContent = $(embedStringFile "data/help/schema.md")

envContent :: Text
envContent = $(embedStringFile "data/help/env.md")

-- | @[TOPIC] [-w|--width COLUMNS]@. The width option is shared by both
--   shapes rather than attached to the topic branch: attached there,
--   @shiki help --width 60@ would fail with @Missing: TOPIC@, and declared
--   in two alternatives it would be listed twice in @--help@. Without a
--   topic the width is accepted and ignored, because the index is short.
helpParser :: Parser HelpCommand
helpParser = mkHelpCommand <$> optional topicArg <*> widthOption
  where
    mkHelpCommand Nothing _ = ListTopics
    mkHelpCommand (Just t) w = ShowTopic t w
    topicArg =
      argument
        str
        ( metavar "TOPIC"
            <> help ("Help topic (one of: " <> Text.unpack topicList <> ")")
        )
    topicList = Text.intercalate ", " (fmap (^. #name) helpTopics)

widthOption :: Parser (Maybe Int)
widthOption =
  optional
    ( option
        auto
        ( long "width"
            <> short 'w'
            <> metavar "COLUMNS"
            <> help "Wrap topic prose to COLUMNS (indented blocks stay verbatim)"
        )
    )

runHelp :: HelpCommand -> IO ()
runHelp = \case
  ListTopics -> listTopics
  ShowTopic topic mWidth -> showTopic topic mWidth

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

showTopic :: Text -> Maybe Int -> IO ()
showTopic raw mWidth =
  let key = Text.toLower (Text.strip raw)
   in case find (\t -> (t ^. #name) == key) helpTopics of
        Just t -> do
          effective <- resolveWidth mWidth
          case effective of
            -- The embedded content already ends in a newline.
            Nothing -> TIO.putStr (t ^. #content)
            -- 'rewrap' drops the trailing newline.
            Just w -> TIO.putStrLn (renderTopic (Just w) (t ^. #content))
        Nothing -> do
          hPutStrLn stderr ("Unknown topic: " <> Text.unpack raw)
          hPutStrLn
            stderr
            ( "Available: "
                <> Text.unpack
                  (Text.intercalate ", " (fmap (^. #name) helpTopics))
            )
          exitFailure

-- | Cap for auto-detected widths. An explicit @--width@ bypasses it.
maxAutoWidth :: Int
maxAutoWidth = 140

-- | The width to re-flow to, or 'Nothing' to print verbatim. An explicit
--   width always wins, with no cap and no terminal check. Otherwise the
--   width comes from the terminal (via @ioctl@, never escape sequences)
--   capped at 'maxAutoWidth', and a non-terminal stdout yields 'Nothing'
--   so piped output stays byte-stable.
resolveWidth :: Maybe Int -> IO (Maybe Int)
resolveWidth (Just w) = pure (Just w)
resolveWidth Nothing = do
  isTty <- hIsTerminalDevice stdout
  if not isTty
    then pure Nothing
    else do
      mWin <- TermSize.hSize stdout
      pure $ case mWin of
        Just win | win ^. #width > 0 -> Just (min (win ^. #width) maxAutoWidth)
        _ -> Nothing

-- | Render a topic body for the given width; 'Nothing' is the identity.
renderTopic :: Maybe Int -> Text -> Text
renderTopic Nothing body = body
renderTopic (Just w) body = rewrap (max 1 w) body

-- | Re-flow prose paragraphs to at most @width@ columns. Paragraphs are
--   separated by blank lines. A paragraph whose every non-blank line is
--   indented by two spaces is a table, example, or transcript and passes
--   through untouched; any other paragraph is packed greedily, with a word
--   longer than the width on a line of its own. Paragraphs are rejoined
--   with a single blank line, and the result has no trailing newline.
rewrap :: Int -> Text -> Text
rewrap width body =
  Text.intercalate "\n\n" (fmap (rewrapParagraph width) (splitOnBlankLines body))

splitOnBlankLines :: Text -> [Text]
splitOnBlankLines body = go [] [] (Text.lines body)
  where
    go acc cur [] = reverse (flush cur acc)
    go acc cur (l : ls)
      | Text.null (Text.strip l) = go (flush cur acc) [] ls
      | otherwise = go acc (l : cur) ls
    flush [] acc = acc
    flush cur acc = Text.intercalate "\n" (reverse cur) : acc

rewrapParagraph :: Int -> Text -> Text
rewrapParagraph width paragraph
  | isIndentedBlock paragraph = paragraph
  | otherwise = reflow width paragraph

isIndentedBlock :: Text -> Bool
isIndentedBlock paragraph = not (null nonBlank) && all ("  " `Text.isPrefixOf`) nonBlank
  where
    nonBlank = filter (not . Text.null . Text.strip) (Text.lines paragraph)

reflow :: Int -> Text -> Text
reflow width paragraph = Text.intercalate "\n" (packWords (Text.words paragraph))
  where
    packWords [] = []
    packWords (firstWord : rest) = go firstWord rest
    go acc [] = [acc]
    go acc (w : ws)
      | Text.length acc + 1 + Text.length w <= width = go (acc <> " " <> w) ws
      | otherwise = acc : go w ws
