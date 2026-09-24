# Test matrix for the pull-side mechanism (lib.mkContainer +
# nixosModules.updater/.host). Three checks:
#
#   happy-path      full VM integration test: manifest fetch -> realise
#                   -> symlink swap -> container start, on a REAL
#                   container closure built the same way container-factory
#                   builds one (isStandalone=false at build time).
#   bad-manifest    VM integration test: a missing/unfetchable manifest
#                   fails the stage step safely, without crash-looping
#                   past container@'s StartLimitBurst guard.
#   podman-nesting  pure eval-level structural check (no VM -- a podman
#                   image pull needs network access NixOS VM tests don't
#                   have): confirms usesPodman wires the storage bind
#                   mount, CAP_BPF, and /dev/fuse device that authentik's
#                   real "no space left on device" incident depended on.
{
  pkgs,
  self,
  inputs,
  lib,
}:
let
  inherit (pkgs) system;

  # Minimal option shims a bare NixOS eval needs before it can build a
  # mkContainer-produced containers.<name> closure or import
  # nixosModules.host -- see lib/factory.nix's header comment. A real
  # consumer's own NixOS config already has my.network.bridge; this
  # flake doesn't declare it itself.
  shimModule =
    { lib, ... }:
    {
      options.my.network = {
        bridge = lib.mkOption {
          type = lib.types.str;
          default = "cbr0";
        };
        subnet = lib.mkOption {
          type = lib.types.str;
          default = "";
        };
        hostAddress = lib.mkOption {
          type = lib.types.str;
          default = "";
        };
      };
      # A minimal stand-in for the external `impermanence` module's
      # environment.persistence option (see modules/host.nix's header
      # comment) -- enough to satisfy the module system's "does this
      # option exist" check for tests, which run with
      # enablePersistence = false anyway. A real consumer without
      # impermanence would declare a stub like this too.
      options.environment.persistence = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule {
            options.directories = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
            };
          }
        );
        default = { };
      };
    };

  demoCfg = {
    ip = "10.233.1.2/24";
    # false: autoStart only matters for a container that's ALREADY
    # staged (it's what brings it back up after a reboot). On a
    # completely fresh, never-staged container, autoStart races
    # container@'s own boot-time start attempts against
    # container-updater-bootstrap's staging -- confirmed live in this
    # test matrix: the unit's rapid early restarts exhaust
    # StartLimitBurst before staging finishes, so by the time bootstrap
    # tries to start it, `container@demo` is already stuck in
    # start-limit-hit and needs `systemctl reset-failed` to recover.
    # That's a real timing edge case worth its own coverage some day,
    # but not what these tests are checking -- drive activation
    # explicitly instead.
    autoStart = false;
  };

  demoInnerConfig = {
    system.stateVersion = "25.11";
  };

  # Built once, in isolated (non-standalone) mode: no my.services.container-updater
  # registration in scope, so mkContainer's isStandalone resolves false and
  # .path is a real, buildable NixOS system closure -- exactly how
  # container-factory builds a container's closure for real (standaloneRunner
  # forced off at the factory call site; here it's just never turned on).
  demoFactoryEval = inputs.nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      shimModule
      (
        { config, ... }:
        {
          inherit
            (self.lib.mkContainer {
              inherit config;
              name = "demo";
              cfg = demoCfg;
              innerConfig = demoInnerConfig;
            })
            containers
            ;
          system.stateVersion = "25.11";
        }
      )
    ];
  };
  demoClosure = demoFactoryEval.config.containers.demo.path;

  manifestFile = pkgs.writeText "manifest.json" (
    builtins.toJSON {
      rev = "test";
      generated = "1970-01-01T00:00:00Z";
      systems = {
        ${system} = {
          demo = "${demoClosure}";
        };
      };
    }
  );

  # The "host" node: a real deployment target, with demo registered as
  # standalone (isStandalone=true -> .path is the runtime symlink the
  # updater swaps) -- the same container definition as demoFactoryEval,
  # just evaluated in a different context.
  mkHostNode =
    { manifestUrl }:
    {
      imports = [
        self.nixosModules.host
        self.nixosModules.updater
        shimModule
      ];

      my.container-host = {
        enable = true;
        subnet = "10.233.1.0/24";
        hostAddress = "10.233.1.1";
        inherit manifestUrl;
        # Needs the external `impermanence` NixOS module (environment.persistence)
        # which this flake doesn't depend on -- see modules/host.nix's header
        # comment. Off here since these tests don't exercise persistence.
        enablePersistence = false;
      };

      # my.container-host only configures firewall rules for cfg.bridge
      # -- it does NOT create the bridge interface itself (confirmed
      # live: "Failed to add interface vb-demo to bridge cbr0: No such
      # device" without this). A real consumer must declare this too.
      networking.bridges.cbr0.interfaces = [ ];

      inherit
        (self.lib.mkContainer {
          config = {
            my.network.bridge = "cbr0";
            my.services.container-updater.containers = [ "demo" ];
          };
          name = "demo";
          cfg = demoCfg;
          innerConfig = demoInnerConfig;
        })
        containers
        ;

      networking.firewall.enable = false;
      system.stateVersion = "25.11";
    };
in
{
  happy-path = pkgs.testers.runNixOSTest {
    name = "nix-gantry-happy-path";
    nodes.host = mkHostNode { manifestUrl = "file://${manifestFile}"; };
    testScript = ''
      start_all()
      host.wait_for_unit("multi-user.target")

      # Full stage+activate: manifest fetch -> realise -> symlink swap
      # -> container start, on a never-before-staged container.
      host.succeed("systemctl start --wait update-container@demo.service")
      host.succeed("test -L /var/lib/machines/demo/current")
      host.wait_for_unit("container@demo.service")
      host.succeed("machinectl status demo")

      # Re-running against an unchanged manifest is a no-op stage (same
      # store path) that still completes without error. (Not asserting
      # machinectl state afterward here -- machinectl restart on an
      # already-running container is a separate behavior from the
      # stage/activate mechanism this test is about.)
      host.succeed("systemctl start --wait update-container@demo.service")
    '';
  };

  bad-manifest = pkgs.testers.runNixOSTest {
    name = "nix-gantry-bad-manifest";
    nodes.host = mkHostNode { manifestUrl = "file:///nonexistent/manifest.json"; };
    testScript = ''
      start_all()
      host.wait_for_unit("multi-user.target")

      # Staging fails cleanly (curl can't read a missing file) --
      # nothing crashes, nothing loops.
      host.fail("systemctl start --wait update-container-stage@demo.service")
      host.succeed("systemctl is-failed update-container-stage@demo.service")

      # No symlink was ever created, so container@demo's
      # ConditionPathExists correctly keeps it stopped rather than
      # crash-looping against a target that doesn't exist.
      host.fail("systemctl is-active container@demo.service")
      host.fail("test -e /var/lib/machines/demo/current")
    '';
  };

  podman-nesting =
    let
      built = self.lib.mkContainer {
        config = {
          my.network.bridge = "cbr0";
          my.services.container-updater.containers = [ ];
        };
        name = "demo-podman";
        cfg = {
          ip = "10.233.2.2/24";
          hostDataDir = "/var/lib/demo-podman";
        };
        usesPodman = true;
      };
      c = built.containers.demo-podman;
      hasStorageMount = c.bindMounts ? "/var/lib/containers";
      hasBpf = builtins.elem "CAP_BPF" c.additionalCapabilities;
      hasFuseDevice = builtins.any (d: d.node == "/dev/fuse") c.allowedDevices;
      hasContainersSubdir = builtins.any (
        rule: lib.hasInfix "demo-podman/containers" rule
      ) built.systemd.tmpfiles.rules;
    in
    pkgs.runCommand "nix-gantry-podman-nesting-check" { } ''
      ${if hasStorageMount then "" else throw "usesPodman: missing /var/lib/containers bind mount"}
      ${
        if hasBpf then
          ""
        else
          throw "usesPodman: missing CAP_BPF (needed for crun's cgroup-v2 eBPF device management)"
      }
      ${if hasFuseDevice then "" else throw "usesPodman: missing /dev/fuse allowedDevice"}
      ${
        if hasContainersSubdir then
          ""
        else
          throw "usesPodman: missing tmpfiles rule pre-creating hostDataDir/containers"
      }
      touch $out
    '';
}
