module Shiki.Cli.HelpSpec
  ( tests,
  )
where

import Data.List (nub)
import Data.Text (Text)
import Data.Text qualified as Text
import Options.Applicative qualified as Opt
import Shiki.Cli.Help
  ( HelpCommand (..),
    HelpTopic (..),
    helpParser,
    helpTopics,
    renderTopic,
    rewrap,
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertEqual, testCase)

tests :: TestTree
tests =
  testGroup
    "Shiki.Cli.Help"
    [ testCase "registry has at least six topics" $
        assertBool
          ("expected >= 6 topics, got " <> show (length helpTopics))
          (length helpTopics >= 6),
      testCase "every topic is well-formed" wellFormedCase,
      testCase "topic names are unique" $ do
        let ns = topicNames
        assertEqual "duplicate topic name(s) detected" (length ns) (length (nub ns)),
      testCase "topic names are lowercase ASCII letters or hyphen" $
        mapM_ assertNameOk topicNames,
      testCase "parser: no argument => ListTopics" $
        assertEqual "" (Right ListTopics) (parsePure []),
      testCase "parser: 'services' => ShowTopic \"services\" Nothing" $
        assertEqual "" (Right (ShowTopic "services" Nothing)) (parsePure ["services"]),
      testCase "parser: 'services --width 60' => ShowTopic with width" $
        assertEqual
          ""
          (Right (ShowTopic "services" (Just 60)))
          (parsePure ["services", "--width", "60"]),
      testCase "parser: '-w 60 services' => ShowTopic with width" $
        assertEqual
          ""
          (Right (ShowTopic "services" (Just 60)))
          (parsePure ["-w", "60", "services"]),
      testCase "parser: '--width 60' without a topic => ListTopics" $
        assertEqual "" (Right ListTopics) (parsePure ["--width", "60"]),
      testCase "rewrap: prose lines fit the width" rewrapProseCase,
      testCase "rewrap: indented blocks stay verbatim" rewrapIndentedCase,
      testCase "rewrap: a word longer than the width gets its own line" $
        assertEqual
          ""
          "a\nsupercalifragilistic\nb"
          (rewrap 10 "a supercalifragilistic b"),
      testCase "rewrap: every topic's prose fits 40 columns" rewrapTopicsCase,
      testCase "renderTopic Nothing is the identity on every topic" $
        mapM_
          (\HelpTopic {name, content} -> assertEqual (Text.unpack name) content (renderTopic Nothing content))
          helpTopics
    ]

topicNames :: [Text]
topicNames = fmap topicName helpTopics

topicName :: HelpTopic -> Text
topicName HelpTopic {name} = name

wellFormedCase :: Assertion
wellFormedCase = mapM_ check helpTopics
  where
    check HelpTopic {name, description, content} = do
      assertBool ("name non-empty for " <> show name) (not (Text.null name))
      assertBool
        ("description non-empty for " <> show name)
        (not (Text.null description))
      assertBool ("content non-empty for " <> show name) (not (Text.null content))

assertNameOk :: Text -> Assertion
assertNameOk n =
  assertBool
    ("topic name not lowercase-ascii/hyphen: " <> show n)
    (not (Text.null n) && Text.all okChar n)
  where
    okChar c = (c >= 'a' && c <= 'z') || c == '-'

parsePure :: [String] -> Either String HelpCommand
parsePure args =
  case Opt.execParserPure
    Opt.defaultPrefs
    (Opt.info helpParser Opt.idm)
    args of
    Opt.Success a -> Right a
    Opt.Failure _ -> Left "parse failed"
    Opt.CompletionInvoked _ -> Left "unexpected completion"

proseParagraph :: Text
proseParagraph =
  "shiki records every run in PostgreSQL with its service, command, status,\n\
  \timing, and duration, so ad hoc operational work is easy to audit later.\n"

rewrapProseCase :: Assertion
rewrapProseCase = do
  let out = rewrap 20 proseParagraph
  mapM_
    (\l -> assertBool ("line longer than 20: " <> show l) (Text.length l <= 20))
    (Text.lines out)
  assertEqual "words preserved" (Text.words proseParagraph) (Text.words out)

rewrapIndentedCase :: Assertion
rewrapIndentedCase = do
  let block = "  shiki runs list --service ingest --limit 20\n  shiki runs show 3f2c1a9d"
      body = proseParagraph <> "\n" <> block <> "\n"
      out = rewrap 20 body
  assertBool
    ("indented block altered:\n" <> Text.unpack out)
    (block `Text.isSuffixOf` out)

rewrapTopicsCase :: Assertion
rewrapTopicsCase = mapM_ check helpTopics
  where
    check HelpTopic {name, content} =
      mapM_
        ( \l ->
            assertBool
              (Text.unpack name <> ": prose line longer than 40: " <> show l)
              ("  " `Text.isPrefixOf` l || Text.length l <= 40 || length (Text.words l) == 1)
        )
        (Text.lines (rewrap 40 content))
