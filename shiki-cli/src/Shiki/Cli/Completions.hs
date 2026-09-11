-- | The @shiki completions@ subcommand. Each generator prints a static script
--   that asks the @shiki@ binary for completions at Tab time through
--   optparse-applicative's @--bash-completion-*@ protocol, so the scripts never
--   need a hand-maintained command list. Bash uses the plain protocol, because
--   Bash cannot display descriptions. Zsh and Fish use the enriched protocol,
--   which appends a tab-separated description to each word.
--
--   The scripts call @shiki@ by name rather than embedding an absolute path
--   (as optparse-applicative's built-in @--bash-completion-script PATH@ does),
--   so installed completions keep working when a Nix upgrade moves the binary
--   to a new store path.
module Shiki.Cli.Completions
  ( CompletionsShell (..),
    completionsParser,
    completionScript,
    runCompletions,
  )
where

import Data.Text qualified as Text
import Data.Text.IO qualified as TIO
import Options.Applicative (Parser, command, hsubparser, info, progDesc)
import Shiki.Prelude

data CompletionsShell = Bash | Zsh | Fish
  deriving stock (Generic, Eq, Show, Enum, Bounded)

completionsParser :: Parser CompletionsShell
completionsParser =
  hsubparser
    ( command "bash" (info (pure Bash) (progDesc "Print the Bash completion script"))
        <> command "zsh" (info (pure Zsh) (progDesc "Print the Zsh completion script"))
        <> command "fish" (info (pure Fish) (progDesc "Print the Fish completion script"))
    )

runCompletions :: CompletionsShell -> IO ()
runCompletions = TIO.putStr . completionScript

completionScript :: CompletionsShell -> Text
completionScript = \case
  Bash -> bashScript
  Zsh -> zshScript
  Fish -> fishScript

-- | @complete -o filenames@ falls back to file completion when shiki offers
--   nothing, which is what the @run@ passthrough arguments want.
bashScript :: Text
bashScript =
  Text.unlines
    [ "_shiki_completions() {",
      "    local CMDLINE",
      "    local IFS=$'\\n'",
      "    CMDLINE=(--bash-completion-index $COMP_CWORD)",
      "",
      "    for arg in ${COMP_WORDS[@]}; do",
      "        CMDLINE=(${CMDLINE[@]} --bash-completion-word \"$arg\")",
      "    done",
      "",
      "    COMPREPLY=( $(shiki \"${CMDLINE[@]}\" 2>/dev/null) )",
      "}",
      "",
      "complete -o filenames -F _shiki_completions shiki"
    ]

-- | @_describe@ separates a word from its description with @:@, so colons in
--   the word itself are escaped.
zshScript :: Text
zshScript =
  Text.unlines
    [ "#compdef shiki",
      "",
      "_shiki() {",
      "    local -a completions",
      "    local CMDLINE",
      "    local IFS=$'\\n'",
      "",
      "    CMDLINE=(--bash-completion-enriched --bash-completion-index $((CURRENT - 1)))",
      "",
      "    for arg in ${words[@]}; do",
      "        CMDLINE=(${CMDLINE[@]} --bash-completion-word \"$arg\")",
      "    done",
      "",
      "    local line",
      "    for line in $(shiki \"${CMDLINE[@]}\" 2>/dev/null); do",
      "        local word=${line%%$'\\t'*}",
      "        local desc=${line#*$'\\t'}",
      "        if [[ \"$word\" != \"$desc\" ]]; then",
      "            completions+=(\"${word//:/\\\\:}:${desc}\")",
      "        else",
      "            completions+=(\"$word\")",
      "        fi",
      "    done",
      "",
      "    if [[ ${#completions[@]} -gt 0 ]]; then",
      "        _describe 'shiki' completions",
      "    fi",
      "}",
      "",
      "_shiki"
    ]

-- | @complete -c shiki -f@ disables Fish's default file completion.
fishScript :: Text
fishScript =
  Text.unlines
    [ "# Disable file completion by default",
      "complete -c shiki -f",
      "",
      "function __shiki_complete",
      "    set -l tokens (commandline -cop)",
      "    set -l current (commandline -ct)",
      "    set -l index (count $tokens)",
      "",
      "    set -l args --bash-completion-enriched --bash-completion-index $index",
      "    for token in $tokens",
      "        set args $args --bash-completion-word $token",
      "    end",
      "    set args $args --bash-completion-word \"$current\"",
      "",
      "    for line in (shiki $args 2>/dev/null)",
      "        set -l parts (string split \\t -- $line)",
      "        if test (count $parts) -ge 2",
      "            printf '%s\\t%s\\n' $parts[1] $parts[2]",
      "        else",
      "            echo $line",
      "        end",
      "    end",
      "end",
      "",
      "complete -c shiki -a '(__shiki_complete)'"
    ]
