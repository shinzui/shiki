module Main (main) where

import Data.Text qualified as Text
import Shiki.K8s.Client (loadDefaultClientConfig)
import Shiki.K8s.Introspection
  ( DeploymentName (..),
    Namespace (..),
    inspectDeployment,
  )
import Shiki.K8s.JobBuilder (JobInputs (..), generateJobName)
import Shiki.K8s.Runner (runJob)
import Shiki.Prelude
import Shiki.Service.Config.Dhall (loadServiceConfig)
import System.Environment (getArgs)

-- | Live-cluster smoke test for the Job runner. Loads
--   @services\/\<service\>.dhall@, talks to the operator's current kube
--   context, submits a one-off Job, follows it to completion, and
--   prints the 'JobOutcome'.
--
-- @
-- shiki-run-once \<service\> -- \<command args...\>
-- @
main :: IO ()
main = do
  rawArgs <- getArgs
  (svcName, cmd) <- case break (== "--") rawArgs of
    (s : _, "--" : rest) -> pure (s, rest)
    _ -> error "usage: shiki-run-once <service-name> -- <args...>"
  cfg <- loadServiceConfig ("services/" <> svcName <> ".dhall")
  env <- loadDefaultClientConfig
  snap <-
    inspectDeployment
      env
      (Namespace (cfg ^. #defaultNamespace))
      (DeploymentName (cfg ^. #detectFromDeployment))
      (cfg ^. #containerName)
  now <- getCurrentTime
  nm <- generateJobName (cfg ^. #name) now
  let inputs =
        JobInputs
          { namespace = Namespace (cfg ^. #defaultNamespace),
            args = map Text.pack cmd,
            jobName = nm
          }
  outcome <- runJob env cfg snap inputs 5 345600
  print outcome
