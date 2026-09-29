# Windows — Intune / MDE sync helpers & winget patch task

Three small, self-contained PowerShell helpers for a Windows 10/11 estate managed by Intune +
Defender for Business.

| Script | What it does | Run as |
|---|---|---|
| `Sync-Intune.ps1` | Forces an immediate check-in: restarts the MDM (`EnterpriseMgmt`) scheduled tasks **and** the Intune Management Extension (IME) for apps/scripts. | Admin |
| `Sync-MDE.ps1` | Updates Defender signatures and pushes the Defender/TVM telemetry + software inventory to the portal. | Admin |
| `Deploy-WingetUpdateTask.ps1` | Deploys a hidden SYSTEM scheduled task that runs `winget upgrade --all` weekly, with logging. Meant to be pushed as an **Intune Platform Script** (Run as SYSTEM = Yes, 64-bit = Yes). | SYSTEM (via Intune) |

## Sync-Intune.ps1

Handy when you've just assigned a policy or app and don't want to wait for the natural polling cycle
(~1 h, up to 8 h for Win32 apps). It reproduces what the **Settings → Accounts → Access work or
school → Info → Sync** button does, plus an IME restart that the button does not do.

```powershell
# From an elevated PowerShell
.\Sync-Intune.ps1
```

## Sync-MDE.ps1

Refreshes Defender signatures and forces the diagnostic/telemetry upload so that the software
inventory (used by threat & vulnerability management) is reported without waiting for the daily cycle.

```powershell
.\Sync-MDE.ps1
```

## Deploy-WingetUpdateTask.ps1

Rather than relying on each vendor's own updater, this installs a single, logged, SYSTEM-context
`winget upgrade --all` job. It writes the runner script to `C:\ProgramData\IntuneWingetUpdate\`,
registers a weekly scheduled task (Wednesday 03:00 by default), and is **idempotent** (re-running it
replaces the task).

**Deploy via Intune** — *Devices → Scripts and remediations → Platform scripts*:

- Run this script using the logged-on credentials: **No**
- Enforce script signature check: **No**
- Run script in 64-bit PowerShell: **Yes**

Logs land in `C:\ProgramData\IntuneWingetUpdate\` (`deploy.log`, `winget-upgrade.log`).

> **Tuning ideas**: change the trigger day/time in `New-ScheduledTaskTrigger`, or narrow the update
> scope with `winget upgrade <id>` + a pinned list instead of `--all`. `--include-unknown` upgrades
> packages whose installed version winget cannot detect — drop it if you want to be conservative.
