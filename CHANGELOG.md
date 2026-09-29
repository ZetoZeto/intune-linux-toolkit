# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.1.0] - 2026-09-29

Initial public release.

### Added

- **linux-autosync/** - silent Intune auto-sync for Ubuntu: systemd timer + service drop-ins and a
  polkit rule, laid down under `/etc` and enabled globally so accounts created later inherit it, plus
  an idempotent installer. Removes the manual *open portal -> Synchronize -> password* gesture.
- **linux-enrollment-troubleshooting/** - write-up of the "fresh Linux registrations never complete
  MDM enrollment" case, a read-only Graph diagnostic (`Diagnose-Compliance.ps1`), a clean
  re-enrollment runbook, a full teardown/reinstall script (`fresh-reinstall.sh`) and a ready-to-fill
  Microsoft support case template.
- **windows-sync/** - on-demand Intune and Defender/MDE sync helpers, and a SYSTEM scheduled-task
  deployer for weekly `winget upgrade --all`.
- Project scaffolding: MIT license, contributing guide, security policy, code of conduct, issue and
  PR templates.

### Notes

- The `intune-agent.service` drop-in now clears the `StateDirectory=` directive (not just the
  environment variable), which fixes **both** documented `STATE_DIRECTORY` failure modes: the agent
  dying in `238/STATE_DIRECTORY` before exec, and the agent reading its registration from the wrong
  (empty) state directory.
