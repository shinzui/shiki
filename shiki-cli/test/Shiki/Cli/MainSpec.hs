-- | The six outcomes 'runShikiMain' has to distinguish, and the exact line
--   each 'ShikiError' constructor renders as.
module Shiki.Cli.MainSpec (tests) where

import Control.Exception qualified as E
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TIO
import Effectful (Eff, liftIO)
import Effectful.Error.Static (throwError)
import Effectful.Exception (evaluate)
import Shiki.Analysis.Backend (AnalyzerError (..))
import Shiki.Cli.Error (CliError (..))
import Shiki.Cli.Main (CliEff, runShikiMain)
import Shiki.Error
  ( ConfigError (..),
    KubeError (..),
    ShikiError (..),
    StoreError (..),
    renderShikiError,
  )
import System.Exit (ExitCode (..), exitWith)
import System.IO (Handle, IOMode (ReadMode), hClose, withFile)
import System.IO.Temp (withSystemTempFile)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase)

tests :: TestTree
tests =
  testGroup
    "Shiki.Cli.Main"
    [ testCase "success exits 0 and prints nothing" $ do
        (out, code) <- capture (pure ())
        assertEqual "exit code" ExitSuccess code
        assertEqual "stderr" "" out,
      testCase "a core error prints its rendered line and exits 1" $ do
        (out, code) <- capture (throwError (ShikiConfigError NoConnectionString))
        assertEqual "exit code" (ExitFailure 1) code
        assertEqual
          "stderr"
          (renderShikiError (ShikiConfigError NoConnectionString) <> "\n")
          out,
      testCase "a CLI error the handler already reported prints nothing" $ do
        (out, code) <- capture (throwError CommandFailed)
        assertEqual "exit code" (ExitFailure 1) code
        assertEqual "stderr" "" out,
      testCase "a deliberate exit code passes through" $ do
        (out, code) <- capture (liftIO (exitWith (ExitFailure 7)))
        assertEqual "exit code" (ExitFailure 7) code
        assertEqual "stderr" "" out,
      testCase "an unclassified exception becomes one 'unexpected error' line" $ do
        (out, code) <- capture (evaluate (error "boom" :: ()))
        assertEqual "exit code" (ExitFailure 1) code
        assertEqual "stderr" "shiki: unexpected error: boom\n" out
        assertBool "no backtrace" (not ("HasCallStack" `Text.isInfixOf` out)),
      testCase "Ctrl-C escapes the handler" $ do
        caught <-
          E.try @E.AsyncException $
            withSystemTempFile "shiki-main-interrupt" $ \_ h ->
              runShikiMain h (liftIO (E.throwIO E.UserInterrupt))
        case caught of
          Left E.UserInterrupt -> pure ()
          Left other -> assertFailure ("unexpected async exception: " <> show other)
          Right code -> assertFailure ("interrupt was swallowed, got " <> show code),
      testCase "every ShikiError constructor renders its documented line" $
        mapM_
          (\(err, expected) -> assertEqual (Text.unpack expected) expected (renderShikiError err))
          renderTable
    ]

-- | Every 'ShikiError' constructor and the one line it prints.
renderTable :: [(ShikiError, Text)]
renderTable =
  [ ( ShikiConfigError NoConnectionString,
      "shiki: no Postgres connection string; pass --db, add a shiki.dhall, \
      \or set SHIKI_DATABASE_URL / PG_CONNECTION_STRING"
    ),
    ( ShikiConfigError (InvalidSchemaName "must match [A-Za-z_][A-Za-z0-9_]*"),
      "shiki: invalid schema name: must match [A-Za-z_][A-Za-z0-9_]*"
    ),
    ( ShikiConfigError (UndeclaredEnvironment "typo" "/w/shiki.dhall" ["dev", "prod"]),
      "shiki: environment typo is not declared in /w/shiki.dhall (declared: dev, prod)"
    ),
    ( ShikiConfigError (ProjectConfigInvalid "shiki.dhall" "unexpected token"),
      "shiki: cannot load shiki.dhall: unexpected token"
    ),
    ( ShikiConfigError (ServiceConfigNotFound "services/ingest.dhall"),
      "shiki: no service config at services/ingest.dhall"
    ),
    ( ShikiConfigError (ServiceConfigInvalid "services/ingest.dhall" "unexpected token"),
      "shiki: cannot load services/ingest.dhall: unexpected token"
    ),
    ( ShikiStoreError (DatabaseUnavailable "Connection refused"),
      "shiki: cannot connect to the database: Connection refused"
    ),
    ( ShikiStoreError (MigrationFailed "shiki" "pg-migrate execution failed"),
      "shiki: migration failed for schema shiki: pg-migrate execution failed"
    ),
    ( ShikiStoreError (StatementFailed "list recent runs" "relation does not exist"),
      "shiki: database error during list recent runs: relation does not exist"
    ),
    ( ShikiKubeError (KubeConfigUnavailable "/nonexistent: does not exist"),
      "shiki: cannot load the Kubernetes config: /nonexistent: does not exist"
    ),
    ( ShikiKubeError (KubeCredentialFailed "aws exited with 1"),
      "shiki: Kubernetes credential plugin failed: aws exited with 1"
    ),
    ( ShikiKubeError (DeploymentInspectionFailed "ingest" "not found"),
      "shiki: cannot inspect deployment ingest: not found"
    ),
    ( ShikiKubeError (KubeRequestFailed "submit job" "403 Forbidden"),
      "shiki: Kubernetes request failed during submit job: 403 Forbidden"
    ),
    ( ShikiAnalyzerError AnalyzerBackendDisabled,
      "shiki: analyzer disabled (backend = None)"
    ),
    ( ShikiAnalyzerError (AnalyzerUnknown "baikai:nope"),
      "shiki: unknown analyzer override: baikai:nope"
    ),
    ( ShikiAnalyzerError (AnalyzerBaikaiError "no API key"),
      "shiki: baikai backend failed: no API key"
    )
  ]

-- | Run an action through 'runShikiMain' with its handle pointed at a
--   temporary file, and return what it wrote alongside the exit code.
capture :: Eff CliEff () -> IO (Text, ExitCode)
capture action =
  withSystemTempFile "shiki-main" $ \path h -> do
    code <- runShikiMain h action
    hClose h
    contents <- withFile path ReadMode readAll
    pure (contents, code)
  where
    readAll :: Handle -> IO Text
    readAll r = do
      t <- TIO.hGetContents r
      Text.length t `seq` pure t
