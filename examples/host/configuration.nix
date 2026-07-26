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

  # Evaluate every target from ground truth and push the verdict out. Several
  # kinds are configured on purpose: each `kind` takes a different path through
  # the generated script, so a check over one kind proves nothing about the rest.
  nixbackup.monitor = {
    enable = true;
    pushUrl = "https://status.example.com/push";

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
