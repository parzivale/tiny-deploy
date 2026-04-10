{
  config,
  pkgs,
  lib,
  ...
}: let
  cfg = config.services.tiny-deploy;
in {
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

    # ── Stripped kernel ───────────────────────────────────────────────────
    # Headless ssh-only deploy shell: rip out anything we don't need.
    # Monolithic kernel (MODULES=n) — no loadable modules exist.
    boot.initrd.availableKernelModules = lib.mkForce [];
    boot.initrd.kernelModules = lib.mkForce [];
    boot.kernelModules = lib.mkForce [];
    boot.initrd.includeDefaultModules = false;

    boot.kernelPackages = pkgs.linuxPackagesFor (pkgs.linux.override {
      ignoreConfigErrors = true;
      structuredExtraConfig = with lib.kernel; lib.mapAttrs (_: lib.mkForce) {
        # Monolithic kernel: no loadable modules, everything needed is builtin.
        MODULES = no;

        # ── Boot-critical: force builtin (default =m would become =n) ────
        # Root filesystem + nix store
        EXT4_FS = yes;
        SQUASHFS = yes;
        SQUASHFS_XZ = yes;
        SQUASHFS_ZSTD = yes;
        OVERLAY_FS = yes;

        # /boot (VFAT)
        VFAT_FS = yes;
        FAT_FS = yes;
        NLS_CODEPAGE_437 = yes;
        NLS_ASCII = yes;
        NLS_ISO8859_1 = yes;
        NLS_UTF8 = yes;

        # SD card (sd-image boots from SD on the pi)
        MMC = yes;
        MMC_BLOCK = yes;
        MMC_SDHCI = yes;
        MMC_SDHCI_PLTFM = yes;
        MMC_SDHCI_IPROC = yes;
        MMC_BCM2835 = yes;

        # NVMe (pi5 commonly boots off NVMe hat)
        BLK_DEV_NVME = yes;
        NVME_CORE = yes;

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

        # Device tree + pi platform bits
        OF = yes;
        DEVTMPFS = yes;
        DEVTMPFS_MOUNT = yes;

        # Firewall (nftables)
        NETFILTER = yes;
        NF_TABLES = yes;
        NF_TABLES_INET = yes;
        NFT_CT = yes;

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

        # Virtualization: pi is not a hypervisor host
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
        ATA = no;

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
