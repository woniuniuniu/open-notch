# Open Notch

Open Notch is an open-source macOS menu bar manager with a OneDrive-aware
layout guardian. It uses native AppKit and SwiftUI, keeps the menu bar stable
when hosted status items are rebuilt, and provides a status item menu for
expand, scan, restart, settings, and quit actions.

The app defaults to English and can be switched to Simplified Chinese from
General settings. Light and Dark appearance modes apply to both the settings
window and the status item menu.

## Requirements

- Apple silicon Mac
- macOS 14 or later (macOS 26 is supported)
- Accessibility access for Open Notch in System Settings > Privacy & Security
  > Accessibility

Open Notch is not affiliated with Apple, Bartender, Ice, Microsoft, or
OneDrive. Apple, macOS, OneDrive, Bartender, and Ice are trademarks or
projects of their respective owners.

## Install

Clone this repository, run the build script below, move `build/Open Notch.app`
to `/Applications`, and launch it. Grant Accessibility access when prompted.
Do not run Ice, Bartender, or another menu bar manager at the same time; those
tools can move each other's status items.

## Build locally

The project uses the Apple Command Line Tools and does not require a full Xcode
project:

```zsh
./build.sh
```

The script creates `build/Open Notch.app` and `build/Open Notch.zip`. The app is
ad-hoc signed for local testing. A Developer ID signature and notarization are
required for distribution outside a development machine.

## How it works

macOS does not expose a public API for rearranging another process's status
items. When a move is required, Open Notch performs one bounded, native-style
Command-drag transaction through the Accessibility API. Read-only discovery and
the continuous monitor never synthesize mouse movement. The layout reconciler
requires a stable observation before it requests a move, and the move engine
defers while the user is interacting with the mouse or keyboard.

On macOS 26, OneDrive status items can be hosted by Control Center and can
temporarily lose their Accessibility identity. Open Notch matches the semantic
OneDrive bundle identifier, live geometry, and persisted window bindings so the
policy follows the logical item rather than a transient window number or
`Item-0` title. Anonymous Control Center windows are not exposed as manageable
items.

## Privacy

Open Notch does not make network requests or collect analytics. Accessibility is
used only to inspect menu bar items and perform the explicit Command-drag
transactions described above. Preferences and identity bindings stay in the
local `UserDefaults` store.

## License and acknowledgements

Open Notch is licensed under the GNU General Public License v3.0; see
[`LICENSE`](LICENSE). The hosted status-item event-routing compatibility layer
is derived from the event-routing mechanism in [Ice](https://github.com/jordanbaird/Ice),
which is also GPL-3.0. See [`NOTICE.md`](NOTICE.md) for attribution details.

Contributions are welcome. Please read [`CONTRIBUTING.md`](CONTRIBUTING.md)
before opening an issue or pull request.
