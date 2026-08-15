#Requires -Version 5.1
<#
.SYNOPSIS
    Stamp SPDX licence headers onto deployed PowerShell sources (6.4-D3).

.DESCRIPTION
    Adds a two-line SPDX header to every deployed .ps1 and .psm1 under SCRIPTS\.
    Idempotent: a file that already carries the identifier is left untouched, so
    the script can be run repeatedly and after every new file is added.

    WHY SPDX RATHER THAN THE FULL APACHE BOILERPLATE

    The Apache appendix suggests an eleven-line notice per file. SPDX carries
    the same legal information in a form that licence-scanning tools read
    directly -- and a scanner is what an enterprise procurement review actually
    runs against a codebase. The full text remains in LICENSE, which is where it
    has legal effect; repeating it 29 times adds 300 lines that no human reads
    and no tool needs.

    ENCODING CONSTRAINT

    SCRIPTS\**\*.ps1 and *.psm1 are ASCII-only with no BOM, enforced by audits
    A1 and A2. This script writes with UTF8Encoding($false) and uses only ASCII
    characters, so stamping cannot break either audit. It verifies that after
    writing, and restores the original file if it somehow did.

    PLACEMENT

    The header goes immediately after a leading #Requires statement where one
    exists, otherwise at the top. #Requires is left first deliberately: it is
    the established shape of every file in this tree and the suite is green
    with it there. Correctness beats tidiness on a 29-file sweep.

.PARAMETER Path
    Root to scan. Defaults to the SCRIPTS directory beside this script's parent.

.PARAMETER Year
    Copyright year. Defaults to the current year.

.PARAMETER Holder
    Copyright holder.

.PARAMETER WhatIf
    Report what would change without writing.

.EXAMPLE
    .\tools\Apply-LicenseHeaders.ps1 -WhatIf
    .\tools\Apply-LicenseHeaders.ps1

.NOTES
    FieldOps Pro - Phase 6, Stream 6.4 - D3
    PS 5.1. ASCII source. Idempotent.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$Path   = '',
    [int]$Year      = 0,
    [string]$Holder = 'Ousman Dorley'
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

$SPDX_TAG = 'SPDX-License-Identifier: Apache-2.0'

if ($Year -le 0) { $Year = (Get-Date).Year }

if ($Path -eq '') {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $Path = Join-Path $repoRoot 'SCRIPTS'
}

if (-not (Test-Path -LiteralPath $Path)) {
    throw "Apply-LicenseHeaders: path not found: $Path"
}

function Write-Info { param([string]$M) Write-Host "  $M" -ForegroundColor DarkGray }
function Write-Act  { param([string]$M) Write-Host "  $M" -ForegroundColor Cyan }
function Write-Skip { param([string]$M) Write-Host "  $M" -ForegroundColor DarkGray }
function Write-Bad  { param([string]$M) Write-Host "  $M" -ForegroundColor Red }

Write-Host ''
Write-Host 'FieldOps Pro -- licence header stamp (6.4-D3)' -ForegroundColor White
Write-Host ("  Root   : {0}" -f $Path)
Write-Host ("  Header : {0} / Copyright {1} {2}" -f $SPDX_TAG, $Year, $Holder)
Write-Host ''

# File selection, deliberately explicit.
#
# NOT -Include: PowerShell silently ignores -Include when it is combined with
# -LiteralPath, so `-LiteralPath X -Recurse -Include *.ps1` returns EVERY file
# under X. A dry run caught that returning 55 files instead of 29, among them
# .bak snapshots, a .psd1, a .json, and anssi-diagnostic.html -- which is
# UTF-8 WITH BOM by design and carries French accented text. Stamping that
# would have broken the template encoding contract.
#
# Filtering on $_.Extension is exact: 'Invoke-NetRepair.ps1.jsonpatch.bak' has
# extension .bak, not .ps1, so it is excluded on the property rather than on a
# pattern that has to be right about every naming variant in the tree.
#
# Exclusions match the D14 repository audit: the Archive tree is retired code
# and Patch-/Debug-/Apply- utilities are dev tooling, neither deployed.
$files = @(
    Get-ChildItem -LiteralPath $Path -Recurse -File |
        Where-Object { $_.Extension -eq '.ps1' -or $_.Extension -eq '.psm1' } |
        Where-Object {
            $_.FullName -notmatch '\\Archive\\' -and
            $_.Name -notmatch '^(Patch|Debug|Apply)-' -and
            $_.Name -notmatch '\.bak$'
        }
)

if ($files.Count -eq 0) {
    throw "Apply-LicenseHeaders: no deployed scripts found under $Path. Refusing to report success on an empty set."
}

$stamped = 0
$skipped = 0
$failed  = @()

foreach ($file in $files) {
    $raw = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop

    if ($raw -match [regex]::Escape($SPDX_TAG)) {
        $skipped++
        Write-Skip ("skip   {0} (already stamped)" -f $file.Name)
        continue
    }

    # Preserve the file's existing line ending style rather than imposing one.
    $eol = "`r`n"
    if ($raw -notmatch "`r`n") { $eol = "`n" }

    $header = @(
        "# $SPDX_TAG",
        "# Copyright $Year $Holder. See LICENSE at the repository root."
    ) -join $eol

    $lines = $raw -split "`r?`n"

    # Insert after a leading #Requires if present, else at the very top.
    $insertAt = 0
    for ($i = 0; $i -lt [Math]::Min(5, $lines.Count); $i++) {
        if ($lines[$i] -match '^\s*#Requires\b') { $insertAt = $i + 1 }
    }

    $before = if ($insertAt -gt 0) { $lines[0..($insertAt - 1)] } else { @() }
    $after  = $lines[$insertAt..($lines.Count - 1)]
    $new    = (@($before) + @($header) + @($after)) -join $eol

    if ($PSCmdlet.ShouldProcess($file.FullName, 'stamp SPDX header')) {
        $backup = $raw
        [System.IO.File]::WriteAllText($file.FullName, $new, (New-Object System.Text.UTF8Encoding($false)))

        # Verify the write did not violate A1 (ASCII) or A2 (no BOM). A licence
        # sweep that quietly breaks the encoding contract across 29 files would
        # be discovered as 29 audit failures with no obvious cause.
        $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
        $bad   = $false
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $bad = $true }
        foreach ($b in $bytes) { if ($b -gt 127) { $bad = $true; break } }

        if ($bad) {
            [System.IO.File]::WriteAllText($file.FullName, $backup, (New-Object System.Text.UTF8Encoding($false)))
            $failed += $file.FullName
            Write-Bad ("REVERTED {0} (encoding check failed)" -f $file.Name)
            continue
        }

        $stamped++
        Write-Act ("stamp  {0}" -f $file.Name)
    } else {
        $stamped++
        Write-Act ("would stamp {0}" -f $file.Name)
    }
}

Write-Host ''
Write-Host ("  Files considered : {0}" -f $files.Count)
Write-Host ("  Stamped          : {0}" -f $stamped) -ForegroundColor Green
Write-Host ("  Already stamped  : {0}" -f $skipped)

if ($failed.Count -gt 0) {
    Write-Host ("  REVERTED         : {0}" -f $failed.Count) -ForegroundColor Red
    $failed | ForEach-Object { Write-Bad "    $_" }
    Write-Host ''
    throw "Apply-LicenseHeaders: $($failed.Count) file(s) failed the encoding check and were restored."
}

Write-Host ''
