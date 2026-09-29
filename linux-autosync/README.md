# Linux — silent Intune auto-sync (no manual "Synchronize" click)

Goal: after a **single** interactive enrollment (the user opens the portal once, signs in with Entra
+ MFA), an Ubuntu endpoint syncs with Intune **on its own, silently, at a regular interval** — no one
ever has to reopen `intune-portal` and click *Synchronize*.

This is achieved with **three system files** dropped under `/etc` (plus one global enable). None of
them lives in a user's `$HOME`, so an account created **later** inherits the behaviour with no extra
step — which makes this suitable for imaging machines **before** any user is enrolled.

> **You do not push this through Intune.** Intune for Linux can only deliver compliance policies and
> custom scripts, not config-file management. The vector here is your imaging/baseline tooling (or the
> installer in this folder), laying the files down as root.

## The three Intune components on Linux

The `intune-portal` package installs three **distinct** pieces:

| Component | Type | Role | Runs when |
|---|---|---|---|
| `intune-portal` | GUI app | The light front-end with the *Synchronize* button. **Does nothing on its own.** | When the user opens it |
| `intune-daemon.service` | **system** service (root) | Applies policies that touch the system | Always |
| `intune-agent.service` | **user** service | Polls Intune ("any new policy?") and triggers the sync | While a graphical session is open |

**The *Synchronize* button only wakes up `intune-agent`.** Wake it automatically and the button
becomes unnecessary.

## What the files do

### 1. `etc/systemd/user/intune-agent.timer.d/override.conf` — the cadence

A systemd **drop-in** (never edit the vendor file in `/usr/lib`, an `apt upgrade` would overwrite it;
`/etc` always wins on merge). Sets the first sync 1 min after session start, then every 10 min.

```ini
[Timer]
OnStartupSec=1min
OnUnitActiveSec=10min
RandomizedDelaySec=30s
```

Check the effective cadence: `systemctl --user list-timers | grep intune` — the `NEXT` column should
fall around 10–12 min (the vendor unit keeps `AccuracySec=2m`, so treat 10 min as a floor, not a
period).

### 2. `etc/systemd/user/intune-agent.service.d/override.conf` — **the fix that makes it work**

This is the decisive one. Without it, the background agent **never** checks in, whatever cadence you
set. The vendor unit `/usr/lib/systemd/user/intune-agent.service` declares `StateDirectory=intune`,
which breaks the agent in **one of two ways depending on the client build**:

- **Mode 1 — the agent never starts.** On Ubuntu 24.04, systemd cannot provision `~/.local/state`
  for a *user* unit, so the agent dies in `status=238/STATE_DIRECTORY` **before exec**, doing nothing.
- **Mode 2 — the agent starts but looks in the wrong place.** systemd injects
  `$STATE_DIRECTORY=~/.local/state/intune` — an **empty** directory. The agent reads its registration
  there, doesn't find it (the real one is `~/.config/intune/registration.toml`, consulted only when
  `$STATE_DIRECTORY` is absent), and logs on every timer tick:

  ```
  Skipping checkin with Intune: Cannot checkin before a user logs in
  ```

Both are the same underlying path bug in the Intune Linux client. The drop-in fixes **both** at once:

```ini
[Service]
StateDirectory=
ExecStart=
ExecStart=/usr/bin/env -u STATE_DIRECTORY /opt/microsoft/intune/bin/intune-agent
```

Clearing `StateDirectory=` removes the directive itself (fixes mode 1 — clearing only the env var is
**not** enough, because the failure happens in systemd's preparation phase, before `ExecStart`).
Empty `ExecStart=` then cancels the original command; the second line relaunches the same binary with
`env -u STATE_DIRECTORY` so it reads `~/.config` (fixes mode 2). Then `systemctl --user daemon-reload`.

### 3. `etc/polkit-1/rules.d/50-intune.rules` — suppress the password prompt

When the user-service agent needs a root action via the daemon, Linux goes through **polkit**, which
pops "Authentication required" — exactly what breaks unattended operation. A narrow rule returns
`YES` for the identified Intune action only:

```javascript
polkit.addRule(function(action, subject) {
    if (action.id == "com.microsoft.intune.actions.ConfigureDevice") {
        return polkit.Result.YES;
    }
});
```

> Scope kept deliberately narrow: only `ConfigureDevice`. If another Intune action reprompts during
> debugging, list the real actions with `pkaction | grep intune` and add it.

## Install

```bash
sudo ./install-autosync.sh
```

The installer copies the three files, reloads systemd, enables the timer **globally** (so accounts
created afterwards inherit it: `systemctl --global enable intune-agent.timer`), and prints the checks
below. It is idempotent.

## Verify

```bash
# Cadence is applied
systemctl --user list-timers | grep intune          # NEXT ~10-12 min

# The check-in actually succeeds (run inside a graphical session)
systemctl --user start intune-agent.service
journalctl --user -u intune-agent.service --since "2 min ago" \
  | grep -iE 'login succeeded|policy_count|cannot checkin'
```

Expected: `Login succeeded` then `Processing assigned policies policy_count=N`, with **no window and
no password prompt**. The `Cannot checkin before a user logs in` lines *before* enrollment are normal.

## Inherent limits (not bugs)

- **A graphical session must be open.** `intune-agent` is a *user* service — it only syncs while
  someone is logged into a graphical session. Powered-off machine or login screen = no sync. Fine for
  a 1 machine = 1 person model.
- **The cloud has its own rhythm.** A 10 min client cadence does not make Intune distribute a policy
  faster than its server-side schedule. You gain re-check responsiveness, not instant delivery.

## How the timer behaves before enrollment (measured)

`intune-agent.service` is `Type=oneshot`. A oneshot that fails goes to *failed* without reaching
*active*, which could suggest the timer stays silent until the next session — the exact case of a
session opened before enrollment. **Measured: the re-arm happens anyway.** Successive ticks fire, all
failing `Cannot checkin` before enrollment, then the first tick after enrollment succeeds. No
`OnUnitInactiveSec=` is needed.

The base unit carries `PartOf=graphical-session.target` and `WantedBy=graphical-session.target`; that
target holds the activation link placed by `systemctl --global enable` — which is the technical
translation of the "session required" limit above.
