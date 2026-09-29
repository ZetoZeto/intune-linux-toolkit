#!/usr/bin/env bash
# =============================================================================
#  install-autosync.sh - silent Intune auto-sync for Ubuntu
#
#  Lays down three system files that make intune-agent sync silently in the
#  background, then enables the timer globally so accounts created later inherit
#  it. Idempotent. Run as root. See README.md for the full rationale.
#
#  Target : Ubuntu 22.04 / 24.04, GNOME, systemd, intune-portal installed.
# =============================================================================
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (sudo ./install-autosync.sh)." >&2
    exit 1
fi

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/etc"

install_file() {
    local rel="$1"                      # path relative to etc/
    local dst="/etc/${rel}"
    install -D -m 0644 "${SRC}/${rel}" "${dst}"
    echo "  installed ${dst}"
}

echo "== Installing Intune auto-sync files =="
install_file "systemd/user/intune-agent.timer.d/override.conf"    # cadence
install_file "systemd/user/intune-agent.service.d/override.conf"  # STATE_DIRECTORY fix
install_file "polkit-1/rules.d/50-intune.rules"                   # no password prompt

echo "== Reloading systemd and enabling the timer globally =="
# --global enable places the activation link so accounts created afterwards inherit it.
systemctl --global enable intune-agent.timer || true

echo
echo "== Done. Verify inside a graphical session: =="
echo "   systemctl --user daemon-reload"
echo "   systemctl --user restart intune-agent.timer"
echo "   systemctl --user list-timers | grep intune          # NEXT ~10-12 min"
echo "   systemctl --user start intune-agent.service"
echo "   journalctl --user -u intune-agent.service --since '2 min ago' | grep -iE 'login succeeded|policy_count|cannot checkin'"
echo
echo "Expected after enrollment: 'Login succeeded' then 'policy_count=N', no window, no password prompt."
