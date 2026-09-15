SHIKI POSTGRES SCHEMA


shiki installs its tables into a dedicated PostgreSQL schema (default
name: 'shiki') so they do not pollute 'public'.

The database itself is selected separately: --db, then the active
shiki.dhall environment databaseUrl, then SHIKI_DATABASE_URL, then
PG_CONNECTION_STRING.


TABLES

  shiki.runs               One row per 'shiki run' invocation. See
                           'shiki help runs' for columns. Migration 003
                           adds nullable last_watched_at, refreshed about
                           once a minute by a waiting shiki process.

  shiki.ledger_metadata    pg-migrate ledger format version.
  shiki.migrations         Applied migration identities and checksums.
  shiki.history_imports    Audits imported legacy migration history.
  shiki.repairs            Audits explicit migration repairs.

Older releases used shiki.schema_migrations. On first upgrade, shiki
verifies and imports any valid ordered prefix without rerunning its SQL,
then retains the old table as read-only recovery evidence.


RESTRICTED ROLES

Once a privileged role has bootstrapped or upgraded the schema, a
narrower role can record runs without any CREATE privilege:

  GRANT USAGE ON SCHEMA shiki TO some_role;
  GRANT SELECT ON shiki.ledger_metadata TO some_role;
  GRANT SELECT ON shiki.migrations TO some_role;
  GRANT SELECT ON shiki.history_imports TO some_role;
  GRANT SELECT ON shiki.repairs TO some_role;
  GRANT SELECT, INSERT, UPDATE ON shiki.runs TO some_role;

It cannot apply new migrations. After a shiki upgrade that adds one, or
before the first pg-migrate cutover, run shiki as the owning role first.


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
