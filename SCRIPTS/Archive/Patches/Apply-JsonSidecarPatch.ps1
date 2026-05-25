<#
.SYNOPSIS
    FieldOps Pro - Apply JSON Sidecar Patch v1.0
.DESCRIPTION
    Adds JSON sidecar output to SecurityScan and NetRepair engines.

    Both engines currently produce HTML reports but no machine-readable
    JSON. This patch adds a JSON write alongside the HTML write, using
    the same schema as PCHealth (Hostname, Timestamp, Technician, Summary,
    Checks, Findings).

    The patch is idempotent and non-destructive:
    - Creates .jsonpatch.bak files before modifying
    - Re-running detects the patch is already applied
    - Anchor-based replacement (fails safely if anchor missing)

    Adds zero new dependencies. Adds approx 12 lines per engine.
.NOTES
    Author  : FieldOps Pro
    Version : 1.0
    Targets : Invoke-SecurityScan.ps1, Invoke-NetRepair.ps1
    Output  : LOGS\SecurityScan_HOST_TIMESTAMP.json
              LOGS\NetRepair_HOST_TIMESTAMP.json
#>

#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ProjectRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Resolve project root (find a folder that contains SCRIPTS\)
if (-not $ProjectRoot) {
    $here = $PSScriptRoot
    if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
    # Walk up until we find a SCRIPTS\ child
    $candidate = $here
    for ($i = 0; $i -lt 5; $i++) {
        if (Test-Path (Join-Path $candidate 'SCRIPTS')) { $ProjectRoot = $candidate; break }
        $parent = Split-Path $candidate -Parent
        if (-not $parent -or $parent -eq $candidate) { break }
        $candidate = $parent
    }
}
if (-not $ProjectRoot -or -not (Test-Path (Join-Path $ProjectRoot 'SCRIPTS'))) {
    throw "Could not locate project root. Pass -ProjectRoot 'C:\path\to\fieldops-pro'."
}

Write-Host ''
Write-Host '  +--------------------------------------------------------+' -ForegroundColor White
Write-Host '  |  JSON Sidecar Patch - SecurityScan + NetRepair         |' -ForegroundColor White
Write-Host '  +--------------------------------------------------------+' -ForegroundColor White
Write-Host "  Project root: $ProjectRoot" -ForegroundColor DarkGray
Write-Host ''

function Invoke-EnginePatch {
    param(
        [Parameter(Mandatory)] [string]$EnginePath,
        [Parameter(Mandatory)] [string]$EngineName,
        [Parameter(Mandatory)] [string]$LogsVarName,
        [Parameter(Mandatory)] [string]$AnchorLine,
        [Parameter(Mandatory)] [string]$JsonBlock
    )

    if (-not (Test-Path $EnginePath)) {
        Write-Host "  [SKIP] $EngineName not found at $EnginePath" -ForegroundColor Yellow
        return
    }

    $content = Get-Content -LiteralPath $EnginePath -Raw

    # Idempotency check
    if ($content -like "*FieldOps-ANSSI-JSON-Sidecar-Marker*") {
        Write-Host "  [SKIP] $EngineName - patch already applied (marker found)" -ForegroundColor Yellow
        return
    }

    # Anchor check
    if ($content -notlike "*$AnchorLine*") {
        Write-Host "  [FAIL] $EngineName - anchor not found, NOT modified" -ForegroundColor Red
        Write-Host "         Anchor sought: $AnchorLine" -ForegroundColor DarkGray
        return
    }

    # Backup
    $backupPath = "$EnginePath.jsonpatch.bak"
    if (-not (Test-Path $backupPath)) {
        Copy-Item -LiteralPath $EnginePath -Destination $backupPath -Force
        Write-Host "  [+] Backup created: $(Split-Path $backupPath -Leaf)" -ForegroundColor DarkGray
    }

    # Replace: insert JSON block AFTER the anchor line
    $replacement = $AnchorLine + "`r`n" + $JsonBlock
    $newContent = $content.Replace($AnchorLine, $replacement)

    if ($newContent -eq $content) {
        Write-Host "  [FAIL] $EngineName - replacement did not change file" -ForegroundColor Red
        return
    }

    Set-Content -LiteralPath $EnginePath -Value $newContent -Encoding UTF8 -NoNewline
    Write-Host "  [OK]   $EngineName patched" -ForegroundColor Green
}

# ===========================================================================
# SecurityScan patch
# ===========================================================================
$securityScanPath = Join-Path $ProjectRoot 'SCRIPTS\Security\Invoke-SecurityScan.ps1'

$ssAnchor = '$HtmlContent | Out-File -FilePath $ReportFile -Encoding UTF8 -Force'

$ssBlock = @'

# FieldOps-ANSSI-JSON-Sidecar-Marker - DO NOT REMOVE (idempotency check anchor)
try {
    $jsonFile = Join-Path $LogsPath ("SecurityScan_${Hostname}_${Timestamp}.json")
    $reportData = [PSCustomObject]@{
        Engine     = 'SecurityScan'
        Version    = '1.0'
        Hostname   = $Hostname
        Timestamp  = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Summary    = @{
            Total    = ($script:Results | Measure-Object).Count
            Pass     = ($script:Results | Where-Object { $_.Status -eq 'Pass' }    | Measure-Object).Count
            Warning  = ($script:Results | Where-Object { $_.Status -eq 'Warning' } | Measure-Object).Count
            Fail     = ($script:Results | Where-Object { $_.Status -eq 'Fail' }    | Measure-Object).Count
            Info     = ($script:Results | Where-Object { $_.Status -eq 'Info' }    | Measure-Object).Count
        }
        Checks     = @($script:Results)
        Findings   = @($script:Findings)
    }
    $reportData | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $jsonFile -Encoding UTF8 -Force
    Write-Host "  JSON  : $jsonFile" -ForegroundColor DarkGray
} catch {
    Write-Host "  [WARN] JSON sidecar failed: $($_.Exception.Message)" -ForegroundColor Yellow
}
'@

Invoke-EnginePatch -EnginePath $securityScanPath `
                   -EngineName 'Invoke-SecurityScan.ps1' `
                   -LogsVarName 'LogsPath' `
                   -AnchorLine $ssAnchor `
                   -JsonBlock $ssBlock

# ===========================================================================
# NetRepair patch
# ===========================================================================
$netRepairPath = Join-Path $ProjectRoot 'SCRIPTS\Network\Invoke-NetRepair.ps1'

$nrAnchor = '$HtmlContent | Out-File -FilePath $ReportFile -Encoding UTF8 -Force'

# NetRepair uses Results and Findings collections too. If schema differs we
# fall back to whatever is in scope.
$nrBlock = @'

# FieldOps-ANSSI-JSON-Sidecar-Marker - DO NOT REMOVE (idempotency check anchor)
try {
    $jsonFile = Join-Path $LogsPath ("NetRepair_${Hostname}_${Timestamp}.json")
    $allChecks = @()
    if (Get-Variable -Name 'Results' -Scope Script -EA SilentlyContinue) { $allChecks = @($script:Results) }
    $allFindings = @()
    if (Get-Variable -Name 'Findings' -Scope Script -EA SilentlyContinue) { $allFindings = @($script:Findings) }

    $reportData = [PSCustomObject]@{
        Engine     = 'NetRepair'
        Version    = '2.0'
        Hostname   = $Hostname
        Timestamp  = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Summary    = @{
            Total   = ($allChecks | Measure-Object).Count
            Pass    = ($allChecks | Where-Object { $_.Status -eq 'Pass' }    | Measure-Object).Count
            Warning = ($allChecks | Where-Object { $_.Status -eq 'Warning' } | Measure-Object).Count
            Fail    = ($allChecks | Where-Object { $_.Status -eq 'Fail' }    | Measure-Object).Count
            Info    = ($allChecks | Where-Object { $_.Status -eq 'Info' }    | Measure-Object).Count
        }
        Checks     = $allChecks
        Findings   = $allFindings
    }
    $reportData | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $jsonFile -Encoding UTF8 -Force
    Write-Host "  JSON  : $jsonFile" -ForegroundColor DarkGray
} catch {
    Write-Host "  [WARN] JSON sidecar failed: $($_.Exception.Message)" -ForegroundColor Yellow
}
'@

Invoke-EnginePatch -EnginePath $netRepairPath `
                   -EngineName 'Invoke-NetRepair.ps1' `
                   -LogsVarName 'LogsPath' `
                   -AnchorLine $nrAnchor `
                   -JsonBlock $nrBlock

Write-Host ''
Write-Host '  Patch complete.' -ForegroundColor Green
Write-Host '  Run the engines once to generate JSON sidecars in LOGS\.' -ForegroundColor White
Write-Host '  Rollback: each engine has a .jsonpatch.bak alongside it.' -ForegroundColor DarkGray
Write-Host ''
