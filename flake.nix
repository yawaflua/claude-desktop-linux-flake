{
  description = "Claude Desktop for Linux";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" ] (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };
      in
      {
        packages = rec {
          node-pty = pkgs.callPackage ./pkgs/node-pty.nix { };

          claude-desktop = pkgs.callPackage ./pkgs/claude-desktop.nix {
            electron = pkgs.electron_41;
            inherit node-pty;
          };

          claude-desktop-with-fhs = pkgs.symlinkJoin {
            name = "claude-desktop-with-fhs";
            paths = [
              claude-desktop
              (pkgs.buildFHSEnv {
                name = "claude-desktop-bwrap";
                targetPkgs =
                  pkgs: with pkgs; [
                    docker
                    glibc
                    openssl
                    nodejs
                    uv
                    glib
                    gvfs
                    xdg-utils
                    bubblewrap
                  ];
                runScript = "${claude-desktop}/bin/claude-desktop";
              })
            ];
            postBuild = ''
              rm -f $out/bin/claude-desktop
              ln -sf $out/bin/claude-desktop-bwrap $out/bin/claude-desktop
            '';
          };

          claude-desktop-shell = pkgs.buildFHSEnv {
            name = "claude-desktop-shell";
            targetPkgs =
              pkgs: with pkgs; [
                docker
                glibc
                openssl
                nodejs
                uv
                glib
                gvfs
                xdg-utils
                bubblewrap
              ];
            runScript = "bash";
          };

          default = claude-desktop;
        };

        apps = rec {
          # `nix run .#update` — resolve the newest Claude Desktop release,
          # verify it, and rewrite version + both hashes in
          # pkgs/claude-desktop.nix so `nix build` stays pure and cacheable.
          update = {
            type = "app";
            program =
              let
                updater = pkgs.writeShellApplication {
                  name = "claude-desktop-update";
                  runtimeInputs = with pkgs; [
                    wget
                    gnused
                    gnugrep
                    gawk
                    coreutils
                    nix
                  ];
                  text = ''exec bash "${./scripts/update.sh}" "$@"'';
                };
              in
              "${updater}/bin/claude-desktop-update";
          };

          default = update;
        };
      }
    );
}
