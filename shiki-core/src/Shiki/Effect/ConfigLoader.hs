{-# LANGUAGE TypeFamilies #-}

-- | Loading shiki's two Dhall files, as one effect.
--
--   @shiki.dhall@ says where the runs live; @services\/\<name\>.dhall@ says
--   what a service is. Both are loaded by Dhall, which reports a missing
--   import, a syntax error, and a type mismatch by throwing; the interpreter
--   ("Shiki.Effect.ConfigLoader.runConfigLoaderIO") turns each into a typed
--   'Shiki.Error.ConfigError' so a typo in a config file prints one message
--   instead of GHC's uncaught-exception banner.
module Shiki.Effect.ConfigLoader
  ( ConfigLoader (..),
    loadServiceConfig,
    loadProjectConfig,
    runConfigLoaderIO,
  )
where

import Data.Text qualified as Text
import Effectful (Dispatch (Dynamic), DispatchOf, Eff, Effect, IOE, type (:>))
import Effectful.Dispatch.Dynamic (interpret_, send)
import Effectful.Error.Static (Error, throwError)
import Effectful.Exception qualified as Exc
import Shiki.Error (ConfigError (..), ShikiError (..))
import Shiki.Prelude
import Shiki.Project.Config (ProjectConfig)
import Shiki.Project.Config.Dhall qualified as ProjectDhall
import Shiki.Service.Config (ServiceConfig)
import Shiki.Service.Config.Dhall qualified as ServiceDhall
import System.Directory (doesFileExist)

data ConfigLoader :: Effect where
  LoadServiceConfig :: FilePath -> ConfigLoader m ServiceConfig
  LoadProjectConfig :: FilePath -> ConfigLoader m ProjectConfig

type instance DispatchOf ConfigLoader = Dynamic

loadServiceConfig :: (ConfigLoader :> es) => FilePath -> Eff es ServiceConfig
loadServiceConfig = send . LoadServiceConfig

loadProjectConfig :: (ConfigLoader :> es) => FilePath -> Eff es ProjectConfig
loadProjectConfig = send . LoadProjectConfig

-- | Read the files from disk with Dhall.
--
--   A file that is not there and a file that does not parse are different
--   mistakes with different fixes, so they get different messages: @no service
--   config at \<path\>@ versus @cannot load \<path\>: \<Dhall's diagnostic\>@.
--   Dhall's diagnostic is kept as Dhall wrote it, caret line and all, because
--   it is the only thing that says /where/ the typo is.
runConfigLoaderIO ::
  (IOE :> es, Error ShikiError :> es) =>
  Eff (ConfigLoader : es) a ->
  Eff es a
runConfigLoaderIO = interpret_ $ \case
  LoadServiceConfig path -> do
    requireFile path (ServiceConfigNotFound path)
    load path (ServiceDhall.loadServiceConfig path) (ServiceConfigInvalid path)
  LoadProjectConfig path -> do
    requireFile path (ProjectConfigInvalid path "file not found")
    load path (ProjectDhall.loadProjectConfig path) (ProjectConfigInvalid path)
  where
    requireFile path missing = do
      present <- liftIO (doesFileExist path)
      unless present (throwError (ShikiConfigError missing))

    load _path act invalid =
      Exc.trySync (liftIO act) >>= \case
        Right value -> pure value
        Left e ->
          throwError
            ( ShikiConfigError
                (invalid (Text.strip (Text.pack (Exc.displayException e))))
            )
