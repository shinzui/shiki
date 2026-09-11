-- | A Kubernetes credential can die while shiki is still waiting on a Job:
--   GKE's exec plugin hands out what is left of a one-hour token, and
--   @shiki run@ blocks for as long as the Job takes. These tests pin the two
--   behaviours that keep such a run from being reported as failed.
module Shiki.K8s.CredentialExpirySpec (tests) where

import Control.Exception (Exception, throwIO, try)
import Data.Functor (($>))
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Kubernetes.OpenAPI qualified as K8s
import Kubernetes.OpenAPI.ModelLens qualified as K8sLens
import Shiki.K8s.Client (retryOnUnauthorized)
import Shiki.K8s.Runner
  ( JobPhase (..),
    maxConsecutiveStatusFailures,
    waitForCompletionWith,
  )
import Shiki.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase)

tests :: TestTree
tests =
  testGroup
    "Shiki.K8s (credential expiry)"
    [ testGroup
        "retryOnUnauthorized"
        [ testCase "mints a new credential and retries once on 401" $ do
            calls <- newIORef ([] :: [Text])
            stored <- newIORef ("stale" :: Text)
            -- Unauthorized under the stale token, fine under the fresh one.
            let perform cfg = modifyList calls cfg $> (cfg == "stale")
            resp <-
              retryOnUnauthorized id (Just (pure "fresh")) (writeIORef stored) perform "stale"
            assertEqual "second attempt authorized" False resp
            assertEqual "tried both credentials" ["stale", "fresh"] =<< readIORef calls
            assertEqual "fresh credential kept for later calls" "fresh" =<< readIORef stored,
          testCase "does not retry when there is no credential to mint" $ do
            calls <- newIORef ([] :: [Text])
            let perform cfg = modifyList calls cfg $> True
            resp <- retryOnUnauthorized id Nothing (const (pure ())) perform "static"
            assertEqual "the 401 is returned as-is" True resp
            assertEqual "request issued once" ["static"] =<< readIORef calls,
          testCase "does not retry an authorized response" $ do
            calls <- newIORef ([] :: [Text])
            let perform cfg = modifyList calls cfg $> False
            _ <- retryOnUnauthorized id (Just (pure "fresh")) (const (pure ())) perform "token"
            assertEqual "request issued once" ["token"] =<< readIORef calls,
          testCase "gives up after a second 401 rather than minting forever" $ do
            calls <- newIORef ([] :: [Text])
            let perform cfg = modifyList calls cfg $> True
            resp <- retryOnUnauthorized id (Just (pure "fresh")) (const (pure ())) perform "stale"
            assertEqual "still unauthorized" True resp
            assertEqual "exactly two attempts" ["stale", "fresh"] =<< readIORef calls
        ],
      testGroup
        "waitForCompletionWith"
        [ testCase "keeps polling through transient status-read failures" $ do
            readStatus <- scriptedReads [Left StatusReadBoom, Left StatusReadBoom, Right succeeded]
            phase <- runWait readStatus
            assertEqual "" JobSucceeded phase,
          testCase "a failure run shorter than the cap does not end the wait" $ do
            let failures = replicate (maxConsecutiveStatusFailures - 1) (Left StatusReadBoom)
            readStatus <- scriptedReads (failures <> [Right succeeded])
            phase <- runWait readStatus
            assertEqual "" JobSucceeded phase,
          testCase "the failure count resets after a good read" $ do
            let failures = replicate (maxConsecutiveStatusFailures - 1) (Left StatusReadBoom)
            readStatus <-
              scriptedReads (failures <> [Right stillRunning] <> failures <> [Right succeeded])
            phase <- runWait readStatus
            assertEqual "" JobSucceeded phase,
          testCase "gives up once reads fail consecutively past the cap" $ do
            readStatus <-
              scriptedReads (replicate maxConsecutiveStatusFailures (Left StatusReadBoom))
            result <- try @StatusReadBoom (runWait readStatus)
            assertBool "the read error propagates" (isLeft result)
        ]
    ]
  where
    modifyList ref x = atomicModifyIORef' ref (\xs -> (xs <> [x], ()))
    isLeft = either (const True) (const False)

-- | Stands in for whatever the status read throws (a 401 wrapped in
--   @JobStatusReadFailed@, an HTTP exception, a DNS blip).
data StatusReadBoom = StatusReadBoom
  deriving stock (Eq, Show)
  deriving anyclass (Exception)

-- | A status reader that replays the given outcomes in order, then throws if
--   the loop asks for more than the script provides.
scriptedReads :: [Either StatusReadBoom K8s.V1JobStatus] -> IO (IO K8s.V1JobStatus)
scriptedReads script = do
  remaining <- newIORef script
  pure (nextRead remaining)

nextRead :: IORef [Either StatusReadBoom K8s.V1JobStatus] -> IO K8s.V1JobStatus
nextRead remaining = do
  next <- atomicModifyIORef' remaining $ \case
    [] -> ([], Nothing)
    (x : xs) -> (xs, Just x)
  case next of
    Nothing -> throwIO StatusReadBoom
    Just (Left err) -> throwIO err
    Just (Right status) -> pure status

-- | Poll with no delay and a timeout far larger than any test needs, so only
--   the scripted reads decide the outcome.
runWait :: IO K8s.V1JobStatus -> IO JobPhase
runWait readStatus = do
  startedAt <- getCurrentTime
  waitForCompletionWith readStatus startedAt 0 3600

succeeded :: K8s.V1JobStatus
succeeded = K8s.mkV1JobStatus & K8sLens.v1JobStatusSucceededL ?~ 1

-- | Neither succeeded nor failed yet: the loop must poll again.
stillRunning :: K8s.V1JobStatus
stillRunning = K8s.mkV1JobStatus & K8sLens.v1JobStatusActiveL ?~ 1
