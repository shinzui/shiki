module Main (main) where

import Shiki.Analysis.BackendSpec qualified as BackendSpec
import Shiki.Analysis.HeuristicSpec qualified as HeuristicSpec
import Shiki.K8s.ExecCredentialSpec qualified as ExecCredentialSpec
import Shiki.K8s.JobBuilderSpec qualified as JobBuilderSpec
import Shiki.Persistence.ErrorSummaryColumnSpec qualified as ErrorSummaryColumnSpec
import Shiki.Persistence.RestrictedRoleSpec qualified as RestrictedRoleSpec
import Shiki.Persistence.RunListSpec qualified as RunListSpec
import Shiki.Persistence.RunSpec qualified as RunSpec
import Shiki.Persistence.SchemaIsolationSpec qualified as SchemaIsolationSpec
import Shiki.Persistence.SchemaSpec qualified as SchemaSpec
import Shiki.Project.ConfigSpec qualified as ProjectConfigSpec
import Shiki.Service.ConfigSpec qualified as ConfigSpec
import "tasty" Test.Tasty (defaultMain, testGroup)

main :: IO ()
main =
  defaultMain $
    testGroup
      "shiki-core"
      [ ConfigSpec.tests,
        ProjectConfigSpec.tests,
        RunSpec.tests,
        RunListSpec.tests,
        JobBuilderSpec.tests,
        ExecCredentialSpec.tests,
        SchemaSpec.tests,
        SchemaIsolationSpec.tests,
        RestrictedRoleSpec.tests,
        HeuristicSpec.tests,
        BackendSpec.tests,
        ErrorSummaryColumnSpec.tests
      ]
