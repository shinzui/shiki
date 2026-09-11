-- | Core abstraction for invoking @fzf@ as a subprocess from shiki.
--
--   Detection happens per call site, only when a command actually needs a
--   picker ('detectFzfConfig'). 'runFzf' is the only function that
--   actually spawns @fzf@: callers build a list of 'Candidate' values and
--   a 'FzfOpts' bundle, get back a 'FzfResult'. Every flag beyond the
--   hidden index column is driven by 'FzfOpts'.
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
    withSelectOne,
    withHeaderRow,

    -- * Selection
    Candidate (..),
    FzfResult (..),
    runFzf,
  )
where

import Control.Exception (IOException, try)
import Data.Generics.Labels ()
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (maybeToList)
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
    hPutStr,
    hSetBuffering,
    openFile,
  )
import System.Process
  ( CreateProcess (..),
    StdStream (..),
    createProcess,
    proc,
    waitForProcess,
  )

-- | A snapshot of the local fzf availability. @binary@ is the resolved
--   absolute path to the binary if it was found on @PATH@, or the literal
--   @\"fzf\"@ if not (still recorded for diagnostics; @available@ is the
--   source of truth).
data FzfConfig = FzfConfig
  { binary :: !FilePath,
    available :: !Bool,
    ttyAvailable :: !Bool
  }
  deriving stock (Generic, Eq, Show)

-- | Probe the operator environment: look for @fzf@ on @PATH@ and try to
--   open @\/dev\/tty@, which is where fzf reads keys and draws its
--   interface.
detectFzfConfig :: IO FzfConfig
detectFzfConfig = do
  mPath <- findExecutable "fzf"
  ttyOk <- probeTty
  pure
    FzfConfig
      { binary = fromMaybe "fzf" mPath,
        available = isJust mPath,
        ttyAvailable = ttyOk
      }
  where
    probeTty :: IO Bool
    probeTty = do
      r <- try @IOException (openFile "/dev/tty" ReadMode >>= hClose)
      pure (either (const False) (const True) r)

-- | fzf reads keys from @\/dev\/tty@ (its stdin is our pipe), so it can run
--   exactly when the binary exists and @\/dev\/tty@ opens.
isFzfAvailable :: FzfConfig -> Bool
isFzfAvailable cfg = cfg ^. #available && cfg ^. #ttyAvailable

-- | Right-biased option bundle; combine via @<>@ in caller modules.
data FzfOpts = FzfOpts
  { prompt :: !(Maybe Text),
    header :: !(Maybe Text),
    height :: !(Maybe Text),
    ansi :: !Bool,
    noSort :: !Bool,
    selectOne :: !Bool,
    headerRow :: !(Maybe Text)
  }
  deriving stock (Generic, Eq, Show)

instance Semigroup FzfOpts where
  a <> b =
    FzfOpts
      { prompt = b ^. #prompt <|> a ^. #prompt,
        header = b ^. #header <|> a ^. #header,
        height = b ^. #height <|> a ^. #height,
        ansi = a ^. #ansi || b ^. #ansi,
        noSort = a ^. #noSort || b ^. #noSort,
        selectOne = a ^. #selectOne || b ^. #selectOne,
        headerRow = b ^. #headerRow <|> a ^. #headerRow
      }

instance Monoid FzfOpts where
  mempty =
    FzfOpts
      { prompt = Nothing,
        header = Nothing,
        height = Nothing,
        ansi = False,
        noSort = False,
        selectOne = False,
        headerRow = Nothing
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

-- | Accept the only candidate without drawing the picker (fzf's @-1@).
withSelectOne :: FzfOpts
withSelectOne = mempty & #selectOne .~ True

-- | A line of column titles shown above the candidates. It is sent as the
--   first input line and marked with @--header-lines=1@, so fzf renders it
--   through the same @--with-nth@ as the rows and never returns it.
withHeaderRow :: Text -> FzfOpts
withHeaderRow t = mempty & #headerRow ?~ t

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
  deriving stock (Eq, Show, Functor)

-- | Spawn fzf and let the operator pick one candidate.
--
--   Implementation notes:
--
--   * Each candidate is fed to fzf as @\"<index>\\t<display>\"@; we pass
--     @--with-nth=2..@ so the index column is hidden but used to look
--     the value back up. A header row, when set, is sent first as
--     @\"-\\t<titles>\"@ with @--header-lines=1@; fzf never prints a
--     header line, so its unparseable index cannot come back.
--   * @delegate_ctlc = True@ on the 'CreateProcess' so Ctrl-C reaches
--     fzf (exit 130 → 'FzfCancelled') instead of killing shiki.
--   * fzf draws on and reads keys from the terminal via @\/dev\/tty@;
--     @std_err = Inherit@ only lets fzf's own error messages through.
--   * @std_out@ is piped, read lazily via 'hGetContents', then
--     'waitForProcess' forces the read.
--   * Empty candidate list short-circuits to 'FzfNoMatch' so we never
--     spawn fzf with no input.
--   * 'isFzfAvailable' is checked defensively; callers should have
--     gated on it already.
--   * Only 'IOException' (spawn failure, broken pipe) becomes 'FzfError';
--     asynchronous exceptions such as @UserInterrupt@ propagate.
runFzf :: FzfConfig -> FzfOpts -> [Candidate a] -> IO (FzfResult a)
runFzf cfg opts candidates
  | null candidates = pure FzfNoMatch
  | not (isFzfAvailable cfg) = pure (FzfError "fzf not available")
  | otherwise = do
      let numbered = zip [0 :: Int ..] candidates
          valueByIndex = Map.fromList [(i, c ^. #value) | (i, c) <- numbered]
          stdinPayload =
            Text.unlines
              ( ["-\t" <> row | row <- maybeToList (opts ^. #headerRow)]
                  <> [Text.pack (show i) <> "\t" <> c ^. #display | (i, c) <- numbered]
              )
          args = "--with-nth=2.." : optsToArgs opts
          cp =
            (proc (cfg ^. #binary) args)
              { std_in = CreatePipe,
                std_out = CreatePipe,
                std_err = Inherit,
                delegate_ctlc = True
              }
      r <- try @IOException $ do
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
      ["--no-sort" | o ^. #noSort],
      ["-1" | o ^. #selectOne],
      ["--header-lines=1" | isJust (o ^. #headerRow)]
    ]
