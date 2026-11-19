# UNMANAGED, project-specific build wiring. This file is imported only when
# present (see the `builtins.pathExists` guard in flake.nix).
#
# The managed nix/haskell-cli-app.nix (haskell-cli-app) owns the package
# outputs: packages.shiki-core, packages.shiki-cli, packages.default and
# checks.shiki-cli-test, all selected from haskellProject.applicationScope.
# This module feeds that scope the project's own Haskell wiring. mkAfter keeps
# these overlays after the managed one, so the overlay's shiki-core/shiki-cli
# (git hash, staged root files, Hackage pins) replace the plain callCabal2nix
# recipes the managed module declares.
{ inputs, lib, ... }:
{
  perSystem = { pkgs, config, ... }:
    let
      gitRev = inputs.self.shortRev or "dirty";
    in
    {
      haskellProject.applicationOverlays = lib.mkAfter [
        (inputs.haskell-nix.lib.haskellExtension pkgs.haskell.lib.compose pkgs)
        (import ./nix/haskell-overlay.nix {
          inherit pkgs gitRev;
        })
      ];

      packages.shiki = config.packages.shiki-cli;
    };
}
