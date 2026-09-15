# ADR 4: Use pg-migrate with per-Shiki-schema ledgers

Status: Accepted

Date: 2026-09-15


## Context

Shiki automatically brings its PostgreSQL schema up to date before a database-backed
command runs. Earlier releases discovered SQL files at runtime and used `hasql-migration`,
which recorded filename, base64 MD5, and execution time in `schema_migrations`. Shiki also
supports multiple configured schemas in one database, and each schema must evolve
independently.

The old runner required a private compatibility checkout plus `crypton` and `ram` source
pins. More importantly, replacing it could not simply start an empty ledger: an existing
database might contain any applied prefix of Shiki's three released SQL files, and executing
those files again would fail or corrupt migration history. Restricted runtime roles also
have to keep working after an owner performs an upgrade.

[EP-18](../plans/18-migrate-shiki-from-hasql-migration-to-pg-migrate.md) implemented the
cutover using `mori://shinzui/pg-migrate`, including its embedding package and its
`hasql-migration` history adapter.


## Decision

Shiki uses the released `pg-migrate`, `pg-migrate-embed`, and
`pg-migrate-import-hasql-migration` 1.1 package family. The immutable SQL files are listed in
an ordered manifest and embedded as exact bytes at compile time in one component named
`shiki`. Production migration execution never discovers SQL from the runtime filesystem.

Each configured Shiki schema contains its own `ledger_metadata`, `migrations`,
`history_imports`, and `repairs` tables. All Shiki migration operations share advisory-lock
key `0x7368696B695F6D67`. A dedicated Hasql connection receives a right-precedence libpq
`options=-csearch_path=<schema>,public` setting so the existing unqualified SQL targets the
selected schema while the runner owns locking and cleanup for the connection's whole
lifetime.

When the target ledger has no Shiki migration rows, the runner examines that schema's legacy
`schema_migrations` table. A non-empty legacy history is importable only when its filenames,
ordered by execution time and filename, form an exact prefix of the embedded manifest and
each base64 MD5 checksum matches the embedded source bytes. Matching rows are imported as
same-payload history without executing their SQL, and only the remaining manifest suffix is
run. Unknown, reordered, gapped, duplicated, missing, or checksum-mismatched source history
fails before target migration rows are trusted. The legacy table is retained unchanged as
recovery evidence. An initialized target ledger with zero Shiki rows follows the same path,
so interruption between ledger initialization and history import is retryable.

Automatic migration remains part of database-backed CLI startup. An owning role must run a
new release first. A restricted runtime role may reuse an already-current schema without
database or schema `CREATE`; it needs `USAGE` on the Shiki schema, `SELECT` on the four
ledger tables, and its existing data-manipulation grants on `runs`.


## Consequences

- Adding, removing, duplicating, or failing to list a sibling SQL file is a compile-time
  manifest error. Applied SQL bytes remain immutable; schema evolution appends a manifest
  entry.
- Two Shiki schemas in one database have independent migration histories. The shared
  advisory key may serialize rare migrations across those schemas, which is acceptable and
  avoids an unstable schema-to-lock hashing rule.
- The first upgraded owner invocation adds the pg-migrate tables and preserves
  `schema_migrations`. Operators must not edit either history by hand; checksum or prefix
  failures require investigation and restoration of the original evidence.
- Runtime roles need new ledger read grants after the owner upgrade. They still cannot apply
  pending DDL, so every release that adds a migration requires owner-first rollout.
- `migrationsDirectory` remains only for transition tests and packaged SQL inspection. The
  binary's production behavior comes from the reviewed embedded manifest.
