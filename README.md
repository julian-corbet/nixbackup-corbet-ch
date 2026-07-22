# nixbackup

**ZFS backup-destination discipline, learned the hard way, as enforced NixOS
modules.**

Three independently toggleable modules that encode the invariants a ZFS
backup/replication setup needs to actually stay correct over time — not just
on the day it was built. Each rule here exists because a real, live setup
violated it and paid for that violation; the fix in every case was not "watch
more closely" but "make the wrong state structurally harder to reach, and
verify the right state instead of trusting anything's exit code."

## The pitch

`zfs send | zfs receive` replication looks solved the day you set it up: the
first bootstrap lands, the first incremental works, the first status check is
green. None of that predicts whether it is still correct six months later,
because three failure modes hide behind a green dashboard and a zero exit
code:

1. **A receive destination that gets mounted develops a phantom write.**
   Mount a receive destination's root and its children's own mounts occlude
   the parent's placeholder directories — a few bytes of directory-entry
   metadata churn that `zfs receive`'s incremental-safety check cannot tell
   apart from real data changing. The next incremental refuses
   ("destination has been modified since most recent snapshot"), even though
   every child dataset shows zero bytes actually written. It reads exactly
   like data loss. It is not one. It still costs a manual re-baseline, and it
   recurs on every root a reboot or a rebuild remounts.
2. **"Auto-create the destination" flags, across more than one popular
   replication tool, turn out not to actually create anything.** A newly
   added child dataset under an already-replicating tree gets no destination
   at all — the tool logs "destination does not exist, will be rechecked
   every run" forever and never attempts the create, no matter how long you
   wait.
3. **A job's own exit code is not a signal, and a name or mtime is not proof
   of a complete transfer.** A replication job can exit 0 every single night
   while silently replicating nothing. A truncated `btrfs receive` can leave
   behind a directory with a perfectly fresh timestamp and no actual snapshot
   subvolume inside it. Both look identical to "healthy" from anything that
   isn't reading the artifact's actual, structural ground truth.

`nixbackup` is the fix for all three, encoded so it can't be quietly
re-lost: not documentation to remember, but modules that assert the correct
state, re-apply it on a schedule, and evaluate freshness from ground truth
rather than from a log line that says "success."

## The three modules

- **`destinations.nix`** (`nixbackup.destinations`) — every backup receive
  destination dataset stays `canmount=noauto` + `readonly=on`, both SET
  LOCALLY (a locally-set property always wins over one carried in by a
  received stream), plus actually unmounted. A boot + timer oneshot
  re-asserts all three, so nothing — not a stray `zfs set`, not a host
  rebuild that remounts the pool — can silently reopen the phantom-write
  divergence described above. The full mechanism is documented in the
  module's own header comment.
- **`autobootstrap.nix`** (`nixbackup.autobootstrap`) — a timer that
  enumerates replication plans at RUNTIME from ZFS user-properties (never a
  hardcoded list — a plan absent from a hand-list is structurally invisible
  to anything built around that list) and seeds any destination child that
  does not exist yet with one `zfs send -w | zfs receive -u`, closing the
  broken-"auto-create" hole for every newly added child dataset. Every
  dataset it creates is immediately set to `canmount=noauto` +
  `readonly=on`, so it starts life already compliant with
  `nixbackup.destinations`'s invariant, whether or not that module also runs
  on the same host.
- **`monitor.nix`** (`nixbackup.monitor`) — the ground-truth freshness
  evaluator: stats the ARTIFACT a job was supposed to produce, never the
  job's exit code; reduces freshness by per-leaf MIN, never a recursive MAX
  that lets one fresh child hide a dead subtree; diffs source against
  destination structurally so a newly-missing child is its own failure, not
  silence; detects "husks" (btrfs) — a numbered snapshot directory that
  exists with no snapshot subvolume ever having landed inside it, which
  reads as fresh by mtime and is actually empty; applies cadence-aware
  staleness deadlines (a weekend evaluation still compares against the last
  weekday the job was expected to run, not an invented deadline); and runs a
  configurable journal error-budget check per unit, because a unit can exit
  0 while its own log already recorded a real per-item send/receive
  failure. Publishes every result to a configurable push-style monitoring
  endpoint.

### Deliberately out of scope

**Which datasets to back up, and how often.** This repo has no opinion on
your retention policy, your pool layout, or your replication tool of choice
(the modules assume `zfs send`/`receive` underneath, same as most of the
common tools). It owns the invariants that make whatever you already run
stay correct, not the policy decisions about what to run.

**The replication daemon itself.** `nixbackup` does not run or configure
`znapzend`, `syncoid`, or anything else that actually schedules and executes
`zfs send`/`receive` on your behalf — it assumes one of those (or an
equivalent you wrote yourself) already exists, stamps the ZFS user-properties
these modules read, and does the routine incremental work. `nixbackup` covers
the three specific gaps those tools tend to share: destination-mount safety,
the broken-autoCreation hole for new children, and ground-truth freshness
evaluation instead of trusting the tool's own reported success.

## Status

**Pre-alpha, all three modules real and evaluated.** All three were
extracted and generalized from a working setup — each rule above corresponds
to an incident that was actually hit, root-caused, and fixed on that setup
before being pulled out here with every site-specific value replaced by a
generic parameter. Verified so far by NixOS module evaluation (`nix eval` on
each `nixosModules.*` attribute, plus a toy `nixosSystem` importing all
three together) — not yet run against a second, independent real ZFS pool.
Nothing advertised here is invented or missing; nothing is claimed as
battle-tested beyond the module-evaluation level until it has actually run
elsewhere.

- [x] `nixosModules.destinations` (`modules/destinations.nix`)
- [x] `nixosModules.autobootstrap` (`modules/autobootstrap.nix`)
- [x] `nixosModules.monitor` (`modules/monitor.nix`)

## Usage

The three modules work independently or together; a typical host enables
all three.

### destinations: enforce the receive-destination invariant

```nix
{
  inputs.nixbackup.url = "github:<you>/nixbackup";

  outputs = { self, nixpkgs, nixbackup }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        nixbackup.nixosModules.destinations
        {
          nixbackup.destinations = {
            enable = true;

            # REQUIRED: at least one backup receive-destination dataset.
            datasets = [
              "tank/backups/dbs"
              "tank/backups/office"
            ];

            # Optional; shown here are the defaults:
            # recursive = true;   # also enforce on every existing descendant
            # interval = "1h";    # re-assertion cadence (plus once at boot)
          };
        }
      ];
    };
  };
}
```

### autobootstrap: close the broken-autoCreation hole

```nix
{
  inputs.nixbackup.url = "github:<you>/nixbackup";

  outputs = { self, nixpkgs, nixbackup }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        nixbackup.nixosModules.autobootstrap
        {
          nixbackup.autobootstrap = {
            enable = true;

            # REQUIRED: the pool/root dataset scanned for plan roots.
            sourcePool = "tank";

            # Optional; shown here are the defaults:
            # enabledProperty = "org.nixbackup:enabled";
            # destinationProperty = "org.nixbackup:destination";
            # excludePatterns = [ ];
            # interval = "1d";
            # timeoutSec = "2h";
          };
        }
      ];
    };
  };
}
```

Your replication tool's own configuration (or a small companion `zfs set`)
needs to stamp `org.nixbackup:enabled=on` and
`org.nixbackup:destination=<dest dataset>` on each plan-root source dataset
— that pair of properties is the entire runtime contract this module reads.

### monitor: ground-truth freshness, pushed to your monitoring stack

```nix
{
  inputs.nixbackup.url = "github:<you>/nixbackup";

  outputs = { self, nixpkgs, nixbackup }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        nixbackup.nixosModules.monitor
        {
          nixbackup.monitor = {
            enable = true;

            # REQUIRED: your push-style monitoring endpoint.
            pushUrl = "https://monitor.example/push";

            # Optional; shown here are the defaults:
            # group = "backups";
            # tokenFile = null;   # e.g. "/run/secrets/monitor-push-token"
            # interval = "6h";

            targets = {
              # A flat tree of received btrfs snapshot subvolumes.
              offsite-pull = {
                kind = "btrfs-received";
                paths = [ "/mnt/backup-received" ];
                maxAgeHours = 30;
              };

              # Per-leaf ZFS snapshot freshness, MIN-reduced.
              database-mirror = {
                kind = "zfs-leaves";
                paths = [ "tank/backups/dbs/postgres" "tank/backups/dbs/mysql" ];
                maxAgeHours = 30;
              };

              # Ground-truth replication-plan discovery + structural diff.
              pool-mirror = {
                kind = "zfs-dynamic";
                scanRoot = "tank";
                cadence = {
                  weekdays = [ "Mon" "Tue" "Wed" "Thu" "Fri" ];
                  atHour = 3;
                  slackHours = 7;
                };
              };
            };

            journalChecks = {
              replication-errors = {
                unit = "my-backup.service";
                patterns = [ "cannot send" "cannot receive" "does not exist or is offline" ];
                since = { atHour = 3; slackHours = 7; };
                excludeDestinationsOf = "pool-mirror";
              };
            };
          };
        }
      ];
    };
  };
}
```

## Full example

See [`examples/configuration.nix`](examples/configuration.nix) for a
complete, generic flake wiring all three modules together on one host.

## Roadmap

- [x] Receive-destination invariant enforcement — `modules/destinations.nix`
- [x] Runtime-discovered auto-bootstrap — `modules/autobootstrap.nix`
- [x] Ground-truth freshness/integrity monitor — `modules/monitor.nix`

Future work:

- [ ] Run against a second, independent real ZFS pool (not just module
      evaluation)
- [ ] A `lib` helper for stamping the `org.nixbackup:*` properties this repo
      reads, so a consumer doesn't have to hand-write the `zfs set` calls
- [ ] Full documentation of the cadence/`journalChecks` interaction beyond
      the inline option docs

## Related projects

`nixbackup` is one of several independent, narrowly-scoped NixOS/Nix
projects. [nixvps](https://github.com/julian-corbet/nixvps-corbet-ch) does
the same "hard-won discipline as reusable modules" pattern for tiny cloud
VMs; [nixram](https://github.com/julian-corbet/nixram-corbet-ch) handles
memory-pressure tuning. Use them together or separately.

## License

[MIT License](LICENSE) &copy; 2026 Julian Corbet
