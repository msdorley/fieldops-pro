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

function Get-UserModulesRoot {
    <#
    .SYNOPSIS
        The WindowsPowerShell user modules directory, honouring folder redirection.
    .DESCRIPTION
        $env:USERPROFILE\Documents is WRONG on any machine where the Documents
        known folder is redirected -- OneDrive Backup does this by default, and
        it is the norm on a corporate Windows 11 image, which is precisely the
        environment this toolkit targets.

        On such a machine the literal path either does not exist or is a stub
        that is NOT on PSModulePath, so a bundle copied there is invisible to
        module resolution while Install-Module targets the redirected path.
        The two disagree, and the bootstrap fails in a way that reads like a
        missing bundle.

        GetFolderPath('MyDocuments') resolves the redirection. The literal path
        remains as a last-resort fallback for a profile with no Documents
        folder registered at all.
    #>
    $docs = ''
    try {
        $docs = [Environment]::GetFolderPath('MyDocuments')
    } catch {
        $docs = ''
    }
    if (-not $docs) {
        $docs = Join-Path $env:USERPROFILE 'Documents'
    }
    return (Join-Path $docs 'WindowsPowerShell\Modules')
}

function Test-ModuleDirUsable {
    <#
    .SYNOPSIS
        True only if the directory holds an actual importable manifest.
    .DESCRIPTION
        A bare Test-Path on the directory is not enough: a previous run that
        created the folder and then failed the copy leaves an empty directory
        behind, which would make the bootstrap skip the copy and then import
        nothing.
    #>
    param([string]$Dir, [string]$ModuleName)
    if (-not (Test-Path -LiteralPath $Dir)) { return $false }
    return (Test-Path -LiteralPath (Join-Path $Dir "$ModuleName.psd1"))
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
        # -Force unconditionally: see the note at Step 3. Reaching this line at
        # all means the session module (if any) was unsatisfactory.
        Import-Module -Name $best.ModuleBase -RequiredVersion $best.Version -Force -ErrorAction Stop
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
    $userModulesRoot = Get-UserModulesRoot
    $targetDir       = Join-Path $userModulesRoot "$MODULE_NAME\$REQUIRED_VERSION"

    if (-not (Test-ModuleDirUsable -Dir $targetDir -ModuleName $MODULE_NAME)) {
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

    # Importing from the USB directly is a legitimate outcome, not a failure:
    # the toolkit is designed to run off the stick. The copy is a convenience.
    if (-not (Test-ModuleDirUsable -Dir $targetDir -ModuleName $MODULE_NAME)) {
        Write-Warn "Copy target unusable. Importing directly from the bundle."
        $targetDir = $bundlePath
    }

    $targetManifest = Join-Path $targetDir "$MODULE_NAME.psd1"
    try {
        # -Force is REQUIRED here, and must not be gated on the -Force parameter.
        #
        # Import-Module is a no-op when a module of the same name is already
        # loaded, whatever its version. Step 1 only warns about an unsatisfactory
        # session module and falls through -- so by the time control reaches this
        # line, a stale Pester (e.g. version 0.0 from a .psm1 imported without
        # its manifest) may still be resident. Without -Force the import silently
        # does nothing, the version probe below reads the STALE module, and the
        # bootstrap reports "bundle loaded but version 0.0" while having loaded
        # nothing at all -- then burns the PSGallery fallback on a problem that
        # was never about the bundle.
        #
        # The -Force PARAMETER means "re-import even when already satisfied".
        # It must not gate the corrective re-import of an unsatisfactory one.
        $imported = Import-Module -Name $targetManifest -Force -PassThru -ErrorAction Stop

        # -PassThru gives the module actually imported. Get-Module -Name can
        # return several entries when more than one Pester is resident, and
        # .Version on that array is not a version.
        $importedVer = $imported.Version
        if (Test-PesterVersionSatisfied -Candidate $importedVer) {
            Write-OK "Pester $importedVer imported from offline bundle: $($imported.Path)"
            return
        }
        Write-Warn "Bundle at $targetManifest reports version $importedVer, which does not satisfy $REQUIRED_VERSION."
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

Import-Module -Name $installed.ModuleBase -RequiredVersion $installed.Version -Force -ErrorAction Stop
Write-OK "Pester $($installed.Version) imported from PSGallery install."
