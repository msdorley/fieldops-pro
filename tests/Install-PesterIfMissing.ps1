#Requires -Version 5.1
<#
.SYNOPSIS
    Pester 5.7.1 install bootstrap for FieldOps Pro test infrastructure.

.DESCRIPTION
    Ensures Pester 5.7.1 is available on the current machine before the test
    runners invoke it.  Resolution order:

        1. Already-loaded module in the current session (no-op path).
        2. Module installed in user scope at the required version.
        3. Offline bundle at TOOLS\PowerShellModules\Pester\5.7.1\ on the USB
           (copied to user profile modules path for session durability).
        4. PSGallery download (requires network; fails gracefully when
           unreachable -- 6.6-Risk-1 mitigation).

    On success the module is imported into the caller session.
    On failure a terminating error is thrown.

.PARAMETER BundleRoot
    Override the USB root path for testing purposes.
    Defaults to the parent of $PSScriptRoot (i.e. the USB root when the
    script lives at tests\Install-PesterIfMissing.ps1).

.PARAMETER Force
    Re-import even if Pester is already loaded.

.NOTES
    FieldOps Pro - Chapter 6.6 Continuous Validation - D1
    PS 5.1.  ASCII source.  Set-StrictMode -Version 1.0.
#>

[CmdletBinding(SupportsShouldProcess = $false)]
param(
    [Parameter(Mandatory = $false)]
    [string]$BundleRoot = '',

    [Parameter(Mandatory = $false)]
    [switch]$Force
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
$REQUIRED_MAJOR   = 5
$REQUIRED_MINOR   = 7
$REQUIRED_PATCH   = 1
$REQUIRED_VERSION = "$REQUIRED_MAJOR.$REQUIRED_MINOR.$REQUIRED_PATCH"
$MODULE_NAME      = 'Pester'
$BUNDLE_RELATIVE  = "TOOLS\PowerShellModules\Pester\$REQUIRED_VERSION"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Info {
    param([string]$Message)
    Write-Verbose "[Install-PesterIfMissing] $Message"
}

function Write-Step {
    param([string]$Message)
    Write-Host "[Pester Bootstrap] $Message" -ForegroundColor Cyan
}

function Write-OK {
    param([string]$Message)
    Write-Host "[Pester Bootstrap] OK: $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Warning "[Pester Bootstrap] $Message"
}

function Test-PesterVersionSatisfied {
    param([System.Version]$Candidate)
    if ($Candidate.Major -ne $REQUIRED_MAJOR) { return $false }
    if ($Candidate.Minor -lt $REQUIRED_MINOR)  { return $false }
    if ($Candidate.Minor -eq $REQUIRED_MINOR -and $Candidate.Build -lt $REQUIRED_PATCH) {
        return $false
    }
    return $true
}

# ---------------------------------------------------------------------------
# Step 1: Session-loaded module (fast exit)
# ---------------------------------------------------------------------------
if (-not $Force) {
    $loaded = Get-Module -Name $MODULE_NAME | Select-Object -First 1
    if ($null -ne $loaded) {
        if (Test-PesterVersionSatisfied -Candidate $loaded.Version) {
            Write-Info "Pester $($loaded.Version) already loaded. No action required."
            return
        }
        Write-Warn "Pester $($loaded.Version) loaded but does not meet $REQUIRED_VERSION. Continuing."
    }
}

# ---------------------------------------------------------------------------
# Step 2: Installed modules (user / machine scope)
# ---------------------------------------------------------------------------
Write-Step "Checking for installed Pester >= $REQUIRED_VERSION ..."

$installedModules = Get-Module -Name $MODULE_NAME -ListAvailable -ErrorAction SilentlyContinue
if ($null -ne $installedModules) {
    $best = $installedModules |
        Where-Object { Test-PesterVersionSatisfied -Candidate $_.Version } |
        Sort-Object Version -Descending |
        Select-Object -First 1

    if ($null -ne $best) {
        Write-OK "Found installed Pester $($best.Version) at: $($best.ModuleBase)"
        Import-Module -Name $best.ModuleBase -RequiredVersion $best.Version -Force:$Force -ErrorAction Stop
        Write-OK "Pester $($best.Version) imported."
        return
    }
}

# ---------------------------------------------------------------------------
# Step 3: Offline bundle on USB
# ---------------------------------------------------------------------------
Write-Step "No suitable installed module found. Checking offline bundle ..."

$usbRoot = ''
if ($BundleRoot -ne '') {
    $usbRoot = $BundleRoot
} else {
    # Script lives at tests\ -- one level up is the repo/USB root
    $usbRoot = Split-Path $PSScriptRoot -Parent
}

$bundlePath     = Join-Path $usbRoot $BUNDLE_RELATIVE
$bundleManifest = Join-Path $bundlePath "$MODULE_NAME.psd1"

if (Test-Path $bundleManifest) {
    Write-Step "Offline bundle found at: $bundlePath"

    # Copy to user modules so the session is not USB-dependent
    $userModulesRoot = Join-Path $env:USERPROFILE "Documents\WindowsPowerShell\Modules"
    $targetDir       = Join-Path $userModulesRoot "$MODULE_NAME\$REQUIRED_VERSION"

    if (-not (Test-Path $targetDir)) {
        Write-Step "Copying bundle to user modules: $targetDir"
        try {
            $null = New-Item -ItemType Directory -Path $targetDir -Force -ErrorAction Stop
            Copy-Item -Path "$bundlePath\*" -Destination $targetDir -Recurse -Force -ErrorAction Stop
            Write-OK "Bundle copied to: $targetDir"
        } catch {
            Write-Warn "Bundle copy failed: $_  Falling back to direct USB import."
            $targetDir = $bundlePath
        }
    } else {
        Write-Info "Bundle already at user modules path. Skipping copy."
    }

    $targetManifest = Join-Path $targetDir "$MODULE_NAME.psd1"
    try {
        Import-Module -Name $targetManifest -Force:$Force -ErrorAction Stop
        $importedVer = (Get-Module -Name $MODULE_NAME).Version
        if (Test-PesterVersionSatisfied -Candidate $importedVer) {
            Write-OK "Pester $importedVer imported from offline bundle."
            return
        }
        Write-Warn "Bundle loaded but version $importedVer does not satisfy $REQUIRED_VERSION."
    } catch {
        Write-Warn "Offline bundle import failed: $_"
    }
} else {
    Write-Warn "Offline bundle not found at: $bundleManifest"
    Write-Warn "Expected: TOOLS\PowerShellModules\Pester\$REQUIRED_VERSION\Pester.psd1"
    Write-Warn "Populate D2 (offline bundle) to enable air-gap deployment."
}

# ---------------------------------------------------------------------------
# Step 4: PSGallery download (online fallback)
# ---------------------------------------------------------------------------
Write-Step "Attempting PSGallery install of Pester $REQUIRED_VERSION ..."

$galleryReachable = $false
try {
    $null = [System.Net.Dns]::GetHostEntry('www.powershellgallery.com')
    $galleryReachable = $true
} catch {
    Write-Warn "PSGallery DNS resolution failed. Network may be unavailable."
}

if (-not $galleryReachable) {
    $msg  = "Pester $REQUIRED_VERSION could not be resolved. "
    $msg += "PSGallery is unreachable and the offline bundle is absent or invalid. "
    $msg += "Populate TOOLS\PowerShellModules\Pester\$REQUIRED_VERSION\ on the USB. "
    $msg += "See 6.6-Risk-1 in DOCS\PHASE-6-DESIGN.md."
    throw $msg
}

try {
    Install-Module -Name $MODULE_NAME `
                   -RequiredVersion $REQUIRED_VERSION `
                   -Scope CurrentUser `
                   -Repository 'PSGallery' `
                   -Force `
                   -AllowClobber `
                   -SkipPublisherCheck `
                   -ErrorAction Stop
    Write-OK "Pester $REQUIRED_VERSION installed from PSGallery."
} catch {
    $msg  = "PSGallery install failed: $_  "
    $msg += "Populate the offline bundle at TOOLS\PowerShellModules\Pester\$REQUIRED_VERSION\ "
    $msg += "See 6.6-Risk-1."
    throw $msg
}

$installed = Get-Module -Name $MODULE_NAME -ListAvailable |
    Where-Object { Test-PesterVersionSatisfied -Candidate $_.Version } |
    Sort-Object Version -Descending |
    Select-Object -First 1

if ($null -eq $installed) {
    throw "Pester $REQUIRED_VERSION installed but not found via Get-Module. Check PSModulePath."
}

Import-Module -Name $installed.ModuleBase -RequiredVersion $installed.Version -Force:$Force -ErrorAction Stop
Write-OK "Pester $($installed.Version) imported from PSGallery install."
