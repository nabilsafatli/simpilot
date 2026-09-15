# Phase 0 findings

Captured 2026-09-13 on macOS 26.6.2, Xcode 26.6 (17F113), Swift 6.3.3.

These findings are the reason several models depart from the original brief. The
capture machine had **one runtime, one platform, no unavailable devices and no
pairs** — it is close to the least representative machine possible, which is why
the test corpus is fixture-driven rather than built from live state.

## Boot and usage history is reported, not inferred

The brief assumed `simctl` exposes no usage history and planned a filesystem-mtime
proxy. It does expose it:

| Field | Command | Notes |
|---|---|---|
| `lastBootedAt` | `simctl list devices --json` | Absent entirely on never-booted devices |
| `lastUsage` | `simctl list runtimes --json` | Per-architecture map |
| `lastUsedAt` | `simctl runtime list --json` | Flat timestamp |

`lastBootedAt` is persisted in each device's `device.plist`. On the capture
machine, 2 of 11 devices had it.

**Consequence:** "never booted" is stated as fact. The *recommendation* built on
it stays medium confidence, because a developer may legitimately keep an unbooted
device for a future test matrix. The evidence is certain; the conclusion is not.

## Runtimes need two commands joined

- `simctl list runtimes --json` — identity, version, availability, platform. **No UUID.**
- `simctl runtime list --json` — UUID-keyed, with `sizeBytes`, `deletable`, `state`, `mountPath`.

Neither alone suffices, so `SimulatorRuntime.id` is the runtime identifier string
and the deletion UUID is a separate optional field. A runtime present only in the
first command has no deletable image.

`deletable` is simctl's own flag and is never inferred from age, size or version.

`simctl runtime list` returns a **bare** top-level dictionary with no wrapper
object, so any unrecognised sibling key would break ordinary decoding. Decoding is
lenient per-entry; a skipped entry degrades to "not deletable", which is the safe
direction.

## Runtimes live outside the scanned tree

```
~/Library/Developer/CoreSimulator/     Devices 7.2G, Caches, Temp      (user)
/Library/Developer/CoreSimulator/      Volumes/, Images/, Cryptex/     (root)
/System/Library/AssetsV2/...           the actual 8.5 GB runtime .dmg
~/Library/Logs/CoreSimulator/<UUID>/   per-device logs                 (separate tree)
```

A scanner pointed only at the user directory reports 7.2 GB and misses the single
largest reclaimable item on the machine. Runtime sizes therefore come from
`simctl`, not from any walk.

## `dataPathSize` is a stale cache

| Device | `dataPathSize` | Measured | Delta |
|---|---|---|---|
| iPhone 17 Pro | 2.527 GB | 2.829 GB | +12.0% |
| iPhone 17 | 4.381 GB | 4.776 GB | +9.0% |
| 9 never-booted | 0.018 GB | 0.018 GB | 0.0% |

Not an apparent-vs-allocated artifact: apparent size was 2.810 GB, still above
simctl's figure. It is a snapshot written at boot/shutdown. Exact for never-booted
devices, which are byte-identical at 18,337,792 — the fresh-device baseline.

A full walk of the 7.2 GB tree took **0.63s** against simctl's 0.087s, so measuring
is affordable. Both figures are retained so the UI can explain a discrepancy rather
than silently disagree with the command line.

## Sizes are estimates for a real reason

`simctl runtime add --help` states images are cloned where possible so no
additional disk space is used. APFS cloning means deleting a target can free less
than its reported size. This is why cleanup must report *measured* recovery from a
re-scan rather than echoing a prediction.

## Layout hazards

- `Devices/device_set.plist` is a **file** among the UUID directories — skip it.
- Device directories hold siblings next to `data/` (e.g. `datacom.apple.modelcatalog`),
  so the device total exceeds `dataPath` alone.
- 22 of 24 log directories on the capture machine had no live device. There is no
  simctl command to remove these, so they are **reported and never deleted**.

## Safety findings

- **Pairs exist.** `simctl list pairs --json` returned `{"pairs":{}}` only because
  no watchOS runtime was installed. Deleting either half of a pair breaks it, and
  nothing in a device's own listing reveals the relationship.
- **simctl requires full Xcode.** There is no `simctl` in
  `/Library/Developer/CommandLineTools`. "No usable Xcode" is a real first-run
  state, not an edge case.
- **`simctl list devices` includes unavailable devices by default**; `available` is
  an opt-in filter (`simctl help list`).
- **Native dry run exists**: `simctl runtime delete --dry-run` and
  `--notUsedSinceDays <n>`.
- **`simctl --set <path>` gives a fully isolated device set.** A device was created
  and deleted in a throwaway set with the real 11-device set verifiably untouched.
  Destructive paths can be integration-tested for real. The directory must exist
  first; simctl will not create it.

## Unverified

The JSON shape of an **unavailable device** could not be captured — the machine had
none. `isAvailable` was verified present on every device in every capture, so
Rule A keys off that, and `availabilityError` is treated as an optional
display-only string. The corresponding fixture is hand-built and labelled as such.

## Distribution constraint

The app ships **Developer ID–signed and notarized, outside the App Sandbox**. A
sandboxed process cannot spawn `xcrun` nor read `~/Library/Developer/CoreSimulator`,
so the Mac App Store is not a viable target without dropping core functionality.
