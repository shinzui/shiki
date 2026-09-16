-- | The 'Analyzer' effect and its @Baikai@-backed interpreter, with the
--   network replaced by a canned reply.
--
--   'Baikai' is interpreted locally in each case, so these tests assert
--   shiki's policy — the model allow-list, the 512-character cap, which
--   backends reach a model at all — without a provider, an API key, or a
--   socket.
module Shiki.Effect.AnalyzerSpec (tests) where

import Baikai (Response, emptyResponse, errorResponse, providerError)
import Baikai.Content (AssistantContent (..), emptyTextContent)
import Baikai.Effectful (Baikai (..))
import Baikai.Model (emptyModel)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Text qualified as Text
import Data.Time qualified as Time
import Data.Vector qualified as V
import Effectful (Eff, IOE, runEff, type (:>))
import Effectful.Dispatch.Dynamic (interpret_)
import Effectful.Error.Static (runErrorNoCallStack)
import Shiki.Analysis.Backend (AnalyzerError (..), AnalyzerKind (..), AnalyzerResult (..))
import Shiki.Analysis.Baikai (summaryCharCap)
import Shiki.Effect.Analyzer (analyze, runAnalyzerBaikai)
import Shiki.Error (ShikiError (..))
import Shiki.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase)

tests :: TestTree
tests =
  testGroup
    "Shiki.Effect.Analyzer"
    [ testCase "an assistant reply becomes the summary, tagged with the model" $ do
        (result, calls) <- runAnalyze (textResponse "out of memory") (Baikai supportedId) "logs"
        assertEqual "the model was asked exactly once" 1 calls
        case result of
          Right res -> do
            assertEqual "summary" (Just "out of memory") (res ^. #summary)
            assertEqual "source" ("baikai:" <> supportedId) (res ^. #source)
          Left err -> assertFailure ("expected a summary, got " <> show err),
      testCase "a reply longer than the cap is truncated to it" $ do
        let long = Text.replicate (summaryCharCap * 2) "x"
        (result, _) <- runAnalyze (textResponse long) (Baikai supportedId) "logs"
        case result of
          Right res ->
            assertEqual
              "summary length"
              (Just summaryCharCap)
              (Text.length <$> (res ^. #summary))
          Left err -> assertFailure ("expected a summary, got " <> show err),
      testCase "an error-shaped reply becomes ShikiAnalyzerError" $ do
        (result, calls) <- runAnalyze providerFailure (Baikai supportedId) "logs"
        assertEqual "the model was asked" 1 calls
        case result of
          Left (ShikiAnalyzerError (AnalyzerBaikaiError message)) ->
            assertBool
              ("the provider's message survives: " <> Text.unpack message)
              ("no API key" `Text.isInfixOf` message)
          other -> assertFailure ("expected AnalyzerBaikaiError, got " <> show other),
      testCase "an unknown model id fails without invoking Baikai" $ do
        (result, calls) <- runAnalyze (textResponse "unused") (Baikai "no-such-model") "logs"
        assertEqual "no request was made" 0 calls
        case result of
          Left (ShikiAnalyzerError (AnalyzerUnknown message)) ->
            assertEqual
              "the message echoes what the operator typed"
              "baikai:no-such-model"
              message
          other -> assertFailure ("expected AnalyzerUnknown, got " <> show other),
      testCase "Heuristic summarizes in process, without invoking Baikai" $ do
        let logs =
              Text.unlines
                [ "Traceback (most recent call last):",
                  "  File \"/app/main.py\", line 1, in <module>",
                  "    raise RuntimeError('boom')",
                  "RuntimeError: boom"
                ]
        (result, calls) <- runAnalyze (textResponse "unused") Heuristic logs
        assertEqual "no request was made" 0 calls
        case result of
          Right res -> do
            assertEqual "source" "heuristic" (res ^. #source)
            assertEqual "summary" (Just "RuntimeError: boom") (res ^. #summary)
          Left err -> assertFailure ("expected a summary, got " <> show err),
      testCase "None is a typed refusal, not a request" $ do
        (result, calls) <- runAnalyze (textResponse "unused") None "logs"
        assertEqual "no request was made" 0 calls
        case result of
          Left (ShikiAnalyzerError AnalyzerBackendDisabled) -> pure ()
          other -> assertFailure ("expected AnalyzerBackendDisabled, got " <> show other)
    ]

-- | One of the ids shiki's allow-list accepts.
supportedId :: Text
supportedId = "anthropic_claude_haiku_4_5"

-- | Run one 'analyze' call against a canned reply, and report how many times
--   the 'Baikai' effect was actually reached.
runAnalyze ::
  Response ->
  AnalyzerKind ->
  Text ->
  IO (Either ShikiError AnalyzerResult, Int)
runAnalyze canned kind input = do
  calls <- newIORef (0 :: Int)
  result <-
    runEff
      . runErrorNoCallStack @ShikiError
      . runCannedBaikai calls canned
      . runAnalyzerBaikai
      $ analyze kind input
  (result,) <$> readIORef calls

-- | Interpret 'Baikai' with a fixed reply, counting the requests made.
runCannedBaikai ::
  (IOE :> es) =>
  IORef Int ->
  Response ->
  Eff (Baikai : es) a ->
  Eff es a
runCannedBaikai calls canned = interpret_ $ \case
  Complete {} -> do
    liftIO (readIORef calls >>= \n -> writeIORef calls (n + 1))
    pure canned
  StreamCollect {} -> pure []
  StreamEach {} -> pure ()

textResponse :: Text -> Response
textResponse t =
  emptyResponse
    & #message
    . #content
    .~ V.singleton (AssistantText (emptyTextContent & #text .~ t))

providerFailure :: Response
providerFailure =
  errorResponse emptyModel epoch 0 (providerError "no API key configured")

epoch :: UTCTime
epoch = Time.UTCTime (Time.fromGregorian 2026 5 27) 0
