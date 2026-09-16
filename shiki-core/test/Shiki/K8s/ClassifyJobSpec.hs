-- | 'classifyJob' is what @shiki runs sync@ trusts to finalize a run whose
--   waiting process is gone, so pin how a Job's status maps to a phase and
--   an end time.
module Shiki.K8s.ClassifyJobSpec (tests) where

import Data.Time qualified as Time
import Kubernetes.OpenAPI qualified as K8s
import Shiki.K8s.Runner (JobObservation (..), JobPhase (..), classifyJob)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertEqual, testCase)

tests :: TestTree
tests =
  testGroup
    "Shiki.K8s.Runner.classifyJob"
    [ testCase "a Job with no status is active" $
        assertEqual "active" JobActive (classifyJob K8s.mkV1Job),
      testCase "a Job with only active pods is active" $
        assertEqual
          "active"
          JobActive
          (classifyJob (withStatus K8s.mkV1JobStatus {K8s.v1JobStatusActive = Just 1})),
      testCase "a succeeded Job ends at its completionTime" $
        assertEqual
          "succeeded"
          (JobFinished JobSucceeded (Just t1))
          ( classifyJob
              ( withStatus
                  K8s.mkV1JobStatus
                    { K8s.v1JobStatusSucceeded = Just 1,
                      K8s.v1JobStatusCompletionTime = Just (K8s.DateTime t1)
                    }
              )
          ),
      testCase "a failed Job carries its reason and ends when the Failed condition was set" $
        assertEqual
          "failed"
          (JobFinished (JobFailed "BackoffLimitExceeded") (Just t2))
          ( classifyJob
              ( withStatus
                  K8s.mkV1JobStatus
                    { K8s.v1JobStatusFailed = Just 1,
                      K8s.v1JobStatusConditions =
                        Just
                          [ condition "FailureTarget" t1,
                            condition "Failed" t2
                          ]
                    }
              )
          )
    ]
  where
    t1 = Time.UTCTime (Time.fromGregorian 2026 9 14) (Time.secondsToDiffTime 79800)
    t2 = Time.UTCTime (Time.fromGregorian 2026 9 14) (Time.secondsToDiffTime 79830)
    withStatus s = K8s.mkV1Job {K8s.v1JobStatus = Just s}
    condition ty t =
      (K8s.mkV1JobCondition "True" ty)
        { K8s.v1JobConditionReason = Just "BackoffLimitExceeded",
          K8s.v1JobConditionLastTransitionTime = Just (K8s.DateTime t)
        }
