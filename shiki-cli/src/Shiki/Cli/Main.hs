-- | The one place @shiki@ turns an outcome into output and an exit code.
--
--   Every command runs inside 'runShikiMain'. There are exactly five things
--   that can come out of a command, and this module decides what each one
--   looks like to an operator:
--
--   * it succeeded — nothing is printed and the exit code is 0;
--   * it threw a 'ShikiError' or a 'CliError' — the rendered line goes to the
--     given handle (stderr in production) and the exit code is 1. A few
--     'CliError' values render as 'Nothing', which prints nothing and still
--     exits 1;
--   * it called @exitWith@ — that exit code passes through unchanged, so
--     @shiki agent assist@ can exit with the status of the @claude@ process it
--     launched;
--   * it threw something nobody classified — one line reading
--     @shiki: unexpected error: \<message\>@ and exit 1, never GHC's
--     @Uncaught exception@ banner and never a @HasCallStack@ backtrace;
--   * it was interrupted — Ctrl-C arrives as an /asynchronous/ exception,
--     which nothing here catches. It reaches GHC's own handler, which prints
--     nothing and exits with the interrupt status (130 in a shell).
--
--   The ordering of the handlers matters. @trySync@ sits just inside 'runEff'
--   and outside everything else: effectful's typed errors are already turned
--   into 'Left' by the two @runErrorNoCallStack@ calls within it, and
--   @trySync@ ignores asynchronous exceptions by construction.
module Shiki.Cli.Main
  ( CliEff,
    runShikiMain,
  )
where

import Data.Text qualified as Text
import Data.Text.IO qualified as TIO
import Effectful (Eff, IOE, runEff)
import Effectful.Concurrent (Concurrent, runConcurrent)
import Effectful.Error.Static (Error, runErrorNoCallStack)
import Effectful.Exception qualified as Exc
import Shiki.Cli.Error (CliError, renderCliError)
import Shiki.Error (ShikiError, renderShikiError)
import System.Exit (ExitCode (..))
import System.IO (Handle)

-- | The effects every command may use. Commands add their own effects on top
--   and discharge them before returning to this stack.
type CliEff = '[Error CliError, Error ShikiError, Concurrent, IOE]

-- | Run a command and turn every outcome into an exit code, printing failures
--   on the given handle (stderr in production, a temporary file in tests).
runShikiMain :: Handle -> Eff CliEff () -> IO ExitCode
runShikiMain h action = do
  result <-
    runEff
      . Exc.trySync
      . runConcurrent
      . runErrorNoCallStack @ShikiError
      . runErrorNoCallStack @CliError
      $ action
  case result of
    Right (Right (Right ())) -> pure ExitSuccess
    Right (Right (Left cliErr)) -> failWith (renderCliError cliErr)
    Right (Left coreErr) -> failWith (Just (renderShikiError coreErr))
    Left ex
      | Just code <- Exc.fromException @ExitCode ex -> pure code
      | otherwise ->
          failWith
            (Just ("shiki: unexpected error: " <> Text.pack (Exc.displayException ex)))
  where
    failWith message = do
      mapM_ (TIO.hPutStrLn h) message
      pure (ExitFailure 1)
