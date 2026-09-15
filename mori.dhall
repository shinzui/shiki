let Schema =
      https://raw.githubusercontent.com/shinzui/mori-schema/3522f4a51181d73c9c90fc27a7c0838bd29ae95f/package.dhall
        sha256:dcb19e2312e790bad14e622cc98a1281cd2298c5b564a2f0d0534d3c718d8803

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
          , Schema.Dependency.ByName "shinzui/pg-migrate"
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
              , versionConstraint = None Text
              }
          , Schema.Dependency.WithAugmentation
              { name = "UnkindPartition/tasty"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Test
              , versionConstraint = None Text
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
              , versionConstraint = None Text
              }
          , Schema.Dependency.WithAugmentation
              { name = "UnkindPartition/tasty"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Test
              , versionConstraint = None Text
              }
          , Schema.Dependency.WithAugmentation
              { name = "haskell-hvr/uuid"
              , extraDocs = [] : List Schema.DocRef.Type
              , localPathOverride = None Text
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              , scope = Some Schema.DependencyScope.Test
              , versionConstraint = None Text
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
      , "shinzui/pg-migrate"
      , "snoyberg/http-client"
      , "codedownio/kubernetes-api"
      , "ekmett/lens"
      , "pcapriotti/optparse-applicative"
      , "UnkindPartition/tasty"
      , "haskell-hvr/uuid"
      ]
    , okfBundles =
      [ Schema.OkfBundle::{
        , name = "user-documentation"
        , path = "docs/user"
        , profile = Some "mori/user-documentation-profile.dhall"
        , profileBinding = Some
            ( Schema.ProfileBinding.Published
                Schema.PinnedImport::{
                , publisher = "shinzui/okf-profiles"
                , publisherRef = Some
                    Schema.MoriRef::{ namespace = "shinzui", name = "okf-profiles" }
                , export = Some "documentation.userDocumentation"
                , version = Some "v0.13.1"
                , pin = Some
                    "sha256:3be4c39d128ef8a21e39d7ae4eaef29097801b343ab5672caaf7e30186a8f91a"
                }
            )
        , okfVersion = "0.2"
        , description = Some "Reader-facing product documentation"
        }
      ]
    }
