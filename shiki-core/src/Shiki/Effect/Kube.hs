{-# LANGUAGE TypeFamilies #-}

-- | Everything shiki does to a Kubernetes cluster, as one effect.
--
--   Listing @Kube :> es@ in a handler's type is what makes a command's
--   dependence on the cluster visible, and its absence is what makes
--   @shiki runs list@ work with no kubeconfig at all: the client is loaded by
--   the interpreter ("Shiki.Effect.Kube.Client"), so a command that never
--   interprets 'Kube' never reads @~\/.kube\/config@.
--
--   As with 'Shiki.Effect.RunStore.RunStore', the operations are the things
--   shiki actually does rather than a generic "make an API request", so no
--   caller mentions @kubernetes-api@.
module Shiki.Effect.Kube
  ( Kube (..),
    inspectDeployment,
    deploymentExists,
    submitJob,
    awaitJob,
    observeJob,
    collectOutcome,
  )
where

import Effectful (Dispatch (Dynamic), DispatchOf, Eff, Effect, type (:>))
import Effectful.Dispatch.Dynamic (send)
import Shiki.K8s.Introspection (DeploymentName, DeploymentSnapshot, Namespace)
import Shiki.K8s.JobBuilder (JobInputs)
import Shiki.K8s.Runner (JobObservation, JobOutcome, JobPhase)
import Shiki.Prelude
import Shiki.Service.Config (ServiceConfig)

data Kube :: Effect where
  -- | namespace, deployment, container name within it
  InspectDeployment :: Namespace -> DeploymentName -> Text -> Kube m DeploymentSnapshot
  DeploymentExists :: Namespace -> DeploymentName -> Kube m Bool
  -- | submit and return as soon as the API accepts the create request
  SubmitJob :: ServiceConfig -> DeploymentSnapshot -> JobInputs -> Kube m ()
  -- | submit, then poll until the Job ends or the deadline passes
  AwaitJob :: ServiceConfig -> DeploymentSnapshot -> JobInputs -> Kube m JobOutcome
  -- | namespace, job name
  ObserveJob :: Namespace -> Text -> Kube m JobObservation
  -- | namespace, job name, started at, ended at, the phase already observed
  CollectOutcome :: Namespace -> Text -> UTCTime -> UTCTime -> JobPhase -> Kube m JobOutcome

type instance DispatchOf Kube = Dynamic

inspectDeployment ::
  (Kube :> es) => Namespace -> DeploymentName -> Text -> Eff es DeploymentSnapshot
inspectDeployment ns dep container = send (InspectDeployment ns dep container)

deploymentExists :: (Kube :> es) => Namespace -> DeploymentName -> Eff es Bool
deploymentExists ns dep = send (DeploymentExists ns dep)

submitJob ::
  (Kube :> es) => ServiceConfig -> DeploymentSnapshot -> JobInputs -> Eff es ()
submitJob svc snap inputs = send (SubmitJob svc snap inputs)

awaitJob ::
  (Kube :> es) => ServiceConfig -> DeploymentSnapshot -> JobInputs -> Eff es JobOutcome
awaitJob svc snap inputs = send (AwaitJob svc snap inputs)

observeJob :: (Kube :> es) => Namespace -> Text -> Eff es JobObservation
observeJob ns jobName = send (ObserveJob ns jobName)

collectOutcome ::
  (Kube :> es) => Namespace -> Text -> UTCTime -> UTCTime -> JobPhase -> Eff es JobOutcome
collectOutcome ns jobName startedAt endedAt phase =
  send (CollectOutcome ns jobName startedAt endedAt phase)
