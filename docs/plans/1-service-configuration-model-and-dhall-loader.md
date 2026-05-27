---
id: 1
slug: service-configuration-model-and-dhall-loader
title: "Service Configuration Model and Dhall Loader"
kind: exec-plan
created_at: 2026-05-27T04:46:51Z
master_plan: "docs/masterplans/1-microservice-job-runner-with-postgres-backed-run-history.md"
---


# Service Configuration Model and Dhall Loader

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

`shiki` is a CLI that submits one-off Kubernetes Jobs on behalf of a small fleet of
microservices and records every run in PostgreSQL. Before any of that can happen, the CLI
needs a typed answer to the question: *"What does it mean to run a command against
`mls-service-v2`?"* — which namespace, which Deployment to mirror, which init containers to
attach, which environment variables to wire in from which ConfigMap or Secret keys, which
container name and binary path the args are passed to. Today that knowledge lives implicitly
in a shell script (`/Users/shinzui/Keikaku/work/microtan/mls-service-v2-master/scripts/infrastructure/run-oneoff-task.sh`)
that hard-codes `mls-service-v2-worker`, the container name `mls-service-v2`, a specific
init-container image for Cloud SQL Proxy, and a long fixed list of env-var-to-source mappings.

This plan replaces that implicit knowledge with a Haskell record type, `ServiceConfig`, plus a
loader that reads one Dhall file per microservice from `services/<name>.dhall`. After this
plan, a reader can run

```bash
cabal run shiki -- service show mls-service-v2
```

and see the parsed configuration pretty-printed to stdout, proving that the file was found,
parsed, and decoded into the typed record. No Kubernetes or Postgres involvement is required
to verify this plan; everything is local and offline.

This plan is also the first place new code is added to the project, so it is responsible for
extending `Shiki.Prelude` to match the project's Haskell standards (see Context and
Orientation below). Later plans rely on the extended prelude.

The `ServiceConfig` value produced here is the central input of the Kubernetes job runner
implemented in `docs/plans/3-kubernetes-job-runner.md` and is reloaded by the `run` CLI
command in `docs/plans/4-run-cli-command-end-to-end.md`. Those two consumers must not extend
this record locally; any new field must be added here first via the MasterPlan's update mode.


## Progress

- [ ] Extend `Shiki.Prelude` to match the project's custom-prelude standard.
- [ ] Add `Shiki.Service.Config` exporting `ServiceConfig`, `InitContainer`, `EnvVar`,
  `EnvSource`, `Resources`, `ServiceName` (newtype).
- [ ] Add `Shiki.Service.Config.Dhall` exporting `loadServiceConfig`.
- [ ] Add `services/mls-service-v2.dhall` sample.
- [ ] Add `shiki-core/test/Spec.hs` plus `shiki-core/test/Shiki/Service/ConfigSpec.hs`.
- [ ] Extend `shiki-cli` with the `service show <name>` subcommand.
- [ ] `cabal build all` and `cabal test all` clean; capture the transcripts in Concrete Steps.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Adopt the Haskell standards from `/Users/shinzui/Keikaku/bokuno/haskell-jitsurei`
  for every module added in this plan and beyond. Specifically: postpositive `qualified`
  imports, `Shiki.Prelude` as the project's custom prelude, no field prefixes, strict
  fields, explicit deriving strategies, `#fieldName` lens access, and `MultilineStrings`
  for embedded SQL/JSON/Dhall snippets.
  Rationale: User-stated requirement; consistent with the user's other Haskell CLIs;
  recorded once at the MasterPlan level as well.
  Date: 2026-05-26

- Decision: Use Dhall (via `dhall-lang/dhall-haskell`) as the configuration format rather
  than YAML/JSON/TOML.
  Rationale: The user's CLIs and other projects standardize on Dhall; Dhall's type system
  catches schema drift at load time (e.g., a missing `commandPath` field becomes a parse
  error, not a runtime `Nothing`); imports allow shared snippets across services (e.g., a
  common `cloud-sql-proxy.dhall`).
  Date: 2026-05-26

- Decision: One file per service under `services/<name>.dhall`, located relative to the
  current working directory at runtime (overridable later via `--config-dir`).
  Rationale: Mirrors how the existing shell script is invoked per repository checkout; keeps
  service definitions reviewable alongside the code they target; avoids a registry file that
  becomes a merge-conflict magnet.
  Date: 2026-05-26

- Decision: `ServiceConfig` describes only the *shape* of the Job (deployment to mirror,
  init containers, env-var wiring, container name). The *dynamic* values (image digest,
  ConfigMap name, Secret name) are filled in at run time by
  `docs/plans/3-kubernetes-job-runner.md` by introspecting the live Deployment.
  Rationale: Matches the existing script's pattern: the operator never has to update config
  when the image is bumped or when ConfigMap/Secret rotate; the live Deployment is the
  authoritative source of those mutable values.
  Date: 2026-05-26

- Decision: `ServiceName` is a newtype around `Text`, not a bare `Text`, with
  `deriving newtype (FromJSON, ToJSON)` plus `deriving stock (Generic, Eq, Ord, Show)`.
  Rationale: Matches the user's record-patterns convention (newtypes for domain IDs);
  prevents accidental confusion with namespace or container name strings.
  Date: 2026-05-26


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

`shiki` is laid out as two cabal packages described in
`/Users/shinzui/Keikaku/bokuno/shiki/cabal.project`:

```text
packages:
  shiki-core
  shiki-cli
```

`shiki-core` is the library with domain types and business logic. Today its only module is
`shiki-core/src/Shiki/Prelude.hs`, which re-exports `Control.Lens`, `Data.Generics.Labels`,
`Data.Generics.Product`, and `Data.Generics.Sum`. Its cabal file
(`shiki-core/shiki-core.cabal`) currently depends on `base`, `generic-lens`, `lens ^>= 5.3`,
and `text ^>= 2.1`, with `default-language: GHC2024` inside a `common common-options` stanza
that enables `DeriveAnyClass`, `DuplicateRecordFields`, `OverloadedLabels`, and
`OverloadedStrings`. The standards in
`/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/core/standards.md` name the stanza `common
common` rather than `common common-options`; both names are functionally equivalent and the
project may keep the existing name to avoid churn — the rule is "shared `common` stanza
with the listed extensions", not a specific identifier.

`shiki-cli` ships an executable named `shiki` (entry point
`shiki-cli/app/Main.hs`) that calls `Shiki.Cli.runCli` (defined in
`shiki-cli/src/Shiki/Cli.hs`). The current CLI parser uses `optparse-applicative` and has a
single `hello` subcommand. It is a starter scaffold to be replaced; this plan does *not*
remove `hello` (later plans will), it only adds a new `service` subparser alongside it.

Build environment: the project relies on a Nix flake (`flake.nix`) that provides GHC 9.12.4
plus `cabal-install`, `process-compose`, `postgresql`, and `pkg-config`. Enter the shell with
`nix develop` (or rely on direnv); after that, `cabal build all` and `cabal test all` work as
usual. Postgres is not needed for any milestone in *this* plan.

### Haskell Standards Summary

The relevant cookbook docs in `/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/` are:

- `core/standards.md` — GHC 9.12+, `GHC2024`, the four mandatory default-extensions, and
  postpositive `qualified` imports.
- `core/custom-prelude.md` — the project-level `Shiki.Prelude` module with `PackageImports`,
  `as X` re-exports, and the canonical baseline (`Generic`, `Text`, `UTCTime`,
  `FromJSON`/`ToJSON`, lens vocabulary).
- `core/record-patterns.md` — no field prefixes, strict `!` fields, `deriving stock` /
  `deriving anyclass` / `deriving newtype`, `#fieldName` for both reading and writing.
- `core/multiline-strings.md` — `MultilineStrings` with `"""..."""` for embedded SQL/JSON
  and other multi-line literals.

The condensed contract followed by this plan:

```cabal
common common-options
  default-language: GHC2024
  default-extensions:
    DeriveAnyClass
    DuplicateRecordFields
    OverloadedLabels
    OverloadedStrings
    MultilineStrings
    PackageImports
```

Imports use postpositive `qualified`:

```haskell
import Data.Text qualified as Text
import Data.Map.Strict qualified as Map
import Dhall qualified
```

Records use no prefixes, strict fields, explicit deriving, and `#` lens access:

```haskell
data Foo = Foo { name :: !Text, count :: !Int }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

mkFoo :: Text -> Foo
mkFoo n = Foo { name = n, count = 0 }

updateCount :: Int -> Foo -> Foo
updateCount n foo = foo & #count .~ n
```

### Term Definitions

- **Kubernetes Deployment** — a long-running set of pods managed by Kubernetes; the "worker"
  deployment is what `shiki` mirrors when constructing a one-off Job.
- **Kubernetes Job** — a one-off batch workload, also defined by Kubernetes; this is what
  `shiki run` ultimately submits (constructed in EP-3).
- **ConfigMap / Secret** — namespaced Kubernetes objects holding key/value pairs of
  non-sensitive and sensitive configuration. Container env vars typically reference keys in
  these.
- **Init container** — a container that runs to completion (or, when restartable, runs as a
  sidecar) before the main containers in a pod start. `cloud-sql-proxy` is the canonical
  example.
- **Dhall** — a programmable typed configuration language; values are statically typed and
  evaluate to normal forms. Schemas can be imported from disk or by URL. The Haskell binding
  is the `dhall` package.

### Cross-Plan Contract

From the MasterPlan's Integration Points section:

> **`Shiki.Service.Config.ServiceConfig`** (Haskell record type, module
> `Shiki.Service.Config` in `shiki-core/src/Shiki/Service/Config.hs`). Defined by EP-1.
> Consumed by EP-3 (the job runner turns it into a `V1Job`) and EP-4 (the CLI loads it from
> disk and passes it to the runner). EP-1 owns its shape.

A reference example of the existing shell script that this entire MasterPlan replaces lives
at `/Users/shinzui/Keikaku/work/microtan/mls-service-v2-master/scripts/infrastructure/run-oneoff-task.sh`.
You do not need to read it to complete this plan, but the sample Dhall config produced below
mirrors its assumptions one-for-one.


## Plan of Work

### Milestone 1 — Extend `Shiki.Prelude` to the standard

Scope: replace the contents of `shiki-core/src/Shiki/Prelude.hs` with the canonical
re-exports from `/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/core/custom-prelude.md`.
Update the cabal file to add `aeson`, `aeson-casing`, `time`, and `mtl` as build
dependencies. Add `MultilineStrings` and `PackageImports` to the default-extensions.

Replace `shiki-core/src/Shiki/Prelude.hs` with:

```haskell
-- | Project-wide prelude for shiki. Re-exports the common vocabulary used by
--   every module: lens operators, generic-lens labels, basic types, MonadIO,
--   aeson, time.
module Shiki.Prelude
  ( module X
  , module Control.Lens
  ) where

import "base" GHC.Generics as X (Generic)
import "base" Control.Monad as X (void, when, unless, guard)
import "base" Data.Maybe as X (fromMaybe, isJust, isNothing)
import "base" Data.Proxy as X (Proxy(..))
import "base" Control.Applicative as X ((<|>))
import "base" Control.Monad.IO.Class as X (MonadIO, liftIO)
import "base" Data.List.NonEmpty as X (NonEmpty(..))

import "text" Data.Text as X (Text)

import "aeson" Data.Aeson as X
  ( FromJSON, ToJSON
  , parseJSON, toJSON, fromJSON, toEncoding
  , genericParseJSON, genericToJSON, genericToEncoding
  , Options, SumEncoding(..), defaultOptions
  )
import "aeson-casing" Data.Aeson.Casing as X (camelTo2)

import "time" Data.Time as X (UTCTime, getCurrentTime)

import "generic-lens" Data.Generics.Labels ()

import "lens" Control.Lens
```

Edit `shiki-core/shiki-core.cabal`:

- Inside `common common-options`, add `MultilineStrings` and `PackageImports` to
  `default-extensions`.
- Inside `library`, add `aeson ^>= 2.2`, `aeson-casing ^>= 0.2`, `time ^>= 1.12`,
  `mtl ^>= 2.3` to `build-depends`.

Acceptance: `cabal build shiki-core` succeeds; `cabal repl shiki-core` followed by
`:t (undefined :: Text)` returns `Text` without an explicit import.

### Milestone 2 — `ServiceConfig` types compile in `shiki-core`

Scope: introduce the Haskell record types in `Shiki.Service.Config`. No Dhall, no CLI
changes, no filesystem I/O. At the end of this milestone a reader can `cabal repl
shiki-core` and construct a `ServiceConfig` literal that compiles.

Add `shiki-core/src/Shiki/Service/Config.hs`:

```haskell
module Shiki.Service.Config
  ( ServiceName(..)
  , ServiceConfig(..)
  , InitContainer(..)
  , EnvVar(..)
  , EnvSource(..)
  , Resources(..)
  ) where

import Shiki.Prelude

import Data.Map.Strict (Map)

newtype ServiceName = ServiceName { unServiceName :: Text }
  deriving stock (Generic, Eq, Ord, Show)
  deriving newtype (FromJSON, ToJSON)

data ServiceConfig = ServiceConfig
  { name                 :: !ServiceName
  , defaultNamespace     :: !Text
  , detectFromDeployment :: !Text
  , containerName        :: !Text
  , commandPath          :: !Text
  , serviceAccount       :: !Text
  , nodeSelector         :: !(Map Text Text)
  , initContainers       :: ![InitContainer]
  , env                  :: ![EnvVar]
  , resources            :: !Resources
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data InitContainer = InitContainer
  { name        :: !Text
  , image       :: !Text
  , args        :: ![Text]
  , env         :: ![EnvVar]
  , resources   :: !Resources
  , restartable :: !Bool
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data EnvVar = EnvVar
  { name   :: !Text
  , source :: !EnvSource
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data EnvSource
  = ConfigMap { key   :: !Text }
  | Secret    { key   :: !Text }
  | Literal   { value :: !Text }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data Resources = Resources
  { cpuRequest    :: !Text
  , cpuLimit      :: !Text
  , memoryRequest :: !Text
  , memoryLimit   :: !Text
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)
```

Edit `shiki-core/shiki-core.cabal`:

- Add `Shiki.Service.Config` under `exposed-modules`.
- Add `containers ^>= 0.7` to `build-depends`.

Acceptance: `cabal build shiki-core` succeeds.

### Milestone 3 — Dhall loader reads a sample service file

Scope: add the `services/` directory with a real sample and `Shiki.Service.Config.Dhall`
exposing `loadServiceConfig :: FilePath -> IO ServiceConfig`. Round-trip the sample in a
tasty test.

Add `services/mls-service-v2.dhall`:

```dhall
let EnvSource = < ConfigMap : { key : Text }
                | Secret    : { key : Text }
                | Literal   : { value : Text }
                >

let EnvVar = { name : Text, source : EnvSource }

let mkConfigEnv = \(name : Text) ->
      { name = name, source = EnvSource.ConfigMap { key = name } }

let mkSecretEnv = \(name : Text) ->
      { name = name, source = EnvSource.Secret { key = name } }

let CommonEnv =
      [ mkConfigEnv "PROJECT_ID"
      , mkConfigEnv "DATABASE_NAME"
      , mkConfigEnv "DATABASE_USER"
      , mkSecretEnv "DATABASE_PASSWORD"
      , { name = "PG_CONNECTION_STRING"
        , source = EnvSource.Literal
            { value = "postgresql://\$(DATABASE_USER):\$(DATABASE_PASSWORD)@localhost:5432/\$(DATABASE_NAME)" }
        }
      , mkConfigEnv "HASKELL_ENV"
      , mkConfigEnv "PG_POOL_SIZE"
      , mkSecretEnv "C1_OAUTH_CLIENT_ID"
      , mkSecretEnv "C1_OAUTH_CLIENT_SECRET"
      , mkConfigEnv "OTEL_SERVICE_NAME"
      , mkConfigEnv "OTEL_EXPORTER_OTLP_ENDPOINT"
      , mkSecretEnv "OTEL_EXPORTER_OTLP_HEADERS"
      , mkConfigEnv "OTEL_SDK_DISABLED"
      ]

in  { name                 = "mls-service-v2"
    , defaultNamespace     = "prod"
    , detectFromDeployment = "mls-service-v2-worker"
    , containerName        = "mls-service-v2"
    , commandPath          = "/app/mls-service-v2"
    , serviceAccount       = "mls-service-v2"
    , nodeSelector         = toMap { `iam.gke.io/gke-metadata-server-enabled` = "true" }
    , initContainers =
        [ { name  = "cloud-sql-proxy"
          , image = "gcr.io/cloud-sql-connectors/cloud-sql-proxy:2.21.0"
          , args  = [ "\$(DATABASE_INSTANCE)?port=5432" ]
          , env =
              [ mkConfigEnv "DATABASE_INSTANCE"
              , { name = "CSQL_PROXY_HEALTH_CHECK"         , source = EnvSource.Literal { value = "true" } }
              , { name = "CSQL_PROXY_HTTP_PORT"            , source = EnvSource.Literal { value = "9090" } }
              , { name = "CSQL_PROXY_HTTP_ADDRESS"         , source = EnvSource.Literal { value = "0.0.0.0" } }
              , { name = "CSQL_PROXY_EXIT_ZERO_ON_SIGTERM" , source = EnvSource.Literal { value = "true" } }
              , { name = "CSQL_PROXY_STRUCTURED_LOGS"      , source = EnvSource.Literal { value = "true" } }
              ]
          , resources =
              { cpuRequest = "50m", cpuLimit = "300m"
              , memoryRequest = "16Mi", memoryLimit = "64Mi"
              }
          , restartable = True
          }
        ]
    , env       = CommonEnv
    , resources =
        { cpuRequest = "500m", cpuLimit = "2"
        , memoryRequest = "512Mi", memoryLimit = "4096Mi"
        }
    }
```

Add `shiki-core/src/Shiki/Service/Config/Dhall.hs`:

```haskell
module Shiki.Service.Config.Dhall
  ( loadServiceConfig
  ) where

import Shiki.Prelude

import Shiki.Service.Config
  ( EnvSource, EnvVar, InitContainer, Resources, ServiceConfig, ServiceName
  )
import Dhall qualified
import Data.Text qualified as Text

-- | Load a 'ServiceConfig' from a Dhall file on disk.
--
-- The file must evaluate to a record whose shape matches 'ServiceConfig'.
-- See @services/mls-service-v2.dhall@ for the canonical example.
loadServiceConfig :: FilePath -> IO ServiceConfig
loadServiceConfig path = Dhall.inputFile Dhall.auto path

-- 'FromDhall' instances are derived generically. Because the Haskell
-- constructor names (@ConfigMap@, @Secret@, @Literal@) match the Dhall
-- union alternative names exactly, no custom interpret options are needed.
deriving anyclass instance Dhall.FromDhall ServiceName
deriving anyclass instance Dhall.FromDhall ServiceConfig
deriving anyclass instance Dhall.FromDhall InitContainer
deriving anyclass instance Dhall.FromDhall EnvVar
deriving anyclass instance Dhall.FromDhall EnvSource
deriving anyclass instance Dhall.FromDhall Resources

_unused :: Text
_unused = Text.pack ""
```

(The `_unused` binding plus `Text.pack ""` exists only to assert at compile time that the
postpositive-`qualified` import of `Data.Text` resolves; remove it once another use site is
added.)

Add `shiki-core/test/Spec.hs`:

```haskell
module Main (main) where

import Shiki.Service.ConfigSpec qualified as ConfigSpec
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main = defaultMain $ testGroup "shiki-core"
  [ ConfigSpec.tests
  ]
```

Add `shiki-core/test/Shiki/Service/ConfigSpec.hs`:

```haskell
module Shiki.Service.ConfigSpec (tests) where

import Shiki.Prelude

import Shiki.Service.Config
  ( InitContainer, ServiceConfig, ServiceName(..)
  )
import Shiki.Service.Config.Dhall (loadServiceConfig)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertEqual, testCase)

tests :: TestTree
tests = testGroup "Shiki.Service.Config"
  [ testCase "loadServiceConfig parses mls-service-v2.dhall" $ do
      cfg <- loadServiceConfig "services/mls-service-v2.dhall"
      assertEqual "name"
        (ServiceName "mls-service-v2")
        (cfg ^. #name)
      assertEqual "defaultNamespace"
        ("prod" :: Text)
        (cfg ^. #defaultNamespace)
  , testCase "first init container is cloud-sql-proxy" $ do
      cfg <- loadServiceConfig "services/mls-service-v2.dhall"
      case cfg ^. #initContainers of
        (ic : _) ->
          assertEqual "init container name"
            ("cloud-sql-proxy" :: Text)
            (ic ^. #name)
        [] ->
          fail "expected at least one init container"
  ]
```

Edit `shiki-core/shiki-core.cabal`:

- Add `Shiki.Service.Config.Dhall` to `exposed-modules`.
- Add `dhall ^>= 1.42` to the library's `build-depends` (verify exact version available in
  the GHC 9.12.4 nixpkgs set via `nix develop` then `ghc-pkg list dhall`).
- Add a `test-suite shiki-core-test` stanza:

  ```cabal
  test-suite shiki-core-test
    import: common-options
    type: exitcode-stdio-1.0
    main-is: Spec.hs
    hs-source-dirs: test
    other-modules:
      Shiki.Service.ConfigSpec
    build-depends:
      base >=4.20 && <5,
      shiki-core,
      tasty ^>=1.5,
      tasty-hunit ^>=0.10,
      text ^>=2.1,
  ```

Acceptance: `cabal test shiki-core` passes both assertions.

### Milestone 4 — `shiki service show <name>` subcommand

Scope: extend the CLI parser so a reader can pretty-print the parsed config from the
command line, providing the user-visible verification described in Purpose / Big Picture.

Edit `shiki-cli/src/Shiki/Cli.hs`:

- Replace the existing flat module with an extended one that keeps the `hello` subcommand
  and adds a `service` subparser. The full replacement file is:

  ```haskell
  module Shiki.Cli
    ( runCli
    ) where

  import Shiki.Prelude

  import Shiki.Service.Config (ServiceConfig)
  import Shiki.Service.Config.Dhall (loadServiceConfig)

  import Data.Aeson.Encode.Pretty qualified as AesonPretty
  import Data.ByteString.Lazy.Char8 qualified as BL8
  import Data.Text qualified as Text
  import Data.Text.IO qualified as TIO
  import Options.Applicative

  data Command
    = Hello !(Maybe Text)
    | ServiceShow !Text
    deriving stock (Eq, Show)

  newtype Options = Options
    { command :: Command
    }
    deriving stock (Eq, Show)

  runCli :: IO ()
  runCli = do
    opts <- execParser parserInfo
    runCommand (opts ^. #command)

  parserInfo :: ParserInfo Options
  parserInfo =
    info
      (optionsParser <**> helper)
      ( fullDesc
          <> progDesc
            "shiki conducts operational commands across Kubernetes services and records what ran, where it ran, and how long it took."
          <> header "shiki - one-off Kubernetes Jobs with durable run history"
      )

  optionsParser :: Parser Options
  optionsParser = Options <$> commandParser

  commandParser :: Parser Command
  commandParser =
    hsubparser
      ( command "hello"
          ( info
              ( Hello
                  <$> optional
                        (strOption (long "name" <> metavar "NAME" <> help "Whom to greet"))
              )
              (progDesc "Print a greeting")
          )
          <> command "service"
              ( info
                  serviceCommand
                  (progDesc "Inspect microservice configuration files")
              )
      )

  serviceCommand :: Parser Command
  serviceCommand =
    hsubparser
      ( command "show"
          ( info
              (ServiceShow <$> argument str (metavar "NAME"))
              (progDesc "Pretty-print the parsed ServiceConfig for NAME")
          )
      )

  runCommand :: Command -> IO ()
  runCommand (Hello mName) =
    TIO.putStrLn ("Hello, " <> fromMaybe "shiki" mName <> "!")
  runCommand (ServiceShow nm) = do
    let path = "services/" <> Text.unpack nm <> ".dhall"
    cfg <- loadServiceConfig path
    printConfig cfg

  printConfig :: ServiceConfig -> IO ()
  printConfig = BL8.putStrLn . AesonPretty.encodePretty
  ```

Edit `shiki-cli/shiki-cli.cabal`:

- Add `shiki-core`, `aeson`, `aeson-pretty`, `bytestring` to the library stanza's
  `build-depends`. (`shiki-core` is already listed; only add what is missing.)
- Add the same default-extensions (`MultilineStrings`, `PackageImports`) to its `common
  common-options` so the prelude imports compile.

Acceptance: see Validation and Acceptance.


## Concrete Steps

All commands assume the working directory is the repository root,
`/Users/shinzui/Keikaku/bokuno/shiki`, and that the dev shell has been entered with
`nix develop` (or via direnv).

After Milestone 1:

```bash
cabal build shiki-core
```

Expected (last line):

```text
Linking dist-newstyle/.../shiki-core-0.1.0.0 ...
```

After Milestone 2:

```bash
cabal build shiki-core
cabal repl shiki-core
-- in the REPL:
:t (undefined :: Shiki.Service.Config.ServiceConfig)
```

Expected REPL output:

```text
(undefined :: Shiki.Service.Config.ServiceConfig)
  :: Shiki.Service.Config.ServiceConfig
```

After Milestone 3:

```bash
cabal test shiki-core
```

Expected (truncated):

```text
shiki-core
  Shiki.Service.Config
    loadServiceConfig parses mls-service-v2.dhall: OK
    first init container is cloud-sql-proxy:      OK

All 2 tests passed
```

After Milestone 4:

```bash
cabal run shiki -- service show mls-service-v2
```

Expected (truncated; key fields shown):

```text
{
    "name": "mls-service-v2",
    "defaultNamespace": "prod",
    "detectFromDeployment": "mls-service-v2-worker",
    "containerName": "mls-service-v2",
    "commandPath": "/app/mls-service-v2",
    "serviceAccount": "mls-service-v2",
    "initContainers": [
        { "name": "cloud-sql-proxy", "image": "gcr.io/cloud-sql-connectors/cloud-sql-proxy:2.21.0", ... }
    ],
    "env": [ ... ],
    "resources": { ... }
}
```

And:

```bash
cabal run shiki -- service show no-such-service
```

Expected (stderr, exit code non-zero):

```text
shiki: services/no-such-service.dhall: openFile: does not exist (No such file or directory)
```


## Validation and Acceptance

After implementing all four milestones, the following must hold:

1. `cabal build all` succeeds with no warnings beyond the existing baseline.
2. `cabal test shiki-core` passes both assertions in
   `shiki-core/test/Shiki/Service/ConfigSpec.hs`.
3. `cabal run shiki -- service show mls-service-v2` prints a JSON document whose
   `defaultNamespace` field equals `"prod"` and whose `initContainers[0].name` equals
   `"cloud-sql-proxy"`. Operators can verify visually.
4. `cabal run shiki -- service show no-such-service` exits non-zero with a stderr message
   beginning `shiki: services/no-such-service.dhall:` — i.e., a missing file produces a
   readable diagnostic, not a silent failure.
5. `Shiki.Prelude` matches the structure in
   `/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/core/custom-prelude.md`. Verify by
   grepping: `grep -n '^import "' shiki-core/src/Shiki/Prelude.hs` should show
   `PackageImports` qualifications on every external module.

If any of these fail, do not advance to dependent plans (EP-3, EP-4).


## Idempotence and Recovery

All steps are pure file edits and Dhall is referentially transparent: re-running
`cabal build`, `cabal test`, or `cabal run shiki -- service show mls-service-v2` from a clean
working tree produces the same result. There is no database, no network call, and no shared
mutable state. If a Dhall edit produces a confusing error, the safest recovery is
`git checkout services/mls-service-v2.dhall` followed by re-applying the change. The prelude
extension is reversible: `git checkout shiki-core/src/Shiki/Prelude.hs` restores the
original.


## Interfaces and Dependencies

Libraries used and why:

- `dhall ^>= 1.42` (from `dhall-lang/dhall-haskell`): typed configuration loader; provides
  `Dhall.inputFile`, `Dhall.auto`, and `Generic`-based deriving of `FromDhall`.
- `aeson ^>= 2.2`: `ToJSON`/`FromJSON` for `ServiceConfig`, used by `service show` and by
  the JSON column writes in EP-2/EP-4.
- `aeson-casing ^>= 0.2`: re-exported by `Shiki.Prelude` for `camelTo2 '_'` when needed by
  later JSON schemas.
- `aeson-pretty`: stable pretty-printing for the CLI.
- `bytestring`: required for `aeson-pretty`'s lazy `ByteString` output.
- `text ^>= 2.1`: already a dependency.
- `time ^>= 1.12`: `UTCTime` re-exported by the prelude; used by later plans.
- `mtl ^>= 2.3`: `MonadIO` re-exported by the prelude.
- `containers ^>= 0.7`: `Map Text Text` for `nodeSelector`.
- `tasty ^>= 1.5` + `tasty-hunit ^>= 0.10`: test suite.

Module-level surface that must exist at the end of this plan:

- `Shiki.Prelude` (extended) — re-exports per `core/custom-prelude.md`.

- `Shiki.Service.Config` (in `shiki-core/src/Shiki/Service/Config.hs`):

  ```haskell
  newtype ServiceName = ServiceName { unServiceName :: Text }

  data ServiceConfig = ServiceConfig
    { name                 :: !ServiceName
    , defaultNamespace     :: !Text
    , detectFromDeployment :: !Text
    , containerName        :: !Text
    , commandPath          :: !Text
    , serviceAccount       :: !Text
    , nodeSelector         :: !(Map Text Text)
    , initContainers       :: ![InitContainer]
    , env                  :: ![EnvVar]
    , resources            :: !Resources
    }

  data InitContainer = InitContainer { ... }
  data EnvVar = EnvVar { name :: !Text, source :: !EnvSource }
  data EnvSource = ConfigMap { key :: !Text } | Secret { key :: !Text } | Literal { value :: !Text }
  data Resources = Resources { cpuRequest, cpuLimit, memoryRequest, memoryLimit :: !Text }
  ```

- `Shiki.Service.Config.Dhall` (in `shiki-core/src/Shiki/Service/Config/Dhall.hs`):

  ```haskell
  loadServiceConfig :: FilePath -> IO ServiceConfig
  ```

Downstream consumers (must not extend this surface; open a MasterPlan update first):

- `docs/plans/3-kubernetes-job-runner.md` — turns `ServiceConfig` plus a discovered
  Deployment snapshot into a `V1Job`.
- `docs/plans/4-run-cli-command-end-to-end.md` — loads `ServiceConfig` from disk at the top
  of `shiki run` and threads it to the runner.
