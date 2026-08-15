# Using FieldOps Pro

FieldOps Pro - Phase 6, Stream 6.4 (6.4-D5)

What each tool does, when to reach for it, and what it leaves behind.

---

## The launcher

```powershell
powershell.exe -ExecutionPolicy Bypass -File E:\SCRIPTS\FieldOps-Launcher.ps1
```

| Key | Tool |
|-----|------|
| **1** | PC Health Diagnostic |
| **2** | Network Repair & Testing |
| **3** | Security Scan |
| **4** | Disk Analysis & SMART Health |
| **5** | Software Deployment |
| **6** | Azure AD Join Workflow |
| **7** | GlobalProtect VPN Setup |
| **8** | Incident Report (HTML) |
| **9** | Compliance Snapshot & Diff |
| **D** | Build HTML Dashboard |
| **F** | Fleet Report |
| **P** | Run Playbook |
| **A** | AutoFix (guided remediation) |
| **N** | AutoFix Plan-Before-Execute |
| **T** | Portable Tools |
| **L** | Logs |
| **Q** | Quit / Reboot / Shutdown |

Every script also runs directly, which is what you want for scripted or repeated
use. The launcher is a convenience, not a dependency.

---

## The compliance report

This is the deliverable a customer keeps. Everything else supports it.

FieldOps Pro evaluates the machine against the **42 rules of the ANSSI Guide
d'hygiene informatique** and produces a signed, bilingual HTML report.

### Three outcomes, and why there are three

| Status | Meaning |
|--------|---------|
| **cv** *(conforme verifie)* | The control is in place and the toolkit observed it directly |
| **pv** *(partiellement verifie)* | Evidence is incomplete -- the probe could not run, the hardware is absent, or the rule needs human judgement |
| **hp** *(hors perimetre)* | Outside what an endpoint scan can assess: staff training, HR procedure, physical security |

**`pv` is not a soft failure and `hp` is not an excuse.** A machine with no TPM
cannot demonstrate hardware-backed authentication, and reporting that as either
a pass or a fail would be a lie. An auditor needs to know which rules were
actually verified and which were not, and a report that cannot distinguish those
is not evidence.

This is why the toolkit never reports a control as satisfied on the basis that
its probe returned nothing.

### Report integrity

Each report embeds a SHA-256 of its own delivered bytes. A report whose content
has been altered no longer matches its signature. That makes the report suitable
to hand to a third party who needs to know it is the one you produced.

### Running it

Menu key `9`, or directly:

```powershell
.\SCRIPTS\Core\Invoke-ComplianceDiff.ps1
```

---

## Snapshot and diff

The compliance engine has a second mode that answers a different question: **what
changed on this machine?**

```powershell
# Before your work
.\SCRIPTS\Core\Invoke-ComplianceDiff.ps1 -Mode Before

# ... perform the intervention ...

# After: takes the second snapshot and produces the diff
.\SCRIPTS\Core\Invoke-ComplianceDiff.ps1 -Mode After
```

A snapshot covers **16 categories** -- services, registry, scheduled tasks,
firewall, local users, software, listening ports, certificates, startup items,
SMB shares, BitLocker, Defender, WMI persistence, hosts file, environment, and
drivers.

Changes are classified as Improvement, Regression, Neutral or Suspicious, mapped
to **MITRE ATT&CK techniques** where they match a known pattern, and given a risk
score. A rollback script is generated alongside.

**This is the tool that proves an intervention did what it claimed** -- and, more
usefully, that it did nothing else.

With an API key configured, the diff is also narrated in prose. Without one, the
same classification runs on local rules and says so.

### Other modes

```powershell
-Mode Diagnose   # verify configuration and AI connectivity, change nothing
-Mode Compare    # diff two existing snapshot files
-NoAI            # force local rules even when a key is present
```

---

## Diagnostics

**PC Health (1)** -- CPU, memory, disk, temperatures, event log errors, uptime,
pending reboots. The first thing to run on a machine someone says is "slow".

**Network Repair (2)** -- adapters, DNS, DHCP, gateway reachability, proxy
configuration, Wi-Fi encryption. Repairs are offered, never automatic.

**Security Scan (3)** -- Defender status, firewall profiles, UAC, BitLocker,
SMBv1, credential exposure, autologon, LSA protection.

**Disk Analysis (4)** -- SMART attributes, partition layout, free space, volume
health. A failing disk explains most "slow computer" tickets, so run this early.

Each writes an HTML report to `REPORTS\` and a JSON sidecar to `LOGS\`. **The
JSON is what the compliance engine consumes**, which is why running the
diagnostics before the compliance report produces a more complete result.

---

## Deployment tools

**Software Deployment (5)**, **Azure AD Join (6)**, **GlobalProtect VPN (7)** --
guided workflows for provisioning tasks, aimed at repeatability rather than
speed. Each records what it did so the run can be audited later.

---

## Playbooks

Two different things share the word "playbook".

**Workflow playbooks** (`PLAYBOOKS\*.json`, menu key `P`) chain several engines
into one operation -- `hardware-audit`, `security-hardening`,
`new-hire-deployment`, `routine-maintenance`, `malware-remediation`.

**Remediation playbooks** (`PLAYBOOKS\remediation\RB-*.md`) are written
procedures for a technician to follow, each covering one fix: how to verify the
condition, the steps, the rollback, and what to do when it does not hold. These
are what the AI cites when it recommends a fix, and the citation is validated --
the toolkit will not let a recommendation reference a procedure that does not
exist.

Read `PLAYBOOKS/remediation/SCHEMA.md` before writing one.

---

## AutoFix

**AutoFix (A)** walks known-safe remediations with confirmation at each step.

**AutoFix Plan-Before-Execute (N)** does the same but produces a risk analysis
per fix *first* -- what it will change, what could break, how to revert -- and
records the whole decision trail. Use this one on a machine you do not own, or
where you will need to explain the intervention afterwards.

Neither changes anything without an explicit confirmation.

---

## Reporting

**Incident Report (8)** -- a structured HTML report for a specific incident,
combining findings with your own narrative.

**Dashboard (D)** -- a single self-contained HTML file summarising the latest
snapshots. Openable anywhere, no server.

**Fleet Report (F)** -- rolls up the last 90 days across every machine whose
snapshots are on the stick. This is how a recurring fault across a fleet becomes
visible when each individual machine looked unremarkable.

---

## Portable tools (T)

Launches third-party utilities carried on the stick -- HWiNFO64,
CrystalDiskInfo, Nmap, Wireshark, Sysinternals, NirSoft. They are not part of
FieldOps Pro and carry their own licences; the menu is a convenience for tools a
field technician already uses.

---

## What gets written where

| Location | Contents | Safe to delete |
|----------|----------|----------------|
| `REPORTS\` | HTML and PDF reports | Yes |
| `LOGS\` | Run logs, JSON sidecars, snapshots | Yes, but you lose diff history |
| `LOGS\ai-audit.jsonl` | One record per AI call | Yes, but it is your cost and usage evidence |

**On the target machine: nothing.** No registry keys, no services, no scheduled
tasks, no files outside the report path you chose.

---

## Working without AI

Everything above works with no API key and no network. The AI adds narration,
severity ranking and remediation guidance on top of findings that are computed
deterministically either way.

**The AI never decides compliance.** The 42 rule evaluations come from observed
system state via deterministic code. The model describes and prioritises; it
does not score.

Force local-only with `-NoAI` on any script.

---

## Language

Set `Language` in `CONFIG\technician.json`, or per run:

```powershell
.\FieldOps-Launcher.ps1 -Language en
```

French and English are complete and kept at parity -- a test asserts neither
language has a key the other lacks, so a partially translated report cannot
ship.

---

## Related

- `DOCS/INSTALL.md` -- deployment and configuration
- `DOCS/ARCHITECTURE.md` -- how the pieces fit together
- `DOCS/AI-INTEGRATION.md` -- AI configuration, cost controls, audit log
- `PLAYBOOKS/remediation/SCHEMA.md` -- writing remediation playbooks
