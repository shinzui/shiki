-- | Exercise the installed command, real Kubernetes client, and migrating store.
module Shiki.Cli.DestinationSpec (tests) where

import Control.Exception (bracket)
import Control.Monad (forM_)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as BL
import Data.List (isInfixOf, isPrefixOf)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import EphemeralPg qualified as Pg
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (preparable)
import Shiki.Cli.ClusterFixture (Cluster, kubeconfig, requests, tokenUser, withCluster)
import Shiki.Cli.EnvRoutingSpec (withEphemeralPg)
import Shiki.Cli.Fixtures (minimalServiceDhall)
import Shiki.Persistence.Connection
import Shiki.Persistence.Migration (migrationsDirectory)
import Shiki.Persistence.Schema (defaultSchema)
import Shiki.Service.Config.Dhall (loadServiceConfig)
import System.Directory (createDirectory, removeFile)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (CreateProcess (cwd, env), proc, readCreateProcessWithExitCode)
import System.Timeout (timeout)
import Test.Tasty (TestTree)
import Test.Tasty.HUnit

tests :: TestTree
tests = testCase "submit, inspect history and reconcile across two Kubernetes contexts" $
  withCluster "local-token" $ \local -> withCluster "prod-token" $ \prod ->
    withSystemTempDirectory "shiki-destination" $ \dir -> do
      result <- withEphemeralPg $ \db -> do
        let url = Pg.connectionString db
        bracket (acquirePool (ConnectionString url) defaultSchema) releasePool $ \pool -> do
          exercise dir url pool local prod
      either (assertFailure . show) pure result

exercise :: FilePath -> Text -> Pool.Pool -> Cluster -> Cluster -> IO ()
exercise dir url pool local prod = do
  let config = dir </> "config"
      project = dir </> "shiki.dhall"
      localEntry = ("local", local, tokenUser "local-token")
      both = kubeconfig [localEntry, ("sennari", prod, tokenUser "prod-token")]
      withoutProd = BL.writeFile config (kubeconfig [localEntry])
      serviceDir = dir </> "services"
      submit args = ["run", "worker"] <> args <> ["--", "check"]
      prodArgs = ["--env", "prod"]
      dbArgs = ["--db", T.unpack url]
  outer <- getEnvironment
  let vars = [("KUBECONFIG", config), ("SHIKI_DATABASE_URL", T.unpack url), ("SHIKI_DB_SCHEMA", "shiki")]
      cli args = do
        let cmd = (proc "shiki" args) {cwd = Just dir, env = Just (vars <> filter (\(k, _) -> k /= "SHIKI_ENV" && k `notElem` map fst vars) outer)}
        timeout 30000000 (readCreateProcessWithExitCode cmd "") >>= maybe (assertFailure ("timeout: " <> show args)) pure
      success args = do
        (code, out, err) <- cli args
        assertEqual (show args <> "\n" <> err <> out) ExitSuccess code
        pure out
      submitIn flags opts dest result = do
        out <- success (flags <> submit opts)
        case lines out of
          [announcement, outcome] -> do
            announcement @?= dest
            assertBool outcome (result `isPrefixOf` outcome)
            pure outcome
          _ -> assertFailure ("unexpected submission output: " <> out)
      showRow rid = do
        out <- success ["runs", "show", rid]
        case Aeson.eitherDecodeStrict (TE.encodeUtf8 (T.pack out)) of
          Right (Aeson.Object fields) -> pure fields
          _ -> assertFailure ("invalid run JSON: " <> out)
      checkRow rid envValue ctx status = do
        fields <- showRow rid
        KeyMap.lookup "environment" fields @?= Just envValue
        KeyMap.lookup "kubernetesContext" fields @?= Just ctx
        KeyMap.lookup "status" fields @?= Just status
      detachedRun flags dest = do
        outcome <- submitIn flags ["--no-wait"] dest "submitted job "
        case words outcome of
          ["submitted", "job", name, "(run", rid]
            | Just ident <- T.stripSuffix ")" (T.pack rid) ->
                pure (T.unpack ident, T.pack name)
          _ -> assertFailure ("unexpected detached outcome: " <> outcome)
      paths cluster = map (\(method, path, _) -> (method, path)) <$> requests cluster
      deployment ns = ("GET", ["apis", "apps", "v1", "namespaces", ns, "deployments", "worker"])
      jobs ns = ("POST", ["apis", "batch", "v1", "namespaces", ns, "jobs"])
  createDirectory serviceDir
  TIO.writeFile (serviceDir </> "worker.dhall") (T.replace "\"default\"" "\"ops\"" (minimalServiceDhall "worker"))
  let envRecord binding = "{ databaseUrl = " <> T.pack (show (T.unpack url)) <> binding <> " }"
      configText bound =
        "{ environments = toMap { prod = "
          <> envRecord (if bound then ", kubernetesContext = Some \"sennari\"" else "")
          <> ", staging = "
          <> envRecord (if bound then ", kubernetesContext = None Text" else "")
          <> " }, defaultEnvironment = \"staging\" }"
  TIO.writeFile project (configText True)
  prepareOldStore pool (serviceDir </> "worker.dhall")
  withoutProd
  forM_ [[], dbArgs] $ \override -> do
    cli (override <> prodArgs <> submit ["--no-wait"])
      >>= (@?= (ExitFailure 1, "", "shiki: environment prod declares missing Kubernetes context sennari\n"))
  sql
    pool
    """
    DO $$ BEGIN
      IF (SELECT count(*) FROM runs) <> 1 OR to_regclass('shiki.migrations') IS NOT NULL THEN
        RAISE EXCEPTION 'missing context touched the store';
      END IF;
    END $$;
    """
  requests local >>= (@?= [])
  requests prod >>= (@?= [])

  BL.writeFile config both
  (prodId, prodJob) <- detachedRun prodArgs "environment=prod context=sennari namespace=ops"
  paths local >>= (@?= [])
  paths prod >>= (@?= [deployment "ops", jobs "ops"])
  waited <- submitIn (dbArgs <> prodArgs) ["--namespace", "qa"] "environment=prod context=sennari namespace=qa" "run "
  (waitId, waitJob) <- case words waited of
    ["run", rid, "Succeeded", job] | Just name <- T.stripPrefix "job=" (T.pack job) -> pure (rid, name)
    _ -> assertFailure ("unexpected wait outcome: " <> waited)
  let statusPath ns name = ("GET", ["apis", "batch", "v1", "namespaces", ns, "jobs", name, "status"])
      logs ns = [("GET", ["api", "v1", "namespaces", ns, "pods"]), ("GET", ["api", "v1", "namespaces", ns, "pods", "worker-pod", "log"])]
  paths prod >>= (@?= [deployment "ops", jobs "ops", deployment "qa", jobs "qa", statusPath "qa" waitJob] <> logs "qa")
  paths local >>= (@?= [])
  BL.readFile config >>= (@?= both)

  (stagingId, stagingJob) <- detachedRun [] "environment=staging context=local namespace=ops"
  paths local >>= (@?= [deployment "ops", jobs "ops"])
  writeFile config "unusable"
  table <- success ["runs", "list"]
  let listed rid pair = case filter (isPrefixOf (take 8 rid)) (lines table) of
        [line] -> assertEqual line pair (take 2 (drop 4 (words line)))
        rows -> assertFailure ("expected one listed run: " <> show rows)
  listed prodId ["prod", "sennari"]
  listed stagingId ["staging", "local"]
  listed oldId ["-", "-"]
  checkRow prodId "prod" "sennari" "Running"
  checkRow stagingId "staging" "local" "Running"
  checkRow waitId "prod" "sennari" "Succeeded"
  checkRow oldId Aeson.Null Aeson.Null "Running"

  -- Removing one context must leave its row unfinished while bulk sync
  -- continues to the rows on the other server, including the pre-004 row.
  withoutProd
  (syncCode, _, err) <- cli ["runs", "sync"]
  syncCode @?= ExitFailure 1
  assertBool err (("run " <> take 8 prodId <> ": sync failed: missing Kubernetes context sennari") `isInfixOf` err)
  checkRow prodId "prod" "sennari" "Running"
  checkRow stagingId "staging" "local" "Succeeded"
  checkRow oldId Aeson.Null Aeson.Null "Failed"
  localPaths <- paths local
  assertBool (show localPaths) (statusPath "ops" stagingJob `elem` localPaths && statusPath "ops" "old-job" `elem` localPaths)
  assertBool "missing context contacted local for prod job" (statusPath "ops" prodJob `notElem` localPaths)

  BL.writeFile config both
  _ <- success ["runs", "sync", prodId]
  checkRow prodId "prod" "sennari" "Succeeded"
  paths local >>= (@?= localPaths)
  prodPaths <- paths prod
  assertBool (show prodPaths) (statusPath "ops" prodJob `elem` prodPaths)

  TIO.writeFile project (configText False)
  (legacyId, _) <- detachedRun [] "environment=staging context=local namespace=ops"
  checkRow legacyId "staging" "local" "Running"
  removeFile project
  (outsideId, _) <- detachedRun [] "environment=- context=local namespace=ops"
  checkRow outsideId Aeson.Null "local" "Running"

oldId :: String
oldId = "12345678-0000-0000-0000-000000000001"

-- | Recreate a database left by the released three-migration binary.
prepareOldStore :: Pool.Pool -> FilePath -> IO ()
prepareOldStore pool serviceFile = do
  dir <- migrationsDirectory
  sql pool "CREATE SCHEMA shiki; CREATE TABLE shiki.schema_migrations(filename text, checksum text, executed_at timestamp);"
  forM_ [("001-create-runs.sql", "7Hetr6wmYoX7OrfnnzmURg=="), ("002-add-error-summary.sql", "7hHk4MldKAU/1OSXG9HWGA=="), ("003-add-last-watched-at.sql", "OhHriiHjXU2+wmEZULMyRg==")] $ \(file, checksum) -> do
    TIO.readFile (dir </> file) >>= sql pool
    sql pool ("INSERT INTO schema_migrations VALUES ('" <> T.pack file <> "','" <> checksum <> "',clock_timestamp());")
  snapshot <- Aeson.toJSON <$> loadServiceConfig serviceFile
  let insertOld =
        preparable
          """
          INSERT INTO runs(id,service_name,command,namespace,job_name,status,started_at,service_config)
          VALUES ('12345678-0000-0000-0000-000000000001','worker','{check}','ops','old-job','running',now() - interval '1 day',$1)
          """
          (E.param (E.nonNullable E.jsonb))
          D.noResult
  Pool.use pool (Session.statement snapshot insertOld) >>= either (fail . show) pure

sql :: Pool.Pool -> Text -> IO ()
sql pool statement = Pool.use pool (Session.script statement) >>= either (fail . show) pure
