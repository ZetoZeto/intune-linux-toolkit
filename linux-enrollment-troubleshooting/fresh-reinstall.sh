#!/usr/bin/env bash
#
# fresh-reinstall.sh - TOTAL reset then clean reinstall of the Intune client,
# the Microsoft identity broker and Microsoft Edge on Ubuntu.
#
# Purpose: start from scratch on BOTH tools (Intune + Edge) to determine whether
# they cause the HTTP 500 on LinuxDeviceCheckinService. Nothing is kept:
# packages, systemd units, local state, profiles, CACHES, keyring secrets,
# cached .deb in apt, Edge enterprise policies.
#
# Usage:
#   ./fresh-reinstall.sh wipe        # full purge (the bulk of the work)
#   sudo reboot
#   ./fresh-reinstall.sh install     # clean reinstall of both tools
#   sudo reboot                      # then open Company Portal and sign in
#   ./fresh-reinstall.sh check       # ~10 min later: the 6 gates
#
# Options:
#   --only-intune        Leave Edge alone (Intune + broker only).
#   --only-edge          Leave Intune/broker alone (Edge only).
#   --no-backup          (wipe) Do not back up the Edge profile before removal.
#   --include-chromium-safe-storage
#                        (wipe) Also delete a keyring entry named
#                        ' Chromium/Chrome Safe Storage '. Default NO: it may
#                        belong to Chrome or Chromium, not to Edge.
#   --allow-locked-keyring
#                        (wipe) Continue despite a locked keyring. AVOID this:
#                        it is exactly the scenario that produced the false
#                        TOTAL=0 success.
#   --pkg-version V      (install) Exact intune-portal version, downgrade allowed.
#   --broker-version V   (install) Exact microsoft-identity-broker version, downgrade
#                        allowed. The broker is what writes operatingSystemVersion into
#                        the Entra object: a lever to test if that field comes out
#                        malformed (e.g. 'Ubuntu+24.04.4+LTS' instead of '24.04').
#                        Versions: apt-cache madison microsoft-identity-broker
#   --hold / --unhold    (install) Pin / unpin intune-portal AND the broker (apt-mark).
#   --dry-run            Print the actions without executing anything.
#   --yes | -y           No interactive confirmation (required when not a TTY).
#   --log FILE           Log file (default: ~/fresh-reinstall-<timestamp>.log)
#   -h | --help
#
# MANDATORY PREREQUISITE FOR `wipe`: a LOCAL graphical session (never SSH), the
# ' Login ' keyring UNLOCKED. The script refuses to continue otherwise, and treats
# TOTAL=0 as a blocking error when the packages are installed.
#
# WHAT THIS SCRIPT NEVER DOES:
#   - no `apt autoremove`
#   - no removal of the whole ~/.local/share/keyrings/
#   - no removal of a secret outside the Intune / broker / Edge patterns
#   - no change to machine-id, GDM, auto-login, network, ~/.pki
#   - no automatic reboot
#   - no removal of a path whose name is outside the allowlist
#
# If the file was copied from Windows:
#   sed -i 's/\r$//' fresh-reinstall.sh && chmod +x fresh-reinstall.sh
#

set -uo pipefail

# ---------------------------------------------------------------------------
# Scope: closed lists. Do not widen without review.
# ---------------------------------------------------------------------------

INTUNE_PKGS=(intune-portal)
BROKER_PKGS=(microsoft-identity-broker)
EDGE_PKGS=(microsoft-edge-stable microsoft-edge-beta microsoft-edge-dev)

INTUNE_USER_DIRS=(
  "$HOME/.config/intune"
  "$HOME/.local/share/intune"
  "$HOME/.local/state/intune"
  "$HOME/.cache/intune"
)
INTUNE_SYS_DIRS=(
  /var/opt/microsoft/intune
  /opt/microsoft/intune
)
BROKER_USER_DIRS=(
  "$HOME/.config/microsoft-identity-broker"
  "$HOME/.local/share/microsoft-identity-broker"
  "$HOME/.local/state/microsoft-identity-broker"
  "$HOME/.cache/microsoft-identity-broker"
)
BROKER_SYS_DIRS=(
  /var/lib/microsoft-identity-broker
  /opt/microsoft/identity-broker
  /var/opt/microsoft/identity-broker
)
EDGE_USER_DIRS=(
  "$HOME/.config/microsoft-edge"
  "$HOME/.config/microsoft-edge-beta"
  "$HOME/.config/microsoft-edge-dev"
  "$HOME/.cache/microsoft-edge"
  "$HOME/.cache/microsoft-edge-beta"
  "$HOME/.cache/microsoft-edge-dev"
  "$HOME/.local/share/microsoft-edge"
)
EDGE_SYS_DIRS=(
  /opt/microsoft/msedge
  /etc/opt/edge
)

# Defence in depth: no path whose basename is outside this list can be removed,
# even if an array above were mis-edited.
# 'intune-agent.service.d' is here: it is the systemd drop-in directory, which
# apt purge does not always remove and which must be rewritten on each install.
ALLOWED_BASENAMES='^(intune|intune-agent\.service\.d|microsoft-identity-broker|microsoft-identity-device-broker|identity-broker|microsoft-edge(-beta|-dev)?|msedge|edge)$'

# systemd unit patterns.
INTUNE_UNIT_RE='^intune[-_.a-z0-9]*\.(service|timer|socket|path)$'
BROKER_UNIT_RE='^microsoft-identity[-_a-z]*\.(service|timer|socket|path)$'

# Process patterns, based on the binary PATH: a bare ' edge ' or ' intune '
# would match anything in a command line.
PROC_PATTERNS_INTUNE=('/opt/microsoft/intune/')
PROC_PATTERNS_BROKER=('microsoft-identity-broker')
PROC_PATTERNS_EDGE=('/opt/microsoft/msedge/')

# Keyring secret patterns. Deliberately narrow: a bare ' microsoft ' would match
# Teams, OneDrive, Outlook - out of scope.
SECRET_RE_MS='intune|microsoft-identity|msal|workplace-?join|com\.microsoft\.(identity|companyportal|windowsintune)|identity-?broker|device-?registration'
SECRET_RE_EDGE='microsoft.?edge|msedge'
SECRET_RE_CHROMIUM='(chromium|chrome) safe storage'

# Required drop-in on the intune-agent unit.
# The stock unit declares StateDirectory=intune; on Ubuntu 24.04 systemd cannot
# provision ~/.local/state for a *user* unit and the agent dies in
# 238/STATE_DIRECTORY doing nothing - this is what left the Entra object
# unfinished. The drop-in shipped by the package only does an `env -u
# STATE_DIRECTORY`, which acts on the child environment only: insufficient, the
# failure happens before exec. The directive itself must be cleared.
AGENT_DROPIN_DIR=/etc/systemd/user/intune-agent.service.d
AGENT_DROPIN="$AGENT_DROPIN_DIR/override.conf"
AGENT_DROPIN_CONTENT='[Service]
StateDirectory=
ExecStart=
ExecStart=/usr/bin/env -u STATE_DIRECTORY /opt/microsoft/intune/bin/intune-agent'

# Microsoft repositories.
EDGE_REPO_LIST=/etc/apt/sources.list.d/microsoft-edge.list
MS_KEY=/usr/share/keyrings/microsoft-prod.gpg

# Already-burned identities - a re-enrollment reusing one is an immediate failure.
# Fill these with the Entra deviceIds / Intune device_ids you have already burned
# during previous wipes on this host, so the check gate can flag a recycled identity.
AAD_BURNED=()
INTUNE_BURNED=()

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

ACTION=""
SCOPE_INTUNE=true
SCOPE_EDGE=true
DO_BACKUP=true
KILL_CHROMIUM_SAFE_STORAGE=false
ALLOW_LOCKED_KEYRING=false
DRY_RUN=false
ASSUME_YES=false
PKG_VERSION=""
BROKER_VERSION=""
HOLD_PKG=false
PKG_UNHOLD=false
LOG=""

WARNINGS=()
FAILURES=()
CHANGES=0

HAD_INTUNE=false
HAD_BROKER=false
HAD_EDGE=false

OS_ID=unknown; OS_VER=unknown; OS_CODE=""

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

ts() { date '+%Y-%m-%d %H:%M:%S'; }
say()  { printf '%s\n' "$*"; }
info() { printf '%s  INFO  %s\n' "$(ts)" "$*"; }
ok()   { printf '%s  OK    %s\n' "$(ts)" "$*"; }
skip() { printf '%s  SKIP  %s\n' "$(ts)" "$*"; }
warn() { printf '%s  WARN  %s\n' "$(ts)" "$*"; WARNINGS+=("$*"); }
err()  { printf '%s  ERR   %s\n' "$(ts)" "$*"; }
fail() { printf '%s  FAIL  %s\n' "$(ts)" "$*"; FAILURES+=("$*"); }
die()  { err "$*"; printf '\nLog: %s\n' "${LOG:-none}"; sleep 0.2; exit 1; }

section() {
  printf '\n%s\n== %s\n%s\n' \
    '--------------------------------------------------------------------' \
    "$*" \
    '--------------------------------------------------------------------'
}

# Execute (or print only in --dry-run). Returns the command's exit code.
run() {
  if $DRY_RUN; then
    printf '%s  DRY   %s\n' "$(ts)" "$*"
    return 0
  fi
  printf '%s  RUN   %s\n' "$(ts)" "$*"
  "$@"
}

# Same but failure is only reported, never fatal (unit stops, kills...).
run_soft() { run "$@" || printf '%s  ..    (no effect, ignored)\n' "$(ts)"; }

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    wipe|install|check)
      [[ -n "$ACTION" ]] && { err "one action at a time (got '$ACTION' then '$1')"; exit 2; }
      ACTION="$1" ;;
    --only-intune)   SCOPE_EDGE=false ;;
    --only-edge)     SCOPE_INTUNE=false ;;
    --no-backup)     DO_BACKUP=false ;;
    --include-chromium-safe-storage) KILL_CHROMIUM_SAFE_STORAGE=true ;;
    --allow-locked-keyring)          ALLOW_LOCKED_KEYRING=true ;;
    --dry-run)       DRY_RUN=true ;;
    --yes|-y)        ASSUME_YES=true ;;
    --pkg-version)   shift; [[ $# -gt 0 ]] || { err "--pkg-version expects a version"; exit 2; }; PKG_VERSION="$1" ;;
    --broker-version) shift; [[ $# -gt 0 ]] || { err "--broker-version expects a version"; exit 2; }; BROKER_VERSION="$1" ;;
    --hold)          HOLD_PKG=true ;;
    --unhold)        PKG_UNHOLD=true ;;
    --log)           shift; [[ $# -gt 0 ]] || { err "--log expects a path"; exit 2; }; LOG="$1" ;;
    -h|--help)       usage 0 ;;
    *) err "unknown argument: $1"; usage 2 ;;
  esac
  shift
done

[[ -n "$ACTION" ]] || { err "missing action (wipe | install | check)"; usage 2; }
$SCOPE_INTUNE || $SCOPE_EDGE || { err "--only-intune and --only-edge are exclusive"; exit 2; }

: "${LOG:="$HOME/fresh-reinstall-$(date '+%Y%m%d-%H%M%S').log"}"
touch "$LOG" 2>/dev/null || { err "log not writable: $LOG"; exit 1; }
exec > >(tee -a "$LOG") 2>&1

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

pkg_installed() {
  [[ "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null)" == "installed" ]]
}

any_pkg_installed() {
  local p
  for p in "$@"; do pkg_installed "$p" && return 0; done
  return 1
}

confirm() {
  $ASSUME_YES && return 0
  $DRY_RUN   && return 0
  [[ -t 0 ]] || die "not a TTY: pass --yes to confirm explicitly"
  local reply
  printf '\n%s\n' "$1"
  # Prompt written directly to the terminal: stdout goes through a tee, which
  # would not flush its buffer on a prompt without a trailing newline.
  printf '\nConfirm? [type yes] ' >/dev/tty
  read -r reply </dev/tty
  printf '%s\n' "$reply"
  [[ "$reply" == "yes" ]] || die "aborted by the operator"
}

# Units matching a pattern, user or system scope, de-duplicated.
discover_units() {
  local scope="$1" re="$2" flag=""
  [[ "$scope" == user ]] && flag="--user"
  {
    systemctl $flag list-units      --all --plain --no-legend 2>/dev/null | awk '{print $1}'
    systemctl $flag list-unit-files       --plain --no-legend 2>/dev/null | awk '{print $1}'
  } | grep -E "$re" 2>/dev/null | sort -u
}

stop_units() {
  local scope="$1" re="$2" label="$3"
  local units=() u
  mapfile -t units < <(discover_units "$scope" "$re")
  if [[ ${#units[@]} -eq 0 ]]; then
    skip "no $scope unit for $label"
    return 0
  fi
  for u in "${units[@]}"; do
    info "$scope unit: $u"
    if [[ "$scope" == user ]]; then
      run_soft systemctl --user stop "$u"
      run_soft systemctl --user disable "$u"
    else
      run_soft sudo systemctl stop "$u"
      run_soft sudo systemctl disable "$u"
    fi
    CHANGES=$((CHANGES + 1))
  done
}

# Kill processes whose binary lives under an in-scope path. Essential: a still
# running Edge or agent would rewrite its profile right after removal.
kill_procs() {
  local label="$1"; shift
  local pat pids
  for pat in "$@"; do
    pids="$(pgrep -u "$(id -u)" -f "$pat" 2>/dev/null | tr '\n' ' ')"
    [[ -z "${pids// /}" ]] && continue
    info "$label: processes to stop ($pat): $pids"
    run_soft pkill -u "$(id -u)" -TERM -f "$pat"
    $DRY_RUN || sleep 3
    if pgrep -u "$(id -u)" -f "$pat" >/dev/null 2>&1; then
      warn "$label: stubborn process, SIGKILL"
      run_soft pkill -u "$(id -u)" -KILL -f "$pat"
    fi
    CHANGES=$((CHANGES + 1))
  done
}

# Locked removal: absolute path, not /, not $HOME, basename in the allowlist.
# Absent => no-op, which makes the script re-runnable.
safe_remove() {
  local target="$1" base owner
  [[ -n "$target"    ]] || { fail "safe_remove: empty target"; return 1; }
  [[ "$target" == /* ]] || { fail "safe_remove: relative path refused ($target)"; return 1; }
  [[ "$target" != "/" ]] || { fail "safe_remove: refusing /"; return 1; }
  [[ "$target" != "$HOME" && "$target" != "$HOME/" ]] || { fail "safe_remove: refusing \$HOME"; return 1; }

  base="$(basename "$target")"
  if ! printf '%s' "$base" | grep -Eq "$ALLOWED_BASENAMES"; then
    fail "safe_remove: name out of scope, refused ($target)"
    return 1
  fi

  if [[ ! -e "$target" && ! -L "$target" ]]; then
    skip "absent: $target"
    return 0
  fi

  local sz; sz="$(du -sh "$target" 2>/dev/null | cut -f1)"
  owner="$(stat -c '%U' "$target" 2>/dev/null || echo '?')"
  if [[ "$owner" != "$(id -un)" ]]; then
    info "$target owned by '$owner' - removing via sudo (${sz:-?})"
    run sudo rm -rf -- "$target" || { fail "could not remove: $target"; return 1; }
  else
    run rm -rf -- "$target" || { fail "could not remove: $target"; return 1; }
  fi
  ok "removed: $target (${sz:-?})"
  CHANGES=$((CHANGES + 1))
  return 0
}

# ---------------------------------------------------------------------------
# Keyring (libsecret via GObject Introspection)
# ---------------------------------------------------------------------------

secret_helper_available() {
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - <<'PY' >/dev/null 2>&1
import gi
gi.require_version("Secret", "1")
from gi.repository import Secret  # noqa: F401
PY
}

# $1 = mode: probe | list | delete    $2 = regex (list/delete)
secret_op() {
  local mode="$1" re="${2:-}"
  python3 - "$mode" "$re" <<'PY'
import re, sys

import gi
gi.require_version("Secret", "1")
from gi.repository import Secret

mode = sys.argv[1]
pattern = sys.argv[2] if len(sys.argv) > 2 else ""

service = Secret.Service.get_sync(
    Secret.ServiceFlags.OPEN_SESSION | Secret.ServiceFlags.LOAD_COLLECTIONS, None)
cols = service.get_collections() or []

if mode == "probe":
    locked = 0
    items = 0
    for c in cols:
        if c.get_locked():
            locked += 1
            print("    collection: %s  [LOCKED]" % c.get_label())
            continue
        try:
            c.load_items_sync(None)
        except Exception:
            pass
        n = len(c.get_items() or [])
        items += n
        print("    collection: %s  [unlocked, %d items]" % (c.get_label(), n))
    print("COLLECTIONS=%d" % len(cols))
    print("LOCKED=%d" % locked)
    print("ITEMS=%d" % items)
    raise SystemExit(0)

rx = re.compile(pattern, re.I)
total = 0
failed = 0
for c in cols:
    if c.get_locked():
        print("    (locked collection, skipped: %s)" % c.get_label())
        continue
    try:
        c.load_items_sync(None)
    except Exception:
        pass
    for item in c.get_items() or []:
        label = item.get_label() or ""
        attrs = item.get_attributes() or {}
        blob = label + " " + " ".join("%s=%s" % kv for kv in attrs.items())
        if not rx.search(blob):
            continue
        total += 1
        print("    %s [%s] %s :: %s" % ("DEL " if mode == "delete" else "SEEN",
                                        c.get_label(), label, attrs))
        if mode == "delete":
            try:
                item.delete_sync(None)
            except Exception as e:
                failed += 1
                print("    ERR  could not delete: %s" % e)
print("TOTAL=%d" % total)
print("FAILED=%d" % failed)
PY
}

# Extract KEY=value from the helper output.
field() { printf '%s' "$1" | sed -n "s/^$2=//p" | tail -1; }

secret_regex_scope() {
  local re=""
  $SCOPE_INTUNE && re="$SECRET_RE_MS"
  if $SCOPE_EDGE; then
    re="${re:+$re|}$SECRET_RE_EDGE"
    $KILL_CHROMIUM_SAFE_STORAGE && re="$re|$SECRET_RE_CHROMIUM"
  fi
  printf '%s' "$re"
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

preflight() {
  section "Preflight"

  # Intune state and the Edge profile are PER USER. Run as root, $HOME would be
  # /root: the script would clean the wrong profile and leave the real state.
  [[ ${EUID:-$(id -u)} -ne 0 ]] || die "do not run as root or via sudo: state is per user. Re-run as the desktop user."
  [[ -n "${HOME:-}" && -d "$HOME" ]] || die "invalid HOME: '${HOME:-}'"
  [[ "$HOME" != "/root" ]] || die "HOME=/root: unexpected session, aborting"

  local missing=() c
  for c in systemctl dpkg-query apt-get pgrep pkill; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  [[ ${#missing[@]} -eq 0 ]] || die "missing commands: ${missing[*]}"

  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"; OS_VER="${VERSION_ID:-unknown}"; OS_CODE="${VERSION_CODENAME:-}"
  fi

  info "OS      : $OS_ID $OS_VER ($OS_CODE)"
  info "user    : $(id -un)   host: $(hostname)"
  info "session : type=${XDG_SESSION_TYPE:-?} desktop=${XDG_CURRENT_DESKTOP:-?} display=${DISPLAY:-none}${WAYLAND_DISPLAY:+ wayland=$WAYLAND_DISPLAY}"
  info "scope   : $($SCOPE_INTUNE && printf 'Intune+broker ')$($SCOPE_EDGE && printf 'Edge')"
  info "log     : $LOG"
  $DRY_RUN && info "DRY-RUN MODE: no changes"

  if [[ "$ACTION" != check ]]; then
    command -v sudo >/dev/null 2>&1 || die "sudo required for '$ACTION'"
    if ! $DRY_RUN; then
      info "sudo validation (password may be requested)"
      sudo -v || die "sudo unavailable"
    fi
  fi
}

# The point that makes a wipe silently fail: without a reachable, unlocked
# keyring, the secret purge returns TOTAL=0 and looks like success.
preflight_keyring() {
  section "Keyring preflight - the critical point"

  if [[ -n "${SSH_CONNECTION:-}" && "${XDG_SESSION_TYPE:-}" != "x11" && "${XDG_SESSION_TYPE:-}" != "wayland" ]]; then
    die "SSH session detected: the graphical session keyring is not reachable from here.
     The wipe would return TOTAL=0 and report success, without removing the device certificate.
     -> sit physically at the machine, in a local graphical session."
  fi
  [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]] || die "DBUS_SESSION_BUS_ADDRESS missing: no session bus, the keyring is unreachable."

  if ! secret_helper_available; then
    warn "python3-gi / gir1.2-secret-1 missing: installing (prerequisite to purge secrets)"
    run sudo apt-get install -y python3-gi gir1.2-secret-1 || die "could not install python3-gi / gir1.2-secret-1: the wipe cannot purge the keyring."
    if ! $DRY_RUN && ! secret_helper_available; then
      die "libsecret helper still unavailable after installation."
    fi
    ok "libsecret prerequisites installed"
    CHANGES=$((CHANGES + 1))
  else
    ok "libsecret helper available"
  fi

  local probe
  if ! probe="$(secret_op probe)"; then
    $DRY_RUN && { warn "DRY-RUN: keyring unreadable (prerequisites not installed), check skipped"; return 0; }
    die "could not read the keyring (see the log)."
  fi
  printf '%s\n' "$probe"
  local ncol nlock nitem
  ncol="$(field "$probe" COLLECTIONS)"; nlock="$(field "$probe" LOCKED)"; nitem="$(field "$probe" ITEMS)"

  [[ "${ncol:-0}" -gt 0 ]] || die "NO keyring collection visible: gnome-keyring is unreachable from this session.
     This is exactly the configuration that produces a false TOTAL=0 success.
     -> open seahorse (' Passwords and Keys '), check that a ' Login ' keyring exists and is unlocked, then re-run."

  if [[ "${nlock:-0}" -gt 0 ]]; then
    if $ALLOW_LOCKED_KEYRING; then
      warn "$nlock locked collection(s) - forced to continue by --allow-locked-keyring. Their secrets WILL NOT be removed."
    else
      die "$nlock LOCKED keyring collection(s): their secrets would survive the wipe.
     -> unlock them in seahorse (double-click the keyring, session password), then re-run.
     -> or, knowingly: --allow-locked-keyring"
    fi
  fi
  ok "keyring reachable: $ncol collection(s), $nitem visible items, $nlock locked"
}

# ---------------------------------------------------------------------------
# WIPE
# ---------------------------------------------------------------------------

backup_edge_profile() {
  $DO_BACKUP || { skip "Edge profile backup disabled (--no-backup)"; return 0; }
  [[ -d "$HOME/.config/microsoft-edge" ]] || { skip "no Edge profile to back up"; return 0; }

  local dest="$HOME/edge-profile-before-wipe-$(date '+%Y%m%d-%H%M%S').tar.gz"
  info "backing up the Edge profile (bookmarks, passwords, sessions) -> $dest"
  info "  caches are excluded: this is a lifeline, not an image"
  if $DRY_RUN; then
    printf '%s  DRY   tar czf %s (excluding caches)\n' "$(ts)" "$dest"
    return 0
  fi
  if tar czf "$dest" \
        --exclude='*/Cache' --exclude='*/Code Cache' --exclude='*/GPUCache' \
        --exclude='*/Service Worker' --exclude='*/DawnCache' --exclude='*/ShaderCache' \
        --exclude='*/component_crx_cache' --exclude='*/optimization_guide_*' \
        -C "$HOME/.config" microsoft-edge 2>/dev/null; then
    ok "backup written: $dest ($(du -sh "$dest" 2>/dev/null | cut -f1))"
  else
    warn "Edge profile backup incomplete or failed - the wipe continues"
  fi
}

purge_secrets() {
  section "Keyring secrets"
  local re; re="$(secret_regex_scope)"
  info "pattern: $re"
  $SCOPE_EDGE && ! $KILL_CHROMIUM_SAFE_STORAGE && \
    info "a ' Chromium/Chrome Safe Storage ' entry will NOT be touched (may belong to Chrome) - force with --include-chromium-safe-storage"

  local out n
  out="$(secret_op list "$re")" || { fail "could not read the keyring"; return 1; }
  printf '%s\n' "$out"
  n="$(field "$out" TOTAL)"; n="${n:-0}"

  if [[ "$n" -eq 0 ]]; then
    # The trap: zero secrets while the packages are present means an unreachable
    # keyring, not a clean host. Blocking error, never a success.
    if $HAD_INTUNE || $HAD_BROKER || $HAD_EDGE; then
      die "TOTAL=0 while in-scope packages were installed.
     The keyring is not returning its secrets: the device certificate would survive the wipe and the
     re-enrollment would reuse the same Entra identity.
     -> check in seahorse that the ' Login ' keyring is unlocked, then re-run.
     STATE: the purge is INCOMPLETE, do not reinstall as-is."
    fi
    skip "no secret in scope (no package was installed: consistent)"
    return 0
  fi

  if $DRY_RUN; then
    info "DRY-RUN: $n secret(s) would be removed"
    return 0
  fi

  info "removing $n secret(s)"
  local del nfail
  del="$(secret_op delete "$re")" || { fail "secret removal failed"; return 1; }
  printf '%s\n' "$del"
  nfail="$(field "$del" FAILED)"; nfail="${nfail:-0}"
  [[ "$nfail" -gt 0 ]] && fail "$nfail secret(s) could not be removed"
  CHANGES=$((CHANGES + 1))

  # Immediate verification: the pattern must return nothing anymore.
  local after nafter
  after="$(secret_op list "$re")" || true
  nafter="$(field "$after" TOTAL)"; nafter="${nafter:-?}"
  if [[ "$nafter" == "0" ]]; then
    ok "verification: no more in-scope secret in the keyring"
  else
    printf '%s\n' "$after"
    fail "$nafter in-scope secret(s) remain after removal"
  fi
}

verify_wipe() {
  section "Post-wipe verification - did the wipe really empty the host?"
  local clean=true p d
  local pkgs=()
  $SCOPE_INTUNE && pkgs+=("${INTUNE_PKGS[@]}" "${BROKER_PKGS[@]}")
  $SCOPE_EDGE   && pkgs+=("${EDGE_PKGS[@]}")

  for p in "${pkgs[@]}"; do
    if pkg_installed "$p"; then fail "package still installed: $p"; clean=false; fi
  done

  local dirs=()
  $SCOPE_INTUNE && dirs+=("${INTUNE_USER_DIRS[@]}" "${INTUNE_SYS_DIRS[@]}" "${BROKER_USER_DIRS[@]}" "${BROKER_SYS_DIRS[@]}")
  $SCOPE_EDGE   && dirs+=("${EDGE_USER_DIRS[@]}" "${EDGE_SYS_DIRS[@]}")
  for d in "${dirs[@]}"; do
    if [[ -e "$d" || -L "$d" ]]; then fail "directory still present: $d"; clean=false; fi
  done

  if [[ -e "$AGENT_DROPIN_DIR" ]]; then
    info "drop-in still present (normal if the package was not installed): $AGENT_DROPIN_DIR"
  fi

  local re out n
  re="$(secret_regex_scope)"
  out="$(secret_op list "$re" 2>/dev/null)" || out=""
  n="$(field "$out" TOTAL)"; n="${n:-?}"
  if [[ "$n" == "0" ]]; then
    ok "keyring: 0 in-scope secret"
  else
    fail "keyring: $n in-scope secret(s) remain"
    clean=false
  fi

  $clean && ok "HOST CLEAN - ready for reboot then install"
}

do_wipe() {
  # Capture BEFORE any purge: used to decide whether a TOTAL=0 is legitimate or suspect.
  any_pkg_installed "${INTUNE_PKGS[@]}" && HAD_INTUNE=true
  any_pkg_installed "${BROKER_PKGS[@]}" && HAD_BROKER=true
  any_pkg_installed "${EDGE_PKGS[@]}"   && HAD_EDGE=true
  info "state before: intune=$HAD_INTUNE broker=$HAD_BROKER edge=$HAD_EDGE"

  preflight_keyring

  local what=""
  $SCOPE_INTUNE && what="intune-portal + microsoft-identity-broker"
  $SCOPE_EDGE   && what="${what:+$what + }microsoft-edge"

  confirm "TOTAL WIPE on $(hostname) - scope: $what

Will be PERMANENTLY removed:
  - the packages above (purge, never autoremove)
  - all in-scope systemd units
  - all local state: config, data, state, CACHES, Edge browsing profile
  - Edge enterprise policies (/etc/opt/edge)
  - Intune / MSAL / broker / Edge keyring secrets
  - the matching .deb in the apt cache (reinstalled from the repo)

Consequences: Edge/Teams SSO to redo, Edge bookmarks and passwords lost
$($DO_BACKUP && printf 'a profile backup is written to %s before removal' "$HOME" || printf 'NO backup: --no-backup')
No automatic reboot. Log: $LOG"

  section "1/7 Stopping processes and units"
  if $SCOPE_INTUNE; then
    stop_units user   "$INTUNE_UNIT_RE" "intune"
    stop_units system "$INTUNE_UNIT_RE" "intune"
    stop_units user   "$BROKER_UNIT_RE" "broker"
    stop_units system "$BROKER_UNIT_RE" "broker"
    kill_procs "intune" "${PROC_PATTERNS_INTUNE[@]}"
    kill_procs "broker" "${PROC_PATTERNS_BROKER[@]}"
  fi
  if $SCOPE_EDGE; then
    kill_procs "edge" "${PROC_PATTERNS_EDGE[@]}"
  fi
  run_soft systemctl --user daemon-reload
  run_soft systemctl --user reset-failed

  section "2/7 Edge profile backup"
  if $SCOPE_EDGE; then backup_edge_profile; else skip "Edge out of scope"; fi

  section "3/7 Package purge"
  local pkgs=() p present=()
  $SCOPE_INTUNE && pkgs+=("${INTUNE_PKGS[@]}" "${BROKER_PKGS[@]}")
  $SCOPE_EDGE   && pkgs+=("${EDGE_PKGS[@]}")
  for p in "${pkgs[@]}"; do
    if pkg_installed "$p"; then present+=("$p"); else skip "not installed: $p"; fi
  done
  if [[ ${#present[@]} -gt 0 ]]; then
    info "purge: ${present[*]}   (never apt autoremove)"
    run sudo apt-get purge -y "${present[@]}" || fail "apt-get purge failed on: ${present[*]}"
    CHANGES=$((CHANGES + 1))
  fi
  # A hold would survive the purge and block reinstalling the current version.
  local hp
  for hp in intune-portal microsoft-identity-broker; do
    if apt-mark showhold 2>/dev/null | grep -qx "$hp"; then
      info "hold present on $hp, removing it"
      run_soft sudo apt-mark unhold "$hp"
    fi
  done

  section "4/7 Local state, profiles and caches"
  local d dirs=()
  $SCOPE_INTUNE && dirs+=("${INTUNE_USER_DIRS[@]}" "${INTUNE_SYS_DIRS[@]}" "${BROKER_USER_DIRS[@]}" "${BROKER_SYS_DIRS[@]}")
  $SCOPE_EDGE   && dirs+=("${EDGE_USER_DIRS[@]}" "${EDGE_SYS_DIRS[@]}")
  for d in "${dirs[@]}"; do safe_remove "$d"; done
  if $SCOPE_INTUNE; then
    safe_remove "$AGENT_DROPIN_DIR"
    run_soft systemctl --user daemon-reload
  fi

  section "5/7 apt cache (the .deb will be re-downloaded)"
  local globs=()
  $SCOPE_INTUNE && globs+=(/var/cache/apt/archives/intune-portal_*.deb /var/cache/apt/archives/microsoft-identity-broker_*.deb)
  $SCOPE_EDGE   && globs+=(/var/cache/apt/archives/microsoft-edge-*.deb)
  local g found=()
  for g in "${globs[@]}"; do [[ -e "$g" ]] && found+=("$g"); done
  if [[ ${#found[@]} -gt 0 ]]; then
    info "removing ${#found[@]} cached .deb"
    run sudo rm -f -- "${found[@]}" || fail "apt cache cleanup failed"
    CHANGES=$((CHANGES + 1))
  else
    skip "no in-scope .deb in the apt cache"
  fi

  section "6/7 Keyring secrets"
  purge_secrets

  section "7/7 Verification"
  verify_wipe

  section "snap / flatpak variants (reporting only)"
  local sn fl
  sn="$(snap list 2>/dev/null | grep -i edge)"
  fl="$(flatpak list 2>/dev/null | grep -i edge)"
  if [[ -n "$sn" ]]; then
    warn "Edge is also installed as a snap - not handled by this script:"
    printf '%s\n' "$sn"
    warn "  -> sudo snap remove microsoft-edge"
  fi
  if [[ -n "$fl" ]]; then
    warn "Edge is also installed as a flatpak - not handled by this script:"
    printf '%s\n' "$fl"
    warn "  -> flatpak uninstall <ref>"
  fi
  [[ -z "$sn$fl" ]] && skip "no snap/flatpak variant of Edge"
}

# ---------------------------------------------------------------------------
# INSTALL
# ---------------------------------------------------------------------------

ms_prod_repo_file() {
  grep -rslE 'packages\.microsoft\.com/(ubuntu|debian)/[0-9.]+/prod' \
    /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null | head -1
}

ensure_ms_key() {
  if [[ -s "$MS_KEY" ]]; then skip "Microsoft key already present: $MS_KEY"; return 0; fi
  command -v curl >/dev/null 2>&1 || die "curl required to install the Microsoft key"
  command -v gpg  >/dev/null 2>&1 || die "gpg required to install the Microsoft key"
  if $DRY_RUN; then
    printf '%s  DRY   curl microsoft.asc | gpg --dearmor > %s\n' "$(ts)" "$MS_KEY"
    return 0
  fi
  curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
    | gpg --dearmor | sudo tee "$MS_KEY" >/dev/null || die "could not fetch the Microsoft key"
  sudo chmod 0644 "$MS_KEY"
  ok "key installed: $MS_KEY"
  CHANGES=$((CHANGES + 1))
}

ensure_prod_repo() {
  local existing; existing="$(ms_prod_repo_file)"
  if [[ -n "$existing" ]]; then
    ok "Microsoft prod repo already configured: $existing"
    return 0
  fi
  [[ "$OS_ID" == "ubuntu" ]] || die "Microsoft prod repo missing and OS is not Ubuntu ($OS_ID $OS_VER): manual configuration required."
  ensure_ms_key
  local list="/etc/apt/sources.list.d/microsoft-ubuntu-${OS_VER}-prod.list"
  local line="deb [arch=amd64 signed-by=$MS_KEY] https://packages.microsoft.com/ubuntu/${OS_VER}/prod ${OS_CODE:-noble} main"
  if $DRY_RUN; then
    printf '%s  DRY   write %s: %s\n' "$(ts)" "$list" "$line"
  else
    printf '%s\n' "$line" | sudo tee "$list" >/dev/null
    ok "prod repo written: $list"
    CHANGES=$((CHANGES + 1))
  fi
}

ensure_edge_repo() {
  ensure_ms_key
  local line="deb [arch=amd64 signed-by=$MS_KEY] https://packages.microsoft.com/repos/edge stable main"
  if [[ -f "$EDGE_REPO_LIST" ]] && grep -qF 'packages.microsoft.com/repos/edge' "$EDGE_REPO_LIST"; then
    ok "Edge repo already configured: $EDGE_REPO_LIST"
    return 0
  fi
  if $DRY_RUN; then
    printf '%s  DRY   write %s: %s\n' "$(ts)" "$EDGE_REPO_LIST" "$line"
    return 0
  fi
  printf '%s\n' "$line" | sudo tee "$EDGE_REPO_LIST" >/dev/null
  ok "Edge repo written: $EDGE_REPO_LIST"
  CHANGES=$((CHANGES + 1))
}

ensure_agent_dropin() {
  if [[ -f "$AGENT_DROPIN" ]] && [[ "$(cat "$AGENT_DROPIN" 2>/dev/null)" == "$AGENT_DROPIN_CONTENT" ]]; then
    skip "drop-in already conform: $AGENT_DROPIN"
    return 0
  fi
  if $DRY_RUN; then
    printf '%s  DRY   write %s (StateDirectory= empty)\n' "$(ts)" "$AGENT_DROPIN"
    return 0
  fi
  sudo mkdir -p "$AGENT_DROPIN_DIR" || { fail "could not create $AGENT_DROPIN_DIR"; return 1; }
  printf '%s\n' "$AGENT_DROPIN_CONTENT" | sudo tee "$AGENT_DROPIN" >/dev/null || { fail "could not write the drop-in"; return 1; }
  sudo chmod 0644 "$AGENT_DROPIN"
  run_soft systemctl --user daemon-reload
  ok "drop-in written: $AGENT_DROPIN"
  CHANGES=$((CHANGES + 1))
}

do_install() {
  local what=""
  $SCOPE_INTUNE && what="microsoft-identity-broker + intune-portal${PKG_VERSION:+ (=$PKG_VERSION)}"
  $SCOPE_EDGE   && what="${what:+$what + }microsoft-edge-stable"

  confirm "INSTALL on $(hostname) - installing: $what
Microsoft repositories will be configured if missing. No other package is
installed explicitly, no reboot. Log: $LOG"

  section "1/5 Repositories"
  $SCOPE_INTUNE && ensure_prod_repo
  $SCOPE_EDGE   && ensure_edge_repo

  section "2/5 apt index"
  run sudo apt-get update || warn "apt-get update failed or partial - the install may fail"

  section "3/5 Installation"
  # A hold on either package would silently defeat the requested pinning.
  local hp
  for hp in intune-portal microsoft-identity-broker; do
    if $PKG_UNHOLD || apt-mark showhold 2>/dev/null | grep -qx "$hp"; then
      run_soft sudo apt-mark unhold "$hp"
      ok "hold removed on $hp"
    fi
  done

  # Deliberate order: the broker first - Edge and the Company Portal rely on it
  # for SSO; the reverse yields a degraded first authentication.
  if $SCOPE_INTUNE; then
    if [[ -n "$BROKER_VERSION" ]]; then
      info "requested broker version: $BROKER_VERSION"
      apt-cache madison microsoft-identity-broker 2>/dev/null | head -8
      run sudo apt-get install -y --allow-downgrades "microsoft-identity-broker=$BROKER_VERSION" \
        || fail "install of broker=$BROKER_VERSION failed"
      $HOLD_PKG && { run_soft sudo apt-mark hold microsoft-identity-broker; ok "broker pinned at $BROKER_VERSION"; }
    else
      run sudo apt-get install -y "${BROKER_PKGS[@]}" || fail "broker install failed"
    fi
    CHANGES=$((CHANGES + 1))

    if [[ -n "$PKG_VERSION" ]]; then
      info "requested intune-portal version: $PKG_VERSION"
      apt-cache madison intune-portal 2>/dev/null | head -10
      run sudo apt-get install -y --allow-downgrades "intune-portal=$PKG_VERSION" \
        || fail "install of intune-portal=$PKG_VERSION failed"
      $HOLD_PKG && { run_soft sudo apt-mark hold intune-portal; ok "intune-portal pinned at $PKG_VERSION"; }
    else
      run sudo apt-get install -y "${INTUNE_PKGS[@]}" || fail "intune-portal install failed"
    fi
    CHANGES=$((CHANGES + 1))
  fi

  if $SCOPE_EDGE; then
    run sudo apt-get install -y microsoft-edge-stable || fail "install of microsoft-edge-stable failed"
    CHANGES=$((CHANGES + 1))
  fi

  section "4/5 Agent unit drop-in (without it: 238/STATE_DIRECTORY)"
  if $SCOPE_INTUNE; then ensure_agent_dropin; else skip "Intune out of scope"; fi

  section "5/5 Verification"
  dpkg-query -W -f='  ${binary:Package} ${Version} ${db:Status-Status}\n' \
    intune-portal microsoft-identity-broker microsoft-edge-stable 2>/dev/null

  # A package in 'config-files' is NOT installed: apt still lists it and the summary
  # can look like success. Also checks the pinned version is the one in place
  # (an unsatisfiable dependency fails the install without apt returning 1 everywhere).
  if $SCOPE_INTUNE; then
    local p v
    for p in microsoft-identity-broker intune-portal; do
      if ! pkg_installed "$p"; then
        fail "$p is NOT installed (state: $(dpkg-query -W -f='${db:Status-Status}' "$p" 2>/dev/null || echo absent)). DO NOT ENROLL."
        continue
      fi
      v="$(dpkg-query -W -f='${Version}' "$p" 2>/dev/null)"
      case "$p" in
        microsoft-identity-broker)
          [[ -n "$BROKER_VERSION" && "$v" != "$BROKER_VERSION" ]] && \
            fail "broker requested $BROKER_VERSION but $v is installed" ;;
        intune-portal)
          [[ -n "$PKG_VERSION" && "$v" != "$PKG_VERSION" ]] && \
            fail "intune-portal requested $PKG_VERSION but $v is installed" ;;
      esac
    done
  fi
  $SCOPE_EDGE && { command -v microsoft-edge >/dev/null 2>&1 \
    && ok "edge: $(microsoft-edge --version 2>/dev/null)" \
    || warn "microsoft-edge binary not found in PATH"; }

  if $SCOPE_INTUNE && ! $DRY_RUN; then
    info "starting the system broker"
    run_soft sudo systemctl enable --now microsoft-identity-device-broker.service
    printf '  broker: %s\n' "$(systemctl is-active microsoft-identity-device-broker.service 2>&1)"

    # A MASKED unit never starts and produces no error: without this check,
    # the test below wrongly concludes all is well and you enroll into the void.
    # Observed: intune-agent.service masked after a failed purge/install cycle.
    local u
    for u in intune-agent.service intune-agent.timer; do
      if [[ "$(systemctl --user is-enabled "$u" 2>/dev/null)" == "masked" ]]; then
        warn "$u is MASKED - unmasking"
        run_soft systemctl --user unmask "$u"
        CHANGES=$((CHANGES + 1))
      fi
    done
    run_soft systemctl --user daemon-reload

    info "agent start test (an auth failure is EXPECTED: no account signed in)"
    systemctl --user start intune-agent.service >/dev/null 2>&1
    sleep 2
    local st; st="$(systemctl --user status intune-agent.service --no-pager -l 2>&1)"
    if grep -q 'masked' <<<"$st"; then
      fail "intune-agent.service stays MASKED: DO NOT ENROLL. Fix with: systemctl --user unmask intune-agent.service"
    elif grep -qE 'could not be found|not-found' <<<"$st"; then
      fail "intune-agent.service not found: the intune-portal package is not installed. DO NOT ENROLL."
    elif grep -q '238/STATE_DIRECTORY' <<<"$st"; then
      fail "the agent fails in 238/STATE_DIRECTORY: DO NOT ENROLL. The drop-in is not taken into account (start a new session, or check $AGENT_DROPIN)."
    else
      ok "agent startable, not masked, no STATE_DIRECTORY error - enrollment possible"
    fi
    printf '%s\n' "$st" | head -12 | sed 's/^/  /'
  fi
}

# ---------------------------------------------------------------------------
# CHECK - the gates, in a single pass
# ---------------------------------------------------------------------------

do_check() {
  local REG="$HOME/.config/intune/registration.toml"

  section "Context"
  printf '  date       : %s\n' "$(date -Is)"
  printf '  host       : %s   user: %s\n' "$(hostnamectl --static 2>/dev/null)" "$(id -un)"
  printf '  machine-id : %s\n' "$(cat /etc/machine-id 2>/dev/null)"
  printf '  os         : %s %s\n' "$OS_ID" "$OS_VER"
  dpkg-query -W -f='  package    : ${binary:Package} ${Version} ${db:Status-Status}\n' \
    intune-portal microsoft-identity-broker microsoft-edge-stable 2>/dev/null
  apt-mark showhold 2>/dev/null | sed 's/^/  hold       : /'

  section "GATE 1 - did the Entra identity actually run?"
  if [[ ! -f "$REG" ]]; then
    warn "$REG missing: no effective enrollment (did you sign in to the Company Portal?)"
  else
    stat -c '  written: %y' "$REG"
    sed 's/^/  /' "$REG"
    local AAD DEV hit=""
    AAD="$(sed -n 's/^aad_device_hint *= *"\(.*\)"/\1/p' "$REG")"
    DEV="$(sed -n 's/^device_hint *= *"\(.*\)"/\1/p' "$REG")"
    local g
    for g in "${AAD_BURNED[@]}";    do [[ "$AAD" == "$g" ]] && hit="$g"; done
    for g in "${INTUNE_BURNED[@]}"; do [[ "$DEV" == "$g" ]] && hit="${hit:+$hit + }$g"; done
    if [[ -n "$hit" ]]; then
      fail "already-burned identity reused: $hit - the wipe did not rotate the identity, no point going further"
    else
      ok "aad_device_hint=$AAD  device_hint=$DEV  (no recycled identity)"
    fi
  fi

  section "GATE 2 - did the previous wipe really purge the keyring?"
  # Look for the last WIPE log, not simply the most recent log: the current run
  # carries the same name pattern and would be picked.
  local last="" f
  for f in $(ls -t "$HOME"/fresh-reinstall-*.log 2>/dev/null); do
    [[ "$f" == "$LOG" ]] && continue
    grep -q 'Post-wipe verification' "$f" 2>/dev/null && { last="$f"; break; }
  done
  if [[ -n "$last" ]]; then
    printf '  last wipe log: %s\n' "$last"
    grep -Ein 'TOTAL=|FAILED=|locked|removing [0-9]+ secret|HOST CLEAN' "$last" | tail -20 | sed 's/^/  /'
    if grep -q 'HOST CLEAN' "$last"; then
      ok "the last wipe finished on a verified clean host"
    else
      warn "the last wipe did not finish on ' HOST CLEAN ' - re-read $last"
    fi
  else
    warn "no wipe log (fresh-reinstall-*.log with a post-wipe verification) in the home directory"
  fi

  section "GATE 3 - is the device certificate persisted?"
  if secret_helper_available; then
    local out n
    out="$(secret_op list "$SECRET_RE_MS")" || out=""
    printf '%s\n' "$out"
    n="$(field "$out" TOTAL)"; n="${n:-0}"
    if printf '%s' "$out" | grep -qi 'signed_cert'; then
      ok "' Intune :: signed_cert ' present in the keyring ($n in-scope items)"
    else
      fail "no signed_cert in the keyring: the client does not persist its identity"
    fi
  else
    warn "libsecret helper unavailable: inspect the keyring via seahorse"
  fi

  section "GATE 4 - is the agent in a state to run?"
  if [[ -f "$AGENT_DROPIN" ]]; then
    ok "drop-in present: $AGENT_DROPIN"
    sed 's/^/    /' "$AGENT_DROPIN"
  else
    fail "drop-in MISSING ($AGENT_DROPIN): the agent will die in 238/STATE_DIRECTORY and enrollment will produce an unfinished device object"
  fi
  local u en
  for u in intune-agent.service intune-agent.timer; do
    en="$(systemctl --user is-enabled "$u" 2>&1)"
    printf '  user   %-40s %s (%s)\n' "$u" "$(systemctl --user is-active "$u" 2>&1)" "$en"
    [[ "$en" == "masked" ]] && fail "$u is MASKED: it will never start. Fix: systemctl --user unmask $u"
  done
  # 'failed' alone does not say why. 255/EXCEPTION = the agent treated an HTTP
  # response as fatal (the case for 404/500 on details); 238 = it never started.
  printf '  user   %-40s Result=%s ExecMainStatus=%s\n' "intune-agent.service (detail)" \
    "$(systemctl --user show intune-agent.service -p Result --value 2>/dev/null)" \
    "$(systemctl --user show intune-agent.service -p ExecMainStatus --value 2>/dev/null)"
  for u in intune-daemon.service microsoft-identity-device-broker.service; do
    printf '  system %-40s %s\n' "$u" "$(systemctl is-active "$u" 2>&1)"
  done
  if journalctl --user -u 'intune*' -b --no-pager 2>/dev/null | grep -q '238/STATE_DIRECTORY'; then
    fail "238/STATE_DIRECTORY present in this boot's journal"
  else
    ok "no 238/STATE_DIRECTORY since startup"
  fi

  section "GATE 5 - does the check-in pass?"
  # The window is anchored on the registration.toml write, NOT on a fixed duration.
  # A 60 min window mixes several identity generations and would judge 500s that
  # belong to an already-dead device. A mistake to avoid: four 500s from two
  # previous identities producing a FAIL on an enrollment that had not yet
  # emitted a single check-in.
  local since="" curdev=""
  if [[ -f "$REG" ]]; then
    since="$(date -d "@$(stat -c %Y "$REG")" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
    curdev="$(sed -n 's/^device_hint *= *"\(.*\)"/\1/p' "$REG")"
  fi
  if [[ -z "$since" ]]; then
    warn "no registration.toml: falling back to 60 min, verdict only indicative"
    since="-60min"
  else
    info "window anchored on the current enrollment: since $since, device_id $curdev"
  fi

  local jrn; jrn="$(journalctl --user -u 'intune*' --since "$since" --no-pager 2>/dev/null)"
  local nchk; nchk="$(printf '%s\n' "$jrn" | grep -c 'Exchanging device details')"
  local codes; codes="$(printf '%s\n' "$jrn" | grep -oE 'status code [0-9]+' | sort | uniq -c | sort -rn)"

  # A check-in carrying a device_id different from registration.toml's belongs to
  # a previous generation: it says nothing about the current enrollment.
  local nstale=0
  if [[ -n "$curdev" ]]; then
    nstale="$(printf '%s\n' "$jrn" | grep -oE 'device_id="[0-9a-f-]+"' \
              | grep -vc "$curdev")" || nstale=0
    [[ "$nstale" -gt 0 ]] && info "$nstale line(s) carry a device_id from an earlier generation, out of verdict"
  fi

  if [[ "$nchk" -eq 0 ]]; then
    warn "NO check-in since the enrollment of $since: the timer has not run yet
     (observed cycle ~10-11 min). Verdict IMPOSSIBLE to render, re-run 'check' later.
     Conclude nothing from earlier HTTP codes: they belong to dead identities."
  elif [[ -z "$codes" ]]; then
    ok "$nchk check-in(s) since the enrollment, no HTTP error code"
  else
    printf '%s\n' "$codes" | sed 's/^/  /'
    if grep -qE '50[0-9]|404' <<<"$codes"; then
      fail "the fault persists on the current enrollment ($nchk check-in, device_id $curdev)"
    fi
  fi

  printf '  check-ins in the window:\n'
  printf '%s\n' "$jrn" \
    | grep -iE 'Exchanging device details|checkin succeed|Successfully checked in|Failed to checkin' \
    | tail -8 | sed 's/^/    /'
  printf '  activity_id in the window (attach to any support ticket):\n'
  printf '%s\n' "$jrn" \
    | grep -oE 'activity_id="[0-9a-f-]+"' | sort -u | tail -8 | sed 's/^/    /'

  section "GATE 6 - did Edge come back clean?"
  if command -v microsoft-edge >/dev/null 2>&1; then
    ok "edge: $(microsoft-edge --version 2>/dev/null)"
    if [[ -d "$HOME/.config/microsoft-edge" ]]; then
      printf '  profile created: %s\n' "$(stat -c '%y' "$HOME/.config/microsoft-edge" 2>/dev/null)"
    else
      info "profile absent: Edge has not been launched yet"
    fi
    if [[ -d /etc/opt/edge/policies/managed ]]; then
      printf '  enterprise policies:\n'
      ls -1 /etc/opt/edge/policies/managed 2>/dev/null | sed 's/^/    /'
    else
      info "no Edge enterprise policy (/etc/opt/edge/policies/managed absent)"
    fi
  else
    warn "microsoft-edge absent from PATH"
  fi
  printf '  broker auth errors (since %s):\n' "$since"
  journalctl --user --since "$since" --no-pager 2>/dev/null \
    | grep -iE 'interaction_required|additional_action|AADSTS' | tail -8 | sed 's/^/    /'

  section "To check tenant-side, from the admin Windows machine"
  [[ -n "$curdev" ]] && printf '  current Intune device_id: %s\n' "$curdev"
  local curaad=""
  [[ -f "$REG" ]] && curaad="$(sed -n 's/^aad_device_hint *= *"\(.*\)"/\1/p' "$REG")"
  [[ -n "$curaad" ]] && printf '  current Entra deviceId   : %s\n\n' "$curaad"
  cat <<'PS'
  Connect-MgGraph -Scopes "Device.Read.All","DeviceManagementManagedDevices.Read.All" -NoWelcome

  # WARNING: Graph returns UTC. Always convert, otherwise you think you are reading
  # objects from an earlier generation. Classic pitfall (12:38 UTC = 14:38 local).
  $id  = '<current Intune device_id, above>'
  $aad = '<current Entra deviceId, above>'

  # 1. Does Intune resolve the device on which the check-in fails?
  $d = Invoke-MgGraphRequest -Method GET -OutputType PSObject `
       -Uri "https://graph.microsoft.com/beta/deviceManagement/managedDevices/$id"
  $d | Select-Object id,deviceName,azureADDeviceId,managementAgent,managementState,
      model,manufacturer,serialNumber,
      @{n='enrolled';e={$_.enrolledDateTime.ToLocalTime()}},
      @{n='lastSync';e={$_.lastSyncDateTime.ToLocalTime()}} | Format-List

  # 2. Did the Entra object complete?
  $ent = (Invoke-MgGraphRequest -Method GET -OutputType PSObject `
    -Uri "https://graph.microsoft.com/v1.0/devices?`$filter=deviceId eq '$aad'").value
  $ent | Select-Object displayName,deviceId,trustType,managementType,deviceOwnership,
      isManaged,isCompliant,
      @{n='created';e={$_.createdDateTime.ToLocalTime()}},
      @{n='lastSignIn';e={$_.approximateLastSignInDateTime.ToLocalTime()}} | Format-List

  Reading:
    - managementAgent = msSense  -> Defender for Endpoint object, NOT an MDM enrollment.
      Normal to see one duplicated with the same deviceName. Do not delete it.
    - Intune resolves $id but the check-in returns 404 on that same id
      -> the service contradicts itself. This is the ticket argument, and it is verifiable.
    - managementType EMPTY more than 20 min after enrollment, with a healthy agent and
      no 238/STATE_DIRECTORY -> object unfinished service-side, not device-side.
    - approximateLastSignInDateTime == createdDateTime -> the credential was never used.
PS
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

preflight

case "$ACTION" in
  wipe)    do_wipe ;;
  install) do_install ;;
  check)   do_check ;;
esac

section "Summary"
info "action: $ACTION - changes applied: $CHANGES$($DRY_RUN && printf ' (DRY-RUN: none)')"

if [[ ${#WARNINGS[@]} -gt 0 ]]; then
  say ""
  say "Warnings (${#WARNINGS[@]}):"
  printf '  - %s\n' "${WARNINGS[@]}"
fi

if [[ ${#FAILURES[@]} -gt 0 ]]; then
  say ""
  say "FAILURES (${#FAILURES[@]}) - fix BEFORE moving to the next step:"
  printf '  - %s\n' "${FAILURES[@]}"
fi

case "$ACTION" in
  wipe)
    say ""
    say "Next:  1) sudo reboot"
    say "       2) ./fresh-reinstall.sh install"
    say "       3) sudo reboot"
    say "       4) open Company Portal, sign in, wait ~10 min"
    say "       5) ./fresh-reinstall.sh check"
    say ""
    say "Tenant-side, BEFORE step 4: the test device's objects must have been"
    say "deleted from Intune THEN from Entra, with 15 min of propagation."
    ;;
  install)
    say ""
    say "Next:  1) sudo reboot"
    say "       2) watch in a terminal: journalctl --user -u 'intune*' -f"
    say "       3) open Company Portal and sign in"
    say "       4) ~10 min later: ./fresh-reinstall.sh check"
    ;;
  check)
    say ""
    say "Reading: GATE 1 and the Entra managementType are the only two criteria"
    say "that decide. ' A single object in the console ' has already validated three failures."
    ;;
esac

say ""
say "Full log: $LOG"
say "It contains hostname, UPN and IP addresses - review it before sharing."

sleep 0.3
[[ ${#FAILURES[@]} -eq 0 ]] || exit 1
exit 0
