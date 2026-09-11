# PRD — ClientVaultAccessMSIBuilder

**Project name:** ClientVaultAccessMSIBuilder
**Entry point:** `start.bat` → `ClientVaultAccessMSIBuilder.ps1`
**Author:** Harry Joseph — System Integrator/Developer
**Date:** 2026-07-18
**Status:** Draft v0.1

> Generates vault-specific M-Files client installers from live server data — no GUI, no manual GUIDs, one command.

---

## 1. Problem Statement

Deploying the M-Files desktop client with pre-configured vault connections currently requires manually retrieving each vault's server name and GUID, hand-editing the `CustomizeInstaller.xml` customization file, and running `CustomizeInstaller2.3.vbs` against the base MSI. This process is:

- **Error-prone.** GUIDs are typed or pasted by hand. A stale or mistyped GUID produces an MSI that installs successfully but connects to nothing.
- **Repetitive.** Different user groups need different vault sets (Approbation only, Conformity only, or combined), so the process repeats per deployment profile and per language (fra/eng).
- **Fragile across vault lifecycle events.** Restoring or re-attaching a vault assigns a new GUID, silently invalidating any previously built installer.

## 2. Solution Overview

A PowerShell CLI tool that automates the full pipeline:

```
package repo lookup → signature/hash verification → live vault GUID fetch (COM)
→ profile-driven XML generation → CustomizeInstaller2.3.vbs invocation
→ named output MSI + build manifest
```

The tool runs directly **on the target M-Files server** (COM connection via localhost). GUIDs are **always fetched live** from the server at build time — never stored, never hand-entered.

**Usage:**

```bat
start.bat                        &  menu (Enter = French), then 3 MSIs
start.bat fra                    &  no menu — 3 MSIs, French
start.bat eng                    &  no menu — 3 MSIs, English
start.bat approbation fra        &  no menu — 1 MSI (Approbation, French)
start.bat conformity fra         &  no menu — 1 MSI (Conformity, French)
start.bat approbation eng        &  no menu — 1 MSI (Approbation, English)
start.bat conformity eng         &  no menu — 1 MSI (Conformity, English)
start.bat both fra               &  no menu — 1 MSI (Both vaults, French)
start.bat both eng               &  no menu — 1 MSI (Both vaults, English)
```

**Argument contract (positional, disambiguated by first token):**

- **Zero arguments** → language menu (§5.4), then the full default set: 3 MSIs.
- **One argument that is a language token** (`fr | fra | en | eng`, case-insensitive; `fr`→`fra`, `en`→`eng` normalized internally) → menu bypassed, full default set: 3 MSIs in that language.
- **Two arguments: `<profile> <lang>`** → menu bypassed, 1 MSI for that profile in that language. Valid profiles: `conformity`, `approbation`, `both`.
- **No third argument exists.** The argument count is the signal: two args = 1 MSI, one arg = 3 MSIs, zero args = menu + 3 MSIs.
- Disambiguation rule: if the first argument is a recognized language token it is treated as the language (all profiles built); otherwise it is treated as a profile name. Unambiguous because no profile is named `fr`/`fra`/`en`/`eng`.
- `-Lang all` (direct PowerShell invocation) → both languages, 6 MSIs. CLI-only; not a menu or positional option.

Any profile (`conformity` | `approbation` | `both`) combines with any language (`fra` | `eng`).

`start.bat` launches PowerShell with `-NoProfile -ExecutionPolicy Bypass -File ClientVaultAccessMSIBuilder.ps1`, mapping positional arguments to `-Profile` / `-Lang` per the contract above. Direct invocation remains available:

```powershell
.\ClientVaultAccessMSIBuilder.ps1                              # menu, then all three profiles
.\ClientVaultAccessMSIBuilder.ps1 -Lang fra                    # no menu, all three profiles
.\ClientVaultAccessMSIBuilder.ps1 -Profile approbation -Lang fra
```

### 2.1 Default output set

| # | Output MSI | Vault connections configured | GUIDs |
|---|---|---|---|
| 1 | `..._Conformity.msi` | Conformity only — Approbation not visible in client | 1 |
| 2 | `..._Approbation.msi` | Approbation only — Conformity not visible in client | 1 |
| 3 | `..._Both.msi` | Conformity + Approbation | 2 |

Each MSI configures client connections **only** for its listed vaults; the other vault is simply never connected, so it does not appear in the user's client. Note: this controls connection/visibility, not authorization — server-side vault permissions remain the security boundary.

## 3. Goals

- G1. Build all three vault-access MSIs with a single command and at most one keypress (the language menu; fully promptless with `-Lang`).
- G2. Eliminate all manual handling of vault GUIDs.
- G3. Support French and English base packages via the startup menu or `-Lang` — never separate procedures.
- G4. Produce an auditable manifest for every generated MSI.
- G5. Fail loudly and early on any inconsistency (missing vault, bad signature, missing package) — never emit a partially correct installer.

## 4. Non-Goals (Out of Scope)

- **No server-side writes.** The tool reads vault name/GUID only. It never modifies vault structure, workflows, or configuration.
- **No AI / prompt-driven behavior.** Fully deterministic. (Any AI-assisted tooling is a separate project with its own PRD.)
- **No automated download of base MSIs from M-Files.** The installed client auto-updates from `findupdates.m-files.com`; the deployment package only needs to be recent enough to install cleanly. Package refresh is a deliberate, manual, few-times-a-year event (see §6).
- **No endpoint distribution.** Pushing the generated MSI (GPO, Intune, SCCM) is downstream of this tool.
- **No code signing of output MSIs in v1.** `sign` is passed as `False`. Revisit post-adoption (see §12 Open Questions).

## 5. Architecture & Pipeline

### 5.1 Components

| Component | Role |
|---|---|
| `start.bat` | Launcher — invokes PowerShell with `-NoProfile -ExecutionPolicy Bypass`, forwards arguments |
| `ClientVaultAccessMSIBuilder.ps1` | Orchestrator CLI (PowerShell 5.1+, runs on admin tool server) |
| `profiles.json` | Vault-access profiles + server connection settings |
| `versions.json` | Pinned package version + verification hashes |
| Package repository (UNC share) | Base MSIs (fra/eng) + `CustomizeInstaller2.3.vbs` |
| M-Files COM API (`MFilesAPI.MFilesServerApplication`) | Live vault name/GUID enumeration |
| `CustomizeInstaller2.3.vbs` (`xml` mode) | Applies generated XML to a copy of the base MSI |

### 5.2 Pipeline steps

1. **Load config.** Read `profiles.json` and `versions.json`. Resolve requested profiles (default: all three) and language (default: **fra**; `-Lang eng` or `-Lang all` to override).
2. **Language selection.** Show the startup menu (§5.4) unless `-Lang` was supplied — Enter defaults to French.
3. **Pre-flight check (gate).** Runs in strict order — each layer must pass before the next is attempted:
   - **a. Environment check (first, always):** the **M-Files Server service (`MFServer`) is installed and running** on this machine (the COM API depends on the service, not on the Admin GUI being open); the **package share is reachable** and contains `versions.json`; kit files are present (VBS, configs); `cscript.exe` is available. Any failure here aborts in the first second with a plain message (e.g. *"M-Files Server service (MFServer) is not running. Start the service, then rerun the script."*).
   - **b. Server connection:** connect via COM and enumerate online vaults.
   - **c. Vault resolution per §5.3** (duplicate check — abort on ambiguity).
   - **d. Package verification:** the pinned base MSI(s) for the selected language(s) exist in the repo with valid signatures and matching hashes.

   Any pre-flight failure aborts the entire run with a clear message — no MSI is generated. Resolved names and GUIDs are reused by all builds in the run (single COM session).
4. **Per-profile build loop.** For each profile: generate XML, invoke customizer, name output, write manifest (steps below).
5. **Generate XML.** Render the customization XML from the standard template, replacing the commented `<Vault>` blocks under `<Client><Vaults>` with one populated block per profile vault (`ServerVaultName`, live `ServerVaultGUID`, `ProtocolSequence`, `NetworkAddress`, `Endpoint`, `AuthType`, `AutoLogin`, `SPN`, `MinimumAuthenticationLevel` from profile/server config). Apply the profile's auto-update policy (§7).
6. **Invoke customizer.** `cscript CustomizeInstaller2.3.vbs xml <baseMsi> <generatedXml> <outputMsi> True False` (silent build, no signing). Non-zero exit code fails that profile's build.
7. **Name & manifest.** Output MSI named `M-Files_Online_x64_{lang}_client_{version}_EV_{Profile}.msi`; write manifest (§8) beside it. Clean up the temp XML (or retain with `-KeepXml` for debugging).
8. **Run summary.** Print per-profile result (built / failed + reason) and exit non-zero if any profile failed. Because pre-flight validates shared prerequisites, a per-profile failure at this stage should be rare (e.g. cscript error); when it occurs, remaining profiles still build.

## 6. Deployment Model & Kit Structure

**Operating model:** each customer engagement provisions a **new M-Files server**. After the Conformity and Approbation vaults are imported on that server, the kit folder is copied onto it and run once to generate the customized client MSIs. The tool is a **portable kit** — no installation and no per-server configuration edits; its only runtime dependency is read access to the central package share.

**Kit** (copied to each new server — small, instant to copy):

```
ClientVaultAccessMSIBuilder\
    start.bat
    ClientVaultAccessMSIBuilder.ps1
    profiles.json          ← includes "packageShare" path
    CustomizeInstaller2.3.vbs
    README.md              ← 10-line runbook: what it does, 3 steps, top 2 errors
    output\                ← generated MSIs + manifests + build log
```

**Central share** (single source of truth for base packages, maintained in one place):

```
\\SRV\MFiles\packages\
    M-Files_Online_x64_fra_client_26_5_16015_4_EV.msi
    M-Files_Online_x64_eng_client_26_5_16015_4_EV.msi
    versions.json          ← pinned version + SHA-256 hashes, lives WITH the MSIs
```

- **Base MSIs are read from the share at build time; customized output is written locally** to the kit's `output\` folder. No large files are ever copied into the kit.
- `versions.json` lives beside the MSIs it describes — refreshing packages and recording hashes is one atomic act in one location, and every future deployment on every server picks up the new pin automatically.
- **All kit paths are relative** (`$PSScriptRoot` / `%~dp0`); the only external path is the share, held in `profiles.json`.
- **Server address for COM is always `localhost`** — the script runs on the M-Files server it interrogates.
- **Nothing is edited per deployment.** Pattern-based vault matching (§5.3), the language menu (§5.4), localhost COM, and auto-detected NetworkAddress mean the same kit runs unmodified on every customer server.

**Version policy: pin by default, float never.** The build always uses the version pinned in `versions.json`. Moving to a new M-Files release is a deliberate act performed once on the master kit: drop the new fra/eng MSIs in, **confirm the `fra` file actually installs the French client (one-time manual verification per version — see below)**, record their SHA-256 hashes, update `pinned`. Because installed clients auto-update themselves, this refresh is needed only a few times per year, and only to keep fresh installs current-enough.

**Why the manual language confirmation matters:** M-Files MSIs report `ProductLanguage 1033` regardless of whether they're the `fra` or `eng` client variant — the MSI's own metadata cannot distinguish them. So the SHA-256 recorded here *is* the language guarantee from that point forward: a human confirms once, at intake, that the file named `fra` is genuinely the French client, and every subsequent build cryptographically verifies it's still that exact byte-for-byte file. There is no automated substitute for that one-time check.

**`versions.json`:**

```json
{
  "pinned": "26_5_16015_4",
  "vbs": "CustomizeInstaller2.3.vbs",
  "packages": {
    "26_5_16015_4": {
      "fra": { "sha256": "<hash>" },
      "eng": { "sha256": "<hash>" }
    }
  }
}
```

**`profiles.json`:**

```json
{
  "packageShare": "\\\\SRV\\MFiles\\packages",
  "server": {
    "endpoint": "2266",
    "protocolSequence": "ncacn_ip_tcp",
    "authType": "auto",
    "autoLogin": "0",
    "minimumAuthenticationLevel": "1"
  },
  "vaultPatterns": {
    "conformity":  "conform",
    "approbation": "approb"
  },
  "defaultProfiles": ["conformity", "approbation", "both"],
  "profiles": {
    "conformity":  { "vaultKeys": ["conformity"],                "autoUpdate": true },
    "approbation": { "vaultKeys": ["approbation"],               "autoUpdate": true },
    "both":        { "vaultKeys": ["conformity", "approbation"], "autoUpdate": true }
  }
}
```

Profiles reference **vault keys**, not exact names. Each key resolves to one live vault via the rules in §5.3. Patterns use language-neutral roots (`conform`, `approb`) so French and English vault names match identically, case-insensitive.

**`server.authType` is dual-purpose and can be `"auto"`.** The same value drives two things: (a) how the build machine itself authenticates its own COM connection to the M-Files server to fetch live vault GUIDs, and (b) the `<AuthType>` value written into every deployed client MSI from that run (§5.2 step 5). Setting it to a fixed numeric value (e.g. `"1"`) uses exactly that method for the build's own COM connection and pins the same value into every output MSI. Setting it to `"auto"` instead:

1. Attempts the build's own COM connection via Windows SSO (`MFAuthType 1`, `MFAuthTypeLoggedOnWindowsUser` — the current process's Windows identity, no credentials ever passed).
2. If SSO fails, prompts the operator via `Get-Credential` for M-Files Authentication credentials and retries via `MFAuthType 3` (`MFAuthTypeSpecificMFilesUser`).
3. Whichever method succeeds becomes the value used for that run — both for the remainder of the build and for the `<AuthType>` baked into the output MSIs.

**This is a deliberate, explicit exception to the single-interactive-moment invariant** stated elsewhere in this document (§5.3, §5.4): if `authType` is `"auto"` and SSO fails, the `Get-Credential` prompt is a *second* interactive moment, and will block indefinitely in an unattended/scheduled run with no operator present to answer it. Operators running this kit unattended must either confirm SSO works in that environment beforehand, or pin `authType` to a fixed value rather than `"auto"`.

**NetworkAddress in the generated XML:** the COM connection is `localhost` (script runs on the server), but the XML written into the client MSI must contain the server's **network-reachable name** — that's what user desktops will connect to. The script auto-detects it at runtime (machine hostname / FQDN, e.g. `[System.Net.Dns]::GetHostEntry('').HostName`) and prints the detected name in the run summary so the operator can spot a wrong value (e.g. a server not yet joined to its final domain). An optional `-ServerAddress` parameter overrides detection for edge cases — still no config edit.

### 5.3 Vault Resolution (pre-flight, once per run)

Vault names may carry project suffixes (`Conformity_construction Jean Paul`), and temporary working copies (`...cp1`) may exist mid-project. Policy: **two vaults with similar Conformity or Approbation names cannot coexist at build time — no exceptions.** The check runs at the very beginning of every run, before anything else. Resolution per key, fully non-interactive.

**Resolution scope: the run resolves only the vault keys its output MSIs reference.** The full default set (3 MSIs, includes Both) requires both keys. `conformity`-only requires only `conform`; `approbation`-only requires only `approb`; the `both` profile requires both keys. This permits staged onboarding: a single-vault MSI can be built and shipped before the other vault is imported, while the full set still demands a complete environment. The COM enumeration always observes all online vaults; scope governs only what is *required*. Zero-match and duplicate rules below apply **within the run's scope**; anomalies on out-of-scope patterns (e.g. two `conform` matches during an approbation-only build) never block the run but are reported as a one-line notice (*"note: 2 vaults match 'conform' — resolve before running the full set"*) as early warning for a later full run. When an in-scope key fails to resolve, the abort message always prints the full list of online vaults — so an operator who typed the wrong profile sees what actually exists and can self-correct. The script never substitutes an available vault for a requested one and never asks "did you mean" — an explicit instruction that contradicts the environment is refused, both sides shown, human resolves.

1. **Pattern match.** Case-insensitively match all online vault names against the key's pattern (`conform` / `approb`):
   - **Exactly one match** → auto-select (the normal case).
   - **Multiple matches** → **abort the run immediately.** Message states the rule and the fix, e.g.:
     > *Only one Conformity vault can exist. Found 2 online: "Conformity_construction Jean Paul", "Conformity_construction Jean Paul cp1" [possible copy]. Detach or remove the extra vault in M-Files Admin, then rerun the script.*
     Names containing copy/test markers (`cp`, `copy`, `test`, `backup`) are flagged `[possible copy]` to point at the likely candidate for removal. The message says **detach or remove** — detaching (taking the vault offline) is sufficient and non-destructive.
   - **Zero matches** → abort; print the pattern and the full list of online vaults for diagnosis.
2. Resolution happens **once per run**, before any build. All profiles in the run (including "Both") use the same resolved pair — the three MSIs are guaranteed mutually consistent.

**Invariant:** every run resolves exactly one vault per **in-scope** key, with zero interactive prompts during vault resolution and zero overrides. A duplicate or missing vault within scope is an environment error: the script names it, the operator corrects it, the script is rerun. Out-of-scope anomalies are noticed, never enforced. The three-MSI default set is only ever produced from a complete, unambiguous environment — the mutual-consistency guarantee (the Both MSI contains the same two vaults as the singles) holds because the full set and the `both` profile always require both keys. (The only interactive moment in the entire tool is the language menu, §5.4 — one keypress, defaulting on Enter, bypassable with `-Lang`.)

### 5.4 Language Selection (startup menu)

The base MSI language is chosen by the operator at startup via a titled menu — the integrator performing the deployment always knows the customer's language, so the tool asks rather than infers. **The menu itself displays in English by default, with a toggle to switch the menu display to French** (menu display language and MSI language are independent choices):

```
=========================================
          CLIENT VAULT CREATION
=========================================

 Select client MSI language:

   [1] French   (default)
   [2] English

   [F] Afficher le menu en français
   [X] Exit

 Selection (Enter = 1): _
```

Pressing `F` redraws the same menu with French labels (`[E] Display menu in English` toggles back):

```
=========================================
          CLIENT VAULT CREATION
=========================================

 Choisir la langue du client MSI :

   [1] Français   (défaut)
   [2] English

   [E] Display menu in English
   [X] Quitter

 Sélection (Entrée = 1) : _
```

- **Enter or `1`** → French MSI (default, reflecting the predominantly French customer base). **`2`** → English MSI.
- **`X`** → cancel without building anything. Exits non-zero (never 0) — no artifact was produced, so a caller checking the exit code must not read this as success.
- Building **both** languages is not a menu option — it remains available via the command line only (`-Lang all`), for the operator who explicitly wants six MSIs.
- **`-Lang fra|eng|all` on the command line skips the menu entirely** — required for scheduled/unattended runs.
- After selection, pre-flight verifies the chosen base MSI(s): signature and hash must match `versions.json` — catching a renamed, corrupted, or tampered package in the share. (`ProductLanguage` is read and recorded in the manifest for observability, but is not compared against the filename's language token — see §6: M-Files' own MSIs report `ProductLanguage 1033` regardless of client-language variant, so it cannot distinguish `fra` from `eng` at intake. The SHA-256 pin is the actual language guarantee, established once by a human at intake.)

The menu is the **bare-run fallback only** — it appears solely when `start.bat` is launched with no arguments, serving the operator who runs the kit without reading the README. Any language argument (`start.bat fra`, `start.bat eng`, or any `<profile> <lang>` form, or `-Lang` on direct invocation) bypasses the menu entirely; the standard documented deployment command is `start.bat fra`. Language tokens are accepted generously (`fr|fra|en|eng`, case-insensitive) and normalized to `fra`/`eng` internally before any filename matching. This remains the only interactive moment in the tool, it defaults on a bare Enter, and it is bypassable. No language auto-detection is performed — an operator who knows the customer beats any inference.

## 7. Auto-Update Policy (Decision Point)

The M-Files client self-updates via `findupdates.m-files.com` unless disabled. The generated XML controls this through `<Common><AutomaticUpdates><CheckForUpdates>`.

- `"autoUpdate": true` (default) — element omitted; clients drift to current on their own. Minimal maintenance.
- `"autoUpdate": false` — emit `<CheckForUpdates>0</CheckForUpdates>`; clients stay on the deployed version until a new MSI is pushed. Appropriate if change control requires it (e.g. version-sensitive add-ins or integration components on the endpoint).

**Action item:** confirm the expected policy for this environment with the team before first production build. The setting is per-profile and recorded in the manifest, so mixed policies are supported.

## 8. Build Manifest

Written beside every output MSI as `<outputName>.manifest.json`:

```json
{
  "builtUtc": "2026-07-18T14:00:00Z",
  "profile": "approbation",
  "lang": "fra",
  "langResolvedBy": "menu-default | menu-selection | explicit",
  "baseMsi": "M-Files_Online_x64_fra_client_26_5_16015_4_EV.msi",
  "baseMsiSha256": "<hash>",
  "baseMsiProductLanguage": "<MSI ProductLanguage property, observational only — not compared against fra/eng, see §6>",
  "vbs": "CustomizeInstaller2.3.vbs",
  "autoUpdate": true,
  "vaults": [
    { "key": "conformity", "resolvedName": "Conformity_construction Jean Paul", "guid": "{...}", "resolvedBy": "auto-pattern" }
  ],
  "server": { "networkAddress": "<auto-detected hostname/FQDN>", "endpoint": "2266", "addressResolvedBy": "auto-detect | -ServerAddress" },
  "outputSha256": "<hash>",
  "builtBy": "<username>",
  "builtOn": "<machine>"
}
```

Answers "what exactly is inside this installer?" without archaeology, and makes stale-GUID incidents diagnosable in seconds.

## 9. Validation & Failure Behavior

**Pre-flight failures abort the entire run before any MSI is generated.** Per-profile failures (rare, post-gate) skip that profile, continue the rest, and force a non-zero exit with a run summary. No partial output MSI is ever left in the output directory (build to temp, move on success).

Every error message must state: what failed, the expected vs. actual value, and the concrete next step (e.g. *"No vault matching 'approb' found among online vaults. Online vaults: Conformity_construction Jean Paul, Integrator. If the Approbation vault was just imported, verify it is attached and online in M-Files Admin, then rerun."*).

| Stage | Condition | Behavior |
|---|---|---|
| Pre-flight (env) | M-Files Server service (`MFServer`) not installed / not running | Abort immediately; instruct to start the service and rerun |
| Pre-flight (env) | Package share unreachable or `versions.json` missing on share | Abort immediately; state the configured share path; check network/credentials/DNS on the new server |
| Pre-flight (env) | Kit files missing (VBS, config) | Abort immediately; state which file and that the kit folder must be copied complete |
| Pre-flight (env) | `cscript.exe` not found | Abort immediately; state expected location |
| Pre-flight | Profile or language not found in config | Abort run; list valid values |
| Pre-flight | Selected MSI `ProductLanguage` property missing/unreadable | Abort run; report the file as unreadable/corrupt; refuse to build |
| Pre-flight | Pinned base MSI missing for the selected language | Abort run; state expected filename and repo path |
| Pre-flight | Authenticode signature invalid / wrong signer | Abort run; refuse to build |
| Pre-flight | SHA-256 mismatch vs `versions.json` | Abort run; flag possible tampering or bad copy |
| Pre-flight | COM connection to server fails | Abort run; report server/auth context |
| Pre-flight | Vault pattern matches zero online vaults (in-scope key) | Abort run; print pattern and full online vault list; note likely cause: vault not yet imported or not online after import — verify in M-Files Admin and rerun |
| Pre-flight | Vault pattern matches multiple online vaults (in-scope duplicate) | Abort run at the start; list matches with `[possible copy]` flags; instruct: detach/remove the extra vault and rerun the script |
| Pre-flight | Out-of-scope pattern anomaly (duplicate or zero match on a key this run does not build) | Do not abort; print one-line notice recommending resolution before a full-set run |
| Per-profile | `cscript` non-zero exit | Fail that profile; surface script output; continue others; exit non-zero |
| Per-profile | Output move/manifest write fails | Fail that profile; continue others; exit non-zero |

## 10. Security Considerations

- Base packages are verified (Authenticode + recorded SHA-256) before every build; the cached-package model is safe because trust is established at intake and re-checked at use.
- The tool requires only read access to the M-Files server (vault enumeration) and runs under the operator's Windows credentials — no stored secrets.
- Output MSIs are unsigned in v1; distribute only through internal, access-controlled channels.

## 11. Milestones

| # | Deliverable | Notes |
|---|---|---|
| M1 | Core pipeline building all three default profiles in one run: repo resolve → verify → COM fetch → XML render → VBS invoke | Default = 3 MSIs; `-Profile`/`-Lang` narrow the build |
| M2 | Full validation matrix (§9) + manifest output per MSI | Production-safe; one vault fetch shared across all builds in a run |
| M3 | `-KeepXml` debug switch + per-run summary report (built/failed per profile) | Convenience |
| M4 | Team handoff: README, one-page runbook, repo permissions review | Adoption |

## 12. Open Questions

1. **Auto-update policy** — org default on or off? (§7; ask before first production build.)
2. **`_EV` build channel** — confirm the significance of the `_EV` suffix and that future packages will follow the same naming pattern.
3. **Third vault** — will an additional vault profile (e.g. combined with Integrator/lab) be needed for any user group?
4. **Output MSI signing** — required by endpoint policy now or later? If later, note certificate source and IP/ownership question before purchasing.
5. **Repo permissions** — who besides the author may add packages to the share (i.e., who is trusted to update `versions.json` hashes)?
