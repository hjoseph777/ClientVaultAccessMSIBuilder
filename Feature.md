# Feature.md — ClientVaultAccessMSIBuilder: Contemplated Features

> **⛔ DIRECTIVE — READ FIRST**
> Everything in this file is **contemplated only**. Nothing here is approved, scoped, or to be implemented.
> **Do not build, scaffold, code, or reference any item in this file unless Harry explicitly directs it.**
> This applies to humans and to AI coding assistants alike. The build contract is `ClientVaultAccessMSIBuilder_PRD.md` and nothing else.

Each entry records: what it is, why it's attractive, and what it costs or risks — so the decision can be made later without re-litigating from scratch.

---

## FI-1. Share-hosted bootstrap (`deploy.bat`)

**What:** A batch file living on the central share beside the packages. Run directly from the new server (`\\SRV\MFiles\packages\deploy.bat`), it robocopy-mirrors the kit to a local folder (e.g. `C:\MFilesDeploy\`, excluding `output\` so reruns preserve prior builds), then launches `start.bat`, passing arguments through (`/MIR /XD output`; treat robocopy exit codes < 8 as success).

**Why:** Onboarding becomes a single action with nothing pre-placed on the server. `/MIR` means every deployment automatically runs the current kit — update the script once on the share and all future deployments pick it up. Solves the tool's own update-distribution problem for free.

**Costs / risks:** SmartScreen or zone prompts if the share is not in the domain's Intranet zone. The local copy remains on the server after deployment (arguably a feature — it doubles as a deployment record). Adds one more artifact to maintain on the share.

**Status:** Superseded in ambition by FI-2, which achieves the same goals with less machinery. Keep only if FI-2 is rejected.

---

## FI-2. Single-file, run-from-share model (the "one file" end state)

**What:** Collapse the kit to a single `ClientVaultAccessMSIBuilder.ps1` executed **directly from the share** — no copy step at all:

```
powershell -ExecutionPolicy Bypass -File \\SRV\MFiles\packages\ClientVaultAccessMSIBuilder.ps1
```

Component absorption:
- `profiles.json` → embedded `$Config` block at the top of the ps1 (all values are constants that never change per deployment: patterns, endpoint 2266, auth settings, share path).
- `CustomizeInstaller2.3.vbs` → stays on the share beside the MSIs it version-pairs with; the script copies it to `%TEMP%` at runtime and invokes it there.
- `start.bat` → replaced by the one documented command above (execution policy handled by `-ExecutionPolicy Bypass`).
- `README.md` → stays on the share as the runbook; contains the one command.
- Output → since `$PSScriptRoot` would be the share, output must NOT be script-relative; write to a fixed local path (`C:\MFilesDeploy\output\`, created if absent), preserving the local deployment record.

**Why:** Zero files copied per deployment, zero drift (one script on the share is the only version in existence), zero per-server anything. Embedding the config *strengthens* the "nothing edited per deployment" guarantee. Share contents: the ps1, two base MSIs, versions.json, the VBS, README — five items total.

**Costs / risks:** Loses double-click launch — the command must be typed or pasted from the README (trivial for the operator population). Share must be reachable at run time (already true of the current design). Config changes now require editing the script (acceptable: the config never changes). Possible Mark-of-the-Web / zone friction running a ps1 from UNC on some hardened servers — verify once on a representative server before committing.

**Status:** Contemplated. Strongest candidate; would simplify §6 of the PRD substantially if adopted.

---

*Adding to this file: keep the three-part structure (what / why / costs). Nothing graduates from this file to the PRD without Harry's explicit direction.*
