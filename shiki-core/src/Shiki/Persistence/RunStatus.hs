-- | The lifecycle state of a single run. Mirrors the @status text@ column
--   of the @runs@ table defined in
--   @shiki-core\/sql\/migrations\/001-create-runs.sql@; the table-side
--   @CHECK@ constraint enumerates the same four values that this ADT
--   defines.
module Shiki.Persistence.RunStatus
  ( RunStatus (..)
  , runStatusToText
  , runStatusFromText
  ) where

import Shiki.Prelude

import "text" Data.Text qualified as Text

data RunStatus
  = Pending
  | Running
  | Succeeded
  | Failed
  deriving stock (Generic, Eq, Show, Bounded, Enum)
  deriving anyclass (FromJSON, ToJSON)

runStatusToText :: RunStatus -> Text
runStatusToText = \case
  Pending -> "pending"
  Running -> "running"
  Succeeded -> "succeeded"
  Failed -> "failed"

runStatusFromText :: Text -> Either Text RunStatus
runStatusFromText t = case Text.toLower t of
  "pending" -> Right Pending
  "running" -> Right Running
  "succeeded" -> Right Succeeded
  "failed" -> Right Failed
  other -> Left ("unknown run status: " <> other)
