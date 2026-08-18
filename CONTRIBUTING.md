# Contributing

Thanks for helping improve Open Notch.

## Before you start

- Read the GPL-3.0 license and [`NOTICE.md`](NOTICE.md).
- Search existing issues before opening a new one.
- Never include Accessibility dumps, screenshots, user data, credentials, or
  machine-specific paths in a commit.

## Development

Run `./build.sh` on an Apple silicon Mac with macOS 14 or later. Test changes
with a clean Accessibility permission state when they touch discovery or move
behavior. Keep read-only discovery separate from input-event code, and avoid
adding network access or telemetry.

## Pull requests

Describe the user-visible behavior, the macOS versions tested, and the checks
you ran. Keep pull requests focused and include regression tests or a manual
verification checklist for behavior changes.
