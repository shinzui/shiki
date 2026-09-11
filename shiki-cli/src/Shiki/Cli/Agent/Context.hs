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

import Shiki.Persistence.Run
  ( RunRecord,
    listRecentRunsStatement,
  )
import Shiki.Persistence.Schema (Schema, schemaText)
import Shiki.Prelude
import Shiki.Service.Config
  ( AnalyzerBackend (..),
    ServiceConfig,
    ServiceName (..),
  )
import Shiki.Service.Config.Dhall (loadServiceConfig)
import "base" Control.Exception (SomeException, try)
import "base" Data.List (sort)
import "directory" System.Directory
  ( doesDirectoryExist,
    getCurrentDirectory,
    listDirectory,
  )
import "filepath" System.FilePath (takeExtension, (</>))
import "hasql" Hasql.Session qualified as Session
import "hasql-pool" Hasql.Pool (Pool)
import "hasql-pool" Hasql.Pool qualified as Pool
import "text" Data.Text qualified as Text

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
gatherAgentContext :: Pool -> Schema -> IO AgentContext
gatherAgentContext pool schema = do
  cwdStr <- getCurrentDirectory
  let servicesPath = "services"
  (services, serviceErrs) <- loadServicesDir servicesPath
  (runs, dbErrs) <- loadRecentRuns pool
  pure
    AgentContext
      { cwd = Text.pack cwdStr,
        servicesDir = servicesPath,
        services,
        serviceLoadErrors = serviceErrs <> dbErrs,
        recentRuns = runs,
        schemaName = schemaText schema,
        cluster = "unknown"
      }

-- | Enumerate @services/*.dhall@, parsing each one through
--   'loadServiceConfig'. Files that fail to parse are returned in the
--   second list. A missing services directory is not an error.
loadServicesDir :: FilePath -> IO ([ServiceSummary], [FilePath])
loadServicesDir dir = do
  exists <- doesDirectoryExist dir
  if not exists
    then pure ([], [])
    else do
      entries <- listDirectory dir
      let dhallFiles = sort [dir </> e | e <- entries, takeExtension e == ".dhall"]
      foldr step (pure ([], [])) dhallFiles
  where
    step path acc = do
      (svcs, errs) <- acc
      mCfg <- try @SomeException (loadServiceConfig path)
      case mCfg of
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
--   empty list plus one @"db: ..."@ entry in the error log.
loadRecentRuns :: Pool -> IO ([RunRecord], [FilePath])
loadRecentRuns pool = do
  result <- Pool.use pool (Session.statement 20 listRecentRunsStatement)
  pure $ case result of
    Right rs -> (rs, [])
    Left err -> ([], ["db: " <> show err])
