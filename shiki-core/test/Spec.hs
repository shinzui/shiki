module Main (main) where

import Shiki.Analysis.HeuristicSpec qualified as HeuristicSpec
import Shiki.Effect.AnalyzerSpec qualified as AnalyzerSpec
import Shiki.Effect.RunStoreSpec qualified as RunStoreSpec
import Shiki.EffectfulContractSpec qualified as EffectfulContractSpec
import Shiki.K8s.ClassifyJobSpec qualified as ClassifyJobSpec
import Shiki.K8s.CredentialExpirySpec qualified as CredentialExpirySpec
import Shiki.K8s.ExecCredentialSpec qualified as ExecCredentialSpec
import Shiki.K8s.JobBuilderSpec qualified as JobBuilderSpec
import Shiki.Persistence.ErrorSummaryColumnSpec qualified as ErrorSummaryColumnSpec
import Shiki.Persistence.LastWatchedAtSpec qualified as LastWatchedAtSpec
import Shiki.Persistence.MigrationSpec qualified as MigrationSpec
import Shiki.Persistence.RestrictedRoleSpec qualified as RestrictedRoleSpec
import Shiki.Persistence.RunListSpec qualified as RunListSpec
import Shiki.Persistence.RunSpec qualified as RunSpec
import Shiki.Persistence.SchemaIsolationSpec qualified as SchemaIsolationSpec
import Shiki.Persistence.SchemaSpec qualified as SchemaSpec
import Shiki.Project.ConfigSpec qualified as ProjectConfigSpec
import Shiki.Service.ConfigSpec qualified as ConfigSpec
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main =
  defaultMain $
    testGroup
      "shiki-core"
      [ EffectfulContractSpec.tests,
        ConfigSpec.tests,
        ProjectConfigSpec.tests,
        RunSpec.tests,
        RunListSpec.tests,
        JobBuilderSpec.tests,
        ExecCredentialSpec.tests,
        CredentialExpirySpec.tests,
        ClassifyJobSpec.tests,
        SchemaSpec.tests,
        SchemaIsolationSpec.tests,
        MigrationSpec.tests,
        RestrictedRoleSpec.tests,
        HeuristicSpec.tests,
        ErrorSummaryColumnSpec.tests,
        LastWatchedAtSpec.tests,
        RunStoreSpec.tests,
        AnalyzerSpec.tests
      ]
