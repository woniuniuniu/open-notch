# Notices and acknowledgements

Open Notch is an independent project released under the GNU General Public
License v3.0-only (GPL-3.0-only). It is not affiliated with Apple, Bartender,
Ice, Microsoft, or OneDrive. Their names, products, and marks belong to their
respective owners.

## Ice-derived event routing

The hosted-status-item event-routing compatibility layer in Open Notch is
derived from the event-routing mechanism in Ice:

- Repository: https://github.com/jordanbaird/Ice
- License: GNU General Public License v3.0
- Copyright: Copyright (C) 2024-2025 Jordan Baird
- Upstream source: `Ice/MenuBar/MenuBarItems/MenuBarItemManager.swift`
- Local derivative: `Sources/TargetedEventRouter.swift`

`Sources/TargetedEventRouter.swift` was adapted for Open Notch in 2026 and is
distributed under GPL-3.0-only. The Ice copyright and license notices remain
applicable to the derived portion. Redistributors and derivative works must
preserve this attribution, mark their modifications and dates, and provide the
corresponding source under the GPL-3.0 terms.

## Ice and Thaw-derived WindowServer compatibility

The experimental macOS 27 menu bar window enumeration bridge is adapted from
the WindowServer bridging and enumeration techniques used by Ice and Thaw:

- Ice repository: https://github.com/jordanbaird/Ice
- Ice copyright: Copyright (C) 2023-2025 Jordan Baird
- Thaw repository: https://github.com/thaw-app/Thaw
- Thaw copyright: Copyright (C) 2026 Toni Forster and Thaw contributors
- License: GNU General Public License v3.0
- Local derivative: `Sources/WindowServerBridge.swift`

The bridge was adapted for Open Notch in 2026 and is distributed under
GPL-3.0-only. It uses undocumented WindowServer symbols and is provided as an
experimental compatibility path; Apple may change these symbols during macOS
beta releases.

## Open Notch work

The OneDrive semantic-to-host-window matching, discovery heuristics, layout
reconciler, move engine, SwiftUI/AppKit interface, localization, and build
scripts were written for Open Notch. The complete Open Notch source is
distributed under GPL-3.0-only.

Bartender is proprietary software and is referenced only as product inspiration.
No Bartender source code or proprietary asset is included in this repository.

## macOS 27 MenuBarAgent compatibility

The macOS 27 Accessibility inventory and MenuBarAgent compatibility path in
`Sources/MenuBarAgentBridge.swift` was independently implemented for Open
Notch from runtime inspection of the operating system. It uses undocumented
Apple frameworks and selectors, contains no Apple source code, and is provided
under GPL-3.0-only. Apple may change or remove this compatibility path in later
macOS releases.
