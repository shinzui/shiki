module Shiki.Cli.HelpSpec
  ( tests
  ) where

import Shiki.Cli.Help (HelpCommand (..), HelpTopic (..), helpParser, helpTopics)

import "base" Data.List (nub)
import "optparse-applicative" Options.Applicative qualified as Opt
import "tasty" Test.Tasty (TestTree, testGroup)
import "tasty-hunit" Test.Tasty.HUnit (Assertion, assertBool, assertEqual, testCase)
import "text" Data.Text (Text)
import "text" Data.Text qualified as Text

tests :: TestTree
tests =
  testGroup
    "Shiki.Cli.Help"
    [ testCase "registry has at least six topics" $
        assertBool
          ("expected >= 6 topics, got " <> show (length helpTopics))
          (length helpTopics >= 6)
    , testCase "every topic is well-formed" wellFormedCase
    , testCase "topic names are unique" $ do
        let ns = topicNames
        assertEqual "duplicate topic name(s) detected" (length ns) (length (nub ns))
    , testCase "topic names are lowercase ASCII letters or hyphen" $
        mapM_ assertNameOk topicNames
    , testCase "parser: no argument => ListTopics" $
        assertEqual "" (Right ListTopics) (parsePure [])
    , testCase "parser: 'services' => ShowTopic \"services\"" $
        assertEqual "" (Right (ShowTopic "services")) (parsePure ["services"])
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
    Opt.Success a       -> Right a
    Opt.Failure _       -> Left "parse failed"
    Opt.CompletionInvoked _ -> Left "unexpected completion"
