module Shiki.Cli.HeartbeatSpec (tests) where

import Control.Concurrent (newEmptyMVar, putMVar, readMVar, threadDelay)
import Control.Exception (SomeException, throwIO, try)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.List (isInfixOf)
import Effectful (Eff, IOE, runEff)
import Effectful.Concurrent (Concurrent, runConcurrent)
import Effectful.Error.Static (Error, runErrorNoCallStack, throwError)
import Shiki.Cli.Heartbeat (withHeartbeat)
import Shiki.Error (ConfigError (..), ShikiError (..))
import Shiki.Prelude
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase)

-- | 'withHeartbeat' now lives in @Eff@, so each case runs through the same
--   three handlers a command does: 'IOE' for the terminal, 'Concurrent' for
--   the child thread that beats, and a typed 'ShikiError' handler standing in
--   for the store's.
runHeartbeat :: Eff '[Error ShikiError, Concurrent, IOE] a -> IO (Either ShikiError a)
runHeartbeat = runEff . runConcurrent . runErrorNoCallStack @ShikiError

tests :: TestTree
tests =
  testGroup
    "Shiki.Cli.Heartbeat"
    [ testCase "beats immediately and stops before returning" $ do
        count <- newIORef (0 :: Int)
        thirdBeat <- newEmptyMVar
        let beat = liftIO $ do
              n <- atomicModifyIORef' count (\n -> let next = n + 1 in (next, next))
              when (n == 3) (putMVar thirdBeat ())
        completed <-
          timeout testTimeout . runHeartbeat $
            withHeartbeat testInterval beat $
              liftIO $ do
                initial <- readIORef count
                assertBool "the first beat precedes the body" (initial >= 1)
                readMVar thirdBeat
        assertEqual "body completed before timeout" (Just (Right ())) completed
        countAtReturn <- readIORef count
        threadDelay (testInterval * 5)
        assertEqual "no beat after return" countAtReturn =<< readIORef count,
      testCase "synchronous beat failures are ignored and later beats continue" $ do
        count <- newIORef (0 :: Int)
        thirdBeat <- newEmptyMVar
        let beat = do
              liftIO $ do
                n <- atomicModifyIORef' count (\n -> let next = n + 1 in (next, next))
                when (n == 3) (putMVar thirdBeat ())
              liftIO (throwIO (userError "heartbeat unavailable"))
        completed <-
          timeout testTimeout . runHeartbeat $
            withHeartbeat testInterval beat (liftIO (readMVar thirdBeat))
        assertEqual "body still completes" (Just (Right ())) completed
        finalCount <- readIORef count
        assertBool "a failed beat did not stop later attempts" (finalCount >= 3),
      testCase "typed store failures in a beat are ignored too" $ do
        count <- newIORef (0 :: Int)
        thirdBeat <- newEmptyMVar
        let beat = do
              liftIO $ do
                n <- atomicModifyIORef' count (\n -> let next = n + 1 in (next, next))
                when (n == 3) (putMVar thirdBeat ())
              throwError (ShikiConfigError NoConnectionString)
        completed <-
          timeout testTimeout . runHeartbeat $
            withHeartbeat testInterval beat (liftIO (readMVar thirdBeat))
        assertEqual "the typed error did not end the run" (Just (Right ())) completed
        finalCount <- readIORef count
        assertBool "a failed beat did not stop later attempts" (finalCount >= 3),
      testCase "a body exception propagates and still stops the heartbeat" $ do
        count <- newIORef (0 :: Int)
        let beat = liftIO (atomicModifyIORef' count (\n -> (n + 1, ())))
        result <-
          try @SomeException . runHeartbeat $
            withHeartbeat testInterval beat $
              liftIO $ do
                initial <- readIORef count
                assertBool "the first beat precedes the body" (initial >= 1)
                throwIO (userError "body failed")
        case result of
          Left e -> assertBool "body exception propagated" ("body failed" `isInfixOf` show e)
          Right _ -> assertFailure "expected body exception"
        countAtReturn <- readIORef count
        threadDelay (testInterval * 5)
        assertEqual "no beat after exceptional return" countAtReturn =<< readIORef count
    ]

testInterval :: Int
testInterval = 1_000

testTimeout :: Int
testTimeout = 5_000_000
