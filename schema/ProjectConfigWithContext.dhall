let Environment = ./EnvironmentWithContext.dhall

in  { environments : List { mapKey : Text, mapValue : Environment }
    , defaultEnvironment : Text
    }
