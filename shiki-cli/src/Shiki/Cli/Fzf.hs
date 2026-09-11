-- | Core abstraction for invoking @fzf@ as a subprocess from shiki.
--
--   Detection happens once per CLI invocation ('detectFzfConfig'); the
--   resulting 'FzfConfig' is threaded through 'Shiki.Cli.Env.CliEnv' so
--   each handler sees the same snapshot. 'runFzf' is the only function
--   that actually spawns @fzf@: callers build a list of 'Candidate'
--   values and a 'FzfOpts' bundle, get back a 'FzfResult'.
--
--   The interface deliberately stays narrow — single-select with hidden
--   index column, no preview, no expect-keys. Selector modules
--   ("Shiki.Cli.Fzf.Selector.*") layer on top.
module Shiki.Cli.Fzf
  ( -- * Detection
    FzfConfig (..),
    detectFzfConfig,
    isFzfAvailable,

    -- * Options (Monoid)
    FzfOpts (..),
    withPrompt,
    withHeader,
    withHeight,
    withAnsi,
    withNoSort,

    -- * Selection
    Candidate (..),
    FzfResult (..),
    runFzf,
  )
where

import Control.Exception (SomeException, try)
import Data.Generics.Labels ()
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Text.Read qualified as TextRead
import Shiki.Prelude
import System.Directory (findExecutable)
import System.Exit (ExitCode (..))
import System.IO
  ( BufferMode (..),
    IOMode (..),
    hClose,
    hGetContents,
    hIsTerminalDevice,
    hPutStr,
    hSetBuffering,
    openFile,
    stdin,
    stdout,
  )
import System.Process
  ( CreateProcess (..),
    StdStream (..),
    createProcess,
    proc,
    waitForProcess,
  )

-- | A snapshot of the local fzf availability captured once per CLI
--   invocation. @binary@ is the resolved absolute path to the binary
--   if it was found on @PATH@, or the literal @\"fzf\"@ if not (still
--   recorded for diagnostics; @available@ is the source of truth).
data FzfConfig = FzfConfig
  { binary :: !FilePath,
    available :: !Bool,
    stdinIsTerminal :: !Bool,
    stdoutIsTerminal :: !Bool,
    ttyAvailable :: !Bool
  }
  deriving stock (Generic, Eq, Show)

-- | Probe the operator environment: look for @fzf@ on @PATH@, check
--   whether stdin and stdout are terminal devices, and try to open
--   @\/dev\/tty@ as a fallback for piped invocations.
detectFzfConfig :: IO FzfConfig
detectFzfConfig = do
  mPath <- findExecutable "fzf"
  inTty <- hIsTerminalDevice stdin
  outTty <- hIsTerminalDevice stdout
  ttyOk <- probeTty
  pure
    FzfConfig
      { binary = fromMaybe "fzf" mPath,
        available = isJust mPath,
        stdinIsTerminal = inTty,
        stdoutIsTerminal = outTty,
        ttyAvailable = ttyOk
      }
  where
    probeTty :: IO Bool
    probeTty = do
      r <- try @SomeException (openFile "/dev/tty" ReadMode >>= hClose)
      pure (either (const False) (const True) r)

-- | @True@ when the binary exists AND we can deliver an interactive
--   keyboard somehow (real stdin terminal or a usable @\/dev\/tty@).
isFzfAvailable :: FzfConfig -> Bool
isFzfAvailable cfg =
  cfg ^. #available && (cfg ^. #stdinIsTerminal || cfg ^. #ttyAvailable)

-- | Right-biased option bundle; combine via @<>@ in caller modules.
data FzfOpts = FzfOpts
  { prompt :: !(Maybe Text),
    header :: !(Maybe Text),
    height :: !(Maybe Text),
    ansi :: !Bool,
    noSort :: !Bool
  }
  deriving stock (Generic, Eq, Show)

instance Semigroup FzfOpts where
  a <> b =
    FzfOpts
      { prompt = b ^. #prompt <|> a ^. #prompt,
        header = b ^. #header <|> a ^. #header,
        height = b ^. #height <|> a ^. #height,
        ansi = a ^. #ansi || b ^. #ansi,
        noSort = a ^. #noSort || b ^. #noSort
      }

instance Monoid FzfOpts where
  mempty =
    FzfOpts
      { prompt = Nothing,
        header = Nothing,
        height = Nothing,
        ansi = False,
        noSort = False
      }

withPrompt :: Text -> FzfOpts
withPrompt t = mempty & #prompt ?~ t

withHeader :: Text -> FzfOpts
withHeader t = mempty & #header ?~ t

withHeight :: Text -> FzfOpts
withHeight t = mempty & #height ?~ t

withAnsi :: FzfOpts
withAnsi = mempty & #ansi .~ True

withNoSort :: FzfOpts
withNoSort = mempty & #noSort .~ True

-- | One row presented to the operator. @display@ is what fzf
--   shows; @value@ is the value handed back to the caller when
--   the row is chosen.
data Candidate a = Candidate
  { display :: !Text,
    value :: !a
  }
  deriving stock (Generic, Functor)

-- | The four states fzf invocation can land in.
data FzfResult a
  = FzfSelected !a
  | FzfNoMatch
  | FzfCancelled
  | FzfError !Text
  deriving stock (Functor)

-- | Spawn fzf and let the operator pick one candidate.
--
--   Implementation notes:
--
--   * Each candidate is fed to fzf as @\"<index>\\t<display>\"@; we pass
--     @--with-nth=2..@ so the index column is hidden but used to look
--     the value back up.
--   * @delegate_ctlc = True@ on the 'CreateProcess' so Ctrl-C reaches
--     fzf (exit 130 → 'FzfCancelled') instead of killing shiki.
--   * @std_err = Inherit@ so fzf's TUI renders to the terminal.
--   * @std_out@ is piped, read lazily via 'hGetContents', then
--     'waitForProcess' forces the read.
--   * Empty candidate list short-circuits to 'FzfNoMatch' so we never
--     spawn fzf with no input.
--   * 'isFzfAvailable' is checked defensively; callers should have
--     gated on it already.
runFzf :: FzfConfig -> FzfOpts -> [Candidate a] -> IO (FzfResult a)
runFzf cfg opts candidates
  | null candidates = pure FzfNoMatch
  | not (isFzfAvailable cfg) = pure (FzfError "fzf not available")
  | otherwise = do
      let numbered = zip [0 :: Int ..] candidates
          valueByIndex = Map.fromList [(i, c ^. #value) | (i, c) <- numbered]
          stdinPayload =
            Text.unlines
              [ Text.pack (show i) <> "\t" <> c ^. #display
              | (i, c) <- numbered
              ]
          args = ["-1", "--with-nth=2.."] <> optsToArgs opts
          cp =
            (proc (cfg ^. #binary) args)
              { std_in = CreatePipe,
                std_out = CreatePipe,
                std_err = Inherit,
                delegate_ctlc = True
              }
      r <- try @SomeException $ do
        (Just hin, Just hout, _, ph) <- createProcess cp
        hSetBuffering hin NoBuffering
        hPutStr hin (Text.unpack stdinPayload)
        hClose hin
        out <- hGetContents hout
        ec <- waitForProcess ph
        pure (ec, out)
      case r of
        Left e -> pure (FzfError (Text.pack ("fzf spawn failed: " <> show e)))
        Right (ec, out) -> pure (interpretExit valueByIndex ec out)
  where
    interpretExit :: Map Int a -> ExitCode -> String -> FzfResult a
    interpretExit valueByIndex ec out =
      case ec of
        ExitSuccess -> case parsePicked (Text.pack out) of
          Just i -> case Map.lookup i valueByIndex of
            Just v -> FzfSelected v
            Nothing -> FzfError ("fzf returned unknown index " <> Text.pack (show i))
          Nothing -> FzfError "fzf returned no parseable index"
        ExitFailure 1 -> FzfNoMatch
        ExitFailure 130 -> FzfCancelled
        ExitFailure n -> FzfError ("fzf exited with code " <> Text.pack (show n))

    parsePicked :: Text -> Maybe Int
    parsePicked raw =
      let firstLine = Text.takeWhile (/= '\n') raw
          idxField = Text.takeWhile (/= '\t') firstLine
       in case TextRead.decimal idxField of
            Right (n, _) -> Just n
            Left _ -> Nothing

optsToArgs :: FzfOpts -> [String]
optsToArgs o =
  concat
    [ maybe [] (\t -> ["--prompt", Text.unpack t]) (o ^. #prompt),
      maybe [] (\t -> ["--header", Text.unpack t]) (o ^. #header),
      maybe [] (\t -> ["--height", Text.unpack t]) (o ^. #height),
      ["--ansi" | o ^. #ansi],
      ["--no-sort" | o ^. #noSort]
    ]
