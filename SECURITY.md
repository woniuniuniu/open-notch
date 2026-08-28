# Security Policy

## Supported versions

Only the latest tagged release and the default branch are actively maintained.

## Reporting a vulnerability

Please do not open a public issue for a security vulnerability. Use GitHub's
private vulnerability reporting for this repository when it is enabled, or
contact the maintainers privately through the address listed on their GitHub
profile. Include the affected version, macOS version, reproduction steps, and
any relevant logs with personal data removed.

Open Notch does not collect analytics or telemetry. Ordinary menu bar
management is local. The optional AI Organizer makes a network request only
after the user clicks Generate; it sends an anonymous installation ID, app
language, time-zone offset, hardware model identifier, display geometry,
macOS version, and each scanned item's name, bundle identifier, and visible
state to the Open Notch service. Recommendation context is processed by
DeepSeek. It does not send device serial numbers, screen contents, usernames,
or file paths.

Reports about unexpected pointer or menu bar behavior should include whether
another menu bar manager was running at the same time. Do not attach an
unredacted debug report to a public issue.
