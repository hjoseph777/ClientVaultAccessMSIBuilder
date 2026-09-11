# Independent Review Report 2 — ClientVaultAccessMSIBuilder

**Date:** 2026-09-11
**Scope:** ClientVaultAccessMSIBuilder.ps1, Start.bat, tests/Test-StartBatArgs.ps1, profiles.json
**Context:** Internal-only tool. Builds customized M-Files client MSI packages. Operator authenticates via Windows SSO.

## Score: 9.5 / 10

## Recommendation

Advised for internal use as-is. One optional, non-blocking config cleanup noted below.

## What changed since the prior review round

`Start.bat`'s argument validator was upgraded from a denylist to a strict whitelist:

- Only alphanumeric characters, `.`, `-`, `_`, `:` are accepted for `-Profile` / `-Lang` / `-ServerAddress` inputs.
- Any other character is rejected outright before the value ever reaches PowerShell.

This is a stronger security posture than a denylist because it does not depend on having enumerated every dangerous character in advance.

Regression suite re-verified after the change:

```
16/16 test cases passed
```

Launcher contract (0/1/2 positional args) confirmed intact.

## Current state of prior findings

| Area | Status |
|---|---|
| Argument/command injection (launcher) | Resolved — whitelist-grade validation |
| COM lifecycle (connect/disconnect/release) | Clean — release on every path, no leaks found |
| StrictMode-safe JSON/property access | Clean — no direct dot-access on untrusted config nodes |
| Network address resolution fallback | Clean — FQDN → hostname → explicit abort with remediation guidance |
| Secret handling (M-Files Authentication fallback) | Present in code, inert in this environment (SSO succeeds, so the plaintext-password branch never executes) |
| Regression coverage | 16/16 passing |

## Open item (non-blocking)

`profiles.json` still has:

```json
"authType": "auto"
```

Since Windows SSO is confirmed working, pinning this to `"1"` would:

- Remove the plaintext-password fallback code path entirely (not just leave it unused).
- Skip the SSO retry/fallback delay logic on every run.
- Match the PRD's own documented guidance for environments with confirmed SSO.
- Produce byte-identical `<AuthType>` values in generated client MSIs (since `"auto"` already resolves to `"1"` today).

This is optional and does not block internal use. Not yet applied — pending explicit confirmation, since `authType` is dual-purpose and also determines the `<AuthType>` written into every shipped client MSI.

## Bottom line

Safe to run internally today. The only remaining action item is an optional config pin (`authType: "auto"` → `"1"`) to close out the last theoretical, currently-inert finding.
