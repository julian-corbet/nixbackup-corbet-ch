# btrbk-pull.nix — the HOME/RECEIVER half of a pull-based btrfs replication
# pair (see `local-snapshots.nix`, this repo's sibling module, for the
# SOURCE side).
#
# This host reaches OUT to a remote node, picks the newest remote snapshot
# (produced by that node's own `nixbackup.localSnapshots`), and ships the
# delta home via `btrfs send -p <parent> | btrfs receive`.
#
# DIRECTION MATTERS. The remote node never pushes. A remote that is a
# public-internet box holds ZERO credentials reaching into this (trusted)
# side with a pull design — a compromised remote can at most be READ from,
# never write into anything here. This host (trusted) initiates outbound
# and only ever READS from the remote.
#
# WHY A SEPARATE MODULE FROM `btrbk-push.nix`: that module wraps the
# `btrbk` tool's own scheduling for a host that IS allowed to hold
# credentials reaching outward toward a receiver — the opposite trust
# shape from this one. Both are real, common shapes a btrfs replication
# pair takes; this repo ships both rather than picking one and forcing
# every deployment into it.
#
# `remoteSnapshotDir` must match the remote's own `nixbackup.localSnapshots.
# snapshotDir` (this repo's sibling module) exactly — nothing here verifies
# that agreement automatically; get it right by reading the fact off the
# remote's own config rather than assuming a convention. Its retention
# (`retain` there) must outlive the gap between two pulls here, or no
# shared parent survives on the remote side and every pull degrades from a
# cheap incremental send to an expensive full one.
{ config, lib, pkgs, ... }:

let
  cfg = config.nixbackup.btrbkPull;
in
{
  options.nixbackup.btrbkPull = {
    enable = lib.mkEnableOption ''
      Home-side btrfs snapshot PULL from a remote node. See this module's
      own header for the full trust-direction rationale.
    '';

    remoteHost = lib.mkOption {
      type = lib.types.str;
      example = "203.0.113.5";
      description = "Address of the node to pull from. No default -- this is the one fact this module cannot guess.";
    };

    remoteUser = lib.mkOption {
      type = lib.types.str;
      default = "root";
      description = "SSH user on the remote node. Needs to run `btrfs send` (root, in practice).";
    };

    remoteSnapshotDir = lib.mkOption {
      type = lib.types.path;
      example = "/data/snapshots/hot";
      description = ''
        Where the remote node's own `nixbackup.localSnapshots` (this
        repo's sibling module) puts its snapshots. Must match exactly --
        see this module's header.
      '';
    };

    targetPath = lib.mkOption {
      type = lib.types.path;
      example = "/mnt/btrfs-backup/example-node";
      description = ''
        Receive directory on THIS host. MUST be on a real btrfs
        filesystem — `btrfs receive` creates subvolumes via btrfs
        ioctls and cannot work on NFS or ZFS.
      '';
    };

    sshIdentityFile = lib.mkOption {
      type = lib.types.path;
      example = "/root/.ssh/id_nixbackup_pull";
      description = ''
        Private key for the pull. Should exist ONLY on this receiving
        host; its public half is added to the remote node's own
        `authorizedKeys`. No default — a shared or reused key here
        defeats the whole point of a dedicated, narrowly-scoped pull
        identity.
      '';
    };

    retainDays = lib.mkOption {
      type = lib.types.int;
      default = 14;
      description = ''
        Delete RECEIVED snapshots (on this host) older than this many
        days. The most recent received snapshot is ALWAYS kept
        regardless of this setting — it is the parent for the next
        incremental send.
      '';
    };

    onCalendar = lib.mkOption {
      type = lib.types.str;
      default = "03:30";
      description = "systemd OnCalendar= for the pull.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.nixbackup-btrbk-pull = {
      description = "Pull btrfs snapshots from ${cfg.remoteHost} to ${cfg.targetPath}";
      path = with pkgs; [
        btrfs-progs
        coreutils
        openssh
      ];
      script = ''
        set -euo pipefail

        SSH="ssh -i ${cfg.sshIdentityFile} -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 ${cfg.remoteUser}@${cfg.remoteHost}"

        mkdir -p ${cfg.targetPath}

        # Newest snapshot on the remote node (TS names are lexicographically chronological
        # among THEMSELVES -- but the dir can also hold one-off named snapshots, and a
        # non-timestamp name can sort after every real timestamp under a naive sort. Filter
        # to the timestamp shape first, so a stray name never gets mistaken for the real
        # newest and stall the pull re-declaring victory on it forever.)
        LATEST=$($SSH "ls -1 ${cfg.remoteSnapshotDir}" | grep -E '^[0-9]{8}T[0-9]{6}Z$' | sort | tail -1)
        if [ -z "$LATEST" ]; then
          echo "no snapshots on ${cfg.remoteHost}:${cfg.remoteSnapshotDir}" >&2
          exit 1
        fi

        if [ -e "${cfg.targetPath}/$LATEST" ]; then
          echo "already have $LATEST -- nothing to pull"
          exit 0
        fi

        # Parent = newest locally-received snapshot that STILL EXISTS on the remote.
        # Without a shared parent an incremental send is impossible, so we fall back to a
        # full send (costlier, but correct).
        REMOTE_LIST=$($SSH "ls -1 ${cfg.remoteSnapshotDir}")
        PARENT=""
        for cand in $(ls -1 ${cfg.targetPath} 2>/dev/null | sort -r); do
          if echo "$REMOTE_LIST" | grep -qx "$cand"; then
            PARENT="$cand"
            break
          fi
        done

        # --compressed-data ships the on-disk compressed extents as-is (no decompress/
        # recompress) when both sides support it.
        if [ -n "$PARENT" ]; then
          echo "incremental send: parent=$PARENT -> $LATEST"
          $SSH "btrfs send --compressed-data -p ${cfg.remoteSnapshotDir}/$PARENT ${cfg.remoteSnapshotDir}/$LATEST" \
            | btrfs receive ${cfg.targetPath}
        else
          echo "no shared parent -- FULL send of $LATEST (check the remote's nixbackup.localSnapshots.retain)"
          $SSH "btrfs send --compressed-data ${cfg.remoteSnapshotDir}/$LATEST" \
            | btrfs receive ${cfg.targetPath}
        fi
        echo "received: ${cfg.targetPath}/$LATEST"

        # Retention: drop received snapshots older than retainDays, but NEVER the newest --
        # it is the parent for the next incremental.
        NEWEST=$(ls -1 ${cfg.targetPath} | sort | tail -1)
        CUTOFF=$(date -u -d "${toString cfg.retainDays} days ago" +%Y%m%dT%H%M%SZ)
        for old in $(ls -1 ${cfg.targetPath} | sort); do
          [ "$old" = "$NEWEST" ] && continue
          if [ "$old" \< "$CUTOFF" ]; then
            btrfs subvolume delete "${cfg.targetPath}/$old"
            echo "retired: $old"
          fi
        done
      '';
      serviceConfig = {
        Type = "oneshot";
        # A failed pull must be loud: this is the ONLY copy of this data outside the source
        # host by design, and a silent failure here can run for weeks before anyone notices.
        SuccessExitStatus = [ 0 ];
      };
      after = [
        "local-fs.target"
        "network-online.target"
      ];
      wants = [ "network-online.target" ];
      requires = [ "local-fs.target" ];
    };

    systemd.timers.nixbackup-btrbk-pull = {
      description = "btrfs snapshot pull from ${cfg.remoteHost}";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.onCalendar;
        Persistent = true; # catch up if the box was down at the scheduled tick
        AccuracySec = "5min";
      };
    };
  };
}
