# Intune Linux Toolkit - silent auto-sync, enrollment troubleshooting & Windows sync helpers

[![lint](https://github.com/ZetoZeto/intune-linux-toolkit/actions/workflows/lint.yml/badge.svg)](https://github.com/ZetoZeto/intune-linux-toolkit/actions/workflows/lint.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform: Ubuntu 22.04 / 24.04](https://img.shields.io/badge/Ubuntu-22.04%20%7C%2024.04-E95420?logo=ubuntu&logoColor=white)](#requirements)
[![Platform: Windows 10 / 11](https://img.shields.io/badge/Windows-10%20%7C%2011-0078D6?logo=windows&logoColor=white)](#requirements)
[![Shell: Bash + PowerShell](https://img.shields.io/badge/shell-bash%20%2B%20PowerShell-4EAA25.svg)](#layout)
[![PRs welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](CONTRIBUTING.md)

A field-tested toolkit for **Microsoft Intune** administrators managing a **mixed Windows / Linux
(Ubuntu) estate** under **Microsoft 365 Business Premium** (Intune Plan 1, Defender for Business,
Entra ID P1).

It gathers three things that are poorly documented elsewhere:

1. **Windows** - on-demand sync helpers (MDM policies, IME apps/scripts, Defender/MDE inventory) and
   a SYSTEM scheduled task that keeps the estate patched with `winget`.
2. **Linux** - a **silent Intune auto-sync** setup that removes the manual *"open portal -> click
   Synchronize -> type password"* gesture, including the **undocumented `STATE_DIRECTORY` bug fix**
   without which the background agent never checks in.
3. **Linux enrollment troubleshooting** - a full diagnostic + re-enrollment runbook for the case
   where fresh Linux registrations silently fail to complete MDM enrollment, plus a Graph-based
   diagnostic script and a ready-to-fill support case.

> **Scope & honesty.** These are helpers and diagnostics, not a product. Everything here was written
> and validated against a real estate of ~20 Windows and ~15 Ubuntu 24.04 endpoints. Paths, package
> versions and behaviours reflect Ubuntu 24.04 + Intune client `1.26xx` and Windows 11 Pro as of
> mid-2026 - verify against your own version before relying on them.

## Layout

| Folder | What's inside |
|---|---|
| [`windows-sync/`](windows-sync/) | `Sync-Intune.ps1`, `Sync-MDE.ps1`, `Deploy-WingetUpdateTask.ps1` |
| [`linux-autosync/`](linux-autosync/) | systemd drop-ins + polkit rule + installer for silent Intune sync |
| [`linux-enrollment-troubleshooting/`](linux-enrollment-troubleshooting/) | problem write-up, Graph diagnostic, re-enrollment runbook, fresh reinstall script, support case template |

## Requirements

- **Windows helpers**: Windows 10/11, PowerShell 5.1+, admin/SYSTEM context for the scheduled task.
- **Linux auto-sync**: Ubuntu 22.04/24.04 (GNOME, systemd), `intune-portal` package installed, root
  access to write under `/etc`.
- **Graph diagnostic**: PowerShell 7+, `Microsoft.Graph` module, an account able to consent to the
  read-only scopes listed in the script.

## A note on the `STATE_DIRECTORY` bug (the reason this repo exists)

On several Intune Linux client builds, `intune-agent.service` ships with `StateDirectory=intune`.
Depending on the build this breaks the background agent in one of two ways: either it dies in
`status=238/STATE_DIRECTORY` **before it starts** (systemd cannot provision `~/.local/state` for a
user unit), or it starts but reads its registration from the empty `$STATE_DIRECTORY` instead of
`~/.config/intune/registration.toml` and refuses to check in with:

```
Skipping checkin with Intune: Cannot checkin before a user logs in
```

The portal syncs fine when opened manually, but the **background timer never does**. The fix is a
systemd drop-in that clears the `StateDirectory=` directive (not just the env var) and relaunches the
binary with `env -u STATE_DIRECTORY` - see [`linux-autosync/`](linux-autosync/).

## Contributing & security

- Bug reports, environment reports (which Ubuntu / client version reproduces what) and PRs are
  welcome - see [CONTRIBUTING.md](CONTRIBUTING.md).
- Please read [SECURITY.md](SECURITY.md) before opening an issue: **never paste diagnostic output,
  logs, tenant IDs, hostnames or UPNs** into a public issue.

## License

MIT - see [LICENSE](LICENSE).

---

*Sanitized for public release: no organization name, tenant ID, hostname, serial, device ID or
secret. Placeholder values (`example.com`, `00000000-...`, `linux-test`) are meant to be replaced.*
