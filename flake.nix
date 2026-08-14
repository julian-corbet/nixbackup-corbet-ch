{
  description = "nixbackup - ZFS backup-destination discipline as enforced, tested NixOS modules";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      lib = nixpkgs.lib;
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: lib.genAttrs systems f;
    in
    {
      # Six NixOS modules, plus a seventh system-manager-only one, each
      # independently toggleable, sharing one namespace (`nixbackup.*`). The
      # first three share one convention (ZFS user-properties as the runtime
      # source of truth, never a hand-maintained list); the next three are
      # the BTRFS replication pair-of-shapes (push and pull) plus the
      # local-snapshot source the pull side depends on; the seventh
      # (systemManagerModules.snapperBackup) covers the same push shape as
      # btrbkPush for a non-NixOS host with no equivalent native module. See
      # README.md for the pitch and per-module usage.
      nixosModules = {
        # nixbackup.destinations: enforce canmount=noauto + readonly=on
        # (both LOCAL) + unmounted on every backup receive-destination
        # dataset, with a boot + timer oneshot that re-asserts them.
        destinations = ./modules/destinations.nix;

        # nixbackup.autobootstrap: discover replication plans at runtime
        # from ZFS user-properties and seed any destination child that does
        # not exist yet (`zfs send -w | zfs receive -u`), closing the
        # broken-autoCreation hole most ZFS-replication tools share.
        autobootstrap = ./modules/autobootstrap.nix;

        # nixbackup.monitor: evaluate every configured backup target from
        # ground truth (never a job's own exit code) and push the verdict to
        # a configurable push-style monitoring endpoint.
        monitor = ./modules/monitor.nix;

        # nixbackup.btrbkPush: a declarative front end over the upstream
        # `services.btrbk`, for a host allowed to hold credentials reaching
        # OUTWARD toward a backup receiver. See the module's own header for
        # why this is not "nixbackup running a competing daemon".
        btrbkPush = ./modules/btrbk-push.nix;

        # nixbackup.localSnapshots: the SOURCE half of the pull-based
        # alternative to btrbkPush -- local, retained, read-only btrfs
        # snapshots a remote puller (btrbkPull, below) reaches in and picks
        # up over its OWN SSH connection.
        localSnapshots = ./modules/local-snapshots.nix;

        # nixbackup.btrbkPull: the RECEIVER half of the pull-based pair --
        # this host reaches OUT to a remote node's own localSnapshots and
        # receives the delta home. A remote holding zero inbound-writing
        # credentials, the opposite trust shape from btrbkPush.
        btrbkPull = ./modules/btrbk-pull.nix;
      };

      # A seventh module, system-manager only (see its own header for why no
      # nixosModules export -- nixpkgs' own services.snapper is the better
      # fit for a real NixOS host). Otherwise the same push shape as
      # btrbkPush, for a non-NixOS host (Arch/CachyOS today) whose only
      # snapshot-replication tool is the `snapper` package's bundled `snbk`.
      systemManagerModules = {
        snapperBackup = ./modules/snapper-backup.nix;
      };

      lib = { };

      # The word "tested" in the description above is earned here. Two of these
      # do more than evaluate: they assert the specific behaviours whose absence
      # would be invisible in review and silent in production.
      checks = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};

          # All modules composed into one system, from examples/host.
          # snapper-backup.nix is included directly (not via self.nixosModules
          # -- it's system-manager-only in the public API) purely so it gets
          # the same eval coverage as everything else; see its own header's
          # "TESTING NOTE" for why lib.nixosSystem can evaluate it at all.
          host = lib.nixosSystem {
            inherit system;
            modules = lib.attrValues self.nixosModules
              ++ [ ./modules/snapper-backup.nix ./examples/host/configuration.nix ];
          };

          units = host.config.systemd.services;

          bareStubs = {
            boot.loader.grub.enable = false;
            fileSystems."/" = { device = "none"; fsType = "tmpfs"; };
            system.stateVersion = "25.05";
          };

          # A required option (no default -- `remoteHost`, `source`,
          # `snapshotDir`, ...) with nothing supplied is a MISSING-VALUE
          # error, not a `config.assertions` failure, and (like a type
          # constraint) is only forced deep enough to surface by reaching
          # `.drvPath`, not by a bare `seq` of the `system.build.toplevel`
          # attrset -- see the option's own consumer (the `script`
          # attribute the missing value would have to render into).
          buildFailsWith = modulePath: extraConfig:
            !(builtins.tryEval (
              builtins.seq
                (builtins.unsafeDiscardStringContext
                  (lib.nixosSystem {
                    inherit system;
                    modules = [ modulePath extraConfig bareStubs ];
                  }).config.system.build.toplevel.drvPath)
                true
            )).success;

          # A check over generated shell: hand the script to a derivation and
          # assert against it. Each assertion carries the reason it exists, so a
          # failure tells you what breaks rather than only what changed.
          assertScript = name: script: assertions:
            pkgs.runCommand "nixbackup-check-${name}"
              {
                inherit script;
                passAsFile = [ "script" ];
              }
              ''
                cp "$scriptPath" ./script.sh
                fail=0
                ${lib.concatMapStringsSep "\n" (a: ''
                  if ${a.test}; then
                    echo "ok   — ${a.name}"
                  else
                    echo "FAIL — ${a.name}" >&2
                    echo "       ${a.why}" >&2
                    fail=1
                  fi
                '') assertions}
                [ "$fail" -eq 0 ] || exit 1
                echo "all assertions held" > $out
              '';
        in
        {
          # 1. Does everything still evaluate? Catches type errors, failed
          #    assertions and option renames across all three modules at once.
          #
          #    The string context around the derivation path MUST be discarded. A
          #    store path inside a string is tracked as a build dependency, so
          #    keeping it makes this BUILD an entire NixOS system rather than
          #    evaluate one — minutes and a multi-gigabyte download versus
          #    seconds.
          modules-evaluate =
            pkgs.writeText "nixbackup-host-drvpath"
              (builtins.unsafeDiscardStringContext host.config.system.build.toplevel.drvPath);

          # 2. The finding in studies/phantom-write-footgun.md, made executable.
          #    Mounting a receive destination causes a few bytes of mount-time
          #    metadata churn, which `zfs receive` cannot distinguish from real
          #    writes — so it refuses the next incremental. Both properties must be
          #    set LOCALLY, because a local property beats one carried in by a
          #    received stream; dropping `-s local` would look identical in review
          #    and quietly stop working.
          destinations-enforce-invariants =
            assertScript "destinations" units.nixbackup-destinations.script [
              {
                name = "pins canmount=noauto";
                test = ''grep -q "zfs set canmount=noauto" ./script.sh'';
                why = "without it a received dataset auto-mounts on the next import";
              }
              {
                name = "pins readonly=on";
                test = ''grep -q "zfs set readonly=on" ./script.sh'';
                why = "a writable destination invites the write that breaks replication";
              }
              {
                name = "compares against the LOCAL property source";
                test = ''[ "$(grep -c -- "-s local" ./script.sh)" -ge 2 ]'';
                why = "an inherited value satisfies a naive check while losing to a received stream";
              }
              {
                name = "unmounts a destination that is already mounted";
                test = ''grep -qE "zfs unmount|umount" ./script.sh'';
                why = "canmount=noauto only prevents FUTURE mounts; an already-mounted dataset stays mounted";
              }
            ];

          # 3. Freshness must MIN-reduce across datasets. The module's own header
          #    calls this out: a recursive snapshot listing reduced with `tail -1`
          #    is a MAX, and one fresh child then keeps an entire dead subtree
          #    green. That failure is invisible — the dashboard reads healthy — so
          #    it is exactly the regression worth pinning in CI.
          monitor-min-reduces-freshness =
            assertScript "monitor" units.nixbackup-monitor.script [
              {
                # The `-ge 1` half is not redundant. Comparing two counts alone
                # passes when both are zero, so a rewrite that renamed the listing
                # entirely would satisfy the equality and prove nothing.
                name = "every snapshot listing is depth-limited (and there is at least one)";
                test = ''
                  total=$(grep -c "zfs list -t snapshot" ./script.sh)
                  scoped=$(grep "zfs list -t snapshot" ./script.sh | grep -c -- "-d 1")
                  [ "$total" -ge 1 ] && [ "$total" = "$scoped" ]'';
                why = "a recursive listing turns per-dataset freshness into a pool-wide MAX";
              }
              {
                name = "reduces across datasets by taking the OLDEST";
                test = ''grep -q -- '-lt "$oldest"' ./script.sh'';
                why = "reducing by newest lets one fresh child mask a dead subtree";
              }
              {
                # The example host sets pushUrlSuffix = "/external", so this
                # pins ORDER, not just presence: key, then suffix, then the
                # query string.
                name = "composes the push URL as <base>/<key><suffix>?<query>";
                test = ''grep -q -- '"\$PUSHURL/\$key\$PUSHSUFFIX?success=' ./script.sh'';
                why = "an endpoint whose push path continues past the key (…/<key>/external) is unreachable if the key is always last, and a suffix landing after the query string would be sent as part of the error text instead";
              }
              {
                name = "carries the caller's own pushUrlSuffix through verbatim";
                test = ''grep -qE "^PUSHSUFFIX='?/external'?$" ./script.sh'';
                why = "substituting a baked-in default here would silently push every verdict at the wrong URL, which fails the same way an unreachable endpoint does -- as silence";
              }
              {
                # Both call sites: the zfs-dynamic deadline and the
                # journalCheck log-scan window.
                name = "passes the cadence weekday list as ONE quoted argument, with zero-padded HH MM";
                test = ''
                  calls=$(grep -cF -- "=\$(expected_run_epoch " ./script.sh)
                  wellformed=$(grep -cF -- "=\$(expected_run_epoch '1 2 3 4 5' 03 00)" ./script.sh)
                  [ "$calls" -ge 2 ] && [ "$calls" = "$wellformed" ]'';
                why = "unquoted, the weekday list word-splits and the function reads dows=1 hh=2 mm=3 -- a cadence nobody configured, silently, and a target that died on Tuesday still reports green";
              }
            ];

          # 3b. The cadence claim from the module header, EXECUTED rather than
          #     grepped: a weekend evaluation compares against the last expected
          #     WEEKDAY run and never invents a deadline on a day the job does
          #     not run. Assertion 3's grep pins the call site's quoting; this
          #     pins what the function itself computes, so a rewrite of the
          #     date arithmetic that still looks right cannot pass.
          monitor-cadence-resolves-to-the-last-expected-run =
            pkgs.runCommand "nixbackup-check-monitor-cadence"
              {
                script = units.nixbackup-monitor.script;
                passAsFile = [ "script" ];
              }
              ''
                cp "$scriptPath" ./script.sh
                sed -n '/^day_at()/,/^}/p;/^expected_run_epoch()/,/^}/p' ./script.sh > ./helpers.sh
                . ./helpers.sh

                fail=0
                # case <label> <evaluation moment, UTC> <expected run, UTC>
                case_is() {
                  now=$(date -u -d "$2" +%s)
                  got=$(expected_run_epoch '1 2 3 4 5' 03 00)
                  want=$(date -u -d "$3" +%s)
                  if [ "$got" = "$want" ]; then
                    echo "ok   — $1"
                  else
                    echo "FAIL — $1: evaluating at $2 resolved to $(date -u -d "@$got"), wanted $3" >&2
                    fail=1
                  fi
                }

                # Sunday noon: Friday's run, not a phantom Saturday/Sunday one.
                case_is "a weekend evaluation looks back to Friday" \
                  "2026-08-02 12:00:00" "2026-07-31 03:00:00"
                # Wednesday, before today's run is due: Tuesday's, not today's.
                case_is "before the day's run is due, the previous run counts" \
                  "2026-07-29 02:00:00" "2026-07-28 03:00:00"
                # Wednesday, after it is due: today's.
                case_is "after the day's run is due, today's run counts" \
                  "2026-07-29 04:00:00" "2026-07-29 03:00:00"
                # Exactly at the run time: today's (>=, not >).
                case_is "the run minute itself already counts as today's run" \
                  "2026-07-29 03:00:00" "2026-07-29 03:00:00"

                [ "$fail" -eq 0 ] || exit 1
                echo "cadence resolves correctly" > $out
              '';

          # 3c. The journal filter's suppression rule, EXECUTED. A false green is
          #     the worst failure this module can produce -- it reports a broken
          #     backup as a working one -- so the awk is extracted from the
          #     generated script and RUN against fixtures rather than grepped for
          #     shape. A run-level summary names the SOURCE, so no substring rule
          #     can reach it; it may only be dropped when every detail line under
          #     it is an accepted destination, and never when there are none.
          monitor-journal-filter-suppresses-only-accepted-failures =
            pkgs.runCommand "nixbackup-check-monitor-journal-filter"
              {
                script = units.nixbackup-monitor.script;
                passAsFile = [ "script" ];
              }
              ''
                cp "$scriptPath" ./script.sh

                # FIRST, before anything clever: is the generated script even valid shell? The
                # awk program is embedded in a single-quoted shell word, so one apostrophe in an
                # awk COMMENT ends that word and the rest of the program is parsed as shell.
                # Extracting the awk and running it in isolation cannot see this -- the awk stays
                # perfectly valid while the script around it is broken.
                if ${pkgs.bash}/bin/bash -n ./script.sh 2>./shellerr; then
                  echo "ok   — the generated script is valid shell"
                else
                  echo "FAIL — the generated script is not valid shell" >&2
                  cat ./shellerr >&2
                  exit 1
                fi

                sed -n '/JC_FILTER_AWK_BEGIN/,/JC_FILTER_AWK_END/p' ./script.sh > ./filter.awk
                [ -s ./filter.awk ] || { echo "FAIL — could not extract the filter awk from the generated script" >&2; exit 1; }

                export JC_EXCL="pool/backups/example/placeholders"
                export JC_COND="does not exist or is offline"
                fail=0
                expect() {
                  label="$1"; want="$2"; shift 2
                  got=$(printf '%s\n' "$@" | ${pkgs.gawk}/bin/awk -f ./filter.awk | grep -c . || true)
                  if [ "$got" = "$want" ]; then
                    echo "ok   — $label"
                  else
                    echo "FAIL — $label: $got line(s) survived, wanted $want" >&2
                    fail=1
                  fi
                }

                SUM="Aug 14 05:04:55 h znapzend[999]: ERROR: suspending cleanup source dataset pool/thing because 2 send task(s) failed:"
                ACC="Aug 14 05:04:55 h znapzend[999]:  +-->   sub-destination 'pool/backups/example/placeholders/a' does not exist or is offline"
                ACC2="Aug 14 05:04:55 h znapzend[999]:  +-->   sub-destination 'pool/backups/example/placeholders/b' does not exist or is offline"
                REAL="Aug 14 05:04:55 h znapzend[999]:  +-->   sub-destination 'pool/backups/real/dbs' does not exist or is offline"

                expect "an all-accepted, fully-observed group is dropped whole" 0 "$SUM" "$ACC" "$ACC2"
                expect "one unaccepted detail keeps the summary AND that detail" 2 "$SUM" "$ACC" "$REAL"
                expect "a summary with no detail lines is never dropped" 1 "$SUM"
                expect "a standalone failure is untouched" 1 \
                  "Aug 14 05:04:55 h znapzend[777]: cannot receive incremental stream for pool/backups/real/dbs"
                # A later summary closes every open group. Being wrong here costs a summary that
                # could have been suppressed -- a false RED, the safe direction.
                expect "a later summary closes an earlier open group" 3 \
                  "Aug 14 05:04:55 h znapzend[111]: ERROR: suspending cleanup source dataset pool/a because 1 send task(s) failed:" \
                  "Aug 14 05:04:55 h znapzend[222]: ERROR: suspending cleanup source dataset pool/b because 1 send task(s) failed:" \
                  "Aug 14 05:04:55 h znapzend[111]:  +-->   sub-destination 'pool/backups/example/placeholders/a' does not exist or is offline" \
                  "Aug 14 05:04:55 h znapzend[222]:  +-->   sub-destination 'pool/backups/real/steam' does not exist or is offline"

                # ── The three false-green paths an adversarial review found. Each of these
                #    passed the destination-only, count-free version of this filter. ──

                # 1. Accepted DESTINATION, unaccepted CONDITION. This is what a deliberately
                #    absent destination looks like the day it exists and starts failing for real.
                expect "a real failure ON an excluded destination still counts" 1 \
                  "Aug 14 05:04:55 h znapzend[999]:  +-->   cannot receive into 'pool/backups/example/placeholders/a': destination has been modified"

                # 2. Sibling whose name merely starts with the excluded path.
                expect "an excluded path does not silence a longer sibling name" 1 \
                  "Aug 14 05:04:55 h znapzend[999]: cannot send to 'pool/backups/example/placeholdersync/prod': I/O error"

                # 3. journald rate-limiting / rotation / the window's own start can truncate a
                #    burst of details. Only the ones that survived were accepted -- that says
                #    nothing about the ones that did not.
                expect "fewer details than the summary claims keeps the summary" 1 "$SUM" "$ACC"

                # 4. No left edge on a substring search: an excluded "pool/..." also matches
                #    inside "bigpool/...", silencing a different pool entirely.
                expect "an excluded path inside a LONGER pool name is not excluded" 2 \
                  "Aug 14 05:04:55 h znapzend[555]: ERROR: suspending cleanup source dataset pool/vital because 1 send task(s) failed:" \
                  "Aug 14 05:04:55 h znapzend[555]:  +-->   sub-destination 'bigpool/backups/example/placeholders/vital' does not exist or is offline"

                # 5. Co-occurrence: the excluded path appears on the line, but the destination the
                #    line is ABOUT is a different, unexcluded one.
                expect "an excluded path mentioned elsewhere cannot launder another destination" 1 \
                  "Aug 14 05:04:55 h znapzend[555]: while replicating 'pool/backups/example/placeholders', sub-destination 'pool/backups/vital' does not exist or is offline"

                # 6. PID reuse. A group held open to end-of-stream adopts a detail line emitted
                #    hours later by a recycled PID; if the count lines up, it drops on it.
                expect "a group cannot adopt details across intervening output" 2 \
                  "Aug 14 05:04:55 h znapzend[868761]: ERROR: suspending cleanup source dataset pool/vital because 1 send task(s) failed:" \
                  "Aug 14 11:00:00 h znapzend[868761]: done with backupset pool/other in 3 seconds" \
                  "Aug 14 17:41:02 h znapzend[868761]:  +-->   sub-destination 'pool/backups/example/placeholders/az' does not exist or is offline"

                # 7. …nor across nothing but OTHER runs' summaries and details, where no ordinary
                #    line ever appears to close it. Exactly one line survives: the stale summary,
                #    refusing to be satisfied by a later run's detail. The interposed run is
                #    complete and fully accepted, so it is correctly dropped, and the orphaned
                #    detail is an accepted line in its own right.
                expect "a group cannot adopt details across other runs alone" 1 \
                  "Aug 14 05:04:55 h znapzend[868761]: ERROR: suspending cleanup source dataset pool/vital because 1 send task(s) failed:" \
                  "Aug 14 09:00:00 h znapzend[999111]: ERROR: suspending cleanup source dataset pool/other because 1 send task(s) failed:" \
                  "Aug 14 09:00:00 h znapzend[999111]:  +-->   sub-destination 'pool/backups/example/placeholders/a' does not exist or is offline" \
                  "Aug 14 17:41:02 h znapzend[868761]:  +-->   sub-destination 'pool/backups/example/placeholders/c' does not exist or is offline"

                # 8-10. The tokenizer can only see paths that are QUOTED and contain a slash. A
                #       second destination it cannot see must never be read as excluded.
                expect "an apostrophe in prose cannot swallow a following real path" 2 \
                  "Aug 14 05:04:55 h znapzend[868761]: ERROR: suspending cleanup source dataset pool/x because 1 send task(s) failed:" \
                  "Aug 14 05:04:55 h znapzend[868761]:  +--> sub-destination 'pool/backups/example/placeholders/a' does not exist or is offline; the pool's mirror 'pool/backups/vital' does not exist or is offline"

                expect "an UNQUOTED second destination is not read as excluded" 2 \
                  "Aug 14 05:04:55 h znapzend[868761]: ERROR: suspending cleanup source dataset pool/x because 1 send task(s) failed:" \
                  "Aug 14 05:04:55 h znapzend[868761]:  +--> sub-destination 'pool/backups/example/placeholders/a' does not exist or is offline; pool/backups/vital does not exist or is offline"

                expect "a bare pool root alongside an excluded path is not read as excluded" 2 \
                  "Aug 14 05:04:55 h znapzend[868761]: ERROR: suspending cleanup source dataset pool/x because 1 send task(s) failed:" \
                  "Aug 14 05:04:55 h znapzend[868761]:  +--> sub-destination 'pool/backups/example/placeholders/a' does not exist or is offline; 'tank' does not exist or is offline"

                [ "$fail" -eq 0 ] || exit 1
                echo "filter suppresses only accepted failures" > $out
              '';

          # 4. btrbkPush is a MECHANISM, not a policy -- it must carry the
          #    caller's own retention strings through to `services.btrbk`
          #    verbatim, never substitute a baked-in default of its own
          #    (see the README's "Deliberately out of scope").
          btrbkpush-passes-through-caller-policy-verbatim =
            let
              settings = host.config.services.btrbk.instances.nixbackup.settings;
              ok =
                settings.snapshot_preserve == "24h 7d 4w"
                && settings.target_preserve == "14d 8w 12m"
                && settings.incremental == "strict"
                && settings.send_compressed_data == "yes"
                && settings.target_preserve_min == "no";
            in
            if ok then
              pkgs.runCommand "nixbackup-check-btrbkpush" { } "echo ok > $out"
            else
              throw "nixbackup.btrbkPush: expected the example host's own snapshotPreserve/targetPreserve/incremental to reach services.btrbk.instances.nixbackup.settings unchanged, but at least one value was substituted or lost";

          # 5. localSnapshots must wire the CALLER's `retain`, not its own
          #    module default (24) -- the example host sets 48.
          localsnapshots-retain-is-wired =
            assertScript "local-snapshots" units.nixbackup-local-snapshots.script [
              {
                name = "retires past the CALLER's retain count (48), not the module default (24)";
                test = ''grep -q -- "head -n -48" ./script.sh'';
                why = "hardcoding the module's own default here would silently ignore every caller's own nixbackup.localSnapshots.retain";
              }
              {
                name = "snapshots are read-only (-r)";
                test = ''grep -q -- "btrfs subvolume snapshot -r" ./script.sh'';
                why = "a writable snapshot can itself be mutated, defeating the point of a fixed replication source";
              }
            ];

          # 6. btrbkPull: the newest RECEIVED snapshot is never a retention
          #    candidate (it is tomorrow's incremental parent), and a
          #    missing shared parent falls back to a full send rather than
          #    failing outright.
          btrbkpull-preserves-newest-and-falls-back-to-full-send =
            assertScript "btrbk-pull" units.nixbackup-btrbk-pull.script [
              {
                name = "never retires the newest received snapshot";
                test = ''grep -q -- '\[ "\$old" = "\$NEWEST" \] && continue' ./script.sh'';
                why = "the newest received snapshot is the parent for the NEXT incremental pull; deleting it forces every future pull to a full send";
              }
              {
                name = "falls back to a full send when no shared parent exists";
                test = ''grep -q "FULL send" ./script.sh'';
                why = "without an explicit fallback, a broken parent chain (e.g. the remote's own retention already expired it) would fail the pull outright instead of degrading to a full send";
              }
              {
                name = "ships compressed extents as-is (--compressed-data)";
                test = ''[ "$(grep -c -- "--compressed-data" ./script.sh)" -ge 2 ]'';
                why = "decompressing and recompressing on every pull burns CPU for data that is already compressed on disk";
              }
            ];

          # 7. Required, no-default options actually fail the build when
          #    omitted -- proven in BOTH directions, not just "it evaluates
          #    when you fill in every field".
          btrbkpull-requires-remotehost =
            let
              missing = buildFailsWith self.nixosModules.btrbkPull {
                nixbackup.btrbkPull = {
                  enable = true;
                  remoteSnapshotDir = "/data/snapshots/hot";
                  targetPath = "/mnt/btrfs-backup/example";
                  sshIdentityFile = "/root/.ssh/id_example";
                };
              };
              present = buildFailsWith self.nixosModules.btrbkPull {
                nixbackup.btrbkPull = {
                  enable = true;
                  remoteHost = "203.0.113.5";
                  remoteSnapshotDir = "/data/snapshots/hot";
                  targetPath = "/mnt/btrfs-backup/example";
                  sshIdentityFile = "/root/.ssh/id_example";
                };
              };
            in
            if missing && !present then
              pkgs.runCommand "nixbackup-check-btrbkpull-required" { } "echo ok > $out"
            else
              throw "nixbackup.btrbkPull.remoteHost: expected omitting it to fail the build and supplying it to succeed, got missing=${toString missing} present=${toString present}";

          localsnapshots-requires-source-and-snapshotdir =
            let
              missing = buildFailsWith self.nixosModules.localSnapshots {
                nixbackup.localSnapshots.enable = true;
              };
              present = buildFailsWith self.nixosModules.localSnapshots {
                nixbackup.localSnapshots = {
                  enable = true;
                  source = "/data/hot";
                  snapshotDir = "/data/snapshots/hot";
                };
              };
            in
            if missing && !present then
              pkgs.runCommand "nixbackup-check-localsnapshots-required" { } "echo ok > $out"
            else
              throw "nixbackup.localSnapshots.{source,snapshotDir}: expected omitting them to fail the build and supplying them to succeed, got missing=${toString missing} present=${toString present}";

          # 8. snapperBackup: required options (no defaults) actually fail the
          #    build when omitted, same proof-in-both-directions shape as 7.
          snapperbackup-requires-target-options =
            let
              missing = buildFailsWith ./modules/snapper-backup.nix {
                nixbackup.snapperBackup.enable = true;
              };
              present = buildFailsWith ./modules/snapper-backup.nix {
                nixbackup.snapperBackup = {
                  enable = true;
                  targetHost = "backup-receiver.example.org";
                  targetPathPrefix = "/mnt/btrfs-backup/example-host";
                  sshIdentityFile = "/etc/ssh/nixbackup_snapper_ed25519";
                };
              };
            in
            if missing && !present then
              pkgs.runCommand "nixbackup-check-snapperbackup-required" { } "echo ok > $out"
            else
              throw "nixbackup.snapperBackup.{targetHost,targetPathPrefix,sshIdentityFile}: expected omitting them to fail the build and supplying them to succeed, got missing=${toString missing} present=${toString present}";

          # 8b. snapperBackup.distro: the config-template package a derivative
          #     ships is published for that derivative and for NOBODY else. Both
          #     directions are asserted, and the ABSENT one is the load-bearing
          #     half: a derivative-only name exists in no upstream Arch repo and
          #     in no AUR, and `pacman -S` aborts the ENTIRE transaction on one
          #     unknown target -- so a leak onto the default would not merely
          #     install the wrong package, it would fail every OTHER package a
          #     consuming host declared. Read WITHOUT `enable`, deliberately:
          #     `archPackages` is defined outside the module's `mkIf` so a
          #     consumer can wire it into a reconciler unconditionally.
          snapperbackup-distro-gates-the-template-package =
            let
              archPkgsFor = distro: (lib.nixosSystem {
                inherit system;
                modules = [
                  ./modules/snapper-backup.nix
                  { nixbackup.snapperBackup.distro = distro; }
                  bareStubs
                ];
              }).config.nixbackup.snapperBackup.archPackages;
              onArch = archPkgsFor "arch";
              onCachyos = archPkgsFor "cachyos";
              # A typo in a free-form value would resolve to "publish nothing" and be invisible;
              # the enum is what turns it into an evaluation failure instead. Forced through
              # `archPackages` rather than `system.build.toplevel`, deliberately: nothing in a
              # bare toplevel consumes this option, so an unforced type constraint is no
              # constraint at all -- the check has to read the value it claims is protected.
              typoRejected = !(builtins.tryEval
                (builtins.seq (archPkgsFor "cachyOS") true)).success;
            in
            if onArch == [ ] && onCachyos == [ "cachyos-snapper-support" ] && typoRejected then
              pkgs.runCommand "nixbackup-check-snapperbackup-distro" { } "echo ok > $out"
            else
              throw "nixbackup.snapperBackup.distro: expected arch=[] and cachyos=[\"cachyos-snapper-support\"] with a typo rejected, got arch=${builtins.toJSON onArch} cachyos=${builtins.toJSON onCachyos} typoRejected=${lib.boolToString typoRejected}";

          # 9. The module's own header explains WHY the drop-in leads with an
          #    empty OnCalendar=: systemd ADDS repeated keys instead of
          #    replacing them, so without the clear-first line, a future
          #    `snapper` package default change would fire a SECOND trigger
          #    alongside this one rather than being superseded by it. Order
          #    matters here, not just presence -- this pins the order.
          snapperbackup-dropin-clears-before-setting-oncalendar =
            let
              text = host.config.environment.etc."systemd/system/snapper-backup.timer.d/50-declared-schedule.conf".text;
              hasOrderedClear = lib.strings.hasInfix "OnCalendar=\nOnCalendar=hourly" text;
            in
            if hasOrderedClear then
              pkgs.runCommand "nixbackup-check-snapperbackup-dropin-order" { } "echo ok > $out"
            else
              throw "nixbackup.snapperBackup: expected the timer drop-in to clear OnCalendar= before setting the declared value (in that order), got:\n${text}";

          # 10. The whole point of targetPathPrefix + per-backup targetSubvolume
          #     is that they compose into the real target-path snbk actually
          #     uses -- a rename/typo in either half must be visible here, not
          #     silently drop the join.
          snapperbackup-json-composes-target-path =
            let
              text = host.config.environment.etc."snapper/backup-configs/root.json".text;
              ok =
                lib.strings.hasInfix "\"target-path\":\"/mnt/btrfs-backup/example-host/@\"" text
                && lib.strings.hasInfix "\"ssh-host\":\"backup-receiver.example.org\"" text
                # Regression pin: targetToolBins' default keys are bare tool names
                # ("btrfs"), and this module appends the "target-"/"-bin" wrapping --
                # a mismatched convention on either side doubles the suffix
                # ("target-btrfs-bin-bin") and snbk silently never finds the key it
                # actually wants. Caught exactly this way once already.
                && lib.strings.hasInfix "\"target-btrfs-bin\":" text
                && !(lib.strings.hasInfix "-bin-bin" text);
            in
            if ok then
              pkgs.runCommand "nixbackup-check-snapperbackup-json" { } "echo ok > $out"
            else
              throw "nixbackup.snapperBackup: expected the rendered JSON's target-path to be targetPathPrefix/targetSubvolume, ssh-host to be targetHost, and target-<tool>-bin keys to have no doubled -bin-bin suffix, got:\n${text}";
        });

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);
    };
}
