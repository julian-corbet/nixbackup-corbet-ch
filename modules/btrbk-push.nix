# btrbk-push.nix — a declarative front end over the upstream `services.btrbk`
# module, for a host ALLOWED to hold credentials reaching outward toward a
# backup receiver. This is the PUSH shape of btrfs replication: this host
# actively schedules and ships its own subvolumes out over SSH.
#
# NOT a competing daemon. `nixbackup` does not run or configure a NEW
# scheduling engine here — `services.btrbk` (nixpkgs' own packaging of the
# real, independently-maintained `btrbk` tool) already does the scheduling
# and the actual `btrfs send | btrfs receive` work; this module only
# renders that tool's own settings from a smaller, opinionated option
# surface, the same relationship nixbackup's ZFS-side modules have to
# `znapzend`/`syncoid` (see this repo's README, "Deliberately out of
# scope") — this repo has no opinion on retention or which tool schedules
# the replication, only on making the invariants around it hold.
#
# WHY THIS SHAPE EXISTS ALONGSIDE `btrbk-pull.nix`/`local-snapshots.nix`:
# push and pull are genuinely different trust postures, not two names for
# the same mechanism. Push means THIS host holds a credential reaching
# toward the receiver — appropriate when this host is already trusted (an
# internal box backing up to a home server, say). Pull means the RECEIVER
# reaches out and this host holds nothing outbound at all — appropriate
# when this host is the less-trusted one (a public-internet-facing box).
# Use whichever trust shape matches the host; this repo ships both rather
# than forcing one.
{ config, lib, pkgs, ... }:

let
  cfg = config.nixbackup.btrbkPush;
in
{
  options.nixbackup.btrbkPush = {
    enable = lib.mkEnableOption "btrbk source — push btrfs snapshots to a receiving host over SSH";

    targetHost = lib.mkOption {
      type = lib.types.str;
      example = "backup-receiver.example.org";
      description = "btrbk target hostname. No default -- this is the one fact this module cannot guess.";
    };

    targetUser = lib.mkOption {
      type = lib.types.str;
      default = "root";
      description = "SSH user on the target.";
    };

    targetPath = lib.mkOption {
      type = lib.types.path;
      example = "/mnt/btrbackup/example-source";
      description = "Receive directory on the target (a btrfs subvolume).";
    };

    sshIdentityFile = lib.mkOption {
      type = lib.types.path;
      example = "/etc/ssh/nixbackup_btrbk_push_ed25519";
      description = "Path to the SSH private key used by the btrbk push.";
    };

    subvolumes = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      example = [ "data" ];
      description = ''
        Source btrfs subvolumes to back up, named relative to `sourceVolume`.
        Kept a plain list of names rather than pre-built paths so the same
        volume/prefix isn't retyped once per subvolume.
      '';
    };

    sourceVolume = lib.mkOption {
      type = lib.types.path;
      example = "/data";
      description = "Parent btrfs volume `subvolumes` are named relative to, and where btrbk's own `snapshot_dir` lives.";
    };

    snapshotDir = lib.mkOption {
      type = lib.types.path;
      example = "/data/snapshots";
      description = ''
        Where btrbk keeps its own local snapshots before shipping them
        (CoW on the same disk — cheap). Distinct from
        `nixbackup.localSnapshots.snapshotDir` (this repo's sibling
        module) — that module is the hand-rolled PULL-side snapshot
        source; this one is btrbk's own, used only by this push module.
      '';
    };

    snapshotPreserve = lib.mkOption {
      type = lib.types.str;
      example = "24h 7d 4w";
      description = ''
        btrbk's own `snapshot_preserve` retention policy on the SOURCE
        (this host). This repo has no opinion on what the right policy is
        for your data — see the README's "Deliberately out of scope".
      '';
    };

    targetPreserve = lib.mkOption {
      type = lib.types.str;
      example = "14d 8w 12m";
      description = "btrbk's own `target_preserve` retention policy on the RECEIVING host.";
    };

    incremental = lib.mkOption {
      type = lib.types.enum [ "yes" "strict" "no" ];
      default = "strict";
      description = ''
        btrbk's own `incremental` setting. `"strict"` (the default here)
        never silently falls back to a full send when an incremental one
        fails — a full send is a materially different (and, over a WAN
        link, potentially much more expensive) operation than the
        incremental one that was actually scheduled, and a tool that
        substitutes one for the other without saying so is exactly the
        kind of silent-success failure mode this repo's sibling
        `nixbackup.monitor` module exists to catch from the other end.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.btrbk = {
      instances.nixbackup = {
        onCalendar = "hourly";
        settings = {
          snapshot_preserve = cfg.snapshotPreserve;
          target_preserve = cfg.targetPreserve;
          target_preserve_min = "no";

          # Push already-compressed extents as-is -- no recompress at either end.
          send_compressed_data = "yes";
          stream_compress = "no";

          ssh_identity = cfg.sshIdentityFile;
          ssh_user = cfg.targetUser;
          incremental = cfg.incremental;

          # btrbk 0.32's `target` directive takes a bare URL -- `send-receive` is the
          # default action and must NOT be repeated as a prefix (older btrbk versions
          # required it; the schema changed between 0.30 and 0.32). Check your pinned
          # nixpkgs' btrbk version if this ever needs revisiting.
          snapshot_dir = cfg.snapshotDir;
          volume.${cfg.sourceVolume} = {
            target = "ssh://${cfg.targetUser}@${cfg.targetHost}${cfg.targetPath}";
            subvolume = builtins.listToAttrs (
              map (sv: {
                name = sv;
                value = { };
              }) cfg.subvolumes
            );
          };
        };
      };
    };
  };
}
