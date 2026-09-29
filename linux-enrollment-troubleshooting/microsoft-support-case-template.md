# Microsoft support case template - Linux Intune enrollment fails

Ready-to-fill support case for the "fresh Linux registrations never complete MDM enrollment" issue.
Replace every `<PLACEHOLDER>`. **Frame it as a precise question, not an outage claim** - an outage
claim is refuted on sight because the Linux channel works for older devices on the same tenant.

Suggested severity: **B**. Impact: no Linux device can be re-enrolled; the existing estate works but
becomes unrecoverable as soon as a device is reset.

---

## Case body (English, copy as-is)

**Title:** Linux device registrations created since ~<MONTH YEAR> never complete MDM enrollment -
`operatingSystemVersion` stored as URL-encoded `PRETTY_NAME`, `managementType` stays empty,
`LinuxDeviceCheckinService/details` returns 404

**Tenant:** `<TENANT_ID>`
**Scale unit:** `<SCALE_UNIT>` (from the check-in URL, e.g. `agents.<SCALE_UNIT>.manage.microsoft.com`)
**Affected device:** `<HOSTNAME>` - Ubuntu <VERSION> LTS, <hardware model>, serial `<SERIAL>`, physical machine

### Summary

New Microsoft Entra device registrations for Linux in this tenant never complete their MDM
enrollment. The Entra device object is created, the Intune `managedDevice` object is created and
correctly linked, but `managementType`, `deviceOwnership`, `isManaged` and `isCompliant` remain
permanently empty, and every device check-in fails.

This is **not** a tenant-wide or scale-unit outage: Linux MDM works for devices registered
in <EARLIER MONTH YEAR> on the same tenant and the same scale unit.

### Working baseline (same tenant, same scale unit)

Approximately <N> Ubuntu devices are healthy, queried with
`GET /beta/deviceManagement/managedDevices?$filter=managementAgent eq 'mdm'`:

| Device | `operatingSystem` | `osVersion` | Last sync |
|---|---|---|---|
| `<host-a>` | `Linux (ubuntu)` | 22.04 | <timestamp> |
| `<host-b>` | `Linux (ubuntu)` | 24.04 | <timestamp> |

Their Entra device objects (`GET /v1.0/devices`) all show:

- an object with `trustType: Workplace`, `managementType: MDM`
- an object with `trustType: AzureAd`, `managementType: MDM`, `isManaged: True`, `isCompliant: True`,
  **created <EARLIER MONTH YEAR>**
- `operatingSystemVersion` = `22.04` or `24.04` - a clean version string

### Failing behaviour (registrations created <DATE>)

Every fresh enrollment produces an Entra device object with:

```
trustType                     : AzureAd          (no Workplace object is ever created)
managementType                : (empty)
deviceOwnership               : (empty)
isManaged                     : (empty)
isCompliant                   : (empty)
operatingSystemVersion        : Ubuntu+24.04.4+LTS
approximateLastSignInDateTime : == createdDateTime
```

`operatingSystemVersion` is the full `PRETTY_NAME` string, **URL-encoded** (`+` = spaces), where
healthy devices carry the `VERSION_ID` value. The device's `/etc/os-release` is stock Ubuntu
(`VERSION_ID="24.04"`, `PRETTY_NAME="Ubuntu 24.04.4 LTS"`, `ID=ubuntu`), and `/etc/os-release` and
`/usr/lib/os-release` are identical.

The corresponding Intune `managedDevice` is created and correctly linked, but carries no inventory
and never syncs:

```
managementAgent   : mdm
managementState   : managed
azureADDeviceId   : (correctly matches the Entra deviceId)
operatingSystem   : Linux ()
osVersion         : 0.0.0.0
model / manufacturer / serialNumber : (empty)
lastSyncDateTime  : == enrolledDateTime, never advances
```

Every check-in then fails on an object that Microsoft Graph resolves without error:

```
exchange_device_details{device_id=<DEVICE_ID>}: Exchanging device details
Failed to checkin with Intune: Failed updating device inventory details with Intune:
  Unexpected failure: https://agents.<SCALE_UNIT>.manage.microsoft.com/TrafficGateway/
  TrafficRoutingService/LinuxMdm/LinuxDeviceCheckinService/details
  ?api-version=1.0&client-version=<CLIENT_VERSION>: status code 404
```

`GET /beta/deviceManagement/managedDevices/<DEVICE_ID>` returns the object successfully at the same
moment the check-in service returns 404 for that same id. Earlier generations on the same day
returned 500 on the same endpoint.

### Reproduction

Reproduced <N> times on <DATE>, each time with a fully wiped client and a freshly rotated device
identity (packages purged, state directories removed, keyring secrets deleted and verified at zero,
tenant objects deleted beforehand with propagation time):

| Intune `device_id` | Entra `deviceId` | Result |
|---|---|---|
| `<id>` | `<id>` | 500 |
| `<id>` | `<id>` | 404 |

`activity_id` values: `<activity_id>` (<timestamp>), `<activity_id>`, ...

### Client versions tested - not the cause

| Package | Versions tested | Result |
|---|---|---|
| `intune-portal` | `<v1>`, `<v2>`, `<v3>` | identical failure |
| `microsoft-identity-broker` | `3.0.1`, `3.0.2` | identical failure |

`microsoft-identity-broker 2.0.1` could not be tested: `intune-portal` declares
`Depends: microsoft-identity-broker (>= 3.0.1)`, and the repository serves no version between
`2.0.1` and `3.0.1`.

### Ruled out on the device, with evidence

- `/etc/os-release` is stock Ubuntu 24.04.4; `VERSION_ID="24.04"` present and well-formed.
- Keyring purge verified: secrets deleted, post-wipe re-scan returns zero, on an unlocked `Login`
  collection in a local graphical session.
- Device certificate persists after enrollment (`Intune :: signed_cert`, `id_rsa`, `id_rsa_pub`).
- Agent starts cleanly; no `238/STATE_DIRECTORY`; the systemd drop-in clearing `StateDirectory=` is
  in place. The agent exits `255/EXCEPTION` only as a consequence of the HTTP failure.
- Authentication succeeds: `Login succeeded`, silent token acquired, `isAdfs false`.
- `Dynamic pinning: trusted` on the check-in host; `HTTP client proxy: none`.
- Unique `machine-id`, real DMI, physical machine, single network interface, no bridge, no VPN.
- Inventory payload is well-formed:
  `{ device_id, device_name, manufacturer, os_distribution: "ubuntu", os_version: "24.04" }` - note
  the client computes `24.04` correctly, yet the registration stores `Ubuntu+24.04.4+LTS`.

### Impact

No Linux device in this tenant can be enrolled or re-enrolled. Devices registered earlier continue
to work, but any device that is reset, re-imaged, or whose registration is renewed becomes
permanently unmanageable. This effectively freezes the Linux estate.

### Ask

1. Why do Microsoft Entra device registrations created now for Linux store `operatingSystemVersion`
   as the URL-encoded `PRETTY_NAME` (`Ubuntu+24.04.4+LTS`) instead of the `VERSION_ID` value
   (`24.04`) that earlier devices carry?
2. Is that malformed value the reason the MDM enrollment never completes (`managementType`,
   `deviceOwnership`, `isManaged` all remain empty)?
3. Why does `LinuxDeviceCheckinService/details` return 404 for a `device_id` that
   `GET /beta/deviceManagement/managedDevices/{id}` resolves successfully?
4. Server-side trace of the `activity_id` values listed above.
