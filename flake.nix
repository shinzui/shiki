{
  description = "Shiki is a CLI for safely running operational commands across Kubernetes services while recording execution history, status, and duration in PostgreSQL.";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
  inputs.flake-utils.url = "github:numtide/flake-utils";

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        haskellPackages = pkgs.haskell.packages."ghc9124";
      in
      {
        packages = {
          default = haskellPackages.shiki;
        };

        checks = {
        };

        devShells.default = pkgs.mkShell {
          nativeBuildInputs = [
            pkgs.zlib
            pkgs.just
            pkgs.cabal-install
            pkgs.pkg-config
            pkgs.postgresql
            haskellPackages.ghc
          ]
          ++ pkgs.lib.optional true pkgs.process-compose;

          shellHook = ''
            export LANG=en_US.UTF-8

            export PGHOST="$PWD/db"
            export PGDATA="$PGHOST/db"
            export PGLOG=$PGHOST/postgres.log
            export PGDATABASE=shiki
            export PG_CONNECTION_STRING=postgresql://$(jq -rn --arg x $PGHOST '$x|@uri')/$PGDATABASE

            mkdir -p $PGHOST
            mkdir -p .dev

            if [ ! -d $PGDATA ]; then
              initdb --auth=trust --no-locale --encoding=UTF8
            fi
          '';
        };
      }
    );
}
