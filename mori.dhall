let Schema =
      https://raw.githubusercontent.com/shinzui/mori-schema/026ae74331e5c516542af1dd96f041c658ed4621/package.dhall
        sha256:18258ef583580a897f4af3e7c86db0342afb42fb40efc535b217ba1089230141

in  Schema.Project::{
    , project = Schema.ProjectIdentity::{
      , name = "shiki"
      , namespace = "shinzui"
      , type = Schema.PackageType.Application
      , language = Schema.Language.Haskell
      , lifecycle = Schema.Lifecycle.Active
      , description = Some
          "CLI that conducts operational commands across Kubernetes services with a durable PostgreSQL run history."
      , domains = [ "Kubernetes", "OperationalTools", "CLI" ]
      , owners = [ "shinzui" ]
      }
    , repos = [ Schema.Repo::{ name = "shiki", github = Some "shinzui/shiki" } ]
    , packages =
      [ Schema.Package::{
        , name = "shiki-core"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "shiki-core"
        , description = Some
            "Domain types, persistence, and Kubernetes runner library."
        , dependencies =
          [ Schema.Dependency.ByName "haskell/aeson"
          , Schema.Dependency.ByName "shinzui/baikai"
          , Schema.Dependency.ByName "dhall-lang/dhall-haskell"
          , Schema.Dependency.ByName "hasql/hasql"
          , Schema.Dependency.ByName "shinzui/hasql-migration"
          , Schema.Dependency.ByName "snoyberg/http-client"
          , Schema.Dependency.ByName "codedownio/kubernetes-api"
          , Schema.Dependency.ByName "ekmett/lens"
          , Schema.Dependency.ByName "haskell-hvr/uuid"
          , Schema.Dependency.WithAugmentation
              { name = "shinzui/ephemeral-pg"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Test
              }
          , Schema.Dependency.WithAugmentation
              { name = "UnkindPartition/tasty"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Test
              }
          ]
        }
      , Schema.Package::{
        , name = "shiki-cli"
        , type = Schema.PackageType.Application
        , language = Schema.Language.Haskell
        , path = Some "shiki-cli"
        , description = Some "shiki command-line executable."
        , dependencies =
          [ Schema.Dependency.ByName "haskell/aeson"
          , Schema.Dependency.ByName "shinzui/baikai"
          , Schema.Dependency.ByName "hasql/hasql"
          , Schema.Dependency.ByName "ekmett/lens"
          , Schema.Dependency.ByName "pcapriotti/optparse-applicative"
          , Schema.Dependency.WithAugmentation
              { name = "shinzui/ephemeral-pg"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Test
              }
          , Schema.Dependency.WithAugmentation
              { name = "UnkindPartition/tasty"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Test
              }
          , Schema.Dependency.WithAugmentation
              { name = "haskell-hvr/uuid"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Test
              }
          ]
        }
      ]
    , dependencies =
      [ "haskell/aeson"
      , "shinzui/baikai"
      , "dhall-lang/dhall-haskell"
      , "shinzui/ephemeral-pg"
      , "hasql/hasql"
      , "shinzui/hasql-migration"
      , "snoyberg/http-client"
      , "codedownio/kubernetes-api"
      , "ekmett/lens"
      , "pcapriotti/optparse-applicative"
      , "UnkindPartition/tasty"
      , "haskell-hvr/uuid"
      , "kazu-yamamoto/crypton"
      , "jappeace/ram"
      ]
    }
