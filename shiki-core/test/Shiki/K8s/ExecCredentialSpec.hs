module Shiki.K8s.ExecCredentialSpec (tests) where

import Control.Exception (try)
import Data.Generics.Labels ()
import Data.Text qualified as T
import Shiki.K8s.ExecCredential
  ( ClusterRef (..),
    ExecAuth (..),
    ExecCredentialError (..),
    InteractiveMode (..),
    readKubeConfigExecAuth,
    runExecCredential,
  )
import Shiki.Prelude
import System.Directory (doesDirectoryExist, getCurrentDirectory)
import System.FilePath (takeDirectory, (</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase)

-- | Locate @shiki-core/test/fixtures@ whether the suite is run from the
--   package directory (cwd = @shiki-core/@) or the repo root, mirroring the
--   walk-up helper in 'Shiki.Service.ConfigSpec'.
fixturesDir :: IO FilePath
fixturesDir = getCurrentDirectory >>= locate
  where
    locate dir = do
      let here = dir </> "test" </> "fixtures"
          nested = dir </> "shiki-core" </> "test" </> "fixtures"
      hereExists <- doesDirectoryExist here
      nestedExists <- doesDirectoryExist nested
      if hereExists
        then pure here
        else
          if nestedExists
            then pure nested
            else
              let parent = takeDirectory dir
               in if parent == dir
                    then ioError (userError "no test/fixtures directory found above cwd")
                    else locate parent

fixture :: FilePath -> IO FilePath
fixture name = (</> name) <$> fixturesDir

-- | An 'ExecAuth' wired to a fixture plugin script. @provideClusterInfo@ is
--   toggled per-test to exercise 'KUBERNETES_EXEC_INFO' propagation.
execAuthFor :: FilePath -> Bool -> ExecAuth
execAuthFor scriptPath provide =
  ExecAuth
    { apiVersion = "client.authentication.k8s.io/v1beta1",
      command = T.pack scriptPath,
      args = [],
      environment = [],
      provideClusterInfo = provide,
      interactiveMode = IfAvailable
    }

dummyCluster :: ClusterRef
dummyCluster =
  ClusterRef
    { server = "https://34.x.y.z",
      caData = Just "QkFTRTY0Q0E=",
      caFile = Nothing,
      insecureSkipTls = False
    }

tests :: TestTree
tests =
  testGroup
    "Shiki.K8s.ExecCredential"
    [ testCase "resolves exec user from current-context" $ do
        path <- fixture "kubeconfig-exec.yaml"
        resolved <- readKubeConfigExecAuth path Nothing
        assertEqual
          "cluster server"
          "https://34.x.y.z"
          (resolved ^. #cluster . #server)
        assertEqual
          "cluster CA data"
          (Just "QkFTRTY0Q0E=")
          (resolved ^. #cluster . #caData)
        case resolved ^. #exec of
          Nothing -> assertFailure "expected an exec user, got Nothing"
          Just execAuth -> do
            assertEqual "command" "gke-gcloud-auth-plugin" (execAuth ^. #command)
            assertEqual "args" [] (execAuth ^. #args)
            assertEqual "env" [] (execAuth ^. #environment)
            assertBool "provideClusterInfo" (execAuth ^. #provideClusterInfo)
            assertEqual "interactiveMode" IfAvailable (execAuth ^. #interactiveMode),
      testCase "resolves token user to Nothing" $ do
        path <- fixture "kubeconfig-token.yaml"
        resolved <- readKubeConfigExecAuth path Nothing
        assertEqual "no exec auth" Nothing (resolved ^. #exec)
        assertEqual
          "cluster server"
          "https://10.0.0.1"
          (resolved ^. #cluster . #server),
      testCase "runExecCredential returns the plugin token" $ do
        script <- fixture "fake-exec-plugin.sh"
        token <- runExecCredential (execAuthFor script True) dummyCluster
        assertEqual "token" "ya29.test-token" token,
      testCase "KUBERNETES_EXEC_INFO is hidden when provideClusterInfo is false" $ do
        -- The fake plugin exits non-zero when it cannot see KUBERNETES_EXEC_INFO,
        -- so a False flag must surface as a plugin failure, proving the variable
        -- is only passed when provideClusterInfo is set.
        script <- fixture "fake-exec-plugin.sh"
        result <- try (runExecCredential (execAuthFor script False) dummyCluster)
        case result of
          Left (ExecPluginFailed _ code _) -> assertEqual "exit code" 3 code
          Left other -> assertFailure ("unexpected error: " <> show other)
          Right _ -> assertFailure "expected failure when KUBERNETES_EXEC_INFO is absent",
      testCase "non-zero plugin exit raises ExecCredentialError with stderr" $ do
        script <- fixture "fake-exec-plugin-fail.sh"
        result <- try (runExecCredential (execAuthFor script True) dummyCluster)
        case result of
          Left (ExecPluginFailed _ code err) -> do
            assertEqual "exit code" 1 code
            assertBool
              "stderr is propagated"
              ("boom" `T.isInfixOf` err)
          Left other -> assertFailure ("unexpected error: " <> show other)
          Right _ -> assertFailure "expected a plugin failure",
      testCase "cert-only status is rejected as unsupported" $ do
        script <- fixture "fake-exec-plugin-cert.sh"
        result <- try (runExecCredential (execAuthFor script True) dummyCluster)
        case result of
          Left (ExecCredentialCertModeUnsupported _) -> pure ()
          Left other -> assertFailure ("unexpected error: " <> show other)
          Right _ -> assertFailure "expected the cert-mode-unsupported error"
    ]
