{
  modulesPath,
  lib,
  ...
}: {
  imports = [
    (modulesPath + "/profiles/minimal.nix")
  ];

  # Boots via EDK2 UEFI firmware (pftf/RPi4) written to the FAT firmware
  # partition of the SD card alongside the pi's bootcode. Once UEFI is in
  # place, the rest is handled by the shared module.nix (systemd-boot +
  # image.repart).
  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";
}
