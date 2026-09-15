module Main (main) where

import Shiki.Cli.Agent.ContextSpec qualified as ContextSpec
import Shiki.Cli.Agent.LaunchSpec qualified as LaunchSpec
import Shiki.Cli.Agent.PromptSpec qualified as PromptSpec
import Shiki.Cli.Agent.ProviderSpec qualified as ProviderSpec
import Shiki.Cli.ConfigInitSpec qualified as ConfigInitSpec
import Shiki.Cli.EnvRoutingSpec qualified as EnvRoutingSpec
import Shiki.Cli.Fzf.Selector.RunSpec qualified as RunSelectorSpec
import Shiki.Cli.Fzf.Selector.ServiceSpec qualified as ServiceSelectorSpec
import Shiki.Cli.FzfSpec qualified as FzfSpec
import Shiki.Cli.HelpSpec qualified as HelpSpec
import Shiki.Cli.ParserSpec qualified as ParserSpec
import Shiki.Cli.ProjectSpec qualified as ProjectSpec
import Shiki.Cli.Runs.FormatSpec qualified as RunsFormatSpec
import Shiki.Cli.Runs.SyncSpec qualified as RunsSyncSpec
import Shiki.Cli.VersionSpec qualified as VersionSpec
import Test.Tasty (defaultMain, localOption, testGroup)
import Test.Tasty.Runners (NumThreads (..))

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
          ConfigInitSpec.tests,
          EnvRoutingSpec.tests,
          HelpSpec.tests,
          ParserSpec.tests,
          VersionSpec.tests,
          FzfSpec.tests,
          RunsFormatSpec.tests,
          RunsSyncSpec.tests,
          RunSelectorSpec.tests,
          ServiceSelectorSpec.tests,
          ProjectSpec.tests
        ]
