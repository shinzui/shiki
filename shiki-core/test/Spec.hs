module Main (main) where

import Shiki.Persistence.RunSpec qualified as RunSpec
import Shiki.Service.ConfigSpec qualified as ConfigSpec

import "tasty" Test.Tasty (defaultMain, testGroup)

main :: IO ()
main =
  defaultMain $
    testGroup "shiki-core"
      [ ConfigSpec.tests
      , RunSpec.tests
      ]
