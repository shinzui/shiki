-- | The @shiki runs@ family of subcommands: @list@, @show@, @logs@,
--   @error@, @analyze@, and @sync@. Reads rows written by 'Shiki.Cli.Run'
--   through the persistence statements defined in "Shiki.Persistence.Run";
--   @analyze@ writes, replacing a run's stored error summary, and @sync@
--   finalizes unfinished runs from the cluster ("Shiki.Cli.Runs.Sync").
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
import Effectful (Eff, IOE, type (:>))
import Effectful.Error.Static (Error, throwError)
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
  ( AnalyzerKind (..),
    AnalyzerResult (..),
    analyzerBackendToKind,
    runAnalyzer,
  )
import Shiki.Cli.Env (withKubeClient)
import Shiki.Cli.Error (CliError (..))
import Shiki.Cli.Fzf (FzfOpts)
import Shiki.Cli.Fzf.Selector.Run
  ( analyzeRunOpts,
    lookupRun,
    readRunOpts,
    runTarget,
  )
import Shiki.Cli.Runs.Format (isUnwatched, renderTable)
import Shiki.Cli.Runs.Sync (syncRun, syncRuns)
import Shiki.Effect.RunStore
  ( RunStore,
    databaseNow,
    listRecentRuns,
    updateErrorSummary,
  )
import Shiki.Error (ShikiError (..))
import Shiki.Persistence.Run (RunId (..), RunRecord)
import Shiki.Prelude hiding (argument)
import Shiki.Service.Config.Dhall (loadServiceConfig)
import System.IO (stderr)

data RunsCommand
  = RunsList !(Maybe Text) !Int
  | RunsShow !(Maybe Text)
  | RunsLogs !(Maybe Text)
  | RunsError !(Maybe Text)
  | RunsAnalyze !(Maybe Text) !(Maybe AnalyzerKind)
  | RunsSync !(Maybe Text)
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
        <> Opt.command
          "sync"
          ( info
              ( RunsSync
                  <$> optional
                    ( argument
                        str
                        ( metavar "ID"
                            <> help "Run id (UUID or unambiguous prefix); syncs every unfinished run if omitted"
                        )
                    )
              )
              (progDesc "Finalize unfinished runs from the state of their Jobs in the cluster")
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

-- | How a @runs@ subcommand reaches the store: it hands an action the
--   'RunStore' effect. It is taken as an argument, not called up front,
--   because resolving the connection string and opening the pool must happen
--   /after/ the single-run commands decide their target: a missing positional
--   with no usable fzf has to fail before any connection is made (ADR 2, and
--   see "Shiki.Cli.Fzf.Selector.Run").
type WithStore es = Eff (RunStore : es) () -> Eff es ()

-- | Dispatch a parsed 'RunsCommand' to the right handler. Only @sync@ asks for
--   a Kubernetes client, so a broken kubeconfig no longer breaks a pure
--   database read.
runRuns ::
  ( IOE :> es,
    Error ShikiError :> es,
    Error CliError :> es
  ) =>
  WithStore es ->
  RunsCommand ->
  Eff es ()
runRuns withStore = \case
  RunsList mService limit -> withStore (doList mService limit)
  RunsShow mId -> withRun withStore readRunOpts mId (\observedAt r -> doShow observedAt r)
  RunsLogs mId -> withRun withStore readRunOpts mId (\_ r -> doLogs r)
  RunsError mId -> withRun withStore readRunOpts mId (\_ r -> doError r)
  RunsAnalyze mId override ->
    withRun withStore analyzeRunOpts mId (\_ r -> doAnalyze r override)
  RunsSync Nothing -> withStore (withKubeClient syncRuns)
  RunsSync (Just rid) ->
    withRun withStore readRunOpts (Just rid) $ \observedAt r ->
      withKubeClient (\env -> syncRun env observedAt r)

-- | Decide the target before opening the store, then look the run up and run
--   the handler.
withRun ::
  (IOE :> es, Error CliError :> es) =>
  WithStore es ->
  FzfOpts ->
  Maybe Text ->
  (UTCTime -> RunRecord -> Eff (RunStore : es) ()) ->
  Eff es ()
withRun withStore opts mId body =
  liftIO (runTarget opts mId) >>= \case
    Left failure -> throwError (CliRunLookup failure)
    Right target -> withStore $ do
      observedAt <- databaseNow
      lookupRun observedAt target >>= \case
        Left failure -> throwError (CliRunLookup failure)
        Right r -> body observedAt r

doList ::
  (RunStore :> es, IOE :> es) =>
  Maybe Text ->
  Int ->
  Eff es ()
doList mService limit = do
  observedAt <- databaseNow
  rows <- listRecentRuns mService limit
  liftIO $
    if null rows
      then TIO.putStrLn "(no runs recorded yet)"
      else do
        TIO.putStr (renderTable observedAt rows)
        when (any (isUnwatched observedAt) rows) $
          TIO.hPutStrLn
            stderr
            "unwatched: no shiki process has recently reported watching these runs; their status may not update until 'shiki runs sync' is run"

doShow :: (IOE :> es) => UTCTime -> RunRecord -> Eff es ()
doShow observedAt r = liftIO $ do
  BL8.putStrLn (AesonPretty.encodePretty r)
  when (isUnwatched observedAt r) $
    TIO.hPutStrLn
      stderr
      ( "shiki: run "
          <> shortRunId r
          <> " is unwatched: no shiki process has recently reported watching it, so its status may not update until 'shiki runs sync "
          <> shortRunId r
          <> "' is run"
      )

doLogs :: (IOE :> es) => RunRecord -> Eff es ()
doLogs r = liftIO $ case r ^. #logTail of
  Just t -> TIO.putStr t
  Nothing -> TIO.putStrLn "(no log captured)"

doError :: (IOE :> es) => RunRecord -> Eff es ()
doError r = liftIO $ case r ^. #errorSummary of
  Just t -> TIO.putStrLn t
  Nothing -> TIO.putStrLn "(no summary)"

doAnalyze ::
  (RunStore :> es, IOE :> es, Error ShikiError :> es) =>
  RunRecord ->
  Maybe AnalyzerKind ->
  Eff es ()
doAnalyze r override = do
  kind <- liftIO (effectiveBackend r override)
  case r ^. #logTail of
    Nothing -> liftIO (TIO.putStrLn "(no logs captured; cannot analyze)")
    Just t ->
      liftIO (runAnalyzer kind t) >>= \case
        Left err -> throwError (ShikiAnalyzerError err)
        Right res -> do
          updateErrorSummary (r ^. #runId) (res ^. #summary) (res ^. #source)
          liftIO (TIO.putStrLn (renderAnalyzeOutcome (r ^. #runId) res))

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

renderAnalyzeOutcome :: RunId -> AnalyzerResult -> Text
renderAnalyzeOutcome rid res =
  "analyzed run "
    <> Text.take 8 (Text.pack (show (unRunId rid)))
    <> " with "
    <> (res ^. #source)
    <> ": "
    <> fromMaybe "(no summary)" (res ^. #summary)

shortRunId :: RunRecord -> Text
shortRunId r = Text.take 8 (Text.pack (show (unRunId (r ^. #runId))))
