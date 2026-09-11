module Shiki.Cli.ParserSpec
  ( tests,
  )
where

import Data.Text qualified as Text
import Options.Applicative qualified as Opt
import Shiki.Cli (parserInfo)
import Shiki.Cli.Completions (CompletionsShell (..), completionScript)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase)

tests :: TestTree
tests =
  testGroup
    "Shiki.Cli (parser)"
    [ testGroup
        "completion protocol"
        [ testCase "'shiki ru' completes to run and runs only" $ do
            cs <- completionsFor ["shiki", "ru"]
            assertBool ("expected run in " <> show cs) ("run" `elem` cs)
            assertBool ("expected runs in " <> show cs) ("runs" `elem` cs)
            assertBool ("unexpected agent in " <> show cs) ("agent" `notElem` cs),
          testCase "'shiki runs ' completes the runs subcommands" $ do
            cs <- completionsFor ["shiki", "runs", ""]
            mapM_
              (\c -> assertBool ("expected " <> c <> " in " <> show cs) (c `elem` cs))
              ["list", "show", "logs", "error", "analyze"],
          testCase "'shiki comp' completes to completions" $ do
            cs <- completionsFor ["shiki", "comp"]
            assertBool ("expected completions in " <> show cs) ("completions" `elem` cs),
          testCase "'shiki completions ' completes the three shells" $ do
            cs <- completionsFor ["shiki", "completions", ""]
            mapM_
              (\c -> assertBool ("expected " <> c <> " in " <> show cs) (c `elem` cs))
              ["bash", "zsh", "fish"]
        ],
      testGroup
        "completion scripts"
        [ testCase "bash script registers _shiki_completions" $
            assertContains
              "complete -o filenames -F _shiki_completions shiki"
              (completionScript Bash),
          testCase "zsh script starts with #compdef shiki" $
            assertBool
              "zsh script must start with #compdef"
              ("#compdef shiki\n" `Text.isPrefixOf` completionScript Zsh),
          testCase "fish script registers __shiki_complete" $
            assertContains
              "complete -c shiki -a '(__shiki_complete)'"
              (completionScript Fish),
          testCase "every script calls shiki by name, never by absolute path" $
            mapM_
              ( \sh ->
                  assertBool
                    (show sh <> " script embeds an absolute path")
                    (not ("/nix/store" `Text.isInfixOf` completionScript sh))
              )
              [minBound .. maxBound]
        ]
    ]

-- | Drive the real top-level parser through optparse-applicative's
--   completion protocol, exactly as the generated shell scripts do.
completionsFor :: [String] -> IO [String]
completionsFor wordsSoFar =
  case Opt.execParserPure Opt.defaultPrefs parserInfo protocolArgs of
    Opt.CompletionInvoked c -> lines <$> Opt.execCompletion c "shiki"
    _ -> assertFailure "expected the completion protocol to be invoked"
  where
    protocolArgs =
      ["--bash-completion-index", show (length wordsSoFar - 1)]
        <> concatMap (\w -> ["--bash-completion-word", w]) wordsSoFar

assertContains :: Text.Text -> Text.Text -> IO ()
assertContains needle haystack =
  assertBool
    ("expected " <> show needle <> " in:\n" <> Text.unpack haystack)
    (needle `Text.isInfixOf` haystack)
