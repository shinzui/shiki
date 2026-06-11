{- The shape of a project-local shiki.dhall file.

   environments is a Dhall "Map" (association list) from environment name to
   its Environment record. defaultEnvironment names the environment used when
   neither --env nor SHIKI_ENV is supplied. -}
let Environment = ./Environment.dhall

in  { environments : List { mapKey : Text, mapValue : Environment }
    , defaultEnvironment : Text
    }
