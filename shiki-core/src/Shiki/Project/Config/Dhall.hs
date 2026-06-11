{-# OPTIONS_GHC -Wno-orphans #-}

-- | Load a 'ProjectConfig' from a @shiki.dhall@ file on disk.
--
--   The file must evaluate to a record matching 'ProjectConfig'. See
--   @shiki.dhall.example@ in the repository root for a copyable example.
--
--   The @FromDhall@ instances are derived generically: the Haskell record
--   field names line up with the Dhall record field names, and the
--   @environments@ field decodes from Dhall's @List { mapKey, mapValue }@
--   map encoding into 'Data.Map.Strict.Map' automatically.
module Shiki.Project.Config.Dhall
  ( loadProjectConfig,
  )
where

import Shiki.Project.Config (Environment, ProjectConfig)
import "dhall" Dhall qualified

loadProjectConfig :: FilePath -> IO ProjectConfig
loadProjectConfig = Dhall.inputFile Dhall.auto

deriving anyclass instance Dhall.FromDhall Environment

deriving anyclass instance Dhall.FromDhall ProjectConfig
