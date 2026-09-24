# Optional persistence wiring for container-hosted state, split out of
# modules/host.nix into its own module on purpose: `environment.persistence`
# is an option this flake doesn't declare (it comes from the external
# `impermanence` module, github:nix-community/impermanence) -- and the
# NixOS module system requires a matching `options.<path>` declaration
# for ANY definition of that path, EVEN ONE wrapped in `lib.mkIf false`.
# Wrapping just the VALUE in mkIf inside modules/host.nix (an earlier
# attempt) still tripped "option does not exist" for anyone who hadn't
# imported impermanence, regardless of enablePersistence's value --
# mkIf only makes a value conditional once the option is known to
# exist; it doesn't stop the module system from noticing a path was
# defined at all. The only real way to make this genuinely optional is
# to keep it out of the base module entirely: import THIS module too,
# alongside nixosModules.host, only if you use impermanence.
#
# Usage: import both, alongside your own impermanence import:
#
#   imports = [
#     inputs.nix-gantry.nixosModules.host
#     inputs.nix-gantry.nixosModules.host-persistence
#     inputs.impermanence.nixosModules.impermanence
#   ];
#
#   my.container-host.enablePersistence = true;
{
  config,
  lib,
  ...
}:
let
  cfg = config.my.container-host;
in
{
  config = lib.mkIf (cfg.enable && cfg.enablePersistence) {
    # ─── Persistence for Container State ────────────────────────
    # Container data directories are preserved across reboots
    # (especially important on impermanent hosts like core-pi)
    environment.persistence."/nix/persist".directories =
      let
        # Extract all hostDataDir values from enabled containers
        containerDirs = lib.concatMap (
          name:
          (
            let
              container = config.my.containers.${name};
            in
            if container.enable or false then
              lib.optional ((container.hostDataDir or null) != null) container.hostDataDir
            else
              [ ]
          )
        ) (lib.attrNames config.my.containers);
      in
      lib.unique containerDirs;
  };
}
