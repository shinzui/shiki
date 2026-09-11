{-# OPTIONS_GHC -Wno-orphans #-}

-- | Load a 'ServiceConfig' from a Dhall file on disk.
--
--   The file must evaluate to a record whose shape matches 'ServiceConfig'.
--   See @services\/mls-service-v2.dhall@ for the canonical example.
--
--   The @FromDhall@ instances below are derived generically. Because the
--   Haskell constructor and selector names line up with the Dhall union
--   alternative and record-field names, no @InterpretOptions@ overrides
--   are needed.
module Shiki.Service.Config.Dhall
  ( loadServiceConfig,
  )
where

import Dhall qualified
import Shiki.Service.Config
  ( AnalyzerBackend,
    ContainerImageSource,
    EnvSource,
    EnvVar,
    InitContainer,
    Resources,
    ServiceConfig,
    ServiceName (..),
  )

loadServiceConfig :: FilePath -> IO ServiceConfig
loadServiceConfig = Dhall.inputFile Dhall.auto

-- | Decode 'ServiceName' from a bare Dhall @Text@ rather than from the
--   default newtype-wrapped record @{ unServiceName : Text }@. The
--   default 'Dhall.singletonConstructors' setting is 'Smart', which uses
--   the selector name as the record key for any newtype that carries one;
--   the on-disk @services\/\<name\>.dhall@ files supply the name as a
--   plain string literal, so the manual instance bridges the two shapes.
instance Dhall.FromDhall ServiceName where
  autoWith opts = ServiceName <$> Dhall.autoWith opts

deriving anyclass instance Dhall.FromDhall ServiceConfig

deriving anyclass instance Dhall.FromDhall InitContainer

deriving anyclass instance Dhall.FromDhall ContainerImageSource

deriving anyclass instance Dhall.FromDhall EnvVar

deriving anyclass instance Dhall.FromDhall EnvSource

deriving anyclass instance Dhall.FromDhall Resources

deriving anyclass instance Dhall.FromDhall AnalyzerBackend
