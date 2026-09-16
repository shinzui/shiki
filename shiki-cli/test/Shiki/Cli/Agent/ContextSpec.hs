module Shiki.Cli.Agent.ContextSpec
  ( tests,
  )
where

import Control.Exception (bracket)
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.List qualified as List
import Data.Maybe (isJust)
import Data.Text qualified as Text
import Data.Time (getCurrentTime)
import Data.UUID qualified as UUID
import Data.UUID.V4 qualified as UUIDv4
import Effectful (runEff)
import Effectful.Error.Static (runErrorNoCallStack)
import EphemeralPg qualified as EpPg
import Hasql.Pool (Pool)
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (Statement)
import Shiki.Cli.Agent.Context (AgentContext, gatherAgentContext)
import Shiki.Cli.Effect.FakeRunStore (newFakeStore, runFakeRunStore)
import Shiki.Cli.Fixtures (minimalServiceDhall)
import Shiki.Effect.RunStore.Postgres (runRunStorePostgres)
import Shiki.Error (ShikiError)
import Shiki.Persistence.Connection
  ( ConnectionString (..),
    acquirePool,
    releasePool,
  )
import Shiki.Persistence.Migration (renderMigrationFailure, runMigrations)
import Shiki.Persistence.Run
  ( NewRun (..),
    RunCompletion (..),
    completeRunStatement,
    insertRunStatement,
    newRunId,
  )
import Shiki.Persistence.RunStatus (RunStatus (Succeeded))
import Shiki.Persistence.Schema (Schema, defaultSchema, mkSchema)
import Shiki.Prelude ((^.))
import System.Directory
  ( createDirectory,
    withCurrentDirectory,
  )
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (DependencyType (..), TestTree, dependentTestGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase)

tests :: TestTree
tests =
  dependentTestGroup
    "Shiki.Cli.Agent.Context"
    AllSucceed
    [ testCase "loads good services, records bad ones, sees DB rows" $
        withSchemaPool $ \pool ->
          withSystemTempDirectory "shiki-context-spec" $ \tmp -> do
            let svcDir = tmp </> "services"
            createDirectory svcDir
            writeFile (svcDir </> "foo.dhall") (Text.unpack (minimalServiceDhall "foo"))
            writeFile (svcDir </> "bad.dhall") "this is not dhall"

            now <- getCurrentTime
            rid <- newRunId
            useStmt
              pool
              insertRunStatement
              NewRun
                { runId = rid,
                  serviceName = "foo",
                  command = ["echo", "hi"],
                  namespace = "default",
                  jobName = "foo-oneoff",
                  image = Nothing,
                  startedAt = now,
                  serviceConfig = Aeson.object []
                }
            useStmt
              pool
              completeRunStatement
              RunCompletion
                { runId = rid,
                  status = Succeeded,
                  exitCode = Just 0,
                  endedAt = now,
                  durationMs = 5,
                  logTail = Just "ok\n",
                  errorMessage = Nothing,
                  errorSummary = Nothing,
                  errorSummarySource = "heuristic"
                }

            ctx <-
              withCurrentDirectory tmp $
                gatherContext pool defaultSchema

            case ctx ^. #services of
              [svc] -> do
                assertEqual "good service name" "foo" (svc ^. #name)
                assertEqual "good service analyzer" "heuristic" (svc ^. #analyzer)
              other ->
                fail ("expected exactly one service, got: " <> show other)
            assertBool
              "bad service path in errors"
              ( any
                  (\p -> "bad.dhall" `Text.isSuffixOf` Text.pack p)
                  (ctx ^. #serviceLoadErrors)
              )
            assertEqual "one recent run" 1 (length (ctx ^. #recentRuns))
            assertBool "database observation time is present" (isJust (ctx ^. #observedAt))
            assertEqual "schema name" "shiki" (ctx ^. #schemaName)
            assertEqual "cluster placeholder" "unknown" (ctx ^. #cluster),
      testCase "missing services/ dir is not an error" $
        withSchemaPool $ \pool ->
          withSystemTempDirectory "shiki-context-empty" $ \tmp -> do
            ctx <-
              withCurrentDirectory tmp $
                gatherContext pool defaultSchema
            assertEqual "no services" [] (ctx ^. #services)
            assertEqual "no errors" [] (ctx ^. #serviceLoadErrors)
            assertBool "database observation time is present" (isJust (ctx ^. #observedAt)),
      -- The context is best-effort: a broken store must land on the record,
      -- not end the session. Regression: the store's interpreter throws to the
      -- handler that was in scope where it was installed, so the nested
      -- handler this used to rely on never saw the failure.
      testCase "a broken store lands in the error log, not as a failure" $
        withSystemTempDirectory "shiki-context-broken-db" $ \tmp -> do
          store <- newFakeStore []
          outcome <-
            withCurrentDirectory tmp
              . runEff
              . runErrorNoCallStack @ShikiError
              . runFakeRunStore store (const True)
              $ gatherAgentContext defaultSchema
          case outcome of
            Left err -> assertBool ("expected a context, got " <> show err) False
            Right ctx -> do
              assertEqual "no runs" [] (ctx ^. #recentRuns)
              assertEqual "no observation time" Nothing (ctx ^. #observedAt)
              assertBool
                ("the store failure is logged: " <> show (ctx ^. #serviceLoadErrors))
                (any (List.isPrefixOf "db: ") (ctx ^. #serviceLoadErrors))
    ]

useStmt :: Pool -> Statement a () -> a -> IO ()
useStmt pool stmt input =
  Pool.use pool (Session.statement input stmt) >>= either (fail . show) pure

-- ── Local ephemeral-pg harness (mirrors shiki-core/test TestPg) ──

freshSchema :: IO Schema
freshSchema = do
  u <- UUIDv4.nextRandom
  let raw = "shiki_cli_test_" <> Text.filter (/= '-') (UUID.toText u)
  case mkSchema raw of
    Right s -> pure s
    Left e -> error ("freshSchema: unexpectedly invalid schema: " <> Text.unpack e)

withSchemaPool :: (Pool -> IO ()) -> IO ()
withSchemaPool action = do
  schema <- freshSchema
  result <- EpPg.with $ \db ->
    bracket
      (acquirePool (ConnectionString (EpPg.connectionString db)) schema)
      releasePool
      ( \pool ->
          migrateOrFail (ConnectionString (EpPg.connectionString db)) schema *> action pool
      )
  case result of
    Right () -> pure ()
    Left err ->
      fail ("ephemeral-pg failed to start: " <> show (EpPg.renderStartError err))

-- | 'gatherAgentContext' through the PostgreSQL 'RunStore' interpreter. The
--   context is best-effort, so a store failure lands on the record rather
--   than as a 'Left'; a 'Left' here would be a bug in that promise.
gatherContext :: Pool -> Schema -> IO AgentContext
gatherContext pool schema =
  runEff (runErrorNoCallStack @ShikiError (runRunStorePostgres pool (gatherAgentContext schema)))
    >>= either (fail . show) pure

-- | 'runMigrations' where the test expects success.
migrateOrFail :: ConnectionString -> Schema -> IO ()
migrateOrFail cs schema =
  runMigrations cs schema
    >>= either (fail . Text.unpack . renderMigrationFailure) pure
