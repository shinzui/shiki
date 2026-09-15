-- | One row of the @runs@ PostgreSQL table plus the typed hasql
--   'Statement' values used to insert, update, and read rows. EP-4
--   ('shiki run') and EP-5 ('shiki runs list\/show\/logs') consume the
--   statements exported here verbatim; new fields belong in a fresh
--   migration under @shiki-core\/sql\/migrations\/@, not in ad-hoc SQL
--   on the consumer side.
module Shiki.Persistence.Run
  ( -- * Identifier
    RunId (..),
    newRunId,

    -- * Records
    RunRecord (..),
    NewRun (..),
    RunCompletion (..),

    -- * Statements
    insertRunStatement,
    markRunRunningStatement,
    completeRunStatement,
    completeUnfinishedRunStatement,
    updateErrorSummaryStatement,
    touchRunWatchedStatement,
    databaseNowStatement,
    getRunStatement,
    listRecentRunsStatement,
    listRecentRunsByServiceStatement,
    findRunByPrefixStatement,
    listUnfinishedRunsStatement,
  )
where

import Data.Aeson qualified as Aeson
import Data.Functor.Contravariant ((>$<))
import Data.Generics.Labels ()
import Data.UUID (UUID)
import Data.UUID.V4 qualified as UUIDv4
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Statement (Statement, preparable)
import Shiki.Persistence.RunStatus
  ( RunStatus (Pending),
    runStatusFromText,
    runStatusToText,
  )
import Shiki.Prelude

newtype RunId = RunId {unRunId :: UUID}
  deriving stock (Generic, Eq, Ord, Show)
  deriving newtype (FromJSON, ToJSON)

newRunId :: IO RunId
newRunId = RunId <$> UUIDv4.nextRandom

-- | One row of @runs@. The @serviceConfig@ column holds the JSON
--   snapshot of the 'Shiki.Service.Config.ServiceConfig' that was used
--   when the run was submitted, so a later operator can reconstruct
--   what the CLI saw at submission time.
data RunRecord = RunRecord
  { runId :: !RunId,
    serviceName :: !Text,
    command :: ![Text],
    namespace :: !Text,
    jobName :: !Text,
    image :: !(Maybe Text),
    status :: !RunStatus,
    exitCode :: !(Maybe Int),
    startedAt :: !UTCTime,
    endedAt :: !(Maybe UTCTime),
    durationMs :: !(Maybe Int),
    logTail :: !(Maybe Text),
    serviceConfig :: !Aeson.Value,
    errorMessage :: !(Maybe Text),
    errorSummary :: !(Maybe Text),
    errorSummarySource :: !Text,
    lastWatchedAt :: !(Maybe UTCTime)
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

-- | The fields the CLI knows at submit time: identifier, command,
--   namespace, derived job name, the image discovered from the live
--   Deployment, the wall-clock start time, and the JSON-encoded service
--   config. Status is always 'Pending' immediately after insert.
data NewRun = NewRun
  { runId :: !RunId,
    serviceName :: !Text,
    command :: ![Text],
    namespace :: !Text,
    jobName :: !Text,
    image :: !(Maybe Text),
    startedAt :: !UTCTime,
    serviceConfig :: !Aeson.Value
  }
  deriving stock (Generic, Eq, Show)

-- | The fields the CLI learns at completion time. 'durationMs' is the
--   wall-clock duration in milliseconds; 'logTail' is a truncated tail
--   of the Job pod's logs (the writer must enforce a sane byte cap, see
--   the MasterPlan).
data RunCompletion = RunCompletion
  { runId :: !RunId,
    status :: !RunStatus,
    exitCode :: !(Maybe Int),
    endedAt :: !UTCTime,
    durationMs :: !Int,
    logTail :: !(Maybe Text),
    errorMessage :: !(Maybe Text),
    errorSummary :: !(Maybe Text),
    errorSummarySource :: !Text
  }
  deriving stock (Generic, Eq, Show)

-- ── Statements ─────────────────────────────────────────────────────────────

-- | INSERT a freshly created run in 'Pending' status.
insertRunStatement :: Statement NewRun ()
insertRunStatement = preparable sql encoder Decoders.noResult
  where
    sql =
      """
      INSERT INTO runs
        ( id, service_name, command, namespace, job_name
        , image, status, started_at, service_config )
      VALUES
        ( $1, $2, $3, $4, $5, $6, $7, $8, $9 )
      """
    encoder =
      ((\r -> unRunId (r ^. #runId)) >$< uuidParam)
        <> ((^. #serviceName) >$< textParam)
        <> ((^. #command) >$< textArrayParam)
        <> ((^. #namespace) >$< textParam)
        <> ((^. #jobName) >$< textParam)
        <> ((^. #image) >$< nullableTextParam)
        <> (const Pending >$< runStatusParam)
        <> ((^. #startedAt) >$< utcTimeParam)
        <> ((^. #serviceConfig) >$< jsonbParam)

-- | Mark an existing run as 'Running'.
markRunRunningStatement :: Statement RunId ()
markRunRunningStatement = preparable sql encoder Decoders.noResult
  where
    sql =
      """
      UPDATE runs
         SET status     = 'running',
             updated_at = now()
       WHERE id = $1
      """
    encoder = unRunId >$< uuidParam

-- | Update an existing row with completion details.
completeRunStatement :: Statement RunCompletion ()
completeRunStatement = preparable completeRunSql runCompletionEncoder Decoders.noResult

-- | Like 'completeRunStatement', but only while the row is still
--   @pending@ or @running@; returns whether a row was updated. @shiki runs
--   sync@ writes through this so a reconcile never overwrites the outcome
--   a still-live @shiki run@ recorded first.
completeUnfinishedRunStatement :: Statement RunCompletion Bool
completeUnfinishedRunStatement =
  preparable
    (completeRunSql <> " AND status IN ('pending', 'running')")
    runCompletionEncoder
    ((> 0) <$> Decoders.rowsAffected)

completeRunSql :: Text
completeRunSql =
  """
  UPDATE runs
     SET status                = $2,
         exit_code             = $3,
         ended_at              = $4,
         duration_ms           = $5,
         log_tail              = $6,
         error                 = $7,
         error_summary         = $8,
         error_summary_source  = $9,
         updated_at            = now()
   WHERE id = $1
  """

runCompletionEncoder :: Encoders.Params RunCompletion
runCompletionEncoder =
  ((\r -> unRunId (r ^. #runId)) >$< uuidParam)
    <> ((^. #status) >$< runStatusParam)
    <> ((^. #exitCode) >$< nullableInt4Param)
    <> ((^. #endedAt) >$< utcTimeParam)
    <> ((^. #durationMs) >$< int8Param)
    <> ((^. #logTail) >$< nullableTextParam)
    <> ((^. #errorMessage) >$< nullableTextParam)
    <> ((^. #errorSummary) >$< nullableTextParam)
    <> ((^. #errorSummarySource) >$< textParam)

-- | Overwrite the analyzer fields on an existing row. The post-hoc
--   @shiki runs analyze@ subcommand writes through this rather than
--   touching 'completeRunStatement' so the rest of the row stays intact.
updateErrorSummaryStatement :: Statement (RunId, Maybe Text, Text) ()
updateErrorSummaryStatement = preparable sql encoder Decoders.noResult
  where
    sql =
      """
      UPDATE runs
         SET error_summary        = $2,
             error_summary_source = $3,
             updated_at           = now()
       WHERE id = $1
      """
    encoder =
      ((\(rid, _, _) -> unRunId rid) >$< uuidParam)
        <> ((\(_, s, _) -> s) >$< nullableTextParam)
        <> ((\(_, _, src) -> src) >$< textParam)

-- | Record that a waiting @shiki run@ process is still alive. Completed
--   rows are deliberately ignored, and @updated_at@ continues to mean the
--   last meaningful state change rather than the last liveness signal.
touchRunWatchedStatement :: Statement RunId ()
touchRunWatchedStatement = preparable sql encoder Decoders.noResult
  where
    sql =
      """
      UPDATE runs
         SET last_watched_at = now()
       WHERE id = $1
         AND status IN ('pending', 'running')
      """
    encoder = unRunId >$< uuidParam

-- | Read PostgreSQL's current timestamp so heartbeat age is compared with
--   the same clock that writes 'touchRunWatchedStatement'.
databaseNowStatement :: Statement () UTCTime
databaseNowStatement =
  preparable
    "SELECT now()"
    Encoders.noParams
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.timestamptz)))

runColumnsSql :: Text
runColumnsSql =
  """
  id, service_name, command, namespace, job_name,
  image, status, exit_code, started_at, ended_at,
  duration_ms, log_tail, service_config, error,
  error_summary, error_summary_source, last_watched_at
  """

-- | Look up a single run by id.
getRunStatement :: Statement RunId (Maybe RunRecord)
getRunStatement = preparable sql encoder decoder
  where
    sql = "SELECT " <> runColumnsSql <> " FROM runs WHERE id = $1"
    encoder = unRunId >$< uuidParam
    decoder = Decoders.rowMaybe runRecordRow

-- | List the most recent N runs, newest first.
listRecentRunsStatement :: Statement Int [RunRecord]
listRecentRunsStatement = preparable sql encoder decoder
  where
    sql =
      "SELECT "
        <> runColumnsSql
        <> " FROM runs ORDER BY started_at DESC LIMIT $1"
    encoder = int8Param
    decoder = Decoders.rowList runRecordRow

-- | List the most recent N runs for a single service, newest first.
listRecentRunsByServiceStatement :: Statement (Text, Int) [RunRecord]
listRecentRunsByServiceStatement = preparable sql encoder decoder
  where
    sql =
      "SELECT "
        <> runColumnsSql
        <> " FROM runs WHERE service_name = $1 ORDER BY started_at DESC LIMIT $2"
    encoder =
      (fst >$< textParam)
        <> (snd >$< int8Param)
    decoder = Decoders.rowList runRecordRow

-- | Find rows whose @id@ starts with the given prefix. Returns at most
--   two rows so the caller can tell \"unique\" from \"ambiguous\" without
--   pulling the whole table on degenerate input (e.g. an empty prefix).
findRunByPrefixStatement :: Statement Text [RunRecord]
findRunByPrefixStatement = preparable sql encoder decoder
  where
    sql =
      "SELECT "
        <> runColumnsSql
        <> " FROM runs WHERE id::text LIKE $1 || '%' LIMIT 2"
    encoder = textParam
    decoder = Decoders.rowList runRecordRow

-- | Every run still @pending@ or @running@, oldest first: the candidates
--   @shiki runs sync@ reconciles against the cluster.
listUnfinishedRunsStatement :: Statement () [RunRecord]
listUnfinishedRunsStatement = preparable sql Encoders.noParams decoder
  where
    sql =
      "SELECT "
        <> runColumnsSql
        <> " FROM runs WHERE status IN ('pending', 'running') ORDER BY started_at ASC"
    decoder = Decoders.rowList runRecordRow

-- ── Internal parameter / row helpers ───────────────────────────────────────

uuidParam :: Encoders.Params UUID
uuidParam = Encoders.param (Encoders.nonNullable Encoders.uuid)

textParam :: Encoders.Params Text
textParam = Encoders.param (Encoders.nonNullable Encoders.text)

nullableTextParam :: Encoders.Params (Maybe Text)
nullableTextParam = Encoders.param (Encoders.nullable Encoders.text)

utcTimeParam :: Encoders.Params UTCTime
utcTimeParam = Encoders.param (Encoders.nonNullable Encoders.timestamptz)

nullableInt4Param :: Encoders.Params (Maybe Int)
nullableInt4Param =
  Encoders.param (Encoders.nullable (fromIntegral >$< Encoders.int4))

int8Param :: Encoders.Params Int
int8Param =
  Encoders.param (Encoders.nonNullable (fromIntegral >$< Encoders.int8))

textArrayParam :: Encoders.Params [Text]
textArrayParam =
  Encoders.param $
    Encoders.nonNullable $
      Encoders.array $
        Encoders.dimension foldl' $
          Encoders.element (Encoders.nonNullable Encoders.text)

runStatusParam :: Encoders.Params RunStatus
runStatusParam =
  Encoders.param
    (Encoders.nonNullable (runStatusToText >$< Encoders.text))

jsonbParam :: Encoders.Params Aeson.Value
jsonbParam = Encoders.param (Encoders.nonNullable Encoders.jsonb)

runRecordRow :: Decoders.Row RunRecord
runRecordRow =
  RunRecord
    <$> (RunId <$> Decoders.column (Decoders.nonNullable Decoders.uuid))
    <*> Decoders.column (Decoders.nonNullable Decoders.text)
    <*> Decoders.column (Decoders.nonNullable textArrayDecoder)
    <*> Decoders.column (Decoders.nonNullable Decoders.text)
    <*> Decoders.column (Decoders.nonNullable Decoders.text)
    <*> Decoders.column (Decoders.nullable Decoders.text)
    <*> Decoders.column (Decoders.nonNullable runStatusDecoder)
    <*> ( fmap fromIntegral
            <$> Decoders.column (Decoders.nullable Decoders.int4)
        )
    <*> Decoders.column (Decoders.nonNullable Decoders.timestamptz)
    <*> Decoders.column (Decoders.nullable Decoders.timestamptz)
    <*> ( fmap fromIntegral
            <$> Decoders.column (Decoders.nullable Decoders.int8)
        )
    <*> Decoders.column (Decoders.nullable Decoders.text)
    <*> Decoders.column (Decoders.nonNullable Decoders.jsonb)
    <*> Decoders.column (Decoders.nullable Decoders.text)
    <*> Decoders.column (Decoders.nullable Decoders.text)
    <*> Decoders.column (Decoders.nonNullable Decoders.text)
    <*> Decoders.column (Decoders.nullable Decoders.timestamptz)

textArrayDecoder :: Decoders.Value [Text]
textArrayDecoder =
  Decoders.array $
    Decoders.dimension replicateM $
      Decoders.element (Decoders.nonNullable Decoders.text)
  where
    -- The plan calls for @replicateM@ but the prelude does not re-export it.
    -- Use a local recursive replicate-via-applicative which is what
    -- 'Control.Monad.replicateM' would do for any 'Monad'.
    replicateM :: (Monad m) => Int -> m a -> m [a]
    replicateM n action
      | n <= 0 = pure []
      | otherwise = (:) <$> action <*> replicateM (n - 1) action

runStatusDecoder :: Decoders.Value RunStatus
runStatusDecoder = Decoders.refine runStatusFromText Decoders.text
