#Requires -Version 5.1
<#
.SYNOPSIS
    Fixture loader helper for FieldOps Pro test infrastructure.

.DESCRIPTION
    Resolves and loads named JSON fixtures from tests\fixtures\.
    Fixtures are snapshots of report-data.json used by unit tests and
    property tests to avoid coupling tests to live WMI/registry state.

    Naming convention:
        report-data.<variant>.json

    Variants shipped with 6.6 (see tests\fixtures\):
        nominal            -- clean passing machine, all 42 rules, CV=7 PV=19 HP=16
        all-cv             -- every rule status = cv (CV=42 PV=0 HP=0)
        all-pv             -- every rule status = pv
        all-hp             -- every rule status = hp
        empty-modules      -- Modules array is empty (renderer edge case)
        empty-topfindings  -- TopFindings array is empty
        missing-summary    -- Summary block omitted (schema validation test)
        missing-machine    -- Machine block omitted
        missing-report     -- Report block omitted
        single-module      -- only module I present
        single-rule        -- only R1 present in ModuleDetails
        null-meta          -- one rule has Meta = null
        empty-meta         -- one rule has Meta = ""
        long-meta          -- one rule has Meta > 500 chars
        unicode-meta       -- Meta contains unicode (apostrophes, accents)
        cv-only-modules    -- all non-HP modules show CV only
        max-topfindings    -- TopFindings has exactly 3 entries (normal max)
        zero-topfindings   -- TopFindings is [] (safety-net path)
        future-date        -- GeneratedAt is year 2099 (date handling)
        minimal            -- only required top-level keys, no optional fields

    Usage in a Pester test:

        . (Join-Path $PSScriptRoot '..\..\Get-Fixture.ps1')

        Describe 'Summary counts' {
            It 'nominal fixture has correct totals' {
                $data = Get-Fixture 'nominal'
                $data.Summary.Total | Should -Be 42
                ($data.Summary.CountCV + $data.Summary.CountPV + $data.Summary.CountHP) |
                    Should -Be 42
            }
        }

.PARAMETER Name
    Fixture variant name (without path or extension).
    E.g. 'nominal', 'all-cv', 'missing-summary'.

.PARAMETER FixturesDir
    Override the fixtures directory.  Defaults to tests\fixtures\ relative
    to the directory containing this script ($PSScriptRoot).

.OUTPUTS
    [PSCustomObject] -- the parsed JSON fixture object.
    Throws if the fixture file does not exist or is not valid JSON.

.NOTES
    FieldOps Pro - Chapter 6.6 Continuous Validation - D6
    PS 5.1.  ASCII source.  Set-StrictMode -Version 1.0.
    Dot-sourced by unit tests; not a module.
#>

[CmdletBinding(SupportsShouldProcess = $false)]
param()

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

function Get-Fixture {
    <#
    .SYNOPSIS
        Load a named fixture from tests\fixtures\.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Name,

        [Parameter(Mandatory = $false)]
        [string]$FixturesDir = ''
    )

    if ($FixturesDir -eq '') {
        # $PSScriptRoot = tests\  (this script lives at tests\Get-Fixture.ps1)
        $FixturesDir = Join-Path $PSScriptRoot 'fixtures'
    }

    $filename = "report-data.$Name.json"
    $filepath = Join-Path $FixturesDir $filename

    if (-not (Test-Path $FixturesDir)) {
        throw "Get-Fixture: fixtures directory not found at: $FixturesDir"
    }

    if (-not (Test-Path $filepath)) {
        $available = @(Get-ChildItem -Path $FixturesDir -Filter 'report-data.*.json' |
            ForEach-Object { $_.Name -replace '^report-data\.' -replace '\.json$' } |
            Sort-Object)
        $list = $available -join ', '
        throw "Get-Fixture: fixture '$Name' not found at: $filepath`nAvailable fixtures: $list"
    }

    $raw = $null
    try {
        $raw = Get-Content -LiteralPath $filepath -Raw -Encoding UTF8
    } catch {
        throw "Get-Fixture: failed to read fixture '$Name': $_"
    }

    $parsed = $null
    try {
        $parsed = $raw | ConvertFrom-Json
    } catch {
        throw "Get-Fixture: fixture '$Name' is not valid JSON: $_"
    }

    return $parsed
}

function Get-FixtureNames {
    <#
    .SYNOPSIS
        List all available fixture variant names.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$FixturesDir = ''
    )

    if ($FixturesDir -eq '') {
        $FixturesDir = Join-Path $PSScriptRoot 'fixtures'
    }

    if (-not (Test-Path $FixturesDir)) {
        return @()
    }

    return @(Get-ChildItem -Path $FixturesDir -Filter 'report-data.*.json' |
        ForEach-Object { $_.Name -replace '^report-data\.' -replace '\.json$' } |
        Sort-Object)
}

function Get-FixturePath {
    <#
    .SYNOPSIS
        Resolve the full path of a named fixture without loading it.
        Useful for tests that need to pass a file path rather than an object.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Name,

        [Parameter(Mandatory = $false)]
        [string]$FixturesDir = ''
    )

    if ($FixturesDir -eq '') {
        $FixturesDir = Join-Path $PSScriptRoot 'fixtures'
    }

    $filepath = Join-Path $FixturesDir "report-data.$Name.json"

    if (-not (Test-Path $filepath)) {
        throw "Get-FixturePath: fixture '$Name' not found at: $filepath"
    }

    return $filepath
}
