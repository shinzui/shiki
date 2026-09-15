# UNMANAGED, project-specific build wiring. This file is imported only when
# present (see the `builtins.pathExists` guard in flake.nix).
{ inputs, ... }:
{
  perSystem = { pkgs, ... }:
    let
      gitRev = inputs.self.shortRev or "dirty";
      haskellPackages = pkgs.haskell.packages.ghc9124.override {
        overrides = pkgs.lib.composeExtensions
          (inputs.haskell-nix.lib.haskellExtension pkgs.haskell.lib.compose pkgs)
          (import ./nix/haskell-overlay.nix {
            inherit pkgs gitRev;
          });
      };
    in
    {
      packages.shiki = haskellPackages.shiki-cli;
      packages.default = haskellPackages.shiki-cli;
    };
}
