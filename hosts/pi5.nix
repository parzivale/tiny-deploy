{
  modulesPath,
  lib,
  ...
}: {
  imports = [
    (modulesPath + "/profiles/minimal.nix")
  ];

  # ── Boot ──────────────────────────────────────────────────────────────
  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = true;

  system.nixos-init.enable = true;
  boot.initrd.systemd.enable = true;

  boot.initrd.availableKernelModules = [
    "nvme" "usbhid" "usb_storage"
  ];
  boot.kernelModules = [];
  boot.initrd.includeDefaultModules = false;
  boot.kernelParams = ["quiet"];

  # aarch64
  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";
}
