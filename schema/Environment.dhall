{- A named shiki environment: the settings that vary between, e.g., staging
   and prod. Currently just a PostgreSQL connection string; new fields may be
   added here over time (they must also be added to the Haskell Environment
   record in shiki-core/src/Shiki/Project/Config.hs). -}
{ databaseUrl : Text }
