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
