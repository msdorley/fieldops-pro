
# ===========================================================================
# Phase 6.1 (Streams 6.1-R2 / 6.1-R3): ANSSI data tables wired to the bundle
#
# Build-ANSSIData.ps1 previously carried ASCII-stripped French copies of the
# 10 module titles and 42 rule names. Phase 5.2 had already translated all of
# them properly (accents intact, EN translations present) under
# report.anssi.modules.<Roman>.title and report.anssi.rules.<Rn>.name -- the
# data tables were simply never wired to those keys.
#
# These tests lock the wiring: every entry must route through the T() locale
# wrapper, and every key it references must exist in BOTH bundles.
# ===========================================================================

Describe 'ANSSI data tables are wired to the locale bundle (6.1-R2/R3)' -Tag 'Fast' {
    BeforeAll {
        $testsRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $repoRoot  = Split-Path $testsRoot -Parent
        $script:BuildScript = Join-Path $repoRoot 'SCRIPTS\Compliance\Build-ANSSIData.ps1'
        $script:BuildSource = Get-Content $script:BuildScript -Raw
    }

    It 'all 42 rule names route through the locale wrapper' {
        $wired = ([regex]::Matches($script:BuildSource, "T 'report\.anssi\.rules\.R\d+\.name'")).Count
        $wired | Should -Be 42
    }

    It 'all 10 module titles route through the locale wrapper' {
        $wired = ([regex]::Matches($script:BuildSource, "T 'report\.anssi\.modules\.[IVX]+\.title'")).Count
        $wired | Should -Be 10
    }

    It 'no rule entry carries a bare hardcoded Name string' {
        # A wired entry looks like:  Name=(T '...' -Default '...')
        # A regression would reintroduce:  Name='...'
        $bare = [regex]::Matches($script:BuildSource, "Id='R\d+';\s*Mod='[IVX]+';\s*Name='")
        $bare.Count | Should -Be 0
    }

    It 'no module entry carries a bare hardcoded Title string' {
        $bare = [regex]::Matches($script:BuildSource, "Number='[IVX]+';\s*Title='")
        $bare.Count | Should -Be 0
    }

    It 'every wired rule key references R1..R42 with no gaps or duplicates' {
        $ids = [regex]::Matches($script:BuildSource, "T 'report\.anssi\.rules\.(R\d+)\.name'") |
               ForEach-Object { $_.Groups[1].Value }
        $expected = 1..42 | ForEach-Object { "R$_" }
        ($ids | Sort-Object -Unique).Count | Should -Be 42
        (Compare-Object $ids $expected).Count | Should -Be 0
    }

    It 'every wired module key references I..X with no gaps or duplicates' {
        $nums = [regex]::Matches($script:BuildSource, "T 'report\.anssi\.modules\.([IVX]+)\.title'") |
                ForEach-Object { $_.Groups[1].Value }
        $expected = @('I','II','III','IV','V','VI','VII','VIII','IX','X')
        ($nums | Sort-Object -Unique).Count | Should -Be 10
        (Compare-Object $nums $expected).Count | Should -Be 0
    }

    It 'the build script stays ASCII-clean (defaults are the ASCII fallbacks)' {
        $bytes = [System.IO.File]::ReadAllBytes($script:BuildScript)
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }
}

Describe 'Bundle supplies every wired ANSSI key in both locales (6.1-R2/R3)' -Tag 'Fast' {
    BeforeAll {
        $testsRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $repoRoot  = Split-Path $testsRoot -Parent
        $script:LocalePath = Join-Path $repoRoot 'SCRIPTS\Core\FieldOps-Locale.psm1'
        Import-Module $script:LocalePath -Force -DisableNameChecking
    }
    AfterAll {
        Remove-Module 'FieldOps-Locale' -Force -ErrorAction SilentlyContinue
    }

    It 'FR bundle has all 42 rule names, non-empty' {
        Initialize-Locale -Language fr | Out-Null
        $missing = @()
        foreach ($n in 1..42) {
            $v = Get-LocaleString "report.anssi.rules.R$n.name" -Default ''
            if ([string]::IsNullOrWhiteSpace($v)) { $missing += "R$n" }
        }
        $missing -join ',' | Should -Be ''
    }

    It 'EN bundle has all 42 rule names, non-empty' {
        Initialize-Locale -Language en | Out-Null
        $missing = @()
        foreach ($n in 1..42) {
            $v = Get-LocaleString "report.anssi.rules.R$n.name" -Default ''
            if ([string]::IsNullOrWhiteSpace($v)) { $missing += "R$n" }
        }
        $missing -join ',' | Should -Be ''
    }

    It 'FR bundle has all 10 module titles, non-empty' {
        Initialize-Locale -Language fr | Out-Null
        $missing = @()
        foreach ($n in @('I','II','III','IV','V','VI','VII','VIII','IX','X')) {
            $v = Get-LocaleString "report.anssi.modules.$n.title" -Default ''
            if ([string]::IsNullOrWhiteSpace($v)) { $missing += $n }
        }
        $missing -join ',' | Should -Be ''
    }

    It 'EN bundle has all 10 module titles, non-empty' {
        Initialize-Locale -Language en | Out-Null
        $missing = @()
        foreach ($n in @('I','II','III','IV','V','VI','VII','VIII','IX','X')) {
            $v = Get-LocaleString "report.anssi.modules.$n.title" -Default ''
            if ([string]::IsNullOrWhiteSpace($v)) { $missing += $n }
        }
        $missing -join ',' | Should -Be ''
    }

    It 'FR rule names carry French diacritics (proving bundle text, not ASCII fallback)' {
        Initialize-Locale -Language fr | Out-Null
        # R1 canonical FR text contains accented characters
        $r1 = Get-LocaleString 'report.anssi.rules.R1.name' -Default ''
        ($r1.ToCharArray() | Where-Object { [int]$_ -gt 127 }).Count | Should -BeGreaterThan 0
    }

    It 'FR and EN rule names differ (proving EN is translated, not a FR copy)' {
        Initialize-Locale -Language fr | Out-Null
        $fr = Get-LocaleString 'report.anssi.rules.R13.name' -Default ''
        Initialize-Locale -Language en | Out-Null
        $en = Get-LocaleString 'report.anssi.rules.R13.name' -Default ''
        $en | Should -Not -Be $fr
        $en | Should -Not -BeNullOrEmpty
    }
}
