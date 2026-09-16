-- | An in-memory 'RunStore' for tests that must not reach PostgreSQL.
--
--   Rows come from an 'IORef', and the @shouldFail@ predicate picks which
--   operations answer with the typed 'StatementFailed' the PostgreSQL
--   interpreter would raise. That is how a command's behaviour on a broken
--   database is asserted without breaking one: @'runFakeRunStore' ref
--   (const False)@ is a healthy store, and @(== "find runs by prefix")@ fails
--   exactly the lookup while the rest of the command still works.
module Shiki.Cli.Effect.FakeRunStore
  ( FakeStore,
    newFakeStore,
    runFakeRunStore,
    recordedCompletions,
    healthy,
  )
where

import Data.Generics.Labels ()
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (find)
import Data.Text qualified as Text
import Data.Time qualified as Time
import Effectful (Eff, IOE, type (:>))
import Effectful.Dispatch.Dynamic (interpret_)
import Effectful.Error.Static (Error, throwError)
import Shiki.Effect.RunStore (RunStore (..))
import Shiki.Error (ShikiError (..), StoreError (..))
import Shiki.Persistence.Run (RunCompletion, RunId (..), RunRecord)
import Shiki.Prelude

-- | No operation fails.
healthy :: Text -> Bool
healthy = const False

-- | The rows the fake answers from, and the completions written to it. The
--   second is what proves a command did /not/ finalize a run: after Ctrl-C
--   during @shiki run@ it must stay empty.
data FakeStore = FakeStore
  { rows :: !(IORef [RunRecord]),
    completions :: !(IORef [RunCompletion])
  }
  deriving stock (Generic)

newFakeStore :: [RunRecord] -> IO FakeStore
newFakeStore initialRows =
  FakeStore <$> newIORef initialRows <*> newIORef []

-- | Every 'CompleteRun' and 'CompleteUnfinishedRun' the action wrote, oldest
--   first.
recordedCompletions :: FakeStore -> IO [RunCompletion]
recordedCompletions store = reverse <$> readIORef (completions store)

runFakeRunStore ::
  forall es a.
  (IOE :> es, Error ShikiError :> es) =>
  FakeStore ->
  -- | which operation names fail
  (Text -> Bool) ->
  Eff (RunStore : es) a ->
  Eff es a
runFakeRunStore store shouldFail = interpret_ $ \case
  InsertRun _ -> guardFailure "insert run" (pure ())
  MarkRunRunning _ -> guardFailure "mark run running" (pure ())
  CompleteRun completion -> guardFailure "complete run" (record completion)
  CompleteUnfinishedRun completion ->
    guardFailure "complete unfinished run" (record completion >> pure True)
  UpdateErrorSummary _ _ _ -> guardFailure "update error summary" (pure ())
  TouchRunWatched _ -> guardFailure "record run heartbeat" (pure ())
  DatabaseNow -> guardFailure "read the database clock" (pure epoch)
  ListRecentRuns mService limit ->
    guardFailure "list recent runs" $
      take limit . maybe id (\s -> filter ((== s) . view #serviceName)) mService <$> rows
  FindRunsByPrefix prefix ->
    guardFailure "find runs by prefix" $
      take 2 . filter ((prefix `Text.isPrefixOf`) . runIdText . view #runId) <$> rows
  ListUnfinishedRuns -> guardFailure "list unfinished runs" rows
  GetRun rid -> guardFailure "get run" (find ((== rid) . view #runId) <$> rows)
  where
    rows :: Eff es [RunRecord]
    rows = liftIO (readIORef (store ^. #rows))

    record :: RunCompletion -> Eff es ()
    record completion =
      liftIO (modifyIORef' (store ^. #completions) (completion :))

    guardFailure :: Text -> Eff es b -> Eff es b
    guardFailure operation answer
      | shouldFail operation =
          throwError
            ( ShikiStoreError
                (StatementFailed operation "relation \"runs\" does not exist")
            )
      | otherwise = answer

runIdText :: RunId -> Text
runIdText (RunId u) = Text.pack (show u)

epoch :: UTCTime
epoch = Time.UTCTime (Time.fromGregorian 2026 5 27) 0
