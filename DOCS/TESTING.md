# FieldOps Pro - Testing

How the FieldOps Pro test suite is structured, how to run it, and how to extend
it without breaking the invariants that keep it trustworthy. The suite is the
project's correctness guarantee: it must run offline, on any Windows machine,
under PowerShell 5.1, and it gates every commit and every push.

## Source of truth

The tests live under `tests/`. Pester 5.7.1 is vendored offline in
`TOOLS/PowerShellModules/Pester/5.7.1/` so the suite runs air-gapped with no
network access. Nothing in the suite depends on a specific machine, drive
letter, or hardware model.

As of Chapter 6.6 the suite is **354 tests**, all green.

## Quick start

| Goal | Command |
|---|---|
| Run the fast tier (unit + branch) | `.\tests\Run-FastTests.ps1` |
| Run the full suite (everything) | `.\tests\Run-AllTests.ps1` |
| Install the pre-commit hook (fast tier) | `.\tests\Install-PreCommitHook.ps1` |
| Install the pre-push hook (full suite) | `.\tests\Install-PrePushHook.ps1` |

Pester is bootstrapped automatically from the offline bundle on first run; no
manual install is required. If you want to pre-stage it explicitly, run
`.\tests\Install-PesterIfMissing.ps1`.

## The two-tier gate

Testing is split into two tiers so that local feedback stays fast while nothing
reaches the remote unverified.

| Tier | Hook | Runner | Scope | Time | Contract |
|---|---|---|---|---|---|
| Fast | `pre-commit` | `Run-FastTests.ps1 -CI` | unit + branch | ~13s | under 30s |
| Full | `pre-push` | `Run-AllTests.ps1` | all 354 incl property + audit | ~37s | must pass to push |

On every `git commit`, the pre-commit hook runs the fast tier. On every
`git push`, the pre-push hook runs the **full** suite before any data leaves the
machine; if any test fails, the push is blocked.

Bypass either hook (use sparingly) with `--no-verify`:

```
git commit --no-verify
git push --no-verify
```

### How tier selection works

Tier selection is **tag-driven**, with the tag as the single source of truth.
`Run-FastTests.ps1` discovers every test file under `unit/`, `evaluators/`, and
`audit/`, then applies a Pester tag filter of `Fast`. Only `Fast`-tagged
`Describe` blocks execute; everything else is discovered but not run.

- Unit tests and branch tests are tagged `Fast`.
- Property tests and audit tests are tagged `Slow`.

`Run-AllTests.ps1` applies no tag filter, so it runs every discovered test.

This design replaced an earlier, brittle filename-based exclusion. Do not
reintroduce filename filters: to move a test between tiers, change its `-Tag`,
nothing else.

## Test layout

```
tests/
  Run-AllTests.ps1            # full suite runner (no tag filter)
  Run-FastTests.ps1           # fast tier runner (Fast tag filter)
  Install-PesterIfMissing.ps1 # offline Pester bootstrap
  Install-PreCommitHook.ps1   # writes .git/hooks/pre-commit (fast tier)
  Install-PrePushHook.ps1     # writes .git/hooks/pre-push (full suite)
  Get-Fixture.ps1             # fixture loader (Get-Fixture, Get-FixtureNames)
  Get-EvaluatorSource.ps1     # AST extraction of the 42 rule evaluators
  Format-Bundle.ps1           # locale bundle helpers for tests
  PropertyTests.psm1          # Invoke-Property harness + RNG generators
  fixtures/                   # 20 JSON report fixtures (nominal + edge cases)
  unit/
    Compliance/               # evaluator extraction, helper null-safety, R14/R16/R17
    Core/                     # Fixture, Logger, Summary, Utils
    Locale/                   # Bundle parity (EN/FR), LocaleEngine
  evaluators/
    Evaluators.Branches.Tests.ps1   # every branch of the 22 computed rules (Fast)
    Evaluators.Property.Tests.ps1   # property-based, randomized inputs (Slow)
  audit/
    Audit.Repo.Tests.ps1            # repo-wide structural invariants (Slow)
```

## Architecture and key patterns

These are the load-bearing design decisions. A future maintainer must
understand them before changing the corresponding tests.

### AST evaluator extraction (`Get-EvaluatorSource.ps1`)

`SCRIPTS/Compliance/Build-ANSSIData.ps1` defines the 42 rule evaluators
(`Get-R1`..`Get-R42`) and helpers, then runs a collection main body
unconditionally at the bottom of the file. To test the evaluators in isolation
without executing that main body (which would probe the live machine and write
a report), `Get-EvaluatorSource.ps1` parses the file with the PowerShell AST
(`[System.Management.Automation.Language.Parser]::ParseInput`) and returns only
the function-definition extents as text. Tests dot-source that text in a
`BeforeAll`, getting the real evaluator functions with zero side effects and
zero production changes.

### Property-based testing (`PropertyTests.psm1`)

`Invoke-Property -Name -Generator -Property -Iterations` generates N random
inputs and asserts a property holds for each. The generators
(`Get-RandomInt`, `Get-RandomString`, `Get-RandomElement`, ...) build
deliberately adversarial engine objects: null engines, wrong-type fields,
missing keys, garbage values.

**Critical scope rule:** the `-Property` and `-Generator` scriptblocks execute
inside the harness's scope, *not* the test file's scope. Functions dot-sourced
into `BeforeAll` (evaluators, helpers) are **not** visible by bare name inside
those blocks. Capture them as scriptblocks and call through the capture:

```
$dict = ${function:Get-DictValue}        # capture in BeforeAll
# inside the -Property block:
$status = & $dict $result 'Status' $null # call via the capture, not by name
```

Calling a helper by bare name inside a property block fails with
"term is not recognized". This is the single most common mistake when adding
property tests.

### Repository audit (`audit/Audit.Repo.Tests.ps1`)

Seven structural invariants in two tiers. The suite prints its own scope and
exclusion contract on every run.

Universal laws (whole `SCRIPTS/` tree, archive included):

- **A1 ASCII-only** - zero bytes greater than 127 in any source file.
- **A2 No BOM** - no file begins with the UTF-8 BOM (EF BB BF). A BOM breaks
  `sh` shebang resolution in the git hooks and can corrupt on field consoles.
- **A5 No machine-specific paths** - no `C:\Dev`, `C:\Users`, or `E:\` path
  literal in deployed code. This is detected with the AST tokenizer, not regex,
  so the distinction below is exact.

Production contracts:

- **A3 StrictMode** - an opt-in **allowlist** (currently only
  `Build-ANSSIData.ps1`). A script joins the allowlist when it has been built
  and verified under `Set-StrictMode -Version 1.0`, not by blanket assertion.
  18 of 28 production files legitimately do not declare StrictMode (modules
  inherit the caller's scope), so a blanket rule would be false rigor.
- **A4 42-rule count** - `Build-ANSSIData.ps1` defines exactly `Get-R1`..`Get-R42`,
  no gaps, extras, or duplicates.
- **A6 Report schema** - `report-data.sample.json` has its 6 top-level keys and
  `Summary.Total = 42`.

#### A5: why provider drives are allowed but `C:\Dev` is not

A portability defect is a path tied to *this developer's machine or USB mount*.
A universal Windows location is not. A5 forbids the former and allows the
latter:

| Forbidden (machine-specific) | Allowed (universal) |
|---|---|
| `C:\Dev\...` (developer repo) | `HKLM:\` `HKCU:\` (registry provider drives) |
| `C:\Users\<name>\...` (a profile) | `Cert:\` `Env:\` (provider drives) |
| `E:\...` (the USB dev mount) | `X:\Windows\...` (WinPE RAM disk, always X:) |
| | `C:\Program Files\...` `C:\Windows\...` (standard OS) |

Registry keys (`HKLM:\SOFTWARE\...`) are identical on every Windows machine and
are how the security and compliance scanners legitimately address the registry.
Banning them would break the product. A5 targets only developer/USB roots; code
must resolve its own paths via `$PSScriptRoot`, never a machine literal.

Documented exclusions from the production-set rules: the `Archive\` tree and
`Patch-*` / `Debug-*` / `Apply-*` one-off utilities are dev tooling, never
deployed, and may contain instruction strings with dev paths.

### Offline Pester bootstrap

`Install-PesterIfMissing.ps1` and the runners locate Pester 5.7.1 from
`TOOLS/PowerShellModules/Pester/5.7.1/` when it is not already installed. The
suite never reaches the network. This is required for air-gapped field
environments.

## How to add a test

1. **Pick the tier.** Fast behavioural checks (a rule branch, a helper, a
   parity assertion) go in `unit/` or `evaluators/Evaluators.Branches.Tests.ps1`
   with `-Tag 'Fast'`. Slow checks (randomized property tests, repo-wide audits)
   carry `-Tag 'Slow'`.
2. **Place the file.** Use `*.Tests.ps1` under `unit/`, `evaluators/`, or
   `audit/`. The runners discover it automatically; no registration needed.
3. **Tag every `Describe`.** Tier selection is by tag. An untagged `Describe`
   will not run in the fast tier.
4. **Follow PS 5.1 source rules** (the audit enforces these):
   - ASCII only, no Unicode punctuation, no BOM.
   - `[CmdletBinding()]` then `param()` then `Set-StrictMode` where applicable.
   - Do not use reserved automatic variables as parameter names
     (`$args`, `$input`, `$profile`, `$Event`).
5. **Verify before commit.** Run `.\tests\Run-AllTests.ps1` and confirm green.
   The pre-push hook will run it again before the push is accepted.

## Troubleshooting and known gotchas

These are real failure modes encountered while building the suite.

- **"term is not recognized" inside a property block** - a helper/evaluator was
  called by bare name. Capture it as a scriptblock in `BeforeAll`
  (`${function:Name}`) and call via `& $capture`. See the property-testing
  section above.
- **Pester discovery-scope error** - `-ForEach` data must be built at top-level
  script scope and passed as plain strings or scalars; closure variables built
  in `BeforeAll` are not available at discovery time.
- **Scriptblock counter does not update** - a local integer does not propagate
  through `& $ScriptBlock`. Use a hashtable reference type (`@{Count=0}`).
- **Hook silently breaks** - the hook file was written with a UTF-8 BOM, which
  breaks `sh` shebang resolution. Always write hook files with
  `New-Object System.Text.UTF8Encoding($false)`; both installers guard against
  this and fail loudly if a BOM is present.
- **HashSet constructor overload failure (PS 5.1)** - passing a PowerShell
  `object[]` to the `HashSet[string]` constructor fails. Build an empty set and
  `.Add()` in a loop instead.
- **Audit A1/A2 fails after editing a file** - an editor saved non-ASCII
  (smart quotes, em-dash) or added a BOM. Re-save as ASCII without BOM. To fix
  existing mojibake deterministically, round-trip through Latin1
  (`[System.Text.Encoding]::GetEncoding('ISO-8859-1')`) and replace the exact
  byte sequences.

## Reference

- Full chapter specification: `DOCS/PHASE-6-DESIGN.md` section 6.6.
- Build pipeline for the design document: `DOCS/BUILD-PIPELINE.md`.
