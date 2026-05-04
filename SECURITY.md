# Security Policy

FieldOps Pro is a portable IT diagnostics and compliance toolkit that reads sensitive system state (registry, services, drivers, WMI subscriptions, scheduled tasks, autoruns, hosts file, environment variables) and typically runs with Administrator privileges. Security issues in this codebase can have real impact on the machines it audits. We take reports seriously.

## Supported Versions

Security fixes are applied to the current minor release and, where feasible, the immediately preceding minor release. Older versions are end-of-life and will not receive patches — upgrade to continue receiving security updates.

| Component                      | Version   | Status        |
| ------------------------------ | --------- | ------------- |
| `Invoke-Dashboard.ps1`         | 3.2.x     | Supported     |
| `Invoke-Dashboard.ps1`         | 3.1.x     | Supported     |
| `Invoke-Dashboard.ps1`         | < 3.1     | End-of-life   |
| `Invoke-ComplianceDiff.ps1`    | 1.2.x     | Supported     |
| `Invoke-ComplianceDiff.ps1`    | < 1.2     | End-of-life   |
| `FieldOps-Locale.psm1`         | 1.0.x     | Supported     |

> **Note on ComplianceDiff.** Version 1.2 is the initial public release. There is no preceding minor version to support; the policy applies once 1.3 ships.

## Reporting a Vulnerability

**Please do not open a public GitHub issue for security vulnerabilities.** Public disclosure before a fix is available puts every operator at risk.

Report privately via one of these channels:

- **GitHub Security Advisories** — use the "Report a vulnerability" button on the Security tab of this repository. This is the preferred channel: it creates a private coordination thread with the maintainers and supports CVE assignment.
- **Email** — `contact@domotikchezvous.com`

<!-- TODO: contact@domotikchezvous.com is a temporary inbox. Replace with a permanent address (e.g. security@<final-domain>) once the project domain is finalized, and consider publishing a dedicated PGP key at https://<final-domain>/pgp.asc. -->

Include in your report:

1. A clear description of the vulnerability and its impact
2. Affected version(s) and module(s)
3. Step-by-step reproduction instructions
4. Proof-of-concept code or screenshots if applicable
5. Your name or handle for credit (optional — reports may remain anonymous)

If you need to encrypt sensitive details, request a PGP public key in your initial (unencrypted) message and we will respond with a key out-of-band before you send the technical detail.

### What to expect

| Stage                              | Target timeline |
| ---------------------------------- | --------------- |
| Acknowledgment of receipt          | Within 7 days   |
| Initial triage and severity rating | Within 14 days  |
| Coordinated fix and advisory       | 90 days default, negotiable case-by-case |

We follow a **90-day coordinated disclosure** default, consistent with common industry practice. If a fix takes longer due to complexity or upstream dependencies, we will request an extension and explain why. If 90 days pass without resolution and without a negotiated extension, you may disclose publicly.

This project is maintained by a small team. We will keep you updated throughout the process and credit you in release notes and the advisory unless you prefer otherwise.

## Scope

### In scope

- PowerShell modules in `SCRIPTS/Core/` and any other scripts shipped in the repository
- The locale engine (`FieldOps-Locale.psm1`) and translation files (`en.json`, `fr.json`)
- Dashboard HTML generation — cross-site scripting, HTML injection, or any output-handling issue in `Dashboard.html`
- Snapshot serialization and deserialization — integrity bypass, deserialization attacks, path traversal via crafted filenames
- AI analysis payload construction — prompt injection, unintended data exfiltration, credential leakage in transmitted diffs
- Any code path that writes to the filesystem, modifies the registry, or changes system state
- Local privilege escalation from a standard user running the toolkit (the toolkit assumes the operator already has Administrator rights, but escalation from a lower privilege level is in scope)

### Out of scope

- Issues that require the attacker to already hold Administrator or SYSTEM on the target machine — this is the toolkit's normal operating context
- Vulnerabilities in upstream dependencies (the PowerShell runtime, .NET, or Windows itself) — report these to the relevant vendor; we will update after a patch ships
- Social engineering or physical attacks against the USB drive or the operator
- Issues in GitHub, Ventoy, or other hosting and distribution infrastructure
- Cosmetic issues or typos in report output, unless they have a security impact
- Denial of service caused by running the toolkit against an intentionally hostile or malformed target system (the toolkit is a diagnostic tool, not a security boundary)

## Security Model — What Operators Should Understand

1. **The toolkit runs with Administrator rights.** This is required for most snapshot categories (WMI, services, kernel drivers, scheduled tasks). Only run on machines you have written authorization to audit.

2. **Snapshots contain sensitive data.** Installed software lists, running processes, network configuration, scheduled tasks, WMI subscriptions, and environment variables can all contain credentials, internal hostnames, tokens, or other sensitive strings. Snapshots are compressed with GZip but are **not encrypted at rest by default.** Protect the output directory.

3. **AI analysis transmits snapshot diffs to Anthropic's API when enabled.** The current implementation caps payload size (30 changes, 60-character field truncation, 6000-character total limit), but sensitive strings can still leak within those limits. Disable AI analysis when handling classified, regulated, or otherwise sensitive data. Review what leaves the machine before enabling.

4. **SHA256 sidecars verify integrity, not authenticity.** A sidecar proves a snapshot has not been modified since it was written. It does not prove who wrote it or on which machine. Chain-of-custody must be maintained out-of-band — the toolkit does not sign its output.

5. **No network calls except opt-in AI analysis.** The toolkit performs all other operations locally. AI analysis is gated behind a runtime prompt and an explicit API key — it never runs silently. If you observe unexpected outbound network activity from any module, treat it as a potential vulnerability and report it through the channels above.

## Hardening Recommendations

- **Run from read-only media.** Ventoy is not read-only by default; enable read-only mode in the Ventoy configuration (or use a hardware-write-protected USB) to prevent tampering between field uses.
- **Verify SHA256 of each script** against the signed release manifest before the first use on a new engagement.
- **Store report output on an encrypted volume** (BitLocker, VeraCrypt, or an enterprise-managed equivalent).
- **Review AI analysis prompts and outputs** before sharing externally or storing them long-term.
- **Rotate the Anthropic API key** used for AI analysis regularly; scope it to the minimum required.

## Disclaimer

FieldOps Pro is provided "as is", without warranty of any kind, express or implied. The maintainers make no guarantees about fitness for any particular purpose, and accept no liability for any loss, damage, or service disruption arising from the use, misuse, or inability to use this toolkit. Operators are responsible for verifying the toolkit's behavior in their own environment before relying on it.

## Acknowledgments

Security researchers who submit valid reports are credited in release notes and, with their permission, in `HALL_OF_FAME.md` after coordinated disclosure. We do not currently run a paid bug bounty program.

Thank you for helping keep FieldOps Pro and its operators safe.
