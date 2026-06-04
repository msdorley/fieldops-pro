#Requires -Version 5.1
<#
.SYNOPSIS
    One-time provisioning script: downloads Pester 5.7.1 and stages it as the
    FieldOps Pro offline bundle at TOOLS\PowerShellModules\Pester\5.7.1\.

.DESCRIPTION
    Run this on the build machine (MSDORLEY) whenever the USB needs to be
    re-provisioned or the Pester version is bumped at a new major release.

    What it does:
        1. Downloads Pester 5.7.1 via Save-Module (no session install).
        2. Copies the module tree to the bundle target path.
        3. Verifies the manifest version is exactly 5.7.1.
        4. Prints SHA-256 of Pester.psd1 for audit trail.

    The bundle target is relative to this script location:
        Script lives at:   TOOLS\PowerShellModules\Populate-PesterBundle.ps1
        Bundle lands at:   TOOLS\PowerShellModules\Pester\5.7.1\

    After running, commit the bundle and push via PR.
    Binary PS module files are intentionally tracked -- the repo must be
    self-contained for air-gap USB deployment.

.PARAMETER TargetRoot
    Override the bundle root.  Defaults to the directory containing this script.

.PARAMETER Force
    Overwrite an existing bundle even if the version already matches.

.NOTES
    FieldOps Pro - Chapter 6.6 Continuous Validation - D2 provisioning helper
    Run once per build machine, not on target endpoints.
    PS 5.1.  ASCII source.
#>

[CmdletBinding(SupportsShouldProcess = $false)]
param(
    [Parameter(Mandatory = $false)]
    [string]$TargetRoot = '',

    [Parameter(Mandatory = $false)]
    [switch]$Force
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
$REQUIRED_VERSION = '5.7.1'
$MODULE_NAME      = 'Pester'

# ---------------------------------------------------------------------------
# Resolve target path
# ---------------------------------------------------------------------------
if ($TargetRoot -eq '') {
    $TargetRoot = $PSScriptRoot
}
$bundleTarget   = Join-Path $TargetRoot "$MODULE_NAME\$REQUIRED_VERSION"
$manifestTarget = Join-Path $bundleTarget "$MODULE_NAME.psd1"

# ---------------------------------------------------------------------------
# Guard: already populated?
# ---------------------------------------------------------------------------
if ((Test-Path $manifestTarget) -and (-not $Force)) {
    Write-Host "[D2] Bundle already present at: $bundleTarget" -ForegroundColor Green
    Write-Host "[D2] Use -Force to overwrite." -ForegroundColor Yellow
    $hash = (Get-FileHash $manifestTarget -Algorithm SHA256).Hash
    Write-Host "[D2] Pester.psd1 SHA-256: $hash" -ForegroundColor Cyan
    return
}

# ---------------------------------------------------------------------------
# Step 1: Unblock this script so Save-Module runs cleanly
# ---------------------------------------------------------------------------
Unblock-File -Path $PSCommandPath -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# Step 2: Download via Save-Module to a temp staging path
# ---------------------------------------------------------------------------
$stagingRoot = Join-Path $env:TEMP ("FieldOps-PesterStage-" + [System.Guid]::NewGuid().ToString('N').Substring(0,8))
$null = New-Item -ItemType Directory -Path $stagingRoot -Force

Write-Host "[D2] Staging path: $stagingRoot" -ForegroundColor Cyan
Write-Host "[D2] Downloading Pester $REQUIRED_VERSION from PSGallery ..." -ForegroundColor Cyan

$downloaded = $false
try {
    Save-Module -Name $MODULE_NAME `
                -RequiredVersion $REQUIRED_VERSION `
                -Path $stagingRoot `
                -Repository 'PSGallery' `
                -Force `
                -ErrorAction Stop
    $downloaded = $true
    Write-Host "[D2] Save-Module completed." -ForegroundColor Green
} catch {
    Write-Warning "[D2] Save-Module failed: $_"
}

if (-not $downloaded) {
    Write-Host "[D2] Falling back to Install-Module -Scope CurrentUser ..." -ForegroundColor Yellow
    Install-Module -Name $MODULE_NAME `
                   -RequiredVersion $REQUIRED_VERSION `
                   -Scope CurrentUser `
                   -Repository 'PSGallery' `
                   -Force `
                   -AllowClobber `
                   -SkipPublisherCheck `
                   -ErrorAction Stop

    $installed = Get-Module -Name $MODULE_NAME -ListAvailable |
        Where-Object { $_.Version.ToString() -eq $REQUIRED_VERSION } |
        Select-Object -First 1

    if ($null -eq $installed) {
        throw "Install-Module succeeded but module not found via Get-Module. Check PSModulePath."
    }
    $stagingPath = $installed.ModuleBase
} else {
    $stagingPath = Join-Path $stagingRoot "$MODULE_NAME\$REQUIRED_VERSION"
}

# ---------------------------------------------------------------------------
# Step 3: Verify staging manifest
# ---------------------------------------------------------------------------
$stagingManifest = Join-Path $stagingPath "$MODULE_NAME.psd1"
if (-not (Test-Path $stagingManifest)) {
    throw "Staged manifest not found at: $stagingManifest"
}

$stagedVersion = (Import-PowerShellDataFile $stagingManifest).ModuleVersion
if ($stagedVersion -ne $REQUIRED_VERSION) {
    throw "Staged manifest reports version $stagedVersion but expected $REQUIRED_VERSION."
}
Write-Host "[D2] Staged version verified: $stagedVersion" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Step 4: Copy to bundle target
# ---------------------------------------------------------------------------
Write-Host "[D2] Copying to: $bundleTarget" -ForegroundColor Cyan

if (Test-Path $bundleTarget) {
    Remove-Item $bundleTarget -Recurse -Force
}
$null = New-Item -ItemType Directory -Path $bundleTarget -Force
Copy-Item -Path "$stagingPath\*" -Destination $bundleTarget -Recurse -Force

# ---------------------------------------------------------------------------
# Step 5: Verify manifest at target
# ---------------------------------------------------------------------------
if (-not (Test-Path $manifestTarget)) {
    throw "Post-copy verification failed: manifest not found at $manifestTarget"
}
$hash = (Get-FileHash $manifestTarget -Algorithm SHA256).Hash

# ---------------------------------------------------------------------------
# Step 6: Cleanup staging (best-effort)
# ---------------------------------------------------------------------------
try {
    Remove-Item $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
} catch { }

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "[D2] Bundle provisioned successfully." -ForegroundColor Green
Write-Host "[D2] Path    : $bundleTarget"          -ForegroundColor White
Write-Host "[D2] Version : $REQUIRED_VERSION"      -ForegroundColor White
Write-Host "[D2] SHA-256 : $hash"                  -ForegroundColor Cyan
Write-Host ""
Write-Host "[D2] Next steps:"                                                                           -ForegroundColor Yellow
Write-Host "    git add TOOLS/PowerShellModules/Pester/"                                               -ForegroundColor White
Write-Host "    git commit -m 'chore(test): add Pester 5.7.1 offline bundle (6.6-D2)'"                -ForegroundColor White
Write-Host "    git push"                                                                               -ForegroundColor White
