<!--
  Thanks for the PR! Please confirm the checklist below.
  Never include tenant IDs, hostnames, UPNs, device IDs or unredacted logs.
-->

## What this changes

<!-- One or two sentences. Link the issue it closes, if any. -->

## Tested on

- OS:
- intune-portal / broker version (if relevant):
- What I ran to verify:

## Checklist

- [ ] No secrets or real identifiers (tenant/hostname/UPN/device ID) in code, comments or output
- [ ] Shell scripts stay idempotent and safe to re-run; destructive actions are scoped to an allowlist
- [ ] Line endings are LF (`.gitattributes` enforces this)
- [ ] `shellcheck` clean on changed `.sh` (or noted why not)
- [ ] Docs updated if behaviour changed
