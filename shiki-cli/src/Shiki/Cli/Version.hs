{-# LANGUAGE CPP #-}
{-# LANGUAGE TemplateHaskell #-}

module Shiki.Cli.Version
  ( appVersion,
    appVersionWithGit,
    formatVersionWithGit,
    gitCommitShort,
  )
where

import Data.Text qualified as Text
import Data.Version (showVersion)
import GitHash (GitInfo, giHash, tGitInfoCwdTry)
import Paths_shiki_cli (version)
import Shiki.Prelude

appVersion :: Text
appVersion = Text.pack (showVersion version)

gitInfo :: Either String GitInfo
gitInfo = $$tGitInfoCwdTry

nixGitHash :: Maybe Text
#ifdef GIT_HASH
nixGitHash = Just GIT_HASH
#else
nixGitHash = Nothing
#endif

gitCommitShort :: Maybe Text
gitCommitShort =
  case gitInfo of
    Right gi -> nonEmptyShort (Text.pack (giHash gi)) <|> (nixGitHash >>= nonEmptyShort)
    Left _ -> nixGitHash >>= nonEmptyShort
  where
    nonEmptyShort hashText =
      let shortHash = Text.take 7 hashText
       in if Text.null shortHash
            then Nothing
            else Just shortHash

formatVersionWithGit :: Text -> Maybe Text -> Text
formatVersionWithGit versionText mCommit =
  "shiki v" <> versionText <> foldMap suffix nonEmptyCommit
  where
    nonEmptyCommit =
      mCommit >>= \commit ->
        if Text.null commit
          then Nothing
          else Just commit

    suffix commit = " (" <> commit <> ")"

appVersionWithGit :: Text
appVersionWithGit = formatVersionWithGit appVersion gitCommitShort
