# Phase 7 - Design

FieldOps Pro - authoritative specification for Phase 7

Phase 6 made the product testable, documented and licensed. Phase 7 makes it
**true, verifiable and sellable under someone else's name** -- in that order,
because shipping an overclaim while building the fix is not an option.

Four streams. 7.0 first and alone; 7.1 through 7.3 may run in parallel.

| Stream | Name | Makes true the claim |
|--------|------|----------------------|
| 7.0 | Truth | (removes claims that are not true yet) |
| 7.1 | Report language | "bilingual report" |
| 7.2 | Console language | "French and English at full parity" |
| 7.3 | Provenance and identity | "signed, verifiable, brandable" |

---

## Stream 7.0 -- Truth

**Ships as v0.6.1. Nothing else starts until this does.**

v0.6.0 is published and its documentation overstates it. Every day that stands
is a day a prospect can discover it before you tell them.

### 7.0-D1 -- Narrow the bilingual claims

`README.md` and `USING.md` claim full parity. State precisely what is bilingual
today: the 42 rule names, the 10 module titles, the report chrome, the launcher
menu. Do not claim the findings text or the tool consoles.

### 7.0-D2 -- One version, one source

Three version numbers ship today: v0.6.0 (release), v2.1 (launcher banner and
window title), v1.2.1 (compliance engine). The launcher version is baked into
`launcher.banner.title` in **both** locale bundles.

- One constant, read by everything that displays a version
- Remove version literals from locale strings; substitute at render time
- Add to the `RELEASE.md` checklist
- Test: displayed version equals the newest `CHANGELOG.md` heading

### 7.0-D3 -- Self-test silent skip

On exFAT and FAT32 the file-blocking check prints nothing at all --
`Zone.Identifier` is an NTFS alternate data stream and the error is swallowed.
Report `OK` with "not applicable on this filesystem". Test it on a non-NTFS
fixture.

### 7.0-D4 -- Config truth

- `technician.template.json` says the API key lives in Windows Credential Manager. `Get-AIApiKey` reads the environment variable then config files; no Credential Manager path exists in the client. Correct the template, or implement it -- but do not ship a template that describes software you do not have.
- `DOCS/INSTALL.md` documents a flat config schema; the shipped template is the v2.0 nested one.
- Check whether `FieldOps-RiskPlanner.psm1`'s Credential Manager reference is dead code from the PR #27 reroute.

### 7.0-D5 -- Display honesty

- The startup banner advertises `claude-sonnet-4-6`, marked `legacy` in the pricing config, which the tier mapping will never select. Show the tier, or "resolved at call time".
- `Invoke-ComplianceDiff.ps1:250` prints the key prefix. Public, not secret -- but `Test-Installation.ps1` deliberately never prints it. One policy, both places.
- Snapshot filenames repeat hostname and date.

### 7.0-D6 -- Known issues on the release page

Until 7.1 ships, the v0.6.0 release notes carry a plain statement that report
findings render in French regardless of selected language.

---

## Stream 7.1 -- The report is the product

**The English report is not English.** Rule names, module titles and chrome
switch language correctly. Every evaluator returns hardcoded French `Detail`
and `Evidence` prose. The bundle carries translated `R*.detail` and
`R*.phrases` keys in both languages with **zero readers**.

An English-speaking auditor receives French findings. The report is the
deliverable; this makes the English deliverable unfit for purpose.

### 7.1-D1 -- Wire the evaluators

All 42 evaluators read their `detail` and `phrases` keys. The `phrases`
sub-keys exist precisely for composed strings (`R14.phrases.fwOk`,
`fwNotConfirmed`). This is wiring; the translation is done and correct.

**Constraint:** an evaluator must still never throw, always return a valid
status, and remain deterministic. The property tests already assert this and
must stay green throughout.

### 7.1-D2 -- The guard

A test asserting **an English render contains no French**. Reuse the
accent-folded wordlist from the 6.1-R4a hardcoded-string audit tool, pointed at
the rendered report rather than the template.

This is the deliverable. Wiring 42 evaluators fixes today; the guard is what
makes "bilingual" a property the repository enforces.

### Why the existing tests missed it

`the English render carries English bundle text` passes because the wired rule
names are English. `French and English renders differ` passes for the same
reason. Neither asserts the English render is *free of* French.

---

## Stream 7.2 -- The console

Measured by `TOOLS/Measure-LocaleCoverage.ps1`: **616 bundle keys, 277
orphaned, 839 unrouted console lines.** Two of roughly 25 deployed scripts
route their UI through the bundle.

### 7.2-D1 -- Wire the orphans

`complianceDiff` first: 90 fully translated keys, zero readers, on the
highest-traffic tool. Then the rest by traffic.

### 7.2-D2 -- Two audits

- **No orphaned bundle keys.** A translated key with no reader is work paid for and never delivered.
- **No unrouted user-facing text** in deployed scripts.

Both directions, deliberately. Fixing one lets the gap reopen from the other
side.

---

## Stream 7.3 -- Provenance, identity and branding

Three problems that share one solution: nothing today proves the toolkit is
genuine, unmodified, or whose.

### The credibility problem this fixes

`INSTALL.md`, `USING.md` and `README.md` all instruct the customer to run
`-ExecutionPolicy Bypass`. **A compliance product cannot ask a security-
conscious organisation to disable a security control in order to run.** Any
competent CISO flags it, and no amount of branding covers it.

Signed scripts run under `RemoteSigned` and `AllSigned` without bypass.

### 7.3-D1 -- Authenticode signing

Sign every deployed `.ps1` and `.psm1`.

**Signing happens at release build, never in the repository.** A signature
covers file content, so any edit invalidates it; committed signatures would
churn on every change and be wrong most of the time. `RELEASE.md` gains a
signing step between "build from clean tagged checkout" and "compress".

**Timestamping is mandatory.** Without a timestamp countersignature the
signature dies when the certificate expires, and every stick in the field dies
with it. With one, it stays valid.

**Certificate choice** -- a decision, not a default:

| | OV (organisation validation) | EV (extended validation) |
|---|---|---|
| Cost | ~EUR 300/yr | ~EUR 400/yr plus hardware token |
| Issuance | days | weeks, stricter vetting |
| SmartScreen | reputation accrues over time | immediate |
| Sole trader | obtainable | harder, may require a registered entity |

The entity question here is the same one `COMMERCIAL-LICENSING.md` raises for
contracting. Answer it once.

**Two risks that must be tested, not assumed:**

1. **Encoding.** `Set-AuthenticodeSignature` rewrites the file. The signature block is base64 and ASCII-safe, but if signing introduces a BOM, audit A2 fails. Test signing against A1 and A2 on a fixture before adopting it.
2. **Air-gapped revocation checking.** Signature verification does not need a network; certificate *revocation* checking may attempt one. On an isolated machine this can stall or fail. This directly threatens the product's strongest claim. Test on a genuinely offline machine and document the behaviour honestly.

### 7.3-D2 -- The manifest: the stick proves itself

A signed `MANIFEST.json` carrying a SHA-256 for every shipped file, generated
at release build.

`Test-Installation.ps1` verifies it before the launcher is trusted:

- **Every file matches** -- report `OK`, the stick is genuine
- **A file differs or is missing** -- report `FAIL` and name the file
- **No manifest** -- report `WARN`: this is a development tree, not a release

This is what "the stick proves itself to the operator" means concretely. It
needs no credentials, no lockout, no network, and it survives copying between
sticks -- a technician can verify a stick handed to them by someone else.

**It also closes a gap found in the field:** extracting a release over an
existing deployment leaves stale files behind, and nothing currently notices.

### 7.3-D3 -- Branding as a system, not a brand

**Fixed branding is a ceiling.** An MSP that cannot hand its own customers a
report under its own name is an MSP that does not buy. `COMMERCIAL-LICENSING.md`
already lists "signed reports under an organisation's own identity" as a
commercial-tier candidate.

One file, `CONFIG/branding.json`, is the single source of identity: product
name, short name, colours, logo, report letterhead, support contact.

**Brand and version become tokens, not literals.** Today `common.appName` is
`"FieldOps Pro"` and `launcher.banner.title` contains `"FIELDOPS PRO v2.1"`.
Both must become substitutions, which simultaneously fixes 7.0-D2 -- the
version literal in both bundles -- and makes white-labelling a config change
rather than a translation edit.

**The constraint that must not bend:** Apache 2.0 section 4 requires
attribution and preservation of `NOTICE`, and section 6 grants no trademark
rights. A white-labelled report may carry the operator's identity; it may not
remove attribution. A test asserts `NOTICE` survives any branding override, and
that a rebranded report still carries the attribution line.

Physical branded hardware is **deferred until there is a customer**. Minimum
order quantities and per-unit cost are a commitment to a market that has not
yet bought anything.

---

## What is deliberately not in Phase 7

**Encryption of the stick.** BitLocker To Go is free and Windows-only; hardware-
encrypted sticks cost EUR 80-150 each and need their unlocker to run on the
target machine, which weakens "installs nothing". Revisit when a customer asks.

**Operator authentication.** A PIN before the launcher opens protects a lost
stick, but adds a credential to lose and a support burden for a single
maintainer. The manifest already delivers the verification that matters.

**Licence enforcement.** Hard to enforce meaningfully under Apache 2.0, and it
contradicts the open-core boundary already published.

---

## Sequencing

```
7.0 Truth  ->  v0.6.1                          (days, blocking)
                 |
     +-----------+-----------+
     |           |           |
    7.1         7.2         7.3
   report     console    provenance
     |           |           |
     +-----------+-----------+
                 |
              v0.7.0
```

Only after 7.1 is "bilingual report" defensible. Only after 7.2 is "full
parity" defensible. Only after 7.3 does the product stop asking customers to
disable a security control to run it.

---

## Decisions required before 7.3 starts

- [ ] OV or EV code-signing certificate -- and under which legal entity
- [ ] Is white-labelling free-tier or commercial-tier? (affects `COMMERCIAL-LICENSING.md` section 4)
- [ ] Does the signing identity also sign reports, or only scripts?

None of these can be answered by engineering.
