-- | Selector that lets the operator pick a single run row via @fzf@.
--
--   This is the bridge between the abstract 'Shiki.Cli.Fzf.runFzf' and
--   the concrete @runs@ table: it fetches the 50 most-recent rows,
--   aligns them under the same column titles @runs list@ uses, runs
--   them through fzf, and returns either a full UUID (as 'Text', so the
--   existing handlers can keep using 'findRunByPrefixStatement') or one
--   of the non-selection outcomes.
module Shiki.Cli.Fzf.Selector.Run
  ( RunSelection (..),
    defaultRunOpts,
    formatRunCandidates,
    selectRun,
    resolveRunId,
  )
where

import Data.Generics.Labels ()
import Data.Text qualified as Text
import Data.Text.IO qualified as TIO
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Shiki.Cli.Env (CliEnv (..))
import Shiki.Cli.Fzf
  ( Candidate (..),
    FzfOpts,
    FzfResult (..),
    isFzfAvailable,
    runFzf,
    withHeaderRow,
    withHeight,
    withNoSort,
    withPrompt,
    withSelectOne,
  )
import Shiki.Cli.Runs.Format (computeWidths, formatRow, runColumns, runTableHeader)
import Shiki.Persistence.Run
  ( RunId (..),
    RunRecord,
    listRecentRunsStatement,
  )
import Shiki.Prelude
import System.IO (hPutStrLn, stderr)

-- | The four states 'selectRun' can land in.
data RunSelection
  = RunChosen !RunId !RunRecord
  | RunNoRows
  | RunSelectionCancelled
  | RunFzfUnavailable
  | RunSelectionError !Text

-- | The default fzf options for run pickers: @run> @ prompt, 40% height,
--   sort disabled (we pre-sort by recency), a lone run picked without
--   asking.
defaultRunOpts :: FzfOpts
defaultRunOpts =
  withPrompt "run> " <> withHeight "40%" <> withNoSort <> withSelectOne

-- | How many rows to surface in the picker. 50 is bigger than the 20
--   default of @runs list@ because fuzzy search is more useful with
--   more candidates; 50 still fits in a 40%-height pane on a typical
--   terminal.
selectorRowLimit :: Int
selectorRowLimit = 50

-- | Align the picker rows exactly like @runs list@: the widths are computed
--   over the column titles and every row, and the titles are returned so the
--   caller can show them with 'withHeaderRow'.
formatRunCandidates :: [RunRecord] -> (Text, [Candidate RunRecord])
formatRunCandidates rows =
  let cells = map runColumns rows
      widths = computeWidths (runTableHeader : cells)
   in ( formatRow widths runTableHeader,
        zipWith (\r cs -> Candidate {display = formatRow widths cs, value = r}) rows cells
      )

-- | Fetch the 50 most-recent rows from the @runs@ table and run them
--   through fzf with 'defaultRunOpts'.
selectRun :: CliEnv -> IO RunSelection
selectRun env
  | not (isFzfAvailable (env ^. #fzf)) = pure RunFzfUnavailable
  | otherwise = do
      eRows <-
        Pool.use
          (env ^. #pool)
          (Session.statement selectorRowLimit listRecentRunsStatement)
      case eRows of
        Left e ->
          pure (RunSelectionError (Text.pack ("persistence error: " <> show e)))
        Right [] -> pure RunNoRows
        Right rows -> do
          let (titles, candidates) = formatRunCandidates rows
          res <- runFzf (env ^. #fzf) (defaultRunOpts <> withHeaderRow titles) candidates
          pure $ case res of
            FzfSelected r -> RunChosen (r ^. #runId) r
            FzfNoMatch -> RunNoRows
            FzfCancelled -> RunSelectionCancelled
            FzfError msg -> RunSelectionError msg

-- | The public entry point used by the @runs@ subcommand handlers.
--   Returns the run id as 'Text' (the same shape the existing
--   'findRunByPrefixStatement' path consumes); a 'Nothing' means the
--   caller should exit non-zero (any user-visible message has already
--   been printed).
resolveRunId :: CliEnv -> Maybe Text -> IO (Maybe Text)
resolveRunId _ (Just t) = pure (Just t)
resolveRunId env Nothing
  | not (isFzfAvailable (env ^. #fzf)) = do
      hPutStrLn stderr "shiki: no run id given and fzf is not available"
      pure Nothing
  | otherwise = do
      sel <- selectRun env
      case sel of
        RunChosen (RunId u) _ -> pure (Just (Text.pack (show u)))
        RunNoRows -> do
          TIO.putStrLn "(no runs recorded yet)"
          pure Nothing
        RunSelectionCancelled -> pure Nothing
        RunFzfUnavailable -> do
          hPutStrLn stderr "shiki: no run id given and fzf is not available"
          pure Nothing
        RunSelectionError e -> do
          TIO.hPutStrLn stderr ("shiki: fzf: " <> e)
          pure Nothing
