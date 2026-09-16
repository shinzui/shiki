-- | The production interpreter for "Shiki.Effect.Kube": the handwritten
--   @kubernetes-api@ client, configured from the operator's kubeconfig.
--
--   Loading the config happens here and nowhere else. A command that does not
--   interpret 'Kube' never reads @KUBECONFIG@ or @~\/.kube\/config@, never
--   runs an exec credential plugin, and therefore cannot fail because of
--   them — which is the whole reason @shiki runs list@ no longer needs a
--   working cluster.
module Shiki.Effect.Kube.Client
  ( runKubeDefault,
    runKubeWith,
    loadKubeClient,
    jobPollIntervalSeconds,
    jobTimeoutSeconds,
  )
where

import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Effectful (Eff, IOE, type (:>))
import Effectful.Dispatch.Dynamic (interpret_)
import Effectful.Error.Static (Error, throwError)
import Effectful.Exception qualified as Exc
import Network.HTTP.Client
  ( HttpException (..),
    HttpExceptionContent (InternalException),
    Request,
  )
import Network.HTTP.Client qualified as HttpClient
import Shiki.Effect.Kube (Kube (..))
import Shiki.Error (KubeError (..), ShikiError (..), collapseWhitespace)
import Shiki.K8s.Client (ClientEnv, loadDefaultClientConfig)
import Shiki.K8s.ExecCredential (ExecCredentialError)
import Shiki.K8s.Introspection
  ( DeploymentName (..),
    InspectionError,
  )
import Shiki.K8s.Introspection qualified as Introspection
import Shiki.K8s.Runner qualified as Runner
import Shiki.Prelude

-- | How often 'AwaitJob' asks the cluster for the Job's status.
jobPollIntervalSeconds :: Int
jobPollIntervalSeconds = 5

-- | How long 'AwaitJob' waits before calling the Job timed out: four days,
--   long enough for the overnight backfills shiki is used for.
jobTimeoutSeconds :: Int
jobTimeoutSeconds = 345600

-- | Load the default client config (@KUBECONFIG@, then @~\/.kube\/config@)
--   and interpret 'Kube' with it.
runKubeDefault ::
  (IOE :> es, Error ShikiError :> es) =>
  Eff (Kube : es) a ->
  Eff es a
runKubeDefault action = do
  client <- loadKubeClient
  runKubeWith client action

-- | Interpret 'Kube' against an already-loaded client.
runKubeWith ::
  (IOE :> es, Error ShikiError :> es) =>
  ClientEnv ->
  Eff (Kube : es) a ->
  Eff es a
runKubeWith client = interpret_ $ \case
  InspectDeployment ns dep container ->
    cluster "inspect deployment" (Just dep) $
      Introspection.inspectDeployment client ns dep container
  DeploymentExists ns dep ->
    cluster "check deployment" (Just dep) $
      Introspection.deploymentExists client ns dep
  SubmitJob svc snap inputs ->
    cluster "submit job" Nothing $
      Runner.submitJob client svc snap inputs
  AwaitJob svc snap inputs ->
    cluster "wait for job" Nothing $
      Runner.runJob client svc snap inputs jobPollIntervalSeconds jobTimeoutSeconds
  ObserveJob ns jobName ->
    cluster "read job status" Nothing $
      Runner.observeJob client ns jobName
  CollectOutcome ns jobName startedAt endedAt phase ->
    cluster "collect job outcome" Nothing $
      Runner.collectOutcome client ns jobName startedAt endedAt phase
  where
    -- Every cluster call fails the same three ways, so they are classified
    -- once here rather than at each call site: a Deployment that cannot be
    -- read is 'DeploymentInspectionFailed' and names the Deployment, a
    -- credential plugin that would not run is 'KubeCredentialFailed' (the
    -- client re-runs it on a 401), and anything else names the operation that
    -- was in flight.
    cluster operation mDeployment act =
      Exc.trySync (liftIO act) >>= \case
        Right value -> pure value
        Left e
          | Just inspectionError <- Exc.fromException @InspectionError e ->
              throwError
                ( ShikiKubeError
                    ( DeploymentInspectionFailed
                        (maybe operation unDeploymentName mDeployment)
                        (message inspectionError)
                    )
                )
          | Just credentialError <- Exc.fromException @ExecCredentialError e ->
              throwError
                (ShikiKubeError (KubeCredentialFailed (message credentialError)))
          | otherwise ->
              throwError (ShikiKubeError (KubeRequestFailed operation (message e)))

-- | Load the operator's client config, turning both ways it can fail into a
--   typed 'ShikiError'.
loadKubeClient ::
  (IOE :> es, Error ShikiError :> es) =>
  Eff es ClientEnv
loadKubeClient =
  Exc.trySync (liftIO loadDefaultClientConfig) >>= \case
    Right client -> pure client
    Left e
      | Just credentialError <- Exc.fromException @ExecCredentialError e ->
          throwError (ShikiKubeError (KubeCredentialFailed (message credentialError)))
      | otherwise ->
          throwError (ShikiKubeError (KubeConfigUnavailable (message e)))

-- | One readable line for an exception that escaped a cluster call.
--
--   @http-client@'s own 'Show' for an 'HttpException' prints the entire
--   'Request' record — every header, the redirect count, the proxy mode — and
--   buries the two facts an operator needs. This keeps the request line and
--   the reason and drops the rest.
message :: (Exc.Exception e) => e -> Text
message e = case Exc.fromException @HttpException (Exc.toException e) of
  Just httpError -> renderHttpException httpError
  Nothing -> collapseWhitespace (Text.pack (Exc.displayException e))

renderHttpException :: HttpException -> Text
renderHttpException = \case
  InvalidUrlException url why -> Text.pack url <> ": " <> Text.pack why
  HttpExceptionRequest request content ->
    requestLine request <> ": " <> reason content
  where
    reason = \case
      InternalException inner -> collapseWhitespace (Text.pack (Exc.displayException inner))
      other -> collapseWhitespace (Text.pack (show other))

requestLine :: Request -> Text
requestLine request =
  utf8 (HttpClient.method request)
    <> " "
    <> (if HttpClient.secure request then "https://" else "http://")
    <> utf8 (HttpClient.host request)
    <> ":"
    <> Text.pack (show (HttpClient.port request))
    <> utf8 (HttpClient.path request)
  where
    utf8 = Text.Encoding.decodeUtf8Lenient
