# PROGRESS.md - Project Tracker

## Status: v1.0 Enterprise Ready

Reference: manual legacy-step mapping is documented in README.md under "Manual Step to Script Mapping".

## Completed Features

- Core COM Connector: Connects to local M-Files server and enumerates online vaults.
- Live GUID Fetch: Resolves vault names to GUIDs dynamically based on profiles.json patterns.
- Package Verification: Validates base MSIs via Authenticode and SHA-256 hash against versions.json.
- MSI ProductLanguage Check: Reads MSI metadata to ensure file integrity (observational only, not compared to fra/eng due to M-Files vendor quirk).
- XML Generation: Dynamically builds CustomizeInstaller XML with auto-detected NetworkAddress.
- CLI and Menu Argument Disambiguation: Handles 0, 1, and 2 argument contracts for languages and profiles.
- Enterprise Reliability - Timeouts: cscript.exe wrapped in 300s timeout process.
- Enterprise Reliability - File Locks: Retry logic (5 attempts, 2s delay) for MSI move and manifest write.
- Enterprise Reliability - COM Cleanup: Strict ReleaseComObject implementation.
- Persistent Logging: Timestamped logs in output\ with 30-day auto-pruning.

## Backlog (Future Features)

- FI-3: Central Manifest Registry: Add Copy-Item logic to push manifests to a central UNC share for dashboard observability.
- MSI Code Signing: Implement certificate signing for output MSIs (requires cert procurement).
- CI/CD Integration: Wrap start.bat in GitHub Actions or Azure DevOps for automated testing.
- Configurable Package/Output Paths: externalize base-MSI package
  location and `$outputDir` (currently hardcoded to kit-local
  `output\` in `ClientVaultAccessMSIBuilder.ps1`) into `profiles.json`,
  so the base MSIs and build output can live at a different location
  than the kit folder. Deferred by operator decision on 2026-07-25 —
  keep hardcoded for now.

## Latest Update (2026-07-24)

- Reviewed proposed all-in-one 4-file consolidation model and did a PRD alignment check.
- Decision: keep current PRD architecture (external `profiles.json` + `versions.json`) as the default implementation.
- Confirmed `start.bat` remains the launcher to preserve seamless `-ExecutionPolicy Bypass` operator experience.
- Documented architecture decision in README.md under `Architecture Decision (Current)`.
- Added collaboration workflow preferences to CLAUDE.md:
	- ask clarification when ambiguous,
	- request permission before non-trivial coding,
	- read CLAUDE.md and Skills.md before edits,
	- update progress.md after each coding round.

## Latest Update (2026-07-24) - Server Name/IP Override via start.bat

- Confirmed the script already supports `-ServerAddress` in `ClientVaultAccessMSIBuilder.ps1` for overriding generated client `NetworkAddress`.
- Implemented a PRD-safe launcher enhancement in `Start.bat` without changing positional argument rules:
  - supports `SERVER_ADDRESS` environment variable,
  - supports `MFILES_SERVER_ADDRESS` environment variable (takes precedence if both are set).
- Behavior: operators can now pass either FQDN/server name or IP address through `start.bat` while keeping existing 0/1/2-arg contract intact.
- Updated README.md with concrete examples for hostname and IP usage.

## Latest Update (2026-07-24) - Application Report Added

- Added a new `Application Report` section to README.md.
- The report summarizes end-to-end runtime behavior: launcher contract, pre-flight checks, live COM vault resolution, package integrity checks, network-address override flow, XML generation, VBS execution, output artifacts, and failure model.

## Latest Update (2026-07-24) - Architecture Clarification

- Added an explicit clarification to README.md that this repo is not all-in-one by default.
- Confirmed current default remains PRD-aligned external configuration via profiles.json and versions.json.

## Latest Update (2026-07-24) - Handoff Note Placement

- Added a prominent handoff note at the top of the `Application Report` section in README.md.
- Note explicitly states that the tool is external-config driven (`profiles.json` + `versions.json`) and calls out operator pre-run checks for `packageShare`, pinned version, and SHA-256 hashes.

## Latest Update (2026-07-24) - Live Server Run: Two Critical Bugs Fixed

MFServer was started for the first time in this project's history, enabling
a real end-to-end test instead of synthetic/code-review verification only.

- **CRITICAL, fixed:** `Test-PreflightEnvironment`'s
  `Get-Service -Name 'MFServer'` never matches a real installation.
  The actual Windows service Name is version-suffixed (confirmed live:
  `MFServer 26.6.16115.9`, not `MFServer`). Guaranteed failure on every
  real M-Files server, undiscoverable without a live install. Fixed by
  matching `$_.Name -eq 'MFServer' -or $_.Name -like 'MFServer [0-9]*'`
  (deliberately excludes the separate `MFServerAux ...` service).
  File: `ClientVaultAccessMSIBuilder.ps1` (Test-PreflightEnvironment).
- **CRITICAL, fixed:** `Get-OnlineVaults`'s COM `Connect(...)` call was
  wrong on every count - used 5 arguments against a real 9-parameter
  signature (`AuthType, UserName, Password, Domain, ProtocolSequence,
  NetworkAddress, Endpoint, LocalComputerName, AllowAnonymousConnection`,
  confirmed via `Get-Member` against the live-registered MFilesAPI COM
  object). `AuthType 0` (assumed "logged-on Windows user") was also
  wrong - `AuthType 1` is what actually authenticates. Confirmed the
  real enum by loading the vendor's own
  `Interop.MFilesApi.dll` (found under
  `C:\Program Files\M-Files\<version>\Bin\anycpu\`) and reading
  `[MFilesAPI.MFAuthType]` directly: `0 = MFAuthTypeUnknown`,
  `1 = MFAuthTypeLoggedOnWindowsUser` (Windows SSO - the only method
  this server has configured), `2 = MFAuthTypeSpecificWindowsUser`,
  `3 = MFAuthTypeSpecificMFilesUser`. The original comment was off by
  one, not a different auth model. Fixed to the correct 9-arg call
  with `AuthType 1`, sourcing `ProtocolSequence`/`Endpoint` from
  `profiles.json` instead of hardcoding.
  File: `ClientVaultAccessMSIBuilder.ps1` (Get-OnlineVaults).
- **Verified completely, live, after both fixes:** ran a full build
  against the real server with `profiles.json`'s vault patterns
  temporarily pointed at the server's real vaults (`acme`,
  `Developer Certificate`). Pre-flight passed, COM connected, live
  GUIDs were fetched, package integrity passed, a real MSI was built
  (exit 0), and the manifest correctly recorded the real vault
  names/GUIDs and auto-detected NetworkAddress (`DESKTOP-DKCS42P`).
  **The produced MSI's actual Windows Installer Registry table was
  queried directly** and contains exactly correct
  `ServerVaultName`/`ServerVaultGUID`/`NetworkAddress`/
  `ProtocolSequence`/`Endpoint`/`AuthType`/`AutoLogin`/
  `MinimumAuthenticationLevel` entries for both vaults.
  `profiles.json` was restored to its original `conform`/`approb`
  patterns afterward (hash-verified restore); the test-generated
  MSI/manifest were deleted.
- This closes the item every prior review round listed as the
  dominant remaining blocker: **the full pipeline, including live COM
  vault/GUID fetch, is now proven correct end-to-end against a real
  M-Files server**, not just via synthetic tests and code review.
- Full regression suite (`tests\Test-StartBatArgs.ps1`, 15/15) re-run
  and passing after both fixes.

## Latest Update (2026-07-24) - Auto Auth-Type Detection Added

Confirmed the real `MFAuthType` enum by loading the vendor's own
`Interop.MFilesApi.dll` directly: `0 = MFAuthTypeUnknown`,
`1 = MFAuthTypeLoggedOnWindowsUser` (Windows SSO),
`2 = MFAuthTypeSpecificWindowsUser`,
`3 = MFAuthTypeSpecificMFilesUser`. This server has only SSO
configured, confirmed by the operator.

- Added `authType: "auto"` support to `profiles.json`. When set,
  `Get-OnlineVaults` tries Windows SSO (`AuthType 1`, no credentials)
  first; if that fails, it prompts via `Get-Credential` and retries
  with M-Files Authentication (`AuthType 3`). Whichever succeeds
  becomes the detected auth type for the run.
- The detected value overwrites `$Config.server.authType`, so it
  flows into both the build's own COM session and the `<AuthType>`
  written into every deployed client MSI from that run - this ties
  two previously-independent values together **by explicit operator
  decision**, made after being shown the tradeoff (a build-machine
  auth detail now determines every shipped client's own AuthType).
- **The `Get-Credential` fallback is a deliberate, informed exception
  to the PRD's "only interactive moment is the language menu"
  invariant** (also flagged before implementing): if SSO fails under
  `"auto"`, an unattended/scheduled run will block indefinitely
  waiting for a credential prompt with no operator present. Operators
  running this kit unattended should pin `authType` to a fixed value
  instead of `"auto"` unless SSO is confirmed working in that
  environment.
- New helper `Connect-MFilesServer` centralizes the 9-arg `Connect()`
  call so the SSO attempt and the M-Files-Authentication fallback
  don't duplicate the call site.
- Updated `profiles.json`'s default from `"3"` to `"auto"` - required,
  not optional: leaving it at a fixed `"3"` would have made the
  build's own COM connection try `AuthType 3` (M-Files Authentication)
  with no credentials on every run, a self-inflicted regression on
  the very server just proven working via SSO.
- **Live-verified end-to-end, twice:** once with `authType: "auto"`
  (detected SSO, logged "Connection successful using Windows SSO
  (AuthType=1)"), once with a fixed `authType: "1"` (same result via
  the non-auto code path). A full build was run with vault patterns
  temporarily pointed at the server's real vaults, and **the produced
  MSI's Registry table was queried directly** to confirm
  `AuthType=#1` was correctly written for both vaults - not just
  logged, but actually present in the shipped artifact.
  `profiles.json` restored afterward; test MSI/manifest deleted.
- Full regression suite (`tests\Test-StartBatArgs.ps1`, 15/15) re-run
  and passing.
- PRD §6, CLAUDE.md hard rule 15, and Skills.md §4 updated to
  document the dual-purpose `authType` value and the interactive
  exception explicitly - this is now a documented, ground-truth
  behavior, not an undocumented side effect.

## Latest Update (2026-07-24) - SSO Retry Before Credential Fallback

Added a 2-attempt retry (10s apart) around the Windows SSO connect
step, so a slow COM response on a loaded server isn't misread as SSO
being unavailable and doesn't trigger an unnecessary credential
prompt.

- Reused the existing `Invoke-WithRetry` helper (already used for
  the MSI move/manifest-write retries) rather than writing new retry
  logic, wrapping the `Connect-MFilesServer` SSO call with
  `-MaxAttempts 2 -DelaySeconds 10`.
- **Live-verified the retry count is exactly right, not off by one:**
  forced a real connection failure (temporarily set an invalid
  `endpoint` in `profiles.json`) and watched the actual log output:
  `[WARN] ... attempt 1/2 ... Retrying in 10 second(s)...`, a real
  10-second wait, then `[WARN] ... failed after retries ... Falling
  back to M-Files Authentication.` - confirming exactly 2 total
  attempts, no third, before the fallback. Stopped the run before it
  reached the interactive `Get-Credential` prompt (no way to answer
  it non-interactively in this environment) and confirmed no
  orphaned `powershell.exe` process was left running against the
  server afterward.
- Also confirmed the success path (real endpoint restored) still
  connects on the first attempt with no added delay - the retry
  wrapper only activates on genuine failure.
- `profiles.json` restored to its correct `endpoint` afterward; full
  regression suite (`tests\Test-StartBatArgs.ps1`, 15/15) re-run and
  passing.

## Latest Update (2026-07-24) - Audit Housekeeping Closed Out

Actioned the remaining low-risk findings from the independent audit -
all were doc/orphan-file only, no code changes.

- Deleted `ClientVaultAccessMSIBuilder.ps1.txt` - a stale, pre-rename
  duplicate of the main script (confirmed via hash mismatch and old
  `$Profile` parameter style before deleting).
- Deleted `M-Files_Online_x64_fra_client_26_5_16015_4_EV.msi` - the
  superseded base MSI; `versions.json`'s `pinned` is `26_6_16115_13`
  and has no entry for `26_5_16015_4`, so this file was never
  referenced by any code path.
- Fixed README's "Local Test Directory Tree" to list the current
  `26_6_16115_13` filenames instead of the stale `26_5_16015_4` ones.
- Repo root confirmed clean afterward: exactly one script file, one
  base MSI per language, both matching the pinned version.
- Full regression suite (`tests\Test-StartBatArgs.ps1`, 15/15) re-run
  and passing; script hash unchanged by this cleanup.

## Latest Update (2026-09-11) - Security and Robustness Hardening (No Goal Change)

- Hardened `Start.bat` argument handling without changing the existing
  positional contract (`0/1/2` args behavior unchanged):
  - wrapped forwarded `-Profile` / `-Lang` / `-ServerAddress` values in
    explicit quotes,
  - added unsafe-character guard (`"`, `&`, `|`, `<`, `>`, `^`) for
    launcher-provided values to reduce command/argument injection risk.
- Removed StrictMode-fragile dynamic JSON/property access in
  `ClientVaultAccessMSIBuilder.ps1` by introducing safe property-name
  enumeration helper and by resolving profile/vault key data through
  guarded access paths.
- Improved `Get-NetworkAddress` resilience:
  - primary path remains DNS FQDN detection,
  - now falls back to local host name with explicit warnings,
  - aborts with a clear remediation message only if both lookups fail.
- Validation:
  - full launcher regression suite re-run and passing:
    `tests\Test-StartBatArgs.ps1` -> `===== All cases PASSED =====` (15/15).

## Latest Update (2026-07-25) - Duplicate Logic Rollback to Previous Baseline

- Rolled back duplicate-vault resolver behavior to the previous strict implementation (same as prior baseline):
  - each in-scope key must resolve to exactly one vault,
  - any in-scope duplicate match remains a fatal pre-flight error.
- Removed timestamp-driven duplicate selection and manifest duplicate-audit extensions that were introduced after the baseline.

## Latest Update (2026-07-25) - Local CMD Shortcut Added

- Added `Build-FRA.cmd` to the kit root as a simple local shortcut.
- Behavior: runs from its own folder and calls `Start.bat fra` with no path assumptions.
- Purpose: avoid long `cmd.exe /k ...` launch strings and OneDrive/Desktop path variants.

## Latest Update (2026-07-25) - English CMD Shortcut Added

- Added `Build-ENG.cmd` to the kit root as a matching English shortcut.
- Behavior: runs from its own folder and calls `Start.bat eng` with no path assumptions.
- Updated README and Skills wording to match the restored behavior.

## Latest Update (2026-07-25) - OpenCMD Helper Documented

- Added documentation for `OpenCMD.bat` in README and Skills.
- `OpenCMD.bat` opens a CMD session in `ClientVaultAccessMSIBuilder` using fallback lookup:
  - `%USERPROFILE%\Desktop\ClientVaultAccessMSIBuilder`
  - `%USERPROFILE%\OneDrive\Desktop\ClientVaultAccessMSIBuilder`
- Purpose: give operators a quick command-prompt entrypoint before running `start.bat` or shortcut commands.

## Latest Update (2026-07-25) - Profile Label Normalization for `both`

- Updated profile display labeling so `both` is shown as `Conformity and Approbation` in build progress and summary output.
- Updated output MSI naming for `both` from `_Both.msi` to `_ConformityAndApprobation.msi` for clearer artifact semantics.
- Kept CLI contract unchanged (`start.bat both fra|eng` still the invocation form).

## Latest Update (2026-07-25) - README Operator Prerequisite Note

- Added an explicit prerequisite note in README How To: operators should run commands from the `ClientVaultAccessMSIBuilder` directory.

## Latest Update (2026-07-25) - Start.bat Shell Consistency Hardening

- Updated `Start.bat` to compute an absolute script path (`%~dp0ClientVaultAccessMSIBuilder.ps1`) and fail early if that script is missing.
- Updated launcher invocation to execute PowerShell through `%ComSpec% /d /c` for consistent behavior across parent shells.
- Re-ran `tests/Test-StartBatArgs.ps1` (15/15 passing) to confirm positional argument contract remained unchanged.

## Latest Update (2026-09-11) - Live Server Run: Silent Stop After Vault Enumeration Fixed

A live run on the real M-Files server (7 online vaults, Windows SSO) consistently
stopped right after `[SUCCESS] Enumerated 7 online vault(s).` with no `[ERROR]`
line in either the console or `output\build_*.log` — nothing to diagnose from.

- **Step 1 (diagnostic hardening):** wrapped the client/builder `AuthType`
  reconciliation block (between `Get-OnlineVaults` and `Resolve-Vaults`) in
  `try/catch -> Invoke-Abort`. That block wasn't previously guarded, so any
  exception inside it terminated the run via PowerShell's default error
  rendering — console-only, never reaching `Write-Stage`/the log file, and lost
  entirely once the launching window closed. This surfaced the real error on
  the next run: `Exception setting "clientAuthType": "The property
  'clientAuthType' cannot be found on this object."`
- **Step 2 (root cause, fixed):** `$config.server.clientAuthType = ...` and
  `.builderAuthType = ...` were plain dot-assignments to properties that don't
  exist in `profiles.json`'s schema. A `ConvertFrom-Json` `PSCustomObject` only
  allows dot-assignment for properties it already has; creating a *new*
  property that way throws under `Set-StrictMode -Version Latest`. Fixed by
  switching both to `$config.server | Add-Member -NotePropertyName X
  -NotePropertyValue Y -Force`. Left `$config.server.authType = ...` as
  dot-assignment since `authType` already exists in the schema.
  File: `ClientVaultAccessMSIBuilder.ps1` (main flow, client/builder AuthType
  reconciliation block).
- Confirmed the vault patterns themselves (`conform` / `approb`) were never
  the problem — they correctly substring-match vault names containing
  "conform"/"approba" (PowerShell `-match` is case-insensitive by default).
- Syntax-validated via `[System.Management.Automation.Language.Parser]::ParseFile`
  after both edits (no live M-Files server available in the dev environment to
  run the full pipeline end-to-end). Operator to confirm on next real run.
- Documented the underlying PSCustomObject dot-assignment gotcha in Skills.md
  §4 so it isn't rediscovered the same way again.
- **Follow-up hardening:** wrapped the entire `# ---- Main ----` flow (from
  `Get-KitConfig` through the final `exit 0`) in a top-level `try/catch` ->
  `Invoke-Abort`, so any future unanticipated exception anywhere in the run
  is logged instead of silently vanishing - not just the one block above.
  Confirmed empirically (isolated `pwsh` test) that `exit 1`/`exit 0` inside
  the `try` still terminate the process directly and are never intercepted
  by the new `catch` - existing exit codes and control flow are unchanged.
- Also added a console `Write-Progress` bar tracking each profile x language
  build step (percent complete, current step label), completed at the end of
  the run - purely a console UX addition, no change to the log format or
  CLI contract.
- Re-scanned the whole script for the same dot-assignment-on-new-property
  bug class: no other instances found (`$config.packageShare` and
  `$config.server.authType` are pre-existing schema keys, safe; `$el.InnerText`,
  `$psi.*`, `$proc.StartInfo` are real .NET object properties, not dynamic
  PSCustomObject properties, unaffected).
