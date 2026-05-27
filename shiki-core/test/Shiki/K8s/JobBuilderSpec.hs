module Shiki.K8s.JobBuilderSpec (tests) where

import Shiki.Prelude

import Shiki.K8s.Introspection (DeploymentSnapshot (..), Namespace (..))
import Shiki.K8s.JobBuilder    (JobInputs (..), buildJob)
import Shiki.Service.Config.Dhall (loadServiceConfig)

import "base" GHC.Stack (HasCallStack)
import "directory" System.Directory (doesDirectoryExist, getCurrentDirectory)
import "filepath" System.FilePath ((</>), takeDirectory)
import "kubernetes-api" Kubernetes.OpenAPI.ModelLens qualified as K8sLens
import "tasty" Test.Tasty (TestTree, testGroup)
import "tasty-hunit" Test.Tasty.HUnit (assertBool, assertEqual, testCase)

-- | Walk up from cwd to find a sibling @services/@ directory; mirrors the
--   helper in 'Shiki.Service.ConfigSpec' so the test can be invoked from
--   either the repo root or @shiki-core/@.
serviceConfigPath :: FilePath -> IO FilePath
serviceConfigPath name = do
  start <- getCurrentDirectory
  root  <- locate start
  pure (root </> "services" </> name <> ".dhall")
  where
    locate dir = do
      hit <- doesDirectoryExist (dir </> "services")
      if hit
        then pure dir
        else
          let parent = takeDirectory dir
          in  if parent == dir
                then ioError (userError "no `services/` directory found above cwd")
                else locate parent

tests :: TestTree
tests = testGroup "Shiki.K8s.JobBuilder"
  [ testCase "buildJob produces a Job whose container name, image, command, and args match the inputs" $ do
      path <- serviceConfigPath "mls-service-v2"
      svc  <- loadServiceConfig path
      let snap = DeploymentSnapshot
            { image         = "gcr.io/example/mls-service-v2:abc"
            , configMapName = "mls-cm"
            , secretName    = "mls-sec"
            }
          inputs = JobInputs
            { namespace = Namespace "prod"
            , args      = ["subscription", "process"]
            , jobName   = "mls-service-v2-oneoff-test"
            }
          job   = buildJob svc snap inputs
          spec  = expectJust "spec"         (job ^. K8sLens.v1JobSpecL)
          tmpl  = spec ^. K8sLens.v1JobSpecTemplateL
          pspec = expectJust "podSpec"      (tmpl ^. K8sLens.v1PodTemplateSpecSpecL)
          containers = pspec ^. K8sLens.v1PodSpecContainersL

      assertEqual "metadata name"
        (Just "mls-service-v2-oneoff-test")
        (job ^. K8sLens.v1JobMetadataL >>= (^. K8sLens.v1ObjectMetaNameL))

      c <- case containers of
        (c0 : _) -> pure c0
        []       -> error "expected at least one container"
      assertEqual "container count" 1 (length containers)
      assertEqual "container name"  "mls-service-v2"                       (c ^. K8sLens.v1ContainerNameL)
      assertEqual "image"           (Just "gcr.io/example/mls-service-v2:abc") (c ^. K8sLens.v1ContainerImageL)
      assertEqual "command"         (Just ["/app/mls-service-v2"])         (c ^. K8sLens.v1ContainerCommandL)
      assertEqual "args"            (Just ["subscription", "process"])     (c ^. K8sLens.v1ContainerArgsL)
      assertBool  "has init containers"
        (not (null (fromMaybe [] (pspec ^. K8sLens.v1PodSpecInitContainersL))))
      assertEqual "backoffLimit"    (Just 0)    (spec ^. K8sLens.v1JobSpecBackoffLimitL)
      assertEqual "ttlSecondsAfterFinished"
        (Just 3600)
        (spec ^. K8sLens.v1JobSpecTtlSecondsAfterFinishedL)
      assertEqual "restart policy"  (Just "Never") (pspec ^. K8sLens.v1PodSpecRestartPolicyL)
  ]

expectJust :: HasCallStack => String -> Maybe a -> a
expectJust label = \case
  Just x  -> x
  Nothing -> error ("expected Just for " <> label)
