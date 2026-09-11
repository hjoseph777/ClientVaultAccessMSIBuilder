# CLAUDE.md - ClientVaultAccessMSIBuilder (Connector I)

Project instructions for AI-assisted development.

## 1. Program Baseline (Connector I)

- Objective: transform manual MSI customization into a single deterministic CLI workflow.
- Current status: v1.0 Enterprise Ready.
- Execution model: run locally on the target M-Files server; kit outputs artifacts to local `output\`.
- Phase status:
   - Phase 1 (Core Connector and COM integration): completed.
   - Phase 2 (Automation and pipeline): completed.
   - Phase 3 (Enterprise reliability): completed.
   - Phase 4 (Central registry and handoff): backlog (manifest push to central share, packaging handoff assets).

## 2. Document Map and Precedence

- Primary requirements source: `ClientVaultAccessMSIBuilder_PRD.md`.
- Technical implementation inventory: `Skills.md`.
- Planning snapshot: `PLAN.md` (if present in the repo).
- Precedence rule: if any instruction conflicts with the PRD, the PRD wins.

## 3. AI Operating Directives

- Read first: always read ClientVaultAccessMSIBuilder_PRD.md before proposing architecture or behavior changes. Read Skills.md for technical stack, required files, dependencies, and operational inventory.
- Source of truth: the PRD is the primary requirements source. If any instruction conflicts with the PRD, follow the PRD. If there is ambiguity, defer to the PRD.
- Deterministic only: keep behavior deterministic and CLI-first. Never introduce AI-driven runtime logic.
- Backlog isolation: nothing in Feature.md may be implemented, scaffolded, or referenced as a requirement unless explicitly directed by the user.
- Collaboration preference: if requirements are ambiguous, ask clarifying questions before coding.
- Permission gate: request user confirmation before starting non-trivial code changes.
- Session hygiene: read CLAUDE.md and Skills.md before edits, and update progress.md at the end of each coding round.

## 4. What This Project Is

A PowerShell kit that builds customized M-Files client MSI packages from live vault metadata.
It is an MSI builder only: no endpoint deployment orchestration, no server-side vault writes, and no workflow provisioning.

Main flow:
start.bat -> ClientVaultAccessMSIBuilder.ps1 -> pre-flight -> live vault GUID fetch (COM) -> XML generation -> CustomizeInstaller2.3.vbs -> output MSI + manifest

Default run builds three profiles in one execution: conformity, approbation, and both.

## 5. Ground Truth and Scope

- Primary requirements source: ClientVaultAccessMSIBuilder_PRD.md.
- Technical implementation inventory source: Skills.md.
- If a previous instruction conflicts with the PRD, follow the PRD.
- If there is ambiguity or doubt, defer to ClientVaultAccessMSIBuilder_PRD.md.
- Keep behavior deterministic and CLI-first; no AI-driven runtime logic.

## 6. Hard Rules (Do Not Violate)

1. Never hardcode credentials, secrets, or fixed customer server values.
2. Never require manual vault GUID entry. GUIDs must be fetched live from M-Files COM at build time.
3. Never modify vendor script CustomizeInstaller2.3.vbs unless explicitly requested by the user.
4. Target Windows PowerShell 5.1 for COM-dependent logic (MFilesAPI interop).
5. Never perform server-side writes to vault structure/configuration in this project.
6. Keep pre-flight as a hard gate: if pre-flight fails, abort before any MSI is emitted.
7. Duplicate or missing vault matches are fatal (abort), not a prompt-driven selection — but only for vault keys the current run's profiles actually require. A run resolves and enforces only its in-scope keys; anomalies (duplicate or zero match) on out-of-scope keys never abort, they print a one-line notice so the operator can fix it before a later full-set run.
8. Keep package versioning pinned through versions.json; do not silently float versions.
9. Preserve language behavior: menu default is French on Enter, with CLI override via -Lang fra|eng|all. The menu's own display language defaults to English (toggle with F/E) — independent of which MSI language is selected. Building both languages ("all") is CLI-only, never a menu option.
10. Do not leave partial output MSI artifacts on failure.
11. COM connection is always localhost (script runs on the M-Files server). The NetworkAddress written into the generated client XML is the server's network-reachable hostname/FQDN, auto-detected — never localhost. -ServerAddress overrides detection; still no per-deployment config edit.
12. Nothing in Feature.md may be implemented, scaffolded, or referenced as a requirement unless the user explicitly directs it — it is a contemplated-only backlog, not part of the build contract.
13. start.bat's positional args are disambiguated, not fixed-position: zero args show the language menu; one arg is checked against the language tokens (`fr|fra|en|eng`, case-insensitive, normalized to `fra`/`eng`) and, if recognized, builds the full 3-profile default set in that language with no menu; a first arg that isn't a language token is a profile name, and if given alone the language silently defaults to `fra` (no menu, no third argument ever appears — the menu appears only on a truly bare invocation). Two args are always `<profile> <lang>`.
14. Any dynamic/computed JSON property access on a `ConvertFrom-Json` result (`profiles.json`, `versions.json`) must go through the `Get-JsonValue` helper (try/catch based), never a direct `.property` or `.$variable` dot-access and never a `.PSObject.Properties.Name -contains` pre-check. Both of the latter throw under `Set-StrictMode -Version Latest` when the key is missing — and the pre-check approach *also* throws when the target node is itself an empty `{}` object (confirmed empirically: an empty node's own `.PSObject.Properties` collection doesn't expose `.Name`/`.Count` under strict mode either). `Get-JsonValue` is the only pattern proven safe against all of: missing key, null value, and empty-object value.
15. `profiles.json`'s `server.authType` is dual-purpose: it drives both the build machine's own COM authentication (in `Get-OnlineVaults`) and the `<AuthType>` value baked into every deployed client MSI from that run — the same detected/pinned value is used for both, deliberately (see PRD §6). Setting it to `"auto"` tries Windows SSO (`MFAuthType 1`) first, then falls back to a `Get-Credential` prompt for M-Files Authentication (`MFAuthType 3`) if SSO fails. **This is a deliberate, explicit exception to rule 9's "only interactive moment" framing** — if `authType` is `"auto"` and SSO fails, the credential prompt is a second interactive moment and will block indefinitely under an unattended/scheduled run. Confirmed the real `MFAuthType` enum (0=Unknown, 1=LoggedOnWindowsUser, 2=SpecificWindowsUser, 3=SpecificMFilesUser) by loading the vendor's own `Interop.MFilesApi.dll` — never guess these values again.

## 7. Architecture and Pipeline Constraints

- Launcher: start.bat invokes PowerShell with -NoProfile -ExecutionPolicy Bypass and passes profile/language args.
- Orchestrator: ClientVaultAccessMSIBuilder.ps1 handles config loading, pre-flight, profile loop, XML generation, customizer invocation, and manifest output.
- Config files:
  - profiles.json: packageShare, server settings, vaultPatterns, profiles, defaults.
  - versions.json: pinned version, expected hashes, VBS file identity.
- External dependencies:
  - UNC package share hosting base MSI files and versions.json.
  - MFilesAPI COM for online vault enumeration.
  - cscript.exe for CustomizeInstaller2.3.vbs execution.
  - .NET DNS lookup (hostname/FQDN) for NetworkAddress auto-detection, overridable via -ServerAddress.
- Kit structure (portable, copied per customer server): start.bat, ClientVaultAccessMSIBuilder.ps1, profiles.json, CustomizeInstaller2.3.vbs, README.md, output\ (generated MSIs + manifests + build log). Base MSIs and versions.json stay on the central package share — never copied into the kit.

## 8. Pre-Flight Requirements

Pre-flight must validate, in order, before any build:

1. Environment readiness:
   - MFServer service present and running.
   - package share reachable.
   - required files present.
   - cscript.exe available.
2. COM connectivity and online vault enumeration.
3. Vault resolution by pattern, scoped to the keys the run's profiles require:
   - exactly one match per in-scope key passes,
   - zero or multiple matches on an in-scope key abort,
   - zero or multiple matches on an out-of-scope key print a notice only — never abort.
4. Package integrity for selected language(s):
   - expected file exists,
   - Authenticode is valid,
   - SHA-256 matches versions.json,
   - ProductLanguage is present/readable (abort if not — corrupt file), but NOT compared against a fra/eng expected value: M-Files MSIs report ProductLanguage 1033 regardless of client-language variant (confirmed empirically on real fra/eng packages), so that comparison has zero discriminating power for this vendor. The SHA-256 pin is the actual language guarantee — established once by a human confirming the file's real language at intake (see versions.json refresh procedure). ProductLanguage is still read and recorded in the manifest for observability.

## 9. Build Behavior Requirements

- Default build set is three profiles; optional narrowing by -Profile and -Lang.
- Supported CLI switches: -Profile, -Lang fra|eng|all, -ServerAddress (override auto-detected NetworkAddress), -KeepXml (retain generated XML for debugging instead of deleting it after build).
- Generate XML from template data, with vault blocks driven by resolved live GUIDs.
- Invoke customizer with xml mode and explicit sign=False behavior per PRD.
- Name outputs using the standardized pattern including language, pinned version, and profile.
- Emit one manifest JSON per output MSI with vault resolution and hash evidence.
- Print run summary and exit non-zero if any profile fails.
- Every run also writes a persistent build log (`output\build_<timestamp>.log`, no BOM) mirroring the console's `[PROGRESS]/[SUCCESS]/[WARN]/[ERROR]` lines. Logs older than 30 days are pruned automatically at startup (cleanup failure never blocks the build).
- `cscript.exe` invocations have a 300s timeout; on timeout the process is killed and that profile/language is marked failed, pipeline continues to the next.
- MSI move and manifest-write file operations retry up to 5 times (2s delay) to tolerate transient AV/EDR file locks.
- COM objects (`MFilesAPI`, `WindowsInstaller.Installer`, vault enumeration results) are explicitly released via `Close-ComObjectSafe` as soon as their values are extracted.
- The language menu has a fourth option, `[X] Exit` / `[X] Quitter`, to cancel without building anything — exits non-zero (1), never 0, since no artifact was produced.

## 10. Conventions

- Scripts: Verb-Noun.ps1, Set-StrictMode -Version Latest, $ErrorActionPreference = 'Stop'.
- Logging tags: [PROGRESS], [SUCCESS], [WARN], [ERROR].
- Prefer clear fail messages: what failed, expected vs actual, and exact remediation.
- Keep paths relative to script root for kit-local files.

## 11. PowerShell Refactoring Guardrails

Use this guidance when rewriting or refactoring PowerShell in this repo.

### Primary rules (non-negotiable)

- Function-first: Prefer reusable, single-purpose functions over inline logic.
- Encapsulation: Keep the top-level flow small; place operational details in functions.
- No spaghetti: Keep orchestration linear and readable; avoid large branching blocks.
- Reliability must not change:
   - Preserve integration behavior, side effects, and external interfaces.
   - Do not change expected parameters, outputs, exit codes, file paths, environment variables, or network behavior.
   - Preserve operation order when order affects outcomes.
- Refactoring safety:
   - If behavior is ambiguous, ask for clarification before coding.
   - Do not alter logic in ways that change results.

### Maintenance safety (orphan and duplication control)

- Prevent orphan code:
   - Remove unused functions/variables introduced during refactoring.
   - Do not leave partially migrated code paths.
- Prevent duplication:
   - Centralize repeated logic into helpers.
   - Avoid copy/paste variants with only tiny differences.
- Backward compatibility:
   - Keep public interfaces stable, including parameters and callable entry points used by tooling.
   - Ensure any new helper functions are actually used.

### Code quality requirements

- Use clear, consistent naming.
- Add parameter validation when appropriate.
- Prefer explicit error handling and consistent logging.
- Keep functions focused on one responsibility.
- Maintain a clean, natural code flow and strictly avoid spaghetti coding.
- Prioritize function-based structure over inline blocks.
- Keep comments practical and human-written; avoid AI-style commentary.
- Keep main execution in a small orchestration block or a `Main` function.
- Ensure the script remains directly runnable as-is.

### Expected delivery format for major refactors

When returning substantial refactor work, provide:

1. A brief structure summary (functions added, kept, removed).
2. The full corrected script.
3. Top-level execution that only invokes the orchestrator (no scattered execution logic).

## 12. Testing and Validation Expectations

- Unit-test XML generation as a pure transform from resolved inputs.
- Validate built MSI content via WindowsInstaller COM checks (for expected vault registry entries).
- Treat COM-dependent tests as environment-gated integration tests on Windows hosts with M-Files components available.
- `tests\Test-StartBatArgs.ps1` regression-tests Start.bat's positional argument contract against the real, unmodified batch file (temporarily swaps in a stub .ps1 to capture what's forwarded, then restores the real script). Run it after any change to Start.bat's argument logic.

## 13. Common Commands

```bat
start.bat                        &  menu (Enter = French), then 3 MSIs
start.bat fra                    &  no menu — 3 MSIs, French
start.bat approbation fra        &  no menu — 1 MSI (Approbation, French)
start.bat both eng               &  no menu — 1 MSI (Both vaults, English)
```

Full grid (any profile × any language) is in README.md.

```powershell
.\ClientVaultAccessMSIBuilder.ps1
.\ClientVaultAccessMSIBuilder.ps1 -Profile approbation -Lang fra
.\ClientVaultAccessMSIBuilder.ps1 -Lang all
```

## 14. Non-Goals to Protect

- No endpoint distribution automation (GPO/Intune/SCCM) in this tool.
- No automatic package download from vendor endpoints.
- No output MSI signing in v1 unless explicitly requested.

## 15. When Extending

- Keep extensions aligned with PRD milestones and failure model.
- Add hooks instead of parallel mechanisms.
- Preserve portability of the kit model (copy folder, run, produce local output).
