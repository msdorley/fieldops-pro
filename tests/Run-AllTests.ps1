#Requires -Version 5.1
<#
.SYNOPSIS
    FieldOps Pro full test suite runner.

.DESCRIPTION
    Discovers and runs all Pester tests under tests\ in the correct order:
        1. tests\unit\       -- fast, isolated unit tests
        2. tests\evaluators\ -- rule evaluator unit + property tests
        3. tests\audit\      -- repo-wide invariant audit tests (slower)

    Exit codes:
        0  -- all tests passed
        1  -- one or more tests failed
        2  -- Pester bootstrap failed (Pester unavailable)
        3  -- no test files discovered

    Output:
        Console  -- Pester default output (Detailed verbosity)
        JUnit    -- tests\TestResults\FieldOps-AllTests.xml  (CI integration)

    Usage:
        # Normal run from repo root
        .\tests\Run-AllTests.ps1

        # CI / pre-commit (no interactive prompts, strict exit code)
        .\tests\Run-AllTests.ps1 -CI

        # Skip audit tests (faster, for inner-loop dev)
        .\tests\Run-AllTests.ps1 -SkipAudit

        # Override USB root for offline bundle resolution
        .\tests\Run-AllTests.ps1 -BundleRoot 'E:\'

.PARAMETER CI
    Suppresses all interactive output beyond Pester's own rendering.
    Ensures a non-zero exit code on any failure (default in CI).

.PARAMETER SkipAudit
    Excludes tests\audit\ from the run.  Useful during rapid iteration
    when audit tests are known-passing and slow.

.PARAMETER BundleRoot
    Passed through to Install-PesterIfMissing.ps1.  Override when the
    repo is not at the USB root (e.g. C:\Dev\fieldops-pro on the build
    machine vs E:\ in field deployment).

.PARAMETER OutputDir
    Directory for JUnit XML output.  Defaults to tests\TestResults\.
    Created if absent.

.NOTES
    FieldOps Pro - Chapter 6.6 Continuous Validation - D3
    PS 5.1.  ASCII source.  Set-StrictMode -Version 1.0.
    Dot-sources tests\Install-PesterIfMissing.ps1 (D1) for Pester bootstrap.
#>

[CmdletBinding(SupportsShouldProcess = $false)]
param(
    [Parameter(Mandatory = $false)]
    [switch]$CI,

    [Parameter(Mandatory = $false)]
    [switch]$SkipAudit,

    [Parameter(Mandatory = $false)]
    [string]$BundleRoot = '',

    [Parameter(Mandatory = $false)]
    [string]$OutputDir = ''
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Resolve paths -- all derived from $PSScriptRoot, never hardcoded
# ---------------------------------------------------------------------------
# $PSScriptRoot = tests\
$testsRoot  = $PSScriptRoot
$repoRoot   = Split-Path $testsRoot -Parent

if ($OutputDir -eq '') {
    $OutputDir = Join-Path $testsRoot 'TestResults'
}

$bootstrapScript = Join-Path $testsRoot 'Install-PesterIfMissing.ps1'

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
function Write-Banner {
    param([string]$Text)
    $line = '-' * 72
    Write-Host $line                    -ForegroundColor DarkGray
    Write-Host "  $Text"               -ForegroundColor Cyan
    Write-Host $line                    -ForegroundColor DarkGray
}

function Write-Step {
    param([string]$Text)
    Write-Host "[Run-AllTests] $Text"  -ForegroundColor Cyan
}

function Write-OK {
    param([string]$Text)
    Write-Host "[Run-AllTests] OK: $Text" -ForegroundColor Green
}

function Write-Fail {
    param([string]$Text)
    Write-Host "[Run-AllTests] FAIL: $Text" -ForegroundColor Red
}

if (-not $CI) {
    Write-Banner "FieldOps Pro -- Full Test Suite"
    Write-Host "  Repo    : $repoRoot"    -ForegroundColor DarkGray
    Write-Host "  Tests   : $testsRoot"   -ForegroundColor DarkGray
    Write-Host "  Output  : $OutputDir"   -ForegroundColor DarkGray
    Write-Host "  Date    : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor DarkGray
    Write-Host ""
}

# ---------------------------------------------------------------------------
# Step 1: Bootstrap Pester
# ---------------------------------------------------------------------------
Write-Step "Bootstrapping Pester ..."

if (-not (Test-Path $bootstrapScript)) {
    Write-Fail "Bootstrap script not found at: $bootstrapScript"
    Write-Fail "Expected tests\Install-PesterIfMissing.ps1 (D1) to exist."
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

# Select before reporting: Get-Module -Name returns every resident module of
# that name, and a session carrying a stale Pester 0.0 alongside 5.7.1 renders
# as "0.0 5.7.1". The old null check also passed a session holding ONLY the
# stale module, running the full suite on Pester 0.0. See Run-FastTests.ps1.
$pesterModule = Get-Module -Name 'Pester' |
    Sort-Object Version -Descending |
    Select-Object -First 1

if ($null -eq $pesterModule) {
    Write-Fail "Pester not loaded after bootstrap. Cannot continue."
    exit 2
}
if ($pesterModule.Version.Major -lt 5 -or
    ($pesterModule.Version.Major -eq 5 -and $pesterModule.Version.Minor -lt 7)) {
    Write-Fail "Pester $($pesterModule.Version) loaded, but 5.7.1+ is required. Bootstrap did not take."
    exit 2
}
Write-OK "Pester $($pesterModule.Version) ready."

# ---------------------------------------------------------------------------
# Step 2: Ensure output directory exists
# ---------------------------------------------------------------------------
if (-not (Test-Path $OutputDir)) {
    $null = New-Item -ItemType Directory -Path $OutputDir -Force
}

# ---------------------------------------------------------------------------
# Step 3: Discover test files in run order
# ---------------------------------------------------------------------------
Write-Step "Discovering test files ..."

$unitDir      = Join-Path $testsRoot 'unit'
$evalDir      = Join-Path $testsRoot 'evaluators'
$auditDir     = Join-Path $testsRoot 'audit'

$testFiles = [System.Collections.Generic.List[string]]::new()

# Unit tests first (fastest, most isolated)
if (Test-Path $unitDir) {
    $found = @(Get-ChildItem -Path $unitDir -Recurse -Filter '*.Tests.ps1' |
        Sort-Object FullName |
        Select-Object -ExpandProperty FullName)
    foreach ($f in $found) { $testFiles.Add($f) }
    Write-Step "Unit tests found    : $($found.Count) file(s)"
} else {
    Write-Step "Unit test dir absent: $unitDir (skipping)"
}

# Evaluator tests second
if (Test-Path $evalDir) {
    $found = @(Get-ChildItem -Path $evalDir -Recurse -Filter '*.Tests.ps1' |
        Sort-Object FullName |
        Select-Object -ExpandProperty FullName)
    # Property tests last within evaluators
    $propFile = Join-Path $evalDir 'PropertyTests-Evaluators.ps1'
    $found = @($found | Where-Object { $_ -ne $propFile })
    foreach ($f in $found) { $testFiles.Add($f) }
    if (Test-Path $propFile) {
        $testFiles.Add($propFile)
        Write-Step "Evaluator tests found: $($found.Count + 1) file(s) (incl. property tests)"
    } else {
        Write-Step "Evaluator tests found: $($found.Count) file(s)"
    }
} else {
    Write-Step "Evaluator dir absent: $evalDir (skipping)"
}

# Audit tests last (slower, repo-wide)
if (-not $SkipAudit) {
    if (Test-Path $auditDir) {
        $found = @(Get-ChildItem -Path $auditDir -Recurse -Filter '*.Tests.ps1' |
            Sort-Object FullName |
            Select-Object -ExpandProperty FullName)
        foreach ($f in $found) { $testFiles.Add($f) }
        Write-Step "Audit tests found   : $($found.Count) file(s)"
    } else {
        Write-Step "Audit dir absent    : $auditDir (skipping)"
    }
} else {
    Write-Step "Audit tests skipped (-SkipAudit)"
}

if ($testFiles.Count -eq 0) {
    Write-Fail "No test files discovered under $testsRoot"
    Write-Fail "Add *.Tests.ps1 files to tests\unit\, tests\evaluators\, or tests\audit\"
    exit 3
}

Write-OK "Total test files    : $($testFiles.Count)"
Write-Host ""

# ---------------------------------------------------------------------------
# Step 4: Build Pester configuration
# ---------------------------------------------------------------------------
$xmlOutputPath = Join-Path $OutputDir 'FieldOps-AllTests.xml'

$pesterConfig = New-PesterConfiguration
$pesterConfig.Run.Path                    = $testFiles.ToArray()
$pesterConfig.Run.Exit                    = $true
$pesterConfig.Run.PassThru               = $true
$pesterConfig.Output.Verbosity           = 'Detailed'
$pesterConfig.TestResult.Enabled         = $true
$pesterConfig.TestResult.OutputFormat    = 'JUnitXml'
$pesterConfig.TestResult.OutputPath      = $xmlOutputPath
$pesterConfig.Should.ErrorAction         = 'Continue'

# CodeCoverage off by default -- enabled separately when needed
$pesterConfig.CodeCoverage.Enabled       = $false

# ---------------------------------------------------------------------------
# Step 5: Run
# ---------------------------------------------------------------------------
Write-Step "Running Pester ..."
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
Write-Banner "Results"

if ($null -ne $result) {
    $passed  = $result.PassedCount
    $failed  = $result.FailedCount
    $skipped = $result.SkippedCount
    $total   = $result.TotalCount
    $dur     = [math]::Round($result.Duration.TotalSeconds, 1)

    Write-Host "  Passed  : $passed"  -ForegroundColor Green
    if ($failed -gt 0) {
        Write-Host "  Failed  : $failed"  -ForegroundColor Red
    } else {
        Write-Host "  Failed  : $failed"  -ForegroundColor DarkGray
    }
    Write-Host "  Skipped : $skipped" -ForegroundColor DarkGray
    Write-Host "  Total   : $total"   -ForegroundColor White
    Write-Host "  Duration: ${dur}s"  -ForegroundColor DarkGray
    Write-Host "  JUnit   : $xmlOutputPath" -ForegroundColor DarkGray
    Write-Host ""

    if ($failed -gt 0) {
        Write-Fail "Test run FAILED -- $failed test(s) did not pass."
        exit 1
    } else {
        Write-OK "All $passed test(s) passed."
        exit 0
    }
} else {
    Write-Fail "Pester returned no result object."
    exit 1
}
