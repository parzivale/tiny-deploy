{
  modulesPath,
  lib,
  ...
}: {
  imports = [
    (modulesPath + "/profiles/minimal.nix")
  ];

  # Boots via EDK2 UEFI firmware (worproject/rpi5-uefi) flashed to the
  # board's SPI EEPROM or written to a separate firmware partition. Once
  # UEFI is in place, the rest is handled by the shared module.nix
  # (systemd-boot + image.repart).
  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";
}
