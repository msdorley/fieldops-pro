# FieldOps Pro

> Portable IT diagnostics & compliance toolkit for Windows field engineers.
> Runs from a USB drive. Bilingual (EN/FR). Pure PowerShell 5.1.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![PowerShell 5.1](https://img.shields.io/badge/PowerShell-5.1-blue.svg)](https://learn.microsoft.com/en-us/powershell/)
[![Windows 10 / 11](https://img.shields.io/badge/Windows-10%20%7C%2011-0078d6.svg)](#)

---

## What it is

FieldOps Pro is a self-contained toolkit that a field IT technician carries on a Ventoy USB drive and runs against a Windows machine that needs diagnosing, repairing, hardening, or onboarding. It produces structured reports an operator can hand to a customer, an auditor, or a follow-up engineer.

Most of what's in here exists because something in the field was broken and no off-the-shelf tool solved it cleanly. The project is opinionated about portability, audit trails, and not depending on anything beyond what already ships with Windows.

## Features

- **Compliance snapshots & diffs** — sixteen categories of system state including services, drivers, scheduled tasks, autoruns, WMI subscriptions, hosts file, kernel drivers, and environment variables. Eighteen MITRE ATT&CK technique mappings. Output is GZip-compressed JSON with SHA256 integrity sidecars.
- **HTML dashboard** — single-file HTML report with grades, fleet-wide views, and click-to-copy commands. EN/FR locale switch.
- **PC health diagnostic** — hardware inventory, SMART health, memory pressure, free-space analysis.
- **Network repair** — adapter status, DNS sanity, gateway reachability, common-fault remediation.
- **Security scan** — antivirus state, firewall posture, Windows Update lag, suspicious-process review.
- **Disk analysis** — disk health via SMART, partition layout, BitLocker state.
- **Software deployment** — silent installers for a curated app list (configurable).
- **Azure AD join workflow** — guided onboarding for fresh devices.
- **VPN setup** — GlobalProtect provisioning.
- **Incident reports** — HTML reports built from session telemetry, signed with the operator's identity.
- **Optional AI compliance analysis** — Anthropic Claude API for diff explanations. Disabled by default; opt-in via Credential Manager.
- **Bilingual** — every operator-facing string runs through `FieldOps-Locale.psm1` (275 keys, EN + FR).

## Quick start

### Prerequisites

- Windows 10 or 11
- Windows PowerShell 5.1 (ships with Windows; do **not** use PowerShell 7)
- Administrator rights on the target machine
- A FAT32 or exFAT USB drive (Ventoy recommended; not required)

### Install

```powershell
git clone https://github.com/<your-username>/fieldops-pro.git
cd fieldops-pro
```

Copy the contents to your USB drive's root, or develop on disk and copy to USB only for field testing.

### First-run configuration

1. **Create your operator config.** Copy the template:

   ```powershell
   Copy-Item CONFIG\technician.template.json CONFIG\technician.json
   ```

   Edit `CONFIG\technician.json` with your name, email, team, etc. The real `technician.json` is gitignored — it never gets committed.

2. **(Optional) Enable AI compliance analysis.** Store an Anthropic API key in Windows Credential Manager:

   ```powershell
   Install-Module -Name CredentialManager -Scope AllUsers -Force
   New-StoredCredential -Target 'FieldOpsPro:Anthropic' `
                        -UserName 'api' `
                        -Password '<your-anthropic-api-key>' `
                        -Persist LocalMachine
   ```

   Without this step, AI analysis falls back to local rule-based analysis. The toolkit works either way.

3. **(Optional) Register the `fieldops://` protocol handler:**

   ```powershell
   .\SCRIPTS\Core\Register-FieldOpsProtocol.ps1
   ```

### Run

From an elevated PowerShell:

```powershell
.\SCRIPTS\FieldOps-Launcher.ps1
```

A menu appears. Pick a numbered option. Reports land in `REPORTS\`. Logs land in `LOGS\`.

## Entry points

There are intentionally three FieldOps-prefixed scripts. Know which is which:

| File                                      | Purpose                                                        |
| ----------------------------------------- | -------------------------------------------------------------- |
| `SCRIPTS/FieldOps-Launcher.ps1`           | **Operator-facing menu. This is what you run.**                |
| `SCRIPTS/Core/Invoke-FieldOpsHandler.ps1` | Handles the `fieldops://` URI scheme. Registered, not run.     |
| `SCRIPTS/Core/FieldOps-Tools.ps1`         | Portable-tools sub-menu. Dot-sourced by the launcher.          |

## Project layout

```
SCRIPTS/
  FieldOps-Launcher.ps1       # entry point
  Core/                       # shared modules and engines
  Deployment/                 # software deploy, AAD join, VPN
  Diagnostics/                # PCHealth, disk analysis
  Network/                    # network repair
  Reporting/                  # incident reports
  Security/                   # security scan
CONFIG/
  lang/
    en.json
    fr.json
  technician.template.json    # operator config template (real file gitignored)
DOCS/
  schemas/                    # JSON schemas for editor validation
PLAYBOOKS/                    # operational playbooks
LOGS/                         # generated at runtime, gitignored
REPORTS/                      # generated at runtime, gitignored
SNAPSHOTS/                    # generated at runtime, gitignored
```

## Third-party tools (not included)

The toolkit's "Portable Tools" menu integrates well-known utilities (HWiNFO64, CrystalDiskInfo, Nmap/Zenmap, Wireshark Portable, Sysinternals Suite, NirSoft tools, MalwareBytes Portable, AdwCleaner, RKill, Recuva, TestDisk). These are **not redistributed in this repository** — fetch them from their upstream sources and place them under `TOOLS/`. A `Get-PortableTools.ps1` helper script is on the roadmap.

## PowerShell 5.1 — yes, on purpose

The toolkit targets Windows PowerShell 5.1, not PowerShell 7. PS 5.1 ships with every supported Windows version; PS 7 does not. Field operators land on machines that are broken, locked-down, or both. Depending on a runtime that may not be installed is a non-starter. Read [`CONTRIBUTING.md`](CONTRIBUTING.md) for the PS 5.1 footguns we've already mapped.

## Security

This toolkit reads sensitive system state and runs as Administrator. Snapshots may contain credentials, internal hostnames, and other private data. **Read [`SECURITY.md`](SECURITY.md) before deploying** — especially the operator security model and hardening recommendations. Report vulnerabilities privately, never via public issues.

## Contributing

PRs welcome. See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the development setup, PS 5.1 rules, code style, localization workflow, and PR process. By participating you agree to the [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md).

## Status

This is the initial public release. Modules in current production use:

| Module                        | Version | Notes                                          |
| ----------------------------- | ------- | ---------------------------------------------- |
| `FieldOps-Launcher.ps1`       | 2.0     | Operator menu                                  |
| `Invoke-ComplianceDiff.ps1`   | 1.2.x   | 16 snapshot categories, MITRE mappings, GZip   |
| `Invoke-Dashboard.ps1`        | 3.2.x   | EN/FR localization                             |
| `FieldOps-Locale.psm1`        | 1.0.x   | 275 keys per language                          |

See [`CHANGELOG.md`](CHANGELOG.md) for full history (when populated).

## License

[MIT](LICENSE) © 2026 Ousman Dorley

## Acknowledgments

This toolkit stands on the shoulders of well-maintained free and open-source utilities — HWiNFO, CrystalDiskInfo, Nmap, Wireshark, the Sysinternals Suite, NirSoft tools, MalwareBytes, AdwCleaner, Ventoy, and many others. Their work makes field IT possible. Please respect their licenses when integrating them with this toolkit.
