-- | Project-wide prelude for shiki. Re-exports the common vocabulary used
--   by every module: lens operators, generic-lens labels, basic types,
--   MonadIO, aeson, time. Modules in this project should import
--   @Shiki.Prelude@ in place of the standard prelude wherever practical
--   so that domain modules stay free of import noise.
module Shiki.Prelude
  ( module X
  , module Control.Lens
  ) where

import "base" GHC.Generics as X (Generic)
import "base" Control.Monad as X (void, when, unless, guard)
import "base" Data.Maybe as X (fromMaybe, isJust, isNothing)
import "base" Data.Proxy as X (Proxy (..))
import "base" Control.Applicative as X ((<|>))
import "base" Control.Monad.IO.Class as X (MonadIO, liftIO)
import "base" Data.List.NonEmpty as X (NonEmpty (..))

import "text" Data.Text as X (Text)

import "aeson" Data.Aeson as X
  ( FromJSON
  , ToJSON
  , parseJSON
  , toJSON
  , fromJSON
  , toEncoding
  , genericParseJSON
  , genericToJSON
  , genericToEncoding
  , Options
  , SumEncoding (..)
  , defaultOptions
  , camelTo2
  )

import "time" Data.Time as X (UTCTime, getCurrentTime)

import "generic-lens" Data.Generics.Labels ()

import "lens" Control.Lens
