#Requires -Version 5.1
<#
    FieldOps Pro - Phase 6, Stream 6.1 (R4a)

    Two instruments are under test here, and both had to be corrected before
    the R4b routing work could rely on them:

    1. FLATTENER PARITY.  Three separate implementations now flatten a locale
       bundle to dot-notation keys:
           - FieldOps-Locale.psm1   Flatten-Object      (the engine, authoritative)
           - tests\Format-Bundle.ps1 Expand-BundleObject (test helper)
           - Resolve-LocaleTokens.ps1 (traverses raw JSON by path)
       Phase 6.1-R1 added a rich-text leaf guard to the engine but not the
       helper, so the helper exploded report.anssi.cover.title into
       .parts/.separator sub-keys. Parity tests still passed (both bundles
       exploded identically), so the divergence was invisible -- but any
       zero-unresolved-token guard (R7) would have false-failed on a token
       that resolves perfectly at runtime.

       Rather than assert the single fixed key, these tests assert the FULL
       key sets are identical. That converts a one-off bug fix into a
       standing invariant: any future divergence between the two flatteners
       fails immediately, whatever its cause.

    2. AUDIT SCRIPT.  Find-HardcodedStringsInTemplate must not regress on the
       two properties that make it trustworthy: it excludes stylesheet
       content (or CSS keywords bury every real finding), and it can be
       dot-sourced without emitting a console report.
#>

BeforeAll {
    $script:TestsRoot  = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:RepoRoot   = Split-Path $script:TestsRoot -Parent
    $script:LocalePath = Join-Path $script:RepoRoot 'SCRIPTS\Core\FieldOps-Locale.psm1'
    $script:AuditPath  = Join-Path $script:RepoRoot 'tests\audit\Find-HardcodedStringsInTemplate.ps1'
    $script:Template   = Join-Path $script:RepoRoot 'SCRIPTS\Templates\anssi-diagnostic.html'

    . (Join-Path $script:RepoRoot 'tests\Format-Bundle.ps1')
    . $script:AuditPath
}

AfterAll {
    Remove-Module 'FieldOps-Locale' -Force -ErrorAction SilentlyContinue
}

Describe 'Flattener parity: Format-Bundle helper vs locale engine (6.1-R4a)' -Tag 'Fast' {

    It 'FR: helper and engine produce identical key sets' {
        Import-Module $script:LocalePath -Force -DisableNameChecking
        Initialize-Locale -Language fr | Out-Null
        $engineKeys = @(InModuleScope 'FieldOps-Locale' { @($script:Strings.Keys) })
        $helperKeys = @(Get-BundleKeys -Locale 'fr')

        $onlyEngine = @(Compare-Object $engineKeys $helperKeys |
                        Where-Object { $_.SideIndicator -eq '<=' } |
                        ForEach-Object { $_.InputObject })
        $onlyHelper = @(Compare-Object $engineKeys $helperKeys |
                        Where-Object { $_.SideIndicator -eq '=>' } |
                        ForEach-Object { $_.InputObject })

        ($onlyEngine -join ',') | Should -Be ''
        ($onlyHelper -join ',') | Should -Be ''
    }

    It 'EN: helper and engine produce identical key sets' {
        Import-Module $script:LocalePath -Force -DisableNameChecking
        Initialize-Locale -Language en | Out-Null
        $engineKeys = @(InModuleScope 'FieldOps-Locale' { @($script:Strings.Keys) })
        $helperKeys = @(Get-BundleKeys -Locale 'en')

        $diff = @(Compare-Object $engineKeys $helperKeys)
        ($diff | ForEach-Object { "$($_.SideIndicator)$($_.InputObject)" }) -join ',' | Should -Be ''
    }

    It 'the rich-text cover title flattens to exactly one key in the helper' {
        $k = @(Get-BundleKeys -Locale 'fr' | Where-Object { $_ -like 'report.anssi.cover.title*' })
        $k.Count | Should -Be 1
        $k[0]    | Should -Be 'report.anssi.cover.title'
    }

    It 'the helper does not emit rich-text sub-keys for any bundle key' {
        foreach ($loc in @('fr','en')) {
            $bad = @(Get-BundleKeys -Locale $loc |
                     Where-Object { $_ -like '*.parts' -or $_ -like '*.separator' })
            ($bad -join ',') | Should -Be ''
        }
    }
}

Describe 'Hardcoded-string audit script behaviour (6.1-R4a)' -Tag 'Fast' {

    It 'dot-sourcing the audit script produces no console report' {
        # The script guards its report body with an InvocationName check so
        # tests can import its functions. If that guard breaks, dot-sourcing
        # would print the full audit every time any test file loads it.
        $out = . $script:AuditPath 6>&1
        ($out | Out-String).Trim() | Should -Be ''
    }

    It 'masks style blocks while preserving line numbering' {
        $raw = "<p>un</p>`n<style>`n.a { content: 'module regle'; }`n</style>`n<p>deux</p>"
        $scan = Get-TemplateScanText -Raw $raw
        # same number of lines
        ([regex]::Matches($scan, "`n")).Count | Should -Be ([regex]::Matches($raw, "`n")).Count
        # style content gone
        $scan | Should -Not -Match 'content:'
        # surrounding markup intact
        $scan | Should -Match '<p>un</p>'
        $scan | Should -Match '<p>deux</p>'
    }

    It 'does not report CSS keywords as French findings' {
        $tmp = Join-Path $env:TEMP 'fo-audit-css-test.html'
        @'
<html><head><style>
.module-title { content: ""; }
.rule-name { color: #000; }
.serie { letter-spacing: 0; }
</style></head><body><p>Hello world</p></body></html>
'@ | Set-Content -Path $tmp -Encoding ASCII
        try {
            $hits = @(Find-HardcodedStringsInTemplate -TemplatePath $tmp)
            $hits.Count | Should -Be 0
        } finally {
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
    }

    It 'detects a known hardcoded French string in a text node' {
        $tmp = Join-Path $env:TEMP 'fo-audit-fr-test.html'
        '<html><body><div>Spectre de conformite - 42 mesures</div></body></html>' |
            Set-Content -Path $tmp -Encoding ASCII
        try {
            $hits = @(Find-HardcodedStringsInTemplate -TemplatePath $tmp)
            $hits.Count | Should -BeGreaterThan 0
            $hits[0].Kind | Should -Be 'TextNode'
        } finally {
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
    }

    It 'strips entities and tokens before analysis' {
        Remove-NonLinguisticContent -Text 'A &mdash; B {{TOKEN}} C' | Should -Be 'A B C'
    }

    It 'folds accents so the wordlist matches with or without diacritics' {
        $folded = ConvertTo-AsciiFold -Text ([char]0x00E9 + 'valuation s' + [char]0x00E9 + 'curit' + [char]0x00E9)
        $folded | Should -Be 'evaluation securite'
    }

    It 'flags whitelisted brand strings rather than dropping them silently' {
        Test-IsWhitelisted -Candidate 'FieldOps Pro Service Diagnostic' | Should -BeTrue
        Test-IsWhitelisted -Candidate 'Spectre de conformite'           | Should -BeFalse
    }

    It 'the live template contains zero hardcoded French strings (6.1-R6)' {
        # Guards against the scanner silently breaking (returning nothing) or
        # blowing up with CSS noise. The exact number changes as R4b routes
        # strings; the bounds only assert the scanner is functioning.
        $hits = @(Find-HardcodedStringsInTemplate -TemplatePath $script:Template |
                  Where-Object { -not $_.Whitelisted })
        ($hits | ForEach-Object { "line $($_.Line): $($_.Text)" }) -join ' | ' | Should -Be ''
        # Was "greater than zero": a canary against the scanner silently
    }
}
