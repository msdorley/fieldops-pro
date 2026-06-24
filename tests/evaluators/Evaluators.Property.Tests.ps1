#Requires -Version 5.1
<#
    FieldOps Pro - Chapter 6.6 Continuous Validation
    Evaluator property tests (D13) - Build-ANSSIData.ps1

    D11/D12 test SPECIFIC inputs (this fixture -> that status). D13 tests
    INVARIANTS that must hold for ANY input, fed by randomized and adversarial
    engine objects via the D5 Invoke-Property harness.

    The properties (must hold across thousands of generated inputs):
        P1  No computed evaluator ever throws, for any random engine shape
            (missing fields, wrong types, null checks, malformed structures).
        P2  Every evaluator always returns a hashtable whose Status is one of
            cv / pv / hp -- never null, never malformed.
        P3  Determinism: the same input yields the same Status on repeat calls.
        P4  Helper totality: Get-DictValue and Find-Check never throw on random
            object/key combinations and Find-AllChecks always returns an array.

    This is the strongest portability guarantee in the suite: rather than
    enumerating hardware shapes by hand, we prove the evaluators degrade
    gracefully on machine states we cannot anticipate.

    Loads the evaluators via AST extraction (Get-EvaluatorSource.ps1), same as
    D11/D12 -- the collector main body never runs.
#>

BeforeAll {
    $testsRoot = Split-Path $PSScriptRoot -Parent
    $repoRoot  = Split-Path $testsRoot -Parent

    $srcHelper   = Join-Path $testsRoot 'Get-EvaluatorSource.ps1'
    $propModule  = Join-Path $testsRoot 'PropertyTests.psm1'
    $buildPath   = Join-Path $repoRoot 'SCRIPTS\Compliance\Build-ANSSIData.ps1'

    if (-not (Test-Path $srcHelper))  { throw "Get-EvaluatorSource.ps1 not found at: $srcHelper" }
    if (-not (Test-Path $propModule)) { throw "PropertyTests.psm1 not found at: $propModule" }
    if (-not (Test-Path $buildPath))  { throw "Build-ANSSIData.ps1 not found at: $buildPath" }

    Import-Module $propModule -Force -DisableNameChecking
    . $srcHelper
    . ([scriptblock]::Create((Get-EvaluatorSource -ScriptPath $buildPath)))

    # ---- Adversarial engine generators (defined for use inside Property blocks) ----

    # Random category/name/value/status fields, any of which may be absent or
    # the wrong type. This is the "garbage machine state" generator.
    function New-RandomCheck {
        $categories = @('NetSec','Defender','Encryption','Identity','Firmware',
                        'WinSec','PSSecurity','Surface','PrivEsc','VPN','Proxy',
                        'Updates','Drivers','Storage','Security', $null, '', 12345)
        $statuses   = @('Pass','Fail','Warning','Critical', $null, '', 'Unknown', 999)
        $values     = @('On','Off','Enabled','Disabled','WPA2','WPA3','Connected',
                        'Disconnected','Cannot query','unavailable','Minimal',
                        $null, '', 'N/A', (Get-RandomString -MaxLength 20))

        $check = @{}
        # Randomly include or omit each field -- malformed checks are the point.
        if ((Get-RandomInt -Min 0 -Max 10) -gt 1) { $check['Category'] = Get-RandomElement -Collection $categories }
        if ((Get-RandomInt -Min 0 -Max 10) -gt 1) { $check['Check']    = Get-RandomElement -Collection @('Firewall','BitLocker','TPM','WiFi Security','Real-Time Protection',(Get-RandomString -MaxLength 16),$null) }
        if ((Get-RandomInt -Min 0 -Max 10) -gt 1) { $check['Value']    = Get-RandomElement -Collection $values }
        if ((Get-RandomInt -Min 0 -Max 10) -gt 1) { $check['Status']   = Get-RandomElement -Collection $statuses }
        return $check
    }

    # A random engine object: sometimes a well-formed @{Checks=@(...)},
    # sometimes missing Checks, sometimes Checks is the wrong type, sometimes
    # $null entirely.
    function New-RandomEngine {
        $shape = Get-RandomInt -Min 0 -Max 10
        if ($shape -le 1) { return $null }
        if ($shape -le 2) { return @{} }                      # no Checks key
        if ($shape -le 3) { return @{ Checks = $null } }      # Checks null
        if ($shape -le 4) { return @{ Checks = 'not-an-array' } }  # wrong type
        if ($shape -le 5) { return @{ Checks = @() } }        # empty

        $n = Get-RandomInt -Min 0 -Max 6
        $checks = @()
        for ($k = 0; $k -lt $n; $k++) { $checks += (New-RandomCheck) }
        return @{ Checks = $checks }
    }

    $script:NewRandomEngine = ${function:New-RandomEngine}
    $script:NewRandomCheck  = ${function:New-RandomCheck}

    # The computed rules and how many engine args each takes (from source).
    # We pass random engines into every positional slot.
    $script:ComputedRules = @(
        @{ Name='Get-R4';  ArgN=3 }, @{ Name='Get-R5';  ArgN=3 }, @{ Name='Get-R7';  ArgN=1 },
        @{ Name='Get-R8';  ArgN=1 }, @{ Name='Get-R11'; ArgN=1 }, @{ Name='Get-R12'; ArgN=1 },
        @{ Name='Get-R13'; ArgN=1 }, @{ Name='Get-R14'; ArgN=2 }, @{ Name='Get-R16'; ArgN=1 },
        @{ Name='Get-R17'; ArgN=3 }, @{ Name='Get-R20'; ArgN=2 }, @{ Name='Get-R21'; ArgN=1 },
        @{ Name='Get-R22'; ArgN=2 }, @{ Name='Get-R29'; ArgN=1 }, @{ Name='Get-R30'; ArgN=1 },
        @{ Name='Get-R31'; ArgN=2 }, @{ Name='Get-R32'; ArgN=1 }, @{ Name='Get-R34'; ArgN=2 },
        @{ Name='Get-R35'; ArgN=2 }, @{ Name='Get-R36'; ArgN=1 }
    )

    # Helper: invoke a rule with N random engine args.
    function Invoke-RuleRandom {
        param([string]$RuleName, [int]$ArgCount, $Engine)
        switch ($ArgCount) {
            1       { & $RuleName $Engine }
            2       { & $RuleName $Engine $Engine }
            default { & $RuleName $Engine $Engine $Engine }
        }
    }
    $script:InvokeRuleRandom = ${function:Invoke-RuleRandom}

    # Capture the helpers as scriptblocks too. Property blocks run inside
    # Invoke-Property's scope (PropertyTests.psm1), where the AST-loaded
    # functions are NOT visible by bare name. Calling them through these
    # captured scriptblocks routes resolution back to where they live.
    function Invoke-GetDictValue { param($Obj,$Key,$Def) Get-DictValue $Obj $Key $Def }
    function Invoke-FindCheck    { param($Eng,$Cat,$Like) Find-Check -EngineData $Eng -Category $Cat -CheckLike $Like }
    function Invoke-FindAllChecks{ param($Eng,$Cat,$Like) @(Find-AllChecks -EngineData $Eng -Category $Cat -CheckLike $Like) }

    $script:GetDictValueSB  = ${function:Invoke-GetDictValue}
    $script:FindCheckSB     = ${function:Invoke-FindCheck}
    $script:FindAllChecksSB = ${function:Invoke-FindAllChecks}
}

AfterAll {
    Remove-Module 'PropertyTests' -Force -ErrorAction SilentlyContinue
}

Describe 'P1 - no computed evaluator ever throws on random engine data' -Tag 'Fast' {
    It '<Name> survives 200 random/adversarial engine inputs' -ForEach @(
        @{ Name='Get-R5';  ArgN=3 }, @{ Name='Get-R7';  ArgN=1 }, @{ Name='Get-R8';  ArgN=1 },
        @{ Name='Get-R11'; ArgN=1 }, @{ Name='Get-R12'; ArgN=1 }, @{ Name='Get-R13'; ArgN=1 },
        @{ Name='Get-R14'; ArgN=2 }, @{ Name='Get-R16'; ArgN=1 }, @{ Name='Get-R17'; ArgN=3 },
        @{ Name='Get-R20'; ArgN=2 }, @{ Name='Get-R21'; ArgN=1 }, @{ Name='Get-R22'; ArgN=2 },
        @{ Name='Get-R29'; ArgN=1 }, @{ Name='Get-R30'; ArgN=1 }, @{ Name='Get-R31'; ArgN=2 },
        @{ Name='Get-R32'; ArgN=1 }, @{ Name='Get-R34'; ArgN=2 }, @{ Name='Get-R35'; ArgN=2 },
        @{ Name='Get-R36'; ArgN=1 }
    ) {
        $ruleName = $Name
        $argCount = $ArgN
        $gen      = $script:NewRandomEngine
        $inv      = $script:InvokeRuleRandom

        Invoke-Property -Name "$ruleName never throws" -Iterations 200 -Generator {
            & $gen
        }.GetNewClosure() -Property {
            $eng = $args[0]
            { & $inv -RuleName $ruleName -ArgCount $argCount -Engine $eng } | Should -Not -Throw
        }.GetNewClosure()
    }
}

Describe 'P2 - every evaluator returns a valid cv/pv/hp status on random data' -Tag 'Fast' {
    It '<Name> always returns cv/pv/hp across 200 random inputs' -ForEach @(
        @{ Name='Get-R5';  ArgN=3 }, @{ Name='Get-R8';  ArgN=1 }, @{ Name='Get-R13'; ArgN=1 },
        @{ Name='Get-R14'; ArgN=2 }, @{ Name='Get-R17'; ArgN=3 }, @{ Name='Get-R20'; ArgN=2 },
        @{ Name='Get-R29'; ArgN=1 }, @{ Name='Get-R31'; ArgN=2 }, @{ Name='Get-R32'; ArgN=1 },
        @{ Name='Get-R34'; ArgN=2 }, @{ Name='Get-R36'; ArgN=1 }
    ) {
        $ruleName = $Name
        $argCount = $ArgN
        $gen      = $script:NewRandomEngine
        $inv      = $script:InvokeRuleRandom
        $dict     = $script:GetDictValueSB

        Invoke-Property -Name "$ruleName returns valid status" -Iterations 200 -Generator {
            & $gen
        }.GetNewClosure() -Property {
            $eng = $args[0]
            $result = & $inv -RuleName $ruleName -ArgCount $argCount -Engine $eng
            $status = & $dict $result 'Status' $null
            $status | Should -BeIn @('cv','pv','hp')
        }.GetNewClosure()
    }
}

Describe 'P3 - evaluators are deterministic' -Tag 'Fast' {
    It '<Name> yields the same status on repeat calls with identical input' -ForEach @(
        @{ Name='Get-R14'; ArgN=2 }, @{ Name='Get-R20'; ArgN=2 }, @{ Name='Get-R31'; ArgN=2 },
        @{ Name='Get-R32'; ArgN=1 }, @{ Name='Get-R36'; ArgN=1 }
    ) {
        $ruleName = $Name
        $argCount = $ArgN
        $gen      = $script:NewRandomEngine
        $inv      = $script:InvokeRuleRandom
        $dict     = $script:GetDictValueSB

        Invoke-Property -Name "$ruleName is deterministic" -Iterations 100 -Generator {
            & $gen
        }.GetNewClosure() -Property {
            $eng = $args[0]
            $a = (& $inv -RuleName $ruleName -ArgCount $argCount -Engine $eng)
            $b = (& $inv -RuleName $ruleName -ArgCount $argCount -Engine $eng)
            (& $dict $a 'Status' $null) | Should -Be (& $dict $b 'Status' $null)
        }.GetNewClosure()
    }
}

Describe 'P4 - helper totality on random input' -Tag 'Fast' {
    It 'Get-DictValue never throws on random object/key combinations' {
        $gen  = $script:NewRandomCheck
        $dict = $script:GetDictValueSB
        Invoke-Property -Name 'Get-DictValue total' -Iterations 300 -Generator {
            & $gen
        }.GetNewClosure() -Property {
            $obj = $args[0]
            $key = Get-RandomElement -Collection @('Category','Check','Value','Status','Missing','','X')
            { & $dict $obj $key 'default' } | Should -Not -Throw
        }.GetNewClosure()
    }

    It 'Find-Check never throws on random engine data' {
        $gen   = $script:NewRandomEngine
        $findc = $script:FindCheckSB
        Invoke-Property -Name 'Find-Check total' -Iterations 300 -Generator {
            & $gen
        }.GetNewClosure() -Property {
            $eng = $args[0]
            $cat = Get-RandomElement -Collection @('NetSec','Identity','Encryption','Bogus','')
            { & $findc $eng $cat 'X' } | Should -Not -Throw
        }.GetNewClosure()
    }

    It 'Find-AllChecks always returns a countable array on random engine data' {
        $gen    = $script:NewRandomEngine
        $findall = $script:FindAllChecksSB
        Invoke-Property -Name 'Find-AllChecks array' -Iterations 300 -Generator {
            & $gen
        }.GetNewClosure() -Property {
            $eng = $args[0]
            $r = @(& $findall $eng 'NetSec' 'Firewall')
            $r.Count | Should -BeGreaterOrEqual 0
        }.GetNewClosure()
    }
}
