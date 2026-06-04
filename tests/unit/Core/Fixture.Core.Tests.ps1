#Requires -Version 5.1
<#
    FieldOps Pro - Chapter 6.6 Continuous Validation
    Unit tests for tests\Get-Fixture.ps1 (D6)

    Coverage:
        Get-Fixture         -- loads valid fixture, error on missing
        Get-FixtureNames    -- lists all available variants
        Get-FixturePath     -- resolves path without loading
        Fixture schema      -- nominal fixture has correct shape
#>

BeforeAll {
    # This file: tests\unit\Core\Fixture.Core.Tests.ps1
    $testsRoot   = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $fixtureScript = Join-Path $testsRoot 'Get-Fixture.ps1'
    $fixturesDir   = Join-Path $testsRoot 'fixtures'

    if (-not (Test-Path $fixtureScript)) {
        throw "Get-Fixture.ps1 not found at: $fixtureScript"
    }

    . $fixtureScript
}

Describe 'Get-Fixture' -Tag 'Fast' {
    It 'loads the nominal fixture without throwing' {
        { Get-Fixture -Name 'nominal' } | Should -Not -Throw
    }

    It 'returns a PSCustomObject' {
        $result = Get-Fixture -Name 'nominal'
        $result | Should -BeOfType [System.Management.Automation.PSCustomObject]
    }

    It 'throws a descriptive error for a missing fixture' {
        { Get-Fixture -Name 'does-not-exist-xyz' } | Should -Throw
    }

    It 'error message for missing fixture includes the fixture name' {
        try {
            Get-Fixture -Name 'no-such-fixture'
        } catch {
            $_.Exception.Message | Should -Match 'no-such-fixture'
        }
    }

    It 'error message for missing fixture lists available fixtures' {
        try {
            Get-Fixture -Name 'no-such-fixture'
        } catch {
            $_.Exception.Message | Should -Match 'nominal'
        }
    }

    It 'loads all-cv fixture' {
        { Get-Fixture -Name 'all-cv' } | Should -Not -Throw
    }

    It 'loads all-hp fixture' {
        { Get-Fixture -Name 'all-hp' } | Should -Not -Throw
    }

    It 'loads missing-summary fixture' {
        { Get-Fixture -Name 'missing-summary' } | Should -Not -Throw
    }
}

Describe 'Get-FixtureNames' -Tag 'Fast' {
    It 'returns an array' {
        $result = Get-FixtureNames
        $result | Should -Not -BeNullOrEmpty
        @($result).Count | Should -BeGreaterThan 0
    }

    It 'includes nominal in the list' {
        $names = Get-FixtureNames
        $names | Should -Contain 'nominal'
    }

    It 'includes all-cv in the list' {
        $names = Get-FixtureNames
        $names | Should -Contain 'all-cv'
    }

    It 'returns at least 20 fixtures' {
        @(Get-FixtureNames).Count | Should -BeGreaterOrEqual 20
    }

    It 'returns sorted names' {
        $names = @(Get-FixtureNames)
        $sorted = @($names | Sort-Object)
        $names -join ',' | Should -Be ($sorted -join ',')
    }
}

Describe 'Get-FixturePath' -Tag 'Fast' {
    It 'resolves a path for the nominal fixture' {
        $path = Get-FixturePath -Name 'nominal'
        $path | Should -Not -BeNullOrEmpty
    }

    It 'returned path ends with the correct filename' {
        $path = Get-FixturePath -Name 'nominal'
        $path | Should -Match 'report-data\.nominal\.json$'
    }

    It 'returned path points to an existing file' {
        $path = Get-FixturePath -Name 'nominal'
        Test-Path $path | Should -BeTrue
    }

    It 'throws for a missing fixture' {
        { Get-FixturePath -Name 'no-such-fixture' } | Should -Throw
    }
}

Describe 'Nominal fixture schema' -Tag 'Fast' {
    BeforeAll {
        $script:Data = Get-Fixture -Name 'nominal'
    }

    It 'has a Report block' {
        $script:Data.Report | Should -Not -BeNullOrEmpty
    }

    It 'has a Machine block' {
        $script:Data.Machine | Should -Not -BeNullOrEmpty
    }

    It 'has a Summary block' {
        $script:Data.Summary | Should -Not -BeNullOrEmpty
    }

    It 'has a TopFindings array' {
        $script:Data.TopFindings | Should -Not -BeNullOrEmpty
    }

    It 'has a Modules array' {
        $script:Data.Modules | Should -Not -BeNullOrEmpty
    }

    It 'has a ModuleDetails array' {
        $script:Data.ModuleDetails | Should -Not -BeNullOrEmpty
    }

    It 'Summary.Total is 42' {
        $script:Data.Summary.Total | Should -Be 42
    }

    It 'CV + PV + HP counts sum to 42' {
        $sum = $script:Data.Summary.CountCV +
               $script:Data.Summary.CountPV +
               $script:Data.Summary.CountHP
        $sum | Should -Be 42
    }

    It 'CountCV is 7' {
        $script:Data.Summary.CountCV | Should -Be 7
    }

    It 'CountPV is 19' {
        $script:Data.Summary.CountPV | Should -Be 19
    }

    It 'CountHP is 16' {
        $script:Data.Summary.CountHP | Should -Be 16
    }

    It 'has exactly 10 modules' {
        @($script:Data.Modules).Count | Should -Be 10
    }

    It 'has exactly 10 ModuleDetails entries' {
        @($script:Data.ModuleDetails).Count | Should -Be 10
    }

    It 'ModuleDetails contains 42 rules total' {
        $total = ($script:Data.ModuleDetails |
            ForEach-Object { @($_.Rules).Count } |
            Measure-Object -Sum).Sum
        $total | Should -Be 42
    }

    It 'TopFindings has exactly 3 entries' {
        @($script:Data.TopFindings).Count | Should -Be 3
    }

    It 'every rule has an Id field' {
        $rules = $script:Data.ModuleDetails | ForEach-Object { $_.Rules }
        $rules | ForEach-Object { $_.Id | Should -Not -BeNullOrEmpty }
    }

    It 'every rule Status is cv, pv, or hp' {
        $rules = $script:Data.ModuleDetails | ForEach-Object { $_.Rules }
        $rules | ForEach-Object {
            $_.Status | Should -BeIn @('cv', 'pv', 'hp')
        }
    }

    It 'Report.Id matches expected pattern' {
        $script:Data.Report.Id | Should -Match '^FOPS-\d{8}-\w+-\d{3}$'
    }

    It 'Machine.Hostname is not empty' {
        $script:Data.Machine.Hostname | Should -Not -BeNullOrEmpty
    }
}
