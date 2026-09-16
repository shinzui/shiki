-- | A small lifecycle wrapper for actions that need to announce liveness
--   while a longer body is running.
--
--   The beat and the body are both @Eff@ computations over the same effects,
--   so the heartbeat can write a run row through
--   'Shiki.Effect.RunStore.RunStore' without anyone handing it a connection
--   pool. The loop runs in a child thread started by
--   'Effectful.Concurrent.Async.withAsync', which cancels it when the body
--   returns or throws.
module Shiki.Cli.Heartbeat (withHeartbeat) where

import Control.Monad (forever)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Text qualified as Text
import Data.Text.IO qualified as TIO
import Effectful (Eff, IOE, type (:>))
import Effectful.Concurrent (Concurrent, threadDelay)
import Effectful.Concurrent.Async (withAsync)
import Effectful.Error.Static (Error, catchError)
import Effectful.Exception qualified as Exc
import Shiki.Error (ShikiError, shikiErrorMessage)
import Shiki.Prelude
import System.IO (stderr)

-- | Run the beat now and then every interval (microseconds) until the body
--   returns or throws. A beat failure is reported once on stderr and then
--   ignored: losing the liveness marker must not end a run that is otherwise
--   fine. Both shapes of failure are caught — an exception with 'Exc.trySync'
--   and a typed 'ShikiError' with 'catchError' — because a failed
--   @touchRunWatched@ arrives as the latter.
withHeartbeat ::
  (Concurrent :> es, IOE :> es, Error ShikiError :> es) =>
  Int ->
  Eff es () ->
  Eff es a ->
  Eff es a
withHeartbeat interval beat body = do
  reportedFailure <- liftIO (newIORef False)
  safeBeat reportedFailure
  withAsync
    (forever (threadDelay interval *> safeBeat reportedFailure))
    (const body)
  where
    safeBeat reported =
      Exc.trySync (beat `catchError` \_ e -> reportOnce reported (shikiErrorMessage e))
        >>= \case
          Right () -> pure ()
          Left e -> reportOnce reported (Text.pack (Exc.displayException e))

    reportOnce :: (IOE :> es) => IORef Bool -> Text -> Eff es ()
    reportOnce reported message = liftIO $ do
      alreadyReported <- readIORef reported
      unless alreadyReported $ do
        writeIORef reported True
        TIO.hPutStrLn
          stderr
          ( "shiki: could not record run heartbeat: "
              <> message
              <> "; the run continues"
          )
