-- | The Kubernetes half of a subcommand's context.
--
--   Until EP-19 this module also owned the Postgres pool and applied
--   migrations, which meant every database command loaded the operator's
--   kubeconfig whether or not it ever talked to the cluster: a broken
--   kubeconfig broke @shiki runs list@. Run storage now lives behind the
--   'Shiki.Effect.RunStore.RunStore' effect, so only the commands that really
--   reach the cluster ask for a client, and this module is what they ask.
module Shiki.Cli.Env
  ( CliEnv (..),
    withKubeClient,
  )
where

import Data.Text qualified as Text
import Effectful (Eff, IOE, type (:>))
import Effectful.Error.Static (Error, throwError)
import Effectful.Exception qualified as Exc
import Shiki.Error (KubeError (..), ShikiError (..), collapseWhitespace)
import Shiki.K8s.Client (ClientEnv, loadDefaultClientConfig)
import Shiki.K8s.ExecCredential (ExecCredentialError)
import Shiki.Prelude

newtype CliEnv = CliEnv
  { client :: ClientEnv
  }
  deriving stock (Generic)

-- | Load the default Kubernetes client config (@KUBECONFIG@, then
--   @~\/.kube\/config@) and hand it to the continuation. A failing credential
--   plugin is 'KubeCredentialFailed'; an unreadable or absent kubeconfig is
--   'KubeConfigUnavailable'. The 'ClientEnv' owns an @http-client@ manager
--   that needs no explicit teardown, so there is nothing to release.
withKubeClient ::
  (IOE :> es, Error ShikiError :> es) =>
  (CliEnv -> Eff es a) ->
  Eff es a
withKubeClient k = do
  client <-
    Exc.trySync (liftIO loadDefaultClientConfig) >>= \case
      Right cl -> pure cl
      Left e
        | Just credentialError <- Exc.fromException @ExecCredentialError e ->
            throwError (ShikiKubeError (KubeCredentialFailed (message credentialError)))
        | otherwise ->
            throwError (ShikiKubeError (KubeConfigUnavailable (message e)))
  k CliEnv {client}
  where
    message :: (Exc.Exception e) => e -> Text
    message = collapseWhitespace . Text.pack . Exc.displayException
