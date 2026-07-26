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
      # Three modules, each independently toggleable, sharing one namespace
      # (`nixbackup.*`) and one convention (ZFS user-properties as the
      # runtime source of truth, never a hand-maintained list). See
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
      };

      lib = { };

      # The word "tested" in the description above is earned here. Two of these
      # do more than evaluate: they assert the specific behaviours whose absence
      # would be invisible in review and silent in production.
      checks = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};

          # All three modules composed into one system, from examples/host.
          host = lib.nixosSystem {
            inherit system;
            modules = lib.attrValues self.nixosModules
              ++ [ ./examples/host/configuration.nix ];
          };

          units = host.config.systemd.services;

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
        });

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);
    };
}
