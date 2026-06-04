#Requires -Version 5.1
<#
    FieldOps Pro - Chapter 6.6 Continuous Validation
    Summary block invariant tests across all non-schema-breaking fixtures.

    These tests run every fixture that contains a Summary block and assert
    that the counts are internally consistent.  This catches regressions in
    Build-ANSSIData.ps1 where counter logic drifts from the actual rule
    evaluations.

    Fixtures with intentionally missing Summary (missing-summary) are
    excluded from these tests -- they are covered in Fixture.Core.Tests.ps1.
#>

BeforeAll {
    $testsRoot     = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $fixtureScript = Join-Path $testsRoot 'Get-Fixture.ps1'

    if (-not (Test-Path $fixtureScript)) {
        throw "Get-Fixture.ps1 not found at: $fixtureScript"
    }

    . $fixtureScript

    # Load all fixtures that have a Summary block
    $allNames = Get-FixtureNames
    $script:FixturesWithSummary = @(
        $allNames |
        Where-Object { $_ -ne 'missing-summary' } |
        ForEach-Object {
            $d = Get-Fixture -Name $_
            if ($null -ne $d.Summary) {
                [PSCustomObject]@{ Name = $_; Data = $d }
            }
        }
    )
}

Describe 'Summary block invariants across fixtures' -Tag 'Fast' {
    It '<_.Name>: CountCV + CountPV + CountHP equals Total' -ForEach $script:FixturesWithSummary {
        $s = $_.Data.Summary
        ($s.CountCV + $s.CountPV + $s.CountHP) | Should -Be $s.Total
    }

    It '<_.Name>: Total is non-negative' -ForEach $script:FixturesWithSummary {
        $_.Data.Summary.Total | Should -BeGreaterOrEqual 0
    }

    It '<_.Name>: CountCV is non-negative' -ForEach $script:FixturesWithSummary {
        $_.Data.Summary.CountCV | Should -BeGreaterOrEqual 0
    }

    It '<_.Name>: CountPV is non-negative' -ForEach $script:FixturesWithSummary {
        $_.Data.Summary.CountPV | Should -BeGreaterOrEqual 0
    }

    It '<_.Name>: CountHP is non-negative' -ForEach $script:FixturesWithSummary {
        $_.Data.Summary.CountHP | Should -BeGreaterOrEqual 0
    }
}

Describe 'ModuleDetails rule count matches Modules RuleCount' -Tag 'Fast' {
    BeforeAll {
        # Use nominal only for structural consistency check
        $script:Nominal = Get-Fixture -Name 'nominal'
    }

    It 'each module RuleCount matches actual Rules array length' {
        foreach ($mod in $script:Nominal.Modules) {
            $detail = $script:Nominal.ModuleDetails |
                Where-Object { $_.Number -eq $mod.Number }
            if ($null -ne $detail) {
                @($detail.Rules).Count | Should -Be $mod.RuleCount -Because "module $($mod.Number) RuleCount"
            }
        }
    }

    It 'each module Counts.Cv + Pv + Hp equals RuleCount' {
        foreach ($mod in $script:Nominal.Modules) {
            $sum = $mod.Counts.Cv + $mod.Counts.Pv + $mod.Counts.Hp
            $sum | Should -Be $mod.RuleCount -Because "module $($mod.Number) counts"
        }
    }
}

Describe 'all-cv fixture invariants' -Tag 'Fast' {
    BeforeAll {
        $script:AllCV = Get-Fixture -Name 'all-cv'
    }

    It 'CountPV is 0' {
        $script:AllCV.Summary.CountPV | Should -Be 0
    }

    It 'CountHP is 0' {
        $script:AllCV.Summary.CountHP | Should -Be 0
    }

    It 'all rules have Status cv' {
        $rules = $script:AllCV.ModuleDetails | ForEach-Object { $_.Rules }
        $rules | ForEach-Object { $_.Status | Should -Be 'cv' }
    }
}

Describe 'all-hp fixture invariants' -Tag 'Fast' {
    BeforeAll {
        $script:AllHP = Get-Fixture -Name 'all-hp'
    }

    It 'CountCV is 0' {
        $script:AllHP.Summary.CountCV | Should -Be 0
    }

    It 'CountPV is 0' {
        $script:AllHP.Summary.CountPV | Should -Be 0
    }

    It 'TopFindings is empty' {
        @($script:AllHP.TopFindings).Count | Should -Be 0
    }
}

Describe 'edge case fixtures are loadable and non-null' -Tag 'Fast' {
    $edgeCases = @(
        'empty-modules', 'empty-topfindings', 'single-module',
        'single-rule', 'null-meta', 'empty-meta', 'long-meta',
        'unicode-meta', 'future-date', 'minimal'
    )

    It '<_> loads without error' -ForEach $edgeCases {
        { Get-Fixture -Name $_ } | Should -Not -Throw
    }

    It '<_> returns non-null object' -ForEach $edgeCases {
        $d = Get-Fixture -Name $_
        $d | Should -Not -BeNullOrEmpty
    }
}
