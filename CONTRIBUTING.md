# Contributing

Thanks for considering a contribution. This project is a set of **field-tested helpers and
diagnostics** for Microsoft Intune on a mixed Windows / Linux estate - not a product. The most
valuable contributions are usually not code but **corroboration**: telling us which Ubuntu release
and which Intune client version reproduce (or don't reproduce) a given behaviour.

## Before you open anything

Read [SECURITY.md](SECURITY.md) first. The diagnostic scripts here produce output that contains
**tenant IDs, hostnames, UPNs, device IDs and `activity_id` values**. Never paste that into a public
issue, PR, or commit. Redact to placeholders (`example.com`, `00000000-0000-0000-0000-000000000000`,
`linux-test`) before sharing anything.

## Kinds of contributions we want

- **Environment reports.** "On Ubuntu 24.04.4 with `intune-portal 1.26xx` / broker `3.0.x`, the
  `STATE_DIRECTORY` fix behaves like *mode 1 / mode 2*." These build the compatibility picture that
  no official doc provides.
- **Bug fixes** to the scripts (idempotence, edge cases, distro differences).
- **Documentation** corrections - especially if a step is wrong on a release we haven't tested.
- **New helpers** that fit the scope: making Intune on Linux less painful, safely.

## Ground rules for code

- **Shell scripts** (`*.sh`): target `bash`, `set -euo pipefail` (or a documented reason not to),
  keep them **idempotent** and safe to re-run. Anything destructive must be scoped by an allowlist
  and must no-op when the target is absent - see `fresh-reinstall.sh` for the expected bar.
- **PowerShell** (`*.ps1`): PowerShell 5.1-compatible unless the script header says 7+. Diagnostic
  scripts stay **read-only** (Graph read scopes only) unless their name says otherwise.
- **systemd / polkit** drop-ins live under `etc/` mirroring their real path, never edit vendor units.
- Keep line endings **LF** (enforced by `.gitattributes`). A CRLF shebang breaks a shell script.
- No secrets, no real identifiers, no organization names anywhere - including in comments and
  example output.

## Workflow

1. Fork and branch from `main` (`feature/...` or `fix/...`).
2. Test on a real or throwaway Ubuntu / Windows machine - say which in the PR.
3. Run `shellcheck` on any changed `.sh` if you have it.
4. Open a PR describing **what you tested it on** (OS version, client version) and what changed.

We review for correctness and safety first; a PR that could destroy a working enrollment or leak an
identifier will be asked to change before merge.
