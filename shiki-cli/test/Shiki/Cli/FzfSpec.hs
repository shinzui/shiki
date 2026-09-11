-- | Tests for "Shiki.Cli.Fzf". 'runFzf' is exercised end to end against a
--   generated fake @fzf@ shell script: the script records its arguments and
--   stdin next to itself, then runs a per-test body that plays back an exit
--   code and a chosen line. No terminal is needed.
module Shiki.Cli.FzfSpec
  ( tests,
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Shiki.Cli.Fzf
  ( Candidate (..),
    FzfConfig (..),
    FzfResult (..),
    isFzfAvailable,
    runFzf,
    withHeaderRow,
    withSelectOne,
  )
import System.Directory (doesFileExist, getPermissions, setOwnerExecutable, setPermissions)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase)

tests :: TestTree
tests =
  testGroup
    "Shiki.Cli.Fzf"
    [ testCase "runFzf returns the line fzf printed" $
        withFakeFzf "sed -n 2p \"$dir/stdin\"" $ \cfg _ -> do
          r <- runFzf cfg mempty candidates
          assertEqual "picked" (FzfSelected "worker") r,
      testCase "exit 1 is FzfNoMatch" $
        withFakeFzf "exit 1" $ \cfg _ -> do
          r <- runFzf cfg mempty candidates
          assertEqual "no match" FzfNoMatch r,
      testCase "exit 130 is FzfCancelled" $
        withFakeFzf "exit 130" $ \cfg _ -> do
          r <- runFzf cfg mempty candidates
          assertEqual "cancelled" FzfCancelled r,
      testCase "any other exit code is FzfError" $
        withFakeFzf "exit 2" $ \cfg _ -> do
          r <- runFzf cfg mempty candidates
          assertEqual "error" (FzfError "fzf exited with code 2") r,
      testCase "an unparseable line is FzfError" $
        withFakeFzf "echo nonsense" $ \cfg _ -> do
          r <- runFzf cfg mempty candidates
          assertEqual "error" (FzfError "fzf returned no parseable index") r,
      testCase "a missing binary is a spawn failure" $ do
        r <- runFzf (fakeConfig "/nonexistent/fzf") mempty candidates
        case r of
          FzfError e ->
            assertBool
              ("expected a spawn failure, got: " <> Text.unpack e)
              ("fzf spawn failed" `Text.isPrefixOf` e)
          other -> assertBool ("expected FzfError, got: " <> show other) False,
      testCase "an empty candidate list never spawns fzf" $
        withFakeFzf "exit 0" $ \cfg dir -> do
          r <- runFzf cfg mempty ([] :: [Candidate Text])
          assertEqual "no match" FzfNoMatch r
          spawned <- doesFileExist (dir </> "args")
          assertBool "fzf must not run" (not spawned),
      testCase "withSelectOne passes -1" $
        withFakeFzf "exit 130" $ \cfg dir -> do
          _ <- runFzf cfg withSelectOne candidates
          args <- argsOf dir
          assertBool ("-1 expected in " <> show args) ("-1" `elem` args),
      testCase "mempty does not pass -1" $
        withFakeFzf "exit 130" $ \cfg dir -> do
          _ <- runFzf cfg mempty candidates
          args <- argsOf dir
          assertBool ("-1 unexpected in " <> show args) ("-1" `notElem` args),
      testCase "withHeaderRow sends the titles first with --header-lines=1" $
        withFakeFzf "sed -n 3p \"$dir/stdin\"" $ \cfg dir -> do
          r <- runFzf cfg (withHeaderRow "NAME") candidates
          assertEqual "picked" (FzfSelected "worker") r
          input <- readFile (dir </> "stdin")
          assertEqual "first stdin line" (Just "-\tNAME") (headMay (lines input))
          args <- argsOf dir
          assertBool
            ("--header-lines=1 expected in " <> show args)
            ("--header-lines=1" `elem` args),
      testCase "isFzfAvailable needs both the binary and /dev/tty" $ do
        let cfg a t = FzfConfig {binary = "fzf", available = a, ttyAvailable = t}
        assertEqual
          "truth table"
          [True, False, False, False]
          [isFzfAvailable (cfg a t) | (a, t) <- [(True, True), (True, False), (False, True), (False, False)]]
    ]

candidates :: [Candidate Text]
candidates =
  [ Candidate {display = "ingest", value = "ingest"},
    Candidate {display = "worker", value = "worker"}
  ]

fakeConfig :: FilePath -> FzfConfig
fakeConfig path = FzfConfig {binary = path, available = True, ttyAvailable = True}

-- | Write a fake @fzf@ into a fresh temporary directory. The script saves
--   its arguments (one per line) to @args@ and its stdin to @stdin@ beside
--   itself, then runs @body@ with @$dir@ bound to that directory.
withFakeFzf :: String -> (FzfConfig -> FilePath -> IO a) -> IO a
withFakeFzf body k =
  withSystemTempDirectory "fake-fzf" $ \dir -> do
    let script = dir </> "fzf"
    writeFile script $
      unlines
        [ "#!/bin/sh",
          "dir=$(dirname \"$0\")",
          "printf '%s\\n' \"$@\" > \"$dir/args\"",
          "cat > \"$dir/stdin\"",
          body
        ]
    perms <- getPermissions script
    setPermissions script (setOwnerExecutable True perms)
    k (fakeConfig script) dir

argsOf :: FilePath -> IO [String]
argsOf dir = lines <$> readFile (dir </> "args")

headMay :: [a] -> Maybe a
headMay = \case
  [] -> Nothing
  x : _ -> Just x
