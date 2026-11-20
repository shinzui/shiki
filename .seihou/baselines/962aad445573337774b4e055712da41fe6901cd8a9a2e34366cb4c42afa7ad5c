# Workspace package outputs for the two-package shiki CLI scaffold.
# seihou-managed by haskell-cli-app; project-specific customizations still
# belong in the unmanaged ../flake.module.nix imported by the base flake.
{ inputs, ... }:
{
  perSystem = { pkgs, config, ... }:
    let
      haskellPackages = config.haskellProject.applicationScope;
      corePackage = haskellPackages."shiki-core";
      cliPackage = haskellPackages."shiki-cli";
    in
    {
      haskellProject.ownPackages = [ "shiki-core" "shiki-cli" ];
      haskellProject.applicationOverlays = [
        (hself: _hsuper: {
          "shiki-core" =
            hself.callCabal2nix "shiki-core"
              (builtins.path {
                path = inputs.self + "/shiki-core";
                name = "shiki-core-source";
              })
              { };
          "shiki-cli" =
            hself.callCabal2nix "shiki-cli"
              (builtins.path {
                path = inputs.self + "/shiki-cli";
                name = "shiki-cli-source";
              })
              { };
        })
      ];
      packages."shiki-core" = corePackage;
      packages."shiki-cli" = cliPackage;
      packages.default = cliPackage;
      checks."shiki-cli-test" = pkgs.haskell.lib.doCheck cliPackage;
    };
}
