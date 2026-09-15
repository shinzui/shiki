-- | Column rendering for recorded runs, shared by @shiki runs list@ and the
--   run picker ("Shiki.Cli.Fzf.Selector.Run") so both show the same columns
--   aligned the same way. It depends only on @shiki-core@, so both modules
--   can import it without an import cycle.
module Shiki.Cli.Runs.Format
  ( runTableHeader,
    watchStaleAfter,
    isUnwatched,
    displayStatus,
    runColumns,
    humanDuration,
    computeWidths,
    formatRow,
    renderTable,
  )
where

import Data.Generics.Labels ()
import Data.Text qualified as Text
import Data.Time.Clock (NominalDiffTime, diffUTCTime)
import Data.Time.Format qualified as TimeFmt
import Shiki.Persistence.Run (RunId (..), RunRecord)
import Shiki.Persistence.RunStatus (RunStatus (Pending, Running), runStatusToText)
import Shiki.Prelude

-- | The column titles, in the order 'runColumns' produces cells.
runTableHeader :: [Text]
runTableHeader = ["ID", "STARTED", "SERVICE", "STATUS", "DURATION", "EXIT", "COMMAND"]

-- | A header row followed by one row per run, every cell padded to its
--   column's width.
renderTable :: UTCTime -> [RunRecord] -> Text
renderTable observedAt rs =
  let body = map (runColumns observedAt) rs
      widths = computeWidths (runTableHeader : body)
   in Text.unlines (formatRow widths runTableHeader : map (formatRow widths) body)

-- | The seven cells of one run: 8-character id, start time, service,
--   status, duration, exit code, command.
runColumns :: UTCTime -> RunRecord -> [Text]
runColumns observedAt r =
  [ Text.take 8 (Text.pack (show (unRunId (r ^. #runId)))),
    Text.pack
      ( TimeFmt.formatTime
          TimeFmt.defaultTimeLocale
          "%Y-%m-%d %H:%M:%S"
          (r ^. #startedAt)
      ),
    r ^. #serviceName,
    displayStatus observedAt r,
    maybe "-" humanDuration (r ^. #durationMs),
    maybe "-" (Text.pack . show) (r ^. #exitCode),
    Text.intercalate " " (r ^. #command)
  ]

-- | Five missed one-minute heartbeats are tolerated before a watcher is
--   considered stale.
watchStaleAfter :: NominalDiffTime
watchStaleAfter = 300

-- | Whether an unfinished row has no recent heartbeat. This is a liveness
--   signal, not proof that no operating-system process exists.
isUnwatched :: UTCTime -> RunRecord -> Bool
isUnwatched observedAt r =
  r ^. #status `elem` [Pending, Running]
    && maybe
      True
      (\lastWatched -> diffUTCTime observedAt lastWatched > watchStaleAfter)
      (r ^. #lastWatchedAt)

-- | The status shown to operators without changing the stored status.
displayStatus :: UTCTime -> RunRecord -> Text
displayStatus observedAt r
  | isUnwatched observedAt r = "unwatched"
  | otherwise = runStatusToText (r ^. #status)

-- | Pretty-print a duration in milliseconds: @12s@, @2m5s@, @1h1m1s@.
humanDuration :: Int -> Text
humanDuration ms =
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

-- | The widest cell of each column. Rows may differ in length; a missing
--   cell counts as width 0.
computeWidths :: [[Text]] -> [Int]
computeWidths rows =
  foldr (zipWithLong max . map Text.length) [] rows
  where
    zipWithLong f xs ys =
      let n = max (length xs) (length ys)
          xs' = xs <> replicate (n - length xs) 0
          ys' = ys <> replicate (n - length ys) 0
       in zipWith f xs' ys'

-- | Pad every cell to its column width and join with two spaces.
formatRow :: [Int] -> [Text] -> Text
formatRow widths cols =
  Text.intercalate "  " (zipWith pad widths cols)
  where
    pad w t = t <> Text.replicate (w - Text.length t) " "
