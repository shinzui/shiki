module Shiki.Cli.Fzf.Selector.ServiceSpec
  ( tests,
  )
where

import Data.Generics.Labels ()
import Shiki.Cli.Fzf (FzfConfig (..), FzfResult (..))
import Shiki.Cli.Fzf.Selector.Service
  ( ServiceLookupFailure (..),
    ServiceTarget (..),
    fromServiceFzfResult,
    listServiceNames,
    pickerServiceTarget,
    renderServiceLookupFailure,
    serviceOpts,
  )
import Shiki.Prelude ((^.))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase)

tests :: TestTree
tests =
  testGroup
    "Shiki.Cli.Fzf.Selector.Service"
    [ testCase "fromServiceFzfResult maps each fzf outcome" $ do
        assertEqual "selected" (Right "ingest") (fromServiceFzfResult (FzfSelected "ingest"))
        assertEqual "cancelled" (Left ServicePickerCancelled) (fromServiceFzfResult FzfCancelled)
        assertEqual "error" (Left (ServicePickerFailed "boom")) (fromServiceFzfResult (FzfError "boom")),
      -- Regression: a query matching nothing used to be reported as no configs.
      testCase "a picker query matching nothing is ServicePickerNoMatch" $
        assertEqual "no match" (Left ServicePickerNoMatch) (fromServiceFzfResult FzfNoMatch),
      testCase "renderServiceLookupFailure messages" $
        assertEqual
          "messages"
          [ Just "shiki: no service configs found in services/",
            Just "shiki: no service matches the picker query",
            Nothing,
            Just "shiki: no service name given and fzf is not available",
            Just "shiki: fzf: boom"
          ]
          ( map
              renderServiceLookupFailure
              [ NoServiceConfigs,
                ServicePickerNoMatch,
                ServicePickerCancelled,
                ServiceFzfUnavailable,
                ServicePickerFailed "boom"
              ]
          ),
      testCase "pickerServiceTarget needs a usable fzf" $ do
        let cfg a t = FzfConfig {binary = "fzf", available = a, ttyAvailable = t}
            isPicker = \case
              Right (ServiceByPicker _) -> True
              _ -> False
            isUnavailable = \case
              Left ServiceFzfUnavailable -> True
              _ -> False
        assertBool "available" (isPicker (pickerServiceTarget (cfg True True)))
        assertBool
          "unavailable"
          (all (isUnavailable . pickerServiceTarget) [cfg True False, cfg False True, cfg False False]),
      testCase "the service picker auto-selects a lone config" $
        assertBool "selectOne" (serviceOpts ^. #selectOne),
      testCase "listServiceNames keeps sorted .dhall basenames" $
        withSystemTempDirectory "services" $ \dir -> do
          mapM_ (\f -> writeFile (dir </> f) "") ["b.dhall", "a.dhall", "notes.txt"]
          names <- listServiceNames dir
          assertEqual "names" ["a", "b"] names,
      testCase "listServiceNames on a missing directory is empty" $
        withSystemTempDirectory "services" $ \dir -> do
          names <- listServiceNames (dir </> "missing")
          assertEqual "names" [] names
    ]
