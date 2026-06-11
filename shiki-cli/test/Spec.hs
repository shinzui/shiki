module Main (main) where

import Shiki.Cli.Agent.ContextSpec qualified as ContextSpec
import Shiki.Cli.Agent.LaunchSpec qualified as LaunchSpec
import Shiki.Cli.Agent.PromptSpec qualified as PromptSpec
import Shiki.Cli.Agent.ProviderSpec qualified as ProviderSpec
import Shiki.Cli.EnvRoutingSpec qualified as EnvRoutingSpec
import Shiki.Cli.Fzf.Selector.RunSpec qualified as RunSelectorSpec
import Shiki.Cli.HelpSpec qualified as HelpSpec
import Shiki.Cli.ProjectSpec qualified as ProjectSpec
import "tasty" Test.Tasty (defaultMain, localOption, testGroup)
import "tasty" Test.Tasty.Runners (NumThreads (..))

-- | Run tests sequentially. 'Shiki.Cli.Agent.LaunchSpec' redirects the
--   OS-level @stdout@ to capture output, which is fundamentally racy
--   against any concurrent tasty test that prints. NumThreads 1 keeps
--   the suite deterministic without forcing the whole test binary into
--   single-core mode.
main :: IO ()
main =
  defaultMain $
    localOption (NumThreads 1) $
      testGroup
        "shiki-cli"
        [ ProviderSpec.tests,
          ContextSpec.tests,
          PromptSpec.tests,
          LaunchSpec.tests,
          EnvRoutingSpec.tests,
          HelpSpec.tests,
          RunSelectorSpec.tests,
          ProjectSpec.tests
        ]
