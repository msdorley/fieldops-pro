#Requires -Version 5.1
<#
    FieldOps Pro - Phase 6, Stream 6.5 (D10 + D16)

    Severity classifier accuracy (6.5-SC-5).

    WHAT MAKES THIS TEST MEANINGFUL

    SC-5 requires <= 10% misclassification on >= 10 labeled fixtures. A fixture
    set of only easy cases would pass while proving nothing, so this corpus is
    hard on purpose:

      - CRITICAL findings phrased calmly, no alarm words
      - ADVISORY findings that contain frightening vocabulary
      - both languages, since AI narration follows the report language
      - the structural-override case and the distress-marker case

    Two assertions, not one. Aggregate accuracy is the SC-5 number, but it can
    hide the one error that endangers a customer: a CRITICAL finding scored
    lower. A second assertion checks that no CRITICAL fixture was classified
    below CRITICAL WITHOUT being flagged for review. A flagged downgrade is
    tolerable -- a human will look. A silent one is not.

    Get-AISeverityClassification is exported, so the fixtures call it directly.
    That also sidesteps the Pester 5.x InModuleScope -Parameters scoping trap.
#>

BeforeAll {
    $script:TestsRoot  = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:RepoRoot   = Split-Path $script:TestsRoot -Parent
    $script:ModulePath = Join-Path $script:RepoRoot 'SCRIPTS\AI\FieldOps-AIClient.psm1'
    Import-Module $script:ModulePath -Force -DisableNameChecking

    # Fixtures are DATA, not code (6.5-D16). They live under
    # tests/fixtures/ai/severity-labeled/ so the evidence behind SC-5 can be
    # reviewed, challenged or extended by someone who does not read PowerShell.
    # That matters here specifically: roughly half the cases are French-language
    # classification, and the person best placed to judge those is not
    # necessarily the person maintaining this harness.
    #
    # Every *.json in the directory is loaded, so adding a file adds cases
    # without touching this test.
    $script:FixtureDir = Join-Path $script:TestsRoot 'fixtures\ai\severity-labeled'

    $script:Fixtures = @()
    $script:FixtureFiles = @(Get-ChildItem -Path $script:FixtureDir -Filter '*.json' -File -ErrorAction SilentlyContinue)
    foreach ($file in $script:FixtureFiles) {
        try {
            $loaded = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch {
            throw "Severity fixture file '$($file.Name)' is not valid JSON: $_"
        }
        foreach ($rec in @($loaded)) {
            $script:Fixtures += @{
                lang   = [string]$rec.lang
                expect = [string]$rec.expect
                text   = [string]$rec.text
                note   = [string]$rec.note
                source = $file.Name
            }
        }
    }

    function Test-FixtureSet {
        param($Fixtures)
        $results = @()
        foreach ($f in $Fixtures) {
            $c = Get-AISeverityClassification -Text $f.text
            $results += [PSCustomObject]@{
                Expect  = $f.expect
                Actual  = $c.Severity
                Review  = $c.NeedsHumanReview
                Correct = ($c.Severity -eq $f.expect)
                Note    = $f.note
            }
        }
        return $results
    }
}

AfterAll {
    Remove-Module 'FieldOps-AIClient' -Force -ErrorAction SilentlyContinue
}

Describe 'Severity classifier accuracy on labeled fixtures (6.5-SC-5)' -Tag 'Fast' {

    It 'loads fixtures from disk rather than from this file' {
        # Guards the D16 externalisation. If the directory vanishes or the glob
        # stops matching, the accuracy assertions below would pass vacuously on
        # an empty set -- a green suite proving nothing.
        Test-Path $script:FixtureDir      | Should -BeTrue
        @($script:FixtureFiles).Count     | Should -BeGreaterThan 0
    }

    It 'has at least 10 labeled fixtures' {
        @($script:Fixtures).Count | Should -BeGreaterOrEqual 10
    }

    It 'every fixture record is complete and well-formed' {
        # A record missing 'expect' would be silently counted as a pass by the
        # comparison below, quietly inflating the accuracy figure.
        $levels = @('INFORMATIONAL','ADVISORY','ACTION_REQUIRED','CRITICAL')
        foreach ($f in $script:Fixtures) {
            $f.text   | Should -Not -BeNullOrEmpty -Because "a fixture in $($f.source) has no text"
            $f.note   | Should -Not -BeNullOrEmpty -Because "a fixture in $($f.source) has no note explaining why it exists"
            $f.lang   | Should -BeIn @('en','fr')  -Because "a fixture in $($f.source) has lang '$($f.lang)'"
            $levels   | Should -Contain $f.expect  -Because "a fixture in $($f.source) expects '$($f.expect)'"
        }
    }

    It 'covers all four severity levels' {
        $levels = @($script:Fixtures | ForEach-Object { $_.expect } | Sort-Object -Unique)
        foreach ($l in @('INFORMATIONAL','ADVISORY','ACTION_REQUIRED','CRITICAL')) {
            $levels | Should -Contain $l
        }
    }

    It 'includes fixtures in both languages' {
        $langs = @($script:Fixtures | ForEach-Object { $_.lang } | Sort-Object -Unique)
        $langs | Should -Contain 'en'
        $langs | Should -Contain 'fr'
    }

    It 'misclassifies no more than 10 percent of fixtures' {
        $results = Test-FixtureSet -Fixtures $script:Fixtures
        $total = @($results).Count
        $wrong = @($results | Where-Object { -not $_.Correct })

        if ($wrong.Count -gt 0) {
            $detail = ($wrong | ForEach-Object { "[$($_.Expect)->$($_.Actual)] $($_.Note)" }) -join ' | '
            Write-Host "  misclassified: $detail"
        }

        $rate = $wrong.Count / [double]$total
        $rate | Should -BeLessOrEqual 0.10
    }

    It 'never downgrades a CRITICAL fixture below CRITICAL without flagging review' {
        $results = Test-FixtureSet -Fixtures $script:Fixtures
        $silent = @($results | Where-Object {
            $_.Expect -eq 'CRITICAL' -and $_.Actual -ne 'CRITICAL' -and -not $_.Review
        })
        ($silent | ForEach-Object { $_.Note }) -join ' | ' | Should -Be ''
    }

    It 'classifies the structural-override fixture by the structural method' {
        $c = Get-AISeverityClassification -Text "Severity: CRITICAL`nmild body text"
        $c.Severity | Should -Be 'CRITICAL'
        $c.Method   | Should -Be 'structural'
    }
}

Describe 'Severity classifier degradation (6.5-R10)' -Tag 'Fast' {

    It 'defaults to ADVISORY and flags review when the keyword config is unreadable' {
        $bogus = Join-Path $env:TEMP ('fo-nosev-' + [guid]::NewGuid().ToString('N'))
        $c = Get-AISeverityClassification -Text 'some finding text with no structural line' -ConfigDir $bogus
        $c.Severity         | Should -Be 'ADVISORY'
        $c.NeedsHumanReview | Should -BeTrue
    }

    It 'flags review on an empty response rather than asserting a severity' {
        $c = Get-AISeverityClassification -Text ''
        $c.NeedsHumanReview | Should -BeTrue
    }
}
