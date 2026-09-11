module Shiki.Persistence.SchemaSpec (tests) where

import Data.Text qualified as Text
import Shiki.Persistence.Schema
  ( defaultSchema,
    mkSchema,
    quoteSchema,
    schemaText,
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertEqual, testCase)

tests :: TestTree
tests =
  testGroup
    "Shiki.Persistence.Schema"
    [ testCase "defaultSchema is shiki" $
        assertEqual "" "shiki" (schemaText defaultSchema),
      testCase "quoteSchema wraps in double quotes" $
        assertEqual "" "\"shiki\"" (quoteSchema defaultSchema),
      testCase "accepts plain identifiers" $ do
        accept "shiki"
        accept "Shiki"
        accept "_private"
        accept "shiki_test_42"
        accept (Text.replicate 63 "a"),
      testCase "rejects empty / leading-digit / long / illegal" $ do
        reject ""
        reject "1shiki"
        reject "shiki-staging"
        reject "shiki staging"
        reject "shiki;DROP"
        reject "shiki\""
        reject (Text.replicate 64 "a")
    ]
  where
    accept t = case mkSchema t of
      Right s -> assertEqual "round-trips" t (schemaText s)
      Left e -> fail ("expected " <> show t <> " to validate but got: " <> show e)
    reject t = case mkSchema t of
      Left _ -> pure ()
      Right s -> fail ("expected " <> show t <> " to fail but got: " <> show (schemaText s))
