# FieldOps Pro

A portable Windows field toolkit that runs from a USB stick. Nothing is installed
on the machine being examined.

[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1-blue.svg)](#requirements)
[![Tests](https://img.shields.io/badge/tests-679%20passing-brightgreen.svg)](DOCS/TESTING.md)

Sixteen tools for the technician standing in front of a broken machine: hardware
and disk diagnostics, network repair, security posture, software deployment,
directory enrolment, VPN setup, fleet reporting, incident reports, remediation
playbooks, guided self-healing, and compliance assessment.

It runs air-gapped, installs nothing, and works on any hardware.

---

## The part that matters

Field tools report pass or fail. When a probe cannot run, or the hardware is not
there, or the answer needs a human, they pick one of the two and move on.

FieldOps Pro has a third verdict, and it is the reason to use it.

| Status | Meaning |
|--------|---------|
| **Verified** | The control is in place and the toolkit observed it directly |
| **Could not determine** | Evidence is incomplete: the probe could not run, the hardware is absent, or the question needs human judgement |
| **Out of scope** | Outside what an endpoint scan can assess -- staff training, HR procedure, physical security |

A machine with no TPM **cannot** demonstrate hardware-backed authentication.
Reporting that as a pass is false. Reporting it as a failure implies a defect
that is not there.

Whoever reads the output needs to know what was actually checked and what was
not. A report that cannot make that distinction is not evidence, and the toolkit
never reports a control as satisfied on the basis that its probe returned
nothing.

**Where this stands today:** the discipline is complete in the compliance module,
which carries it across all 42 rules as `cv` / `pv` / `hp`. The other engines
already detect what they could not determine -- and currently discard it before
display. Lifting the same contract into them is the next work, beginning with
SecurityScan, which supplies the evidence behind 30 of those 42 rules.

---

## Compliance is a module, not the product

The compliance engine assesses a machine against the **42 rules of the ANSSI
*Guide d'hygiene informatique*** and produces a signed, bilingual, paginated
report intended to be handed to a client.

ANSSI is the first rule set, not the identity. Evaluators are pure functions over
parsed JSON, so CIS Benchmarks, Cyber Essentials, BSI Grundschutz and NIST
800-171 are the same shape. The rest of the toolkit is not specific to any
country or framework.

---

## Quick start

```powershell
# 1. Extract the release to a USB stick
Expand-Archive .\fieldops-pro-v0.6.0.zip -DestinationPath E:\ -Force

# 2. Verify the deployment before trusting it in the field
E:\SCRIPTS\Core\Test-Installation.ps1

# 3. Run
powershell.exe -ExecutionPolicy Bypass -File E:\SCRIPTS\FieldOps-Launcher.ps1
```

`Test-Installation.ps1` reports **READY** or names exactly what is wrong. Run it
on any stick that was copied from another stick -- see
[why](DOCS/INSTALL.md#9-when-something-does-not-work).

Full instructions: **[DOCS/INSTALL.md](DOCS/INSTALL.md)**

---

## What it does

**Compliance reporting.** The 42 ANSSI rules, evaluated from observed system
state, rendered to a signed HTML report in French or English. Each report embeds
a SHA-256 of its own delivered bytes.

**Snapshot and diff.** Capture the machine before your work and after, across 16
categories -- services, registry, scheduled tasks, firewall, users, software,
listening ports, certificates, startup items, SMB shares, BitLocker, Defender,
WMI persistence, hosts file, environment, drivers. Changes are classified,
mapped to MITRE ATT&CK techniques where they match a known pattern, and a
rollback script is generated.

*This is the tool that proves an intervention did what it claimed -- and, more
usefully, that it did nothing else.*

**Diagnostics.** PC health, network, security posture, disk and SMART. Each
writes a report for a human and a JSON sidecar the compliance engine consumes.

**Remediation.** Guided fixes with confirmation at every step, plus a
plan-before-execute mode that produces a risk analysis first and records the
decision trail -- for a machine you do not own, or one you will need to explain
afterwards.

**Fleet reporting.** Rolls up 90 days across every machine on the stick, which
is how a recurring fault becomes visible when each machine looked unremarkable.

Full tour: **[DOCS/USING.md](DOCS/USING.md)**

---

## Requirements

| | |
|---|---|
| **OS** | Windows 10 or 11, any edition |
| **PowerShell** | 5.1 -- ships with Windows. **PowerShell 7 is not required and not used** |
| **Rights** | Administrator for most diagnostics |
| **Network** | **Not required.** Every core function works air-gapped |
| **Hardware** | Any Windows PC. Probes that cannot answer degrade rather than guess |

Nothing to install. No .NET, no Python, no runtime, no agent, no service.

---

## Optional: AI assistance

With an API key configured, findings are narrated, ranked by severity, and
matched to remediation procedures.

**No feature requires it.** Every AI call site has a deterministic local path and
takes it on any failure -- no key, refused on cost, rate limited, malformed
response.

**The AI never decides compliance.** All 42 evaluations are computed from
observed state by deterministic code. The model describes and prioritises; it
does not score.

Cost ceilings are enforced before the network is touched, and every call is
recorded to an audit log an auditor can verify independently.

Details, including what is transmitted and what is not:
**[DOCS/AI-INTEGRATION.md](DOCS/AI-INTEGRATION.md)**

---

## Quality

679 tests, no network, no API key. The full suite runs in about seven minutes;
the 535-test subset the pre-commit hook runs takes under one.

- **Branch coverage** over every decision path in the computed evaluators
- **Property tests** throwing 200 randomised adversarial inputs at each evaluator, asserting it never throws, always returns a valid status, and is deterministic
- **Repository audits** enforcing ASCII source, no BOM, exactly 42 evaluators, no hardcoded machine paths, licence headers, no direct provider calls, no API key in any log
- **Locale parity** -- neither language may have a key the other lacks

Several tests exist specifically to stop a green suite from proving nothing. A
fixture set that fails to load makes every assertion over it pass vacuously, so
the suites assert their own inputs are non-empty before checking them. That
guard has caught a real failure.

**[DOCS/TESTING.md](DOCS/TESTING.md)**

---

## Documentation

| Document | For |
|----------|-----|
| [INSTALL.md](DOCS/INSTALL.md) | Deploying and configuring a stick |
| [USING.md](DOCS/USING.md) | What each tool does and when to use it |
| [ARCHITECTURE.md](DOCS/ARCHITECTURE.md) | How it fits together, and why |
| [EXTENDING.md](DOCS/EXTENDING.md) | Adding engines, rules, playbooks, languages |
| [AI-INTEGRATION.md](DOCS/AI-INTEGRATION.md) | The AI contract in detail |
| [TESTING.md](DOCS/TESTING.md) | Test suite reference |
| [CHANGELOG.md](CHANGELOG.md) | What changed, including what broke |
| [VERSIONING.md](VERSIONING.md) | What the version number covers |

---

## What is deliberately absent

**No database.** State is files a technician can read, diff and email.

**No agent or service.** Nothing persists on the target machine.

**No telemetry.** Nothing is transmitted anywhere unless AI is explicitly
enabled, and that path is documented and audited.

**No auto-remediation without confirmation.** Every change asks.

---

## What this is not

**Not ANSSI certified or endorsed.** FieldOps Pro implements an assessment
against a published ANSSI guide. It is not affiliated with or approved by ANSSI
-- see [NOTICE](NOTICE).

**It does not guarantee compliance.** It evaluates and reports. Compliance
remains the operator's, and depends on rules no endpoint scan can assess.

**The report signature is not tamper-proofing.** It is a correspondence check
between a report and its content. Someone who regenerates the report regenerates
the hash.

---

## Licence

Apache License 2.0 -- see [LICENSE](LICENSE) and [NOTICE](NOTICE).

Apache 2.0 carries an express patent grant and a trademark reservation. The code
may be used and forked; the name may not be reused to present a fork as this
product.

---

## Status

**v0.6.0**, pre-1.0. The schemas, status vocabulary, script parameters and
directory layout are treated as a public contract and versioned accordingly,
even though `0.x` under SemVer would permit otherwise -- see
[VERSIONING.md](VERSIONING.md).
