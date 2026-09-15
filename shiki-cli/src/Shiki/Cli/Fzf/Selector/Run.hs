-- | Resolve a single run from either a typed id prefix or an @fzf@ picker.
--
--   Resolution happens in two phases. 'runTarget' decides what the operator
--   asked for — a prefix, or the picker — before any database work, so a
--   missing fzf is reported without connecting. 'lookupRun' then turns the
--   target into the 'RunRecord' inside the database environment: the prefix
--   path is the only one that queries by id, and the picker path returns the
--   record fzf handed back. Every way this can fail is a 'RunLookupFailure',
--   rendered in one place by 'renderRunLookupFailure'.
--
--   The picker shows the 50 most-recent rows aligned under the same column
--   titles @runs list@ uses ("Shiki.Cli.Runs.Format").
module Shiki.Cli.Fzf.Selector.Run
  ( RunTarget (..),
    RunLookupFailure (..),
    readRunOpts,
    analyzeRunOpts,
    formatRunCandidates,
    runTarget,
    pickerRunTarget,
    lookupRun,
    fromPrefixMatches,
    fromRunFzfResult,
    renderRunLookupFailure,
  )
where

import Data.Bifunctor (first)
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (Statement)
import Shiki.Cli.Env (CliEnv (..))
import Shiki.Cli.Fzf
  ( Candidate (..),
    FzfConfig,
    FzfOpts,
    FzfResult (..),
    detectFzfConfig,
    isFzfAvailable,
    runFzf,
    withHeader,
    withHeaderRow,
    withHeight,
    withNoSort,
    withPrompt,
    withSelectOne,
  )
import Shiki.Cli.Runs.Format (computeWidths, formatRow, runColumns, runTableHeader)
import Shiki.Persistence.Run
  ( RunRecord,
    findRunByPrefixStatement,
    listRecentRunsStatement,
  )
import Shiki.Prelude

-- | What the operator asked for, decided before any database work.
data RunTarget
  = RunByPrefix !Text
  | RunByPicker !FzfConfig !FzfOpts

-- | Every way turning a target into a run can fail.
data RunLookupFailure
  = NoRunMatching !Text
  | AmbiguousRunPrefix !Text
  | NoRunsRecorded
  | RunPickerNoMatch
  | RunPickerCancelled
  | RunFzfUnavailable
  | RunPickerFailed !Text
  | RunLookupPersistenceError !Text
  deriving stock (Eq, Show)

-- | How many rows to surface in the picker. 50 is bigger than the 20
--   default of @runs list@ because fuzzy search is more useful with
--   more candidates; 50 still fits in a 40%-height pane on a typical
--   terminal.
selectorRowLimit :: Int
selectorRowLimit = 50

-- | @run> @ prompt, 40% height, sort disabled (we pre-sort by recency).
pickerBaseOpts :: FzfOpts
pickerBaseOpts = withPrompt "run> " <> withHeight "40%" <> withNoSort

-- | For show / logs / error: a lone run is picked without asking.
readRunOpts :: FzfOpts
readRunOpts = pickerBaseOpts <> withSelectOne

-- | For analyze, which writes: always ask, and say what Enter does.
analyzeRunOpts :: FzfOpts
analyzeRunOpts =
  pickerBaseOpts
    <> withHeader "Enter re-runs analysis on the selected run and overwrites its stored error summary"

-- | Align the picker rows exactly like @runs list@: the widths are computed
--   over the column titles and every row, and the titles are returned so the
--   caller can show them with 'withHeaderRow'.
formatRunCandidates :: UTCTime -> [RunRecord] -> (Text, [Candidate RunRecord])
formatRunCandidates observedAt rows =
  let cells = map (runColumns observedAt) rows
      widths = computeWidths (runTableHeader : cells)
   in ( formatRow widths runTableHeader,
        zipWith (\r cs -> Candidate {display = formatRow widths cs, value = r}) rows cells
      )

-- | Decide the target. Probes for fzf only when no positional was given.
runTarget :: FzfOpts -> Maybe Text -> IO (Either RunLookupFailure RunTarget)
runTarget _ (Just t) = pure (Right (RunByPrefix t))
runTarget opts Nothing = pickerRunTarget opts <$> detectFzfConfig

-- | The picker target, or 'RunFzfUnavailable' when fzf cannot run.
pickerRunTarget :: FzfOpts -> FzfConfig -> Either RunLookupFailure RunTarget
pickerRunTarget opts cfg
  | isFzfAvailable cfg = Right (RunByPicker cfg opts)
  | otherwise = Left RunFzfUnavailable

-- | Resolve a target to a run. The prefix path is the only one that queries
--   by id; the picker path returns the record fzf handed back.
lookupRun :: CliEnv -> UTCTime -> RunTarget -> IO (Either RunLookupFailure RunRecord)
lookupRun env observedAt = \case
  RunByPrefix t ->
    query findRunByPrefixStatement t <&> (>>= fromPrefixMatches t)
  RunByPicker cfg opts ->
    query listRecentRunsStatement selectorRowLimit >>= \case
      Left e -> pure (Left e)
      Right [] -> pure (Left NoRunsRecorded)
      Right rows -> do
        let (titles, candidates) = formatRunCandidates observedAt rows
        fromRunFzfResult <$> runFzf cfg (opts <> withHeaderRow titles) candidates
  where
    query :: Statement a b -> a -> IO (Either RunLookupFailure b)
    query stmt input =
      first (RunLookupPersistenceError . Text.pack . show)
        <$> Pool.use (env ^. #pool) (Session.statement input stmt)

-- | 'findRunByPrefixStatement' returns at most two rows: enough to tell a
--   unique prefix from an ambiguous one.
fromPrefixMatches :: Text -> [RunRecord] -> Either RunLookupFailure RunRecord
fromPrefixMatches t = \case
  [] -> Left (NoRunMatching t)
  [r] -> Right r
  _ -> Left (AmbiguousRunPrefix t)

fromRunFzfResult :: FzfResult RunRecord -> Either RunLookupFailure RunRecord
fromRunFzfResult = \case
  FzfSelected r -> Right r
  FzfNoMatch -> Left RunPickerNoMatch
  FzfCancelled -> Left RunPickerCancelled
  FzfError e -> Left (RunPickerFailed e)

-- | The message for a failure, or 'Nothing' for a silent cancel. The caller
--   prints it on stderr and exits 1.
renderRunLookupFailure :: RunLookupFailure -> Maybe Text
renderRunLookupFailure = \case
  NoRunMatching t -> Just ("no run matching " <> t)
  AmbiguousRunPrefix t -> Just ("ambiguous id prefix " <> t)
  NoRunsRecorded -> Just "shiki: no runs recorded yet"
  RunPickerNoMatch -> Just "shiki: no run matches the picker query"
  RunPickerCancelled -> Nothing
  RunFzfUnavailable -> Just "shiki: no run id given and fzf is not available"
  RunPickerFailed e -> Just ("shiki: fzf: " <> e)
  RunLookupPersistenceError e -> Just ("shiki: persistence error: " <> e)
