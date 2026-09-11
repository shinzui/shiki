{-# LANGUAGE PackageImports #-}

-- | Project-wide prelude for shiki. Re-exports the common vocabulary used
--   by every module: lens operators, generic-lens labels, basic types,
--   MonadIO, aeson, time. Modules in this project should import
--   @Shiki.Prelude@ in place of the standard prelude wherever practical
--   so that domain modules stay free of import noise.
module Shiki.Prelude
  ( module X,
    module Control.Lens,
  )
where

import "aeson" Data.Aeson as X
  ( FromJSON,
    Options,
    SumEncoding (..),
    ToJSON,
    camelTo2,
    defaultOptions,
    fromJSON,
    genericParseJSON,
    genericToEncoding,
    genericToJSON,
    parseJSON,
    toEncoding,
    toJSON,
  )
import "base" Control.Applicative as X ((<|>))
import "base" Control.Monad as X (guard, unless, void, when)
import "base" Control.Monad.IO.Class as X (MonadIO, liftIO)
import "base" Data.List.NonEmpty as X (NonEmpty (..))
import "base" Data.Maybe as X (fromMaybe, isJust, isNothing)
import "base" Data.Proxy as X (Proxy (..))
import "base" GHC.Generics as X (Generic)
import "generic-lens" Data.Generics.Labels ()
import "lens" Control.Lens
import "text" Data.Text as X (Text)
import "time" Data.Time as X (UTCTime, getCurrentTime)
