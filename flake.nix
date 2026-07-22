{
  description = "nixbackup - ZFS backup-destination discipline as enforced, tested NixOS modules";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems f;
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

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);
    };
}
