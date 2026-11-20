-- | Loads the operator's kubeconfig and produces the @(Manager, Config)@
--   bundle that every other @Shiki.K8s.*@ module needs to talk to the
--   cluster. Centralised so callers do not have to know which kubeconfig
--   path or which auth handler is in play.
module Shiki.K8s.Client
  ( ClientEnv (..),
    KubeConfigSource (..),
    loadDefaultClientConfig,
    loadClientConfig,
    loadDefaultClientForContext,
    loadFileClientForContext,
    MissingContext (..),
    dispatchK8s,
    retryOnUnauthorized,
  )
where

import Control.Concurrent.STM (atomically, newTVar)
import Control.Exception (Exception, throwIO)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Yaml qualified as Yaml
import Kubernetes.Client.Config
  ( KubeConfigSource (..),
    addCACertData,
    addCACertFile,
    applyAuthSettings,
    defaultTLSClientParams,
    mkKubeClientConfig,
    newManager,
    setMasterURI,
    setTokenAuth,
    tlsValidation,
  )
import Kubernetes.Client.KubeConfig qualified as KC
import Kubernetes.OpenAPI qualified as K8s
import Network.HTTP.Client (Manager, responseStatus)
import Network.HTTP.Types.Status (statusCode)
import Shiki.K8s.ExecCredential
  ( KubeConfigError (..),
    execAuthForContext,
    hasContext,
    runExecCredential,
  )
import Shiki.Prelude
import System.Directory (getHomeDirectory)
import System.Environment (lookupEnv)
import System.FilePath (takeDirectory, (</>))

-- | A bundle of the HTTP connection 'Manager' and the typed
--   'K8s.KubernetesClientConfig' that every API call needs. Built once
--   per CLI invocation by 'loadDefaultClientConfig'.
--
--   The config is held in an 'IORef' because a credential can expire while
--   the process is still running: an exec-plugin token (GKE\'s
--   @gke-gcloud-auth-plugin@ hands out what is left of a one-hour token)
--   routinely dies mid-wait under @shiki run@, whose polling loop is meant
--   to outlive it. 'renewAuth' mints a replacement; 'dispatchK8s' installs
--   it on a 401 and every later call picks it up from the ref.
data ClientEnv = ClientEnv
  { httpManager :: !Manager,
    clientConfigRef :: !(IORef K8s.KubernetesClientConfig),
    -- | Mint a fresh config, or 'Nothing' for auth methods whose credential
    --   shiki does not own (client cert, OIDC, in-cluster service account).
    renewAuth :: !(Maybe (IO K8s.KubernetesClientConfig))
  }
  deriving stock (Generic)

-- | Dispatch a Kubernetes request, re-minting the credential once and
--   retrying if the API server answers @401 Unauthorized@.
--
--   Every @Shiki.K8s.*@ call goes through here rather than calling
--   @dispatchMime@ directly, so a token that expires mid-run costs one
--   retried request instead of failing the run.
dispatchK8s ::
  (K8s.Produces req accept, K8s.MimeUnrender accept res, K8s.MimeType contentType) =>
  ClientEnv ->
  K8s.KubernetesRequest req contentType res accept ->
  IO (K8s.MimeResult res)
dispatchK8s env req =
  retryOnUnauthorized
    isUnauthorized
    (env ^. #renewAuth)
    (writeIORef (env ^. #clientConfigRef))
    (\cfg -> K8s.dispatchMime (env ^. #httpManager) cfg req)
    =<< readIORef (env ^. #clientConfigRef)

-- | Run @perform@; if its result looks unauthorized and a @renew@ action is
--   available, mint a new credential, hand it to @store@, and run @perform@
--   once more with it. Retries at most once: a second 401 is a real answer
--   (the identity genuinely lacks access) rather than an expired token.
retryOnUnauthorized ::
  (Monad m) =>
  -- | Does this result mean \"unauthorized\"?
  (resp -> Bool) ->
  -- | Mint a fresh credential.
  Maybe (m cfg) ->
  -- | Remember the fresh credential for later calls.
  (cfg -> m ()) ->
  -- | Perform the request with a given credential.
  (cfg -> m resp) ->
  cfg ->
  m resp
retryOnUnauthorized unauthorized renew store perform cfg = do
  resp <- perform cfg
  case renew of
    Just mint | unauthorized resp -> do
      cfg' <- mint
      store cfg'
      perform cfg'
    _ -> pure resp

isUnauthorized :: K8s.MimeResult a -> Bool
isUnauthorized r = statusCode (responseStatus (K8s.mimeResultResponse r)) == 401

-- | Resolve the operator's current kube context from the standard locations:
--   honor @KUBECONFIG@ if set, otherwise read @\$HOME/.kube/config@. Wires
--   the auth handlers registered by @kubernetes-api-client@ (token, client
--   cert, GCP, OIDC) by passing a fresh OIDC cache.
loadDefaultClientConfig :: IO ClientEnv
loadDefaultClientConfig = snd <$> loadDefaultClientForContext Nothing

loadDefaultClientForContext :: Maybe Text -> IO (Text, ClientEnv)
loadDefaultClientForContext requested = do
  envPath <- lookupEnv "KUBECONFIG"
  path <- maybe ((</> ".kube/config") <$> getHomeDirectory) pure envPath
  loadFileClientForContext path requested

loadClientConfig :: KubeConfigSource -> IO ClientEnv
loadClientConfig (KubeConfigFile path) = snd <$> loadFileClientForContext path Nothing
loadClientConfig KubeConfigCluster = do
  oidcCache <- atomically (newTVar Map.empty)
  (mgr, cfg) <- mkKubeClientConfig oidcCache KubeConfigCluster
  ref <- newIORef cfg
  pure (ClientEnv mgr ref Nothing)

newtype MissingContext = MissingContext Text
  deriving stock (Eq, Show)
  deriving anyclass (Exception)

-- | Take one snapshot. Both the regular auth handlers and any later exec
-- refresh use the cluster and user selected from these bytes.
loadFileClientForContext :: FilePath -> Maybe Text -> IO (Text, ClientEnv)
loadFileClientForContext path requested = do
  bytes <- BS.readFile path
  snapshot <- Yaml.decodeThrow bytes
  -- A named context also works when kubectl has no current context set.
  let selectedDoc = case (requested, snapshot) of
        (Just name, Aeson.Object fields) ->
          Aeson.Object (KeyMap.insert "current-context" (Aeson.String name) fields)
        _ -> snapshot
  execDoc <- decodeConfig selectedDoc
  case requested of
    Just name | not (hasContext name execDoc) -> throwIO (MissingContext name)
    _ -> pure ()
  selected <- decodeConfig selectedDoc
  let name = KC.currentContext selected
  server <- case requested of
    Just _ -> either (throwIO . KubeConfigError . Text.pack) (pure . KC.server) (KC.getCluster selected)
    Nothing -> pure (either (const "localhost:8080") KC.server (KC.getCluster selected))
  let resolved = execAuthForContext (Just name) execDoc
  base <- defaultTLSClientParams
  withData <- addCACertData selected base
  withFile <- addCACertFile selected (takeDirectory path) withData
  let tls = tlsValidation selected withFile
      baseConfig = setMasterURI server <$> K8s.newConfig
  (params, cfg, refresh) <- case resolved of
    Right rc | Just plugin <- rc ^. #exec -> do
      let mint = do
            token <- runExecCredential plugin (rc ^. #cluster)
            setTokenAuth token <$> baseConfig
      initial <- mint
      pure (tls, initial, Just mint)
    _ -> do
      initial <- baseConfig
      oidcCache <- atomically (newTVar Map.empty)
      (params, cfg) <- case KC.getAuthInfo selected of
        Left _ -> pure (tls, initial)
        Right (_, auth) -> do
          let relativeToConfig = (takeDirectory path </>)
              authFiles =
                auth
                  { KC.clientCertificate = relativeToConfig <$> KC.clientCertificate auth,
                    KC.clientKey = relativeToConfig <$> KC.clientKey auth
                  }
          applyAuthSettings oidcCache authFiles (tls, initial)
      pure (params, cfg, Nothing)
  mgr <- newManager params
  ref <- newIORef cfg
  pure (name, ClientEnv mgr ref refresh)
  where
    decodeConfig :: (FromJSON a) => Aeson.Value -> IO a
    decodeConfig value = case Aeson.fromJSON value of
      Aeson.Error err -> throwIO (KubeConfigError (Text.pack err))
      Aeson.Success cfg -> pure cfg
