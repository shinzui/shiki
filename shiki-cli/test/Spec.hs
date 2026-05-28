module Main (main) where

import "tasty" Test.Tasty (defaultMain, testGroup)

import Shiki.Cli.Agent.ContextSpec qualified as ContextSpec
import Shiki.Cli.Agent.LaunchSpec qualified as LaunchSpec
import Shiki.Cli.Agent.PromptSpec qualified as PromptSpec
import Shiki.Cli.Agent.ProviderSpec qualified as ProviderSpec
import Shiki.Cli.HelpSpec qualified as HelpSpec

main :: IO ()
main =
  defaultMain $
    testGroup
      "shiki-cli"
      [ ProviderSpec.tests
      , ContextSpec.tests
      , PromptSpec.tests
      , LaunchSpec.tests
      , HelpSpec.tests
      ]
