{
  description = "Shiki is a CLI for safely running operational commands across Kubernetes services while recording execution history, status, and duration in PostgreSQL.";

  inputs = {
    # The shared base flake. Provides the GHC 9.12.4 / cabal / HLS toolchain via
    # `mkDevShell`, and the single pinned nixpkgs the whole fleet follows.
    haskell-nix-dev.url = "github:shinzui/haskell-nix-dev";
    nixpkgs.follows = "haskell-nix-dev/nixpkgs";

    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";

    treefmt-nix.follows = "haskell-nix-dev/treefmt-nix";

    pre-commit-hooks.url = "github:cachix/git-hooks.nix";
    pre-commit-hooks.inputs.nixpkgs.follows = "nixpkgs";

    # ---- PROJECT-SPECIFIC INPUTS ----

    # Shared Haskell patch management (registry overlay), grafted onto the
    # haskell-nix-dev nixpkgs in flake.module.nix for the package build.
    haskell-nix = {
      url = "github:shinzui/haskell-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    kubernetes-api-src = {
      url = "github:shinzui/kubernetes-api-project/2db0fd55d03424b3b2b7f733511b7b06b18752cd";
      flake = false;
    };

    jose-jwt-src = {
      url = "github:tekul/jose-jwt/95697890390f696cdcf43fbfe8d67f7262fd72bf";
      flake = false;
    };

    hoauth2-src = {
      url = "github:shinzui/hoauth2/3fa57f9ffe6baa6ed98d58919481ebb33f3f4d0d";
      flake = false;
    };
  };

  nixConfig = {
    extra-substituters = [ ];
    extra-trusted-public-keys = [ ];
  };

  # Thin flake-parts dev shell. The dev toolchain comes from the haskell-nix-dev
  # base flake (GHC 9.12.4 / cabal / HLS via mkDevShell); project wiring lives in
  # the imported ./nix modules.
  outputs = inputs@{ flake-parts, nixpkgs, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = nixpkgs.lib.systems.flakeExposed;

      imports =
        [
          ./nix/haskell.nix
          ./nix/treefmt.nix
          ./nix/pre-commit.nix
        ]
        ++ nixpkgs.lib.optional (builtins.pathExists ./flake.module.nix) ./flake.module.nix;
    };
}
