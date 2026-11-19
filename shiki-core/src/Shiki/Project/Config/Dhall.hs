{-# OPTIONS_GHC -Wno-orphans #-}

-- | Load either public project schema, resolving imports relative to the file.
module Shiki.Project.Config.Dhall (loadProjectConfig) where

import Data.Text.IO qualified as TIO
import Data.Void (absurd)
import Dhall qualified
import Shiki.Prelude
import Shiki.Project.Config (Environment (..), ProjectConfig (..))
import System.FilePath (takeDirectory)

loadProjectConfig :: FilePath -> IO ProjectConfig
loadProjectConfig path = do
  let settings = Dhall.defaultInputSettings & Dhall.rootDirectory .~ takeDirectory path & Dhall.sourceName .~ path
  expr <- TIO.readFile path >>= Dhall.inputExprWithSettings settings
  -- Check the exact legacy type before decoding it. A record decoder alone
  -- can ignore an extra field, including a misspelled or ill-typed binding.
  let decoder = case Dhall.expectWithSettings settings legacyProject expr of
        Just () -> legacyProject
        Nothing -> Dhall.auto
  Dhall.fromExpr decoder (absurd <$> expr)

legacyProject :: Dhall.Decoder ProjectConfig
legacyProject =
  Dhall.record $
    ProjectConfig
      <$> Dhall.field "environments" (Dhall.map Dhall.strictText legacyEnvironment)
      <*> Dhall.field "defaultEnvironment" Dhall.strictText
  where
    legacyEnvironment = Dhall.record ((\url -> Environment url Nothing) <$> Dhall.field "databaseUrl" Dhall.strictText)

deriving anyclass instance Dhall.FromDhall Environment

deriving anyclass instance Dhall.FromDhall ProjectConfig
