# Security Policy

## Supported versions

Security fixes go into the latest release only. Update to it from the Mac App Store, or with
`brew upgrade --cask inputconfig` for the Homebrew copy.

| Version | Supported |
| ------- | --------- |
| 1.6     | Yes       |
| 1.5 and earlier | No |

## Reporting a vulnerability

Please report security issues privately, not in a public issue.

1. Open the [Security tab](https://github.com/ryleighnewman/InputConfig/security) of this repository.
2. Choose **Report a vulnerability** and describe the issue, the version, your macOS version, and the steps to reproduce it.

If you cannot use GitHub, reach out through [ryleighnewman.com](https://ryleighnewman.com).

You can expect a first reply within 7 days. Confirmed issues are fixed in the next release, and
the report is credited in the release notes unless you would rather stay anonymous.

## Scope

InputConfig runs in the App Sandbox, collects no data, and makes no network requests of its own
(see [PRIVACY.md](PRIVACY.md)). Reports that are most useful include anything that lets a preset
file, a MIDI or HID device, or another app make InputConfig send input it was not set up to send,
or escape the sandbox.
