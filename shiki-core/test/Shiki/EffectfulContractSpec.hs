{-# LANGUAGE TypeFamilies #-}

-- | Pins down the @effectful@ and GHC exception behaviour that shiki's
--   top-level error handler and heartbeat depend on.
--
--   None of these facts belong to shiki: they are properties of
--   @effectful-core@ 2.7, @effectful@ 2.7, and GHC 9.12. They are asserted
--   here so that a library upgrade which changes one of them fails the test
--   suite instead of silently changing how shiki reports failures.
module Shiki.EffectfulContractSpec (tests) where

import Control.Exception qualified as E
import Control.Monad.IO.Class (liftIO)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.List (isInfixOf)
import Data.Text (Text)
import Effectful (Dispatch (Dynamic), DispatchOf, Eff, Effect, IOE, runEff, type (:>))
import Effectful.Concurrent (Concurrent, runConcurrent, threadDelay)
import Effectful.Concurrent.Async (wait, withAsync)
import Effectful.Dispatch.Dynamic (interpret_, send)
import Effectful.Error.Static (runErrorNoCallStack, throwError)
import Effectful.Exception qualified as Exc
import System.Exit (ExitCode (ExitFailure), exitWith)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase)

-- | A minimal dynamic effect shaped like the heartbeat's use of @RunStore@:
--   one first-order operation, interpreted over an 'IORef'.
data Counter :: Effect where
  Tick :: Counter m ()

type instance DispatchOf Counter = Dynamic

tick :: (Counter :> es) => Eff es ()
tick = send Tick

runCounterIORef :: (IOE :> es) => IORef Int -> Eff (Counter : es) a -> Eff es a
runCounterIORef ref = interpret_ $ \case
  Tick -> liftIO (atomicModifyIORef' ref (\n -> (n + 1, ())))

tests :: TestTree
tests =
  testGroup
    "Shiki.EffectfulContract"
    [ testCase "trySync lets a typed error through" $ do
        result <-
          runEff . runErrorNoCallStack @Text $
            Exc.trySync (throwError @Text "x")
        case result of
          Left err -> assertEqual "the typed error reached its handler" "x" err
          Right (Left _) -> assertFailure "trySync swallowed the typed error"
          Right (Right ()) -> assertFailure "the throwError did not happen",
      testCase "trySync catches ExitCode" $ do
        result <- runEff (Exc.trySync (liftIO (exitWith (ExitFailure 3) :: IO ())))
        case result of
          Left ex ->
            assertEqual
              "the caught exception is the ExitCode"
              (Just (ExitFailure 3))
              (E.fromException ex)
          Right () -> assertFailure "trySync did not catch exitWith",
      testCase "trySync does not catch UserInterrupt" $ do
        outer <-
          E.try @E.AsyncException $
            runEff (Exc.trySync (liftIO (E.throwIO E.UserInterrupt)))
        case outer of
          Left E.UserInterrupt -> pure ()
          Left other -> assertFailure ("unexpected async exception: " <> show other)
          Right _ -> assertFailure "trySync swallowed UserInterrupt",
      testCase "bracket cleanup runs under throwError" $ do
        ref <- newIORef False
        result <-
          runEff . runErrorNoCallStack @Text $
            Exc.bracket
              (pure ())
              (\_ -> liftIO (writeIORef ref True))
              (\_ -> throwError @Text "x")
        assertEqual "the error escaped to its handler" (Left "x" :: Either Text ()) result
        released <- readIORef ref
        assertBool "the release action ran" released,
      testCase "a dynamic effect works inside withAsync" $ do
        ref <- newIORef (0 :: Int)
        runEff . runConcurrent . runCounterIORef ref $
          withAsync
            (let loop = tick >> threadDelay 1000 >> loop in loop)
            (\_ -> waitForCount ref 3)
        count <- readIORef ref
        assertBool ("the child ticked (count = " <> show count <> ")") (count >= 3),
      testCase "throwError in a withAsync child reaches wait" $ do
        result <-
          runEff . runConcurrent . runErrorNoCallStack @Text $
            withAsync (throwError @Text "from the child") wait
        assertEqual
          "wait re-raised the child's typed error"
          (Left "from the child" :: Either Text ())
          result,
      testCase "displayException has no backtrace" $ do
        caught <- E.try @E.SomeException (E.evaluate (error "boom" :: ()))
        case caught of
          Right () -> assertFailure "error did not throw"
          Left ex -> do
            let shown = E.displayException ex
            assertEqual "displayException is just the message" "boom" shown
            assertBool
              "displayException carries no HasCallStack backtrace"
              (not ("HasCallStack" `isInfixOf` shown))
    ]

-- | Spin until the counter reaches @target@, so the assertion does not depend
--   on wall-clock timing. Gives up after two seconds so a broken interpreter
--   fails the assertion instead of hanging the suite.
waitForCount :: (Concurrent :> es, IOE :> es) => IORef Int -> Int -> Eff es ()
waitForCount ref target = go (0 :: Int)
  where
    go n
      | n > 2000 = pure ()
      | otherwise = do
          count <- liftIO (readIORef ref)
          if count >= target
            then pure ()
            else threadDelay 1000 >> go (n + 1)
