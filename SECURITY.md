# Security & privacy

This repository contains **diagnostic and remediation tooling** for Microsoft Intune. Two concerns
matter here: not leaking your own data, and reporting genuine vulnerabilities responsibly.

## Do not leak your own data

The scripts in this repo - especially `Diagnose-Compliance.ps1` and `fresh-reinstall.sh` - produce
output that **identifies your tenant and your machines**:

- tenant ID, scale unit
- hostnames, UPNs / email addresses
- Entra `deviceId`, Intune `device_id`, `azureADDeviceId`
- `activity_id` values, serial numbers, machine IDs
- IP addresses in logs

**Never** paste this into a public GitHub issue, pull request, discussion, or commit. The diagnostic
transcript files (`diag-compliance-*.txt`, `*.log`) are already covered by [`.gitignore`](.gitignore)
so they cannot be committed by accident - do not force them in.

When you need to share output to illustrate a problem, redact to the project's placeholder
conventions first:

| Real value | Placeholder |
|---|---|
| tenant / device GUID | `00000000-0000-0000-0000-000000000000` |
| hostname | `linux-test`, `linux-a` ... |
| domain / UPN | `user@example.com` |
| scale unit | `<SCALE_UNIT>` |

## Reporting a vulnerability

If you believe one of the scripts here does something unsafe (e.g. removes more than its documented
scope, exposes a secret, or a polkit / systemd drop-in widens privilege beyond what's described),
please report it **privately** rather than opening a public issue:

- Open a [GitHub Security Advisory](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)
  on this repository ("Report a vulnerability"), or
- Contact the maintainer through their GitHub profile.

Please include the affected file, the OS / client version, and a minimal description of the impact.
There is no bounty - this is a community toolkit - but fixes for safety issues are prioritized.

## Scope note

These scripts are provided under the MIT license **without warranty**. They act on device management
state that is hard to reverse (enrollment, identity, keyring secrets). Read a script before running
it, prefer `--dry-run` where offered, and test on a throwaway machine first.
