# local-snapshots.nix — the SOURCE half of a pull-based btrfs replication
# pair (see `btrbk-pull.nix`, this repo's sibling module, for the HOME side).
#
# Creates a read-only snapshot of `source` into `snapshotDir/<ts>/` on every
# timer fire (hourly by default), and retires everything past `retain` most-
# recent snapshots. Snapshots are CoW on the SAME filesystem — fast, near-
# zero space cost unless the source churns heavily between fires.
#
# WHY A SEPARATE MODULE FROM `btrbk-push.nix`: this is the OTHER shape a
# btrfs replication pair can take. `btrbk-push.nix` wraps the `btrbk` tool's
# own scheduling (a source host actively ships to a receiver over SSH).
# This module does neither transport nor scheduling of the SEND side — it
# only produces the local, retained, read-only snapshots a REMOTE puller
# (`btrbk-pull.nix`, run on the RECEIVING host) can reach in over its own
# SSH connection and pick the newest one from. The two are not
# interchangeable: `btrbk-push.nix` is for a host that is ALLOWED to hold
# credentials reaching outward into the receiver's network; this module is
# for a host that should hold ZERO credentials reaching the other way — a
# public-internet-facing box, say, where the receiver initiating a pull
# means a compromised source can at most be READ from, never write into the
# trusted side. See `btrbk-pull.nix`'s own header for the full split.
#
# `retain` MUST outlive the gap between two pulls, or no snapshot survives
# on this side that the puller's own history still has a matching parent
# for, and every pull silently degrades from a cheap incremental send to a
# full send — expensive, and if this host pays for egress, a real cost. See
# `btrbk-pull.nix`'s own header for the mechanics of how that parent match
# actually works.
{ config, lib, pkgs, ... }:

let
  cfg = config.nixbackup.localSnapshots;
in
{
  options.nixbackup.localSnapshots = {
    enable = lib.mkEnableOption
      "local, retained, read-only btrfs snapshots of `source`, for a remote puller to pick up over its own SSH connection";

    source = lib.mkOption {
      type = lib.types.path;
      example = "/data/hot";
      description = ''
        btrfs subvolume to snapshot. Whole-subvolume, not per-file — a
        snapshot of the parent captures every child directory atomically in
        one CoW operation, which is also why a single retention count below
        governs everything nested under it as one unit.
      '';
    };

    snapshotDir = lib.mkOption {
      type = lib.types.path;
      example = "/data/snapshots/hot";
      description = ''
        Where to put the snapshots. MUST be on the same btrfs filesystem as
        `source` — cross-filesystem snapshots don't exist. This is exactly
        the path a companion `nixbackup.btrbkPull.remoteSnapshotDir` (this
        repo's own `btrbk-pull.nix`, run on the receiving host) needs to be
        told about, so the two stay in agreement by being set from the same
        fact rather than typed twice.
      '';
    };

    retain = lib.mkOption {
      type = lib.types.int;
      default = 24;
      description = ''
        Number of snapshots to keep. Older ones are deleted on every timer
        fire. The default (24 = roughly one day at the default hourly
        cadence) is a starting point, not a policy recommendation — see
        this module's header for why it must outlive the real gap between
        pulls, which depends entirely on how often the remote puller
        actually runs and how tolerant of a missed run it needs to be.
      '';
    };

    onCalendar = lib.mkOption {
      type = lib.types.str;
      default = "hourly";
      description = "systemd OnCalendar= expression for snapshot cadence.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.nixbackup-local-snapshots = {
      description = "Create + retire btrfs snapshots of ${cfg.source}";
      path = with pkgs; [
        btrfs-progs
        coreutils
      ];
      script = ''
        set -euo pipefail
        mkdir -p ${cfg.snapshotDir}
        TS=$(date -u +%Y%m%dT%H%M%SZ)
        btrfs subvolume snapshot -r ${cfg.source} ${cfg.snapshotDir}/$TS
        echo "nixbackup-local-snapshots: created ${cfg.snapshotDir}/$TS"

        # Retire snapshots older than `retain` (sorted lexicographically;
        # the TS format above is lexicographically chronological).
        cd ${cfg.snapshotDir}
        for old in $(ls -1 | sort | head -n -${toString cfg.retain}); do
          btrfs subvolume delete "$old"
          echo "nixbackup-local-snapshots: retired $old"
        done
      '';
      serviceConfig = {
        Type = "oneshot";
      };
      # Wait for the source filesystem to mount before snapshotting.
      after = [ "local-fs.target" ];
      requires = [ "local-fs.target" ];
    };

    systemd.timers.nixbackup-local-snapshots = {
      description = "Local btrfs snapshot cadence for ${cfg.source}";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.onCalendar;
        Persistent = true; # catch up if the host was off across a scheduled tick
        AccuracySec = "5min"; # let systemd batch with other timers
      };
    };
  };
}
