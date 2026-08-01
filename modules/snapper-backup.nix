# modules/snapper-backup.nix — a declarative front end over Arch's `snapper-backup`
# (the `snbk` tool bundled with the `snapper` package itself), for a system-manager
# host pushing snapper snapshots to a receiving host over SSH.
#
# system-manager ONLY. On real NixOS, nixpkgs' own `services.snapper` already
# provides a native, mature interface for snapshot policy -- this module exists
# specifically to close the gap on non-NixOS Linux hosts (Arch/CachyOS today)
# where `snapper`'s bundled `snbk` binary and its shipped `snapper-backup.service`/
# `.timer` are the only thing available, and where system-manager has no access to
# nixpkgs' own snapper module (same reasoning nixbackup's `btrbkPush` avoided for
# system-manager -- see this repo's README, "Deliberately out of scope"). Extracted
# and generalized from CORBET-ELITEBOOK's real, live setup (verified 2026-08-01) --
# the two incidents below are what actually happened there, not hypotheticals.
#
# WHY A DROP-IN, NOT A FULL UNIT REWRITE: `snbk`'s scheduling comes from the
# `snapper` package's OWN shipped systemd timer (`snapper-backup.timer`,
# OnCalendar=hourly by default) and service (`snapper-backup.service`,
# ExecStart=snbk plus its own hardening flags). system-manager cannot feed
# nixpkgs' `services.snapper` into the mix to regenerate these from scratch, and
# hand-reproducing every hardening line would drift the moment the `snapper`
# package updates them. So this module pins only the one thing that's actually a
# CALLER decision -- the schedule -- via a systemd drop-in, and leaves
# ExecStart/hardening to the package. The leading empty `OnCalendar=` clears the
# package's own directive first: systemd ADDS repeated keys rather than replacing
# them, so without it a future package default change would fire a SECOND trigger
# alongside this one instead of being superseded by it.
#
# WHY THE JSON *AND* THE SSH TRANSPORT ARE BOTH THIS MODULE'S JOB: on the real
# setup this was extracted from, the backup-configs JSON was declared but its SSH
# transport (a ProxyCommand alias) was left as an untracked file. A one-character
# error in that untracked script silently broke every backup for two weeks while
# the declared half looked perfect the whole time. Declaring config while leaving
# its transport untracked is a false sense of GitOps, so this module owns both --
# `sshExtraConfig` below exists so a caller's own transport quirks (a fleet-
# specific ProxyCommand, keepalive tuning) land in the SAME tracked file instead
# of a second untracked one.
#
# TESTING NOTE: this module only ever touches `environment.etc` and
# `systemd.services` -- primitives that mean the same thing under `lib.evalModules`
# regardless of backend -- so, like nixnet's `core.nix`, it can be evaluated
# through an ordinary `lib.nixosSystem` fixture for CI purposes (see flake.nix's
# checks) without a second, system-manager-specific test harness. `isSystemManager`
# below exists ONLY to keep that dual-evaluable: system-manager's `environment.etc`
# has a `replaceExisting` field real NixOS's does not, so it's added via
# `optionalAttrs`, never unconditionally. This is a testing convenience, not a
# claim that the module is meant to run on real NixOS -- see the top of this
# header for why it structurally shouldn't need to.
{ config, lib, pkgs, ... }:

let
  cfg = config.nixbackup.snapperBackup;

  # Same detection nixnet's core.nix uses and documents as deliberately cheaper/
  # more robust than probing whether some other option is an extensible attrset.
  isSystemManager = builtins.hasAttr "system-manager" config;

  mkBackupJson = name: b: builtins.toJSON ({
    config = name;
    automatic = true;
    "target-mode" = "ssh-push";
    "source-path" = b.sourcePath;
    "target-path" = "${cfg.targetPathPrefix}/${b.targetSubvolume}";
    "ssh-host" = cfg.targetHost;
    "ssh-user" = cfg.targetUser;
    "ssh-identity" = cfg.sshIdentityFile;
    "send-compressed-data" = true;
  } // (lib.mapAttrs' (n: v: lib.nameValuePair "target-${n}-bin" v) cfg.targetToolBins));
in
{
  options.nixbackup.snapperBackup = {
    enable = lib.mkEnableOption "snapper-backup (snbk) -- push snapper snapshots to a receiving host over SSH, declaratively, via system-manager";

    targetHost = lib.mkOption {
      type = lib.types.str;
      example = "backup-receiver.example.org";
      description = ''
        SSH host/alias for the receiver. Plain passthrough -- used both as
        the `ssh-host` in every backup's JSON and as the rendered
        ssh_config.d `Host` block below. This repo has no opinion on your
        transport topology (LAN-first/overlay fallback, a bastion,
        whatever) -- see `sshExtraConfig` if that alias needs custom
        resolution beyond a plain hostname.
      '';
    };

    targetUser = lib.mkOption {
      type = lib.types.str;
      default = "root";
      description = "SSH user on the target.";
    };

    targetPathPrefix = lib.mkOption {
      type = lib.types.path;
      example = "/mnt/btrfs-backup/example-host";
      description = ''
        Base receive directory on the target. Each backup's own
        `targetSubvolume` (below) is appended to this to form its full
        target path.
      '';
    };

    sshIdentityFile = lib.mkOption {
      type = lib.types.path;
      example = "/etc/ssh/nixbackup_snapper_ed25519";
      description = "Path to the SSH private key used by the push.";
    };

    sshExtraConfig = lib.mkOption {
      type = lib.types.lines;
      default = "";
      example = ''
            ProxyCommand /path/to/lan-first-fallback-probe
            ConnectTimeout 10
      '';
      description = ''
        Extra lines rendered directly into the generated ssh_config.d
        `Host` block for `targetHost` (e.g. a fleet-specific
        ProxyCommand, keepalive tuning). Indent to match the surrounding
        `Host` block yourself -- this is spliced in verbatim. This repo
        has no opinion on your transport (see the module header) -- but
        the block carrying it is rendered HERE, alongside the config it
        serves, rather than left for the caller to track as a separate
        untracked file.
      '';
    };

    onCalendar = lib.mkOption {
      type = lib.types.str;
      default = "hourly";
      description = ''
        Pins `snapper-backup.timer`'s OnCalendar= via a systemd drop-in,
        rather than leaving it as whatever the `snapper` package happens
        to ship. See the module header for why a drop-in, not a full
        unit rewrite.
      '';
    };

    targetToolBins = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      default = {
        btrfs-bin = "/run/current-system/sw/bin/btrfs";
        ls-bin = "/run/current-system/sw/bin/ls";
        mkdir-bin = "/run/current-system/sw/bin/mkdir";
        rm-bin = "/run/current-system/sw/bin/rm";
        rmdir-bin = "/run/current-system/sw/bin/rmdir";
        sha256sum-bin = "/run/current-system/sw/bin/sha256sum";
      };
      description = ''
        `snbk`'s `target-<tool>-bin` overrides -- the remote-side tool
        paths it shells out to over the ssh-push transport. Defaults
        assume a NixOS receiver (`/run/current-system/sw/bin`); override
        for anything else.
      '';
    };

    backups = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          sourcePath = lib.mkOption {
            type = lib.types.path;
            description = "Local path this snapper config snapshots (must match the snapper config's own SUBVOLUME).";
          };
          targetSubvolume = lib.mkOption {
            type = lib.types.str;
            description = "Subvolume name under targetPathPrefix this backup lands in on the receiver.";
          };
        };
      });
      default = { };
      example = {
        root = {
          sourcePath = "/";
          targetSubvolume = "@";
        };
      };
      description = ''
        One entry per snapper config to back up. The attribute name MUST
        match an existing snapper config name -- snbk is a pure CONSUMER
        of snapper snapshots, it creates none of its own -- so keep this
        set in lockstep with whatever declares your snapper configs, or
        snbk fails ("Unknown config") on the mismatch.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.etc =
      (lib.mapAttrs'
        (name: b: lib.nameValuePair "snapper/backup-configs/${name}.json" ({
          text = (mkBackupJson name b) + "\n";
        } // lib.optionalAttrs isSystemManager { replaceExisting = true; }))
        cfg.backups)
      // {
        "ssh/ssh_config.d/40-nixbackup-snapper-backup.conf" = {
          text = ''
            # Managed by nixbackup (nixbackup.snapperBackup).
            Host ${cfg.targetHost}
                User ${cfg.targetUser}
                IdentityFile ${cfg.sshIdentityFile}
            ${cfg.sshExtraConfig}
          '';
        } // lib.optionalAttrs isSystemManager { replaceExisting = true; };

        "systemd/system/snapper-backup.timer.d/50-declared-schedule.conf".text = ''
          # Managed by nixbackup (nixbackup.snapperBackup).
          [Timer]
          OnCalendar=
          OnCalendar=${cfg.onCalendar}
        '';
      };

    # Writing the drop-in above does not apply it -- systemd needs a daemon-reload
    # AND the already-active timer needs restarting to pick up the new definition.
    # Restarting the *timer* is safe regardless of whether a backup happens to be
    # mid-transfer at that moment: it only resets the timer's own schedule state,
    # never touches an in-flight snapper-backup.service run.
    systemd.services.nixbackup-snapper-backup-reapply = {
      description = "Re-apply the declared snapper-backup.timer schedule after a change";
      after = [ "snapper-backup.timer" ];
      wantedBy = [ "multi-user.target" ];
      restartTriggers = [
        config.environment.etc."systemd/system/snapper-backup.timer.d/50-declared-schedule.conf".source
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "/usr/bin/systemctl daemon-reload";
        ExecStartPost = "/usr/bin/systemctl restart snapper-backup.timer";
      };
    };
  };
}
