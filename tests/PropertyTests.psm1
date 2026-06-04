#Requires -Version 5.1
<#
.SYNOPSIS
    Property-testing shim for FieldOps Pro test infrastructure.

.DESCRIPTION
    Provides Invoke-Property -- a lightweight property-based testing function
    that integrates with Pester 5.x.  Runs a generator function N times,
    feeding random inputs to a property assertion.

    Key design decisions:
        - Explicit seed for reproducibility (6.6-Risk-3 mitigation).
          A failing run saves the seed + offending input to TestResults\ so
          the exact failure can be replayed deterministically.
        - Pure PS 5.1 -- no external dependencies beyond Pester.
        - Integrates with Pester's It block: call Invoke-Property inside
          a Describe/Context/It hierarchy.
        - Generator and Property are plain scriptblocks, not classes.

    Usage inside a Pester test file:

        Import-Module (Join-Path $PSScriptRoot '..\..\PropertyTests.psm1') -Force

        Describe 'Rule evaluator robustness' {
            It 'never throws on null inputs' {
                Invoke-Property `
                    -Name 'evaluator handles null' `
                    -Generator { @{ Wmi = $null; Registry = $null } } `
                    -Property {
                        param($input)
                        { Invoke-MyEvaluator $input } | Should -Not -Throw
                    } `
                    -Iterations 50
            }
        }

    Seed override for replay:

        Invoke-Property -Name '...' -Generator {...} -Property {...} -Seed 1234567890

.NOTES
    FieldOps Pro - Chapter 6.6 Continuous Validation - D5
    PS 5.1.  ASCII source.  Set-StrictMode -Version 1.0.
    Called by tests\evaluators\PropertyTests-Evaluators.ps1 (D13).
    Referenced in DOCS\PHASE-6-DESIGN.md section 6.6.4.3.
#>

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Module-level RNG state
# Kept in module scope so multiple Invoke-Property calls in one session
# share the same RNG instance unless a seed is explicitly supplied.
# ---------------------------------------------------------------------------
$script:Rng = $null

function Initialize-Rng {
    param([int]$Seed)
    $script:Rng = [System.Random]::new($Seed)
}

function Get-RandomInt {
    param(
        [int]$Min = [int]::MinValue,
        [int]$Max = [int]::MaxValue
    )
    if ($null -eq $script:Rng) {
        $script:Rng = [System.Random]::new()
    }
    # System.Random.Next(min, max) -- max is exclusive
    if ($Max -lt [int]::MaxValue) {
        return $script:Rng.Next($Min, $Max + 1)
    }
    return $script:Rng.Next($Min, [int]::MaxValue)
}

function Get-RandomDouble {
    if ($null -eq $script:Rng) {
        $script:Rng = [System.Random]::new()
    }
    return $script:Rng.NextDouble()
}

function Get-RandomString {
    param(
        [int]$MinLength = 0,
        [int]$MaxLength = 64,
        [string]$Charset = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 _-.'
    )
    if ($null -eq $script:Rng) {
        $script:Rng = [System.Random]::new()
    }
    $len  = $script:Rng.Next($MinLength, $MaxLength + 1)
    $chars = $Charset.ToCharArray()
    $result = -join (1..$len | ForEach-Object { $chars[$script:Rng.Next(0, $chars.Length)] })
    return $result
}

function Get-RandomElement {
    param([object[]]$Collection)
    if ($null -eq $script:Rng) {
        $script:Rng = [System.Random]::new()
    }
    if ($null -eq $Collection -or $Collection.Count -eq 0) { return $null }
    return $Collection[$script:Rng.Next(0, $Collection.Count)]
}

# ---------------------------------------------------------------------------
# Save failure evidence to disk for deterministic replay (Risk-3 mitigation)
# ---------------------------------------------------------------------------
function Save-PropertyFailure {
    param(
        [string]$Name,
        [int]$Seed,
        [int]$Iteration,
        [object]$Input,
        [string]$ErrorMessage,
        [string]$OutputDir
    )

    if ($OutputDir -eq '' -or (-not (Test-Path $OutputDir))) {
        try {
            $null = New-Item -ItemType Directory -Path $OutputDir -Force -ErrorAction Stop
        } catch {
            return  # Non-fatal -- evidence saving is best-effort
        }
    }

    $safeName = $Name -replace '[^a-zA-Z0-9_-]', '_'
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $filename  = "PropertyFail-${safeName}-${timestamp}.json"
    $filepath  = Join-Path $OutputDir $filename

    $evidence = [ordered]@{
        Name      = $Name
        Seed      = $Seed
        Iteration = $Iteration
        Input     = $Input
        Error     = $ErrorMessage
        Timestamp = (Get-Date -Format 'o')
        ReplayCmd = "Invoke-Property -Name '$Name' -Generator <same> -Property <same> -Seed $Seed"
    }

    try {
        $evidence | ConvertTo-Json -Depth 5 | Set-Content -Path $filepath -Encoding UTF8
    } catch {
        # Non-fatal
    }
}

# ---------------------------------------------------------------------------
# Invoke-Property -- main entry point
# ---------------------------------------------------------------------------
function Invoke-Property {
    <#
    .SYNOPSIS
        Runs a property-based test: generates N random inputs and asserts
        a property holds for each.

    .PARAMETER Name
        Human-readable description of the property being tested.
        Used in failure messages and evidence file names.

    .PARAMETER Generator
        Scriptblock that returns one random input value per call.
        The module's Get-Random* helpers are available inside the block.
        The block receives no parameters.

    .PARAMETER Property
        Scriptblock that asserts the property.
        Receives the generated input as $args[0] (or via param($input)).
        Should use Pester Should assertions or throw on violation.

    .PARAMETER Iterations
        Number of random inputs to generate and test.  Default: 100.

    .PARAMETER Seed
        RNG seed for reproducibility.  If omitted, a random seed is chosen
        and reported in any failure evidence so the run can be replayed.

    .PARAMETER OutputDir
        Directory for failure evidence JSON files.
        Defaults to the TestResults\ directory relative to the tests\ root.

    .EXAMPLE
        Invoke-Property `
            -Name 'Format-DetailString never returns null' `
            -Generator { Get-RandomString -MinLength 0 -MaxLength 256 } `
            -Property { param($s) (Format-DetailString $s) | Should -Not -BeNullOrEmpty } `
            -Iterations 200
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Generator,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Property,

        [Parameter(Mandatory = $false)]
        [int]$Iterations = 100,

        [Parameter(Mandatory = $false)]
        [int]$Seed = -1,

        [Parameter(Mandatory = $false)]
        [string]$OutputDir = ''
    )

    # Resolve seed
    $actualSeed = $Seed
    if ($actualSeed -eq -1) {
        $actualSeed = [System.Environment]::TickCount
    }

    Initialize-Rng -Seed $actualSeed

    # Resolve output dir for failure evidence
    $evidenceDir = $OutputDir
    if ($evidenceDir -eq '') {
        # Best-effort: walk up from module location to find tests\TestResults\
        $moduleDir   = Split-Path $PSScriptRoot -Parent
        $evidenceDir = Join-Path $moduleDir 'tests\TestResults'
        if (-not (Test-Path (Split-Path $evidenceDir -Parent))) {
            $evidenceDir = $env:TEMP
        }
    }

    $failures  = 0
    $lastError = ''
    $lastInput = $null

    for ($i = 1; $i -le $Iterations; $i++) {
        # Generate input
        $inputVal = $null
        try {
            $inputVal = & $Generator
        } catch {
            throw "Invoke-Property '$Name': Generator threw on iteration $i -- $_"
        }

        # Assert property
        try {
            & $Property $inputVal
        } catch {
            $failures++
            $lastError = $_.ToString()
            $lastInput = $inputVal

            Save-PropertyFailure `
                -Name        $Name `
                -Seed        $actualSeed `
                -Iteration   $i `
                -Input       $inputVal `
                -ErrorMessage $lastError `
                -OutputDir   $evidenceDir

            # Fail fast on first violation -- surface the minimal case
            $msg  = "Property '$Name' violated on iteration $i of $Iterations (seed: $actualSeed).`n"
            $msg += "Input   : $($inputVal | ConvertTo-Json -Depth 3 -Compress)`n"
            $msg += "Error   : $lastError`n"
            $msg += "Replay  : Invoke-Property -Name '$Name' -Generator <same> -Property <same> -Seed $actualSeed"
            throw $msg
        }
    }

    # All iterations passed
    Write-Verbose "Invoke-Property '$Name': $Iterations iterations passed (seed: $actualSeed)."
}

# ---------------------------------------------------------------------------
# Export
# ---------------------------------------------------------------------------
Export-ModuleMember -Function @(
    'Invoke-Property'
    'Get-RandomInt'
    'Get-RandomDouble'
    'Get-RandomString'
    'Get-RandomElement'
    'Initialize-Rng'
)
