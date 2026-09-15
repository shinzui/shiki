module Shiki.Cli.EnvRoutingSpec (tests) where

import Control.Exception (bracket)
import Data.Aeson qualified as Aeson
import Data.Text qualified as Text
import Effectful (Eff, IOE, runEff)
import Effectful.Error.Static (Error, runErrorNoCallStack)
import EphemeralPg qualified as EpPg
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (Statement)
import Shiki.Cli.Config (resolveConnectionString)
import Shiki.Error (ConfigError (..), ShikiError (..))
import Shiki.Persistence.Connection
  ( ConnectionString (..),
    acquirePool,
    releasePool,
  )
import Shiki.Persistence.Migration (renderMigrationFailure, runMigrations)
import Shiki.Persistence.Run
  ( NewRun (..),
    RunRecord,
    insertRunStatement,
    listRecentRunsStatement,
    newRunId,
  )
import Shiki.Persistence.Schema (Schema, defaultSchema)
import Shiki.Prelude
import System.Directory (getCurrentDirectory, setCurrentDirectory)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertEqual, testCase)

tests :: TestTree
tests =
  testGroup
    "Shiki.Cli.EnvRouting"
    [ testCase "staging run is stored in staging database and absent from prod" $
        withCleanEnvAndCwd $
          withTwoDatabases $ \stagingConn prodConn ->
            withSystemTempDirectory "shiki-env-routing" $ \tmp -> do
              writeFile (tmp <> "/shiki.dhall") (projectConfig stagingConn prodConn)
              withCurrentDirectory' tmp $ do
                resolvedStaging <- resolveOrFail Nothing (Just "staging")
                resolvedProd <- resolveOrFail Nothing (Just "prod")
                assertEqual "staging URL" stagingConn resolvedStaging
                assertEqual "prod URL" prodConn resolvedProd

                withMigratedPool stagingConn $ \stagingPool ->
                  withMigratedPool prodConn $ \prodPool -> do
                    now <- getCurrentTime
                    rid <- newRunId
                    useStmt
                      stagingPool
                      insertRunStatement
                      NewRun
                        { runId = rid,
                          serviceName = "mls-service-v2",
                          command = ["subscription", "process"],
                          namespace = "staging",
                          jobName = "mls-service-v2-oneoff",
                          image = Nothing,
                          startedAt = now,
                          serviceConfig = Aeson.object []
                        }

                    stagingRows <- useStmt' stagingPool listRecentRunsStatement (10 :: Int)
                    prodRows <- useStmt' prodPool listRecentRunsStatement (10 :: Int)
                    assertEqual "one staging row" 1 (length (stagingRows :: [RunRecord]))
                    assertEqual "no prod rows" 0 (length (prodRows :: [RunRecord])),
      testCase "legacy fallback, missing source error, and db flag override" $
        withCleanEnvAndCwd $
          withSystemTempDirectory "shiki-env-fallback" $ \tmp ->
            withCurrentDirectory' tmp $ do
              setEnv "SHIKI_DATABASE_URL" "postgresql://legacy/fallback"
              fallback <- resolveOrFail Nothing Nothing
              assertEqual
                "SHIKI_DATABASE_URL fallback"
                (ConnectionString "postgresql://legacy/fallback")
                fallback

              unsetEnv "SHIKI_DATABASE_URL"
              unsetEnv "PG_CONNECTION_STRING"
              missing <- runResolver (resolveConnectionString Nothing Nothing)
              assertEqual
                "a missing source is a typed error, not an exception"
                (Left (ShikiConfigError NoConnectionString))
                missing

              writeFile
                (tmp <> "/shiki.dhall")
                (projectConfig (ConnectionString "postgresql://config/staging") (ConnectionString "postgresql://config/prod"))
              override <- resolveOrFail (Just "postgresql://flag/override") (Just "prod")
              assertEqual
                "--db override"
                (ConnectionString "postgresql://flag/override")
                override
    ]

-- | Run a resolver to its 'Either', the way 'Shiki.Cli.Main.runShikiMain'
--   does, so the test sees the typed error rather than an exception.
runResolver :: Eff '[Error ShikiError, IOE] a -> IO (Either ShikiError a)
runResolver action = runEff (runErrorNoCallStack @ShikiError action)

resolveOrFail :: Maybe Text -> Maybe Text -> IO ConnectionString
resolveOrFail mDb mEnv =
  runResolver (resolveConnectionString mDb mEnv)
    >>= either (fail . show) pure

withTwoDatabases :: (ConnectionString -> ConnectionString -> IO ()) -> IO ()
withTwoDatabases action = do
  result <- EpPg.with $ \staging ->
    EpPg.with $ \prod ->
      action
        (ConnectionString (EpPg.connectionString staging))
        (ConnectionString (EpPg.connectionString prod))
  case result of
    Left err ->
      fail ("ephemeral-pg failed to start staging database: " <> show (EpPg.renderStartError err))
    Right (Left err) ->
      fail ("ephemeral-pg failed to start prod database: " <> show (EpPg.renderStartError err))
    Right (Right ()) ->
      pure ()

withMigratedPool :: ConnectionString -> (Pool.Pool -> IO a) -> IO a
withMigratedPool conn action =
  bracket
    (acquirePool conn defaultSchema)
    releasePool
    (\pool -> migrateOrFail conn defaultSchema *> action pool)

useStmt :: Pool.Pool -> Statement a () -> a -> IO ()
useStmt pool stmt input =
  Pool.use pool (Session.statement input stmt) >>= either (fail . show) pure

useStmt' :: Pool.Pool -> Statement a b -> a -> IO b
useStmt' pool stmt input =
  Pool.use pool (Session.statement input stmt) >>= either (fail . show) pure

projectConfig :: ConnectionString -> ConnectionString -> String
projectConfig (ConnectionString stagingUrl) (ConnectionString prodUrl) =
  Text.unpack $
    Text.unlines
      [ "{ environments =",
        "    [ { mapKey = \"staging\"",
        "      , mapValue = { databaseUrl = \"" <> stagingUrl <> "\" }",
        "      }",
        "    , { mapKey = \"prod\"",
        "      , mapValue = { databaseUrl = \"" <> prodUrl <> "\" }",
        "      }",
        "    ]",
        ", defaultEnvironment = \"staging\"",
        "}"
      ]

withCurrentDirectory' :: FilePath -> IO a -> IO a
withCurrentDirectory' dir body =
  bracket getCurrentDirectory setCurrentDirectory $ \_ -> do
    setCurrentDirectory dir
    body

withCleanEnvAndCwd :: IO a -> IO a
withCleanEnvAndCwd body =
  bracket snapshot restore $ \_ -> do
    unsetEnv "SHIKI_ENV"
    unsetEnv "SHIKI_DATABASE_URL"
    unsetEnv "PG_CONNECTION_STRING"
    body
  where
    snapshot = do
      cwd <- getCurrentDirectory
      shikiEnv <- lookupEnv "SHIKI_ENV"
      dbUrl <- lookupEnv "SHIKI_DATABASE_URL"
      pgConn <- lookupEnv "PG_CONNECTION_STRING"
      pure (cwd, shikiEnv, dbUrl, pgConn)
    restore (cwd, shikiEnv, dbUrl, pgConn) = do
      setCurrentDirectory cwd
      restoreOne "SHIKI_ENV" shikiEnv
      restoreOne "SHIKI_DATABASE_URL" dbUrl
      restoreOne "PG_CONNECTION_STRING" pgConn
    restoreOne name = \case
      Just v -> setEnv name v
      Nothing -> unsetEnv name

-- | 'runMigrations' where the test expects success.
migrateOrFail :: ConnectionString -> Schema -> IO ()
migrateOrFail cs schema =
  runMigrations cs schema
    >>= either (fail . Text.unpack . renderMigrationFailure) pure
