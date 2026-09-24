{
  lib,
  stdenv,
  cargo,
  rustPlatform,
  rustc,
  napi-rs-cli,
  bun,
  libiconv,
}: let
  patchy-cnb-repo = ../patchy-cnb;
in
  rustPlatform.buildRustPackage rec {
    pname = "patchy-cnb";
    version = "0.1.0";

    src = patchy-cnb-repo;

    cargoLock = {
      lockFile = "${patchy-cnb-repo}/Cargo.lock";
    };

    nativeBuildInputs = [
      napi-rs-cli
      bun
    ];

    buildPhase = ''
      runHook preBuild

      bun run build

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p $out/lib
      cp patchy-cnb.*.node $out/lib/

      runHook postInstall
    '';

    meta = with lib; {
      description = "Stub replacement for claude-native-bindings.node, for use in claude-desktop";
      license = with licenses; [
        mit # or
        asl20
      ];
    };
  }
