{
  description = "nix-gantry quickstart: one container, pulled and swapped by a manifest, no fleet infrastructure required";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix-gantry.url = "path:..";
    nix-gantry.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    { nixpkgs, nix-gantry, ... }:
    let
      system = "x86_64-linux";
      inherit (nixpkgs) lib;

      demoInnerConfig =
        { pkgs, ... }:
        {
          services.httpd = {
            enable = true;
            virtualHosts.localhost.documentRoot = pkgs.writeTextDir "index.html" "Hello from nix-gantry!";
          };
          networking.firewall.allowedTCPPorts = [ 80 ];
          system.stateVersion = "25.11";
        };

      # A minimal container preset, following the my.containers.<name>
      # convention nix-gantry's modules expect. A real preset declares
      # its own options.my.containers.<name>; this quickstart inlines
      # it for brevity.
      #
      # Imports the WHOLE mkContainer return value, not just its
      # `.containers` key -- it also carries
      # systemd.services."container@hello".unitConfig (ConditionPathExists,
      # StartLimitBurst, Restart=on-failure) as a sibling top-level key.
      # Extracting only `.containers` silently drops that and lets
      # container@ race its own boot-time start against staging.
      demoContainer = {
        imports = [
          {
            options.my.network.bridge = lib.mkOption {
              type = lib.types.str;
              default = "cbr0";
            };
          }
          (
            { config, ... }:
            nix-gantry.lib.mkContainer {
              inherit config;
              name = "hello";
              cfg = {
                ip = "10.233.1.2/24";
                autoStart = true;
              };
              innerConfig = demoInnerConfig;
            }
          )
        ];
      };

      # Built in isolated (non-standalone) mode -- no
      # my.services.container-updater registration in scope, so
      # mkContainer's isStandalone resolves false and .path is a real,
      # buildable closure. This is what CI does for you in production
      # via .github/workflows/publish-manifest.yaml; this quickstart
      # just does it inline so it's runnable with zero external
      # infrastructure.
      factoryEval = lib.nixosSystem {
        inherit system;
        modules = [ demoContainer ];
      };
      helloClosure = factoryEval.config.containers.hello.path;

      host =
        { pkgs, ... }:
        let
          manifestFile = pkgs.writeText "manifest.json" (
            builtins.toJSON {
              rev = "quickstart";
              generated = "1970-01-01T00:00:00Z";
              systems.${system}.hello = "${helloClosure}";
            }
          );
        in
        {
          imports = [
            nix-gantry.nixosModules.host
            nix-gantry.nixosModules.updater
            demoContainer
          ];

          my.container-host = {
            enable = true;
            subnet = "10.233.1.0/24";
            hostAddress = "10.233.1.1";
            manifestUrl = "file://${manifestFile}";
            enablePersistence = false; # needs the external impermanence module otherwise
          };

          my.services.container-updater.containers = [ "hello" ];

          # my.container-host configures firewall rules for the bridge
          # but doesn't create it -- see README's "External requirements".
          networking.bridges.cbr0.interfaces = [ ];

          networking.firewall.enable = false;
          system.stateVersion = "25.11";
        };
    in
    {
      nixosConfigurations.quickstart = lib.nixosSystem {
        inherit system;
        modules = [ host ];
      };
    };
}
