# tiny-deploy

Locked-down NixOS deployment target. No interactive shell, no nix daemon, no openssh. Just the minimum needed to receive `nix copy` and run `deploy-rs`.

## What it does

- Replaces the deploy user's shell with a Rust binary that only permits `nix-store --serve` and `activate-rs` commands
- Uses tinyssh (~100KB) instead of openssh (~20MB)
- Disables the nix daemon — store paths are pushed from the deploying machine
- Strips out documentation, default packages, getty, polkit, udisks2, etc.

## Usage

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    tiny-deploy.url = "github:yourusername/tiny-deploy";
    deploy-rs.url = "github:serokell/deploy-rs";
  };

  outputs = { self, nixpkgs, tiny-deploy, deploy-rs, ... }: let
    pi5 = tiny-deploy.lib.mkHost {
      hostModule = tiny-deploy.nixosModules.pi5;
      hostName = "livingroom";
      hostname = "livingroom.local";
      authorizedKeys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA..."
      ];
    };
  in {
    # NixOS configuration for ongoing deploys
    nixosConfigurations.livingroom = pi5.nixosConfiguration;

    # SD card image for initial flash
    packages.aarch64-linux.livingroom-image = pi5.sdImage;

    # deploy-rs node
    deploy.nodes.livingroom = pi5.deploy;
  };
}
```

Build the SD image:

```sh
nix build .#livingroom-image
# result/sd-image/nixos-sd-image-*.img
```

Flash it:

```sh
sudo dd if=result/sd-image/nixos-sd-image-*.img of=/dev/sdX bs=4M status=progress
```

Deploy updates:

```sh
deploy .#livingroom
```

## mkHost options

| Option | Type | Default | Description |
|---|---|---|---|
| `hostModule` | module | — | Hardware profile (`nixosModules.pi4`, `nixosModules.pi5`, or your own) |
| `hostName` | string | — | NixOS hostname |
| `hostname` | string | — | Address for deploy-rs to reach the machine |
| `authorizedKeys` | list of strings | — | Ed25519 public keys for the deploy user |
| `system` | string | `"aarch64-linux"` | Target system |
| `extraModules` | list of modules | `[]` | Additional NixOS modules to include |

## Available host modules

- `nixosModules.pi4` — Raspberry Pi 4
- `nixosModules.pi5` — Raspberry Pi 5
- `nixosModules.default` — Just the deploy module, bring your own hardware config

## Adding extra services

Pass additional NixOS modules via `extraModules`:

```nix
pi5 = tiny-deploy.lib.mkHost {
  hostModule = tiny-deploy.nixosModules.pi5;
  hostName = "sensor-node";
  hostname = "sensor-node.local";
  authorizedKeys = [ "ssh-ed25519 AAAA..." ];
  extraModules = [
    {
      services.prometheus.exporters.node = {
        enable = true;
        port = 9100;
      };
      networking.firewall.allowedTCPPorts = [ 9100 ];
    }
  ];
};
```
