# Extending FieldOps Pro

FieldOps Pro - Phase 6, Stream 6.4 (6.4-D6)

How to add a diagnostic engine, a compliance rule mapping, a playbook, or a
language -- and the constraints that will fail your build if you ignore them.

Read `DOCS/ARCHITECTURE.md` first. This document assumes it.

---

## 1. Rules you cannot break

These are enforced by the test suite. A change that violates one fails on
commit, not in the field.

### Encoding

| Path | Encoding |
|------|----------|
| `SCRIPTS/**/*.ps1`, `*.psm1` | **ASCII only, no BOM** |
| `CONFIG/lang/*.json`, `SCRIPTS/Templates/*.html` | **UTF-8 with BOM**, literal accents |

Write PowerShell with `UTF8Encoding($false)`. Write bundles with
`UTF8Encoding($true)`.

In source comments, use `--` where you would write an em dash. No accented
characters in `.ps1` or `.psm1`, ever -- including in comments. Audits A1 and A2
enforce this across the tree.

### PowerShell 5.1 only

No PowerShell 7 syntax. Specifically absent: ternary `?:`, null-coalescing
`??`, `-not` on the pipeline, and `Get-Content -AsByteStream`.

Also worth knowing:

- `Set-StrictMode -Version 1.0` -- higher levels break on PSCustomObject property access
- No scriptblocks as PSCustomObject property values
- No `.ContainsKey()` on a PSCustomObject; use `Get-DictValue`
- `ConvertTo-Json -Depth 5` -- the default of 2 silently truncates
- Never overwrite `$args`, `$profile`, `$Event`
- `Get-ChildItem -Include` is **silently ignored** alongside `-LiteralPath`. Filter on `$_.Extension` instead. This cost us a licence sweep that matched 55 files instead of 29.

### Paths

`$PSScriptRoot`, always. Never a drive letter, never `C:\Dev`, never `E:\`.
Audit A5 fails any deployed script containing a machine-specific path.

The stick's drive letter differs on every machine. This is not a style
preference.

### Licence headers

Every deployed `.ps1` and `.psm1` carries an SPDX header. Add a file, then run:

```powershell
.\TOOLS\Apply-LicenseHeaders.ps1
```

It is idempotent. `Audit-LicenseHeaders.Tests.ps1` fails the suite if you
forget.

---

## 2. Adding a diagnostic engine

An engine observes the machine and emits two artifacts: an HTML report for a
human, and a JSON sidecar for the collector.

### Place it

`SCRIPTS/<Area>/Invoke-<Thing>.ps1`, where `<Area>` is one of `Diagnostics`,
`Network`, `Security`, `Deployment`, `Reporting`, or a new one.

### Emit the sidecar

The collector reads `LOGS\<Prefix>_*.json` and looks up findings by category and
check name. Match the existing shape:

```powershell
$result = [ordered]@{
    Engine    = 'MyEngine'
    Timestamp = (Get-Date).ToString('o')
    Host      = $env:COMPUTERNAME
    Checks    = @(
        [ordered]@{
            Category = 'Identity'
            Check    = 'Local Admin Accounts'
            Status   = 'OK'
            Observed = 'Administrator, fieldtech'
            Detail   = 'two accounts in the local Administrators group'
        }
    )
}
$result | ConvertTo-Json -Depth 5 |
    Set-Content -LiteralPath $out -Encoding UTF8
```

`Category` and `Check` are what evaluators match on, so they are a contract, not
free text. Look at what the existing evaluators expect before inventing new
values.

### Degrade, never guess

This is the rule that matters most.

```powershell
# Right: says what happened
$tpm = Get-Tpm -ErrorAction SilentlyContinue
if ($null -eq $tpm) {
    $status = 'Unknown'; $observed = 'Cannot query - no TPM present'
} else {
    $status = if ($tpm.TpmReady) { 'OK' } else { 'Warning' }
}

# Wrong: a missing TPM becomes a passing check
$status = if ((Get-Tpm -ErrorAction SilentlyContinue).TpmReady) { 'OK' } else { 'OK' }
```

A machine that cannot answer must be recorded as unable to answer. Anything else
produces a compliance report that lies, which is worse than no report.

### Never throw

An engine that throws takes down a diagnostic run over one probe. Wrap probes in
`try`/`catch`, record the failure as a finding, and continue.

---

## 3. Adding or changing a compliance rule mapping

The 42 rules are fixed by ANSSI -- you are changing how a rule is *evaluated*,
not adding a forty-third. Audit A4 asserts exactly `Get-R1` through `Get-R42`
with no gaps or extras.

```powershell
function Get-R20 {
    param($Sec, $Net, $Health)

    $wifi = Find-Check -EngineData $Net -Category 'WiFi' -CheckLike 'Encryption'

    if (-not (Test-Observed $wifi)) {
        # No Wi-Fi is not a failure. A wired desktop has nothing to report.
        return @{ Status = 'pv'; Detail = T 'rule.r20.no_wifi' }
    }
    if ($wifi.Observed -match 'WPA[23]') {
        return @{ Status = 'cv'; Detail = ... }
    }
    # WEP or Open must never be cv.
    return @{ Status = 'pv'; Detail = ... }
}
```

### Requirements

- **Never throw.** Return `pv` on absent data.
- **Never return `cv` because a probe returned nothing.**
- **Deterministic.** Same input, same output. A property test asserts it.
- **All prose through the locale wrapper** (`T 'key'`), never literal French or English. A test asserts no evaluator carries a bare hardcoded name.

### Test it

Add a branch test in `tests/evaluators/Evaluators.Branches.Tests.ps1` for each
decision path, including the null-engine case. The property tests will pick up
your evaluator automatically.

**The branch tests exist because they found a real defect**: R32 matched VPN
status with the regex `'Connected'`, which also matches `'Disconnected'`. Every
machine without a VPN silently passed. The fix was
`'\b(?<!dis)(?<!not\s)(connected|connecte|actif)\b'`. Write the negative case.

---

## 4. Adding a remediation playbook

Read `PLAYBOOKS/remediation/SCHEMA.md`. Briefly:

Create `PLAYBOOKS/remediation/RB-<CAT>-<NNN>.md` where `<CAT>` is a 2-4 letter
category and `<NNN>` a three-digit serial. The filename must equal the front
matter `id`.

```yaml
---
id: RB-FW-003
title: Restore a firewall rule removed by a third-party installer
category: FW
severity: high
prerequisites:
  - Administrator rights
relatedRules:
  anssi: [R17]
estimatedDurationMinutes: 10
revertable: true
schemaVersion: "1.0"
---
```

The body should follow the established shape: when to use, **when not to**,
verify the condition first, numbered procedure, honest rollback, what to do if
it does not hold.

**The "when not to" section is not optional padding.** A technician following
step 3 of a procedure that never applied to their machine is worse off than one
with no playbook. `RB-FW-001` refuses to run where a third-party product owns
the firewall; `RB-BL-003` refuses removable volumes because auto-unlock binds a
disk to one machine.

**On `revertable`**: true only if the playbook documents a *complete* rollback.
When in doubt, false -- the flag gates whether a procedure can be offered as an
automated fix.

The front-matter parser handles a deliberately bounded YAML subset and returns
null on anything else. If it rejects your file, reformat the file; do not extend
the parser.

Validation runs automatically: every `RB-*.md` in the tree must parse and
conform, or the suite fails.

---

## 5. Adding a workflow playbook

Different concept, different directory. `PLAYBOOKS/*.json` chains engines into
one operation, consumed by `Invoke-Playbook.ps1`.

Note that `Invoke-Playbook.ps1` **writes the built-in workflow files on first
run**. If you add one with a name it recognises, expect it to be overwritten.

---

## 6. Adding a language

1. Copy `CONFIG/lang/en.json` to `CONFIG/lang/<code>.json`
2. Translate every value. **Leave every key.**
3. Save as UTF-8 **with BOM**
4. Run the suite

The parity test fails if the new bundle has a key the others lack, or lacks one
they have. This is deliberate: a partially translated report is a worse
deliverable than an untranslated one, because the gaps look like defects.

Empty values fail too -- an untranslated key must not be shipped blank.

---

## 7. Before you open a PR

```powershell
.\TOOLS\Apply-LicenseHeaders.ps1   # if you added a script
.\tests\Run-AllTests.ps1           # everything, including Slow audits
```

The pre-commit hook runs the fast tier and pre-push runs the full suite, so a
violation is caught either way. Running it yourself first means finding out in
seconds rather than after writing a commit message.

### What the audits will tell you

| Failure | Cause |
|---------|-------|
| A1 | Non-ASCII byte in a `SCRIPTS` source file |
| A2 | A file gained a BOM |
| A4 | Evaluator count is no longer exactly 42 |
| A5 | A hardcoded machine path |
| Licence headers | New script not stamped |
| Locale parity | Key drift between bundles |
| Playbook conformance | Front matter that does not parse or conform |

---

## 8. House style

**Comments explain why, not what.** `# increment i` is noise. `# Renaming
rather than deleting is deliberate: it makes the step reversible and preserves
evidence if the reset does not help` is the product.

**One concern per PR.** Broader refactors get tracked as named follow-ups rather
than bundled in.

**Write the guard test before the fix** where you can. `Audit-NoDirectAnthropicCalls`
was authored failing, with its failing state documented as the definition of
done for the work that would make it pass.

**Be honest in commit messages** about what you did not do, and why. "Deliberately
not done" is a section that saves the next person from assuming it was an
oversight.

---

## Related

- `DOCS/ARCHITECTURE.md` -- how the system fits together
- `DOCS/TESTING.md` -- test suite reference
- `PLAYBOOKS/remediation/SCHEMA.md` -- playbook authoring contract
- `CONTRIBUTING.md` -- contribution process
