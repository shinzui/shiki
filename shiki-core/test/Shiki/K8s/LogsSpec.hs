-- | Pin the @pods/log@ request's accept type. With @Accept: text/plain@ the
--   Kubernetes 1.35 API server on GKE answers 406, and every run was recorded
--   without its log tail.
module Shiki.K8s.LogsSpec (tests) where

import Data.ByteString.Lazy qualified as BL
import Kubernetes.OpenAPI qualified as K8s
import Shiki.K8s.Logs (LogFetchError (..), PodLogText, renderLogFetchError)
import Shiki.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertEqual, testCase)

tests :: TestTree
tests =
  testGroup
    "Shiki.K8s.Logs"
    [ testCase "the pod-log request accepts */*, not text/plain" $
        assertEqual
          "accept"
          (Just "*/*")
          (show <$> K8s.mimeType (Proxy @PodLogText)),
      testCase "a plain-text log body decodes as text" $
        assertEqual
          "decoded"
          (Right "line one\nline two\n" :: Either String Text)
          (K8s.mimeUnrender (Proxy @PodLogText) "line one\nline two\n"),
      testCase "invalid UTF-8 in a log is replaced, not fatal" $
        assertEqual
          "decoded"
          (Right "ok \65533 ok\n" :: Either String Text)
          (K8s.mimeUnrender (Proxy @PodLogText) (BL.pack [111, 107, 32, 255, 32, 111, 107, 10])),
      testCase "a log read failure renders as one line naming the pod" $
        assertEqual
          "rendered"
          "reading the log of pod job-abc-xyz failed: HTTP 406 (error statusCode: 406): {}"
          (renderLogFetchError (PodLogReadFailed "job-abc-xyz" "HTTP 406 (error statusCode: 406): {}"))
    ]
