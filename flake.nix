{
  description = "CI builds once; hosts fetch a manifest and atomically swap in a NixOS/systemd-nspawn container. No evaluation or building on the host.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    git-hooks.url = "github:cachix/git-hooks.nix";
    git-hooks.inputs.nixpkgs.follows = "nixpkgs";
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
          config,
          pkgs,
          system,
          ...
        }:
        {
          formatter = pkgs.nixfmt-rfc-style;

          checks = {
            pre-commit-check = inputs.git-hooks.lib.${system}.run {
              src = ./.;
              hooks = {
                nixfmt.enable = true;
                statix.enable = true;
                deadnix.enable = true;
                shellcheck.enable = true;
              };
            };
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
              ${config.checks.pre-commit-check.shellHook}
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
          default.imports = [
            ./modules/updater.nix
            ./modules/host.nix
          ];
        };
      };
    };
}
