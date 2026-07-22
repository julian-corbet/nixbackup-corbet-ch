# autobootstrap.nix — close the "broken autoCreation" hole shared by most
# ZFS-replication tools: none of the common ones reliably create a
# destination dataset for a source child that did not exist the last time
# the tool ran. A newly added child dataset under an already-replicated tree
# (a new container's data volume, a new database, a new PVC -- anything
# under a plan root that already replicates fine) silently gets no
# destination at all. The tool logs "destination does not exist, will be
# rechecked every run" (or an equivalent) forever; no amount of waiting on
# its own fixes it, and its own "autoCreation"-style flag, however named,
# turns out on inspection to never actually attempt the create.
#
# This module is the fix, not just an alarm for the gap. On a timer, it:
#
#   1. Enumerates the CURRENT set of replication plans at RUNTIME, directly
#      from ZFS user-properties stamped on the SOURCE pool -- never a
#      hand-maintained or hardcoded list. A plan absent from a hand-list is
#      structurally invisible to any tooling built around that list; reading
#      the properties instead means a newly declared plan is picked up on
#      the very next timer tick with no code change here. (`nixbackup.monitor`
#      documents the same "ground truth, not a hand-list" principle for the
#      freshness side of this same problem.)
#   2. Diffs every source child against its expected destination.
#   3. For each MISSING destination, runs exactly one
#      `zfs send -w | zfs receive -u` from the source's newest snapshot to
#      seed it. `-w` (raw) is used uniformly whether or not the source
#      happens to be ZFS-native encrypted: for an unencrypted source it is
#      send-flag-equivalent to a plain compressed send, and for an encrypted
#      source it keeps the stream as ciphertext end-to-end -- one flag,
#      correct either way, so this module needs no per-dataset encryption
#      awareness of its own.
#
# Processed shallowest-missing-path first: a child whose own parent is ALSO
# missing needs that parent seeded first (`zfs receive` without `-p` refuses
# to create missing parent datasets), so within one run a parent's receive
# always lands before its child's is attempted.
#
# Once a destination has any snapshot in common with its source, your
# replication tool's own incremental path takes over from there -- this
# module never touches that child again. Every dataset it creates is
# immediately set to `canmount=noauto` and `readonly=on` LOCALLY, matching
# the invariant `nixbackup.destinations` enforces on an ongoing basis -- a
# destination this module creates is compliant with that invariant from the
# moment it exists, whether or not `nixbackup.destinations` is also enabled
# to keep re-asserting it later.
{ config, lib, pkgs, ... }:

let
  cfg = config.nixbackup.autobootstrap;

  runtimeBin = lib.makeBinPath [
    pkgs.zfs
    pkgs.coreutils
    pkgs.gnugrep
    pkgs.gawk
  ];
in
{
  options.nixbackup.autobootstrap = {
    enable = lib.mkEnableOption
      "bootstrap missing replication-destination datasets, discovered at runtime from ZFS user-properties, via one zfs send -w | zfs receive -u per missing child";

    sourcePool = lib.mkOption {
      type = lib.types.str;
      example = "tank";
      description = ''
        Root dataset (typically a whole pool, e.g. "tank") scanned
        recursively (`zfs get -r`) for `enabledProperty`. Every dataset
        found with that property set to "on" (with LOCAL scope) is treated
        as a replication plan root and becomes a bootstrap candidate.
      '';
    };

    enabledProperty = lib.mkOption {
      type = lib.types.str;
      default = "org.nixbackup:enabled";
      description = ''
        ZFS user-property that marks a dataset as a replication plan ROOT
        when its value is "on", set with LOCAL scope (`zfs get -s local`).
        Plans are discovered from this property at RUNTIME -- never a static
        list -- so a newly declared plan needs no change to this module.
        Whatever configures your replication tool's plans is expected to
        stamp this property (and `destinationProperty` below) on each plan
        root; this module only reads them.
      '';
    };

    destinationProperty = lib.mkOption {
      type = lib.types.str;
      default = "org.nixbackup:destination";
      description = ''
        ZFS user-property, set on the same plan-root dataset, whose value is
        the destination dataset that source tree replicates to.
      '';
    };

    excludePatterns = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "tank/backups/scratch" ];
      description = ''
        Dataset name prefixes (matched exactly, or as "prefix/*") skipped on
        both the source and destination side -- e.g. a subtree with no
        independent data of its own (a passthrough mount, a regenerable
        cache). Uses the same matching rule as `nixbackup.monitor`'s target
        `excludePatterns`; keep the two lists in sync for any plan covered
        by both modules.
      '';
    };

    interval = lib.mkOption {
      type = lib.types.str;
      default = "1d";
      description = "How often to scan for and bootstrap missing destination children (`OnUnitActiveSec`).";
    };

    timeoutSec = lib.mkOption {
      type = lib.types.str;
      default = "2h";
      description = ''
        `TimeoutStartSec` for the bootstrap service. A first-time seed of a
        large dataset is a full send, not an incremental -- generous enough
        that it cannot be killed mid-transfer on a run that bootstraps
        several large children at once.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.sourcePool != "";
        message = "nixbackup.autobootstrap.enable requires `sourcePool` to be set.";
      }
    ];

    systemd.services.nixbackup-autobootstrap = {
      description = "Bootstrap missing replication-destination datasets (autoCreation workaround)";
      path = [ pkgs.bash ];
      serviceConfig = {
        Type = "oneshot";
        TimeoutStartSec = cfg.timeoutSec;
      };
      script = ''
        set -uo pipefail
        export PATH=${runtimeBin}:$PATH

        EXCLUDES=(${lib.escapeShellArgs cfg.excludePatterns})
        is_excluded() {
          local ds="$1" pat
          for pat in "''${EXCLUDES[@]:-}"; do
            [ -z "$pat" ] && continue
            case "$ds" in "$pat"|"$pat"/*) return 0 ;; esac
          done
          return 1
        }

        mapfile -t ROOTS < <(zfs get -s local -Ho name,value ${lib.escapeShellArg cfg.enabledProperty} -r ${lib.escapeShellArg cfg.sourcePool} 2>/dev/null | awk '$2=="on"{print $1}')

        if [ "''${#ROOTS[@]}" -eq 0 ]; then
          echo "nixbackup-autobootstrap: no plan roots found via ${cfg.enabledProperty}=on under ${cfg.sourcePool} -- nothing to do"
          exit 0
        fi

        # Collect every missing (source, destination) pair across all plans
        # FIRST, then sort shallowest path first -- so a parent lands before
        # a child that depends on it already existing.
        missing=()
        for root in "''${ROOTS[@]:-}"; do
          [ -z "$root" ] && continue
          is_excluded "$root" && continue

          dst=$(zfs get -Ho value ${lib.escapeShellArg cfg.destinationProperty} "$root" 2>/dev/null)
          if [ -z "$dst" ] || [ "$dst" = "-" ]; then
            echo "nixbackup-autobootstrap: WARN $root has no ${cfg.destinationProperty} property -- skipped" >&2
            continue
          fi

          # The plan root itself may be missing at the destination too, not
          # just a child under it.
          zfs list -H -o name "$dst" >/dev/null 2>&1 || missing+=("$root:$dst")

          while IFS= read -r src_ds; do
            [ -z "$src_ds" ] && continue
            is_excluded "$src_ds" && continue
            rel="''${src_ds#"$root"}"
            dst_ds="$dst$rel"
            zfs list -H -o name "$dst_ds" >/dev/null 2>&1 && continue
            missing+=("$src_ds:$dst_ds")
          done < <(zfs list -H -o name -r "$root" 2>/dev/null | tail -n +2)
        done

        if [ "''${#missing[@]}" -gt 0 ]; then
          mapfile -t missing < <(printf '%s\n' "''${missing[@]}" | awk -F/ '{print NF, $0}' | sort -n | cut -d' ' -f2-)
        fi

        bootstrapped=0
        failed=0
        for pair in "''${missing[@]:-}"; do
          [ -z "$pair" ] && continue
          src_ds="''${pair%%:*}"
          dst_ds="''${pair#*:}"

          snap=$(zfs list -t snapshot -H -o name,creation -p -d 1 "$src_ds" 2>/dev/null | sort -k2 -n | tail -1 | cut -f1)
          if [ -z "$snap" ]; then
            echo "nixbackup-autobootstrap: ERROR $src_ds has no snapshot to seed $dst_ds from -- skipped" >&2
            failed=$((failed + 1))
            continue
          fi

          echo "nixbackup-autobootstrap: bootstrapping $dst_ds from $snap"
          if zfs send -w "$snap" | zfs receive -u "$dst_ds"; then
            zfs set canmount=noauto "$dst_ds"
            zfs set readonly=on "$dst_ds"
            echo "nixbackup-autobootstrap: OK $dst_ds seeded from $snap, canmount=noauto + readonly=on set"
            bootstrapped=$((bootstrapped + 1))
          else
            echo "nixbackup-autobootstrap: FAILED to seed $dst_ds from $snap" >&2
            failed=$((failed + 1))
          fi
        done

        echo "nixbackup-autobootstrap: $bootstrapped bootstrapped, $failed failed this run"
        [ "$failed" -eq 0 ]
      '';
    };

    systemd.timers.nixbackup-autobootstrap = {
      description = "Periodic replication-destination auto-bootstrap (autoCreation workaround)";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "15min";
        OnUnitActiveSec = cfg.interval;
        Persistent = true;
        RandomizedDelaySec = "5min";
      };
    };
  };
}
