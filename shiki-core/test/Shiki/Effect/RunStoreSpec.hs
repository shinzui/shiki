-- | The PostgreSQL interpreter for 'RunStore', exercised against a throwaway
--   database: every operation does what its name says, and a statement that
--   cannot run becomes a typed 'StatementFailed' naming the operation instead
--   of an exception.
module Shiki.Effect.RunStoreSpec (tests) where

import Data.Aeson qualified as Aeson
import Data.Maybe (listToMaybe)
import Data.Text qualified as Text
import Effectful (Eff, IOE, runEff)
import Effectful.Error.Static (Error, runErrorNoCallStack)
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Shiki.Effect.RunStore
  ( RunStore,
    completeRun,
    completeUnfinishedRun,
    databaseNow,
    findRunsByPrefix,
    getRun,
    insertRun,
    listRecentRuns,
    listUnfinishedRuns,
    markRunRunning,
    touchRunWatched,
    updateErrorSummary,
  )
import Shiki.Effect.RunStore.Postgres (runRunStorePostgres)
import Shiki.Error (ShikiError (..), StoreError (..))
import Shiki.Persistence.Run
  ( NewRun (..),
    RunCompletion (..),
    RunId (..),
    RunRecord,
    newRunId,
  )
import Shiki.Persistence.RunStatus (RunStatus (..))
import Shiki.Persistence.TestPg (withSchemaPool)
import Shiki.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase)

tests :: TestTree
tests =
  testGroup
    "Shiki.Effect.RunStore"
    [ testCase "insert, mark running, find by prefix, complete, list" $
        withSchemaPool $ \pool -> do
          rid <- newRunId
          startedAt <- getCurrentTime
          result <- runStore pool $ do
            insertRun (newRun rid startedAt)
            markRunRunning rid

            unfinishedBefore <- listUnfinishedRuns
            recentRows <- listRecentRuns Nothing 10
            byService <- listRecentRuns (Just "no-such-service") 10
            matches <- findRunsByPrefix (Text.take 8 (runIdText rid))
            touchRunWatched rid
            watched <- getRun rid

            completeRun (completion rid startedAt)
            updateErrorSummary rid (Just "out of memory") "heuristic"
            finished <- getRun rid
            unfinishedAfter <- listUnfinishedRuns
            secondComplete <- completeUnfinishedRun (completion rid startedAt)
            storeNow <- databaseNow
            pure
              ( unfinishedBefore,
                recentRows,
                byService,
                matches,
                watched,
                finished,
                unfinishedAfter,
                secondComplete,
                storeNow
              )
          case result of
            Left err -> assertFailure ("store failed: " <> show err)
            Right (unfinishedBefore, recentRows, byService, matches, watched, finished, unfinishedAfter, secondComplete, storeNow) -> do
              assertEqual "the new run is unfinished" 1 (length unfinishedBefore)
              assertEqual "running" (Just Running) (fmap (view #status) (listToMaybe unfinishedBefore))
              assertEqual "one recent run" 1 (length (recentRows :: [RunRecord]))
              assertEqual "the service filter is applied" 0 (length byService)
              assertEqual "the id prefix matches exactly one row" 1 (length matches)
              assertBool
                "touchRunWatched recorded a heartbeat"
                (isJust (watched >>= view #lastWatchedAt))
              assertEqual "completed" (Just Succeeded) (view #status <$> finished)
              assertEqual "exit code" (Just (Just 0)) (view #exitCode <$> finished)
              assertEqual
                "the error summary was replaced"
                (Just (Just "out of memory"))
                (view #errorSummary <$> finished)
              assertEqual "nothing is unfinished any more" 0 (length unfinishedAfter)
              assertEqual
                "a second completion does not overwrite a finished row"
                (Just False)
                (Just secondComplete)
              assertBool "the database clock answered" (storeNow >= startedAt),
      testCase "a statement that cannot run is a typed StatementFailed" $
        withSchemaPool $ \pool -> do
          dropRunsTable pool
          result <- runStore pool (listRecentRuns Nothing 10)
          case result of
            Left (ShikiStoreError (StatementFailed operation message)) -> do
              assertEqual "the failing operation is named" "list recent runs" operation
              assertBool
                ("the message mentions the missing table: " <> Text.unpack message)
                ("runs" `Text.isInfixOf` message)
            other -> assertFailure ("expected StatementFailed, got " <> show (() <$ other))
    ]

-- | Run an action with 'RunStore' interpreted over the pool, discharging the
--   typed error the way 'Shiki.Cli.Main.runShikiMain' does.
runStore ::
  Pool.Pool ->
  Eff '[RunStore, Error ShikiError, IOE] a ->
  IO (Either ShikiError a)
runStore pool action =
  runEff (runErrorNoCallStack @ShikiError (runRunStorePostgres pool action))

newRun :: RunId -> UTCTime -> NewRun
newRun rid startedAt =
  NewRun
    { runId = rid,
      serviceName = "ingest",
      command = ["reindex"],
      namespace = "data",
      jobName = "shiki-ingest-test",
      image = Just "registry.example.com/ingest:latest",
      startedAt = startedAt,
      serviceConfig = Aeson.object []
    }

completion :: RunId -> UTCTime -> RunCompletion
completion rid startedAt =
  RunCompletion
    { runId = rid,
      status = Succeeded,
      exitCode = Just 0,
      endedAt = startedAt,
      durationMs = 12_000,
      logTail = Just "ok\n",
      errorMessage = Nothing,
      errorSummary = Nothing,
      errorSummarySource = "heuristic"
    }

runIdText :: RunId -> Text
runIdText (RunId u) = Text.pack (show u)

-- | Remove the table the statements target, so the next statement fails for a
--   reason the interpreter has to classify.
dropRunsTable :: Pool.Pool -> IO ()
dropRunsTable pool =
  Pool.use pool (Session.script "DROP TABLE runs;")
    >>= either (fail . show) pure
