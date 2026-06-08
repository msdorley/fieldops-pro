#Requires -Version 5.1
<#
    FieldOps Pro - Chapter 6.6 Continuous Validation
    Locale bundle tests (D10) - structural integrity and EN/FR parity.

    Uses tests\Format-Bundle.ps1 (D7) to flatten and compare bundles.

    Coverage:
        - Both bundles load and flatten without error
        - EN and FR have identical key sets (zero drift) -- the core invariant
        - Every key has a non-empty value in both locales
        - _meta block is present and correct in both
        - Known structural keys exist (common.*, report.anssi.*, dashboard.*)

    The parity test is the load-bearing one: if a developer adds a key to
    en.json without adding it to fr.json (or vice versa), this fails and
    names the missing keys. This directly guards the 6.1 Locale Routing work.
#>

BeforeAll {
    # This file: tests\unit\Locale\Bundle.Locale.Tests.ps1
    $testsRoot     = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $bundleScript  = Join-Path $testsRoot 'Format-Bundle.ps1'

    if (-not (Test-Path $bundleScript)) {
        throw "Format-Bundle.ps1 not found at: $bundleScript"
    }

    . $bundleScript
}

Describe 'Bundle loading' -Tag 'Fast' {
    It 'EN bundle loads and returns keys' {
        $keys = Get-BundleKeys -Locale 'en'
        @($keys).Count | Should -BeGreaterThan 0
    }

    It 'FR bundle loads and returns keys' {
        $keys = Get-BundleKeys -Locale 'fr'
        @($keys).Count | Should -BeGreaterThan 0
    }

    It 'EN bundle has a substantial key count (>= 500)' {
        @(Get-BundleKeys -Locale 'en').Count | Should -BeGreaterOrEqual 500
    }
}

Describe 'EN/FR parity (zero drift)' -Tag 'Fast' {
    BeforeAll {
        $script:Diff    = Compare-BundleKeys -BaseLocale 'en' -CompareLocale 'fr'
        $script:EnCount = @(Get-BundleKeys -Locale 'en').Count
        $script:FrCount = @(Get-BundleKeys -Locale 'fr').Count
    }

    It 'EN and FR have the same number of keys' {
        $script:FrCount | Should -Be $script:EnCount
    }

    It 'no keys exist only in EN (FR is not missing any)' {
        # If this fails, the listed keys are in en.json but absent from fr.json
        $script:Diff.OnlyInBase | Should -BeNullOrEmpty -Because (
            "FR is missing: $($script:Diff.OnlyInBase -join ', ')"
        )
    }

    It 'no keys exist only in FR (EN is not missing any)' {
        $script:Diff.OnlyInCompare | Should -BeNullOrEmpty -Because (
            "EN is missing: $($script:Diff.OnlyInCompare -join ', ')"
        )
    }
}

Describe 'Meta block integrity' -Tag 'Fast' {
    It 'EN declares language code en' {
        Get-BundleValue -Key '_meta.code' -Locale 'en' | Should -Be 'en'
    }

    It 'FR declares language code fr' {
        Get-BundleValue -Key '_meta.code' -Locale 'fr' | Should -Be 'fr'
    }

    It 'EN declares ltr direction' {
        Get-BundleValue -Key '_meta.direction' -Locale 'en' | Should -Be 'ltr'
    }

    It 'FR declares ltr direction' {
        Get-BundleValue -Key '_meta.direction' -Locale 'fr' | Should -Be 'ltr'
    }

    It 'both bundles declare a version' {
        Get-BundleValue -Key '_meta.version' -Locale 'en' | Should -Not -BeNullOrEmpty
        Get-BundleValue -Key '_meta.version' -Locale 'fr' | Should -Not -BeNullOrEmpty
    }
}

Describe 'Known structural keys present' -Tag 'Fast' {
    BeforeAll {
        $script:EnKeys = Get-BundleKeys -Locale 'en'
    }

    It 'has common.appName' {
        $script:EnKeys | Should -Contain 'common.appName'
    }

    It 'has common.error' {
        $script:EnKeys | Should -Contain 'common.error'
    }

    It 'has common.pass and common.fail' {
        $script:EnKeys | Should -Contain 'common.pass'
        $script:EnKeys | Should -Contain 'common.fail'
    }

    It 'has at least one report.anssi key' {
        $anssi = @($script:EnKeys | Where-Object { $_ -like 'report.anssi.*' })
        $anssi.Count | Should -BeGreaterThan 0
    }

    It 'has at least one dashboard key' {
        $dash = @($script:EnKeys | Where-Object { $_ -like 'dashboard.*' })
        $dash.Count | Should -BeGreaterThan 0
    }
}

Describe 'No empty values' -Tag 'Fast' {
    BeforeAll {
        # Flatten each bundle exactly once (O(n)) instead of calling
        # Get-BundleValue per key (which re-reads the file each time, O(n^2)
        # disk I/O that pushed these two tests past 7 minutes combined).
        $script:EnMap = Get-BundleMap -Locale 'en'
        $script:FrMap = Get-BundleMap -Locale 'fr'
    }

    It 'no EN key has an empty value' {
        $empty = @($script:EnMap.GetEnumerator() |
            Where-Object { $null -eq $_.Value -or $_.Value -eq '' } |
            ForEach-Object { $_.Key } |
            Sort-Object)
        $empty | Should -BeNullOrEmpty -Because "EN keys with empty values: $($empty -join ', ')"
    }

    It 'no FR key has an empty value' {
        $empty = @($script:FrMap.GetEnumerator() |
            Where-Object { $null -eq $_.Value -or $_.Value -eq '' } |
            ForEach-Object { $_.Key } |
            Sort-Object)
        $empty | Should -BeNullOrEmpty -Because "FR keys with empty values: $($empty -join ', ')"
    }
}
