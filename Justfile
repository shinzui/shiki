# Shiki development commands

# List all recipes
default:
    @just --list

# --- Services ---

# Start PostgreSQL via process-compose
[group('services')]
up:
    process-compose up -D

# Stop all services
[group('services')]
down:
    process-compose down

# --- Database ---

# Create the shiki database if it doesn't exist (called by process-compose)
[group('database')]
create-database:
    @psql -lqt | cut -d \| -f 1 | grep -qw $PGDATABASE || createdb $PGDATABASE
    @echo "Database '$PGDATABASE' ready"

# Drop and recreate the database (migrations re-run on the next shiki invocation)
[group('database')]
reset-database:
    dropdb --if-exists $PGDATABASE
    createdb $PGDATABASE

# Open a psql session against the shiki database
[group('database')]
psql:
    psql -d $PGDATABASE

# Truncate postgres logs
[group('database')]
truncate-logs:
    truncate -s 0 $PGLOG

# --- Build ---

# Build all packages
[group('build')]
build:
    cabal build all

# Run all tests
[group('build')]
test:
    cabal test all

# Clean build artifacts
[group('build')]
clean:
    cabal clean

# --- CLI ---

# Run the shiki CLI (e.g. `just shiki runs list`)
[group('cli')]
[positional-arguments]
shiki *args:
    cabal run shiki -- "$@"

# --- Docs ---

# docs/user is the OKF bundle "user-documentation" declared in mori.dhall.
# `okf validate` fails on any deviation from the shared
# documentation.userDocumentation profile: missing or malformed
# frontmatter, a duplicate docId, or a log.md that does not cover a page's
# generated date. `okf graph` additionally resolves every Markdown link
# between pages.
# Strict OKF enforcement for the operator guide under docs/user
[group('docs')]
user-documentation-validate:
    okf validate docs/user --strict --profile mori/user-documentation-profile.dhall --profile-enforce --log-enforce
    okf graph docs/user

# --- Nix ---

# Build via nix
[group('nix')]
nix-build:
    nix build

# Run all nix flake checks
[group('nix')]
nix-check:
    nix flake check

# Format all files via treefmt
[group('nix')]
fmt:
    nix fmt
