-- | Deterministic, in-process recognisers for the failure shapes shiki
--   tends to encounter in one-off Job logs: Python tracebacks, JVM
--   exception chains, Go panics, Rust panics, and level-prefixed log
--   lines. Falls back to the last non-blank line if no recogniser
--   matches. Returns 'Nothing' only when the input has no non-whitespace
--   content.
module Shiki.Analysis.Heuristic
  ( summarizeFailure
  ) where

import Shiki.Prelude

import "text" Data.Text qualified as Text

-- | Hard cap on the returned summary length, in characters. Kept in
--   sync with 'Shiki.Analysis.Backend.summaryByteCap'.
summaryCharCap :: Int
summaryCharCap = 512

-- | Inspect a chunk of container logs and return the most likely
--   failure summary. Recognisers run in priority order; the first one
--   that matches wins. If none match, the fallback is the last
--   non-blank line. The result is capped at 'summaryCharCap' characters.
summarizeFailure :: Text -> Maybe Text
summarizeFailure raw =
  let ls = lines_ raw
   in case dropWhile blank (reverse ls) of
        [] -> Nothing
        _ ->
          let pickers =
                [ pythonTraceback
                , jvmExceptionChain
                , goPanic
                , rustPanic
                , levelPrefixed
                ]
              chosen =
                case asum (map ($ ls) pickers) of
                  Just t  -> t
                  Nothing -> lastNonBlank ls
           in Just (capChars chosen)
  where
    asum = foldr (<|>) Nothing

-- ── Recognisers ──────────────────────────────────────────────────────────

-- | The final non-indented line in the last @Traceback (most recent call
--   last):@ block. That line is the @ExceptionClass: message@ that the
--   operator cares about.
pythonTraceback :: [Text] -> Maybe Text
pythonTraceback ls = do
  let tracebackHeader t = "Traceback (most recent call last):" `Text.isPrefixOf` Text.stripStart t
  ix <- lastIndexBy tracebackHeader ls
  let after = drop (ix + 1) ls
      block = takeWhile (not . blank) after
      exceptionLines = filter (not . isIndented) block
  case lastMaybe exceptionLines of
    Just t  -> Just (Text.stripEnd t)
    Nothing -> Nothing

-- | The last @Exception in thread@ line, joined with the most recent
--   @Caused by:@ line that follows it (if any).
jvmExceptionChain :: [Text] -> Maybe Text
jvmExceptionChain ls = do
  ix <- lastIndexBy (\t -> "Exception in thread " `Text.isPrefixOf` Text.stripStart t) ls
  let header = Text.stripEnd (ls !! ix)
      after  = drop (ix + 1) ls
      causedBy = listToMaybe' [ Text.stripEnd t | t <- after, "Caused by:" `Text.isPrefixOf` Text.stripStart t ]
  pure $ case causedBy of
    Just c  -> header <> " / " <> c
    Nothing -> header

-- | The last @panic:@ header, optionally prefixed by the preceding
--   @goroutine@ context line.
goPanic :: [Text] -> Maybe Text
goPanic ls = do
  ix <- lastIndexBy (\t -> "panic:" `Text.isPrefixOf` Text.stripStart t) ls
  let header = Text.stripEnd (ls !! ix)
      before = take ix ls
      previousGoroutine =
        case dropWhile (not . isGoroutineLine) (reverse before) of
          (g : _) -> Just (Text.stripEnd g)
          _       -> Nothing
  pure $ case previousGoroutine of
    Just g  -> g <> " / " <> header
    Nothing -> header
  where
    isGoroutineLine t = "goroutine " `Text.isPrefixOf` Text.stripStart t

-- | The last @thread '...' panicked at ...@ line, exactly as printed.
rustPanic :: [Text] -> Maybe Text
rustPanic ls = do
  let isRustPanic t =
        let s = Text.stripStart t
         in "thread '" `Text.isPrefixOf` s && " panicked at " `Text.isInfixOf` s
  ix <- lastIndexBy isRustPanic ls
  pure (Text.stripEnd (ls !! ix))

-- | The last line whose first whitespace-delimited token names a level
--   commonly used for terminal-fatal messages, in either bracketed,
--   bare, or structured-JSON form.
levelPrefixed :: [Text] -> Maybe Text
levelPrefixed ls = do
  ix <- lastIndexBy isLevelLine ls
  pure (Text.stripEnd (ls !! ix))
  where
    isLevelLine t =
      let s = Text.stripStart t
          firstTok = Text.takeWhile (not . isSpace) s
       in firstTok `elem` levelTokens
            || "\"level\":\"error\"" `Text.isInfixOf` t
            || "\"level\":\"fatal\"" `Text.isInfixOf` t
    isSpace c = c == ' ' || c == '\t'
    levelTokens =
      [ "ERROR"
      , "FATAL"
      , "PANIC"
      , "EMERGENCY"
      , "[ERROR]"
      , "[FATAL]"
      , "[PANIC]"
      , "[EMERGENCY]"
      ]

-- ── Helpers ──────────────────────────────────────────────────────────────

-- | Split on @\n@ without collapsing trailing empty entries — those are
--   needed by the blank-line detection in 'pythonTraceback'.
lines_ :: Text -> [Text]
lines_ = Text.splitOn "\n"

blank :: Text -> Bool
blank = Text.null . Text.strip

isIndented :: Text -> Bool
isIndented t = case Text.uncons t of
  Just (c, _) -> c == ' ' || c == '\t'
  Nothing     -> False

-- | The last element of a list, or 'Nothing' on @[]@. Local re-spelling
--   to avoid pulling 'Data.Maybe.listToMaybe' shadowing.
lastMaybe :: [a] -> Maybe a
lastMaybe = foldl (\_ x -> Just x) Nothing

listToMaybe' :: [a] -> Maybe a
listToMaybe' []      = Nothing
listToMaybe' (x : _) = Just x

-- | The 0-based index of the last element satisfying the predicate.
lastIndexBy :: (a -> Bool) -> [a] -> Maybe Int
lastIndexBy p xs =
  case [i | (i, x) <- zip [0 :: Int ..] xs, p x] of
    [] -> Nothing
    is -> Just (last is)

lastNonBlank :: [Text] -> Text
lastNonBlank ls = case dropWhile blank (reverse ls) of
  (t : _) -> Text.stripEnd t
  []      -> ""

capChars :: Text -> Text
capChars t
  | Text.length t <= summaryCharCap = t
  | otherwise                       = Text.take summaryCharCap t
