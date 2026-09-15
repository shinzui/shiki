{ pkgs
, gitRev
}:
let
  inherit (pkgs.haskell.lib.compose) doJailbreak dontCheck dontHaddock overrideCabal;

  noDerivingTypeable = drv: {
    configureFlags = (drv.configureFlags or [ ]) ++ [
      "--ghc-option=-Wno-deriving-typeable"
    ];
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
  # effectful 2.7 is not in nixpkgs' GHC 9.12 set (it ships 2.6.1.0) and the
  # `haskell-nix` input still pins baikai-effectful 0.4.0.1, which caps
  # effectful-core at 2.6. Pull the Hackage releases cabal.project resolves to
  # so `nix build` and `cabal build` compile the same libraries.
  # effectful-core 2.7 needs strict-mutable-base 2.x (the set has 1.1.0.0), so
  # that comes along too. `file-io` is not pinned: GHC 9.12.4 ships it as a boot
  # library behind `directory`, and overriding it makes Cabal abort with
  # "indirectly depends on multiple versions of the same package".
  strict-mutable-base =
    dontCheck (final.callHackageDirect
      {
        pkg = "strict-mutable-base";
        ver = "2.0.0.0";
        sha256 = "sha256-3o2PMN8l56X7ULqyNNJrJQZ8xgqqOsxhjm0jfULQt+k=";
      }
      { });

  effectful-core =
    dontCheck (final.callHackageDirect
      {
        pkg = "effectful-core";
        ver = "2.7.1.2";
        sha256 = "sha256-OZhGk0UY3BMWF+oUAQnCvF3hnzscBCm0Cz+nz8p2XM8=";
      }
      { });

  effectful =
    dontCheck (final.callHackageDirect
      {
        pkg = "effectful";
        ver = "2.7.1.0";
        sha256 = "sha256-1jr7uWldG/qzNljv41c8ustRFNLnD9DuOFBmL3BYT6g=";
      }
      { });

  baikai-effectful =
    dontCheck (final.callHackageDirect
      {
        pkg = "baikai-effectful";
        ver = "0.4.0.2";
        sha256 = "sha256-SgcvuYmfJt8bF4WU5MCKQzTCBkAPdsy5G5X3nwPVPd0=";
      }
      { });

  # nixpkgs' Haskell set lags Hackage here: it ships kubernetes-api 135 (shiki
  # targets the 1.34 client), and jose-jwt 0.10 / hoauth2 2.14, which still use
  # `memory` instead of the `ram` package crypton 1.1 needs. Pull the Hackage
  # releases that match cabal.project's plan.
  kubernetes-api =
    dontCheck (doJailbreak
      (overrideCabal noDerivingTypeable
        (final.callHackageDirect
          {
            pkg = "kubernetes-api";
            ver = "134.0.1";
            sha256 = "sha256-vFkrnALeuxpUqhW+Gpe65M73ycVx4gBhSOjHIj1oOjQ=";
          }
          { })));

  kubernetes-api-client =
    dontCheck (doJailbreak (overrideCabal noDerivingTypeable prev.kubernetes-api-client));

  jose-jwt =
    dontCheck (doJailbreak
      (final.callHackageDirect
        {
          pkg = "jose-jwt";
          ver = "0.11.0";
          sha256 = "sha256-b2yixchUxx6AqCB07yq5to8nFG9h2tTJQZLLB/GWXmA=";
        }
        { }));

  hoauth2 =
    dontCheck (doJailbreak
      (final.callHackageDirect
        {
          pkg = "hoauth2";
          ver = "2.15.2";
          sha256 = "sha256-OKs2b3MGPq5mKWy1T0qYtaGtEp9v638Ynm4TNmBqNYw=";
        }
        { }));

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
