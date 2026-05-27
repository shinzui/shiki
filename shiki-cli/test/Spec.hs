module Main (main) where

import "tasty" Test.Tasty (defaultMain, testGroup)

import Shiki.Cli.Agent.ContextSpec qualified as ContextSpec
import Shiki.Cli.Agent.ProviderSpec qualified as ProviderSpec

main :: IO ()
main =
  defaultMain $
    testGroup
      "shiki-cli"
      [ ProviderSpec.tests
      , ContextSpec.tests
      ]
