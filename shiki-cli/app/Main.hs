module Main (main) where

import Shiki.Cli (runCli)
import System.Exit (exitWith)

-- | 'runCli' never exits on its own: it returns the code its top-level
--   handler decided on, and this is the only place that acts on it.
main :: IO ()
main = runCli >>= exitWith
