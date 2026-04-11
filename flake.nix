{
  description = "tiny-deploy";

  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    crane.url = "github:ipetkov/crane";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    deploy-rs = {
      url = "github:serokell/deploy-rs";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs @ {flake-parts, ...}:
    flake-parts.lib.mkFlake {inherit inputs;} ({self, ...}: {
      systems = ["x86_64-linux" "aarch64-linux" "aarch64-darwin" "x86_64-darwin"];

      flake.nixosModules = {
        default = ./module.nix;
        pi4 = ./hosts/pi4.nix;
        pi5 = ./hosts/pi5.nix;
      };

      flake.lib.mkHost = {
        hostModule,
        hostName,
        hostname,
        authorizedKeys,
        system ? "aarch64-linux",
        extraModules ? [],
      }: let
        nixos = inputs.nixpkgs.lib.nixosSystem {
          inherit system;
          modules =
            [
              self.nixosModules.default
              hostModule
              {
                services.tiny-deploy = {
                  enable = true;
                  inherit hostName authorizedKeys;
                  deployShell = self.packages.${system}.default;
                };
              }
            ]
            ++ extraModules;
        };
      in {
        nixosConfiguration = nixos;
        image = nixos.config.system.build.image;
        deploy = {
          inherit hostname;
          profiles.system = {
            sshUser = "deploy";
            user = "root";
            path = inputs.deploy-rs.lib.${system}.activate.nixos nixos;
            magicRollback = true;
            interactiveSudo = false;
          };
        };
      };

      perSystem = {
        pkgs,
        system,
        ...
      }: let
        rustToolchain = pkgs.rust-bin.fromRustupToolchainFile ./rust-toolchain.toml;
        craneLib = (inputs.crane.mkLib pkgs).overrideToolchain rustToolchain;
        src = craneLib.cleanCargoSource ./.;
        commonArgs = {
          inherit src;
          strictDeps = true;
        };
        cargoArtifacts = craneLib.buildDepsOnly commonArgs;
        tiny-deploy = craneLib.buildPackage (commonArgs
          // {
            inherit cargoArtifacts;
            meta.mainProgram = "deploy-shell";
            passthru.shellPath = "/bin/deploy-shell";
          });
      in {
        _module.args.pkgs = import inputs.nixpkgs {
          inherit system;
          overlays = [inputs.rust-overlay.overlays.default];
        };

        packages.default = tiny-deploy;

        devShells.default = pkgs.mkShell {
          packages = [
            rustToolchain
            pkgs.rust-analyzer
          ];
        };
      };
    });
}
