-- | The pluggable analyzer surface: an 'AnalyzerKind' selects which
--   backend produces the failure summary, and 'runAnalyzer' dispatches
--   to the matching implementation. The deterministic in-process
--   'Heuristic' branch is the default; the 'Baikai' branch is wired up
--   in M7 (it returns a placeholder 'AnalyzerBaikaiError' until then).
module Shiki.Analysis.Backend
  ( AnalyzerKind (..)
  , AnalyzerResult (..)
  , AnalyzerError (..)
  , summaryByteCap
  , runAnalyzer
  ) where

import Shiki.Prelude

import Shiki.Analysis.Heuristic (summarizeFailure)

-- | Which backend produces the summary. Carries the model id for the
--   'Baikai' variant so dispatch is purely value-driven.
data AnalyzerKind
  = Heuristic
  | Baikai !Text
  | None
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

-- | The summary text plus its provenance tag (e.g. @\"heuristic\"@ or
--   @\"baikai:anthropic_claude_haiku_4_5\"@), packaged so callers do not
--   have to derive the tag string from 'AnalyzerKind' themselves.
data AnalyzerResult = AnalyzerResult
  { summary :: !(Maybe Text)
  , source  :: !Text
  }
  deriving stock (Generic, Eq, Show)

-- | Why an analyzer call failed.
data AnalyzerError
  = AnalyzerBackendDisabled
    -- ^ the caller asked for 'None'; no work was attempted
  | AnalyzerUnknown !Text
    -- ^ a CLI override could not be parsed into an 'AnalyzerKind'
  | AnalyzerBaikaiError !Text
    -- ^ the 'Baikai' branch failed; the wrapped 'Text' is a human-readable
    --   rendering of the underlying error
  deriving stock (Generic, Eq, Show)

-- | Maximum number of characters the analyzer is allowed to emit. The
--   heuristic and the Baikai backend both enforce this cap before
--   returning.
summaryByteCap :: Int
summaryByteCap = 512

-- | Dispatch a chunk of analysis-buffer text through the chosen backend.
--   The 'Baikai' branch is stubbed in M2 and gets a real implementation
--   in M7.
runAnalyzer :: AnalyzerKind -> Text -> IO (Either AnalyzerError AnalyzerResult)
runAnalyzer kind input = case kind of
  Heuristic ->
    pure
      ( Right
          AnalyzerResult
            { summary = summarizeFailure input
            , source  = "heuristic"
            }
      )
  Baikai _ ->
    pure (Left (AnalyzerBaikaiError "backend not yet wired (M7)"))
  None ->
    pure (Left AnalyzerBackendDisabled)
