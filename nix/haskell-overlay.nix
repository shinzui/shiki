{ pkgs
, gitRev
, kubernetes-api-src
, jose-jwt-src
, hoauth2-src
}:
let
  inherit (pkgs.haskell.lib.compose) doJailbreak dontCheck overrideCabal;

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

  shiki-core =
    dontCheck
      (overrideCabal stageRootFiles
        (doJailbreak (final.callCabal2nix "shiki-core" ../shiki-core { })));

  shiki-cli =
    dontCheck
      (overrideCabal (drv: stageRootFiles drv // shikiVersionFlags drv)
        (doJailbreak (final.callCabal2nix "shiki-cli" ../shiki-cli { })));
}
