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
        }
      , Schema.Package::{
        , name = "shiki-cli"
        , type = Schema.PackageType.Application
        , language = Schema.Language.Haskell
        , path = Some "shiki-cli"
        , description = Some "shiki command-line executable."
        }
      ]
    , dependencies =
      [ "shinzui/hasql-migration"
      , "kazu-yamamoto/crypton"
      , "jappeace/ram"
      , "codedownio/kubernetes-api"
      ]
    }
