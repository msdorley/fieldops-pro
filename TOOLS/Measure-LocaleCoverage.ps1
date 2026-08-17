# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Ousman Dorley. See LICENSE at the repository root.
<#
================================================================================
Measure-LocaleCoverage.ps1 -- FieldOps Pro Phase 7, Stream 7.1
================================================================================
Measures how much of the operator-facing interface is actually localised, in
both directions.

WHY THIS EXISTS

    The locale suite proves fr.json and en.json agree with each other, and that
    the HTML report renders in both languages with no unresolved tokens. Both
    are true. Neither says anything about whether a bundle key is ever read, or
    whether what a technician sees on screen came from the bundle at all.

    Running v0.6.0 from a USB stick showed the consequence: the launcher menu
    is French, and the compliance-diff engine it launches is English. The
    bundle carries 90 fully translated complianceDiff keys with zero readers.
    The translation was done and never wired.

    Parity between two files nobody reads is the same class of defect as a
    test that passes over an empty set -- a check agreeing with itself.

TWO MEASUREMENTS, DELIBERATELY BOTH DIRECTIONS

    ORPHANED KEYS   translated, present in both bundles, referenced by nothing.
                    Work that was paid for and never delivered.

    UNROUTED OUTPUT console writes carrying literal user-facing text instead of
                    a bundle lookup. What the technician actually sees.

    Fixing only one leaves the other free to drift.

NOT A TEST

    This reports; it does not assert. A failing test here would block every
    commit through the pre-commit hook before the fix exists. The audits come
    with the fixes, per stream, once the scope is known.

USAGE
    .\TOOLS\Measure-LocaleCoverage.ps1
    .\TOOLS\Measure-LocaleCoverage.ps1 -Detail
================================================================================
#>

[CmdletBinding()]
param(
    # List every orphaned key and every unrouted line, not just the counts.
    [switch]$Detail
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot

# ------------------------------------------------------------------ the bundle

$bundlePath = Join-Path $RepoRoot 'CONFIG\lang\fr.json'
if (-not (Test-Path -LiteralPath $bundlePath)) { throw "Bundle not found: $bundlePath" }

$bundle = Get-Content -LiteralPath $bundlePath -Raw -Encoding UTF8 | ConvertFrom-Json

function Get-LeafKey {
    param($Node, [string]$Prefix = '')
    $out = @()
    foreach ($p in $Node.PSObject.Properties) {
        $name = if ($Prefix) { "$Prefix.$($p.Name)" } else { $p.Name }

        # A rich-text value ({parts, separator}) is ONE key, not a container.
        # The 6.1-R1 flattener defect was exactly this distinction, and getting
        # it wrong here would inflate the orphan count with phantom sub-keys.
        $isRich = $false
        if ($p.Value -is [PSCustomObject]) {
            $n = @($p.Value.PSObject.Properties.Name)
            $isRich = ($n -contains 'parts') -and ($n -contains 'separator')
        }

        if (($p.Value -is [PSCustomObject]) -and -not $isRich) {
            $out += Get-LeafKey -Node $p.Value -Prefix $name
        } else {
            $out += $name
        }
    }
    return $out
}

$allKeys = @(Get-LeafKey -Node $bundle | Where-Object { $_ -notlike '_meta*' })

# ---------------------------------------------------------------- the readers

# Deployed set only. Archive/ and one-off Patch-/Debug-/Apply- utilities are
# dev tooling and never ship, per the A5 audit's documented scope.
$deployed = @(
    Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'SCRIPTS') -Recurse -File |
        Where-Object {
            $_.Extension -in @('.ps1', '.psm1') -and
            $_.FullName -notmatch '\\Archive\\' -and
            $_.Name -notmatch '^(Patch|Debug|Apply)-' -and
            $_.Name -notlike '*.bak'
        }
)

$template = Join-Path $RepoRoot 'SCRIPTS\Templates\anssi-diagnostic.html'
$sources = @($deployed.FullName)
if (Test-Path -LiteralPath $template) { $sources += $template }

$referenced = New-Object System.Collections.Generic.HashSet[string]
foreach ($f in $sources) {
    $text = Get-Content -LiteralPath $f -Raw
    # Bundle keys appear as 'section.key' in code and {{t:section.key}} in the
    # template. One pattern catches both.
    foreach ($m in [regex]::Matches($text, "[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)+")) {
        [void]$referenced.Add($m.Value)
    }
}

$orphans = @($allKeys | Where-Object { -not $referenced.Contains($_) })

# --------------------------------------------------------- unrouted output

# A console write carrying a quoted string of real words, with no locale call
# on the line. Deliberately conservative: it counts lines that are almost
# certainly user-facing prose, not every string literal.
$unrouted = @()
foreach ($f in $deployed) {
    $n = 0
    $lines = Get-Content -LiteralPath $f.FullName
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -notmatch 'Write-Host|Write-Step|Write-Warning') { continue }
        if ($line -match "Get-LocaleString|\(L\s+'")                { continue }
        # Two or more consecutive words of four-plus letters inside quotes.
        if ($line -match "['`"][^'`"]*\b[A-Za-z]{4,}\s+[A-Za-z]{4,}\b") {
            $n++
            if ($Detail) {
                $unrouted += [PSCustomObject]@{
                    File = $f.Name; Line = $i + 1; Text = $line.Trim()
                }
            }
        }
    }
    if (-not $Detail -and $n -gt 0) {
        $unrouted += [PSCustomObject]@{ File = $f.Name; Line = $n; Text = '' }
    }
}

# --------------------------------------------------------------------- report

Write-Host ''
Write-Host '=========================================================================='
Write-Host '  FIELDOPS PRO -- LOCALE COVERAGE'
Write-Host '=========================================================================='
Write-Host ("  Bundle keys           : {0}" -f $allKeys.Count)
Write-Host ("  Referenced by code    : {0}" -f ($allKeys.Count - $orphans.Count))
Write-Host ("  ORPHANED (no readers) : {0}" -f $orphans.Count)
Write-Host ''

$bySection = $orphans | Group-Object { ($_ -split '\.')[0] } | Sort-Object Count -Descending
if ($bySection) {
    Write-Host '  Orphaned keys by section -- translated, shipped, never displayed:'
    foreach ($g in $bySection) {
        Write-Host ("    {0,-18} {1,4}" -f $g.Name, $g.Count)
    }
    Write-Host ''
}

Write-Host '  Unrouted console output -- literal text a technician sees:'
if ($Detail) {
    foreach ($g in ($unrouted | Group-Object File | Sort-Object Count -Descending)) {
        Write-Host ("    {0,-40} {1,4}" -f $g.Name, $g.Count)
    }
} else {
    foreach ($u in ($unrouted | Sort-Object Line -Descending)) {
        Write-Host ("    {0,-40} {1,4}" -f $u.File, $u.Line)
    }
}

$totalUnrouted = if ($Detail) { $unrouted.Count } else { ($unrouted | Measure-Object Line -Sum).Sum }

Write-Host ''
Write-Host '--------------------------------------------------------------------------'
Write-Host ("  {0} orphaned keys    {1} unrouted lines" -f $orphans.Count, $totalUnrouted)
Write-Host '--------------------------------------------------------------------------'
Write-Host '  Orphans are wiring, not translation: the French already exists.'
Write-Host '  Run with -Detail for file-by-file lines.'
Write-Host ''

if ($Detail) {
    Write-Host '  ---- ORPHANED KEYS ----'
    $orphans | Sort-Object | ForEach-Object { Write-Host "    $_" }
    Write-Host ''
    Write-Host '  ---- UNROUTED LINES ----'
    $unrouted | ForEach-Object { Write-Host ("    {0}:{1}  {2}" -f $_.File, $_.Line, $_.Text) }
}
