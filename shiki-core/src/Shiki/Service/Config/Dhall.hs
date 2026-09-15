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
--
--   Dhall has no optional record fields: a decoder for a record with a
--   @Maybe@ field rejects a record that leaves it out. Fields added to
--   'ServiceConfig' after services were written ('optionalFields') are filled
--   in with @None@ when a file omits them, so existing service files keep
--   loading unchanged.
module Shiki.Service.Config.Dhall
  ( loadServiceConfig,
  )
where

import Control.Lens ((&), (.~))
import Data.Text (Text)
import Data.Text.IO qualified as TIO
import Data.Void (Void, absurd)
import Dhall qualified
import Dhall.Core (Expr (..), makeRecordField)
import Dhall.Map qualified as DhallMap
import Dhall.Src (Src)
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
import System.FilePath (takeDirectory)

loadServiceConfig :: FilePath -> IO ServiceConfig
loadServiceConfig path = do
  text <- TIO.readFile path
  let settings =
        Dhall.defaultInputSettings
          & Dhall.rootDirectory .~ takeDirectory path
          & Dhall.sourceName .~ path
  expr <- Dhall.inputExprWithSettings settings text
  Dhall.fromExprWithSettings settings Dhall.auto (absurd <$> fillOptionalFields expr)

-- | Optional 'ServiceConfig' fields a service file may omit, with the Dhall
--   type of their @None@.
optionalFields :: [(Text, Expr Src Void)]
optionalFields = [("ttlSecondsAfterFinished", Natural)]

-- | Add @None T@ for each of 'optionalFields' a record literal lacks. Any
--   other expression is left for the decoder to reject with its usual error.
fillOptionalFields :: Expr Src Void -> Expr Src Void
fillOptionalFields = \case
  RecordLit fields -> RecordLit (foldr addMissing fields optionalFields)
  other -> other
  where
    addMissing (key, ty) fields
      | DhallMap.member key fields = fields
      | otherwise = DhallMap.insert key (makeRecordField (App None ty)) fields

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
