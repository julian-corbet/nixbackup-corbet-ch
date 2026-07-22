# examples

Minimal, working, option-accurate example configurations showing how to use
the three nixbackup modules in a real NixOS flake.

## Full example with all three modules

**`configuration.nix`** — a complete flake demonstrating:

- `nixbackup.destinations` enforcing canmount=noauto + readonly=on +
  unmounted on two backup receive-destination roots
- `nixbackup.autobootstrap` discovering replication plans at runtime from
  ZFS user-properties on a source pool, and bootstrapping missing children
  under a destination pool
- `nixbackup.monitor` evaluating every one of its five target kinds
  (`btrfs-received`, `btrfs-mtime`, `zfs-leaves`, `stampfile`,
  `zfs-dynamic`) plus a `journalChecks` entry, all pushing to a generic
  monitoring endpoint

All values are generic (`tank`, `pool/backups/...`,
`https://monitor.example/push`, placeholder unit names); swap in your own
pool names, dataset paths, and monitoring URL before deploying.

To check parsing: `nix-instantiate --parse configuration.nix`.

## Per-module quickstart

See the main [README](../README.md) for copy-pasteable per-module snippets
under "Usage".
