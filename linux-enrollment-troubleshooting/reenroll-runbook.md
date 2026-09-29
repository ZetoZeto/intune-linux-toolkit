# Runbook - clean re-enrollment of a Linux device in Intune

For when a Linux (Ubuntu) endpoint must be re-enrolled from scratch: broken enrollment, stuck
`Not evaluated`, or a device that has to be reset with a fresh identity against a clean tenant.

Companion scripts: [`fresh-reinstall.sh`](fresh-reinstall.sh) (wipe/install/check),
[`Diagnose-Compliance.ps1`](Diagnose-Compliance.ps1) (Graph diagnostic).

## Golden rules

1. **Tenant first, device second.** Most failed re-enrollments come from the reverse order: the
   device is rebuilt while the tenant still holds the conflicting objects. Delete tenant-side, wait
   for propagation, then touch the device.
2. **One device at a time.** Don't rebuild device B until device A is validated. Two parallel
   failures are indistinguishable from a device-vs-device collision.
3. **`wipe` runs in a local graphical session only** (never SSH), with the login keyring **unlocked**.
   Otherwise the secret purge silently removes nothing (see the keyring trap below).
4. **The two real success criteria** are: (a) the device's Entra identity actually rotated, and
   (b) the Entra object *completes* (`managementType` becomes `MDM`, `deviceOwnership` fills in). "A
   single object in the console that survives a few cycles" is **not** a success criterion - it can be
   true of a broken enrollment.

---

## Phase 0 - Verify the tenant is really empty (admin Windows machine)

Deleting the device from Intune and Defender does **not** delete the device object in Entra. Check
both, from PowerShell with the Microsoft.Graph module.

```powershell
Connect-MgGraph -Scopes "DeviceManagementManagedDevices.ReadWrite.All","Device.ReadWrite.All" -NoWelcome

$HOST = 'linux-test'   # the device host name / display-name prefix

# 0.1 - Intune: should return 0 objects for this host
$u  = "https://graph.microsoft.com/beta/deviceManagement/managedDevices?`$filter=managementAgent eq 'mdm'"
$lx = (Invoke-MgGraphRequest -Method GET -Uri $u).value | Where-Object operatingSystem -match 'Linux'
$lx | Where-Object deviceName -like "$HOST*" |
     Select-Object deviceName,id,serialNumber,azureADDeviceId,enrolledDateTime | Format-Table -AutoSize

# 0.2 - Entra: this is where orphans survive
$ent = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/devices?`$filter=startswith(displayName,'$HOST')").value
$ent | Select-Object id,displayName,deviceId,trustType,isManaged,operatingSystem | Format-Table -AutoSize
```

> **Graph filter trap.** Filtering on `operatingSystem eq 'Linux'` returns **only Defender
> (`msSense`) records**. Real MDM enrollments carry the string `Linux (ubuntu)` and are found by
> `managementAgent eq 'mdm'`. Mixing these up leads to wrong conclusions.

**Gate 0:** both counts must be `0`. If Entra objects remain, review then delete, and **wait
~15 minutes** for propagation before Phase 1:

```powershell
$ent | Select-Object id,displayName | Format-Table -AutoSize      # review before deleting
foreach ($d in $ent) { Invoke-MgGraphRequest -Method DELETE -Uri "https://graph.microsoft.com/v1.0/devices/$($d.id)" }
```

---

## Phase 1 - The device

### 1.1 The `STATE_DIRECTORY` drop-in - required, do not remove

The stock unit `/usr/lib/systemd/user/intune-agent.service` declares `StateDirectory=intune`. On
Ubuntu 24.04, systemd cannot provision `~/.local/state` for a *user* unit and the agent dies in
`status=238/STATE_DIRECTORY` **before doing anything** - which produces a half-created device object
in both Intune and Entra.

The drop-in shipped by the package only does `env -u STATE_DIRECTORY`, which acts on the child
environment; the failure happens earlier, in systemd's preparation phase. You must **clear the
directive itself**:

```bash
sudo mkdir -p /etc/systemd/user/intune-agent.service.d
sudo tee /etc/systemd/user/intune-agent.service.d/override.conf >/dev/null <<'EOF'
[Service]
StateDirectory=
ExecStart=
ExecStart=/usr/bin/env -u STATE_DIRECTORY /opt/microsoft/intune/bin/intune-agent
EOF
sudo chmod 0644 /etc/systemd/user/intune-agent.service.d/override.conf
systemctl --user daemon-reload
```

> The drop-in lives in `/etc` but its directory is removed by `apt purge` and is **not restored by a
> `--reinstall`**. It must be rewritten after each reinstall. `fresh-reinstall.sh install` writes it
> automatically. A `mkdir -p ~/.local/state` does **not** substitute for it.

**Mandatory check before any enrollment:**

```bash
systemctl --user start intune-agent.service
systemctl --user status intune-agent.service --no-pager -l | head -20
```

- `ExecStart=/usr/bin/env -u STATE_DIRECTORY ...` visible and a failure on authentication (no account
  signed in) -> **green light**, you may enroll.
- `status=238/STATE_DIRECTORY` -> **stop**. Enrolling now would create a half-formed device object.

### 1.2 Wipe (including the identity broker)

```bash
systemctl --user stop intune-agent.timer intune-agent.service
./fresh-reinstall.sh wipe        # broker + Edge included by default; --only-intune to keep Edge
sudo reboot
```

Wiping the **broker** is essential: the device identity is linked in
`~/.config/intune/registration.toml` and in the keyring. Without it the host reuses the same identity
and nothing changes.

> **The keyring trap.** If the login keyring is unreachable or locked, the secret purge returns
> `TOTAL=0` and looks like a success while the **device certificate survives** - the re-enrollment
> then reuses the same Entra identity. `fresh-reinstall.sh` treats `TOTAL=0` as a **blocking error**
> when in-scope packages were installed, and refuses to run outside a local graphical session or with
> a locked keyring. Do not bypass this. The wipe must end on `HOST CLEAN`.

Seahorse note: the device identity does not live only under "Intune" - also under **Microsoft**,
**broker**, **MSAL**, **WorkplaceJoin**, **device registration** entries. Missing those is exactly
what makes a naive wipe ineffective. Never `rm -rf ~/.local/share/keyrings/` - that deletes all
session secrets (wifi, apps).

### 1.3 Reinstall and enroll under monitoring

```bash
./fresh-reinstall.sh install
sudo reboot
```

In a terminal, **before** opening the app:

```bash
journalctl --user -u 'intune*' -f
```

Then open the Company Portal and sign in. **Watch for:**

```
Exchanging device inventory properties with Intune
exchange_device_details{device_id=<NEW GUID>}: Exchanging device details
```

...**without** a trailing `Failed to checkin with Intune: ... status code 500/404`. Note the new
`device_id` - it must differ from the previous one.

### 1.4 Validation (the two real gates)

Let the timer run ~10-15 min, then run `./fresh-reinstall.sh check`, or verify by hand:

```bash
systemctl --user status intune-agent.service            # inactive (dead), NOT failed
journalctl --user -u 'intune*' -b | grep -c 'status code 500'   # should be 0
```

Tenant-side:

```powershell
$lx | Where-Object deviceName -like "$HOST*" |
     Select-Object deviceName,id,azureADDeviceId,lastSyncDateTime | Format-Table -AutoSize
$ent = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/devices?`$filter=startswith(displayName,'$HOST')").value
$ent | Select-Object displayName,trustType,managementType,deviceOwnership,isManaged,isCompliant,
      @{n='created';e={$_.createdDateTime}},@{n='lastSignIn';e={$_.approximateLastSignInDateTime}} | Format-List
```

**Success =** exactly **one** object for the host, **and** within ~10 min `managementType` becomes
`MDM` and `deviceOwnership` fills in. An object that is `isManaged: True` with `managementType`
**empty** is an **unfinished** object - the signature of the `STATE_DIRECTORY` failure. A second tell:
`approximateLastSignInDateTime` equal to `createdDateTime` means the credential was never used.

If either gate fails, **stop** - do not proceed to the next device. See *When to escalate*.

---

## Phase 2 - Additional devices

Only after Phase 1 is fully validated. Same sequence (1.1 -> 1.4). If devices were cloned from the same
image, verify identity uniqueness first - a shared `machine-id` will collide:

```bash
hostnamectl
cat /etc/machine-id
sudo dmidecode -s system-serial-number
```

If the `machine-id` matches another device:

```bash
sudo rm -f /etc/machine-id && sudo systemd-machine-id-setup
sudo rm -f /var/lib/dbus/machine-id && sudo ln -s /etc/machine-id /var/lib/dbus/machine-id
sudo reboot
```

Then confirm two distinct objects in the console (different `deviceName`, `serialNumber`,
`azureADDeviceId`), and that device A did not regress after B's enrollment.

---

## Phase 3 - Re-onboard Defender for Endpoint

A device removed from the tenant is also out of Defender coverage.

- **MDE deployed via Intune** (app + configuration profile): onboarding re-applies automatically after
  Intune enrollment. Check after ~30 min: `mdatp health --field org_id` and `mdatp health --field healthy`.
- **MDE onboarded manually**: get the Linux onboarding package from the Defender portal
  (*Settings -> Endpoints -> Onboarding -> Linux Server -> Local Script*), then:

  ```bash
  sudo apt-get update && sudo apt-get install -y mdatp
  unzip <OnboardingPackage>.zip
  sudo python3 MicrosoftDefenderATPOnboardingLinuxServer.py
  mdatp health --field org_id       # non-empty
  mdatp health --field licensed     # true
  mdatp health --field healthy      # true
  ```

- **Azure Arc-managed fleet**: onboard via Arc (*Azure Arc -> Machines -> Add -> Generate script*), then
  enable **Defender for Servers** in Defender for Cloud - MDE deploys automatically on Arc machines.

Confirm each device appears **once** in the Defender inventory, with no duplicate from old objects.

> Defender coverage is **independent of Intune**. If the Intune management gap persists, MDE is your
> real security coverage on Linux in the meantime - deploy it regardless.

---

## Understanding `Not evaluated`

`Not evaluated` has two possible, independent causes - diagnose which one with
[`Diagnose-Compliance.ps1`](Diagnose-Compliance.ps1):

1. **No compliance policy targets the device.** If every Linux compliance policy targets *All
   Devices* but the device sits in an **excluded group**, none applies -> no evaluation is even
   scheduled. The tenant fallback setting *"Mark devices with no compliance policy assigned as"*
   (`secureByDefault`) then decides compliant vs not-compliant. This is a **grouping/assignment**
   issue, unrelated to any check-in error.
2. **No inventory.** If the agent never completes a single `exchange_device_details`, Intune has no
   data to evaluate -> `Not evaluated`, and `Model`/`Manufacturer`/`Serial number` show `Not
   available`. This one is fixed by fixing the check-in; compliance repairs itself once the first
   inventory lands.

Don't chase a phantom "exclusion to remove" or try to repair compliance directly until you know which
of the two you have.

---

## When to escalate to Microsoft support

Local troubleshooting is done - open a case - when a clean re-enrollment against an empty tenant with
a fresh identity still fails on `LinuxDeviceCheckinService/details`. The strongest, unfalsifiable
evidence to include:

- **The service is not self-consistent**: the same endpoint returning **HTTP 500 then 404** seconds
  apart, same device, same session, byte-identical request. No local cause can produce two different
  status codes for two identical requests - it points to backend instances disagreeing on whether the
  device object exists.
- **Client version is not the cause**: two client versions (current and one prior) produce an
  identical failure. Test a downgrade to prove it, but **do not stay pinned** on an old version - L1
  support requires the current version before escalating, so a pinned-old client is a bounce excuse:

  ```bash
  ./fresh-reinstall.sh install --pkg-version <older-version> --hold   # test only
  ./fresh-reinstall.sh install --unhold                               # then go back to current
  ```

- **Everything client-side ruled out, with evidence**: auth + federation working, dynamic pinning
  trusted, no proxy, device certificate persisted in an unlocked keyring, state dirs user-owned,
  unique `machine-id`, real DMI (not a VM/clone), single interface no bridge/VPN, well-formed
  inventory payload.
- **The `activity_id` values** from the failing check-ins (`fresh-reinstall.sh check` collects them),
  plus tenant ID and scale unit - see [`microsoft-support-case-template.md`](microsoft-support-case-template.md).

Frame the case as a **precise question about the malformed registration**, not as an outage claim -
an outage claim is refuted on sight because Linux MDM works for older devices on the same tenant.

---

## Pitfalls (hard-won)

- **Never** chain `apt autoremove` behind `apt purge intune-portal` - it removes every unused package.
- Purging `microsoft-identity-broker` also breaks **Edge/Teams SSO** on the host. Acceptable on a test
  machine; document it if you industrialize the procedure.
- When purging tenant-side, **always filter by name** (`<host>*`). A `foreach` over all Linux devices
  would take out your other endpoints.
- A **masked** unit never starts and emits no error. After a failed purge/install cycle, check
  `systemctl --user is-enabled intune-agent.service` and unmask if needed.
- Graph returns **UTC**. Convert timestamps, or you'll mistake current objects for an earlier
  generation.
- `msSense` object with the same `deviceName` is the **Defender** record, not an MDM enrollment.
  Normal to see it duplicated - don't delete it.

---

### Lesson learned (why order and the drop-in matter)

The first agent run right after enrollment is the one that **finalizes** the device object. If it dies
on `238/STATE_DIRECTORY` (missing drop-in), you get two objects created but permanently unfinished:
`MDM: None` in Entra, `Not available` inventory in Intune, and a check-in endpoint that cannot resolve
the device. That is why section 1.1 (the drop-in) must be verified **before** enrolling, and why the wipe
must rotate the identity **before** a fresh attempt - retrying on the half-created object changes
nothing.
