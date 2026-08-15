# Installation

FieldOps Pro - Phase 6, Stream 6.4 (6.4-D4)

FieldOps Pro runs from a USB stick. There is no installer, no service, and
nothing is written to the machine you are diagnosing beyond the reports you
choose to keep.

---

## 1. Requirements

**On the USB stick**

| Requirement | Detail |
|-------------|--------|
| Capacity | 8 GB minimum; 32 GB or more if you carry ISOs and portable tools |
| Filesystem | NTFS or exFAT. FAT32 will not hold files over 4 GB |

**On the target machine**

| Requirement | Detail |
|-------------|--------|
| Windows | Windows 10 or 11, any edition. Windows Server is untested but generally works |
| PowerShell | 5.1, which ships with Windows. **PowerShell 7 is not required and not used** |
| Rights | Local Administrator for most diagnostics; some read-only checks work without |
| Network | **Not required.** Every core function works air-gapped |

There is no .NET, Python or runtime to install. Everything the toolkit needs is
either in Windows already or carried on the stick.

**Deliberately no hardware requirements.** FieldOps Pro is built to run on any
Windows PC regardless of make or model. Where a probe cannot answer -- no TPM,
no BitLocker, a VM with no SMART data -- the affected rule degrades to "partially
verified" rather than failing or reporting a false pass.

---

## 2. Deploy to the stick

Download the release zip from the Releases page, then:

```powershell
Expand-Archive -Path .\fieldops-pro-v0.6.0.zip -DestinationPath E:\ -Force
```

Replace `E:\` with your USB drive letter. The zip expands to the stick's root,
not into a subfolder -- the layout below is what the scripts expect.

### Verify the deployment

```powershell
E:\SCRIPTS\Core\Test-Installation.ps1
```

This checks the directory layout, PowerShell version, execution policy,
configuration files and script integrity, and reports anything missing. **Run it
before trusting a stick in the field**, particularly one that has been copied
from another stick.

---

## 3. Directory layout

```
E:\
  SCRIPTS\        Diagnostic and compliance engines
  TOOLS\          Portable third-party tools, offline Pester bundle
  CONFIG\         Technician identity, language, AI configuration
  PLAYBOOKS\      Multi-engine workflows (*.json)
    remediation\  Remediation playbooks (RB-*.md)
  REPORTS\        Generated reports. Safe to clear
  LOGS\           Run logs, snapshots, AI audit log
  DRIVERS\        Optional driver payloads
  ISOs\           Optional bootable images
  DOCS\           This documentation
```

`REPORTS\` and `LOGS\` grow with use. Both are safe to empty; the tools recreate
what they need.

---

## 4. Configuration

Create `CONFIG\technician.json`:

```json
{
  "TechnicianName": "A. Technician",
  "OrgName": "Contoso IT",
  "Language": "fr"
}
```

| Field | Effect |
|-------|--------|
| `TechnicianName` | Appears on reports. Also hashed into the AI audit log as a pseudonymous id |
| `OrgName` | Appears on reports |
| `Language` | `fr` or `en`. Sets report and interface language |

**Everything is optional.** With no configuration file the toolkit runs with
defaults and the current Windows username.

### Optional: AI features

Add an API key to enable narration, severity classification and remediation
guidance:

```json
{
  "TechnicianName": "A. Technician",
  "AnthropicApiKey": "sk-ant-..."
}
```

**No feature requires this.** Without a key every tool takes its deterministic
local path and says so. See `DOCS/AI-INTEGRATION.md` for cost controls, the
audit log, and what is transmitted.

Verify the AI configuration without guessing:

```powershell
E:\SCRIPTS\Core\Invoke-ComplianceDiff.ps1 -Mode Diagnose
```

---

## 5. Execution policy

Windows blocks unsigned scripts by default. Two options, in order of preference.

**Per session, no machine change** -- the right choice for a machine that is not
yours:

```powershell
powershell.exe -ExecutionPolicy Bypass -File E:\SCRIPTS\FieldOps-Launcher.ps1
```

**Per user, persistent** -- for your own machine:

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

You may also need to unblock files copied from another machine:

```powershell
Get-ChildItem -Path E:\SCRIPTS -Recurse | Unblock-File
```

Windows marks files downloaded from the internet, and that mark survives a copy
to USB. `Test-Installation.ps1` reports it if present.

---

## 6. First run

```powershell
powershell.exe -ExecutionPolicy Bypass -File E:\SCRIPTS\FieldOps-Launcher.ps1
```

The launcher opens a menu. Nothing runs until you choose it, and every
destructive action asks first.

To start in a specific language or write reports elsewhere:

```powershell
.\FieldOps-Launcher.ps1 -Language en -OutputRoot D:\FieldOpsReports
```

---

## 7. WinPE

FieldOps Pro detects WinPE and adapts: probes that cannot work in a preboot
environment degrade rather than fail. Deploy the same stick and run the launcher
from the WinPE command prompt.

Not every diagnostic is meaningful in WinPE -- there is no running Defender to
query, for instance -- and affected rules report as unverified rather than as
failures.

---

## 8. Uninstalling

Delete the folder, or reformat the stick.

Nothing is installed on target machines. No registry keys, no services, no
scheduled tasks, no files outside the report path you chose. If you used the
optional protocol handler registration
(`SCRIPTS\Core\Register-FieldOpsProtocol.ps1`), that writes one registry key,
and the same script removes it.

---

## 9. When something does not work

| Symptom | Cause |
|---------|-------|
| "running scripts is disabled on this system" | Execution policy -- see section 5 |
| "The term ... is not recognized" | Not run from the stick root, or an incomplete copy. Run `Test-Installation.ps1` |
| Reports appear but are empty | Not elevated. Most probes need Administrator |
| French accents render as two garbled Latin characters instead of one accented letter | The stick was copied by a tool that rewrote file encodings. Re-extract from the release zip rather than copying folder-to-folder |
| AI features silently do nothing | Expected without a key. Run `Invoke-ComplianceDiff.ps1 -Mode Diagnose` to see which path was taken and why |

For anything else, `LOGS\` holds a per-run log naming the step that failed.

---

## Related

- `DOCS/USING.md` -- what each tool does and when to use it
- `DOCS/ARCHITECTURE.md` -- how the pieces fit together
- `DOCS/AI-INTEGRATION.md` -- AI configuration, costs and audit log
- `SECURITY.md` -- reporting a vulnerability
