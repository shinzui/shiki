-- | Loopback API server. Each instance records its own requests.
module Shiki.Cli.ClusterFixture (Cluster, withCluster, requests, kubeconfig, tokenUser, tests) where

import Control.Exception (try)
import Data.Aeson (Value (..), decode, encode, object, toJSON, (.:), (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (parseMaybe)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.IORef
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Network.HTTP.Types
import Network.Wai
import Network.Wai.Handler.Warp (Port, testWithApplication)
import Shiki.K8s.Client (MissingContext (..), loadFileClientForContext)
import Shiki.K8s.ExecCredential (KubeConfigError)
import Shiki.K8s.Introspection (DeploymentName (..), Namespace (..), deploymentExists)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

type RequestLog = [(BS.ByteString, [Text], Maybe BS.ByteString)]

data Cluster = Cluster !Port !(IORef RequestLog)

requests :: Cluster -> IO RequestLog
requests (Cluster _ ref) = reverse <$> readIORef ref

withCluster :: Text -> (Cluster -> IO a) -> IO a
withCluster token action = do
  ref <- newIORef []
  jobs <- newIORef []
  testWithApplication (pure (api ref jobs)) $ \port -> action (Cluster port ref)
  where
    api ref jobs req respond = do
      let method = requestMethod req
          path = pathInfo req
          auth = lookup hAuthorization (requestHeaders req)
      atomicModifyIORef' ref (\xs -> ((method, path, auth) : xs, ()))
      let json status = responseLBS status [(hContentType, "application/json")]
      response <-
        if auth /= Just ("Bearer " <> TE.encodeUtf8 token)
          then pure (json status401 "{}")
          else case (method, path) of
            ("GET", ["apis", "apps", "v1", "namespaces", _, "deployments", "worker"]) ->
              pure (json status200 deployment)
            ("POST", ["apis", "batch", "v1", "namespaces", ns, "jobs"]) -> do
              body <- strictRequestBody req
              case decode body >>= parseMaybe (\job -> job .: "metadata" >>= (.: "name")) of
                Just name -> do
                  atomicModifyIORef' jobs (\xs -> ((ns, name) : xs, ()))
                  pure (json status201 body)
                Nothing -> pure (json status400 "{}")
            ("GET", ["apis", "batch", "v1", "namespaces", ns, "jobs", name, "status"]) -> do
              submitted <- readIORef jobs
              pure $
                if (ns, name) `elem` submitted
                  then json status200 "{\"status\":{\"succeeded\":1}}"
                  else json status404 "{}"
            ("GET", ["api", "v1", "namespaces", _, "pods"]) ->
              pure (json status200 "{\"items\":[{\"metadata\":{\"name\":\"worker-pod\"}}]}")
            ("GET", ["api", "v1", "namespaces", _, "pods", "worker-pod", "log"]) ->
              pure (responseLBS status200 [(hContentType, "text/plain")] "completed")
            _ -> pure (json status404 "{}")
      respond response

deployment :: BL.ByteString
deployment =
  """
  {"spec":{"selector":{},"template":{"spec":{"containers":[
    {"name":"worker","image":"worker:test","env":[
      {"name":"CONFIG","valueFrom":{"configMapKeyRef":{"name":"config","key":"config"}}},
      {"name":"SECRET","valueFrom":{"secretKeyRef":{"name":"secret","key":"secret"}}}
    ]}
  ]}}}}
  """

-- | Entries use separate cluster, context, and credential names so an
-- implementation cannot accidentally substitute one name for another.
kubeconfig :: [(Text, Cluster, Value)] -> BL.ByteString
kubeconfig entries =
  encode $
    object
      [ "current-context" .= ("local" :: Text),
        "clusters" .= [object ["name" .= (name <> "-cluster"), "cluster" .= object ["server" .= ("http://127.0.0.1:" <> show port)]] | (name, Cluster port _, _) <- entries],
        "contexts" .= [object ["name" .= name, "context" .= object ["cluster" .= (name <> "-cluster"), "user" .= (name <> "-user")]] | (name, _, _) <- entries],
        "users" .= [object ["name" .= (name <> "-user"), "user" .= user] | (name, _, user) <- entries]
      ]

tokenUser :: Text -> Value
tokenUser token = object ["token" .= token]

tests :: TestTree
tests =
  testGroup
    "file client routing"
    [ testCase "a binding can select a context with no current context, but needs a resolvable cluster" $
        withCluster "token" $ \cluster -> withSystemTempDirectory "shiki-bound" $ \dir -> do
          let path = dir </> "config"
          case decode (kubeconfig [("named", cluster, tokenUser "token")]) of
            Just (Object fields) -> do
              let noCurrent = KeyMap.delete "current-context" fields
              BL.writeFile path (encode (Object noCurrent))
              (name, client) <- loadFileClientForContext path (Just "named")
              name @?= "named"
              deploymentExists client (Namespace "ns") (DeploymentName "worker") >>= (@?= True)
              BL.writeFile path (encode (Object (KeyMap.insert "clusters" (toJSON ([] :: [Value])) noCurrent)))
              try @KubeConfigError (loadFileClientForContext path (Just "named")) >>= \case
                Left _ -> pure ()
                Right _ -> assertFailure "constructed client with no referenced cluster"
            _ -> assertFailure "invalid fixture"
          BL.writeFile path "contexts: null"
          try @MissingContext (loadFileClientForContext path (Just "named")) >>= \case
            Left err -> err @?= MissingContext "named"
            Right _ -> assertFailure "accepted empty config",
      testCase "selects endpoint and user, retaining the kubeconfig snapshot through a 401" $
        withCluster "local-token" $ \local -> withCluster "prod-token" $ \prod ->
          withSystemTempDirectory "shiki-auth" $ \dir -> do
            let path = dir </> "config"
                localEntry = ("local", local, tokenUser "local-token")
                probe client = deploymentExists client (Namespace "ops") (DeploymentName "worker")
                load user = do
                  let bytes = kubeconfig [localEntry, ("sennari", prod, user)]
                  BL.writeFile path bytes
                  (name, client) <- loadFileClientForContext path (Just "sennari")
                  name @?= "sennari"
                  BS.readFile path >>= (@?= BL.toStrict bytes)
                  pure client
            regular <- load (tokenUser "prod-token")
            probe regular >>= (@?= True)
            let script = dir </> "credential.sh"
            writeFile script $
              unlines
                [ "if test -e \"$1\"; then token=prod-token; else token=expired; touch \"$1\"; fi",
                  "printf '{\"apiVersion\":\"client.authentication.k8s.io/v1\",\"kind\":\"ExecCredential\",\"status\":{\"token\":\"%s\"}}' \"$token\""
                ]
            plugin <-
              load $
                object
                  [ "exec"
                      .= object
                        ["apiVersion" .= ("client.authentication.k8s.io/v1" :: Text), "command" .= ("sh" :: Text), "args" .= [script, dir </> "minted"]]
                  ]
            BL.writeFile path (kubeconfig [localEntry])
            probe plugin >>= (@?= True)
            requests local >>= (@?= [])
            seen <- requests prod
            [auth | (_, _, auth) <- seen] @?= map Just ["Bearer prod-token", "Bearer expired", "Bearer prod-token"]
            try @MissingContext (loadFileClientForContext path (Just "sennari")) >>= \case
              Left err -> err @?= MissingContext "sennari"
              Right _ -> assertFailure "accepted missing context"
    ]
