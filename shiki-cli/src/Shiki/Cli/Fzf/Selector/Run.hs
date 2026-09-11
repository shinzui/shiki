-- | Selector that lets the operator pick a single run row via @fzf@.
--
--   This is the bridge between the abstract 'Shiki.Cli.Fzf.runFzf' and
--   the concrete @runs@ table: it fetches the 50 most-recent rows,
--   formats them in the same column shape that @runs list@ uses, runs
--   them through fzf, and returns either a full UUID (as 'Text', so the
--   existing handlers can keep using 'findRunByPrefixStatement') or one
--   of the non-selection outcomes.
module Shiki.Cli.Fzf.Selector.Run
  ( RunSelection (..),
    defaultRunOpts,
    formatRunCandidate,
    selectRun,
    resolveRunId,
  )
where

import Data.Generics.Labels ()
import Data.Text qualified as Text
import Data.Text.IO qualified as TIO
import Data.Time.Format qualified as TimeFmt
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Shiki.Cli.Env (CliEnv (..))
import Shiki.Cli.Fzf
  ( Candidate (..),
    FzfOpts,
    FzfResult (..),
    isFzfAvailable,
    runFzf,
    withAnsi,
    withHeight,
    withNoSort,
    withPrompt,
  )
import Shiki.Persistence.Run
  ( RunId (..),
    RunRecord,
    listRecentRunsStatement,
  )
import Shiki.Persistence.RunStatus (runStatusToText)
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
--   ANSI colour rendering on, sort disabled (we pre-sort by recency).
defaultRunOpts :: FzfOpts
defaultRunOpts =
  withPrompt "run> " <> withHeight "40%" <> withAnsi <> withNoSort

-- | How many rows to surface in the picker. 50 is bigger than the 20
--   default of @runs list@ because fuzzy search is more useful with
--   more candidates; 50 still fits in a 40%-height pane on a typical
--   terminal.
selectorRowLimit :: Int
selectorRowLimit = 50

-- | Build the candidate row for one 'RunRecord'. The display is a
--   single line in the same column shape as @runs list@; the value is
--   the @(RunId, RunRecord)@ pair so callers can either re-query or
--   use the cached record directly.
formatRunCandidate :: RunRecord -> Candidate (RunId, RunRecord)
formatRunCandidate r =
  Candidate
    { display = Text.intercalate "  " columns,
      value = (r ^. #runId, r)
    }
  where
    columns =
      [ Text.take 8 (Text.pack (show (unRunId (r ^. #runId)))),
        Text.pack
          ( TimeFmt.formatTime
              TimeFmt.defaultTimeLocale
              "%Y-%m-%d %H:%M:%S"
              (r ^. #startedAt)
          ),
        r ^. #serviceName,
        runStatusToText (r ^. #status),
        maybe "-" formatDuration (r ^. #durationMs),
        "exit=" <> maybe "-" (Text.pack . show) (r ^. #exitCode),
        Text.intercalate " " (r ^. #command)
      ]

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
          let candidates = map formatRunCandidate rows
          res <- runFzf (env ^. #fzf) defaultRunOpts candidates
          pure $ case res of
            FzfSelected (rid, rec) -> RunChosen rid rec
            FzfNoMatch -> RunNoRows
            FzfCancelled -> RunSelectionCancelled
            FzfError msg -> RunSelectionError msg

-- | Pretty-print a duration in milliseconds. Mirrors the formatter
--   used by @runs list@; kept local so the selector module does not
--   depend on "Shiki.Cli.Runs" (which would create a cycle).
formatDuration :: Int -> Text
formatDuration ms =
  let secs = ms `div` 1000
      mins = secs `div` 60
      hours = mins `div` 60
      remMins = mins `mod` 60
      remSecs = secs `mod` 60
   in if hours > 0
        then Text.pack (show hours <> "h" <> show remMins <> "m" <> show remSecs <> "s")
        else
          if mins > 0
            then Text.pack (show mins <> "m" <> show remSecs <> "s")
            else Text.pack (show secs <> "s")

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
