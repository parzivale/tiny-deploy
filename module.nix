{
  config,
  pkgs,
  lib,
  modulesPath,
  ...
}: let
  cfg = config.services.tiny-deploy;
in {
  imports = [
    (modulesPath + "/image/repart.nix")
  ];

  options.services.tiny-deploy = {
    enable = lib.mkEnableOption "tiny-deploy locked-down deployment target";

    authorizedKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "Ed25519 public keys authorized for deployment.";
    };

    interface = lib.mkOption {
      type = lib.types.str;
      default = "eth0";
      description = "Network interface to enable DHCP on.";
    };

    hostName = lib.mkOption {
      type = lib.types.str;
      description = "Hostname for the target machine.";
    };

    deployShell = lib.mkOption {
      type = lib.types.package;
      description = "The deploy-shell binary package.";
    };
  };

  config = lib.mkIf cfg.enable {
    system.etc.overlay.enable = true;

    # ── Nix ───────────────────────────────────────────────────────────────
    nix.enable = false;

    # ── Users ─────────────────────────────────────────────────────────────
    users.mutableUsers = false;
    services.userborn.enable = true;
    # I want to be locked out
    users.allowNoPasswordLogin = true;
    users.users.root = {
      hashedPassword = "!";
      shell = pkgs.shadow;
    };

    users.users.deploy = {
      isSystemUser = true;
      group = "deploy";
      shell = cfg.deployShell;
      openssh.authorizedKeys.keys = cfg.authorizedKeys;
    };
    users.groups.deploy = {};

    security.sudo.extraRules = [
      {
        users = ["deploy"];
        commands = [
          {
            command = "/run/current-system/sw/bin/activate-rs";
            options = ["NOPASSWD"];
          }
        ];
      }
    ];

    # ── SSH (tinyssh) ─────────────────────────────────────────────────────
    services.openssh.enable = false;

    environment.etc."tinyssh/authorized_keys".text =
      lib.concatStringsSep "\n" cfg.authorizedKeys;

    system.activationScripts.tinyssh-keygen = {
      text = ''
        if [ ! -f /etc/tinyssh/sshkeydir/ed25519.pk ]; then
          mkdir -p /etc/tinyssh/sshkeydir
          ${pkgs.tinyssh}/bin/tinysshd-makekey /etc/tinyssh/sshkeydir
        fi
      '';
      deps = [];
    };

    systemd.sockets.tinysshd = {
      wantedBy = ["sockets.target"];
      socketConfig = {
        ListenStream = 22;
        Accept = true;
      };
    };

    systemd.services."tinysshd@" = {
      serviceConfig = {
        ExecStart = "${pkgs.tinyssh}/bin/tinysshd /etc/tinyssh/sshkeydir";
        KillMode = "process";
        SuccessExitStatus = 111;
        StandardInput = "socket";
      };
    };

    # ── Firewall ──────────────────────────────────────────────────────────
    networking.firewall = {
      enable = true;
      allowedTCPPorts = [22];
    };

    # ── Systemd hardening ─────────────────────────────────────────────────
    systemd.suppressedSystemUnits = [
      "systemd-machined.service"
      "systemd-importd.service"
      "systemd-coredump@.service"
      "systemd-coredump.socket"
      "rescue.service"
      "rescue.target"
      "emergency.service"
      "emergency.target"
    ];

    services.getty.autologinUser = lib.mkForce null;
    systemd.services."getty@".enable = false;
    systemd.services."serial-getty@".enable = false;

    # ── Bootloader (UEFI + systemd-boot) ──────────────────────────────────
    # UEFI everywhere: x86 server, aarch64 server, Pi 4/5 via EDK2 (pftf /
    # worproject), VMs via OVMF. systemd-boot manages generation entries for
    # deploy-rs rollback. No u-boot, no extlinux, no sd-image machinery.
    boot.loader.grub.enable = false;
    boot.loader.generic-extlinux-compatible.enable = false;
    boot.loader.systemd-boot.enable = true;
    boot.loader.systemd-boot.configurationLimit = 10;
    # SBCs with EDK2 firmware generally cannot persist EFI variables.
    boot.loader.efi.canTouchEfiVariables = false;
    boot.loader.efi.efiSysMountPoint = "/boot";

    boot.initrd.systemd.enable = true;
    boot.kernelParams = ["quiet"];

    # ── Filesystems ───────────────────────────────────────────────────────
    fileSystems."/" = {
      device = "/dev/disk/by-partlabel/root";
      fsType = "ext4";
    };
    fileSystems."/boot" = {
      device = "/dev/disk/by-partlabel/ESP";
      fsType = "vfat";
      options = ["umask=0077"];
    };

    # ── Disk image (systemd-repart) ───────────────────────────────────────
    # Builds a GPT image with an ESP (pre-populated with systemd-boot + a
    # bootstrap UKI so the image boots on first power-on) and an ext4 root.
    # On activation, the systemd-boot installer writes per-generation entries
    # to /boot, so deploy-rs rollback works normally after first boot.
    system.image.id = lib.mkDefault "tiny-deploy";
    system.image.version = lib.mkDefault "1";

    image.repart = {
      name = "tiny-deploy";
      # OVMF/EDK2 builds expect 512-byte sectors.
      sectorSize = 512;
      partitions = {
        "10-esp" = {
          contents = {
            "/EFI/BOOT/BOOT${lib.toUpper pkgs.stdenv.hostPlatform.efiArch}.EFI".source =
              "${pkgs.systemd}/lib/systemd/boot/efi/systemd-boot${pkgs.stdenv.hostPlatform.efiArch}.efi";
            "/EFI/Linux/${config.system.boot.loader.ukiFile}".source =
              "${config.system.build.uki}/${config.system.boot.loader.ukiFile}";
          };
          repartConfig = {
            Type = "esp";
            Format = "vfat";
            Label = "ESP";
            SizeMinBytes = "128M";
          };
        };
        "20-root" = {
          storePaths = [config.system.build.toplevel];
          repartConfig = {
            Type = "root";
            Format = "ext4";
            Label = "root";
            Minimize = "guess";
          };
        };
      };
    };

    # ── Stripped kernel ───────────────────────────────────────────────────
    # Headless ssh-only deploy target: rip out anything we don't need.
    # Monolithic kernel (MODULES=n) — no loadable modules exist.
    boot.initrd.availableKernelModules = lib.mkForce [];
    boot.initrd.kernelModules = lib.mkForce [];
    boot.kernelModules = lib.mkForce [];
    boot.initrd.includeDefaultModules = false;

    boot.kernelPackages = pkgs.linuxPackagesFor (pkgs.linux.override {
      ignoreConfigErrors = true;
      structuredExtraConfig = with lib.kernel;
        lib.mapAttrs (_: lib.mkForce) {
          # Monolithic kernel: no loadable modules, everything needed is builtin.
          MODULES = no;

          # ── Boot-critical: force builtin (default =m would become =n) ──
          # Root filesystem + nix store
          EXT4_FS = yes;
          SQUASHFS = yes;
          SQUASHFS_XZ = yes;
          SQUASHFS_ZSTD = yes;
          OVERLAY_FS = yes;

          # /boot (VFAT ESP)
          VFAT_FS = yes;
          FAT_FS = yes;
          NLS_CODEPAGE_437 = yes;
          NLS_ASCII = yes;
          NLS_ISO8859_1 = yes;
          NLS_UTF8 = yes;

          # EFI: needed to consume UEFI firmware services and ESP
          EFI = yes;
          EFI_STUB = yes;
          EFI_PARTITION = yes;
          EFIVAR_FS = yes;
          EFI_RUNTIME_WRAPPERS = yes;

          # GPT
          PARTITION_ADVANCED = yes;

          # Storage: NVMe (servers / pi NVMe hat)
          BLK_DEV_NVME = yes;
          NVME_CORE = yes;

          # Storage: SATA/AHCI (x86 / arm servers)
          ATA = yes;
          SATA_AHCI = yes;
          SATA_AHCI_PLATFORM = yes;

          # Storage: virtio (VMs)
          VIRTIO = yes;
          VIRTIO_PCI = yes;
          VIRTIO_BLK = yes;
          VIRTIO_NET = yes;
          VIRTIO_MMIO = yes;

          # Storage: SD/MMC (pi SD boot; harmless elsewhere)
          MMC = yes;
          MMC_BLOCK = yes;
          MMC_SDHCI = yes;
          MMC_SDHCI_PLTFM = yes;

          # USB host + storage + HID
          USB = yes;
          USB_SUPPORT = yes;
          USB_XHCI_HCD = yes;
          USB_XHCI_PCI = yes;
          USB_XHCI_PLATFORM = yes;
          USB_STORAGE = yes;
          HID = yes;
          HID_GENERIC = yes;
          USB_HID = yes;

          # Device tree + platform bits (ARM SBCs)
          OF = yes;
          DEVTMPFS = yes;
          DEVTMPFS_MOUNT = yes;

          # Firewall (nftables)
          NETFILTER = yes;
          NF_TABLES = yes;
          NF_TABLES_INET = yes;
          NFT_CT = yes;

          # I/O scheduler: mq-deadline is plenty, drop BFQ
          # (default =m breaks with MODULES=n)
          IOSCHED_BFQ = no;

          # No audio / media / graphics
          SOUND = no;
          MEDIA_SUPPORT = no;
          DRM = no;
          FB = no;
          LOGO = no;
          BACKLIGHT_CLASS_DEVICE = no;
          VT = no;
          AGP = no;

          # No wireless / bluetooth / short-range radio
          WIRELESS = no;
          CFG80211 = no;
          MAC80211 = no;
          BT = no;
          RFKILL = no;
          NFC = no;
          WIMAX = no;
          HAMRADIO = no;

          # No exotic networking
          CAN = no;
          IEEE802154 = no;
          ATM = no;
          IRDA = no;
          DECNET = no;
          APPLETALK = no;
          X25 = no;
          LAPB = no;
          PHONET = no;
          "6LOWPAN" = no;
          MPLS = no;
          L2TP = no;
          VLAN_8021Q = no;
          BRIDGE = no;
          NET_SCHED = no;
          NET_L3_MASTER_DEV = no;

          # Filesystems: keep ext4 + vfat, drop the rest
          BTRFS_FS = no;
          XFS_FS = no;
          JFS_FS = no;
          REISERFS_FS = no;
          F2FS_FS = no;
          NILFS2_FS = no;
          NTFS3_FS = no;
          HFSPLUS_FS = no;
          HFS_FS = no;
          OCFS2_FS = no;
          GFS2_FS = no;
          UBIFS_FS = no;
          AFS_FS = no;
          CEPH_FS = no;
          CIFS = no;
          NFS_FS = no;
          NFSD = no;
          "9P_FS" = no;
          QUOTA = no;
          AUTOFS_FS = no;
          FUSE_FS = no;
          ISO9660_FS = no;
          UDF_FS = no;
          MSDOS_FS = no;
          JFFS2_FS = no;
          NFS_COMMON = no;
          SUNRPC = no;

          # Virtualization: deploy target is not a hypervisor host
          KVM = no;
          XEN = no;
          HYPERV = no;
          VIRTUALIZATION = no;
          PARAVIRT = no;

          # Debug / tracing / profiling
          FTRACE = no;
          PROFILING = no;
          KGDB = no;
          PERF_EVENTS = no;
          KPROBES = no;
          UPROBES = no;

          # Legacy / unused buses and stacks
          PCCARD = no;
          PARPORT = no;
          MTD = no;
          THUNDERBOLT = no;
          FIREWIRE = no;
          EISA = no;
          PCI_QUIRKS = no;

          # Power management / hotplug we don't need
          SUSPEND = no;
          HIBERNATION = no;
          MEMORY_HOTPLUG = no;
          NUMA = no;
          KEXEC = no;
          CRASH_DUMP = no;

          # Block layer extras
          MD = no;
          BLK_DEV_DM = no;
          BCACHE = no;
          ZRAM = no;
          BLK_DEV_NBD = no;
          BLK_DEV_RBD = no;
          BLK_DEV_DRBD = no;

          # SCSI low-level drivers (keep core for usb-storage)
          SCSI_LOWLEVEL = no;

          # Sensors / EDAC / misc hardware
          HWMON = no;
          EDAC = no;
          WATCHDOG = no;
          IIO = no;

          # Input: keep keyboard/mouse core; drop the rest
          INPUT_JOYSTICK = no;
          INPUT_TABLET = no;
          INPUT_TOUCHSCREEN = no;
          INPUT_MISC = no;
          JOYSTICK_XPAD = no;

          # USB: keep core + hid + storage; drop the rest
          USB_SERIAL = no;
          USB_PRINTER = no;
          USB_VIDEO_CLASS = no;
          USB_NET_DRIVERS = no;

          # Misc
          ACCESSIBILITY = no;
          TABLET = no;
          FONTS = no;
          STAGING = no;
          GAMEPORT = no;
        };
    });

    # ── Strip environment ─────────────────────────────────────────────────
    environment.systemPackages = lib.mkForce [pkgs.tinyssh];
    environment.defaultPackages = lib.mkForce [];

    programs.bash.enable = false;
    programs.command-not-found.enable = false;

    documentation.enable = false;
    documentation.man.enable = false;
    documentation.nixos.enable = false;

    i18n.supportedLocales = lib.mkForce ["en_US.UTF-8/UTF-8"];
    fonts.fontconfig.enable = false;

    # ── Security ──────────────────────────────────────────────────────────
    security.polkit.enable = false;
    services.udisks2.enable = false;
    security.wrappers = lib.mkForce {};

    # ── Networking ────────────────────────────────────────────────────────
    networking.hostName = cfg.hostName;
    networking.useDHCP = false;
    networking.interfaces.${cfg.interface}.useDHCP = true;
    networking.usePredictableInterfaceNames = false;

    # ── Logging ───────────────────────────────────────────────────────────
    services.journald.extraConfig = ''
      Storage=volatile
      RuntimeMaxUse=32M
    '';
  };
}
