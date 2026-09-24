{
  description = "CI builds once; hosts fetch a manifest and atomically swap in a NixOS/systemd-nspawn container. No evaluation or building on the host.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs =
    inputs@{ flake-parts, self, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      perSystem =
        {
          pkgs,
          ...
        }:
        {
          formatter = pkgs.nixfmt-rfc-style;

          checks = {
            # Hand-rolled in place of git-hooks.nix (removed as a flake
            # input -- this was its only use, and running the same four
            # tools directly needs no external dependency at all).
            lint =
              pkgs.runCommandLocal "nix-gantry-lint"
                {
                  nativeBuildInputs = [
                    pkgs.nixfmt-rfc-style
                    pkgs.statix
                    pkgs.deadnix
                    pkgs.shellcheck
                  ];
                }
                ''
                  cp -r ${./.} src
                  chmod -R +w src
                  cd src
                  echo "Checking nixfmt..."
                  find . -name '*.nix' -print0 | xargs -0 nixfmt --check
                  echo "Checking statix..."
                  statix check .
                  echo "Checking deadnix..."
                  deadnix --fail .
                  echo "Checking shellcheck..."
                  shellcheck apps/publish-manifest.sh
                  touch $out
                '';
          }
          // (import ./tests {
            inherit pkgs self inputs;
            inherit (pkgs) lib;
          });

          apps.publish-manifest = {
            type = "app";
            program = "${
              pkgs.writeShellApplication {
                name = "publish-manifest";
                runtimeInputs = with pkgs; [
                  jq
                  nix
                ];
                text = builtins.readFile ./apps/publish-manifest.sh;
              }
            }/bin/publish-manifest";
          };

          devShells.default = pkgs.mkShell {
            shellHook = ''
              echo "nix-gantry devshell"
            '';
            buildInputs = with pkgs; [
              nixfmt-rfc-style
              statix
              deadnix
              shellcheck
            ];
          };
        };

      flake = {
        lib = {
          mkContainer = import ./lib/factory.nix { inherit (inputs.nixpkgs) lib; };
        };

        nixosModules = {
          updater = import ./modules/updater.nix;
          host = import ./modules/host.nix;
          # Not part of `default` -- opt-in only, alongside your own
          # impermanence import. See its header comment.
          host-persistence = import ./modules/host-persistence.nix;
          default.imports = [
            ./modules/updater.nix
            ./modules/host.nix
          ];
        };
      };
    };
}
