{ pkgs
, gitRev
, kubernetes-api-src
, jose-jwt-src
, hoauth2-src
}:
let
  inherit (pkgs.haskell.lib.compose) doJailbreak dontCheck dontHaddock overrideCabal;

  noDerivingTypeable = drv: {
    configureFlags = (drv.configureFlags or [ ]) ++ [
      "--ghc-option=-Wno-deriving-typeable"
    ];
  };

  stageKubernetesLicense = drv: {
    prePatch = (drv.prePatch or "") + ''
      rm -f LICENSE
      cp ${kubernetes-api-src}/kubernetes-api/LICENSE LICENSE
    '';
  };

  stageRootFiles = drv: {
    prePatch = (drv.prePatch or "") + ''
      cp ${../CHANGELOG.md} ../CHANGELOG.md
      cp ${../LICENSE} ../LICENSE
      cp -r ${../schema} ../schema
    '';
  };

  shikiVersionFlags = drv: {
    configureFlags = (drv.configureFlags or [ ]) ++ [
      "--ghc-option=-DGIT_HASH=\"${builtins.substring 0 7 gitRev}\""
    ];
  };
in
final: prev:
{
  kubernetes-api =
    dontCheck (doJailbreak
      (overrideCabal (drv: noDerivingTypeable drv // stageKubernetesLicense drv)
        (final.callCabal2nix "kubernetes-api" "${kubernetes-api-src}/kubernetes-api/kubernetes-api-1.34" { })));

  kubernetes-api-client =
    dontCheck (doJailbreak
      (overrideCabal (drv: noDerivingTypeable drv // stageKubernetesLicense drv)
        (final.callCabal2nix "kubernetes-api-client" "${kubernetes-api-src}/kubernetes-api/kubernetes-api-client" { })));

  jose-jwt =
    dontCheck (doJailbreak (final.callCabal2nix "jose-jwt" jose-jwt-src { }));

  hoauth2 =
    dontCheck (doJailbreak (final.callCabal2nix "hoauth2" "${hoauth2-src}/hoauth2" { }));

  # `dontHaddock` below: shiki ships a CLI, not a library anyone reads Haddock
  # for, and these are exactly the derivations that rebuild on every `nix build`
  # here and on every `darwin-rebuild` in mori://shinzui/dotfiles.nix. nixpkgs'
  # builder defaults `doHaddock` to true, which adds a `doc` output plus a
  # Haddock pass over the package and its dependencies' interfaces — pure
  # repeated cost. Scoped to these packages rather than the whole scope (which
  # is what `disableHaddock = true` on mori://shinzui/haskell-nix's
  # `mkChannelExtension` would do) so the dependency closure keeps its hashes
  # instead of needing a one-time full rebuild.

  shiki-core =
    dontHaddock (dontCheck
      (overrideCabal stageRootFiles
        (doJailbreak (final.callCabal2nix "shiki-core" ../shiki-core { }))));

  shiki-cli =
    dontHaddock (dontCheck
      (overrideCabal (drv: stageRootFiles drv // shikiVersionFlags drv)
        (doJailbreak (final.callCabal2nix "shiki-cli" ../shiki-cli { }))));
}
