module Shiki.Cli.HeartbeatSpec (tests) where

import Control.Concurrent (newEmptyMVar, putMVar, readMVar, threadDelay)
import Control.Exception (SomeException, throwIO, try)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.List (isInfixOf)
import Shiki.Cli.Heartbeat (withHeartbeat)
import Shiki.Prelude
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase)

tests :: TestTree
tests =
  testGroup
    "Shiki.Cli.Heartbeat"
    [ testCase "beats immediately and stops before returning" $ do
        count <- newIORef (0 :: Int)
        thirdBeat <- newEmptyMVar
        let beat = do
              n <- atomicModifyIORef' count (\n -> let next = n + 1 in (next, next))
              when (n == 3) (putMVar thirdBeat ())
        completed <-
          timeout testTimeout $
            withHeartbeat testInterval beat $ do
              initial <- readIORef count
              assertBool "the first beat precedes the body" (initial >= 1)
              readMVar thirdBeat
        assertEqual "body completed before timeout" (Just ()) completed
        countAtReturn <- readIORef count
        threadDelay (testInterval * 5)
        assertEqual "no beat after return" countAtReturn =<< readIORef count,
      testCase "synchronous beat failures are ignored and later beats continue" $ do
        count <- newIORef (0 :: Int)
        thirdBeat <- newEmptyMVar
        let beat = do
              n <- atomicModifyIORef' count (\n -> let next = n + 1 in (next, next))
              when (n == 3) (putMVar thirdBeat ())
              throwIO (userError "heartbeat unavailable")
        completed <- timeout testTimeout (withHeartbeat testInterval beat (readMVar thirdBeat))
        assertEqual "body still completes" (Just ()) completed
        finalCount <- readIORef count
        assertBool "a failed beat did not stop later attempts" (finalCount >= 3),
      testCase "a body exception propagates and still stops the heartbeat" $ do
        count <- newIORef (0 :: Int)
        let beat = atomicModifyIORef' count (\n -> (n + 1, ()))
        result <-
          try @SomeException $
            withHeartbeat testInterval beat $ do
              initial <- readIORef count
              assertBool "the first beat precedes the body" (initial >= 1)
              throwIO (userError "body failed")
        case result of
          Left e -> assertBool "body exception propagated" ("body failed" `isInfixOf` show e)
          Right () -> assertFailure "expected body exception"
        countAtReturn <- readIORef count
        threadDelay (testInterval * 5)
        assertEqual "no beat after exceptional return" countAtReturn =<< readIORef count
    ]

testInterval :: Int
testInterval = 1_000

testTimeout :: Int
testTimeout = 5_000_000
