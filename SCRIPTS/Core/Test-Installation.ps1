#Requires -Version 5.1
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Ousman Dorley. See LICENSE at the repository root.
<#
.SYNOPSIS
    Verify a FieldOps Pro deployment before trusting it in the field (6.4-D17).

.DESCRIPTION
    Checks that this stick is complete and usable: PowerShell version, directory
    layout, required scripts, configuration, execution policy, blocked files and
    file encoding.

    WHY THIS EXISTS

    A USB toolkit gets copied. Technician to technician, folder to folder, and
    through tools that helpfully rewrite text file encodings on the way. A copy
    that lost its CONFIG directory, or had its French locale bundle re-encoded,
    or arrived with every file marked blocked by Windows, looks identical to a
    good one until it fails in front of a customer.

    This turns "it looks fine" into an answer. It changes nothing and needs no
    Administrator rights.

    SEVERITY

      FAIL  the deployment is broken; fix before use
      WARN  usable, but something will surprise you
      OK    verified

    Exit code is 1 if any FAIL, otherwise 0, so it can gate a deployment script.

.PARAMETER Root
    Deployment root. Defaults to two levels above this script.

.PARAMETER Quiet
    Suppress per-check output; print the summary only.

.EXAMPLE
    E:\SCRIPTS\Core\Test-Installation.ps1

.NOTES
    FieldOps Pro - Phase 6, Stream 6.4 - D17
    PS 5.1. ASCII source. Read-only. No elevation required.
#>

[CmdletBinding()]
param(
    [string]$Root = '',
    [switch]$Quiet
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Continue'

if ($Root -eq '') {
    $Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}

$script:Results = @()

function Add-Check {
    param(
        [Parameter(Mandatory)][string]$Area,
        [Parameter(Mandatory)][ValidateSet('OK','WARN','FAIL')][string]$Status,
        [Parameter(Mandatory)][string]$Message,
        [string]$Fix = ''
    )
    $script:Results += [PSCustomObject]@{
        Area = $Area; Status = $Status; Message = $Message; Fix = $Fix
    }
    if (-not $Quiet) {
        $colour = switch ($Status) { 'OK' {'Green'} 'WARN' {'Yellow'} 'FAIL' {'Red'} }
        Write-Host ("  [{0,-4}] {1,-22} {2}" -f $Status, $Area, $Message) -ForegroundColor $colour
        if ($Fix -and $Status -ne 'OK') {
            Write-Host ("         -> {0}" -f $Fix) -ForegroundColor DarkGray
        }
    }
}

if (-not $Quiet) {
    Write-Host ''
    Write-Host ('=' * 74) -ForegroundColor Cyan
    Write-Host '  FIELDOPS PRO -- INSTALLATION SELF-TEST' -ForegroundColor White
    Write-Host ('=' * 74) -ForegroundColor Cyan
    Write-Host ("  Root : {0}" -f $Root)
    Write-Host ("  Host : {0}" -f $env:COMPUTERNAME)
    Write-Host ("  Date : {0}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
    Write-Host ''
}

# --------------------------------------------------------------------------
# 1. Runtime
# --------------------------------------------------------------------------
$psv = $PSVersionTable.PSVersion
if ($psv.Major -ge 5) {
    Add-Check 'PowerShell' 'OK' ("version {0}" -f $psv)
} else {
    Add-Check 'PowerShell' 'FAIL' ("version {0}; 5.1 or later required" -f $psv) `
              'Windows 10 and 11 ship 5.1. This machine predates that or has it disabled.'
}

# 64-bit matters: some probes query providers absent from the 32-bit host.
if ([Environment]::Is64BitProcess) {
    Add-Check 'Process architecture' 'OK' '64-bit'
} else {
    Add-Check 'Process architecture' 'WARN' '32-bit PowerShell on a 64-bit OS' `
              'Some hardware probes return nothing here. Use the 64-bit console.'
}

$policy = Get-ExecutionPolicy
if ($policy -in @('Restricted','AllSigned')) {
    Add-Check 'Execution policy' 'WARN' ("{0} blocks unsigned scripts" -f $policy) `
              'Launch with: powershell.exe -ExecutionPolicy Bypass -File <script>'
} else {
    Add-Check 'Execution policy' 'OK' ("{0}" -f $policy)
}

$isAdmin = $false
try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $isAdmin = ([Security.Principal.WindowsPrincipal]$id).IsInRole(
                [Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { $isAdmin = $false }

if ($isAdmin) {
    Add-Check 'Elevation' 'OK' 'running as Administrator'
} else {
    # Not a failure: the self-test itself needs nothing. But a technician who
    # runs the diagnostics unelevated gets empty reports and no explanation.
    Add-Check 'Elevation' 'WARN' 'not elevated' `
              'Diagnostics will return incomplete data. Re-launch as Administrator before use.'
}

if (Test-Path 'X:\Windows\System32\wpeinit.exe') {
    Add-Check 'Environment' 'OK' 'WinPE detected; probes will degrade as designed'
}

# --------------------------------------------------------------------------
# 2. Layout
# --------------------------------------------------------------------------
# Three tiers, because a warning that fires on a healthy deployment teaches the
# reader to ignore warnings -- and then they miss a real one.
#
#   required   absent means the deployment is broken
#   featured   absent means a capability is missing; worth a WARN
#   payload    absent is normal; carrying driver bundles or ISOs is a choice
$required = @('SCRIPTS','CONFIG','DOCS')
$featured = @('TOOLS','PLAYBOOKS')
$payload  = @('DRIVERS','ISOs')
$onDemand = @('REPORTS','LOGS')

foreach ($d in $required) {
    if (Test-Path -LiteralPath (Join-Path $Root $d)) {
        Add-Check 'Layout' 'OK' ("{0}\ present" -f $d)
    } else {
        Add-Check 'Layout' 'FAIL' ("{0}\ missing" -f $d) `
                  'Deployment is incomplete. Re-extract from the release zip.'
    }
}

foreach ($d in $featured) {
    if (-not (Test-Path -LiteralPath (Join-Path $Root $d))) {
        $why = if ($d -eq 'TOOLS') { 'The portable tools menu will be empty.' }
               else                { 'Workflow and remediation playbooks will be unavailable.' }
        Add-Check 'Layout' 'WARN' ("{0}\ absent" -f $d) $why
    }
}

foreach ($d in $payload) {
    if (-not (Test-Path -LiteralPath (Join-Path $Root $d))) {
        Add-Check 'Layout' 'OK' ("{0}\ absent; optional payload, not required" -f $d)
    }
}

foreach ($d in $onDemand) {
    if (-not (Test-Path -LiteralPath (Join-Path $Root $d))) {
        Add-Check 'Layout' 'OK' ("{0}\ absent; created on first run" -f $d)
    }
}

# --------------------------------------------------------------------------
# 3. Core scripts
# --------------------------------------------------------------------------
$core = @(
    'SCRIPTS\FieldOps-Launcher.ps1',
    'SCRIPTS\Core\Invoke-ComplianceDiff.ps1',
    'SCRIPTS\Compliance\Build-ANSSIData.ps1',
    'SCRIPTS\Core\Utils.psm1',
    'SCRIPTS\Core\Logger.psm1',
    'SCRIPTS\Core\FieldOps-Locale.psm1',
    'SCRIPTS\Templates\anssi-diagnostic.html'
)

$missingCore = @()
foreach ($rel in $core) {
    if (-not (Test-Path -LiteralPath (Join-Path $Root $rel))) { $missingCore += $rel }
}
if ($missingCore.Count -eq 0) {
    Add-Check 'Core scripts' 'OK' ("all {0} present" -f $core.Count)
} else {
    Add-Check 'Core scripts' 'FAIL' ("{0} missing" -f $missingCore.Count) `
              ("Missing: " + ($missingCore -join ', '))
}

# --------------------------------------------------------------------------
# 4. Locale bundles
# --------------------------------------------------------------------------
# The bundles are UTF-8 WITH BOM by design and hold literal accented French. A
# copy tool that stripped the BOM or transcoded the file produces a report full
# of mojibake, which is the single most visible way a bad copy shows itself to
# a customer.
foreach ($lang in @('fr','en')) {
    $p = Join-Path $Root ("CONFIG\lang\{0}.json" -f $lang)
    if (-not (Test-Path -LiteralPath $p)) {
        Add-Check 'Locale bundle' 'FAIL' ("{0}.json missing" -f $lang) `
                  'Reports cannot render. Re-extract from the release zip.'
        continue
    }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($p)
        $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        $null = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json

        if ($lang -eq 'fr' -and -not $hasBom) {
            Add-Check 'Locale bundle' 'WARN' 'fr.json has lost its UTF-8 BOM' `
                      'Accented characters may render incorrectly. Re-extract from the release zip.'
        } else {
            Add-Check 'Locale bundle' 'OK' ("{0}.json parses" -f $lang)
        }
    } catch {
        Add-Check 'Locale bundle' 'FAIL' ("{0}.json does not parse" -f $lang) `
                  'The file was corrupted in transit. Re-extract from the release zip.'
    }
}

# --------------------------------------------------------------------------
# 5. Configuration
# --------------------------------------------------------------------------
$cfgCandidates = @('technician.json','FieldOps.config.json','fieldops.json','config.json')
$cfgFound = $null
foreach ($name in $cfgCandidates) {
    $p = Join-Path $Root ("CONFIG\{0}" -f $name)
    if (Test-Path -LiteralPath $p) { $cfgFound = $p; break }
}

if (-not $cfgFound) {
    Add-Check 'Configuration' 'WARN' 'no technician.json found' `
              'Reports will use defaults and the current Windows username. See DOCS/INSTALL.md.'
} else {
    try {
        $cfg = Get-Content -LiteralPath $cfgFound -Raw -Encoding UTF8 | ConvertFrom-Json
        Add-Check 'Configuration' 'OK' ("{0} parses" -f (Split-Path $cfgFound -Leaf))

        $names = @($cfg.PSObject.Properties.Name)
        $hasKey = $false
        foreach ($a in @('AnthropicApiKey','AnthropicKey','ApiKey','ClaudeApiKey')) {
            if ($names -contains $a -and $cfg.$a) { $hasKey = $true; break }
        }
        if ($hasKey -or $env:ANTHROPIC_API_KEY) {
            # Deliberately does not print, log or validate the key itself.
            Add-Check 'AI configuration' 'OK' 'API key present; AI features available'
        } else {
            Add-Check 'AI configuration' 'OK' 'no API key; AI features off, local paths used'
        }
    } catch {
        Add-Check 'Configuration' 'FAIL' ("{0} does not parse as JSON" -f (Split-Path $cfgFound -Leaf)) `
                  'Fix the syntax, or delete the file to fall back to defaults.'
    }
}

# --------------------------------------------------------------------------
# 6. Blocked files
# --------------------------------------------------------------------------
# Windows marks files that came from the internet, and the mark survives a copy
# to USB. A stick full of blocked scripts fails with an error that names the
# execution policy, sending the technician down the wrong path entirely.
$blocked = 0
try {
    $sample = @(Get-ChildItem -LiteralPath (Join-Path $Root 'SCRIPTS') -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -eq '.ps1' -or $_.Extension -eq '.psm1' })
    foreach ($f in $sample) {
        if (Get-Item -LiteralPath $f.FullName -Stream 'Zone.Identifier' -ErrorAction SilentlyContinue) {
            $blocked++
        }
    }
} catch { $blocked = -1 }

if ($blocked -gt 0) {
    Add-Check 'File blocking' 'FAIL' ("{0} script(s) marked blocked by Windows" -f $blocked) `
              ("Run: Get-ChildItem -Path '{0}\SCRIPTS' -Recurse | Unblock-File" -f $Root)
} elseif ($blocked -eq 0) {
    Add-Check 'File blocking' 'OK' 'no blocked scripts'
}

# --------------------------------------------------------------------------
# 7. Licensing
# --------------------------------------------------------------------------
foreach ($f in @('LICENSE','NOTICE')) {
    if (Test-Path -LiteralPath (Join-Path $Root $f)) {
        Add-Check 'Licensing' 'OK' ("{0} present" -f $f)
    } else {
        Add-Check 'Licensing' 'WARN' ("{0} missing" -f $f) `
                  'Redistribution requires it. Re-extract from the release zip.'
    }
}

# --------------------------------------------------------------------------
# 8. Writable output
# --------------------------------------------------------------------------
# A read-only stick produces reports nowhere and says little about why.
$probe = Join-Path $Root ('.fieldops-write-probe-' + [Guid]::NewGuid().ToString('N') + '.tmp')
try {
    Set-Content -LiteralPath $probe -Value 'probe' -ErrorAction Stop
    Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
    Add-Check 'Writable media' 'OK' 'deployment root is writable'
} catch {
    Add-Check 'Writable media' 'WARN' 'deployment root is not writable' `
              'Reports and logs cannot be written here. Use -OutputRoot to redirect them.'
}

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
$fails = @($script:Results | Where-Object Status -eq 'FAIL')
$warns = @($script:Results | Where-Object Status -eq 'WARN')
$oks   = @($script:Results | Where-Object Status -eq 'OK')

Write-Host ''
Write-Host ('-' * 74) -ForegroundColor DarkGray
Write-Host ("  OK: {0}    WARN: {1}    FAIL: {2}" -f $oks.Count, $warns.Count, $fails.Count)
Write-Host ('-' * 74) -ForegroundColor DarkGray

if ($fails.Count -gt 0) {
    Write-Host ''
    Write-Host '  NOT READY FOR USE' -ForegroundColor Red
    Write-Host '  Resolve the FAIL items above before running against a customer machine.' -ForegroundColor Red
    Write-Host ''
    exit 1
}

if ($warns.Count -gt 0) {
    Write-Host ''
    Write-Host '  USABLE, WITH CAVEATS' -ForegroundColor Yellow
    Write-Host '  The warnings above will change what you get. Read them before proceeding.' -ForegroundColor Yellow
    Write-Host ''
    exit 0
}

Write-Host ''
Write-Host '  READY' -ForegroundColor Green
Write-Host ''
exit 0
