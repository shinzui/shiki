-- | Authenticate to a Kubernetes cluster whose kubeconfig user uses an
--   __exec credential plugin__ (the @client.authentication.k8s.io@ contract,
--   e.g. GKE's @gke-gcloud-auth-plugin@). The upstream @kubernetes-api-client@
--   cannot represent exec auth at all — its @AuthInfo@ record has no @exec@
--   field, so the stanza is silently dropped on decode and the first API call
--   throws @AuthMethodException "AuthMethod not configured: AuthApiKeyBearerToken"@.
--
--   This module owns the missing piece: it parses the exec stanza out of the
--   kubeconfig itself (M1) and runs the plugin to mint a bearer token (M2).
--   'Shiki.K8s.Client' uses the result to build a token-authenticated client.
module Shiki.K8s.ExecCredential
  ( -- * Kubeconfig exec resolution
    InteractiveMode (..),
    ExecAuth (..),
    ClusterRef (..),
    ResolvedContext (..),
    KubeConfigDoc,
    KubeConfigError (..),
    execAuthForContext,
    readKubeConfigExecAuth,

    -- * Exec plugin runner
    ExecCredentialStatus (..),
    ExecCredentialError (..),
    runExecCredential,
  )
where

import Control.Exception (Exception, throwIO)
import Data.Aeson
  ( Value,
    eitherDecode,
    encode,
    object,
    withObject,
    (.:),
    (.:?),
    (.=),
  )
import Data.Aeson.Types (Parser)
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Lazy.Char8 qualified as BLC
import Data.Generics.Labels ()
import Data.List qualified as List
import Data.Text qualified as T
import Data.Text.Lazy qualified as TL
import Data.Text.Lazy.Encoding qualified as TLE
import Data.Yaml qualified as Yaml
import Shiki.Prelude hiding ((.=))
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.Process
  ( CreateProcess (env),
    proc,
    readCreateProcessWithExitCode,
  )

-- ---------------------------------------------------------------------------
-- M1: kubeconfig exec-stanza model + resolver
-- ---------------------------------------------------------------------------

-- | Whether the plugin may prompt interactively. GKE defaults to
--   'IfAvailable'. shiki runs non-interactively (it can be invoked from
--   CI/cron), so it sets @spec.interactive = false@ and refuses 'Always'.
data InteractiveMode = Never | IfAvailable | Always
  deriving stock (Eq, Show, Generic)

-- | The @user.exec@ stanza, modelling the @client.authentication.k8s.io@
--   contract. This is the data the library throws away.
data ExecAuth = ExecAuth
  { -- | e.g. @client.authentication.k8s.io/v1beta1@; echoed in the request and
    --   expected back in the response.
    apiVersion :: !Text,
    command :: !Text,
    args :: ![Text],
    -- | extra @name=value@ pairs overlaid on the plugin's environment.
    environment :: ![(Text, Text)],
    -- | when 'True', pass @KUBERNETES_EXEC_INFO@ describing the cluster.
    provideClusterInfo :: !Bool,
    interactiveMode :: !InteractiveMode
  }
  deriving stock (Eq, Show, Generic)

-- | The cluster a context points at — the master URI, the TLS CA, and (when
--   @provideClusterInfo@ is set) the @KUBERNETES_EXEC_INFO@ payload all come
--   from here. shiki uses this for the plugin request; the actual client TLS
--   is built from the library's own @Config@ in 'Shiki.K8s.Client'.
data ClusterRef = ClusterRef
  { server :: !Text,
    -- | base64 PEM (@certificate-authority-data@).
    caData :: !(Maybe Text),
    -- | path (@certificate-authority@), relative to the kubeconfig directory.
    caFile :: !(Maybe FilePath),
    insecureSkipTls :: !Bool
  }
  deriving stock (Eq, Show, Generic)

-- | The selected context resolved to its cluster and (optional) exec auth.
--   @exec = Nothing@ means the user is not an exec user, so the caller
--   falls back to the library's normal auth path.
data ResolvedContext = ResolvedContext
  { cluster :: !ClusterRef,
    exec :: !(Maybe ExecAuth)
  }
  deriving stock (Eq, Show, Generic)

-- | Raised when a kubeconfig cannot be resolved to a context/cluster/user.
newtype KubeConfigError = KubeConfigError Text
  deriving stock (Eq, Show)
  deriving anyclass (Exception)

-- | A kubeconfig decoded just far enough to answer the exec question. Only the
--   fields we need are modelled; aeson ignores the rest, so a full real-world
--   kubeconfig decodes fine.
data KubeConfigDoc = KubeConfigDoc
  { currentContext :: !(Maybe Text),
    contexts :: ![NamedContext],
    clusters :: ![NamedCluster],
    users :: ![NamedUser]
  }
  deriving stock (Eq, Show, Generic)

data NamedContext = NamedContext
  { name :: !Text,
    context :: !ContextRef
  }
  deriving stock (Eq, Show, Generic)

data ContextRef = ContextRef
  { cluster :: !Text,
    user :: !Text
  }
  deriving stock (Eq, Show, Generic)

data NamedCluster = NamedCluster
  { name :: !Text,
    cluster :: !ClusterRef
  }
  deriving stock (Eq, Show, Generic)

data NamedUser = NamedUser
  { name :: !Text,
    exec :: !(Maybe ExecAuth)
  }
  deriving stock (Eq, Show, Generic)

instance FromJSON KubeConfigDoc where
  parseJSON = withObject "kubeconfig" $ \o ->
    KubeConfigDoc
      <$> o .:? "current-context"
      <*> (fromMaybe [] <$> o .:? "contexts")
      <*> (fromMaybe [] <$> o .:? "clusters")
      <*> (fromMaybe [] <$> o .:? "users")

instance FromJSON NamedContext where
  parseJSON = withObject "context entry" $ \o ->
    NamedContext <$> o .: "name" <*> o .: "context"

instance FromJSON ContextRef where
  parseJSON = withObject "context" $ \o ->
    ContextRef <$> o .: "cluster" <*> o .: "user"

instance FromJSON NamedCluster where
  parseJSON = withObject "cluster entry" $ \o ->
    NamedCluster <$> o .: "name" <*> o .: "cluster"

instance FromJSON ClusterRef where
  parseJSON = withObject "cluster" $ \o ->
    ClusterRef
      <$> o .: "server"
      <*> o .:? "certificate-authority-data"
      <*> o .:? "certificate-authority"
      <*> (fromMaybe False <$> o .:? "insecure-skip-tls-verify")

instance FromJSON NamedUser where
  parseJSON = withObject "user entry" $ \o -> do
    userName <- o .: "name"
    userEntry <- o .: "user"
    mexec <- userEntry .:? "exec"
    pure (NamedUser userName mexec)

instance FromJSON ExecAuth where
  parseJSON = withObject "exec" $ \o -> do
    apiVer <- o .: "apiVersion"
    cmd <- o .: "command"
    argv <- fromMaybe [] <$> o .:? "args"
    rawEnv <- fromMaybe [] <$> o .:? "env"
    envPairs <- traverse parseEnvPair rawEnv
    provide <- fromMaybe False <$> o .:? "provideClusterInfo"
    mode <- o .:? "interactiveMode" >>= maybe (pure IfAvailable) parseInteractiveMode
    pure
      ExecAuth
        { apiVersion = apiVer,
          command = cmd,
          args = argv,
          environment = envPairs,
          provideClusterInfo = provide,
          interactiveMode = mode
        }

parseEnvPair :: Value -> Parser (Text, Text)
parseEnvPair = withObject "exec env entry" $ \o ->
  (,) <$> o .: "name" <*> o .: "value"

parseInteractiveMode :: Text -> Parser InteractiveMode
parseInteractiveMode t = case t of
  "Never" -> pure Never
  "IfAvailable" -> pure IfAvailable
  "Always" -> pure Always
  other -> fail ("unknown interactiveMode: " <> T.unpack other)

-- | Resolve a context (explicit name, else @current-context@) to its cluster
--   and exec auth. A missing context/cluster/user yields a descriptive 'Left'.
execAuthForContext :: Maybe Text -> KubeConfigDoc -> Either Text ResolvedContext
execAuthForContext mname doc = do
  ctxName <- case mname <|> doc ^. #currentContext of
    Just n -> Right n
    Nothing -> Left "kubeconfig has no current-context and no context was specified"
  ctx <-
    findBy (^. #name) ctxName (doc ^. #contexts) $
      "no context named " <> ctxName
  let ref = ctx ^. #context
  namedCluster <-
    findBy (^. #name) (ref ^. #cluster) (doc ^. #clusters) $
      "context " <> ctxName <> " references unknown cluster " <> ref ^. #cluster
  namedUser <-
    findBy (^. #name) (ref ^. #user) (doc ^. #users) $
      "context " <> ctxName <> " references unknown user " <> ref ^. #user
  Right
    ResolvedContext
      { cluster = namedCluster ^. #cluster,
        exec = namedUser ^. #exec
      }

findBy :: (a -> Text) -> Text -> [a] -> Text -> Either Text a
findBy key want xs err = maybe (Left err) Right (List.find ((== want) . key) xs)

-- | Read a kubeconfig from disk and resolve the current (or named) context.
--   Throws 'KubeConfigError' on a resolution failure (the YAML decoder throws
--   its own exception on a malformed file).
readKubeConfigExecAuth :: FilePath -> Maybe Text -> IO ResolvedContext
readKubeConfigExecAuth path mname = do
  doc <- Yaml.decodeFileThrow path
  case execAuthForContext mname doc of
    Left err -> throwIO (KubeConfigError err)
    Right rc -> pure rc

-- ---------------------------------------------------------------------------
-- M2: exec plugin runner
-- ---------------------------------------------------------------------------

-- | The @status@ block of an @ExecCredential@ response.
data ExecCredentialStatus = ExecCredentialStatus
  { token :: !(Maybe Text),
    clientCertData :: !(Maybe Text),
    clientKeyData :: !(Maybe Text),
    -- | parsed but currently ignored (shiki is short-lived; see the plan's
    --   Decision Log). Kept so a future long-running mode could cache.
    expirationTimestamp :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)

instance FromJSON ExecCredentialStatus where
  parseJSON = withObject "ExecCredential.status" $ \o ->
    ExecCredentialStatus
      <$> o .:? "token"
      <*> o .:? "clientCertificateData"
      <*> o .:? "clientKeyData"
      <*> o .:? "expirationTimestamp"

data ExecCredentialResponse = ExecCredentialResponse
  { apiVersion :: !(Maybe Text),
    kind :: !(Maybe Text),
    status :: !(Maybe ExecCredentialStatus)
  }
  deriving stock (Eq, Show, Generic)

instance FromJSON ExecCredentialResponse where
  parseJSON = withObject "ExecCredential" $ \o ->
    ExecCredentialResponse
      <$> o .:? "apiVersion"
      <*> o .:? "kind"
      <*> o .:? "status"

-- | Why an exec credential could not be obtained. Constructors are positional
--   (no shared record fields) so the @-Wpartial-fields@ check stays quiet; the
--   leading 'Text' is always the plugin command for context.
data ExecCredentialError
  = -- | command, exit code, captured stderr (plugin not installed / not logged in).
    ExecPluginFailed !Text !Int !Text
  | -- | raw stdout, aeson parse error.
    ExecPluginUnparseable !Text !String
  | -- | command, what was wrong with @kind@/@apiVersion@.
    ExecCredentialProtocol !Text !Text
  | -- | command; @interactiveMode: Always@ with no TTY available.
    ExecPluginInteractiveRefused !Text
  | -- | command; status carried client-cert data, which shiki does not yet support.
    ExecCredentialCertModeUnsupported !Text
  | -- | command; status had neither a token nor client-cert data.
    ExecCredentialNoToken !Text
  deriving stock (Eq, Show)
  deriving anyclass (Exception)

-- | Run the credential plugin per the @client.authentication.k8s.io@ contract
--   and return the bearer token. Throws 'ExecCredentialError' on any failure.
runExecCredential :: ExecAuth -> ClusterRef -> IO Text
runExecCredential execAuth clusterRef = do
  when (execAuth ^. #interactiveMode == Always) $
    throwIO (ExecPluginInteractiveRefused (execAuth ^. #command))
  childEnv <- buildChildEnv execAuth clusterRef
  let cmd = T.unpack (execAuth ^. #command)
      argv = map T.unpack (execAuth ^. #args)
      createProc = (proc cmd argv) {env = Just childEnv}
  (code, out, err) <- readCreateProcessWithExitCode createProc ""
  case code of
    ExitFailure n ->
      throwIO (ExecPluginFailed (execAuth ^. #command) n (T.pack err))
    ExitSuccess ->
      case eitherDecode (BLC.pack out) of
        Left perr -> throwIO (ExecPluginUnparseable (T.pack out) perr)
        Right resp -> extractToken execAuth resp

-- | Assemble the plugin's environment: the parent process environment, with
--   the exec @env@ pairs overlaid, plus @KUBERNETES_EXEC_INFO@ when
--   @provideClusterInfo@ is set.
buildChildEnv :: ExecAuth -> ClusterRef -> IO [(String, String)]
buildChildEnv execAuth clusterRef = do
  parent <- getEnvironment
  let overlay = [(T.unpack n, T.unpack v) | (n, v) <- execAuth ^. #environment]
      execInfo
        | execAuth ^. #provideClusterInfo =
            [("KUBERNETES_EXEC_INFO", lazyUtf8ToString (encodeExecInfo execAuth clusterRef))]
        | otherwise = []
  pure (mergeEnv parent (overlay <> execInfo))

-- | Right-biased environment merge: entries in @over@ replace same-named
--   entries in @base@.
mergeEnv :: [(String, String)] -> [(String, String)] -> [(String, String)]
mergeEnv base overrides =
  let overKeys = map fst overrides
   in [kv | kv@(k, _) <- base, k `notElem` overKeys] <> overrides

-- | The @ExecCredential@ /request/ written to @KUBERNETES_EXEC_INFO@.
encodeExecInfo :: ExecAuth -> ClusterRef -> BL.ByteString
encodeExecInfo execAuth clusterRef =
  encode $
    object
      [ "apiVersion" .= (execAuth ^. #apiVersion),
        "kind" .= ("ExecCredential" :: Text),
        "spec"
          .= object
            [ "cluster"
                .= object
                  ( ["server" .= (clusterRef ^. #server)]
                      <> maybe
                        []
                        (\d -> ["certificate-authority-data" .= d])
                        (clusterRef ^. #caData)
                  ),
              "interactive" .= False
            ]
      ]

lazyUtf8ToString :: BL.ByteString -> String
lazyUtf8ToString = TL.unpack . TLE.decodeUtf8

-- | Validate the response envelope and pull the bearer token out, mapping the
--   cert-only and empty cases to explicit errors.
extractToken :: ExecAuth -> ExecCredentialResponse -> IO Text
extractToken execAuth resp = do
  let cmd = execAuth ^. #command
  case resp ^. #kind of
    Just "ExecCredential" -> pure ()
    _ -> throwIO (ExecCredentialProtocol cmd "response kind was not \"ExecCredential\"")
  case resp ^. #apiVersion of
    Just v | v == execAuth ^. #apiVersion -> pure ()
    _ -> throwIO (ExecCredentialProtocol cmd "response apiVersion missing or did not match the request")
  credStatus <- maybe (throwIO (ExecCredentialNoToken cmd)) pure (resp ^. #status)
  case credStatus ^. #token of
    Just tok | not (T.null tok) -> pure tok
    _ -> case (credStatus ^. #clientCertData, credStatus ^. #clientKeyData) of
      (Just _, Just _) -> throwIO (ExecCredentialCertModeUnsupported cmd)
      _ -> throwIO (ExecCredentialNoToken cmd)
