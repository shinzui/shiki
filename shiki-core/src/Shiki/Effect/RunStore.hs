{-# LANGUAGE TypeFamilies #-}

-- | Everything shiki does to the @runs@ table, as one effect.
--
--   An /effect/ here is a named capability a function lists in its type. A
--   handler written as @(RunStore :> es) => … -> Eff es a@ says "this code may
--   read and write run rows" and, just as importantly, says nothing else: it
--   cannot open a file, shell out, or talk to the cluster. An /interpreter/
--   gives the effect meaning; "Shiki.Effect.RunStore.Postgres" is the one
--   production uses, and a test can supply an in-memory one instead.
--
--   The operations are deliberately high-level — one per thing shiki does to
--   the table — rather than a generic "run any hasql session". That is what
--   effectful's own documentation recommends, and it is what makes the
--   interpreter swappable: no caller mentions hasql, a pool, or SQL.
module Shiki.Effect.RunStore
  ( RunStore (..),
    insertRun,
    markRunRunning,
    completeRun,
    completeUnfinishedRun,
    updateErrorSummary,
    touchRunWatched,
    databaseNow,
    listRecentRuns,
    findRunsByPrefix,
    listUnfinishedRuns,
    getRun,
  )
where

import Effectful (Dispatch (Dynamic), DispatchOf, Eff, Effect, type (:>))
import Effectful.Dispatch.Dynamic (send)
import Shiki.Persistence.Run (NewRun, RunCompletion, RunId, RunRecord)
import Shiki.Prelude

data RunStore :: Effect where
  InsertRun :: NewRun -> RunStore m ()
  MarkRunRunning :: RunId -> RunStore m ()
  CompleteRun :: RunCompletion -> RunStore m ()
  -- | 'True' when a row was still unfinished and this call completed it.
  CompleteUnfinishedRun :: RunCompletion -> RunStore m Bool
  -- | run, summary (or 'Nothing' for none), the source tag to record
  UpdateErrorSummary :: RunId -> Maybe Text -> Text -> RunStore m ()
  TouchRunWatched :: RunId -> RunStore m ()
  -- | @now()@ as the database sees it, so liveness is judged on one clock
  DatabaseNow :: RunStore m UTCTime
  -- | optional service filter, row limit
  ListRecentRuns :: Maybe Text -> Int -> RunStore m [RunRecord]
  -- | at most two rows: enough to tell a unique prefix from an ambiguous one
  FindRunsByPrefix :: Text -> RunStore m [RunRecord]
  ListUnfinishedRuns :: RunStore m [RunRecord]
  GetRun :: RunId -> RunStore m (Maybe RunRecord)

type instance DispatchOf RunStore = Dynamic

insertRun :: (RunStore :> es) => NewRun -> Eff es ()
insertRun = send . InsertRun

markRunRunning :: (RunStore :> es) => RunId -> Eff es ()
markRunRunning = send . MarkRunRunning

completeRun :: (RunStore :> es) => RunCompletion -> Eff es ()
completeRun = send . CompleteRun

completeUnfinishedRun :: (RunStore :> es) => RunCompletion -> Eff es Bool
completeUnfinishedRun = send . CompleteUnfinishedRun

updateErrorSummary :: (RunStore :> es) => RunId -> Maybe Text -> Text -> Eff es ()
updateErrorSummary rid summary source = send (UpdateErrorSummary rid summary source)

touchRunWatched :: (RunStore :> es) => RunId -> Eff es ()
touchRunWatched = send . TouchRunWatched

databaseNow :: (RunStore :> es) => Eff es UTCTime
databaseNow = send DatabaseNow

listRecentRuns :: (RunStore :> es) => Maybe Text -> Int -> Eff es [RunRecord]
listRecentRuns mService limit = send (ListRecentRuns mService limit)

findRunsByPrefix :: (RunStore :> es) => Text -> Eff es [RunRecord]
findRunsByPrefix = send . FindRunsByPrefix

listUnfinishedRuns :: (RunStore :> es) => Eff es [RunRecord]
listUnfinishedRuns = send ListUnfinishedRuns

getRun :: (RunStore :> es) => RunId -> Eff es (Maybe RunRecord)
getRun = send . GetRun
