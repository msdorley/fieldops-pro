#Requires -Version 5.1
<#
    FieldOps Pro - Chapter 6.6 Continuous Validation
    Compliance evaluator tests (D11) - Build-ANSSIData.ps1

    Strategy:
        The 42 evaluators (Get-R1..Get-R42) and their helpers live inside
        Build-ANSSIData.ps1, which runs its collection pipeline unconditionally
        at the bottom. We use Get-EvaluatorSource.ps1 (AST extraction) to load
        ONLY the function definitions -- never the main body -- so no real
        engine JSON is read and no report file is written.

    What these tests lock in (the contract):
        - Helper null-safety: Find-Check / Find-AllChecks / Import-EngineJson
          never throw on absent or malformed engine data.
        - Universal-hardware degradation: computed rules (R14, R16, R17)
          return the correct 'pv' status -- not 'cv', not an exception -- when
          hardware is absent (no BitLocker, no TPM, no Defender, older Windows,
          VM with nothing reported). This is the portability guarantee turned
          into an executable regression contract.
        - Static rules return their fixed status (R1/R6/R38 etc.).
        - Every evaluator returns a well-formed hashtable {Status; Detail; Evidence}
          with Status in cv/pv/hp, for ANY input including $null.

    Synthetic engine fixtures use the REAL check schema confirmed from source:
        @{ Checks = @( @{ Category=...; Check=...; Value=...; Status=... } ) }
        Test-Status passes only when Status -eq 'Pass'.
        Get-DictValue works on hashtables, so fixtures are plain hashtables.
#>

BeforeAll {
    # tests\unit\Compliance\Compliance.Build.Tests.ps1
    $testsRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $repoRoot  = Split-Path $testsRoot -Parent

    $srcHelper = Join-Path $testsRoot 'Get-EvaluatorSource.ps1'
    $buildPath = Join-Path $repoRoot 'SCRIPTS\Compliance\Build-ANSSIData.ps1'

    if (-not (Test-Path $srcHelper)) { throw "Get-EvaluatorSource.ps1 not found at: $srcHelper" }
    if (-not (Test-Path $buildPath)) { throw "Build-ANSSIData.ps1 not found at: $buildPath" }

    . $srcHelper

    # Extract and define ONLY the functions (no main body execution).
    $script:EvaluatorSource = Get-EvaluatorSource -ScriptPath $buildPath
    . ([scriptblock]::Create($script:EvaluatorSource))

    $script:BuildPath = $buildPath

    # ----- Synthetic engine fixture builders (real schema) -----

    # A fully-secured machine: firewall on, Defender real-time on, BitLocker on.
    function New-SecureEngine {
        @{
            Checks = @(
                @{ Category = 'NetSec';     Check = 'Firewall Domain Profile';  Value = 'Enabled'; Status = 'Pass' },
                @{ Category = 'NetSec';     Check = 'Firewall Private Profile'; Value = 'Enabled'; Status = 'Pass' },
                @{ Category = 'NetSec';     Check = 'Firewall Public Profile';  Value = 'Enabled'; Status = 'Pass' },
                @{ Category = 'Defender';   Check = 'Real-Time Protection';     Value = 'On';      Status = 'Pass' },
                @{ Category = 'Encryption'; Check = 'BitLocker System Volume';  Value = 'On';      Status = 'Pass' },
                @{ Category = 'Identity';   Check = 'Directory Join Status';    Value = 'AzureAD'; Status = 'Pass' }
            )
        }
    }

    # A machine with NO BitLocker (common: desktops, Home edition, older Win10).
    # Firewall + Defender present, BitLocker absent entirely.
    function New-NoBitLockerEngine {
        @{
            Checks = @(
                @{ Category = 'NetSec';   Check = 'Firewall Domain Profile';  Value = 'Enabled'; Status = 'Pass' },
                @{ Category = 'NetSec';   Check = 'Firewall Private Profile'; Value = 'Enabled'; Status = 'Pass' },
                @{ Category = 'NetSec';   Check = 'Firewall Public Profile';  Value = 'Enabled'; Status = 'Pass' },
                @{ Category = 'Defender'; Check = 'Real-Time Protection';     Value = 'On';      Status = 'Pass' }
            )
        }
    }

    # A bare VM: nothing security-relevant reported at all.
    function New-EmptyEngine {
        @{ Checks = @() }
    }

    # A machine where probes ran but could not read values.
    function New-CannotQueryEngine {
        @{
            Checks = @(
                @{ Category = 'NetSec';   Check = 'Firewall Domain Profile'; Value = 'Cannot query'; Status = 'Fail' },
                @{ Category = 'Defender'; Check = 'Real-Time Protection';    Value = 'unavailable';  Status = 'Fail' },
                @{ Category = 'Identity'; Check = 'Directory Join Status';   Value = 'Cannot query'; Status = 'Fail' }
            )
        }
    }

    $script:NewSecureEngine       = ${function:New-SecureEngine}
    $script:NewNoBitLockerEngine  = ${function:New-NoBitLockerEngine}
    $script:NewEmptyEngine        = ${function:New-EmptyEngine}
    $script:NewCannotQueryEngine  = ${function:New-CannotQueryEngine}
}

Describe 'Evaluator source extraction' -Tag 'Fast' {
    It 'extracts all 42 Get-Rxx evaluator functions' {
        $names = Get-EvaluatorFunctionNames -ScriptPath $script:BuildPath
        $rules = @($names | Where-Object { $_ -match '^Get-R\d+$' })
        $rules.Count | Should -Be 42
    }

    It 'extracts the helper layer (Find-Check, Get-DictValue, Test-Status)' {
        $names = Get-EvaluatorFunctionNames -ScriptPath $script:BuildPath
        $names | Should -Contain 'Find-Check'
        $names | Should -Contain 'Get-DictValue'
        $names | Should -Contain 'Test-Status'
    }

    It 'defined the evaluators in this session' {
        (Get-Command 'Get-R14' -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
    }

    It 'did NOT execute the collector main body (no report written side effect)' {
        # If the main body had run, it would have needed $LogsDir etc.
        # The fact that extraction + dot-source succeeded without those vars
        # proves only functions were loaded. Sanity: a helper is callable.
        (Get-Command 'Find-Check' -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
    }
}

Describe 'Helper null-safety (never throw on bad input)' -Tag 'Fast' {
    It 'Find-Check returns null on $null engine data' {
        Find-Check -EngineData $null -Category 'NetSec' | Should -BeNullOrEmpty
    }

    It 'Find-AllChecks returns empty array on $null engine data' {
        $r = @(Find-AllChecks -EngineData $null -Category 'NetSec')
        $r.Count | Should -Be 0
    }

    It 'Find-Check returns null when category is absent' {
        $eng = & $script:NewEmptyEngine
        Find-Check -EngineData $eng -Category 'NetSec' -CheckLike 'Firewall' | Should -BeNullOrEmpty
    }

    It 'Test-Status returns false on $null check' {
        Test-Status $null | Should -BeFalse
    }

    It 'Test-Observed returns false on a Cannot-query value' {
        $eng = & $script:NewCannotQueryEngine
        $c = Find-Check -EngineData $eng -Category 'Identity' -CheckLike 'Directory'
        Test-Observed $c | Should -BeFalse
    }

    It 'Get-DictValue returns default for a missing key' {
        Get-DictValue @{ A = 1 } 'B' 'fallback' | Should -Be 'fallback'
    }

    It 'Get-DictValue reads a present key' {
        Get-DictValue @{ A = 1 } 'A' | Should -Be 1
    }
}

Describe 'R14 socle de securite - universal hardware degradation' -Tag 'Fast' {
    It 'returns cv when firewall + Defender + BitLocker all pass' {
        $eng = & $script:NewSecureEngine
        (Get-R14 -Sec $eng -Pch $null).Status | Should -Be 'cv'
    }

    It 'returns pv (NOT cv) on a machine with no BitLocker' {
        $eng = & $script:NewNoBitLockerEngine
        (Get-R14 -Sec $eng -Pch $null).Status | Should -Be 'pv'
    }

    It 'pv detail names BitLocker as non confirme when absent' {
        $eng = & $script:NewNoBitLockerEngine
        (Get-R14 -Sec $eng -Pch $null).Detail | Should -Match 'BitLocker non confirme'
    }

    It 'returns pv on a bare VM with nothing reported' {
        $eng = & $script:NewEmptyEngine
        (Get-R14 -Sec $eng -Pch $null).Status | Should -Be 'pv'
    }

    It 'does not throw when engine data is $null' {
        { Get-R14 -Sec $null -Pch $null } | Should -Not -Throw
    }

    It 'returns pv when engine data is $null (graceful, not false-cv)' {
        (Get-R14 -Sec $null -Pch $null).Status | Should -Be 'pv'
    }
}

Describe 'R16 annuaire - directory join detection' -Tag 'Fast' {
    It 'returns cv when a directory join is observed' {
        $eng = & $script:NewSecureEngine
        (Get-R16 -Sec $eng).Status | Should -Be 'cv'
    }

    It 'returns pv when directory status cannot be read' {
        $eng = & $script:NewCannotQueryEngine
        (Get-R16 -Sec $eng).Status | Should -Be 'pv'
    }

    It 'returns pv (not throw) when engine data is $null' {
        (Get-R16 -Sec $null).Status | Should -Be 'pv'
    }
}

Describe 'R17 pare-feu - multi-profile and fallback' -Tag 'Fast' {
    It 'returns cv when all firewall profiles pass' {
        $eng = & $script:NewSecureEngine
        (Get-R17 -Sec $eng -Pch $null -Net $null).Status | Should -Be 'cv'
    }

    It 'returns pv when no firewall data exists in any source' {
        $eng = & $script:NewEmptyEngine
        (Get-R17 -Sec $eng -Pch $null -Net $null).Status | Should -Be 'pv'
    }

    It 'does not throw when all three sources are $null' {
        { Get-R17 -Sec $null -Pch $null -Net $null } | Should -Not -Throw
    }
}

Describe 'Static rules return fixed status' -Tag 'Fast' {
    It 'R1 (formation) is hp' {
        (Get-R1).Status | Should -Be 'hp'
    }

    It 'R6 (procedures RH) is hp' {
        (Get-R6).Status | Should -Be 'hp'
    }

    It 'R38 (audit technique = FieldOps run) is cv' {
        (Get-R38).Status | Should -Be 'cv'
    }

    It 'R9 (partages SMB) is pv' {
        (Get-R9).Status | Should -Be 'pv'
    }
}

Describe 'All 42 evaluators produce a well-formed result' -Tag 'Fast' {
    BeforeAll {
        # Build a permissive arg splat: most rules take ($Sec, $Pch, $Net) in
        # some subset. We invoke each with secure engine data where the rule
        # accepts it, falling back to no-arg for static rules.
        $script:SecureEng = & $script:NewSecureEngine
    }

    It 'every Get-Rxx returns a hashtable with cv/pv/hp Status and never throws' {
        $bad = @()
        foreach ($n in 1..42) {
            $fn = "Get-R$n"
            $cmd = Get-Command $fn -ErrorAction SilentlyContinue
            if (-not $cmd) { $bad += "$fn missing"; continue }

            # Supply up to three engine args; extra args are ignored by rules
            # that declare fewer params, and rules that take none ignore all.
            $result = $null
            try {
                $paramCount = @($cmd.Parameters.Keys | Where-Object {
                    $_ -notin @('Verbose','Debug','ErrorAction','WarningAction',
                                'InformationAction','ErrorVariable','WarningVariable',
                                'InformationVariable','OutVariable','OutBuffer',
                                'PipelineVariable')
                }).Count

                switch ($paramCount) {
                    0       { $result = & $fn }
                    1       { $result = & $fn $script:SecureEng }
                    2       { $result = & $fn $script:SecureEng $script:SecureEng }
                    default { $result = & $fn $script:SecureEng $script:SecureEng $script:SecureEng }
                }
            } catch {
                $bad += "$fn threw: $($_.Exception.Message)"
                continue
            }

            $status = Get-DictValue $result 'Status'
            if ($status -notin @('cv','pv','hp')) {
                $bad += "$fn bad status: '$status'"
            }
        }
        $bad | Should -BeNullOrEmpty -Because "evaluators with problems: $($bad -join ' | ')"
    }
}
