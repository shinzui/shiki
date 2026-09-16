-- | A 'Kube' interpreter that never reaches a cluster.
--
--   The Deployment inspection answers with a canned snapshot and the submit
--   succeeds; what the Job /does/ is the caller's to decide, which is how a
--   test can make @shiki run@ wait on a Job that is then interrupted.
module Shiki.Cli.Effect.FakeKube
  ( runFakeKube,
    fakeSnapshot,
  )
where

import Data.Map.Strict qualified as Map
import Effectful (Eff, type (:>))
import Effectful.Dispatch.Dynamic (interpret_)
import Effectful.Error.Static (Error, throwError)
import Shiki.Effect.Kube (Kube (..))
import Shiki.Error (KubeError (..), ShikiError (..))
import Shiki.K8s.Introspection (DeploymentSnapshot (..))
import Shiki.K8s.Runner (JobObservation (..), JobOutcome)

fakeSnapshot :: DeploymentSnapshot
fakeSnapshot =
  DeploymentSnapshot
    { image = "registry.example.com/foo:latest",
      configMapName = "foo-config",
      secretName = "foo-secret",
      envByName = Map.empty,
      initImages = Map.empty
    }

-- | Interpret 'Kube'. @onAwait@ is what 'AwaitJob' does; the operations no
--   test here exercises fail loudly rather than pretending to succeed.
runFakeKube ::
  (Error ShikiError :> es) =>
  Eff es JobOutcome ->
  Eff (Kube : es) a ->
  Eff es a
runFakeKube onAwait = interpret_ $ \case
  InspectDeployment {} -> pure fakeSnapshot
  DeploymentExists {} -> pure True
  SubmitJob {} -> pure ()
  AwaitJob {} -> onAwait
  ObserveJob {} -> pure JobActive
  CollectOutcome {} ->
    throwError
      ( ShikiKubeError
          (KubeRequestFailed "collect job outcome" "the fake cluster has no logs")
      )
