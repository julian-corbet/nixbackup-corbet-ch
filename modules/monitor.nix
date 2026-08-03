# monitor.nix — evaluate every configured backup target from GROUND TRUTH on
# a timer, and push the verdict to a configurable push-style monitoring
# endpoint. This is the generalized form of a evaluator that grew out of a
# real incident where a nightly replication job reported success for six
# straight runs while replicating zero bytes, and a separate audit (not any
# alarm) was what actually found a pull-based backup on another host over
# three weeks dead. Both incidents are answered by the same three rules:
#
#   1. NOTHING WATCHED IT. A freshness probe that iterates a HAND-MAINTAINED
#      list of backup targets cannot see a target that was never added to
#      that list -- and a target that exists nowhere in any monitor is
#      structurally invisible. The fix is not a bigger hand-list; it's never
#      hand-listing at all where ground truth can be walked instead (see
#      the `zfs-dynamic` kind below).
#   2. THE JOB'S OWN EXIT CODE IS NOT A SIGNAL. A replication job can exit 0
#      every single run while its destination silently receives nothing.
#      So this module never asks a job how it went -- it stats the ARTIFACT
#      the job was supposed to produce. A dead job cannot suppress a stat()
#      of its own output. (`journalChecks` below is the one deliberate
#      exception: it reads a job's OWN log for known failure signatures, to
#      catch a real per-item send/receive failure that still exits the unit
#      successfully overall, and that a stat() of the destination cannot see
#      until the next scheduled run either way.)
#   3. AGE IS NOT VALIDITY. A btrfs/ZFS receive that gets truncated partway
#      through can still leave behind a directory or dataset with a fresh
#      mtime/creation time -- a name- or mtime-derived freshness check goes
#      GREEN on a truncated receive the moment its name/timestamp lands. For
#      `btrfs-received`/`btrfs-mtime` targets this module additionally
#      checks the receive-completion markers (`received_uuid` + the
#      readonly flag `btrfs receive` sets ONLY on successful completion) and
#      reports the newest COMPLETE snapshot's age, naming any newer partial
#      receives as a separate integrity finding. Age and integrity are two
#      signals; this module carries both, never collapsing one into the
#      other.
#
# WHY PUSH, NOT PROBE. Most status-dashboard tools draw one history bar per
# RESULT. Actively probing a nightly job every few minutes renders dozens of
# bars covering a couple of hours -- a chart of the prober, not of the
# backup. Pushing one result per evaluation renders one bar per evaluation
# window, so "when did this actually stop?" stays answerable at a glance.
# The push route is absence-safe only if your monitoring endpoint supports a
# per-check heartbeat/dead-man's-switch timeout independent of this module
# pushing anything -- if this timer itself dies, the check must go red on
# its own from the RECEIVING side, or this design silently reproduces the
# exact bug it exists to catch. Confirm your endpoint supports that before
# relying on push alone.
{ config, lib, pkgs, ... }:

let
  cfg = config.nixbackup.monitor;

  runtimeBin = lib.makeBinPath [
    pkgs.curl
    pkgs.coreutils # date, stat, sort, head, tail, printf
    pkgs.gnugrep
    pkgs.findutils # find (btrfs-mtime newest-child scan)
    pkgs.gnused
    pkgs.gawk
    pkgs.zfs
    pkgs.btrfs-progs
    pkgs.systemd # journalctl (journalChecks error-budget)
  ];

  weekdayEnum = lib.types.enum [ "Mon" "Tue" "Wed" "Thu" "Fri" "Sat" "Sun" ];
  weekdayIso = {
    Mon = 1; Tue = 2; Wed = 3; Thu = 4; Fri = 5; Sat = 6; Sun = 7;
  };

  cadenceType = lib.types.submodule {
    options = {
      weekdays = lib.mkOption {
        type = lib.types.listOf weekdayEnum;
        default = [ "Mon" "Tue" "Wed" "Thu" "Fri" ];
        description = "Weekdays the job is expected to run, UTC.";
      };
      atHour = lib.mkOption {
        type = lib.types.ints.between 0 23;
        example = 3;
        description = "Expected run hour, UTC, 24h clock.";
      };
      atMinute = lib.mkOption {
        type = lib.types.ints.between 0 59;
        default = 0;
        description = "Expected run minute, UTC.";
      };
      slackHours = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 2;
        description = ''
          Hours of slack past the expected run time before a missing
          artifact/log entry counts as stale. Must exceed the job's own
          typical run duration with real margin, or every run gets reported
          stale while it is still legitimately in progress.
        '';
      };
    };
  };

  # Renders a cadenceType value to the two shell-usable strings the
  # generated script needs: a space-separated list of ISO weekday numbers
  # (1=Mon..7=Sun) and "HH MM slackHours".
  cadenceIsoList = c: lib.concatMapStringsSep " " (d: toString weekdayIso.${d}) c.weekdays;
  cadenceArgs = c: "${cadenceIsoList c} ${toString c.atHour} ${toString c.atMinute} ${toString c.slackHours}";

  targetType = lib.types.submodule {
    options = {
      kind = lib.mkOption {
        type = lib.types.enum [ "btrfs-received" "btrfs-mtime" "zfs-leaves" "stampfile" "zfs-dynamic" ];
        description = ''
          How freshness is derived from ground truth:
            btrfs-received — a flat tree of received snapshot subvolumes
                             (names carry a timestamp); age of the newest
                             COMPLETE one (`received_uuid` set + readonly).
            btrfs-mtime    — a tree of named subvolumes (e.g. "@root",
                             "@home", ...), each holding numbered snapshot
                             directories with no timestamp in the name; MIN
                             over each subvolume's newest COMPLETE child,
                             by mtime. A numbered directory that lacks its
                             expected snapshot subvolume entirely (a "husk"
                             -- see the module header on age-is-not-validity)
                             is reported as its own failure, never picked as
                             the freshest.
            zfs-leaves     — per-leaf `zfs list -d 1` newest snapshot,
                             reduced by MIN across `paths`. Deliberately
                             NEVER `-r` + `tail -1`: that is a MAX, and lets
                             one fresh child keep a whole dead subtree green.
            stampfile      — a file holding a bare epoch, written only on
                             verified success by the job itself.
            zfs-dynamic    — enumerates replication plans from ZFS
                             user-properties at RUNTIME (`enabledProperty` +
                             `destinationProperty`, scanned under
                             `scanRoot`), diffs every source child against
                             its destination (missing = failure, naming the
                             child), and MIN-reduces freshness over every
                             actual LEAF dataset on the destination side --
                             not just the declared plan roots, so a stalled
                             grandchild cannot hide behind a fresh sibling
                             two levels up. `paths` is unused for this kind;
                             `maxAgeHours` is replaced by `cadence` if set,
                             else falls back to `maxAgeHours` as an ordinary
                             flat threshold.
        '';
      };

      paths = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Filesystem paths or ZFS datasets to evaluate. Reduced by MIN (worst wins). Unused for kind zfs-dynamic.";
      };

      maxAgeHours = lib.mkOption {
        type = lib.types.int;
        default = 0;
        description = ''
          Older than this many hours ⇒ push a failure. Must exceed the
          job's own cadence with real margin. For kind zfs-dynamic, only
          used as a fallback when `cadence` is not set.
        '';
      };

      excludePatterns = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = ''
          kind zfs-dynamic only: dataset name prefixes (matched exactly, or
          as "prefix/*") excluded from BOTH the structural-completeness diff
          and the freshness leaf scan, on both the source and destination
          side. Uses the same matching rule as
          `nixbackup.autobootstrap.excludePatterns`.
        '';
      };

      enabledProperty = lib.mkOption {
        type = lib.types.str;
        default = "org.nixbackup:enabled";
        description = "kind zfs-dynamic only: see `nixbackup.autobootstrap.enabledProperty` -- keep the two in sync.";
      };

      destinationProperty = lib.mkOption {
        type = lib.types.str;
        default = "org.nixbackup:destination";
        description = "kind zfs-dynamic only: see `nixbackup.autobootstrap.destinationProperty` -- keep the two in sync.";
      };

      scanRoot = lib.mkOption {
        type = lib.types.str;
        default = "";
        example = "tank";
        description = "kind zfs-dynamic only: root dataset/pool scanned recursively for plan roots. Required for this kind.";
      };

      cadence = lib.mkOption {
        type = lib.types.nullOr cadenceType;
        default = null;
        description = ''
          kind zfs-dynamic only: if set, freshness is judged against a
          cadence-aware deadline (the most recent expected weekday run, plus
          `slackHours`) instead of a flat `maxAgeHours` -- so a weekend
          evaluation still compares against the last expected weekday run
          rather than inventing a deadline on a day the job never runs.
        '';
      };
    };
  };

  journalCheckType = lib.types.submodule {
    options = {
      unit = lib.mkOption {
        type = lib.types.str;
        example = "my-backup.service";
        description = "systemd unit whose OWN journal is scanned. Its exit code is never consulted -- see the module header.";
      };

      patterns = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        example = [ "cannot send" "cannot receive" ];
        description = "grep -E alternation: any matching line in-window counts as a failure.";
      };

      since = lib.mkOption {
        type = cadenceType;
        description = "Cadence defining the scan window's start -- the journal is scanned from the most recent expected run onward.";
      };

      excludeDestinationsOf = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "zfs-dynamic-target-name";
        description = ''
          Name of a `targets.<name>` entry of kind zfs-dynamic. That
          target's `excludePatterns`, resolved to their destination-side
          paths, are filtered out of matched journal lines before they count
          as a failure here -- so a KNOWN, already-accepted exclusion cannot
          permanently redden this check on every single run.
        '';
      };
    };
  };
in
{
  options.nixbackup.monitor = {
    enable = lib.mkEnableOption
      "evaluate every configured backup target from ground truth on a timer, and push the verdict to a monitoring endpoint";

    pushUrl = lib.mkOption {
      type = lib.types.str;
      example = "https://monitor.example/push";
      description = ''
        Base URL of a push-style monitoring endpoint. Each evaluated target
        (and each `journalChecks` entry) becomes one
        `POST "$pushUrl/<key>$pushUrlSuffix?success=<true|false>&error=<url-encoded text>"`,
        where `<key>` is `<group>_<name>`. This is a deliberately minimal,
        vendor-agnostic contract -- if your monitoring stack expects a
        different shape (a different verb, a UUID-only URL with no query
        params, ...), front it with a tiny adapter that accepts this shape
        and translates. See the module header ("WHY PUSH, NOT PROBE") for
        the design this assumes on the receiving side: a per-check
        heartbeat/dead-man's-switch timeout independent of this timer.
      '';
    };

    pushUrlSuffix = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "/external";
      description = ''
        Path appended AFTER the key and BEFORE the query string, for an
        endpoint whose push path does not end at the key. Several
        status dashboards shape their push API as
        `POST <base>/<key>/external?success=...`: `pushUrl` is then the
        base (`https://status.example/api/v1/endpoints`) and this is
        `"/external"`. Empty (the default) yields the plain
        `<pushUrl>/<key>?...` shape.

        This exists because a key-must-be-last assumption is not a
        cosmetic limitation -- it makes an entire common endpoint shape
        unreachable without standing up an adapter service in front of it,
        and an adapter is one more thing between this evaluator and the
        dashboard that can die quietly.
      '';
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "backups";
      description = "Prefix for the push key: `<group>_<name>`.";
    };

    tokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/run/secrets/monitor-push-token";
      description = ''
        Path to a file holding a bearer token for the push endpoint, unsealed
        by whatever secrets mechanism this host uses. If null, pushes carry
        no Authorization header. If set but unreadable at runtime, the run
        logs a warning and skips pushing for that evaluation rather than
        failing the service.
      '';
    };

    interval = lib.mkOption {
      type = lib.types.str;
      default = "6h";
      description = ''
        Evaluation cadence, DELIBERATELY decoupled from any single target's
        backup cadence -- pushing once per backup cycle forces a very long
        heartbeat timeout on the receiving side (slow detection, and a
        receiver restart resets its own ticker). Evaluating every few hours
        keeps a heartbeat window comfortably inside typical monitoring-stack
        uptime while still yielding a readable per-run history.
      '';
    };

    targets = lib.mkOption {
      type = lib.types.attrsOf targetType;
      default = { };
      description = "Backup targets to evaluate. Each attribute name becomes one push key / one row at the monitoring endpoint.";
    };

    journalChecks = lib.mkOption {
      type = lib.types.attrsOf journalCheckType;
      default = { };
      description = ''
        Error-budget checks: scan a systemd unit's OWN journal for known
        failure signatures since its last expected run, independent of that
        unit's exit code. See the module header ("THE JOB'S OWN EXIT CODE
        IS NOT A SIGNAL") for why this exists as checks separate from every
        artifact-freshness target above.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.targets != { } || cfg.journalChecks != { };
        message = "nixbackup.monitor.enable is true but both `targets` and `journalChecks` are empty -- there is nothing to evaluate.";
      }
    ] ++ (lib.mapAttrsToList
      (name: t: {
        assertion = t.kind != "zfs-dynamic" || t.scanRoot != "";
        message = "nixbackup.monitor.targets.${name}: kind = \"zfs-dynamic\" requires `scanRoot` to be set.";
      })
      cfg.targets)
    ++ (lib.mapAttrsToList
      (name: jc: {
        assertion = jc.excludeDestinationsOf == null || cfg.targets ? ${jc.excludeDestinationsOf};
        message = "nixbackup.monitor.journalChecks.${name}.excludeDestinationsOf refers to \"${toString jc.excludeDestinationsOf}\", which is not a name in `targets` -- check for a typo.";
      })
      cfg.journalChecks);

    systemd.services.nixbackup-monitor = {
      description = "Evaluate backup freshness/integrity from ground truth, publish to a monitoring endpoint";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      path = [ pkgs.bash ];
      serviceConfig = {
        Type = "oneshot";
        TimeoutStartSec = "10min";
      };
      script = ''
        set -uo pipefail
        export PATH=${runtimeBin}:$PATH

        PUSHURL=${lib.escapeShellArg cfg.pushUrl}
        PUSHSUFFIX=${lib.escapeShellArg cfg.pushUrlSuffix}
        GROUP=${lib.escapeShellArg cfg.group}
        ${lib.optionalString (cfg.tokenFile != null) "TOKENFILE=${lib.escapeShellArg cfg.tokenFile}"}

        now=$(date +%s)

        # URL-encode for the ?error= query param.
        urlenc() { sed -e 's/%/%25/g' -e 's/ /%20/g' -e 's/&/%26/g' -e 's/#/%23/g' -e 's/+/%2B/g'; }

        # push <name> <ok:true|false> <error-text>
        push() {
          local name="$1" ok="$2" err="$3" key token=""
          key="''${GROUP}_''${name}"
          ${lib.optionalString (cfg.tokenFile != null) ''
            if [ ! -r "$TOKENFILE" ]; then
              echo "nixbackup-monitor: WARN token $TOKENFILE not readable -- skipping push for $name" >&2
              return 0
            fi
            token=$(tr -d '[:space:]' < "$TOKENFILE")
          ''}
          # -g/--globoff: error text can be arbitrary and may contain "[" / "]"
          # (e.g. a raw journalctl line), which curl's default URL-globbing
          # otherwise refuses to parse ("bad range in position N") before any
          # request is even sent -- percent-encoding alone does not cover it.
          if curl -sf -g -m 15 -o /dev/null -X POST \
               ''${token:+-H "Authorization: Bearer $token"} \
               "$PUSHURL/$key$PUSHSUFFIX?success=$ok&error=$(printf '%s' "$err" | urlenc)"; then
            echo "nixbackup-monitor: $name success=$ok ''${err:+($err)}"
          else
            echo "nixbackup-monitor: WARN push failed for $name (endpoint unreachable?)" >&2
          fi
        }

        # Epoch of a "%Y%m%dT%H%M%SZ"-style name (e.g. btrfs-received subvolumes).
        name_epoch() {
          local n="$1"
          date -u -d "''${n:0:4}-''${n:4:2}-''${n:6:2}T''${n:9:2}:''${n:11:2}:''${n:13:2}Z" +%s 2>/dev/null
        }

        # day_at <epoch> <HH> <MM> -> epoch of that UTC calendar date at HH:MM.
        day_at() {
          date -u -d "$(date -u -d "@$1" +%Y-%m-%d) $2:$3:00" +%s
        }

        # expected_run_epoch <"iso-dow iso-dow ..."> <HH> <MM> -> epoch of the
        # most recent expected run at-or-before $now, for a cadence whose
        # weekdays are given as space-separated ISO numbers (1=Mon..7=Sun).
        expected_run_epoch() {
          local dows="$1" hh="$2" mm="$3" cand dow d dow2
          cand=$(day_at "$now" "$hh" "$mm")
          dow=$(date -u -d "@$now" +%u)
          if [ "$now" -ge "$cand" ] && printf ' %s ' "$dows" | grep -q " $dow "; then
            echo "$cand"; return
          fi
          d=$now
          while :; do
            d=$(( d - 86400 ))
            dow2=$(date -u -d "@$d" +%u)
            if printf ' %s ' "$dows" | grep -q " $dow2 "; then
              day_at "$d" "$hh" "$mm"; return
            fi
          done
        }

        ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: t: ''
          # ── ${name} (${t.kind}) ──────────────────────────────────────────
          (
            oldest=""; detail=""; fail=""
            ${lib.optionalString (t.kind == "btrfs-received") ''
              for p in ${lib.escapeShellArgs t.paths}; do
                if [ ! -d "$p" ]; then fail="$fail $p(missing)"; continue; fi
                good=""; partial=0
                # Newest-first: the first COMPLETE subvolume is the last real
                # backup. Anything newer than it is a truncated receive, and
                # is counted, never trusted.
                for s in $(ls -1 "$p" 2>/dev/null | grep -E '^[0-9]{8}T[0-9]{6}Z$' | sort -r); do
                  info=$(btrfs subvolume show "$p/$s" 2>/dev/null) || { partial=$((partial + 1)); continue; }
                  ruuid=$(printf '%s' "$info" | sed -n 's/^[[:space:]]*Received UUID:[[:space:]]*//p')
                  flags=$(printf '%s' "$info" | sed -n 's/^[[:space:]]*Flags:[[:space:]]*//p')
                  if [ -n "$ruuid" ] && [ "$ruuid" != "-" ] && printf '%s' "$flags" | grep -q readonly; then
                    good="$s"; break
                  fi
                  partial=$((partial + 1))
                done
                if [ -z "$good" ]; then fail="$fail $(basename "$p")(no-complete-snapshot)"; continue; fi
                e=$(name_epoch "$good") || { fail="$fail $(basename "$p")(unparsable)"; continue; }
                if [ -z "$oldest" ] || [ "$e" -lt "$oldest" ]; then oldest="$e"; fi
                if [ "$partial" -gt 0 ]; then detail="$detail $partial-partial-receive(s)-newer-than-$good"; fi
              done
            ''}
            ${lib.optionalString (t.kind == "btrfs-mtime") ''
              for p in ${lib.escapeShellArgs t.paths}; do
                if [ ! -d "$p" ]; then fail="$fail $p(missing)"; continue; fi
                # Each top-level subvolume must itself be fresh -- MIN, so
                # one stalled subvolume reddens the row instead of hiding
                # behind fresher siblings.
                for sub in "$p"/*; do
                  [ -d "$sub" ] || continue
                  any_child=0
                  valid_e=""; valid_dir=""
                  # HUSK DETECTION: a numbered snapshot directory can exist
                  # with no `snapshot` subvolume ever having landed inside it
                  # -- the sending tool allocates/creates the directory up
                  # front and the transfer aborts before the subvolume itself
                  # arrives. Picking "newest child directory BY MTIME"
                  # unconditionally, and only checking receive-completeness
                  # IF that pick happens to have a snapshot subvolume, makes
                  # a husk newer than the last real snapshot invisible: there
                  # is no snapshot to inspect, so nothing is ever flagged,
                  # and the husk's own (fresh) directory mtime gets reported
                  # as this row's age while the real backups underneath it
                  # have gone silently stale. Instead: ANY directory lacking
                  # a `snapshot` subvolume is a FAILURE in its own right (age
                  # is irrelevant -- a husk never counts as fresh), and
                  # freshness is derived ONLY from the newest child that
                  # actually has one.
                  while IFS= read -r line; do
                    [ -z "$line" ] && continue
                    any_child=1
                    ce=''${line%% *}; ce=''${ce%.*}
                    cdir=''${line#* }
                    if [ -d "$cdir/snapshot" ]; then
                      if [ -z "$valid_e" ] || [ "$ce" -gt "$valid_e" ]; then valid_e="$ce"; valid_dir="$cdir"; fi
                    else
                      fail="$fail $(basename "$sub")/$(basename "$cdir")(husk)"
                    fi
                  done < <(find "$sub" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' 2>/dev/null | sort -n)

                  if [ "$any_child" -eq 0 ]; then fail="$fail $(basename "$sub")(empty)"; continue; fi
                  [ -z "$valid_dir" ] && continue  # every child was a husk; already recorded above

                  if [ -z "$oldest" ] || [ "$valid_e" -lt "$oldest" ]; then oldest="$valid_e"; fi
                  # Age is not validity here either: the received subvolume
                  # itself can still be a truncated receive even though its
                  # directory exists and looks complete.
                  info=$(btrfs subvolume show "$valid_dir/snapshot" 2>/dev/null)
                  ruuid=$(printf '%s' "$info" | sed -n 's/^[[:space:]]*Received UUID:[[:space:]]*//p')
                  flags=$(printf '%s' "$info" | sed -n 's/^[[:space:]]*Flags:[[:space:]]*//p')
                  if [ -z "$ruuid" ] || [ "$ruuid" = "-" ] || ! printf '%s' "$flags" | grep -q readonly; then
                    detail="$detail $(basename "$sub")/$(basename "$valid_dir")-incomplete-receive"
                  fi
                done
              done
            ''}
            ${lib.optionalString (t.kind == "zfs-leaves") ''
              for ds in ${lib.escapeShellArgs t.paths}; do
                # This kind's MIN-across-`paths` reduction is only correct if
                # every path IS a true leaf: `-d 1` reads one level of child
                # datasets, so a mis-passed non-leaf path can leave a stale
                # grandchild past that depth invisible and silently green.
                # Fail loudly instead of guessing.
                nchild=$(zfs list -H -o name -d 1 -t filesystem,volume "$ds" 2>/dev/null | wc -l)
                if [ "$nchild" -gt 1 ]; then
                  fail="$fail $(basename "$ds")(not-a-leaf:has-child-datasets)"
                  continue
                fi
                # -d 1, per leaf, MIN across leaves. `-r ... | tail -1` would
                # be a subtree MAX and can hide a dead branch behind a fresh
                # sibling.
                e=$(zfs list -t snapshot -H -o creation -p -d 1 "$ds" 2>/dev/null | sort -n | tail -1)
                if [ -z "$e" ]; then fail="$fail $(basename "$ds")(none)"; continue; fi
                if [ -z "$oldest" ] || [ "$e" -lt "$oldest" ]; then oldest="$e"; fi
              done
            ''}
            ${lib.optionalString (t.kind == "stampfile") ''
              for f in ${lib.escapeShellArgs t.paths}; do
                if [ ! -r "$f" ]; then fail="$fail $(basename "$f")(missing)"; continue; fi
                e=$(tr -dc '0-9' < "$f")
                if [ -z "$e" ]; then fail="$fail $(basename "$f")(empty)"; continue; fi
                if [ -z "$oldest" ] || [ "$e" -lt "$oldest" ]; then oldest="$e"; fi
              done
            ''}
            ${lib.optionalString (t.kind == "zfs-dynamic") ''
              EXCLUDES=(${lib.escapeShellArgs t.excludePatterns})
              is_excluded() {
                local ds="$1" pat
                for pat in "''${EXCLUDES[@]:-}"; do
                  [ -z "$pat" ] && continue
                  case "$ds" in "$pat"|"$pat"/*) return 0 ;; esac
                done
                return 1
              }

              # Ground truth, never a hand-list: every plan root actually
              # declared via the enabled-property, discovered fresh on every
              # single evaluation.
              mapfile -t ZP_ROOTS < <(zfs get -s local -Ho name,value ${lib.escapeShellArg t.enabledProperty} -r ${lib.escapeShellArg t.scanRoot} 2>/dev/null | awk '$2=="on"{print $1}')
              if [ "''${#ZP_ROOTS[@]}" -eq 0 ]; then
                fail="$fail no-plans-found-via-${t.enabledProperty}"
              fi

              for zroot in "''${ZP_ROOTS[@]:-}"; do
                [ -z "$zroot" ] && continue
                is_excluded "$zroot" && continue
                zdst=$(zfs get -Ho value ${lib.escapeShellArg t.destinationProperty} "$zroot" 2>/dev/null)
                if [ -z "$zdst" ] || [ "$zdst" = "-" ]; then
                  fail="$fail $zroot(no-destination-property)"
                  continue
                fi

                # ── structural completeness: every source child must exist at dest ──
                while IFS= read -r src_ds; do
                  [ -z "$src_ds" ] && continue
                  is_excluded "$src_ds" && continue
                  zrel="''${src_ds#"$zroot"}"
                  zdst_ds="$zdst$zrel"
                  zfs list -H -o name "$zdst_ds" >/dev/null 2>&1 || fail="$fail $zdst_ds(missing-on-dest)"
                done < <(zfs list -H -o name -r "$zroot" 2>/dev/null | tail -n +2)

                # ── freshness: MIN over every LEAF actually present at dest
                # (not just the named roots -- a stalled grandchild must not
                # hide behind a fresh sibling) ──
                mapfile -t ZDST_ALL < <(zfs list -H -o name -r "$zdst" 2>/dev/null)
                for zds in "''${ZDST_ALL[@]:-}"; do
                  [ -z "$zds" ] && continue
                  is_excluded "$zds" && continue
                  is_leaf=1
                  for zother in "''${ZDST_ALL[@]:-}"; do
                    [ "$zother" = "$zds" ] && continue
                    case "$zother" in "$zds"/*) is_leaf=0; break ;; esac
                  done
                  [ "$is_leaf" -eq 1 ] || continue
                  e=$(zfs list -t snapshot -H -o creation -p -d 1 "$zds" 2>/dev/null | sort -n | tail -1)
                  if [ -z "$e" ]; then fail="$fail $zds(no-snapshot)"; continue; fi
                  if [ -z "$oldest" ] || [ "$e" -lt "$oldest" ]; then oldest="$e"; fi
                done
              done

              ${lib.optionalString (t.cadence != null) ''
                zdyn_expected=$(expected_run_epoch ${cadenceArgs t.cadence})
                zdyn_deadline=$(( zdyn_expected + ${toString t.cadence.slackHours} * 3600 ))
              ''}
            ''}

            if [ -n "$fail" ]; then
              push ${lib.escapeShellArg name} false "unavailable:$fail"
            elif [ -z "$oldest" ]; then
              push ${lib.escapeShellArg name} false "no backup artifact found"
            else
              agehrs=$(( (now - oldest) / 3600 ))
              ${if (t.kind == "zfs-dynamic" && t.cadence != null) then ''
                if [ "$now" -ge "$zdyn_deadline" ] && [ "$oldest" -lt "$zdyn_expected" ]; then
                  push ${lib.escapeShellArg name} false "stale: ''${agehrs}h old, no snapshot since the expected $(date -u -d @"$zdyn_expected" '+%a %H:%M') UTC run (deadline $(date -u -d @"$zdyn_deadline" '+%H:%M') UTC passed)$detail"
                elif [ -n "$detail" ]; then
                  push ${lib.escapeShellArg name} false "integrity: ''${agehrs}h old but$detail"
                else
                  push ${lib.escapeShellArg name} true ""
                fi
              '' else ''
                if [ "$agehrs" -gt ${toString t.maxAgeHours} ]; then
                  push ${lib.escapeShellArg name} false "stale: ''${agehrs}h old (limit ${toString t.maxAgeHours}h)$detail"
                elif [ -n "$detail" ]; then
                  # Fresh enough, but the tree carries a truncated receive --
                  # that is a failure of integrity even when age passes.
                  # Never reported as healthy.
                  push ${lib.escapeShellArg name} false "integrity: ''${agehrs}h old but$detail"
                else
                  push ${lib.escapeShellArg name} true ""
                fi
              ''}
            fi
          )
        '') cfg.targets)}

        ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: jc: ''
          # ── journalCheck: ${name} (unit: ${jc.unit}) ──────────────────────
          (
            jc_excl=()
            ${lib.optionalString (jc.excludeDestinationsOf != null) ''
              mapfile -t jc_roots < <(zfs get -s local -Ho name,value ${lib.escapeShellArg (cfg.targets.${jc.excludeDestinationsOf}.enabledProperty)} -r ${lib.escapeShellArg (cfg.targets.${jc.excludeDestinationsOf}.scanRoot)} 2>/dev/null | awk '$2=="on"{print $1}')
              for jc_pat in ${lib.escapeShellArgs (cfg.targets.${jc.excludeDestinationsOf}.excludePatterns or [ ])}; do
                for jc_root in "''${jc_roots[@]:-}"; do
                  [ -z "$jc_root" ] && continue
                  case "$jc_pat" in
                    "$jc_root"|"$jc_root"/*)
                      jc_dst=$(zfs get -Ho value ${lib.escapeShellArg (cfg.targets.${jc.excludeDestinationsOf}.destinationProperty)} "$jc_root" 2>/dev/null)
                      if [ -n "$jc_dst" ] && [ "$jc_dst" != "-" ]; then
                        jc_excl+=("$jc_dst''${jc_pat#"$jc_root"}")
                      fi
                      break
                      ;;
                  esac
                done
              done
            ''}
            jc_filter() {
              if [ "''${#jc_excl[@]}" -eq 0 ]; then
                cat
              else
                local pat
                pat=$(printf '%s\n' "''${jc_excl[@]}")
                grep -vF "$pat"
              fi
            }

            # ONE grep, no `-m`/`| head`: an early-terminating downstream
            # consumer of a pipe can SIGPIPE a still-writing producer the
            # instant it closes its read end after enough matches, on a run
            # with many matching lines. Plain `grep` always reads to EOF and
            # never cuts a producer off, so every match is captured ONCE and
            # "the first line" is taken via pure bash string manipulation --
            # no subprocess, no pipe, no signal.
            jc_since=$(expected_run_epoch ${cadenceArgs jc.since})
            jc_matches=$(journalctl -u ${lib.escapeShellArg jc.unit} --since "@$jc_since" --no-pager 2>/dev/null \
              | jc_filter \
              | grep -E ${lib.escapeShellArg (lib.concatStringsSep "|" jc.patterns)} || true)
            if [ -n "$jc_matches" ]; then
              jc_detail="''${jc_matches%%$'\n'*}"
              push ${lib.escapeShellArg name} false "$jc_detail"
            else
              push ${lib.escapeShellArg name} true ""
            fi
          )
        '') cfg.journalChecks)}

        exit 0
      '';
    };

    systemd.timers.nixbackup-monitor = {
      description = "Periodic backup freshness/integrity evaluation → monitoring endpoint";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "10min";
        OnUnitActiveSec = cfg.interval;
        RandomizedDelaySec = "5min";
        Persistent = true;
      };
    };
  };
}
