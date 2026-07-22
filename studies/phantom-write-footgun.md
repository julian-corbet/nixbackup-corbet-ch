# Why a backup receive destination must stay unmounted

## The problem

A ZFS dataset that is the RECEIVE side of a `zfs send | zfs receive`
replication pipeline looks, on the surface, like any other dataset — it can
be mounted, browsed, and treated like a normal filesystem. That surface
similarity is the footgun. The moment a receive destination gets mounted,
something ZFS itself cannot distinguish from real data loss can quietly
occur, with no data actually at risk.

## What actually happens on disk

Mount a receive destination's root and every child dataset underneath it
gets its own separate mount, layered into the parent's directory tree at
its mountpoint. Before a child mounts — or permanently, for any child that
never auto-mounts for whatever reason — the parent filesystem itself
contains an ordinary empty directory sitting at that mountpoint. Creating
that directory, and the kernel touching it as part of the mount sequence,
is a real write to the PARENT dataset: a few bytes of directory-entry and
metadata churn. Not one byte of the parent's actual payload changes.

`zfs receive`'s own incremental-replication safety check has no way to tell
the difference between "a few bytes of mount-time metadata churn" and "real
data was written here since the last snapshot." It refuses the next
incremental with an error to the effect of *"destination has been modified
since most recent snapshot"* — and that refusal is entirely correct,
mechanically: from ZFS's point of view, the destination genuinely was
written to since its last snapshot. It just wasn't written to in any way
that matters.

The confirming evidence is `zfs get written`: on an affected tree, the
PARENT dataset shows a small nonzero `written` value while every CHILD
dataset underneath it shows exactly zero. Nothing real changed anywhere —
only the parent picked up incidental mount bookkeeping.

## Why the receive-time flag isn't enough

Most replication tools (and `zfs receive` itself) offer a "receive
unmounted" option — an equivalent of `zfs receive -u`, which avoids
mounting the dataset at the moment the stream lands. That flag does exactly
what it says and nothing more: it controls behavior AT RECEIVE TIME. It
says nothing at all about:

- the next reboot,
- the next `zfs mount -a` (run implicitly by plenty of ordinary system
  activity),
- a system rebuild that touches the pool's mount units,
- or an operator simply running `zfs set canmount=on` while poking around.

Any one of those can flip a receive destination from "unmounted, safe" back
to "mounted, one incremental away from a spurious divergence" — and the
receive-time flag has no mechanism to stop that, because its job already
finished the moment the stream landed.

## The fix: local properties, actively re-asserted

Two ZFS properties, both set with LOCAL scope, are what actually close this
gap:

- **`canmount=noauto`** — the dataset never auto-mounts, at boot or via
  `zfs mount -a`, regardless of what a received stream's own properties
  say it should be.
- **`readonly=on`** — even if something does force a mount anyway, ordinary
  POSIX writes into it are refused (`zfs receive` itself still works at the
  ZFS layer, which is the one write path that's supposed to remain open).

The word LOCAL is load-bearing. A ZFS property carried in by a received
stream, or one that's merely inherited from a parent, can be silently
overridden by anything that later sets it a different way — including,
in the incident that motivated this write-up, an unrelated system rebuild
that happened to touch the pool's mount configuration and left the
destination's `canmount` back at whatever value the stream itself carried.
A property set with LOCAL scope (`zfs set`, not `zfs inherit`, and not
whatever a `zfs receive` stream brings with it) always wins over anything
non-local, which is exactly the property this fix depends on.

Setting both once is not sufficient on its own, because "once" only
guarantees the state at the moment it was set — and the whole point is that
something else, later, might change it again. The fix that actually holds
is: set both LOCALLY, unmount explicitly if currently mounted, and
re-verify + re-apply all three on a schedule (plus once at boot, the moment
most likely to have reverted them) — so that no single event, however it
happens, can leave a receive destination in the mountable state for longer
than one enforcement cycle.

## Trade-offs

- **Not prevention at the ZFS-permissions level.** `readonly=on` blocks
  ordinary file writes; it does not prevent a determined `zfs set
  readonly=off` by someone with the privilege to run it. The enforcement
  timer catches and reverts that on its next tick, but there is a window.
- **Detection is not instant.** Between the moment something flips a
  property and the next enforcement tick, the destination is briefly
  vulnerable again. A short enforcement interval narrows that window; it
  cannot close it to zero without becoming its own event-driven watcher.
- **The recovery, when this does happen anyway, is cheap but not free.**
  A spurious "modified since most recent snapshot" refusal is fixed with
  one forced re-sync of that one dataset, not a restore — but it does need
  a human (or an automated bootstrap job) to notice and act, once per
  affected root.

## See also

- [`../modules/destinations.nix`](../modules/destinations.nix) — the full
  implementation and header comment this study expands on
- [`../modules/autobootstrap.nix`](../modules/autobootstrap.nix) — sets the
  same two properties on every dataset it creates, so a freshly bootstrapped
  destination starts life already compliant
- [`../examples/configuration.nix`](../examples/configuration.nix) — a
  complete example wiring the enforcement module into a real host
