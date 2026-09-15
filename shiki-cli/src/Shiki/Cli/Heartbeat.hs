-- | A small lifecycle wrapper for actions that need to announce liveness
--   while a longer body is running.
module Shiki.Cli.Heartbeat (withHeartbeat) where

import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Exception
  ( SomeAsyncException,
    SomeException,
    bracket,
    displayException,
    fromException,
    throwIO,
    try,
  )
import Control.Monad (forever)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Text qualified as Text
import Data.Text.IO qualified as TIO
import Shiki.Prelude
import System.IO (stderr)

-- | Run the beat now and then every interval (microseconds) until the body
--   returns or throws. Beat failures are reported once on stderr and ignored.
withHeartbeat :: Int -> IO () -> IO a -> IO a
withHeartbeat interval beat body = do
  reportedFailure <- newIORef False
  let heartbeatLoop = forever (threadDelay interval *> safeBeat reportedFailure)
  bracket
    (safeBeat reportedFailure *> forkIO heartbeatLoop)
    killThread
    (const body)
  where
    safeBeat :: IORef Bool -> IO ()
    safeBeat reported =
      try @SomeException beat >>= \case
        Right () -> pure ()
        Left e
          | Just asyncErr <- fromException @SomeAsyncException e -> throwIO asyncErr
          | otherwise -> do
              alreadyReported <- readIORef reported
              unless alreadyReported $ do
                writeIORef reported True
                TIO.hPutStrLn
                  stderr
                  ( "shiki: could not record run heartbeat: "
                      <> Text.pack (displayException e)
                      <> "; the run continues"
                  )
