module Shiki.Cli.Runs.SyncSpec (tests) where

import Data.Time.Clock (addUTCTime)
import Shiki.Cli.Fixtures (fixtureRow)
import Shiki.Cli.Runs.Sync (SyncAction (..), decideSync)
import Shiki.K8s.Runner (JobObservation (..), JobPhase (..))
import Shiki.Persistence.Run (RunRecord (..))
import Shiki.Persistence.RunStatus (RunStatus (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertEqual, testCase)

tests :: TestTree
tests =
  testGroup
    "Shiki.Cli.Runs.Sync"
    [ testCase "a terminal run is never touched, whatever the cluster says" $
        assertEqual
          "skip"
          (SkipFinished Succeeded)
          (decideSync later fixtureRow JobNotFound),
      testCase "an active Job leaves the run running" $
        assertEqual "leave" LeaveRunning (decideSync later running JobActive),
      testCase "a finished Job is recorded with the cluster's end time" $
        assertEqual
          "finalize at completion"
          (FinalizeFinished (JobFailed "BackoffLimitExceeded") jobEnded)
          (decideSync later running (JobFinished (JobFailed "BackoffLimitExceeded") (Just jobEnded))),
      testCase "a finished Job without an end time falls back to now" $
        assertEqual
          "finalize now"
          (FinalizeFinished JobSucceeded later)
          (decideSync later running (JobFinished JobSucceeded Nothing)),
      testCase "a missing Job on an old run marks it lost" $
        assertEqual "lost" MarkLost (decideSync later running JobNotFound),
      testCase "a missing Job on a just-submitted run is left alone" $
        assertEqual
          "too recent"
          SkipRecentlySubmitted
          (decideSync (addUTCTime 30 started) running JobNotFound),
      testCase "a pending run is reconciled like a running one" $
        assertEqual "lost" MarkLost (decideSync later running {status = Pending} JobNotFound)
    ]
  where
    started = case fixtureRow of RunRecord {startedAt = t} -> t
    running :: RunRecord
    running = fixtureRow {status = Running, exitCode = Nothing, durationMs = Nothing}
    jobEnded = addUTCTime 3600 started
    later = addUTCTime 7200 started
