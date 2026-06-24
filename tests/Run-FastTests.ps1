#Requires -Version 5.1
<#
.SYNOPSIS
    FieldOps Pro fast test subset runner.

.DESCRIPTION
    Runs only tests tagged [Tag('Fast')] across the full test tree.
    Designed for two contexts:

        1. Pre-commit hook (.git\hooks\pre-commit via D8) -- must complete
           in under 30 seconds so commits do not feel punishing.
        2. Inner-loop development -- run after every save to get immediate
           signal without waiting for audit tests.

    Audit tests and property tests (which are slower by design) are excluded
    unless -IncludeAll is specified, in which case this becomes a thin wrapper
    around Run-AllTests.ps1.

    Exit codes mirror Run-AllTests.ps1:
        0  -- all Fast-tagged tests passed (or no Fast tests found, non-CI)
        1  -- one or more tests failed
        2  -- Pester bootstrap failed
        3  -- no test files discovered at all

    Tag convention:
        Tests that should run here carry:  -Tag 'Fast'
        Tests excluded from fast run carry: -Tag 'Slow' (or no Fast tag)
        All audit tests are implicitly Slow regardless of tagging.

.PARAMETER CI
    Non-interactive mode.  Exits 3 if no Fast-tagged tests are found
    (rather than exiting 0 with a warning).  Used by the pre-commit hook.

.PARAMETER IncludeAll
    Disable Fast tag filter -- run every discovered test.
    Equivalent to Run-AllTests.ps1 -SkipAudit.

.PARAMETER BundleRoot
    Passed through to Install-PesterIfMissing.ps1 (D1).

.PARAMETER OutputDir
    Directory for JUnit XML output.  Defaults to tests\TestResults\.

.NOTES
    FieldOps Pro - Chapter 6.6 Continuous Validation - D4
    PS 5.1.  ASCII source.  Set-StrictMode -Version 1.0.
    Dot-sources tests\Install-PesterIfMissing.ps1 (D1) for Pester bootstrap.
    Called by tests\Install-PreCommitHook.ps1 (D8).
#>

[CmdletBinding(SupportsShouldProcess = $false)]
param(
    [Parameter(Mandatory = $false)]
    [switch]$CI,

    [Parameter(Mandatory = $false)]
    [switch]$IncludeAll,

    [Parameter(Mandatory = $false)]
    [string]$BundleRoot = '',

    [Parameter(Mandatory = $false)]
    [string]$OutputDir = ''
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Resolve paths
# ---------------------------------------------------------------------------
$testsRoot       = $PSScriptRoot
$repoRoot        = Split-Path $testsRoot -Parent
$bootstrapScript = Join-Path $testsRoot 'Install-PesterIfMissing.ps1'

if ($OutputDir -eq '') {
    $OutputDir = Join-Path $testsRoot 'TestResults'
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Banner {
    param([string]$Text)
    $line = '-' * 72
    Write-Host $line               -ForegroundColor DarkGray
    Write-Host "  $Text"          -ForegroundColor Cyan
    Write-Host $line               -ForegroundColor DarkGray
}

function Write-Step {
    param([string]$Text)
    Write-Host "[Run-FastTests] $Text" -ForegroundColor Cyan
}

function Write-OK {
    param([string]$Text)
    Write-Host "[Run-FastTests] OK: $Text" -ForegroundColor Green
}

function Write-Fail {
    param([string]$Text)
    Write-Host "[Run-FastTests] FAIL: $Text" -ForegroundColor Red
}

if (-not $CI) {
    Write-Banner "FieldOps Pro -- Fast Test Subset"
    Write-Host "  Repo    : $repoRoot"  -ForegroundColor DarkGray
    Write-Host "  Filter  : $(if ($IncludeAll) { 'none (IncludeAll)' } else { 'Tag = Fast' })" -ForegroundColor DarkGray
    Write-Host "  Date    : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor DarkGray
    Write-Host ""
}

# ---------------------------------------------------------------------------
# Step 1: Bootstrap Pester
# ---------------------------------------------------------------------------
Write-Step "Bootstrapping Pester ..."

if (-not (Test-Path $bootstrapScript)) {
    Write-Fail "Bootstrap script not found: $bootstrapScript"
    exit 2
}

try {
    $bootstrapArgs = @{}
    if ($BundleRoot -ne '') {
        $bootstrapArgs['BundleRoot'] = $BundleRoot
    }
    . $bootstrapScript @bootstrapArgs
} catch {
    Write-Fail "Pester bootstrap failed: $_"
    exit 2
}

$pesterModule = Get-Module -Name 'Pester'
if ($null -eq $pesterModule) {
    Write-Fail "Pester not loaded after bootstrap."
    exit 2
}
Write-OK "Pester $($pesterModule.Version) ready."

# ---------------------------------------------------------------------------
# Step 2: Ensure output directory
# ---------------------------------------------------------------------------
if (-not (Test-Path $OutputDir)) {
    $null = New-Item -ItemType Directory -Path $OutputDir -Force
}

# ---------------------------------------------------------------------------
# Step 3: Discover test files (unit + evaluators + audit). Tier selection is
# tag-driven: the Fast tag filter (Step 4) runs only Fast-tagged Describe
# blocks. Property and audit tests are tagged Slow, so they are discovered
# but not executed in the fast pre-commit gate -- they run via Run-AllTests
# (pre-push). One source of truth = the tag, not the filename.
# ---------------------------------------------------------------------------
Write-Step "Discovering test files (unit + evaluators + audit) ..."

$testFiles = [System.Collections.Generic.List[string]]::new()
foreach ($sub in @('unit', 'evaluators', 'audit')) {
    $dir = Join-Path $testsRoot $sub
    if (Test-Path $dir) {
        $found = @(Get-ChildItem -Path $dir -Recurse -Filter '*.Tests.ps1' |
            Sort-Object FullName |
            Select-Object -ExpandProperty FullName)
        foreach ($f in $found) { $testFiles.Add($f) }
    }
}

if ($testFiles.Count -eq 0) {
    if ($CI) {
        Write-Fail "No test files discovered. Cannot run fast tests."
        exit 3
    } else {
        Write-Step "No test files found yet -- nothing to run."
        exit 0
    }
}

Write-OK "Test files found: $($testFiles.Count)"

# ---------------------------------------------------------------------------
# Step 4: Build Pester configuration
# ---------------------------------------------------------------------------
$xmlOutputPath = Join-Path $OutputDir 'FieldOps-FastTests.xml'

$pesterConfig = New-PesterConfiguration
$pesterConfig.Run.Path                 = $testFiles.ToArray()
$pesterConfig.Run.Exit                 = $true
$pesterConfig.Run.PassThru            = $true
$pesterConfig.Output.Verbosity        = 'Normal'
$pesterConfig.TestResult.Enabled      = $true
$pesterConfig.TestResult.OutputFormat = 'JUnitXml'
$pesterConfig.TestResult.OutputPath   = $xmlOutputPath
$pesterConfig.Should.ErrorAction      = 'Continue'
$pesterConfig.CodeCoverage.Enabled    = $false

# Apply Fast tag filter unless -IncludeAll
if (-not $IncludeAll) {
    $pesterConfig.Filter.Tag = @('Fast')
}

# ---------------------------------------------------------------------------
# Step 5: Run
# ---------------------------------------------------------------------------
Write-Step "Running fast tests ..."
Write-Host ""

$result = $null
try {
    $result = Invoke-Pester -Configuration $pesterConfig
} catch {
    Write-Fail "Pester invocation threw: $_"
    exit 1
}

# ---------------------------------------------------------------------------
# Step 6: Summary
# ---------------------------------------------------------------------------
Write-Host ""

if ($null -ne $result) {
    $passed  = $result.PassedCount
    $failed  = $result.FailedCount
    $skipped = $result.SkippedCount
    $total   = $result.TotalCount
    $dur     = [math]::Round($result.Duration.TotalSeconds, 1)

    if (-not $CI) {
        Write-Banner "Results"
        Write-Host "  Passed  : $passed"  -ForegroundColor Green
        if ($failed -gt 0) {
            Write-Host "  Failed  : $failed"  -ForegroundColor Red
        } else {
            Write-Host "  Failed  : $failed"  -ForegroundColor DarkGray
        }
        Write-Host "  Skipped : $skipped" -ForegroundColor DarkGray
        Write-Host "  Total   : $total"   -ForegroundColor White
        Write-Host "  Duration: ${dur}s"  -ForegroundColor DarkGray
        Write-Host ""
    }

    # Non-CI: warn if no Fast-tagged tests ran (tests exist but none tagged)
    if (-not $IncludeAll -and $total -eq 0 -and -not $CI) {
        Write-Step "WARNING: No Fast-tagged tests ran. Tag unit tests with -Tag 'Fast'."
        exit 0
    }

    if ($failed -gt 0) {
        Write-Fail "$failed test(s) failed."
        exit 1
    }

    Write-OK "$passed test(s) passed in ${dur}s."
    exit 0
} else {
    Write-Fail "Pester returned no result object."
    exit 1
}
