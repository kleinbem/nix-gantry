# Container Host Module
#
# Provides common setup for devices that host containers: networking
# and wiring containers into nixosModules.updater. No external option
# or module dependencies -- see ./host-persistence.nix for the
# (separate, opt-in) impermanence wiring.
#
# Usage in host config:
#
#   imports = [
#     inputs.nix-gantry.nixosModules.host
#     inputs.nix-gantry.nixosModules.updater  # Must also import this
#   ];
#
#   my.container-host = {
#     enable = true;
#     subnet = "10.85.48.0/24";
#     hostAddress = "10.85.48.1";
#     manifestUrl = "https://github.com/you/your-flake/releases/download/container-manifest/manifest.json";
#     excludeFromUpdater = [ "attic" "caddy" "crowdsec" ];
#   };
#
#   my.containers = {
#     caddy = {
#       enable = true;
#       ip = "10.85.48.5/24";
#       hostDataDir = "/var/lib/caddy";
#     };
#     # ... more containers, each declared by your own container preset
#     # (see ../lib/factory.nix), following the same my.containers.<name>
#     # convention this module and mkContainer both assume.
#   };

{
  config,
  lib,
  ...
}:

let
  cfg = config.my.container-host;
in
{
  options.my.container-host = {
    enable = lib.mkEnableOption "Container Host (LXD networking, persistence, auto-update)";

    subnet = lib.mkOption {
      type = lib.types.str;
      description = "Container subnet (e.g., 10.85.48.0/24)";
      example = "10.85.48.0/24";
    };

    hostAddress = lib.mkOption {
      type = lib.types.str;
      description = "Host bridge IP on container subnet";
      example = "10.85.48.1";
    };

    manifestUrl = lib.mkOption {
      type = lib.types.str;
      description = ''
        Forwarded to my.services.container-updater.manifestUrl. Set here
        (once, alongside subnet/hostAddress) instead of separately
        importing nixosModules.updater just to set one string.
      '';
      example = "https://github.com/you/your-flake/releases/download/container-manifest/manifest.json";
    };

    bridge = lib.mkOption {
      type = lib.types.str;
      default = "cbr0";
      description = "Container bridge name";
    };

    excludeFromUpdater = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Containers still built by container-factory and pulled/cached from the
        CI manifest, but excluded from the automatic nightly bulk update —
        e.g. a reverse proxy you don't want unattended-restarted. Still
        stageable/updatable any time via
        `systemctl start update-container@<name>`.
      '';
      example = [
        "attic"
        "caddy"
        "crowdsec"
      ];
    };

    excludeFromStandalone = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Containers that must build embedded on this host and never be
        treated as standalone/pulled at all — for a container-factory
        structural conflict (e.g. an attrsOf option that recurses in the
        factory's eval), not merely "don't auto-restart" (use
        excludeFromUpdater for that).
      '';
    };

    # Defaults to false. Also import nixosModules.host-persistence
    # (alongside the external impermanence module) to use this -- see
    # that module's header comment for why it's split out rather than
    # just gated here.
    enablePersistence = lib.mkEnableOption "Impermanence for container host";
  };

  config = lib.mkIf cfg.enable {
    # ─── Container Networking ───────────────────────────────────
    my.network = {
      inherit (cfg) subnet hostAddress;
    };

    # Firewall rules below assume this bridge exists; create it (empty
    # -- containers attach dynamically at start) if nothing else
    # already has. mkDefault so a consumer who declares this bridge
    # elsewhere (e.g. alongside libvirtd/podman networking) keeps
    # their own definition untouched.
    networking.bridges.${cfg.bridge}.interfaces = lib.mkDefault [ ];

    # ─── Firewall Rules for Container Traffic ───────────────────
    # Allow container traffic on the bridge
    networking.firewall = {
      extraForwardRules = ''
        # Allow traffic between containers on bridge
        iifname "${cfg.bridge}" oifname "${cfg.bridge}" accept
        # Allow containers to reach external networks
        iifname "${cfg.bridge}" accept
        oifname "${cfg.bridge}" accept
      '';
    };

    # ─── Container Auto-Update Orchestration (ADR 002) ──────────
    # Containers are decoupled from host generation and refreshed
    # nightly from CI-published manifest (eval-free on edge devices).
    # NOTE: Requires services/container-updater.nix to be imported.
    my.services.container-updater = {
      enable = true;
      inherit (cfg) manifestUrl;
      # Source from config.containers (the real nspawn instance names mkContainer
      # produces), not config.my.containers (the my.containers.<option-name>
      # keys) — a preset's mkContainer `name` can differ from its option name
      # (e.g. `my.containers.dashboard` → container "dashboard-homepage"), and
      # this list is matched against the real name by isStandalone in
      # nix-presets/lib/factory.nix. Deriving from the option-name set instead
      # silently left any such container permanently embedded, never pulled.
      #
      # excludeFromStandalone subtracts here, at the base list, because
      # isStandalone matches against this exact list — a container that
      # genuinely can't be factory-built (persona-runtime's attrsOf
      # structural conflict) must never appear in it, or NixOS expects a
      # manifest entry that will never exist. excludeFromUpdater does NOT
      # subtract here — it only opts a container out of the *nightly* bulk
      # restart (below); removing it from this base list would silently
      # build it embedded again instead of pulled/cached.
      containers = lib.subtractLists cfg.excludeFromStandalone (lib.attrNames config.containers);
      excludeFromNightly = cfg.excludeFromUpdater;
    };

    # ─── Systemd Service Dependencies ────────────────────────────
    # Ensure container networking is up before containers start
    systemd.services = lib.mkIf (config.my.services.container-updater.enable or false) {
      # Wait for cache availability before running container updates
      "service-container-updater" = {
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
      };
    };
  };
}
