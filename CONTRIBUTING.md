# Contributing to FieldOps Pro

Thanks for considering a contribution. FieldOps Pro is a portable IT diagnostics and compliance toolkit, and the bar for changes is high: it runs as Administrator on production machines, reads sensitive system state, and is used in the field with no second chance to retry. This document explains how to contribute in a way that keeps the project trustworthy and easy to maintain.

If you have not yet read them, start with:

- [`README.md`](README.md) — what the toolkit is and how to run it
- [`SECURITY.md`](SECURITY.md) — security policy and how to report vulnerabilities (**do not** open a public issue for security bugs)
- [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md) — community expectations

By contributing, you agree that your contribution is licensed under the project's license (see [`LICENSE`](LICENSE)) and that you have the right to submit it.

---

## Ways to contribute

| Contribution                       | Channel                                |
| ---------------------------------- | -------------------------------------- |
| Bug report (non-security)          | GitHub Issues — use the bug template   |
| Security vulnerability             | See [`SECURITY.md`](SECURITY.md) — **never** a public issue |
| Feature request                    | GitHub Issues — use the feature template, expect discussion before code |
| Code change (fix, feature, refactor) | Pull request against `main`          |
| New language translation           | Pull request adding `CONFIG/lang/<lang>.json` |
| Documentation improvement          | Pull request — typo fixes welcome without prior discussion |
| Question, idea, design discussion  | GitHub Discussions                     |

For anything larger than a typo fix or a small bug, **open an issue first** so we can agree on the approach before you spend time on a PR.

---

## Development environment

FieldOps Pro is a Windows-only, PowerShell 5.1 project that runs from removable media. The reference development setup is:

- Windows 10 or 11 (the toolkit targets both)
- **Windows PowerShell 5.1** — the shipped runtime on every supported Windows version. PowerShell 7 is **not** a target; do not introduce 7-only syntax (see "PowerShell 5.1 rules" below).
- Administrator rights on a test machine you own or have written authorization to use
- A FAT32 or exFAT USB drive for end-to-end testing (Ventoy is what we use, but any bootable USB workflow is fine)
- Optional: VS Code with the PowerShell extension, or PowerShell ISE

Clone the repository to a working directory on disk first; do not develop directly on the USB. Copy to the USB only when you are ready to test.

```powershell
git clone https://github.com/<org>/<repo>.git
cd <repo>
```

There is no build step. Scripts run as-is from `SCRIPTS/`.

---

## Project layout

```
SCRIPTS/
  FieldOps-Launcher.ps1            # canonical entry point (operator-facing menu)
  Core/                            # shared modules and engines
    Config.psd1
    FieldOps-Locale.psm1           # translation engine
    FieldOps-Tools.ps1             # portable tools menu (dot-sourced by launcher)
    Invoke-ComplianceDiff.ps1      # snapshot + diff engine
    Invoke-Dashboard.ps1           # HTML dashboard generator
    Invoke-FieldOpsHandler.ps1     # fieldops:// protocol handler
    Logger.psm1
    Register-FieldOpsProtocol.ps1
    SessionManager.psm1
    Utils.psm1                     # Get-DictKeys, Test-DictKey, Get-DictValue
    ...                            # other modules
  Deployment/                      # software deploy, AAD join, VPN setup
  Diagnostics/                     # PCHealth, disk analysis
  Network/                         # network repair
  Reporting/                       # incident reports
  Security/                        # security scan
CONFIG/
  lang/
    en.json                        # English translation keys
    fr.json                        # French translation keys
  technician.template.json         # operator identity template (real config gitignored)
DOCS/
  schemas/
    technician.schema.json         # JSON Schema for technician config
PLAYBOOKS/                         # operational playbooks
```

Generated output (`LOGS/`, `REPORTS/`, `SNAPSHOTS/`, `*.sha256` sidecars, `*.json.gz` snapshots) **must not** be committed. The `.gitignore` covers this; if you find yourself force-adding output files, stop and ask.

### Entry points

There are intentionally three FieldOps-prefixed entry points. Know which is which before modifying:

| File                                      | Purpose                                             |
| ----------------------------------------- | --------------------------------------------------- |
| `SCRIPTS/FieldOps-Launcher.ps1`           | Operator-facing menu. This is what users run.       |
| `SCRIPTS/Core/Invoke-FieldOpsHandler.ps1` | Handles the `fieldops://` URI scheme. Not run directly. |
| `SCRIPTS/Core/FieldOps-Tools.ps1`         | Portable tools sub-menu. Dot-sourced by the launcher. |

### Secrets

The Anthropic API key for AI compliance analysis is **not** stored in any file. It lives in Windows Credential Manager under target `FieldOpsPro:Anthropic`. See `README.md` for the one-time setup command.

---

## PowerShell 5.1 rules (read this before writing code)

These rules exist because PS 5.1 has real footguns that have already cost us multiple production bugs in this codebase. Every one of them is non-negotiable.

### 1. Never use `try`/`catch` as a value inside a hash literal

PS 5.1 does not allow `try`/`catch` as an expression inside `@{}` or `[PSCustomObject]@{}`. It parses but produces wrong results.

```powershell
# WRONG — PS 5.1 will not behave as you expect
[PSCustomObject]@{
    SerialNumber = try { (Get-CimInstance Win32_BIOS).SerialNumber } catch { 'Unknown' }
}

# RIGHT
$serial = try { (Get-CimInstance Win32_BIOS).SerialNumber } catch { 'Unknown' }
[PSCustomObject]@{ SerialNumber = $serial }
```

### 2. Never call `.ContainsKey()` on `PSCustomObject` or `OrderedDictionary`

`PSCustomObject` does not have `.ContainsKey()`. `OrderedDictionary` does, but it behaves inconsistently across the JSON round-trip we do. Use the project helpers in `SCRIPTS/Core/Utils.psm1`:

```powershell
Get-DictKeys $obj      # returns string[] of keys
Test-DictKey $obj 'X'  # returns [bool]
Get-DictValue $obj 'X' # returns the value or $null
```

If you find yourself reaching for `.ContainsKey()`, you are about to write a bug.

### 3. `ConvertTo-Json` rules

- Maximum `Depth` is **5**, and only on per-category data — never on a full snapshot graph.
- Full-graph deep serialization will hang for minutes on real machines. Use the chunked per-category serializer in `Invoke-ComplianceDiff.ps1` as the template.
- After serializing, GZip-compress the output. Plain `.json` snapshots are not the supported format.

### 4. Never match `.sha256` sidecar files as snapshots

When enumerating snapshots, filter explicitly:

```powershell
# WRONG — matches sidecars
Get-ChildItem $SnapshotDir -File

# RIGHT
Get-ChildItem $SnapshotDir -File |
    Where-Object { $_.Extension -in @('.json', '.gz') -and $_.Name -notlike '*.sha256' }
```

This bug has been fixed twice. Do not reintroduce it.

### 5. Never shadow PowerShell automatic variables

`$Host`, `$Error`, `$Input`, `$Matches`, `$PSItem`, `$_`, etc. are reserved. Use `$HostName`, `$ErrorRecord`, etc. instead. The compliance engine carries scars from a `$Host` parameter that silently overrode the runtime's own variable.

### 6. Performance — batch CIM queries

`Get-CimInstance Win32_Service` once and filter in memory beats querying per-service by a factor of >100x on machines with hundreds of services. The same applies to processes, drivers, and scheduled tasks. Look at the existing `Get-ServicesSnapshot` for the correct pattern.

---

## Code style

- **Function naming.** PowerShell `Verb-Noun`, approved verbs only (`Get-Verb` lists them). Use the project prefix `FieldOps-` or a category prefix (`Invoke-`, `Get-`, `Save-`, `Compare-`) consistently.
- **Indentation.** 4 spaces, no tabs.
- **Line length.** Soft limit 120 characters. Break long pipelines after `|` with the operator on the new line.
- **Comments.** Comment *why*, not *what*. The code already says what.
- **Comment-based help.** Every public function gets a `<# .SYNOPSIS / .DESCRIPTION / .PARAMETER / .EXAMPLE #>` block. The dashboard and the help system read these.
- **Strict mode.** New modules should run cleanly under `Set-StrictMode -Version 3.0`. Existing modules are being migrated; do not regress what is already strict.
- **Encoding.** All `.ps1` and `.psm1` files are UTF-8 with BOM (PS 5.1 requires the BOM to read non-ASCII characters correctly — this is critical for French strings). Enforced via `.gitattributes`.
- **Line endings.** CRLF on Windows files, LF on JSON and Markdown. Enforced via `.gitattributes`; do not override.

---

## Localization

The toolkit is bilingual (English, French) via `SCRIPTS/Core/FieldOps-Locale.psm1`. Translation files live in `CONFIG/lang/`. There are currently 275 translation keys per language.

### Adding a new user-facing string

1. Add the key to **both** `CONFIG/lang/en.json` and `CONFIG/lang/fr.json`. Untranslated keys break the locale parity check.
2. Use the key in code via the locale function (do not hard-code English strings):
   ```powershell
   Write-Host (Get-LocaleString 'compliance.diff.summary.header')
   ```
3. Keep keys hierarchical and meaningful: `<module>.<area>.<element>`.

### Adding a new language

1. Copy `CONFIG/lang/en.json` to `CONFIG/lang/<iso-639-1>.json` (e.g. `de.json`, `es.json`).
2. Translate every value. Keep keys identical.
3. Test with `Set-FieldOpsLocale -Language <code>` and run the dashboard end-to-end to catch overflow in fixed-width UI elements.
4. Open a PR — translations get reviewed by a native speaker when one is available.

---

## Testing

There is currently no automated test suite (this is a known gap; contributions welcome). Until there is, every PR must include a manual test plan in the PR description, covering at minimum:

- The exact command(s) you ran
- The Windows version, PowerShell version (`$PSVersionTable.PSVersion`), and locale you tested under
- Expected output vs. actual output, with a snippet or screenshot
- For changes touching snapshots: the `.json.gz` size before and after, and confirmation the SHA256 sidecar still validates
- For changes touching the dashboard: confirmation it renders correctly in both EN and FR

Changes to `SCRIPTS/Core/Invoke-ComplianceDiff.ps1` additionally require:

- A baseline snapshot, a change-inducing action, a delta snapshot, and the resulting diff report attached or summarized
- Confirmation that AI analysis still falls back to local rule-based analysis when no API key is configured in Credential Manager

---

## Pull request workflow

1. **Fork** the repository and create a topic branch from `main`:
   ```
   git checkout -b fix/compliance-diff-empty-baseline
   ```
   Branch naming: `fix/<short-desc>`, `feat/<short-desc>`, `docs/<short-desc>`, `refactor/<short-desc>`.

2. **Commit in logical units.** One concern per commit. Use [Conventional Commits](https://www.conventionalcommits.org/):
   ```
   fix(compliance-diff): handle empty baseline snapshot without throwing
   feat(dashboard): add fleet-wide grade distribution chart
   docs(security): clarify Ventoy read-only requirement
   ```

3. **Sign your commits** if you can (`git commit -s`). This adds a `Signed-off-by:` line and asserts you have the right to submit the contribution under the project license.

4. **Run a self-review** before pushing. Re-read the diff. Look for the PS 5.1 rules above.

5. **Open the PR against `main`.** Fill in the template completely. PRs without a test plan will be asked for one before review.

6. **Address review comments** by pushing additional commits to the same branch. Do not force-push during review unless asked — it makes diffs hard to follow. Squash or rebase at merge time, not before.

7. **Squash on merge** is the default. The maintainer will choose merge strategy; do not perform the merge yourself.

### What gets a PR rejected

- Violates one of the PS 5.1 rules above
- Hard-codes a user-facing English string (must go through the locale)
- Commits generated output (`LOGS/`, `REPORTS/`, `SNAPSHOTS/`, `.sha256`, `.json.gz`)
- Commits secrets, API keys, or real `technician.json` (the gitignored personal config)
- Introduces a runtime dependency on PowerShell 7 or on a module not shipped with Windows
- Adds a new module without comment-based help
- Reaches network endpoints other than the documented Anthropic API for AI analysis
- Lowers test coverage of the locale parity check (every key in `en.json` must exist in every other language file)

---

## Releases and versioning

Releases use **semantic versioning** at the per-script level. Each major component has its own version (`Invoke-ComplianceDiff.ps1` v1.2.x, `Invoke-Dashboard.ps1` v3.2.x, `FieldOps-Locale.psm1` v1.0.x). The repository tag reflects the toolkit-wide release and is set by the maintainer.

Changelogs live in `CHANGELOG.md` at the repo root, organized by date and component. Add an entry to the *Unreleased* section in the same PR that introduces the change.

---

## Getting help

- **Project questions, design discussions:** GitHub Discussions
- **Bug reports:** GitHub Issues
- **Security:** see [`SECURITY.md`](SECURITY.md)
- **Other contact:** `contact@domotikchezvous.com`

<!-- TODO: contact@domotikchezvous.com is a temporary inbox. Replace with a permanent address once the project domain is finalized. -->

We try to acknowledge new issues and PRs within seven days. This is a small-team project — patience appreciated.

Thanks for contributing.
