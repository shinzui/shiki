module Shiki.Cli.Agent.ContextSpec
  ( tests
  ) where

import Shiki.Cli.Agent.Context
  ( AgentContext (..)
  , ServiceSummary (..)
  , gatherAgentContext
  )

import Shiki.Persistence.Connection
  ( ConnectionString (..)
  , acquirePool
  , releasePool
  )
import Shiki.Persistence.Migration (runMigrations)
import Shiki.Persistence.Run
  ( NewRun (..)
  , RunCompletion (..)
  , completeRunStatement
  , insertRunStatement
  , newRunId
  )
import Shiki.Persistence.RunStatus (RunStatus (Succeeded))
import Shiki.Persistence.Schema (Schema, defaultSchema, mkSchema)

import "aeson" Data.Aeson qualified as Aeson
import "base" Control.Exception (bracket)
import "directory" System.Directory
  ( createDirectory
  , withCurrentDirectory
  )
import "temporary" System.IO.Temp (withSystemTempDirectory)
import "ephemeral-pg" EphemeralPg qualified as EpPg
import "filepath" System.FilePath ((</>))
import "hasql-pool" Hasql.Pool (Pool)
import "hasql-pool" Hasql.Pool qualified as Pool
import "hasql" Hasql.Session qualified as Session
import "hasql" Hasql.Statement (Statement)
import "tasty" Test.Tasty (DependencyType (..), TestTree, sequentialTestGroup)
import "tasty-hunit" Test.Tasty.HUnit (assertBool, assertEqual, testCase)
import "time" Data.Time (getCurrentTime)
import "text" Data.Text qualified as Text
import "uuid" Data.UUID qualified as UUID
import "uuid" Data.UUID.V4 qualified as UUIDv4

tests :: TestTree
tests =
  sequentialTestGroup
    "Shiki.Cli.Agent.Context"
    AllSucceed
    [ testCase "loads good services, records bad ones, sees DB rows" $
        withSchemaPool $ \pool ->
          withSystemTempDirectory "shiki-context-spec" $ \tmp -> do
            let svcDir = tmp </> "services"
            createDirectory svcDir
            writeFile (svcDir </> "foo.dhall") (Text.unpack fooDhall)
            writeFile (svcDir </> "bad.dhall") "this is not dhall"

            now <- getCurrentTime
            rid <- newRunId
            useStmt pool insertRunStatement
              NewRun
                { runId         = rid
                , serviceName   = "foo"
                , command       = ["echo", "hi"]
                , namespace     = "default"
                , jobName       = "foo-oneoff"
                , image         = Nothing
                , startedAt     = now
                , serviceConfig = Aeson.object []
                }
            useStmt pool completeRunStatement
              RunCompletion
                { runId               = rid
                , status              = Succeeded
                , exitCode            = Just 0
                , endedAt             = now
                , durationMs          = 5
                , logTail             = Just "ok\n"
                , errorMessage        = Nothing
                , errorSummary        = Nothing
                , errorSummarySource  = "heuristic"
                }

            ctx <- withCurrentDirectory tmp $
              gatherAgentContext pool defaultSchema

            case services ctx of
              [svc] -> do
                assertEqual "good service name" "foo" (name svc)
                assertEqual "good service analyzer" "heuristic" (analyzer svc)
              other ->
                fail ("expected exactly one service, got: " <> show other)
            assertBool "bad service path in errors"
              (any (\p -> "bad.dhall" `Text.isSuffixOf` Text.pack p)
                (serviceLoadErrors ctx))
            assertEqual "one recent run" 1 (length (recentRuns ctx))
            assertEqual "schema name" "shiki" (schemaName ctx)
            assertEqual "cluster placeholder" "unknown" (cluster ctx)
    , testCase "missing services/ dir is not an error" $
        withSchemaPool $ \pool ->
          withSystemTempDirectory "shiki-context-empty" $ \tmp -> do
            ctx <- withCurrentDirectory tmp $
              gatherAgentContext pool defaultSchema
            assertEqual "no services" [] (services ctx)
            assertEqual "no errors" [] (serviceLoadErrors ctx)
    ]

-- | A minimal Dhall record that satisfies 'ServiceConfig'. Inlined
--   rather than reading the repo's @services/@ so the test does not
--   depend on the repo's services-dir path resolving from the tmp dir.
fooDhall :: Text.Text
fooDhall =
  Text.unlines
    [ "let EnvSource ="
    , "      < ConfigMap : { key : Text }"
    , "      | Secret : { key : Text }"
    , "      | Literal : { value : Text }"
    , "      >"
    , ""
    , "let AnalyzerBackend ="
    , "      < Heuristic | Baikai : { model : Text } | None >"
    , ""
    , "in  { name = \"foo\""
    , "    , defaultNamespace = \"default\""
    , "    , detectFromDeployment = \"foo\""
    , "    , containerName = \"foo\""
    , "    , commandPath = \"/foo\""
    , "    , serviceAccount = \"foo\""
    , "    , nodeSelector = toMap {=} : List { mapKey : Text, mapValue : Text }"
    , "    , initContainers ="
    , "        [] : List"
    , "          { name : Text"
    , "          , image : Text"
    , "          , args : List Text"
    , "          , env : List { name : Text, source : EnvSource }"
    , "          , resources :"
    , "              { cpuRequest : Text"
    , "              , cpuLimit : Text"
    , "              , memoryRequest : Text"
    , "              , memoryLimit : Text"
    , "              }"
    , "          , restartable : Bool"
    , "          }"
    , "    , env = [] : List { name : Text, source : EnvSource }"
    , "    , resources ="
    , "        { cpuRequest = \"100m\""
    , "        , cpuLimit = \"500m\""
    , "        , memoryRequest = \"128Mi\""
    , "        , memoryLimit = \"256Mi\""
    , "        }"
    , "    , analyzer = AnalyzerBackend.Heuristic"
    , "    }"
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
    Left e  -> error ("freshSchema: unexpectedly invalid schema: " <> Text.unpack e)

withSchemaPool :: (Pool -> IO ()) -> IO ()
withSchemaPool action = do
  schema <- freshSchema
  result <- EpPg.with $ \db ->
    bracket
      (acquirePool (ConnectionString (EpPg.connectionString db)) schema)
      releasePool
      (\pool -> runMigrations pool schema *> action pool)
  case result of
    Right () -> pure ()
    Left err ->
      fail ("ephemeral-pg failed to start: " <> show (EpPg.renderStartError err))
