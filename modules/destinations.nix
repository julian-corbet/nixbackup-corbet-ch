# destinations.nix — enforce the receive-destination invariants: every backup
# RECEIVE destination dataset (the target side of a `zfs send | zfs receive`
# pipeline) stays canmount=noauto, readonly=on -- both SET LOCALLY -- and
# UNMOUNTED. A boot + timer oneshot re-asserts all three on a schedule, so a
# stray `zfs set`, a `zfs inherit`, or a host rebuild that remounts the pool
# can never re-open the divergence described below.
#
# THE PHANTOM-WRITE MECHANISM (why this module exists)
#
#   A receive destination is a live filesystem: mount its root, and every
#   child dataset underneath gets its own separate mount layered into the
#   parent's directory tree. Between "the parent mounts" and "each child
#   mounts" -- or permanently, for any child that never auto-mounts -- the
#   parent's own filesystem shows empty placeholder directories at each
#   child's mountpoint. Creating and touching those directories is itself a
#   write to the PARENT dataset: a few bytes of directory-entry/metadata
#   churn, not one byte of real payload changing.
#
#   `zfs receive`'s own incremental-replication safety check cannot tell the
#   difference. An incremental receive refuses to write into a destination
#   that has been modified since its last received snapshot ("destination
#   ... has been modified since most recent snapshot") -- and mount-time
#   metadata churn trips that check exactly like real data would. A
#   destination tree that gets mounted even ONCE between backup runs (a host
#   rebuild that remounts everything, an operator poking around, `zfs mount
#   -a` picking it up because `canmount` reverted to whatever value the
#   incoming stream carried) can silently flip from "clean, ready for the
#   next incremental" to "diverged, needs a manual re-baseline" -- with ZERO
#   real data at risk (every child dataset reads back zero bytes written;
#   only the parent shows anything nonzero, and only from mount-time noise).
#   It reads exactly like data loss and is not one -- but every incremental
#   chain broken this way costs a manual re-sync of that one dataset before
#   replication can resume, and that cost recurs for every root a rebuild
#   remounts, not just once.
#
#   A "receive unmounted" flag on the sending side (many ZFS-replication
#   tools have an equivalent of `zfs receive -u`) only controls what happens
#   AT RECEIVE TIME. It says nothing about the next reboot, the next `zfs
#   mount -a`, or the next time anything else touches this dataset's
#   properties. THAT is why this module exists: it sets `canmount=noauto`
#   and `readonly=on` LOCALLY -- a locally-set property always wins over one
#   carried in from a received stream, which is exactly the property this
#   module leans on -- and then actively verifies and re-applies both, plus
#   an explicit unmount, on a schedule. A receive destination that can never
#   mount cannot suffer mount-time metadata churn, so the phantom-write
#   divergence above cannot occur no matter what else touches the box.
{ config, lib, pkgs, ... }:

let
  cfg = config.nixbackup.destinations;

  runtimeBin = lib.makeBinPath [
    pkgs.zfs
    pkgs.coreutils
    pkgs.gnugrep
  ];
in
{
  options.nixbackup.destinations = {
    enable = lib.mkEnableOption
      "enforce receive-destination invariants (canmount=noauto, readonly=on, unmounted) on backup destination datasets, with a boot + timer oneshot re-asserting them";

    datasets = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "tank/backups/dbs" "tank/backups/office" ];
      description = ''
        ZFS datasets that are backup RECEIVE destinations -- the target side
        of a `zfs send | zfs receive` pipeline, never a live/source dataset.
        Each one gets `canmount=noauto` and `readonly=on` set LOCALLY (see
        the module header for why "locally" is load-bearing) and is
        unmounted if currently mounted. Listed explicitly, rather than
        discovered, so this module works standalone; pair with
        `nixbackup.autobootstrap` if you also want new destination children
        discovered from ZFS user-properties as they appear.
      '';
    };

    recursive = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Also enumerate and enforce the invariant on every existing
        descendant of each dataset in `datasets` (`zfs list -r`), not just
        the named datasets themselves. A receive destination tree grows new
        child datasets over time (see `nixbackup.autobootstrap`); this keeps
        every child covered without re-listing every leaf here by hand. Turn
        off only if descendants are deliberately managed some other way.
      '';
    };

    interval = lib.mkOption {
      type = lib.types.str;
      default = "1h";
      description = ''
        How often the enforcement oneshot re-asserts the invariant
        (`OnUnitActiveSec`). It also runs once shortly after boot
        (`OnBootSec`), since a reboot or a system rebuild is exactly the
        moment these properties are most likely to have reverted -- see the
        module header.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.datasets != [ ];
        message = ''
          nixbackup.destinations.enable is true but `datasets` is empty --
          there is nothing to enforce. Either list at least one receive
          destination dataset, or disable this module.
        '';
      }
    ];

    systemd.services.nixbackup-destinations = {
      description = "Enforce backup receive-destination invariants (canmount=noauto, readonly=on, unmounted)";
      path = [ pkgs.bash ];
      serviceConfig = {
        Type = "oneshot";
      };
      script = ''
        set -uo pipefail
        export PATH=${runtimeBin}:$PATH

        fail=0

        enforce_one() {
          local ds="$1"

          # canmount: set LOCALLY so it beats anything a received stream
          # (or anything else) might otherwise leave in place. `zfs get -s
          # local` reports the CURRENT scope, not just the current value --
          # a value that is already "noauto" but scoped "received" or
          # "inherited" still needs the local `zfs set` to actually pin it.
          if [ "$(zfs get -H -o value -s local canmount "$ds" 2>/dev/null)" != "noauto" ]; then
            if zfs set canmount=noauto "$ds"; then
              echo "nixbackup-destinations: set canmount=noauto on $ds"
            else
              echo "nixbackup-destinations: FAILED to set canmount=noauto on $ds" >&2
              fail=1
            fi
          fi

          if [ "$(zfs get -H -o value -s local readonly "$ds" 2>/dev/null)" != "on" ]; then
            if zfs set readonly=on "$ds"; then
              echo "nixbackup-destinations: set readonly=on on $ds"
            else
              echo "nixbackup-destinations: FAILED to set readonly=on on $ds" >&2
              fail=1
            fi
          fi

          # canmount=noauto only prevents FUTURE auto-mounts -- a dataset
          # that is already mounted right now stays mounted until told
          # otherwise. Unmount explicitly so the invariant is "unmounted
          # right now", not just "won't mount again next time".
          if [ "$(zfs get -H -o value mounted "$ds" 2>/dev/null)" = "yes" ]; then
            if zfs unmount "$ds"; then
              echo "nixbackup-destinations: unmounted $ds"
            else
              echo "nixbackup-destinations: FAILED to unmount $ds" >&2
              fail=1
            fi
          fi
        }

        ${lib.concatMapStringsSep "\n" (ds: ''
          enforce_one ${lib.escapeShellArg ds}
          ${lib.optionalString cfg.recursive ''
            while IFS= read -r child; do
              [ -z "$child" ] && continue
              enforce_one "$child"
            done < <(zfs list -H -o name -r ${lib.escapeShellArg ds} 2>/dev/null | tail -n +2)
          ''}
        '') cfg.datasets}

        exit "$fail"
      '';
    };

    systemd.timers.nixbackup-destinations = {
      description = "Periodic backup receive-destination invariant enforcement";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = cfg.interval;
        Persistent = true;
      };
    };
  };
}
