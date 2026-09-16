-- | A typed snapshot of \"what shiki knows right now\" that the
--   @shiki agent assist@ prompt renderer in "Shiki.Cli.Agent.Prompt"
--   consumes. The gatherer is best-effort: a missing @services\/@
--   directory, a broken Dhall file, or a database error all surface as
--   data on 'AgentContext' rather than exceptions, so the operator can
--   still see what *did* work.
module Shiki.Cli.Agent.Context
  ( ServiceSummary (..),
    AgentContext (..),
    gatherAgentContext,
    analyzerBackendToText,
  )
where

import Data.Generics.Labels ()
import Data.List (sort)
import Data.Text qualified as Text
import Effectful (Eff, IOE, type (:>))
import Effectful.Error.Static (Error, catchError)
import Effectful.Exception qualified as Exc
import Shiki.Effect.RunStore (RunStore, databaseNow, listRecentRuns)
import Shiki.Error (ShikiError, shikiErrorMessage)
import Shiki.Persistence.Run (RunRecord)
import Shiki.Persistence.Schema (Schema, schemaText)
import Shiki.Prelude
import Shiki.Service.Config
  ( AnalyzerBackend (..),
    ServiceConfig,
    ServiceName (..),
  )
import Shiki.Service.Config.Dhall qualified as ServiceDhall
import System.Directory
  ( doesDirectoryExist,
    getCurrentDirectory,
    listDirectory,
  )
import System.FilePath (takeExtension, (</>))

-- | A trimmed view of one @services\/\<name\>.dhall@ entry. The prompt
--   only needs the name, default namespace, and the textual rendering of
--   the analyzer backend.
data ServiceSummary = ServiceSummary
  { name :: !Text,
    defaultNamespace :: !Text,
    analyzer :: !Text
  }
  deriving stock (Generic, Eq, Show)

-- | Snapshot of the operator's local state at session-start time.
data AgentContext = AgentContext
  { cwd :: !Text,
    servicesDir :: !FilePath,
    services :: ![ServiceSummary],
    serviceLoadErrors :: ![FilePath],
    recentRuns :: ![RunRecord],
    observedAt :: !(Maybe UTCTime),
    schemaName :: !Text,
    cluster :: !Text
  }
  deriving stock (Generic, Eq, Show)

-- | Render the Dhall-facing 'AnalyzerBackend' as one short textual tag,
--   matching the @--analyzer=...@ vocabulary the operator already knows
--   from @shiki runs analyze@.
analyzerBackendToText :: AnalyzerBackend -> Text
analyzerBackendToText = \case
  Heuristic -> "heuristic"
  Baikai {model = m} -> "baikai:" <> m
  None -> "none"

-- | Build an 'AgentContext' from the current working directory, the
--   shiki Postgres pool, and the resolved 'Schema'. Best-effort: failures
--   land on the record rather than as exceptions.
gatherAgentContext ::
  (RunStore :> es, IOE :> es, Error ShikiError :> es) =>
  Schema ->
  Eff es AgentContext
gatherAgentContext schema = do
  cwdStr <- liftIO getCurrentDirectory
  let servicesPath = "services"
  (services, serviceErrs) <- loadServicesDir servicesPath
  (mObservedAt, runs, dbErrs) <- loadRecentRuns
  pure
    AgentContext
      { cwd = Text.pack cwdStr,
        servicesDir = servicesPath,
        services,
        serviceLoadErrors = serviceErrs <> dbErrs,
        recentRuns = runs,
        observedAt = mObservedAt,
        schemaName = schemaText schema,
        cluster = "unknown"
      }

-- | Enumerate @services/*.dhall@, parsing each one through
--   'loadServiceConfig'. Files that fail to parse are returned in the
--   second list. A missing services directory is not an error.
loadServicesDir ::
  (IOE :> es) =>
  FilePath ->
  Eff es ([ServiceSummary], [FilePath])
loadServicesDir dir = do
  exists <- liftIO (doesDirectoryExist dir)
  if not exists
    then pure ([], [])
    else do
      entries <- liftIO (listDirectory dir)
      let dhallFiles = sort [dir </> e | e <- entries, takeExtension e == ".dhall"]
      foldr step (pure ([], [])) dhallFiles
  where
    -- 'trySync', not 'try': a file that does not parse belongs in the error
    -- list, but a Ctrl-C part way through the scan must still end the command.
    step path acc = do
      (svcs, errs) <- acc
      Exc.trySync (liftIO (ServiceDhall.loadServiceConfig path)) >>= \case
        Right cfg -> pure (toSummary cfg : svcs, errs)
        Left _ -> pure (svcs, path : errs)

toSummary :: ServiceConfig -> ServiceSummary
toSummary cfg =
  ServiceSummary
    { name = unServiceName (cfg ^. #name),
      defaultNamespace = cfg ^. #defaultNamespace,
      analyzer = analyzerBackendToText (cfg ^. #analyzer)
    }

-- | Read the most recent twenty rows. Database failures collapse to an
--   empty list plus one @"db: ..."@ entry in the error log: this context is
--   best-effort, so a broken store must not stop the agent session. Both a
--   typed 'ShikiError' from the interpreter and a stray exception are caught.
--
--   'catchError', not a nested @runErrorNoCallStack@: the 'RunStore'
--   interpreter was installed further out and throws to the handler in scope
--   /there/, so a fresh inner handler would never see a store failure and the
--   best-effort promise would not hold.
loadRecentRuns ::
  (RunStore :> es, Error ShikiError :> es) =>
  Eff es (Maybe UTCTime, [RunRecord], [FilePath])
loadRecentRuns = do
  outcome <-
    Exc.trySync $
      (Right <$> ((,) <$> databaseNow <*> listRecentRuns Nothing 20))
        `catchError` \_ e -> pure (Left (shikiErrorMessage e))
  pure $ case outcome of
    Right (Right (observedAtDb, rs)) -> (Just observedAtDb, rs, [])
    Right (Left message) -> (Nothing, [], ["db: " <> Text.unpack message])
    Left e -> (Nothing, [], ["db: " <> Exc.displayException e])
