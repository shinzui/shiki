{-# LANGUAGE TypeFamilies #-}

-- | Summarizing a failed run's logs, as one effect.
--
--   One operation, 'Analyze', holds all of shiki's policy: which backends
--   exist, which model ids it will talk to, the system prompt, the 256-token
--   request cap, and the 512-character cap on the summary it stores. A caller
--   asks for a summary and gets one; it does not know whether the answer came
--   from a regular expression or from a language model.
--
--   The production interpreter is written in terms of @baikai-effectful@'s
--   @Baikai@ effect, the same way the 'Shiki.Effect.RunStore.RunStore'
--   interpreter is written in terms of hasql: shiki's effect hides the backend
--   from commands, and the library's own effect is how the interpreter reaches
--   it. A test interprets @Baikai@ with a canned reply and never opens a
--   socket.
module Shiki.Effect.Analyzer
  ( Analyzer (..),
    analyze,
    runAnalyzerBaikai,
  )
where

import Baikai (responseError)
import Baikai.Effectful (Baikai, complete)
import Data.Text qualified as Text
import Effectful (Dispatch (Dynamic), DispatchOf, Eff, Effect, type (:>))
import Effectful.Dispatch.Dynamic (interpret_, send)
import Effectful.Error.Static (Error, throwError)
import Effectful.Exception qualified as Exc
import Shiki.Analysis.Backend
  ( AnalyzerError (..),
    AnalyzerKind (..),
    AnalyzerResult (..),
  )
import Shiki.Analysis.Baikai
  ( analyzerContext,
    analyzerOptions,
    capChars,
    extractText,
    lookupModel,
    renderError,
  )
import Shiki.Analysis.Heuristic (summarizeFailure)
import Shiki.Error (ShikiError (..))
import Shiki.Prelude

data Analyzer :: Effect where
  -- | which backend, and the log text to summarize
  Analyze :: AnalyzerKind -> Text -> Analyzer m AnalyzerResult

type instance DispatchOf Analyzer = Dynamic

analyze :: (Analyzer :> es) => AnalyzerKind -> Text -> Eff es AnalyzerResult
analyze kind input = send (Analyze kind input)

-- | 'Heuristic' and 'None' are answered here; a 'Baikai' model goes out
--   through the 'Baikai' effect. Every failure becomes 'ShikiAnalyzerError',
--   including a transport exception — @complete@ reports provider failures
--   in-band, but a socket that dies mid-request still throws, and that must
--   read as a baikai failure rather than as the handler's "unexpected error"
--   fallback.
runAnalyzerBaikai ::
  (Baikai :> es, Error ShikiError :> es) =>
  Eff (Analyzer : es) a ->
  Eff es a
runAnalyzerBaikai = interpret_ $ \case
  Analyze Heuristic input ->
    pure AnalyzerResult {summary = summarizeFailure input, source = "heuristic"}
  Analyze None _ -> failWith AnalyzerBackendDisabled
  Analyze (Baikai modelId) input -> case lookupModel modelId of
    -- Unknown ids fail before any request: the allow-list exists so a typo in
    -- --analyzer cannot silently reach a model the operator did not name.
    Nothing -> failWith (AnalyzerUnknown ("baikai:" <> modelId))
    Just model ->
      Exc.trySync (complete model (analyzerContext input) analyzerOptions) >>= \case
        Left e -> failWith (AnalyzerBaikaiError (Text.pack (Exc.displayException e)))
        Right response -> case responseError response of
          Just err -> failWith (AnalyzerBaikaiError (renderError err))
          Nothing ->
            pure
              AnalyzerResult
                { summary = Just (capChars (extractText response)),
                  source = "baikai:" <> modelId
                }
  where
    failWith = throwError . ShikiAnalyzerError
