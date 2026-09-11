SHIKI POSTGRES SCHEMA


shiki installs its tables into a dedicated PostgreSQL schema (default
name: 'shiki') so they do not pollute 'public'.

The database itself is selected separately: --db, then the active
shiki.dhall environment databaseUrl, then SHIKI_DATABASE_URL, then
PG_CONNECTION_STRING.


TABLES

  shiki.runs               One row per 'shiki run' invocation. See
                           'shiki help runs' for columns.

  shiki.schema_migrations  Tracks applied migrations. Managed by
                           hasql-migration; do not edit by hand.


RESTRICTED ROLES

Migrations only create the schema and schema_migrations when missing.
Once a privileged role has run shiki once, a narrower role can record
runs without any CREATE privilege:

  GRANT USAGE ON SCHEMA shiki TO some_role;
  GRANT SELECT ON shiki.schema_migrations TO some_role;
  GRANT SELECT, INSERT, UPDATE ON shiki.runs TO some_role;

It cannot apply new migrations; after a shiki upgrade that adds one, run
shiki once as the owning role first.


OVERRIDING THE SCHEMA NAME

Two ways, in priority order:

  shiki --db-schema=other_name <subcommand>     # CLI flag (highest)
  SHIKI_DB_SCHEMA=other_name shiki <subcommand> # env var


VALIDATION

Schema names must match the regex [A-Za-z_][A-Za-z0-9_]* and fit within
PostgreSQL's 63-byte identifier limit. Invalid names exit with:

  shiki: invalid schema name: <name>

before any database work happens.


MIGRATING FROM 'public'

If an older shiki checkout wrote into 'public', either drop the dev
database and let shiki re-create the schema, or move the tables in psql:

  CREATE SCHEMA IF NOT EXISTS shiki;
  ALTER TABLE public.runs              SET SCHEMA shiki;
  ALTER TABLE public.schema_migrations SET SCHEMA shiki;


Full reference: docs/user/schema.md
See also: 'shiki help env', 'shiki help runs'.
