-- | Every failure @shiki@ reports, as one sum type with one renderer.
--
--   Nothing in this module prints or exits. Handlers throw a 'ShikiError'
--   through @effectful@'s typed error effect ("Effectful.Error.Static"), and
--   the single top-level handler in @Shiki.Cli.Main@ catches it, renders it
--   with 'renderShikiError', writes the one resulting line on stderr, and
--   exits 1. Keeping the rendering here means a message can be asserted in a
--   unit test without running a command.
--
--   Every rendered line starts with @shiki: @. The prefix is added by
--   'renderShikiError'; constructor payloads never carry it.
module Shiki.Error
  ( ShikiError (..),
    ConfigError (..),
    StoreError (..),
    KubeError (..),
    renderShikiError,
    renderAnalyzerError,
    collapseWhitespace,
    renderConnectionError,
    renderSessionError,
    renderUsageError,
  )
where

import Data.Text qualified as Text
import Hasql.Errors qualified as Errors
import Hasql.Pool qualified as Pool
import Shiki.Analysis.Backend (AnalyzerError (..))
import Shiki.Prelude

-- | Every failure shiki-core reports. Rendered once, by the CLI's top level.
data ShikiError
  = ShikiConfigError !ConfigError
  | ShikiStoreError !StoreError
  | ShikiKubeError !KubeError
  | ShikiAnalyzerError !AnalyzerError
  deriving stock (Generic, Eq, Show)

-- | Configuration shiki could not resolve or load: the connection string, the
--   schema name, the active environment, @shiki.dhall@, and
--   @services\/\<name\>.dhall@.
data ConfigError
  = NoConnectionString
  | InvalidSchemaName !Text
  | -- | environment name, @shiki.dhall@ path, the names it does declare
    UndeclaredEnvironment !Text !FilePath ![Text]
  | -- | path, the loader's message
    ProjectConfigInvalid !FilePath !Text
  | ServiceConfigNotFound !FilePath
  | -- | path, the loader's message
    ServiceConfigInvalid !FilePath !Text
  deriving stock (Generic, Eq, Show)

-- | Failures from the PostgreSQL side: reaching the server, applying
--   migrations, and running a statement.
data StoreError
  = -- | the connection error, already rendered
    DatabaseUnavailable !Text
  | -- | schema, the rendered migration failure
    MigrationFailed !Text !Text
  | -- | operation name (e.g. @\"list recent runs\"@), the rendered usage error
    StatementFailed !Text !Text
  deriving stock (Generic, Eq, Show)

-- | Failures from the Kubernetes side: loading the client config, the exec
--   credential plugin, and requests against the cluster.
data KubeError
  = KubeConfigUnavailable !Text
  | KubeCredentialFailed !Text
  | -- | deployment name, the rendered inspection error
    DeploymentInspectionFailed !Text !Text
  | -- | operation name, the rendered error
    KubeRequestFailed !Text !Text
  deriving stock (Generic, Eq, Show)

-- | The one line an operator sees on stderr, @shiki: @ prefix included.
renderShikiError :: ShikiError -> Text
renderShikiError = ("shiki: " <>) . body
  where
    body = \case
      ShikiConfigError e -> renderConfigError e
      ShikiStoreError e -> renderStoreError e
      ShikiKubeError e -> renderKubeError e
      ShikiAnalyzerError e -> renderAnalyzerError e

renderConfigError :: ConfigError -> Text
renderConfigError = \case
  NoConnectionString ->
    "no Postgres connection string; pass --db, add a shiki.dhall, \
    \or set SHIKI_DATABASE_URL / PG_CONNECTION_STRING"
  InvalidSchemaName e -> "invalid schema name: " <> e
  UndeclaredEnvironment name path declared ->
    "environment "
      <> name
      <> " is not declared in "
      <> Text.pack path
      <> " (declared: "
      <> Text.intercalate ", " declared
      <> ")"
  ProjectConfigInvalid path message -> "cannot load " <> Text.pack path <> ": " <> message
  ServiceConfigNotFound path -> "no service config at " <> Text.pack path
  ServiceConfigInvalid path message -> "cannot load " <> Text.pack path <> ": " <> message

renderStoreError :: StoreError -> Text
renderStoreError = \case
  DatabaseUnavailable message -> "cannot connect to the database: " <> message
  MigrationFailed schema message ->
    "migration failed for schema " <> schema <> ": " <> message
  StatementFailed operation message ->
    "database error during " <> operation <> ": " <> message

renderKubeError :: KubeError -> Text
renderKubeError = \case
  KubeConfigUnavailable message -> "cannot load the Kubernetes config: " <> message
  KubeCredentialFailed message -> "Kubernetes credential plugin failed: " <> message
  DeploymentInspectionFailed deployment message ->
    "cannot inspect deployment " <> deployment <> ": " <> message
  KubeRequestFailed operation message ->
    "Kubernetes request failed during " <> operation <> ": " <> message

-- | The analyzer wording @shiki runs analyze@ has always printed, minus the
--   @shiki: @ prefix 'renderShikiError' adds.
renderAnalyzerError :: AnalyzerError -> Text
renderAnalyzerError = \case
  AnalyzerBackendDisabled -> "analyzer disabled (backend = None)"
  AnalyzerUnknown t -> "unknown analyzer override: " <> t
  AnalyzerBaikaiError t -> "baikai backend failed: " <> t

-- | libpq's own message for a failed connection, without the Haskell
--   constructor name. What the operator needs to see is @connection to server
--   at \"127.0.0.1\", port 1 failed: Connection refused@, not
--   @NetworkingConnectionError "…"@.
--
--   libpq's message is multi-line (it adds a tab-indented hint), and every
--   shiki failure is one line, so the whitespace is collapsed rather than the
--   hint being dropped.
renderConnectionError :: Errors.ConnectionError -> Text
renderConnectionError = collapseWhitespace . reason
  where
    reason = \case
      Errors.NetworkingConnectionError t -> t
      Errors.AuthenticationConnectionError t -> t
      Errors.CompatibilityConnectionError t -> t
      Errors.OtherConnectionError t -> t

-- | A failed session, rendered with hasql's own detail formatting, collapsed
--   onto one line for the same reason as 'renderConnectionError'.
renderSessionError :: Errors.SessionError -> Text
renderSessionError = collapseWhitespace . Errors.toDetailedText

-- | Collapse every run of whitespace, newlines included, into one space.
--   Library messages that are laid out for a terminal (libpq's connection
--   hint, aeson's and yaml's exception text) become the single line every
--   shiki failure is supposed to be.
collapseWhitespace :: Text -> Text
collapseWhitespace = Text.unwords . Text.words

-- | A failed pool use, rendered for an operator.
renderUsageError :: Pool.UsageError -> Text
renderUsageError = \case
  Pool.ConnectionUsageError e -> renderConnectionError e
  Pool.SessionUsageError e -> renderSessionError e
  Pool.AcquisitionTimeoutUsageError -> "timed out waiting for a database connection"
