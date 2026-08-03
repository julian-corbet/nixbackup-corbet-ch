# The smallest NixOS configuration that composes all three nixbackup modules,
# used by every check in this flake.
#
# This is not a machine anyone would run, and the pool and dataset names are
# placeholders. It exists so the modules can be type-checked and so the units
# they generate can be asserted against — nothing here touches a real disk, and
# no pool, host or endpoint from any real system appears.
{ ... }:
{
  # Enforce the receive-destination invariants. See studies/phantom-write-footgun.md
  # for why an unmounted destination is not a preference but a requirement.
  nixbackup.destinations = {
    enable = true;
    datasets = [ "example-cold/backups" ];
    recursive = true;
  };

  # Discover replication plans from ZFS user-properties at runtime and seed any
  # destination child that does not exist yet.
  nixbackup.autobootstrap = {
    enable = true;
    sourcePool = "example-hot";
  };

  # A declarative front end over the upstream `services.btrbk` -- the PUSH shape
  # of btrfs replication, for a host allowed to hold outbound credentials.
  nixbackup.btrbkPush = {
    enable = true;
    targetHost = "backup-receiver.example.org";
    targetPath = "/mnt/btrbackup/example-source";
    sshIdentityFile = "/etc/ssh/nixbackup_btrbk_push_ed25519";
    sourceVolume = "/data";
    snapshotDir = "/data/snapshots";
    subvolumes = [ "data" ];
    snapshotPreserve = "24h 7d 4w";
    targetPreserve = "14d 8w 12m";
  };

  # The PULL shape's two halves -- SOURCE (localSnapshots, run on the less-
  # trusted box) and RECEIVER (btrbkPull, run on the box doing the pulling).
  # Composed on the SAME example host purely so both type-check together;
  # a real deployment runs them on two different machines (see each
  # module's own header for the trust-direction rationale).
  nixbackup.localSnapshots = {
    enable = true;
    source = "/data/hot";
    snapshotDir = "/data/snapshots/hot";
    retain = 48;
    onCalendar = "hourly";
  };

  nixbackup.btrbkPull = {
    enable = true;
    remoteHost = "203.0.113.5";
    remoteSnapshotDir = "/data/snapshots/hot";
    targetPath = "/mnt/btrfs-backup/example-node";
    sshIdentityFile = "/root/.ssh/id_nixbackup_pull";
    retainDays = 14;
    onCalendar = "03:30";
  };

  # Evaluate every target from ground truth and push the verdict out. Several
  # kinds are configured on purpose: each `kind` takes a different path through
  # the generated script, so a check over one kind proves nothing about the rest.
  nixbackup.monitor = {
    enable = true;
    # The key-in-the-MIDDLE push shape (<base>/<key>/external?...), so the
    # checks below exercise a non-default pushUrlSuffix rather than only the
    # plain <base>/<key>?... default. examples/configuration.nix shows the
    # default shape.
    pushUrl = "https://status.example.com/api/v1/endpoints";
    pushUrlSuffix = "/external";

    targets = {
      example-leaves = {
        kind = "zfs-leaves";
        paths = [ "example-cold/backups/host-a" "example-cold/backups/host-b" ];
        maxAgeHours = 26;
      };
      example-dynamic = {
        kind = "zfs-dynamic";
        scanRoot = "example-hot";
        maxAgeHours = 26;
      };
      example-stamp = {
        kind = "stampfile";
        paths = [ "/var/lib/example/last-verified-success" ];
        maxAgeHours = 26;
      };
    };
  };

  # snapper-backup: the same push shape as btrbkPush above, for a non-NixOS
  # host whose only snapshot tool is the `snapper` package's bundled `snbk`.
  # Composed here purely for eval coverage -- see modules/snapper-backup.nix's
  # own "TESTING NOTE".
  nixbackup.snapperBackup = {
    enable = true;
    targetHost = "backup-receiver.example.org";
    targetPathPrefix = "/mnt/btrfs-backup/example-host";
    sshIdentityFile = "/etc/ssh/nixbackup_snapper_ed25519";
    onCalendar = "hourly";
    backups = {
      root = {
        sourcePath = "/";
        targetSubvolume = "@";
      };
    };
  };

  # ── Stubs NixOS demands of any bootable system ───────────────────────────
  # tmpfs on / could never boot a real machine, which is the point: this config
  # exists to type-check modules, not to describe hardware.
  fileSystems."/" = {
    device = "nodev";
    fsType = "tmpfs";
  };

  boot.loader.grub = {
    enable = true;
    devices = [ "nodev" ];
  };

  networking.hostName = "example-node";
  system.stateVersion = "25.05";
}
