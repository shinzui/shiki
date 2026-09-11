-- | A validated PostgreSQL schema (namespace) identifier. The
--   value-constructor is hidden so callers can only obtain a 'Schema' via
--   'mkSchema' or 'defaultSchema'; this gives every internal user the proof
--   that the wrapped 'Text' is safe to splice into a SQL identifier literal.
module Shiki.Persistence.Schema
  ( Schema,
    defaultSchema,
    mkSchema,
    schemaText,
    quoteSchema,
  )
where

import Data.Text qualified as Text
import Shiki.Prelude

-- | A validated PostgreSQL schema name. Members of this type are guaranteed
--   to match @[A-Za-z_][A-Za-z0-9_]*@ and to fit within PostgreSQL's
--   @NAMEDATALEN@ default (63 bytes).
newtype Schema = Schema {unSchema :: Text}
  deriving stock (Generic, Eq, Show)
  deriving newtype (FromJSON, ToJSON)

-- | The default schema used by @shiki@ when nothing else is configured.
defaultSchema :: Schema
defaultSchema = Schema "shiki"

-- | Validate and lift a 'Text' into a 'Schema'. Returns a human-readable
--   error message on failure suitable for printing to stderr.
mkSchema :: Text -> Either Text Schema
mkSchema t
  | Text.null t =
      Left "schema name is empty"
  | Text.length t > 63 =
      Left "schema name exceeds 63 bytes (PostgreSQL NAMEDATALEN)"
  | not (isInitial (Text.head t)) =
      Left "schema name must start with ASCII letter or underscore"
  | not (Text.all isSubsequent t) =
      Left "schema name may only contain ASCII letters, digits, and underscore"
  | otherwise = Right (Schema t)
  where
    isInitial c = isAsciiAlpha c || c == '_'
    isSubsequent c = isAsciiAlpha c || isAsciiDigit c || c == '_'
    isAsciiAlpha c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
    isAsciiDigit c = c >= '0' && c <= '9'

-- | The raw schema name without quoting. Use this when feeding into a SQL
--   parameter (e.g. @information_schema.tables.table_schema = $1@) or
--   composing libpq connection options.
schemaText :: Schema -> Text
schemaText = unSchema

-- | The schema name wrapped in double quotes, suitable for splicing into a
--   SQL identifier position (e.g. @CREATE SCHEMA IF NOT EXISTS "shiki"@).
--   Because 'mkSchema' rejects everything containing a double quote, no
--   escaping is needed beyond the wrapping pair.
quoteSchema :: Schema -> Text
quoteSchema (Schema s) = "\"" <> s <> "\""
