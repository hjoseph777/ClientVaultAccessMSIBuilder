# SKILLS.md - Technical Inventory & Stack

## The Stack

Before diving into the documents, here is the explicit technology stack for this project:

- Language: Windows PowerShell 5.1 (required for M-Files COM interop).
- Core APIs: M-Files COM API (MFilesAPI.MFilesServerApplication), Windows Installer COM API (WindowsInstaller.Installer).
- External execution: cscript.exe (to run M-Files' CustomizeInstaller2.3.vbs).
- Data formats: JSON (configuration, manifests, logging), XML (MSI customization).
- Infrastructure: Windows Server (runs on the M-Files Server host), UNC network share (for central package hosting).

## 1. Technology Stack

- Language: Windows PowerShell 5.1
- APIs: M-Files COM API, Windows Installer COM API
- Execution: cscript.exe (Windows Script Host)
- Data: JSON, XML

## 2. Required Files (Kit Inventory)

- start.bat (Launcher)
- OpenCMD.bat (Opens CMD in kit directory with Desktop/OneDrive fallback)
- Build-FRA.cmd (French build shortcut: calls start.bat fra)
- Build-ENG.cmd (English build shortcut: calls start.bat eng)
- ClientVaultAccessMSIBuilder.ps1 (Orchestrator)
- profiles.json (Vault patterns, server settings)
- CustomizeInstaller2.3.vbs (Vendor script, unmodified)
- README.md (Runbook)
- output\ (Generated MSIs, manifests, logs)

## 3. External Infrastructure

- Central Package Share: UNC path hosting base MSIs and versions.json.
- Target Host: Must be the M-Files Server (requires MFServer service and MFilesAPI registered).

## 4. Core Technical Skills Required

- PowerShell Advanced Functions: Parameter validation, strict mode, error handling.
- COM Interop: Instantiating COM objects, extracting properties, and strictly releasing them to prevent memory leaks.
- MSI Database Querying: Using WindowsInstaller.Installer to execute SQL-like queries against the MSI Property table.
- Process Management: Using System.Diagnostics.Process to control external executables (cscript.exe) with timeouts and standard output redirection.
- XML Generation: Programmatic creation of XML nodes via System.Xml.XmlDocument.
- Auth negotiation: `profiles.json` `server.authType` of `"auto"` tries Windows SSO (`MFAuthType 1`) first, falls back to a `Get-Credential` prompt for M-Files Authentication (`MFAuthType 3`) if SSO fails; the resulting value is reused both for the build's own COM connection and for the `<AuthType>` written into output MSIs. Real `MFAuthType` enum values (0=Unknown, 1=LoggedOnWindowsUser, 2=SpecificWindowsUser, 3=SpecificMFilesUser) came from loading the vendor's `Interop.MFilesApi.dll` directly — don't re-derive by guessing.
- Duplicate vault arbitration: in-scope pattern collisions remain fatal; exactly one online vault must match each required key pattern.
- PSCustomObject dynamic property creation: a `ConvertFrom-Json` result only supports plain dot-assignment (`$obj.existingKey = value`) for properties already present in the JSON. Creating a brand-new property (e.g. the runtime-computed `clientAuthType`/`builderAuthType` on `$config.server`) via dot-assignment throws under `Set-StrictMode -Version Latest` ("The property '...' cannot be found on this object"). Must use `$obj | Add-Member -NotePropertyName X -NotePropertyValue Y -Force` instead. `Get-JsonValue`'s try/catch pattern only covers *reads*, not this write-side failure mode.
- Silent-stop diagnosis pattern: any code between two `Write-Stage` calls that isn't itself wrapped in try/catch can terminate the whole run with zero trace in `output\build_*.log` (StrictMode errors go to console via default PowerShell error rendering, not through `Write-Host`/`Write-Stage`, and are lost if the launching window closes). When a build log cuts off mid-run with no `[ERROR]` line, suspect an unwrapped block between the last logged step and the next one — wrap it in try/catch → `Invoke-Abort` to surface the real exception on the next run.
- `.Count` under StrictMode: any variable that might collapse to a scalar (a single `-Profile`/`-Lang` CLI value, or a single-element `profiles.json` array) has no `.Count` property and throws "The property 'Count' cannot be found on this object" under `Set-StrictMode -Version Latest`. Always force array context first: `@($var).Count`, never bare `$var.Count`, unless `$var` is already guaranteed to be a collection (e.g. built with `@(...)` in the same assignment).
