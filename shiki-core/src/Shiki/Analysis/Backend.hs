-- | The vocabulary of shiki's analyzer: which backend produces a failure
--   summary, what a summary looks like, and how analysis can fail.
--
--   Dispatch itself lives in "Shiki.Effect.Analyzer", so this module stays
--   free of IO and of baikai; the two are separate because
--   "Shiki.Service.Config" needs the vocabulary and nothing else.
module Shiki.Analysis.Backend
  ( AnalyzerKind (..),
    AnalyzerResult (..),
    AnalyzerError (..),
    summaryByteCap,
    analyzerBackendToKind,
  )
where

import Shiki.Prelude
import Shiki.Service.Config qualified as Cfg

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
  { summary :: !(Maybe Text),
    source :: !Text
  }
  deriving stock (Generic, Eq, Show)

-- | Why an analyzer call failed.
data AnalyzerError
  = -- | the caller asked for 'None'; no work was attempted
    AnalyzerBackendDisabled
  | -- | a CLI override could not be parsed into an 'AnalyzerKind'
    AnalyzerUnknown !Text
  | -- | the 'Baikai' branch failed; the wrapped 'Text' is a human-readable
    --   rendering of the underlying error
    AnalyzerBaikaiError !Text
  deriving stock (Generic, Eq, Show)

-- | Maximum number of characters the analyzer is allowed to emit. The
--   heuristic and the Baikai backend both enforce this cap before
--   returning.
summaryByteCap :: Int
summaryByteCap = 512

-- | Bridge the Dhall-facing 'Shiki.Service.Config.AnalyzerBackend' type
--   to the dispatch-facing 'AnalyzerKind'. The two types are kept
--   separate so "Shiki.Service.Config" does not depend on the analysis
--   module; this function is the canonical conversion.
analyzerBackendToKind :: Cfg.AnalyzerBackend -> AnalyzerKind
analyzerBackendToKind = \case
  Cfg.Heuristic -> Heuristic
  Cfg.Baikai {Cfg.model = m} -> Baikai m
  Cfg.None -> None
