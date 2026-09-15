# Simpilot

A macOS app that explains what Xcode's simulators cost you in disk space, and
helps you decide what to do about it.

**Beta.** Version 0.1, macOS 14 or later.

## What it is, and isn't

Simpilot is not a disk cleaner. It is a decision-support tool, and the
difference shows up everywhere in the design:

- Every suggestion carries its reasoning, separated into what `simctl` actually
  reported and what Simpilot inferred from it.
- Nothing is removed without confirmation on a screen that names the exact
  target and lists what will **not** be touched.
- Sizes are labelled as estimates, because they are: macOS shares disk blocks
  between cloned files, so removing something can free less than it appears to
  occupy. Recovered space is measured by re-scanning afterwards, never by
  repeating the prediction back to you.
- Every figure and action can reveal the `simctl` command behind it. The app
  exists because reaching these answers by hand is tedious, not because the
  answers should be hidden.

On the machine it was developed on, it declines to suggest the two largest
consumers of disk space, because both are in active use.

## What it looks at

Simulator devices, runtimes, their storage, and the log directories that outlive
deleted devices. Nothing else — not DerivedData, not package manager caches, not
Docker. All state is read through `xcrun simctl --json`, and every destructive
action goes through `simctl` too. Simpilot never deletes simulator data by any
other means.

## Requirements

Xcode is required, not merely the Command Line Tools: `simctl` ships only with
the full Xcode installation.

## Building

```
swift test                     # the whole correctness suite, headless, no Xcode project
open Simpilot/Simpilot.xcodeproj
```

Copy `Simpilot/Config/Local.xcconfig.example` to `Local.xcconfig` and set your
`DEVELOPMENT_TEAM` before building the app target. The app must **not** be
sandboxed — a sandboxed process can spawn neither `xcrun` nor read
`~/Library/Developer/CoreSimulator`, and would show an empty inventory with no
visible error.

See `docs/releasing.md` for signing, notarization and updates, and
`docs/phase-0-findings.md` for what investigating `simctl` actually turned up —
including several things its documentation does not tell you.

## Contributing

Contributions are welcome. A few things worth knowing before you start:

**Tests are fixture-driven on purpose.** No single machine exhibits the states
that matter — the development machine has one runtime, one platform and no
unavailable devices. Correctness is proven against recorded and hand-built
`simctl` output in `Tests/SimulatorManagerKitTests/Fixtures/`. Captured fixtures
are kept verbatim; hand-built ones declare what was invented; the integrity
suite enforces both.

**The recommendation engine is deterministic and contains no model calls.** A
suggestion that cannot be reproduced from a fixture cannot be explained to a
user or verified by a test. Please keep it that way.

**Restraint is a feature.** Confidence merges as a maximum rather than a sum, so
weak signals cannot accumulate into apparent certainty. Size alone never
justifies deleting anything. Duplicates and older runtimes produce reviews, not
deletions. If a change makes Simpilot more aggressive, it needs a good argument.

## Licence

GPL-3.0-or-later. See [LICENSE](LICENSE).

You may use, study, modify and share this. If you distribute a modified version,
you must release its source under the same licence — so improvements stay
available to everyone who receives them.
