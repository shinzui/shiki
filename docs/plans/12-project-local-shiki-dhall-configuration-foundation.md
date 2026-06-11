---
id: 12
slug: project-local-shiki-dhall-configuration-foundation
title: "Project-local shiki.dhall configuration foundation"
kind: exec-plan
created_at: 2026-06-11T18:40:28Z
intention: "intention_01ktvznw1xewqamnvyfhsbb4w2"
master_plan: "docs/masterplans/2-project-local-configuration-with-per-environment-databases.md"
---

# Project-local shiki.dhall configuration foundation

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This plan is the first of two under the MasterPlan
`docs/masterplans/2-project-local-configuration-with-per-environment-databases.md`. It is
the **producer**: it introduces a project-local configuration file and everything needed
to load and inspect it. The second plan
(`docs/plans/13-route-run-storage-to-the-active-environment-database.md`) consumes what
this plan builds. You do not need to read that plan to implement this one; this plan is
self-contained.


## Purpose / Big Picture

`shiki` is a command-line tool (the `shiki` executable) for running one-off Kubernetes
Jobs against microservices and recording each run in a PostgreSQL database. Today it has no
project-level configuration file: every database setting is passed as a flag or an
environment variable on each invocation.

This plan introduces a single project-local file named `shiki.dhall`, written in **Dhall**
(a small, typed configuration language already used by this project for service
definitions — see `services/mls-service-v2.dhall`). The file declares a set of **named
environments** (for example `staging` and `prod`), each carrying its own PostgreSQL
connection string, plus which environment is the **default**.

After this plan, an operator can run a new read-only command and see their configuration
resolved:

```text
$ shiki config show
config file:        /home/op/project/shiki.dhall
environments:       prod, staging
default environment: staging
active environment: staging   (from defaultEnvironment)
database url:       postgresql://shiki:****@db.staging.internal:5432/shiki
```

and select a different active environment:

```text
$ shiki config show --env prod
config file:        /home/op/project/shiki.dhall
environments:       prod, staging
default environment: staging
active environment: prod   (from --env)
database url:       postgresql://shiki:****@db.prod.internal:5432/shiki
```

Critically, this plan **does not change how any database connection is made**. The
`run`, `runs`, and `agent` subcommands behave exactly as before. The only new user-visible
behavior is the `shiki config show` command and a new global `--env` flag (which, for now,
only `config show` reads). Wiring the active environment into the live database connection
is the job of the next plan
(`docs/plans/13-route-run-storage-to-the-active-environment-database.md`). Keeping the
foundation inert here makes it independently reviewable and reusable for future features
that will read project configuration.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here.

- [x] M1: Shared Dhall types and Haskell config types with loader (see Milestone 1). Completed 2026-06-11.
  - [x] Add `shiki-core/dhall/Environment.dhall` and `shiki-core/dhall/ProjectConfig.dhall`.
  - [x] Add `shiki-core/src/Shiki/Project/Config.hs` (types).
  - [x] Add `shiki-core/src/Shiki/Project/Config/Dhall.hs` (loader + FromDhall instances).
  - [x] Register both modules in `shiki-core/shiki-core.cabal`; add `dhall/*.dhall` to
    `data-files` and `extra-source-files`.
  - [x] Add `shiki-core/test/Shiki/Project/ConfigSpec.hs` round-trip test; register it.
- [x] M2: Discovery + active-environment resolution (see Milestone 2). Completed 2026-06-11.
  - [x] Add `shiki-cli/src/Shiki/Cli/Project.hs`; register it in `shiki-cli/shiki-cli.cabal`.
  - [x] Add `shiki-cli/test/Shiki/Cli/ProjectSpec.hs`; register it.
- [x] M3: `shiki config show` command + global `--env` flag (see Milestone 3). Completed 2026-06-11.
  - [x] Add `shiki-cli/src/Shiki/Cli/ConfigShow.hs`; register it.
  - [x] Wire `Config` command and global `--env` flag into `shiki-cli/src/Shiki/Cli.hs`.
- [x] M4: Documentation + example `shiki.dhall` (see Milestone 4). Completed 2026-06-11.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Discovery: The repo should not track a real root `shiki.dhall`; the implementation ships
  `shiki.dhall.example` and adds `shiki.dhall` to `.gitignore` instead.
  Evidence: `dhall resolve --file shiki.dhall.example` succeeds, and a temporary
  validation copy at `shiki.dhall` made `shiki config show` print the expected masked URL.

- Discovery: `cabal test all` in this workspace runs tests for local dependency packages
  as well as `shiki-core` and `shiki-cli`, producing very large output, but it exited 0.
  Evidence: the command completed successfully after the package-specific `shiki-core` and
  `shiki-cli` suites had already passed.


## Decision Log

- Decision: `Environment` is a Dhall/Haskell record with a single `databaseUrl : Text`
  field rather than a bare `Text`.
  Rationale: The MasterPlan states this config will be reused by future features; a record
  grows additively without breaking the type or its consumers.
  Date: 2026-06-11

- Decision: `environments` is modelled as a `Map Text Environment` keyed by environment
  name, surfaced in Dhall as a list of `{ mapKey : Text, mapValue : Environment }` records
  (Dhall's standard association-list encoding, which the `dhall` Haskell library decodes to
  `Data.Map`).
  Rationale: Map keying is the natural model ("look up the environment named `staging`") and
  the `dhall` library already supports decoding to `Data.Map`.
  Date: 2026-06-11

- Decision: `shiki.dhall` discovery walks up from the current working directory to the
  filesystem root and stops at the first match; absence is not an error.
  Rationale: "Local for each project," usable from any subdirectory; backward compatible.
  Date: 2026-06-11

- Decision: Active-environment precedence is `--env` flag → `SHIKI_ENV` env var →
  `defaultEnvironment` from the config.
  Rationale: User selection during planning; mirrors shiki's existing flag → env → default
  pattern (`--db`/`SHIKI_DATABASE_URL`, `--db-schema`/`SHIKI_DB_SCHEMA`).
  Date: 2026-06-11

- Decision: Ship a copyable `shiki.dhall.example` and ignore local `shiki.dhall` files
  instead of tracking a root `shiki.dhall`.
  Rationale: Project config can contain real database URLs or Dhall environment imports, so
  the repository should provide a safe template while leaving operator-specific config
  untracked. This preserves the project-local workflow without encouraging secrets or
  machine-local settings in commits.
  Date: 2026-06-11


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.

Completed EP-12 on 2026-06-11. The repository now has shared Dhall types, Haskell project
configuration types, a Dhall loader, upward discovery of `shiki.dhall`, active environment
resolution, and a read-only `shiki config show` command with masked URI passwords. The
foundation remains inert for database-touching commands; `Shiki.Cli.Config` and
`withDbEnv` were not changed, leaving the live connection-routing work to
`docs/plans/13-route-run-storage-to-the-active-environment-database.md`.

Validation passed with `cabal test shiki-core`, `cabal test shiki-cli`, and
`cabal test all`. Manual command checks passed for no-config discovery, default selection,
`--env prod`, `SHIKI_ENV=prod`, and `dhall resolve --file shiki.dhall.example`.


## Context and Orientation

`shiki` is a Haskell project built with **Cabal** and a multi-package `cabal.project`. There
are two packages:

- `shiki-core` (library at `shiki-core/`) — domain logic: service-config types, PostgreSQL
  persistence, Kubernetes client, analysis. Its cabal file is `shiki-core/shiki-core.cabal`.
- `shiki-cli` (library + `shiki` executable at `shiki-cli/`) — the command-line interface.
  Its cabal file is `shiki-cli/shiki-cli.cabal`.

Both packages use GHC2024 with these default extensions enabled project-wide (declared in
each cabal file's `common-options`, so you do **not** repeat them per-module):
`DeriveAnyClass`, `DuplicateRecordFields`, `MultilineStrings`, `OverloadedLabels`,
`OverloadedStrings`, `PackageImports`. Note `PackageImports`: this project writes imports as
`import "text" Data.Text qualified as Text` (the quoted string is the package name). Match
that style in every new module. Note `OverloadedLabels` + the `generic-lens`/`lens`
libraries: records are accessed with `value ^. #fieldName`.

**Dhall, in one paragraph.** Dhall is a typed configuration language. A `.dhall` file
evaluates to a value (here, a record). The Haskell `dhall` library (version `^>=1.42`, see
`shiki-core/shiki-core.cabal`) decodes a Dhall value into a Haskell value via a `FromDhall`
typeclass instance. This project derives those instances generically: when Haskell record
field names and constructor names line up with the Dhall record field names and union
alternatives, no manual mapping is needed. The existing example is
`shiki-core/src/Shiki/Service/Config/Dhall.hs`, which decodes `services/<name>.dhall` files
into a `ServiceConfig`. Read that file before you start; this plan mirrors its structure
closely.

**How service configs are loaded today (the pattern to mirror).** The function
`loadServiceConfig :: FilePath -> IO ServiceConfig` in
`shiki-core/src/Shiki/Service/Config/Dhall.hs` is literally:

```haskell
loadServiceConfig :: FilePath -> IO ServiceConfig
loadServiceConfig = Dhall.inputFile Dhall.auto
```

`Dhall.inputFile Dhall.auto path` reads the file at `path`, evaluates it, and decodes it
using the generically-derived `FromDhall` instance for the result type. The `ServiceConfig`
type lives in `shiki-core/src/Shiki/Service/Config.hs` and derives `FromJSON`/`ToJSON`
generically (via `deriving anyclass`). The `FromDhall` instances live in the separate
`.Dhall` module via `deriving anyclass instance Dhall.FromDhall ServiceConfig` and friends.

**Shared Dhall type files.** Reusable Dhall type definitions live under
`shiki-core/dhall/`. There is exactly one today: `shiki-core/dhall/AnalyzerBackend.dhall`,
whose entire content is:

```dhall
{- A pluggable analyzer backend selector. Used by ServiceConfig.analyzer. -}
< Heuristic | Baikai : { model : Text } | None >
```

A service file imports it with a relative path, e.g. in `services/mls-service-v2.dhall`:

```dhall
let AnalyzerBackend = ../shiki-core/dhall/AnalyzerBackend.dhall
```

These shared `.dhall` files are shipped with the package as **data files**. In
`shiki-core/shiki-core.cabal` you will currently find only the SQL migrations registered:

```cabal
extra-source-files: sql/migrations/*.sql
data-files:         sql/migrations/*.sql
```

This plan adds the new `dhall/*.dhall` files to both stanzas.

**The CLI command structure.** The top-level command parser lives in
`shiki-cli/src/Shiki/Cli.hs` (module `Shiki.Cli`). It defines:

```haskell
data Command
  = Run         !RunOptions
  | Runs        !RunsCommand
  | ServiceShow !(Maybe Text)
  | Agent       !AgentCommand
  | Help        !HelpCommand
  deriving stock (Generic, Eq, Show)

data Options = Options
  { dbConnStr :: !(Maybe Text)
  , dbSchema  :: !(Maybe Text)
  , command   :: !Command
  }
  deriving stock (Generic, Eq, Show)
```

`runCli` parses `Options` and dispatches on `opts ^. #command`. The parser is built with
the `optparse-applicative` library (imported as `Opt`). The global options `--db` and
`--db-schema` are parsed in `optionsParser` and apply to all subcommands; subcommands are
defined in `commandParser` via `Opt.hsubparser`. This plan adds a `Config !ConfigCommand`
constructor to `Command`, a `config` subcommand to `commandParser`, and an `envName ::
!(Maybe Text)` field to `Options` parsed as a global `--env` flag.

**Where things connect at runtime.** `shiki-cli/src/Shiki/Cli/Env.hs` defines `withCliEnv`,
which acquires the database pool and Kubernetes client; `shiki-cli/src/Shiki/Cli/Config.hs`
defines `resolveConnectionString`, the global connection-string resolver. **This plan does
not modify either of those** — they are listed only so you understand the surrounding code.
The next plan (EP-13) modifies them.

**Prelude.** Both packages import a custom prelude, `Shiki.Prelude` (file
`shiki-core/src/Shiki/Prelude.hs`). It re-exports common names (`Text`, `Generic`, `(^.)`,
`fromMaybe`, `FromJSON`, `ToJSON`, `getCurrentTime`, etc.). When you need something common,
import `Shiki.Prelude` first and only add explicit package-qualified imports for what it
does not provide. Read `shiki-core/src/Shiki/Prelude.hs` early so you know what is already
in scope. The `shiki-cli` package can import `Shiki.Prelude` because it depends on
`shiki-core`.

**Term definitions used in this plan.**

- *Environment* (in the `shiki.dhall` sense): a named bundle of settings, currently just a
  PostgreSQL connection string. Examples: `staging`, `prod`. Do not confuse this with a
  *Kubernetes namespace* (the `--namespace` flag of `shiki run`) or with OS *environment
  variables*; where ambiguity is possible the plan says "shiki environment" vs "env var".
- *Active environment*: the one environment selected for the current invocation, resolved
  from `--env` / `SHIKI_ENV` / `defaultEnvironment`.
- *libpq connection string*: a PostgreSQL connection string, either the URI form
  (`postgresql://user:pass@host:5432/dbname`) or the keyword form
  (`host=... user=... dbname=...`). `shiki` already treats the connection string as opaque
  `Text` and passes it to the `hasql` library; this plan does the same.


## Plan of Work

The work is four milestones. M1 and M2 are pure library additions with unit tests and no
user-visible surface. M3 adds the `shiki config show` command and the global `--env` flag.
M4 documents the feature and ships an example file. Implement them in order; each is
independently verifiable.

### Milestone 1 — Shared Dhall types, Haskell config types, and loader

Scope: introduce the configuration data model in both Dhall and Haskell, plus a loader that
reads a `shiki.dhall` file into a `ProjectConfig`. At the end of this milestone there is no
CLI surface yet, but a unit test proves a sample Dhall file decodes into the expected
Haskell value.

First add two shared Dhall type files under `shiki-core/dhall/`.

`shiki-core/dhall/Environment.dhall` — the per-environment record type:

```dhall
{- A named shiki environment: the settings that vary between, e.g., staging
   and prod. Currently just a PostgreSQL connection string; new fields may be
   added here over time (they must also be added to the Haskell Environment
   record in shiki-core/src/Shiki/Project/Config.hs). -}
{ databaseUrl : Text }
```

`shiki-core/dhall/ProjectConfig.dhall` — the whole-file type. It imports `Environment`:

```dhall
{- The shape of a project-local shiki.dhall file.

   environments is a Dhall "Map" (association list) from environment name to
   its Environment record. defaultEnvironment names the environment used when
   neither --env nor SHIKI_ENV is supplied. -}
let Environment = ./Environment.dhall

in  { environments : List { mapKey : Text, mapValue : Environment }
    , defaultEnvironment : Text
    }
```

Note the `List { mapKey : Text, mapValue : ... }` shape: this is Dhall's standard encoding
of a map. The `dhall` Haskell library decodes this directly into `Data.Map.Strict.Map Text
Environment` when the target Haskell field has that type — you do not need any custom
decoder for the map.

Next add the Haskell types in a new file `shiki-core/src/Shiki/Project/Config.hs`. Mirror
the style of `shiki-core/src/Shiki/Service/Config.hs` (module header comment, explicit
export list, `deriving stock (Generic, Eq, Show)` plus `deriving anyclass (FromJSON,
ToJSON)`):

```haskell
-- | Project-local configuration loaded from a @shiki.dhall@ file at (or
--   above) the working directory. Models a set of named "environments"
--   (e.g. @staging@, @prod@), each carrying its own PostgreSQL connection
--   string, plus which environment is the default. The Dhall type
--   definitions live in @shiki-core\/dhall\/ProjectConfig.dhall@ and
--   @shiki-core\/dhall\/Environment.dhall@; the loader lives in
--   "Shiki.Project.Config.Dhall".
module Shiki.Project.Config
  ( EnvironmentName (..)
  , Environment (..)
  , ProjectConfig (..)
  ) where

import Shiki.Prelude
import "containers" Data.Map.Strict (Map)

-- | The name of a shiki environment (e.g. @"staging"@). Wrapped so it
--   cannot be confused with a Kubernetes namespace or any other free-form
--   identifier.
newtype EnvironmentName = EnvironmentName { unEnvironmentName :: Text }
  deriving stock (Generic, Eq, Ord, Show)
  deriving newtype (FromJSON, ToJSON)

-- | The settings that vary per environment. Currently just a libpq-style
--   PostgreSQL connection string. Add fields here as future features need
--   them, and mirror the addition in @shiki-core\/dhall\/Environment.dhall@.
data Environment = Environment
  { databaseUrl :: !Text
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

-- | The whole parsed @shiki.dhall@ file. @environments@ is keyed by
--   environment name; @defaultEnvironment@ names the one used when neither
--   @--env@ nor @SHIKI_ENV@ is given.
data ProjectConfig = ProjectConfig
  { environments       :: !(Map Text Environment)
  , defaultEnvironment :: !Text
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)
```

Then add the loader and `FromDhall` instances in
`shiki-core/src/Shiki/Project/Config/Dhall.hs`, mirroring
`shiki-core/src/Shiki/Service/Config/Dhall.hs`:

```haskell
{-# OPTIONS_GHC -Wno-orphans #-}

-- | Load a 'ProjectConfig' from a @shiki.dhall@ file on disk. The file
--   must evaluate to a record matching 'ProjectConfig'. See the example at
--   the repository root's @shiki.dhall@ (added by this plan's Milestone 4).
--
--   The @FromDhall@ instances are derived generically: the Haskell record
--   field names line up with the Dhall record field names, and the
--   @environments@ field decodes from Dhall's @List { mapKey, mapValue }@
--   map encoding into 'Data.Map.Strict.Map' automatically.
module Shiki.Project.Config.Dhall
  ( loadProjectConfig
  ) where

import Shiki.Project.Config (Environment, ProjectConfig)
import "dhall" Dhall qualified

loadProjectConfig :: FilePath -> IO ProjectConfig
loadProjectConfig = Dhall.inputFile Dhall.auto

deriving anyclass instance Dhall.FromDhall Environment

deriving anyclass instance Dhall.FromDhall ProjectConfig
```

Note: the function is named `loadProjectConfig` here in the *core* package's `.Dhall`
module. Milestone 2 re-exports it through `shiki-cli`'s `Shiki.Cli.Project` so CLI callers
have a single import. (If `Dhall.auto`'s generic decoder cannot resolve `EnvironmentName`
because nothing references it in the Dhall shape, that is fine — `EnvironmentName` is a
convenience newtype for Haskell-side code and is not part of the on-disk Dhall record;
do not add a `FromDhall EnvironmentName` instance unless a later milestone needs it.)

Register the new modules in `shiki-core/shiki-core.cabal`. In the `library` stanza's
`exposed-modules` list (currently ending at `Shiki.Service.Config.Dhall`), add:

```cabal
    Shiki.Project.Config
    Shiki.Project.Config.Dhall
```

In the same file, extend the data-files and source-files stanzas so the shared Dhall files
ship with the package and are picked up by relative imports at build/test time. Change:

```cabal
extra-source-files: sql/migrations/*.sql
data-files:         sql/migrations/*.sql
```

to:

```cabal
extra-source-files:
  sql/migrations/*.sql
  dhall/*.dhall

data-files:
  sql/migrations/*.sql
  dhall/*.dhall
```

Finally add a round-trip test. Create `shiki-core/test/Shiki/Project/ConfigSpec.hs` that
writes a sample `shiki.dhall` to a temporary directory, loads it with `loadProjectConfig`,
and asserts the resulting `ProjectConfig` equals the expected value. Use the `tasty` +
`tasty-hunit` libraries already used by the test suite, and the `temporary` /
`directory` libraries. A concrete shape (adapt imports to match existing specs such as
`shiki-core/test/Shiki/Service/ConfigSpec.hs`):

```haskell
module Shiki.Project.ConfigSpec (tests) where

import Shiki.Project.Config (Environment (..), ProjectConfig (..))
import Shiki.Project.Config.Dhall (loadProjectConfig)

import "containers" Data.Map.Strict qualified as Map
import "tasty" Test.Tasty (TestTree, testGroup)
import "tasty-hunit" Test.Tasty.HUnit (testCase, (@?=))
import "temporary" System.IO.Temp (withSystemTempDirectory)
import "text" Data.Text qualified as Text

tests :: TestTree
tests =
  testGroup "Shiki.Project.Config"
    [ testCase "round-trips a two-environment shiki.dhall" $
        withSystemTempDirectory "shiki-cfg" $ \dir -> do
          let path = dir <> "/shiki.dhall"
          writeFile path sample
          cfg <- loadProjectConfig path
          cfg @?= expected
    ]

sample :: String
sample =
  Text.unpack $ Text.unlines
    [ "{ environments ="
    , "    [ { mapKey = \"staging\""
    , "      , mapValue = { databaseUrl = \"postgresql://s/staging\" }"
    , "      }"
    , "    , { mapKey = \"prod\""
    , "      , mapValue = { databaseUrl = \"postgresql://s/prod\" }"
    , "      }"
    , "    ]"
    , ", defaultEnvironment = \"staging\""
    , "}"
    ]

expected :: ProjectConfig
expected =
  ProjectConfig
    { environments =
        Map.fromList
          [ ("staging", Environment { databaseUrl = "postgresql://s/staging" })
          , ("prod",    Environment { databaseUrl = "postgresql://s/prod" })
          ]
    , defaultEnvironment = "staging"
    }
```

Register the new test module and the `temporary` dependency in
`shiki-core/shiki-core.cabal`'s `test-suite shiki-core-test`: add
`Shiki.Project.ConfigSpec` to `other-modules` and `temporary >=1.3` to that stanza's
`build-depends` (the `shiki-cli` test suite already depends on `temporary`, confirming it
is available in the dependency set). Wire `Shiki.Project.ConfigSpec.tests` into the suite's
aggregator `shiki-core/test/Spec.hs` (open that file and add the new `tests` to the list of
test groups, following how the existing specs are aggregated there).

Acceptance for M1: `cabal build shiki-core` succeeds and `cabal test shiki-core` runs the
new round-trip test and it passes. See Concrete Steps for exact commands and expected
output.

### Milestone 2 — Discovery and active-environment resolution

Scope: add the CLI-side module that (a) finds `shiki.dhall` by walking up from the current
directory, (b) loads it, and (c) resolves which environment is active. At the end there is
still no user-visible command, but unit tests prove discovery and resolution behave
correctly.

Create `shiki-cli/src/Shiki/Cli/Project.hs`. It depends on `shiki-core`'s
`Shiki.Project.Config` and `Shiki.Project.Config.Dhall`, and on the `directory` and
`filepath` libraries (both already in `shiki-cli`'s `build-depends`) plus
`System.Environment.lookupEnv` from `base`. Implement exactly this surface (these
signatures are the **integration point** the next plan depends on — see the MasterPlan's
Integration Points section — do not change them without updating the MasterPlan):

```haskell
-- | Discover and resolve project-local configuration from @shiki.dhall@.
--   "Project-local" means the file is found by walking up from the current
--   working directory to the filesystem root and taking the first match.
module Shiki.Cli.Project
  ( -- re-exports so CLI callers need one import
    ProjectConfig (..)
  , Environment (..)
  , discoverProjectConfigPath
  , loadProjectConfig
  , resolveActiveEnvironmentName
  , resolveActiveEnvironment
  , EnvSelectionSource (..)
  ) where

import Shiki.Prelude

import Shiki.Project.Config (Environment (..), ProjectConfig (..))
import Shiki.Project.Config.Dhall (loadProjectConfig)

import "containers" Data.Map.Strict qualified as Map
import "directory" System.Directory (doesFileExist, getCurrentDirectory)
import "filepath" System.FilePath (takeDirectory, (</>))
import "text" Data.Text qualified as Text
import "base" System.Environment (lookupEnv)

-- | Where the active environment name came from. Used by @config show@ to
--   tell the operator why a particular environment is active.
data EnvSelectionSource
  = FromFlag       -- ^ the @--env@ flag
  | FromEnvVar     -- ^ the @SHIKI_ENV@ environment variable
  | FromDefault    -- ^ @defaultEnvironment@ in shiki.dhall
  deriving stock (Generic, Eq, Show)

-- | Walk up from the current working directory looking for a file named
--   @shiki.dhall@. Returns its absolute path on the first match, or
--   'Nothing' if the filesystem root is reached without finding one.
discoverProjectConfigPath :: IO (Maybe FilePath)
discoverProjectConfigPath = getCurrentDirectory >>= go
  where
    go dir = do
      let candidate = dir </> "shiki.dhall"
      found <- doesFileExist candidate
      if found
        then pure (Just candidate)
        else
          let parent = takeDirectory dir
           in if parent == dir         -- reached the root: takeDirectory "/" == "/"
                then pure Nothing
                else go parent

-- | Resolve the active environment NAME and where it came from, given the
--   loaded config and the optional @--env@ flag value. Precedence:
--   @--env@ flag, then @SHIKI_ENV@ env var, then @defaultEnvironment@.
resolveActiveEnvironmentName
  :: ProjectConfig
  -> Maybe Text
  -> IO (Text, EnvSelectionSource)
resolveActiveEnvironmentName cfg mFlag =
  case mFlag of
    Just name | not (Text.null name) -> pure (name, FromFlag)
    _ -> do
      mEnv <- lookupEnv "SHIKI_ENV"
      pure $ case mEnv of
        Just s | not (null s) -> (Text.pack s, FromEnvVar)
        _                     -> (cfg ^. #defaultEnvironment, FromDefault)

-- | Discover, load, and resolve in one step. Returns 'Nothing' when no
--   @shiki.dhall@ is discovered (callers fall back to legacy behavior).
--   When a config IS found but the resolved environment name is not one of
--   its declared environments, this calls 'error' with a clear message
--   (an explicit @--env typo@ should fail loudly, not silently fall back).
resolveActiveEnvironment :: Maybe Text -> IO (Maybe (Text, Environment))
resolveActiveEnvironment mFlag =
  discoverProjectConfigPath >>= \case
    Nothing   -> pure Nothing
    Just path -> do
      cfg <- loadProjectConfig path
      (name, _src) <- resolveActiveEnvironmentName cfg mFlag
      case Map.lookup name (cfg ^. #environments) of
        Just e  -> pure (Just (name, e))
        Nothing ->
          error
            ( "shiki: environment "
                <> Text.unpack name
                <> " is not declared in "
                <> path
                <> " (declared: "
                <> Text.unpack (Text.intercalate ", " (Map.keys (cfg ^. #environments)))
                <> ")"
            )
```

Register `Shiki.Cli.Project` in `shiki-cli/shiki-cli.cabal`'s `library` `exposed-modules`
list (add the line after `Shiki.Cli.Help` or in alphabetical position; the list is not
strictly sorted but keep it tidy).

Add a unit test `shiki-cli/test/Shiki/Cli/ProjectSpec.hs`. Discovery is exercised by
creating a nested temp directory tree, writing `shiki.dhall` at the top, `cd`-ing into a
leaf, and asserting `discoverProjectConfigPath` finds the top file. Resolution is exercised
by calling `resolveActiveEnvironmentName` with and without a flag and (using
`System.Environment.setEnv`/`unsetEnv`) with and without `SHIKI_ENV`. Because
`getCurrentDirectory` and `SHIKI_ENV` are process-global, keep these in a single test case
that saves and restores the working directory and the env var to avoid cross-test
interference. Register the module in the `test-suite shiki-cli-test` `other-modules` list in
`shiki-cli/shiki-cli.cabal` (the suite already depends on `temporary`, `directory`,
`filepath`, `tasty`, `tasty-hunit`, `text`).

Acceptance for M2: `cabal test shiki-cli` runs the new discovery/resolution tests and they
pass.

### Milestone 3 — `shiki config show` command and the global `--env` flag

Scope: expose a read-only `shiki config show` subcommand and a global `--env NAME` flag. At
the end an operator can run `shiki config show [--env NAME]` and see their resolved
configuration with the active database URL's password masked. No database connection is
opened.

Create `shiki-cli/src/Shiki/Cli/ConfigShow.hs`:

```haskell
-- | The @shiki config show@ subcommand: discover the project-local
--   @shiki.dhall@, resolve the active environment, and print a human-readable
--   summary. Read-only: it never opens a database connection or contacts the
--   cluster. The @--env@ flag is the global one parsed in "Shiki.Cli".
module Shiki.Cli.ConfigShow
  ( runConfigShow
  ) where

import Shiki.Prelude

import Shiki.Cli.Project
  ( Environment (..)
  , ProjectConfig (..)
  , discoverProjectConfigPath
  , loadProjectConfig
  , resolveActiveEnvironmentName
  , EnvSelectionSource (..)
  )

import "containers" Data.Map.Strict qualified as Map
import "text" Data.Text qualified as Text
import "text" Data.Text.IO qualified as TIO

-- | Render a connection string with any password masked. Handles the URI
--   form (@scheme://user:PASSWORD@host/...@) by replacing the password run
--   between the first @':'@ after @"//"@ and the next @'@'@ with @****@.
--   Strings without that shape are returned unchanged. This is best-effort
--   display hygiene, not security.
maskPassword :: Text -> Text
maskPassword url =
  case Text.breakOn "://" url of
    (_, rest) | not (Text.null rest) ->
      let scheme   = Text.take (Text.length url - Text.length rest) url
          afterSep = Text.drop 3 rest -- drop "://"
       in case Text.breakOn "@" afterSep of
            (authority, hostPart)
              | not (Text.null hostPart) ->
                  case Text.breakOn ":" authority of
                    (user, pwd)
                      | not (Text.null pwd) ->
                          scheme <> "://" <> user <> ":****" <> hostPart
                    _ -> url
            _ -> url
    _ -> url

runConfigShow :: Maybe Text -> IO ()
runConfigShow mEnvFlag =
  discoverProjectConfigPath >>= \case
    Nothing ->
      TIO.putStrLn
        "no shiki.dhall found (searched the current directory and its parents)"
    Just path -> do
      cfg <- loadProjectConfig path
      (active, src) <- resolveActiveEnvironmentName cfg mEnvFlag
      let envNames = Text.intercalate ", " (Map.keys (cfg ^. #environments))
          srcLabel = case src of
            FromFlag    -> "from --env"
            FromEnvVar  -> "from SHIKI_ENV"
            FromDefault -> "from defaultEnvironment"
      TIO.putStrLn ("config file:         " <> Text.pack path)
      TIO.putStrLn ("environments:        " <> envNames)
      TIO.putStrLn ("default environment: " <> cfg ^. #defaultEnvironment)
      TIO.putStrLn ("active environment:  " <> active <> "   (" <> srcLabel <> ")")
      case Map.lookup active (cfg ^. #environments) of
        Just e  ->
          TIO.putStrLn ("database url:        " <> maskPassword (e ^. #databaseUrl))
        Nothing ->
          TIO.putStrLn
            ( "database url:        <environment "
                <> active
                <> " is not declared in this file>"
            )
```

Now wire it into the parser in `shiki-cli/src/Shiki/Cli.hs`:

1. Add the import near the other handler imports:

   ```haskell
   import Shiki.Cli.ConfigShow (runConfigShow)
   ```

2. Add a `ConfigCommand` data type and a constructor to `Command`. Keep `config` a
   subcommand group (so `config show` reads naturally and leaves room for future
   `config <other>` verbs):

   ```haskell
   data ConfigCommand
     = ConfigShow
     deriving stock (Generic, Eq, Show)

   data Command
     = Run         !RunOptions
     | Runs        !RunsCommand
     | ServiceShow !(Maybe Text)
     | Agent       !AgentCommand
     | Help        !HelpCommand
     | Config      !ConfigCommand     -- new
     deriving stock (Generic, Eq, Show)
   ```

3. Add the global `--env` field to `Options`:

   ```haskell
   data Options = Options
     { dbConnStr :: !(Maybe Text)
     , dbSchema  :: !(Maybe Text)
     , envName   :: !(Maybe Text)     -- new: the --env flag
     , command   :: !Command
     }
     deriving stock (Generic, Eq, Show)
   ```

4. Parse `--env` in `optionsParser`, after the `--db-schema` option and before
   `commandParser` (so the applicative order matches the record field order):

   ```haskell
       <*> Opt.optional
             ( Opt.strOption
                 ( Opt.long "env"
                     <> Opt.metavar "NAME"
                     <> Opt.help
                         "shiki environment from shiki.dhall (overrides SHIKI_ENV / defaultEnvironment)"
                 )
             )
       <*> commandParser
   ```

5. Add the `config` subcommand to `commandParser`'s `Opt.hsubparser` block:

   ```haskell
       <> Opt.command
         "config"
         ( Opt.info
             (Config <$> configSubparser)
             (Opt.progDesc "Inspect project-local shiki.dhall configuration")
         )
   ```

   and define `configSubparser` near `serviceSubparser`:

   ```haskell
   configSubparser :: Parser Command -> ...  -- see note
   configSubparser =
     Opt.hsubparser
       ( Opt.command "show"
           ( Opt.info
               (pure ConfigShow)
               (Opt.progDesc "Show the resolved project configuration and active environment")
           )
       )
   ```

   (The type of `configSubparser` is `Parser ConfigCommand`; the `Config <$>` in the
   `command` entry lifts it to `Parser Command`. Match the exact shape of the existing
   `serviceSubparser` for the surrounding style.)

6. Dispatch in `runCli`. The `Config` branch must **not** call `withDbEnv` (it opens no
   database). Add to the `case opts ^. #command of` block:

   ```haskell
       Config ConfigShow ->
         runConfigShow (opts ^. #envName)
   ```

Register `Shiki.Cli.ConfigShow` in `shiki-cli/shiki-cli.cabal`'s `library`
`exposed-modules`.

Acceptance for M3: build succeeds, `shiki config show` prints the "no shiki.dhall found"
line when run outside a project, and prints the full resolved summary (with masked
password) when a `shiki.dhall` is present. See Concrete Steps for the exact transcript to
reproduce.

### Milestone 4 — Documentation and example file

Scope: ship an example `shiki.dhall` and document the new command, the file format, and the
`--env` / `SHIKI_ENV` resolution. No code changes.

Create an example file at the repository root named `shiki.dhall`. Because this file sits at
the repo root, its relative import of the shared Dhall type points at
`shiki-core/dhall/...`:

```dhall
{- Project-local shiki configuration.

   Declares the shiki environments available in this checkout and which one
   is the default. `shiki config show` prints the resolved configuration;
   `shiki run --env <name> ...` (see EP-13) records runs into the named
   environment's database.

   Connection strings may be inlined as shown, or sourced from OS environment
   variables using Dhall's native import, e.g.:
     databaseUrl = env:SHIKI_STAGING_DATABASE_URL as Text
-}
let Environment = ./shiki-core/dhall/Environment.dhall

let mkEnv = \(url : Text) -> { databaseUrl = url } : Environment

in  { environments =
        toMap
          { staging = mkEnv "postgresql://shiki:changeme@db.staging.internal:5432/shiki"
          , prod    = mkEnv "postgresql://shiki:changeme@db.prod.internal:5432/shiki"
          }
    , defaultEnvironment = "staging"
    }
```

Note `toMap { staging = ..., prod = ... }`: Dhall's `toMap` turns a record into the
`List { mapKey, mapValue }` association-list shape that `ProjectConfig.dhall` declares — the
same idiom `services/mls-service-v2.dhall` uses for `nodeSelector`. This file is a working
example operators copy and edit; the placeholder passwords make clear it is a template.

Decide whether the example `shiki.dhall` should be git-ignored. Check `.gitignore`: if real
operators are expected to keep their own untracked `shiki.dhall`, add `shiki.dhall` to
`.gitignore` and commit the example under a different name such as `shiki.dhall.example`,
adjusting the docs accordingly. Record the choice in the Decision Log. (Recommended: ship
`shiki.dhall.example` and git-ignore `shiki.dhall`, mirroring common practice for
machine-specific config; but the repo currently tracks `services/*.dhall`, so committing a
template `shiki.dhall` directly is also acceptable. Either way, state it in the docs.)

Add user documentation. Create `docs/user/project-config.md` describing: what `shiki.dhall`
is, where shiki looks for it (upward walk from the cwd), the file format (with the example
above), the `--env` / `SHIKI_ENV` / `defaultEnvironment` precedence, and the `shiki config
show` command with a sample transcript. Cross-link it from `docs/user/README.md` (add a
bullet next to the existing "Service configuration" entry) and from `README.md` if it lists
docs. Mention explicitly that, as of this plan, `shiki.dhall` only affects `shiki config
show`; the database connection used by `run`/`runs`/`agent` is wired to it by the follow-up
work in `docs/plans/13-route-run-storage-to-the-active-environment-database.md`.

Acceptance for M4: the example file evaluates (`dhall resolve --file shiki.dhall` or
`shiki config show` from the repo root succeeds), and the docs render the command and format
correctly.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/shiki` unless
stated otherwise. This project uses a Nix dev shell; if commands are not found, prefix them
with `nix develop -c` (for example `nix develop -c cabal build all`). The `cabal` and
`dhall` binaries, and the `bun` used for plan scripts, are provided by that shell.

Build the whole workspace after each milestone:

```bash
cabal build all
```

Run a single package's tests:

```bash
cabal test shiki-core         # after M1
cabal test shiki-cli          # after M2 and M3
cabal test all                # before considering the plan done
```

Expected M1 test output (names illustrative; the key is the new group passes):

```text
Shiki.Project.Config
  round-trips a two-environment shiki.dhall: OK
All N tests passed
```

Try the command after M3, first from a directory with no `shiki.dhall` (use a fresh temp
dir):

```bash
cd /tmp && cabal --project-dir=/Users/shinzui/Keikaku/bokuno/shiki run shiki -- config show
```

Expected:

```text
no shiki.dhall found (searched the current directory and its parents)
```

Then create the example at the repo root (Milestone 4) and run from there:

```bash
cd /Users/shinzui/Keikaku/bokuno/shiki
cabal run shiki -- config show
```

Expected (password masked, environments sorted by `Map` key order):

```text
config file:         /Users/shinzui/Keikaku/bokuno/shiki/shiki.dhall
environments:        prod, staging
default environment: staging
active environment:  staging   (from defaultEnvironment)
database url:        postgresql://shiki:****@db.staging.internal:5432/shiki
```

And with selection:

```bash
cabal run shiki -- config show --env prod
SHIKI_ENV=prod cabal run shiki -- config show
```

The first prints `active environment:  prod   (from --env)`; the second prints
`active environment:  prod   (from SHIKI_ENV)`.

Update this section with the actual observed transcripts as you implement.

Observed 2026-06-11 after implementation:

```text
$ cabal test shiki-core
Shiki.Project.Config
  round-trips a two-environment shiki.dhall: OK
All 31 tests passed
```

```text
$ cabal test shiki-cli
Shiki.Cli.Project
  discovers shiki.dhall in an ancestor directory:             OK
  resolves active environment by flag, env var, then default: OK
All 33 tests passed
```

```text
$ cd /tmp && cabal --project-dir=/Users/shinzui/Keikaku/bokuno/shiki run shiki -- config show
no shiki.dhall found (searched the current directory and its parents)
```

With a temporary local `shiki.dhall` copied from `shiki.dhall.example`:

```text
$ cabal run shiki -- config show
config file:         /Users/shinzui/Keikaku/bokuno/shiki/shiki.dhall
environments:        prod, staging
default environment: staging
active environment:  staging   (from defaultEnvironment)
database url:        postgresql://shiki:****@db.staging.internal:5432/shiki
```

```text
$ cabal run shiki -- config show --env prod
config file:         /Users/shinzui/Keikaku/bokuno/shiki/shiki.dhall
environments:        prod, staging
default environment: staging
active environment:  prod   (from --env)
database url:        postgresql://shiki:****@db.prod.internal:5432/shiki
```

```text
$ SHIKI_ENV=prod cabal run shiki -- config show
config file:         /Users/shinzui/Keikaku/bokuno/shiki/shiki.dhall
environments:        prod, staging
default environment: staging
active environment:  prod   (from SHIKI_ENV)
database url:        postgresql://shiki:****@db.prod.internal:5432/shiki
```

```text
$ dhall resolve --file shiki.dhall.example
let Environment = { databaseUrl : Text }

let mkEnv = \(url : Text) -> { databaseUrl = url } : Environment

in  { environments = toMap
        { staging =
            mkEnv "postgresql://shiki:changeme@db.staging.internal:5432/shiki"
        , prod = mkEnv "postgresql://shiki:changeme@db.prod.internal:5432/shiki"
        }
    , defaultEnvironment = "staging"
    }
```

```text
$ cabal test all
... command completed successfully with exit code 0
```


## Validation and Acceptance

The plan is acceptable when all of the following hold:

1. `cabal build all` and `cabal test all` succeed from the repository root.
2. The M1 round-trip test decodes a sample `shiki.dhall` into the expected `ProjectConfig`
   (proves the Dhall ↔ Haskell mapping, including the map-encoded `environments`).
3. The M2 tests prove: discovery finds a `shiki.dhall` placed in an ancestor directory; and
   `resolveActiveEnvironmentName` returns the flag value when a flag is given, the
   `SHIKI_ENV` value when no flag but the env var is set, and `defaultEnvironment`
   otherwise.
4. `shiki config show` from a directory with no `shiki.dhall` prints the "no shiki.dhall
   found" line and exits 0 (it is informational, not an error).
5. `shiki config show` from a project with the example file prints the config path, the
   environment names, the default, the active environment with its source annotation, and
   the active database URL **with the password masked**.
6. `shiki config show --env prod` and `SHIKI_ENV=prod shiki config show` both report `prod`
   active, with the correct source annotation.
7. `shiki run`, `shiki runs`, and `shiki agent` behave exactly as before this plan (no
   regression): run any existing CLI test suite and confirm it still passes. This guards the
   invariant that the foundation is inert with respect to the live database path.

Acceptance is behavioral: a reviewer can copy the example `shiki.dhall`, run `shiki config
show [--env ...]`, and see the resolved environment and masked URL change as documented.


## Idempotence and Recovery

All steps are additive: new files and new fields/constructors. Re-running `cabal build` /
`cabal test` is safe and repeatable. If a build fails because a new module is not found,
confirm it was added to the correct cabal stanza (`exposed-modules` for library modules,
`other-modules` for test modules) and that the file path matches the module name
(`Shiki.Project.Config` ⇒ `shiki-core/src/Shiki/Project/Config.hs`).

If the Dhall round-trip test fails to decode the map, verify `ProjectConfig.dhall` uses the
`List { mapKey : Text, mapValue : Environment }` shape and that the Haskell field type is
`Data.Map.Strict.Map Text Environment` (not `[(Text, Environment)]`). If `Dhall.auto`
complains about a missing `FromDhall` instance, confirm the `deriving anyclass instance`
lines in `Shiki.Project.Config.Dhall` cover both `Environment` and `ProjectConfig`.

The only potentially destructive choice is whether to git-ignore `shiki.dhall` (Milestone
4). Adding a line to `.gitignore` is reversible; do not delete any existing tracked file.

To back out the whole plan before merge, `git checkout` the new files and revert the cabal
and `Shiki.Cli` (`shiki-cli/src/Shiki/Cli.hs`) edits; nothing in this plan migrates data or changes runtime database
state.


## Interfaces and Dependencies

Libraries used (all already declared in the relevant cabal `build-depends`; this plan adds
only `temporary >=1.3` to `shiki-core`'s test suite):

- `dhall ^>=1.42` (`shiki-core`) — `Dhall.inputFile`, `Dhall.auto`, `Dhall.FromDhall`.
- `containers ^>=0.7` — `Data.Map.Strict.Map` for `environments`.
- `directory ^>=1.3` — `getCurrentDirectory`, `doesFileExist`.
- `filepath ^>=1.5` — `takeDirectory`, `(</>)`.
- `base` — `System.Environment.lookupEnv`.
- `text ^>=2.1` — `Data.Text`, `Data.Text.IO`.
- `optparse-applicative >=0.18` (`shiki-cli`) — parser wiring for the `config` command and
  the `--env` flag.
- `tasty`, `tasty-hunit`, `temporary` — tests.

Modules and the function signatures that must exist at the end of each milestone (these
constitute the integration surface the follow-up plan
`docs/plans/13-route-run-storage-to-the-active-environment-database.md` depends on — keep
them stable, and if you must change them, update that plan and the MasterPlan's Integration
Points section):

- After M1, in `shiki-core`:
  - `Shiki.Project.Config`: `data ProjectConfig`, `data Environment`,
    `newtype EnvironmentName`.
  - `Shiki.Project.Config.Dhall`: `loadProjectConfig :: FilePath -> IO ProjectConfig`.
- After M2, in `shiki-cli`:
  - `Shiki.Cli.Project`: re-exports `ProjectConfig (..)`, `Environment (..)`,
    `loadProjectConfig`, and adds
    `discoverProjectConfigPath :: IO (Maybe FilePath)`,
    `resolveActiveEnvironmentName :: ProjectConfig -> Maybe Text -> IO (Text, EnvSelectionSource)`,
    `resolveActiveEnvironment :: Maybe Text -> IO (Maybe (Text, Environment))`,
    `data EnvSelectionSource`.
- After M3, in `shiki-cli`:
  - `Shiki.Cli.ConfigShow`: `runConfigShow :: Maybe Text -> IO ()`.
  - `Shiki.Cli` (file `shiki-cli/src/Shiki/Cli.hs`): `Options` gains `envName :: Maybe Text`;
    `Command` gains `Config !ConfigCommand`.

This plan does **not** modify `Shiki.Cli.Config` (`resolveConnectionString`) or
`Shiki.Cli.Env` (`withCliEnv`); those are the seam the next plan changes.
