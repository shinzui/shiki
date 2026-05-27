-- | The @shiki runs@ family of read-only subcommands: @list@, @show@,
--   and @logs@. Reads rows written by 'Shiki.Cli.Run' through the
--   persistence statements defined in "Shiki.Persistence.Run"; never
--   mutates the database.
module Shiki.Cli.Runs
  ( RunsCommand (..)
  , runsParser
  , runRuns
  ) where

import Shiki.Prelude hiding (argument)

import Shiki.Analysis.Backend
  ( AnalyzerError (..)
  , AnalyzerKind (..)
  , AnalyzerResult (..)
  , analyzerBackendToKind
  , runAnalyzer
  )
import Shiki.Cli.Env (CliEnv (..))
import Shiki.Persistence.Run
  ( RunId (..)
  , RunRecord
  , findRunByPrefixStatement
  , listRecentRunsByServiceStatement
  , listRecentRunsStatement
  , updateErrorSummaryStatement
  )
import Shiki.Persistence.RunStatus (runStatusToText)
import Shiki.Service.Config.Dhall (loadServiceConfig)

import "aeson-pretty" Data.Aeson.Encode.Pretty qualified as AesonPretty
import "bytestring" Data.ByteString.Lazy.Char8 qualified as BL8
import "text" Data.Text qualified as Text
import "text" Data.Text.IO qualified as TIO
import "time" Data.Time.Format qualified as TimeFmt
import "hasql-pool" Hasql.Pool qualified as Pool
import "hasql" Hasql.Session qualified as Session
import "hasql" Hasql.Statement (Statement)
import "optparse-applicative" Options.Applicative
  ( Parser
  , argument
  , auto
  , help
  , hsubparser
  , info
  , long
  , metavar
  , option
  , optional
  , progDesc
  , short
  , showDefault
  , str
  , strOption
  , value
  )
import "optparse-applicative" Options.Applicative qualified as Opt
import "base" Control.Exception (IOException, try)
import "base" System.Exit (exitFailure)
import "base" System.IO (hPutStrLn, stderr)

data RunsCommand
  = RunsList !(Maybe Text) !Int
  | RunsShow !Text
  | RunsLogs !Text
  | RunsError !Text
  | RunsAnalyze !Text !(Maybe AnalyzerKind)
  deriving stock (Generic, Eq, Show)

-- | Parser for the @runs@ family. The three subcommands intentionally
--   share no flags; if a flag belongs to more than one of them later
--   on, hoist it up here.
runsParser :: Parser RunsCommand
runsParser =
  hsubparser
    ( Opt.command "list"
        ( info
            ( RunsList
                <$> optional
                      ( strOption
                          ( long "service"
                              <> short 's'
                              <> metavar "NAME"
                              <> help "Filter by service name"
                          )
                      )
                <*> option
                      auto
                      ( long "limit"
                          <> short 'l'
                          <> metavar "N"
                          <> value 20
                          <> showDefault
                          <> help "Maximum rows to show"
                      )
            )
            (progDesc "List recent runs, newest first")
        )
        <> Opt.command
          "show"
          ( info
              (RunsShow <$> argument str (metavar "ID"))
              (progDesc "Show one run by id (UUID or unambiguous prefix)")
          )
        <> Opt.command
          "logs"
          ( info
              (RunsLogs <$> argument str (metavar "ID"))
              (progDesc "Print the captured log tail for a run")
          )
        <> Opt.command
          "error"
          ( info
              (RunsError <$> argument str (metavar "ID"))
              (progDesc "Print the captured error summary for a run")
          )
        <> Opt.command
          "analyze"
          ( info
              ( RunsAnalyze
                  <$> argument str (metavar "ID")
                  <*> optional
                        ( option
                            analyzerKindReader
                            ( long "analyzer"
                                <> metavar "heuristic|baikai:<model-id>|none"
                                <> help "Override the service's default analyzer"
                            )
                        )
              )
              (progDesc "Re-run analysis on a stored run's log tail")
          )
    )

analyzerKindReader :: Opt.ReadM AnalyzerKind
analyzerKindReader = Opt.eitherReader $ \raw -> case Text.pack raw of
  "heuristic" -> Right Heuristic
  "none"      -> Right None
  t | "baikai:" `Text.isPrefixOf` t ->
    let mid = Text.drop (Text.length "baikai:") t
     in if Text.null mid
          then Left "expected 'baikai:<model-id>', e.g. baikai:anthropic_claude_haiku_4_5"
          else Right (Baikai mid)
  _ -> Left "expected 'heuristic', 'none', or 'baikai:<model-id>'"

-- | Dispatch a parsed 'RunsCommand' to the right handler.
runRuns :: CliEnv -> RunsCommand -> IO ()
runRuns env = \case
  RunsList mService limit       -> doList env mService limit
  RunsShow idText               -> doShow env idText
  RunsLogs idText               -> doLogs env idText
  RunsError idText              -> doError env idText
  RunsAnalyze idText override   -> doAnalyze env idText override

doList :: CliEnv -> Maybe Text -> Int -> IO ()
doList env mService limit = do
  rows <- case mService of
    Nothing -> runRead env listRecentRunsStatement limit
    Just svc -> runRead env listRecentRunsByServiceStatement (svc, limit)
  if null rows
    then TIO.putStrLn "(no runs recorded yet)"
    else TIO.putStr (renderTable rows)

doShow :: CliEnv -> Text -> IO ()
doShow env idText = do
  matches <- runRead env findRunByPrefixStatement idText
  case matches of
    [] -> noMatch idText
    [r] -> BL8.putStrLn (AesonPretty.encodePretty r)
    _ -> ambiguous idText

doLogs :: CliEnv -> Text -> IO ()
doLogs env idText = do
  matches <- runRead env findRunByPrefixStatement idText
  case matches of
    [] -> noMatch idText
    [r] -> case r ^. #logTail of
      Just t -> TIO.putStr t
      Nothing -> TIO.putStrLn "(no log captured)"
    _ -> ambiguous idText

doError :: CliEnv -> Text -> IO ()
doError env idText = do
  matches <- runRead env findRunByPrefixStatement idText
  case matches of
    [] -> noMatch idText
    [r] -> case r ^. #errorSummary of
      Just t -> TIO.putStrLn t
      Nothing -> TIO.putStrLn "(no summary)"
    _ -> ambiguous idText

doAnalyze :: CliEnv -> Text -> Maybe AnalyzerKind -> IO ()
doAnalyze env idText override = do
  matches <- runRead env findRunByPrefixStatement idText
  case matches of
    [] -> noMatch idText
    _ : _ : _ -> ambiguous idText
    [r] -> do
      kind <- effectiveBackend r override
      case r ^. #logTail of
        Nothing -> TIO.putStrLn "(no logs captured; cannot analyze)"
        Just t  -> do
          result <- runAnalyzer kind t
          case result of
            Left err -> do
              hPutStrLn stderr (renderAnalyzerError err)
              exitFailure
            Right res -> do
              runWrite env updateErrorSummaryStatement
                (r ^. #runId, res ^. #summary, res ^. #source)
              TIO.putStrLn (renderAnalyzeOutcome (r ^. #runId) res)

-- | Resolve the analyzer backend to use for one @runs analyze@ call:
--   CLI override wins; otherwise the service's Dhall default is used;
--   otherwise 'Heuristic' (the same default the inline path picks).
effectiveBackend :: RunRecord -> Maybe AnalyzerKind -> IO AnalyzerKind
effectiveBackend _ (Just k) = pure k
effectiveBackend r Nothing = do
  let path = "services/" <> Text.unpack (r ^. #serviceName) <> ".dhall"
  mCfg <- try @IOException (loadServiceConfig path)
  case mCfg of
    Left _    -> pure Heuristic
    Right cfg -> pure (analyzerBackendToKind (cfg ^. #analyzer))

renderAnalyzerError :: AnalyzerError -> String
renderAnalyzerError = \case
  AnalyzerBackendDisabled -> "shiki: analyzer disabled (backend = None)"
  AnalyzerUnknown t       -> "shiki: unknown analyzer override: " <> Text.unpack t
  AnalyzerBaikaiError t   -> "shiki: baikai backend failed: " <> Text.unpack t

renderAnalyzeOutcome :: RunId -> AnalyzerResult -> Text
renderAnalyzeOutcome rid res =
  "analyzed run "
    <> Text.take 8 (Text.pack (show (unRunId rid)))
    <> " with "
    <> (res ^. #source)
    <> ": "
    <> fromMaybe "(no summary)" (res ^. #summary)

noMatch :: Text -> IO a
noMatch idText = do
  TIO.putStrLn ("no run matching " <> idText)
  exitFailure

ambiguous :: Text -> IO a
ambiguous idText = do
  TIO.putStrLn ("ambiguous id prefix " <> idText)
  exitFailure

-- ── Rendering helpers ──────────────────────────────────────────────────────

renderTable :: [RunRecord] -> Text
renderTable rs =
  let header = ["ID", "STARTED", "SERVICE", "STATUS", "DURATION", "EXIT", "COMMAND"]
      body = map renderRow rs
      widths = computeWidths (header : body)
   in Text.unlines (formatRow widths header : map (formatRow widths) body)

renderRow :: RunRecord -> [Text]
renderRow r =
  [ Text.take 8 (Text.pack (show (unRunId (r ^. #runId))))
  , Text.pack
      ( TimeFmt.formatTime
          TimeFmt.defaultTimeLocale
          "%Y-%m-%d %H:%M:%S"
          (r ^. #startedAt)
      )
  , r ^. #serviceName
  , runStatusToText (r ^. #status)
  , maybe "-" humanDuration (r ^. #durationMs)
  , maybe "-" (Text.pack . show) (r ^. #exitCode)
  , Text.intercalate " " (r ^. #command)
  ]

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

computeWidths :: [[Text]] -> [Int]
computeWidths rows =
  foldr (zipWithLong max . map Text.length) (repeat 0) rows
  where
    zipWithLong f xs ys =
      let n = max (length xs) (length ys)
          xs' = xs <> replicate (n - length xs) 0
          ys' = ys <> replicate (n - length ys) 0
       in zipWith f xs' ys'

formatRow :: [Int] -> [Text] -> Text
formatRow widths cols =
  Text.intercalate "  " (zipWith pad widths cols)
  where
    pad w t = t <> Text.replicate (w - Text.length t) " "

runRead :: CliEnv -> Statement a b -> a -> IO b
runRead env stmt input =
  Pool.use (env ^. #pool) (Session.statement input stmt)
    >>= either (error . ("shiki: persistence error: " <>) . show) pure

runWrite :: CliEnv -> Statement a () -> a -> IO ()
runWrite = runRead
