# Linux Intune enrollment troubleshooting

The case this folder documents: **fresh Ubuntu registrations silently fail to complete MDM
enrollment**, while the existing estate keeps working. If you hit it, the estate looks healthy right
up until you reset or re-image a machine - and then that machine never comes back under management.

## Symptom

- A new endpoint enrolls: the agent loops on retry, no inventory is reported, the device stays
  `Not evaluated` / `Not compliant`.
- Enrollment happens in two steps - (1) the device registers an identity in Microsoft Entra,
  (2) Intune attaches the management (MDM) relationship on that identity. **Step 1 passes, step 2
  no longer does.** The attributes that declare the device managed - `managementType`,
  `deviceOwnership`, `isManaged`, `isCompliant` - stay permanently empty. Check-in returns `404`,
  the agent retries forever.

## The tell

A registration created "now" stores the OS version **malformed**: the full URL-encoded label
(`Ubuntu+24.04.4+LTS`, where `+` are spaces) instead of the version alone (`24.04`). Devices
registered earlier carry the clean value - and work. The client computes `24.04` correctly (visible
in its journal), so it's the **registration** that mangles the value, not the client that sends it
wrong.

## What was established

| Hypothesis | Verdict |
|---|---|
| Intune Linux service outage | **No** - ~15 Linux devices on the same tenant/scale unit are managed and sync, one on the same day |
| Client version regression | **No** - 3 `intune-portal` versions and the 2 broker versions the dependency allows give the same result |
| The endpoint or its OS image | **No** - `os-release` strictly standard, physical machine, identity rebuilt from scratch 4x, wipe verified, device certificate persisted, auth + network conform |
| Intune or Edge mis-installed | **No** - both fully reinstalled, caches/profiles/keyring secrets included |

## What remains unknown

Who mangles the value: the identity broker at write time, or the service at receive time.
Undecidable from the endpoint (traffic is pinned, no inspection; no earlier broker version is
installable because `intune-portal` requires `>= 3.0.1` and the repo serves nothing between `2.0.1`
and `3.0.1`). Chronology points at the 3.0 broker branch (healthy devices came from a 2.0.x, broken
ones from a 3.0.x) - a presumption, not proof.

## The decisions that protect the estate

1. **Do not re-enroll any Linux device** until this is settled. Each re-enrollment destroys a working
   registration without being able to create a new working one - it's the only action that actually
   makes things worse.
2. **Open a support case as a precise question** ("why are registrations created now malformed while
   April ones aren't, on the same tenant?"), not as an outage claim that gets refuted on sight. See
   [`microsoft-support-case-template.md`](microsoft-support-case-template.md).
3. **Keep one broken test machine as-is** - it's the reproducible evidence, and support will ask for
   fresh logs.
4. Defender for Endpoint coverage is intact and independent of Intune - the gap is management and
   compliance, not endpoint protection.

## Method note (the part worth reusing)

Three intermediate conclusions had to be dropped along the way - "service-side fault", "Linux channel
regression", "no Linux device was ever managed" - all resting on a badly chosen comparison (a Windows
device taken as reference for a Linux one; a test on the agent when the broker was the culprit; a
Graph filter that only returned Defender records). **It's the healthy devices, queried in one request,
that settled everything.** They were readable from the start.

> **Rule for the next incident: compare against the working baseline before instrumenting the broken
> one.**

## Files here

| File | Use |
|---|---|
| [`Diagnose-Compliance.ps1`](Diagnose-Compliance.ps1) | Read-only Graph diagnostic: tenant compliance fallback, Linux compliance policies + assignments, per-device state, broken device vs healthy baseline. Writes a transcript you must review before sharing. |
| [`microsoft-support-case-template.md`](microsoft-support-case-template.md) | Ready-to-fill support case (English body), with placeholders for tenant/scale-unit/device IDs. |
| [`reenroll-runbook.md`](reenroll-runbook.md) | Step-by-step clean re-enrollment / reset of the Intune perimeter on an Ubuntu endpoint. |
| [`fresh-reinstall.sh`](fresh-reinstall.sh) | Full teardown + reinstall of the Intune client and identity broker (packages, repo, keyring secrets, state), for a clean reproduction. |

> The diagnostic transcript and any logs you collect **contain tenant IDs, hostnames and UPNs**.
> They are git-ignored here - review before sharing, never commit them.
