# examples/configuration.nix — a complete, generic flake wiring all three
# nixbackup modules together on one host: a receive-destination invariant
# (destinations), a runtime auto-bootstrap for new plan children
# (autobootstrap), and a ground-truth freshness/integrity monitor pushing to
# a generic monitoring endpoint (monitor).
#
# Every value here is a placeholder (tank/backup, pool/data,
# https://monitor.example/push, ...). Swap in your own pool names, dataset
# paths, and monitoring URL before deploying.
#
# To check parsing: `nix-instantiate --parse examples/configuration.nix`.
{
  description = "Example host using all three nixbackup modules";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixbackup.url = "github:<you>/nixbackup";
  };

  outputs = { self, nixpkgs, nixbackup }: {
    nixosConfigurations.example-backup-host = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        nixbackup.nixosModules.destinations
        nixbackup.nixosModules.autobootstrap
        nixbackup.nixosModules.monitor

        {
          # ── destinations: enforce the receive-destination invariant on
          # every dataset under the two mirror roots below (and every
          # existing descendant, via `recursive = true`, the default). ──
          nixbackup.destinations = {
            enable = true;
            datasets = [
              "pool/backups/dbs"
              "pool/backups/data"
            ];
            interval = "1h";
          };

          # ── autobootstrap: discover replication plans at runtime from
          # `org.nixbackup:enabled` / `org.nixbackup:destination` stamped on
          # `tank` (the SOURCE pool), and seed any missing destination
          # child under `pool` (the DESTINATION pool). ──
          nixbackup.autobootstrap = {
            enable = true;
            sourcePool = "tank";
            excludePatterns = [ "tank/scratch" ];
            interval = "1d";
          };

          # ── monitor: ground-truth freshness + integrity, pushed to a
          # generic push-style monitoring endpoint. ──
          nixbackup.monitor = {
            enable = true;
            pushUrl = "https://monitor.example/push";
            tokenFile = "/run/secrets/monitor-push-token";
            interval = "6h";

            targets = {
              # A flat tree of received btrfs snapshot subvolumes, e.g. an
              # offsite pull landing named-timestamp subvolumes directly.
              offsite-pull = {
                kind = "btrfs-received";
                paths = [ "/mnt/backup-received" ];
                maxAgeHours = 30;
              };

              # A snapper-style tree: named subvolumes, each holding
              # numbered snapshot directories (husk detection applies here).
              laptop-mirror = {
                kind = "btrfs-mtime";
                paths = [ "/mnt/backup-received/laptop" ];
                maxAgeHours = 48;
              };

              # Per-leaf ZFS snapshot freshness, MIN-reduced across leaves.
              database-mirror = {
                kind = "zfs-leaves";
                paths = [
                  "pool/backups/dbs/postgres"
                  "pool/backups/dbs/mysql"
                ];
                maxAgeHours = 30;
              };

              # A stampfile a completely different, non-ZFS job writes only
              # on verified success (a bare epoch).
              offsite-dump = {
                kind = "stampfile";
                paths = [ "/var/lib/offsite-dump/last-success" ];
                maxAgeHours = 26;
              };

              # Ground-truth replication-plan discovery: every plan root
              # tagged `org.nixbackup:enabled=on` under `tank`, diffed
              # structurally against its destination, MIN-reduced over
              # every actual leaf on the destination side.
              pool-mirror = {
                kind = "zfs-dynamic";
                scanRoot = "tank";
                excludePatterns = [ "tank/scratch" ];
                cadence = {
                  weekdays = [ "Mon" "Tue" "Wed" "Thu" "Fri" ];
                  atHour = 3;
                  atMinute = 0;
                  slackHours = 7;
                };
              };
            };

            journalChecks = {
              # A unit can exit 0 for the run as a whole while its own log
              # already recorded a real per-item send/receive failure --
              # this catches that class of failure independently of
              # `pool-mirror`'s artifact-freshness check above.
              replication-errors = {
                unit = "my-replication.service";
                patterns = [
                  "cannot send"
                  "cannot receive"
                  "send task\\(s\\) failed"
                  "does not exist or is offline"
                ];
                since = {
                  weekdays = [ "Mon" "Tue" "Wed" "Thu" "Fri" ];
                  atHour = 3;
                  slackHours = 7;
                };
                # Same exclusions as `pool-mirror` above, so a KNOWN,
                # already-accepted gap (e.g. tank/scratch) doesn't
                # permanently redden this check.
                excludeDestinationsOf = "pool-mirror";
              };
            };
          };
        }
      ];
    };
  };
}
