# Development

[Back to the product](../README.md) | [English overview](../README.en.md)

## Build from source

Requires an Apple silicon Mac, macOS 14 or later, and Apple Command Line Tools.

```sh
git clone https://github.com/woniuniuniu/open-bar.git
cd open-bar
./build.sh
```

The build runs the core checks, compiles an arm64 release, packages the app and verifies its signature. The ZIP is written to `build/`. Temporary build products stay outside the repository to avoid cloud-sync metadata affecting signatures.

```sh
swift run OpenBarCoreChecks
swift build
```

For local installation, `./install-local.sh` replaces existing OPEN BAR / Open Notch app bundles and opens the installed app. It preserves the application-support data. Read the script before using it with a custom installation.

## Project layout

| Directory | Responsibility |
| --- | --- |
| `Sources/OpenBarCore` | Identity, policies and local arrangement rules |
| `Sources/OpenBar/Application` | App lifecycle, persistence and native controls |
| `Sources/OpenBar/Infrastructure` | Menu bar discovery and system adapters |
| `Sources/OpenBar/UI` | SwiftUI interface |
| `Tests/OpenBarCoreChecks` | Core checks |

macOS 14-26 uses WindowServer and Accessibility; macOS 27 uses a separate MenuBarAgent adapter. Some system integrations depend on private runtime interfaces and may change between OS releases. On macOS 27, visibility is applied per application and native horizontal ordering is left to macOS.

## Distribution

The current release ZIP is ad-hoc signed and is not Apple notarized. For public Developer ID distribution, set `OPEN_BAR_SIGN_IDENTITY` to a valid Developer ID Application identity and complete Apple notarization separately. The build script does not notarize the app.

## Reporting a problem

Include the app version, macOS version, what you expected, what happened, and whether you use multiple displays or another menu bar manager. Redact personal information before sharing diagnostics.
