-- | The @shiki runs@ family of subcommands: @list@, @show@, @logs@,
--   @error@, and @analyze@. Reads rows written by 'Shiki.Cli.Run' through
--   the persistence statements defined in "Shiki.Persistence.Run"; only
--   @analyze@ writes, replacing a run's stored error summary.
module Shiki.Cli.Runs
  ( RunsCommand (..),
    runsParser,
    runRuns,
  )
where

import Control.Exception (IOException, try)
import Data.Aeson.Encode.Pretty qualified as AesonPretty
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Data.Text.IO qualified as TIO
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (Statement)
import Options.Applicative
  ( Parser,
    argument,
    auto,
    help,
    hsubparser,
    info,
    long,
    metavar,
    option,
    optional,
    progDesc,
    short,
    showDefault,
    str,
    strOption,
    value,
  )
import Options.Applicative qualified as Opt
import Shiki.Analysis.Backend
  ( AnalyzerError (..),
    AnalyzerKind (..),
    AnalyzerResult (..),
    analyzerBackendToKind,
    runAnalyzer,
  )
import Shiki.Cli.Env (CliEnv (..))
import Shiki.Cli.Fzf (FzfOpts)
import Shiki.Cli.Fzf.Selector.Run
  ( RunLookupFailure,
    analyzeRunOpts,
    lookupRun,
    readRunOpts,
    renderRunLookupFailure,
    runTarget,
  )
import Shiki.Cli.Runs.Format (renderTable)
import Shiki.Persistence.Run
  ( RunId (..),
    RunRecord,
    listRecentRunsByServiceStatement,
    listRecentRunsStatement,
    updateErrorSummaryStatement,
  )
import Shiki.Prelude hiding (argument)
import Shiki.Service.Config.Dhall (loadServiceConfig)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

data RunsCommand
  = RunsList !(Maybe Text) !Int
  | RunsShow !(Maybe Text)
  | RunsLogs !(Maybe Text)
  | RunsError !(Maybe Text)
  | RunsAnalyze !(Maybe Text) !(Maybe AnalyzerKind)
  deriving stock (Generic, Eq, Show)

-- | Parser for the @runs@ family. The three subcommands intentionally
--   share no flags; if a flag belongs to more than one of them later
--   on, hoist it up here.
runsParser :: Parser RunsCommand
runsParser =
  hsubparser
    ( Opt.command
        "list"
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
              (RunsShow <$> optional (argument str idArgHelp))
              (progDesc "Show one run by id (UUID or unambiguous prefix; uses fzf if omitted)")
          )
        <> Opt.command
          "logs"
          ( info
              (RunsLogs <$> optional (argument str idArgHelp))
              (progDesc "Print the captured log tail for a run (uses fzf if omitted)")
          )
        <> Opt.command
          "error"
          ( info
              (RunsError <$> optional (argument str idArgHelp))
              (progDesc "Print the captured error summary for a run (uses fzf if omitted)")
          )
        <> Opt.command
          "analyze"
          ( info
              ( RunsAnalyze
                  <$> optional (argument str idArgHelp)
                  <*> optional
                    ( option
                        analyzerKindReader
                        ( long "analyzer"
                            <> metavar "heuristic|baikai:<model-id>|none"
                            <> help "Override the service's default analyzer"
                        )
                    )
              )
              (progDesc "Re-run analysis on a stored run's log tail (uses fzf if omitted)")
          )
    )

idArgHelp :: Opt.Mod Opt.ArgumentFields Text
idArgHelp = metavar "ID" <> help "Run id (UUID or unambiguous prefix); opens an fzf picker if omitted"

analyzerKindReader :: Opt.ReadM AnalyzerKind
analyzerKindReader = Opt.eitherReader $ \raw -> case Text.pack raw of
  "heuristic" -> Right Heuristic
  "none" -> Right None
  t
    | "baikai:" `Text.isPrefixOf` t ->
        let mid = Text.drop (Text.length "baikai:") t
         in if Text.null mid
              then Left "expected 'baikai:<model-id>', e.g. baikai:anthropic_claude_haiku_4_5"
              else Right (Baikai mid)
  _ -> Left "expected 'heuristic', 'none', or 'baikai:<model-id>'"

-- | Dispatch a parsed 'RunsCommand' to the right handler. @withEnv@
--   acquires the database environment ("Shiki.Cli.Env.withCliEnv"); taking
--   it as an argument lets the single-run commands decide their target
--   first, so a missing positional with no usable fzf fails before any
--   connection is made (see "Shiki.Cli.Fzf.Selector.Run").
runRuns :: ((CliEnv -> IO ()) -> IO ()) -> RunsCommand -> IO ()
runRuns withEnv = \case
  RunsList mService limit -> withEnv (\env -> doList env mService limit)
  RunsShow mId -> withRun withEnv readRunOpts mId (const doShow)
  RunsLogs mId -> withRun withEnv readRunOpts mId (const doLogs)
  RunsError mId -> withRun withEnv readRunOpts mId (const doError)
  RunsAnalyze mId override ->
    withRun withEnv analyzeRunOpts mId (\env r -> doAnalyze env r override)

-- | Decide the target before acquiring the environment (so a missing fzf never
--   costs a database connection), then look the run up and run the handler.
withRun ::
  ((CliEnv -> IO ()) -> IO ()) ->
  FzfOpts ->
  Maybe Text ->
  (CliEnv -> RunRecord -> IO ()) ->
  IO ()
withRun withEnv opts mId body =
  runTarget opts mId >>= \case
    Left failure -> failLookup failure
    Right target ->
      withEnv $ \env ->
        lookupRun env target >>= either failLookup (body env)

-- | Print the failure's message (if any) on stderr and exit 1.
failLookup :: RunLookupFailure -> IO a
failLookup failure = do
  mapM_ (TIO.hPutStrLn stderr) (renderRunLookupFailure failure)
  exitFailure

doList :: CliEnv -> Maybe Text -> Int -> IO ()
doList env mService limit = do
  rows <- case mService of
    Nothing -> runRead env listRecentRunsStatement limit
    Just svc -> runRead env listRecentRunsByServiceStatement (svc, limit)
  if null rows
    then TIO.putStrLn "(no runs recorded yet)"
    else TIO.putStr (renderTable rows)

doShow :: RunRecord -> IO ()
doShow r = BL8.putStrLn (AesonPretty.encodePretty r)

doLogs :: RunRecord -> IO ()
doLogs r = case r ^. #logTail of
  Just t -> TIO.putStr t
  Nothing -> TIO.putStrLn "(no log captured)"

doError :: RunRecord -> IO ()
doError r = case r ^. #errorSummary of
  Just t -> TIO.putStrLn t
  Nothing -> TIO.putStrLn "(no summary)"

doAnalyze :: CliEnv -> RunRecord -> Maybe AnalyzerKind -> IO ()
doAnalyze env r override = do
  kind <- effectiveBackend r override
  case r ^. #logTail of
    Nothing -> TIO.putStrLn "(no logs captured; cannot analyze)"
    Just t -> do
      result <- runAnalyzer kind t
      case result of
        Left err -> do
          hPutStrLn stderr (renderAnalyzerError err)
          exitFailure
        Right res -> do
          runWrite
            env
            updateErrorSummaryStatement
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
    Left _ -> pure Heuristic
    Right cfg -> pure (analyzerBackendToKind (cfg ^. #analyzer))

renderAnalyzerError :: AnalyzerError -> String
renderAnalyzerError = \case
  AnalyzerBackendDisabled -> "shiki: analyzer disabled (backend = None)"
  AnalyzerUnknown t -> "shiki: unknown analyzer override: " <> Text.unpack t
  AnalyzerBaikaiError t -> "shiki: baikai backend failed: " <> Text.unpack t

renderAnalyzeOutcome :: RunId -> AnalyzerResult -> Text
renderAnalyzeOutcome rid res =
  "analyzed run "
    <> Text.take 8 (Text.pack (show (unRunId rid)))
    <> " with "
    <> (res ^. #source)
    <> ": "
    <> fromMaybe "(no summary)" (res ^. #summary)

runRead :: CliEnv -> Statement a b -> a -> IO b
runRead env stmt input =
  Pool.use (env ^. #pool) (Session.statement input stmt)
    >>= either (error . ("shiki: persistence error: " <>) . show) pure

runWrite :: CliEnv -> Statement a () -> a -> IO ()
runWrite = runRead
