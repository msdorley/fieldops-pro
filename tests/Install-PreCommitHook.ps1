#Requires -Version 5.1
<#
.SYNOPSIS
    Installs the FieldOps Pro pre-commit hook into the local git repository.

.DESCRIPTION
    Writes .git\hooks\pre-commit so that every `git commit` automatically
    runs tests\Run-FastTests.ps1 -CI before the commit is recorded.

    If any Fast-tagged test fails, the commit is blocked and the developer
    sees the failure output.  The hook can be bypassed with:
        git commit --no-verify

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
    FieldOps Pro - Chapter 6.6 Continuous Validation - D8
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
    Write-Host "[Install-PreCommitHook] $Text" -ForegroundColor Cyan
}

function Write-OK {
    param([string]$Text)
    Write-Host "[Install-PreCommitHook] OK: $Text" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Text)
    Write-Warning "[Install-PreCommitHook] $Text"
}

# ---------------------------------------------------------------------------
# Resolve repo root
# ---------------------------------------------------------------------------
if ($RepoRoot -eq '') {
    # Script lives at tests\Install-PreCommitHook.ps1
    # Parent = repo root
    $RepoRoot = Split-Path $PSScriptRoot -Parent
}

$gitDir   = Join-Path $RepoRoot '.git'
$hooksDir = Join-Path $gitDir 'hooks'
$hookFile = Join-Path $hooksDir 'pre-commit'

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
    Write-Step "Existing pre-commit hook found:"
    Write-Host ""
    Get-Content $hookFile | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    Write-Host ""
    $answer = Read-Host "[Install-PreCommitHook] Overwrite? (y/N)"
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
# ---------------------------------------------------------------------------
$hookContent = @'
#!/bin/sh
# FieldOps Pro pre-commit hook
# Installed by tests/Install-PreCommitHook.ps1 (D8)
# Bypass with: git commit --no-verify
#
# Runs tests/Run-FastTests.ps1 -CI
# Exit 0 = all Fast tests passed, commit proceeds
# Exit 1 = test failure, commit blocked
exec powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Run-FastTests.ps1 -CI
'@

# ---------------------------------------------------------------------------
# Write the hook file
# Must use LF line endings (POSIX sh requirement)
# ---------------------------------------------------------------------------
$hookContentLF = $hookContent -replace "`r`n", "`n" -replace "`r", "`n"

try {
    [System.IO.File]::WriteAllText(
        $hookFile,
        $hookContentLF,
        [System.Text.Encoding]::UTF8
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
if ($written -notmatch 'Run-FastTests') {
    throw "Hook file content verification failed: Run-FastTests not found in written file."
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-OK "Pre-commit hook installed at: $hookFile"
Write-Host ""
Write-Host "  On every 'git commit':"            -ForegroundColor DarkGray
Write-Host "    tests\Run-FastTests.ps1 -CI"     -ForegroundColor White
Write-Host "    Exit 0 -> commit proceeds"        -ForegroundColor DarkGray
Write-Host "    Exit 1 -> commit blocked"         -ForegroundColor DarkGray
Write-Host ""
Write-Host "  To bypass: git commit --no-verify"  -ForegroundColor DarkGray
Write-Host ""
Write-OK "Hook installation complete."
