-- | Project-wide prelude for shiki-core. Re-exports the lens and
--   generic-lens vocabulary every module in this project is expected to use,
--   so consumers can `import Shiki.Prelude` and get the
--   standard toolkit without per-module import noise.
module Shiki.Prelude
  ( -- * Lens vocabulary
    module Control.Lens

    -- * Generic-lens vocabulary
  , module Data.Generics.Labels
  , module Data.Generics.Product
  , module Data.Generics.Sum
  ) where

import Control.Lens
import Data.Generics.Labels ()
import Data.Generics.Product
import Data.Generics.Sum
