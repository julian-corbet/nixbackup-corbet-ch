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
            ];

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
