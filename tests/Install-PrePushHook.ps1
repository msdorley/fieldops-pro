#Requires -Version 5.1
<#
.SYNOPSIS
    Installs the FieldOps Pro pre-push hook into the local git repository.

.DESCRIPTION
    Writes .git\hooks\pre-push so that every `git push` automatically runs
    tests\Run-AllTests.ps1 before the push is sent to the remote.

    This is the second tier of the two-tier test gate:
        pre-commit -> tests\Run-FastTests.ps1 -CI   (fast: unit + branch,
                      ~10s, every commit; quick local feedback)
        pre-push   -> tests\Run-AllTests.ps1         (full: all 354 incl
                      property + audit, ~28s, every push; structural and
                      property invariants gate everything that leaves the
                      machine)

    If any test fails, the push is blocked and the developer sees the failure
    output.  The hook can be bypassed with:
        git push --no-verify

    The hook script written is a POSIX sh script (required by git on all
    platforms) that invokes PowerShell 5.1 with the correct flags:
        -NoProfile          avoid user profile side-effects
        -ExecutionPolicy Bypass  avoid policy blocks on dev machines
        -File               run the script file, not a command string

    Idempotent: running this script multiple times is safe.  If a hook
    already exists it is shown to the user and overwrite is confirmed
    unless -Force is supplied.

    Non-fatal: if the .git directory cannot be found (e.g. running outside
    a git repo) the script exits with a warning rather than an error.
    Test runners (Run-AllTests.ps1, Run-FastTests.ps1) do not depend on
    this hook -- it is a developer convenience only.

.PARAMETER Force
    Overwrite an existing hook without prompting.

.PARAMETER RepoRoot
    Override the repository root.  Defaults to the parent of $PSScriptRoot
    (tests\ -> repo root).

.NOTES
    FieldOps Pro - Chapter 6.6 Continuous Validation - D14b
    PS 5.1.  ASCII source.  Set-StrictMode -Version 1.0.
    Called once per developer clone.
    The hook itself is a sh script; this installer is PowerShell.
    Reference: DOCS\PHASE-6-DESIGN.md section 6.6.4.4.
#>

[CmdletBinding(SupportsShouldProcess = $false)]
param(
    [Parameter(Mandatory = $false)]
    [switch]$Force,

    [Parameter(Mandatory = $false)]
    [string]$RepoRoot = ''
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Step {
    param([string]$Text)
    Write-Host "[Install-PrePushHook] $Text" -ForegroundColor Cyan
}

function Write-OK {
    param([string]$Text)
    Write-Host "[Install-PrePushHook] OK: $Text" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Text)
    Write-Warning "[Install-PrePushHook] $Text"
}

# ---------------------------------------------------------------------------
# Resolve repo root
# ---------------------------------------------------------------------------
if ($RepoRoot -eq '') {
    # Script lives at tests\Install-PrePushHook.ps1
    # Parent = repo root
    $RepoRoot = Split-Path $PSScriptRoot -Parent
}

$gitDir   = Join-Path $RepoRoot '.git'
$hooksDir = Join-Path $gitDir 'hooks'
$hookFile = Join-Path $hooksDir 'pre-push'

# ---------------------------------------------------------------------------
# Verify we are inside a git repo
# ---------------------------------------------------------------------------
if (-not (Test-Path $gitDir)) {
    Write-Warn "No .git directory found at: $gitDir"
    Write-Warn "Run this script from inside a git repository clone."
    Write-Warn "Hook not installed -- this is non-fatal."
    exit 0
}

# ---------------------------------------------------------------------------
# Ensure hooks directory exists
# ---------------------------------------------------------------------------
if (-not (Test-Path $hooksDir)) {
    $null = New-Item -ItemType Directory -Path $hooksDir -Force
    Write-Step "Created hooks directory: $hooksDir"
}

# ---------------------------------------------------------------------------
# Check for existing hook
# ---------------------------------------------------------------------------
if ((Test-Path $hookFile) -and (-not $Force)) {
    Write-Step "Existing pre-push hook found:"
    Write-Host ""
    Get-Content $hookFile | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    Write-Host ""
    $answer = Read-Host "[Install-PrePushHook] Overwrite? (y/N)"
    if ($answer -notmatch '^[yY]') {
        Write-Warn "Hook installation cancelled. Existing hook preserved."
        exit 0
    }
}

# ---------------------------------------------------------------------------
# Build the hook script content
# The path passed to -File must use forward slashes and be relative to the
# repo root so the hook works regardless of where git is invoked from.
# git sets the working directory to the repo root before running hooks.
#
# A pre-push hook receives one line per ref on stdin:
#     <local ref> <local sha> <remote ref> <remote sha>
# For a DELETION the local sha is all zeros, because no commits are being sent.
# The hook used to discard stdin entirely and run the suite unconditionally, so
# `git push origin --delete <branch>` spent 5.5 minutes testing a tree that was
# not being pushed anywhere. Nothing was wrong with the result; it was simply
# an answer to a question nobody asked.
#
# The zero check is written as "contains any non-zero character" rather than a
# comparison against forty zeros, so it keeps working under SHA-256 repos where
# the null sha is sixty-four characters.
# ---------------------------------------------------------------------------
$hookContent = @'
#!/bin/sh
# FieldOps Pro pre-push hook
# Installed by tests/Install-PrePushHook.ps1 (D14b)
# Bypass with: git push --no-verify
#
# Runs the FULL suite (all tests incl property + audit) via Run-AllTests.ps1
# Exit 0 = all tests passed, push proceeds
# Exit non-zero = test failure, push blocked
#
# Deletions and an empty stdin send no commits, so there is nothing to test.

has_commits=0
while read -r local_ref local_sha remote_ref remote_sha
do
    case "$local_sha" in
        *[!0]*) has_commits=1 ;;
    esac
done

if [ "$has_commits" -eq 0 ]; then
    echo "pre-push: no commits in this push (deletion only) -- skipping the suite."
    exit 0
fi

exec powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Run-AllTests.ps1
'@

# ---------------------------------------------------------------------------
# Write the hook file
# Must use LF line endings (POSIX sh requirement)
# ---------------------------------------------------------------------------
$hookContentLF = $hookContent -replace "`r`n", "`n" -replace "`r", "`n"
$utf8NoBom     = New-Object System.Text.UTF8Encoding($false)

try {
    [System.IO.File]::WriteAllText(
        $hookFile,
        $hookContentLF,
        $utf8NoBom
    )
} catch {
    throw "Failed to write hook file at '$hookFile': $_"
}

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
if (-not (Test-Path $hookFile)) {
    throw "Hook file not found after write: $hookFile"
}

$written = [System.IO.File]::ReadAllText($hookFile, [System.Text.Encoding]::UTF8)
if ($written -notmatch 'Run-AllTests') {
    throw "Hook file content verification failed: Run-AllTests not found in written file."
}

$firstBytes = [System.IO.File]::ReadAllBytes($hookFile)
if ($firstBytes.Length -ge 3 -and
    $firstBytes[0] -eq 0xEF -and
    $firstBytes[1] -eq 0xBB -and
    $firstBytes[2] -eq 0xBF) {
    throw "Hook file was written with a UTF-8 BOM, which breaks sh shebang resolution. This is a bug in the writer."
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-OK "Pre-push hook installed at: $hookFile"
Write-Host ""
Write-Host "  On every 'git push':"               -ForegroundColor DarkGray
Write-Host "    tests\Run-AllTests.ps1"            -ForegroundColor White
Write-Host "    Exit 0 -> push proceeds"           -ForegroundColor DarkGray
Write-Host "    Exit non-zero -> push blocked"     -ForegroundColor DarkGray
Write-Host ""
Write-Host "  To bypass: git push --no-verify"     -ForegroundColor DarkGray
Write-Host ""
Write-OK "Hook installation complete."
