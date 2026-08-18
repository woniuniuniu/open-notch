# Notices and acknowledgements

Open Notch is an independent GPL-3.0 project. It is not affiliated with Apple,
Bartender, Ice, Microsoft, or OneDrive. Those names and marks belong to their
respective owners.

The hosted-status-item event routing compatibility layer in Open Notch is
derived from the event routing mechanism in Ice:

- Ice: https://github.com/jordanbaird/Ice
- Ice license: GNU General Public License v3.0
- Ice copyright: Copyright (C) 2024-2025 Jordan Baird
- Upstream source: `Ice/MenuBar/MenuBarItems/MenuBarItemManager.swift`

Open Notch's `Sources/TargetedEventRouter.swift` is a modified implementation
of that event-routing mechanism. It was adapted for Open Notch in 2026 and is
distributed under GPL-3.0-only.

The OneDrive semantic-to-host-window matching, discovery heuristics, layout
reconciler, and move engine were written for Open Notch. The complete Open
Notch source is distributed under GPL-3.0. Ice's license and copyright notices
remain applicable to the portions derived from Ice.
