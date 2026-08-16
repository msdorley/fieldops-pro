# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Ousman Dorley. See LICENSE at the repository root.
<#
    Audit-SelfTest.Tests.ps1 -- FieldOps Pro Phase 6, Stream 6.4 (6.4-D17)

    Test-Installation.ps1 is the first thing a customer runs, and its verdict
    is their first impression of the product. It has now twice reported a
    healthy deployment as "usable, with caveats":

      1. DRIVERS\ and ISOs\ absent were warnings, though both are optional
         payload. Fixed by tiering the directory checks.
      2. technician.json absent was a warning, though INSTALL.md states
         configuration is optional and the toolkit falls back to defaults.
         That one reached a built release artifact before it was caught.

    A warning that fires on a correct deployment teaches the reader to ignore
    warnings, and then they miss a real one. These tests assert the two states
    that must be clean: a full development tree, and a freshly extracted
    release with no configuration at all.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSCommandPath
    while ($script:RepoRoot -and -not (Test-Path -LiteralPath (Join-Path $script:RepoRoot 'LICENSE'))) {
        $parent = Split-Path -Parent $script:RepoRoot
        if ($parent -eq $script:RepoRoot) { break }
        $script:RepoRoot = $parent
    }

    $script:SelfTest = Join-Path $script:RepoRoot 'SCRIPTS\Core\Test-Installation.ps1'

    # Build a deployment that mirrors what a customer actually extracts from
    # the release zip: the full required layout, every core script, both
    # locale bundles, the licence files -- and no configuration, because
    # configuration is optional and absent on a first run.
    #
    # A first version of this fixture created only a few directories and one
    # script, which made it a BROKEN deployment rather than a fresh one. The
    # self-test correctly reported NOT READY, and the test failed for a reason
    # that had nothing to do with what it was written to check. A fixture that
    # does not represent the state it claims to represent tests nothing.
    $script:Fresh = Join-Path ([System.IO.Path]::GetTempPath()) ("fostest-" + [guid]::NewGuid().ToString('N').Substring(0, 8))

    # Directories a healthy deployment has. TOOLS and PLAYBOOKS are featured,
    # not optional: their absence costs a capability and is warned about, so a
    # fresh-release fixture must include them.
    foreach ($d in @('SCRIPTS\Core','SCRIPTS\Compliance','SCRIPTS\Templates',
                     'CONFIG\lang','DOCS','TOOLS','PLAYBOOKS')) {
        New-Item -ItemType Directory -Path (Join-Path $script:Fresh $d) -Force | Out-Null
    }

    # Real files, copied from the real tree rather than stubbed. If one is
    # renamed, this list fails loudly instead of quietly standing in for a
    # path that no longer exists.
    $script:FixtureFiles = @(
        'SCRIPTS\FieldOps-Launcher.ps1'
        'SCRIPTS\Core\Invoke-ComplianceDiff.ps1'
        'SCRIPTS\Core\Test-Installation.ps1'
        'SCRIPTS\Core\Utils.psm1'
        'SCRIPTS\Core\Logger.psm1'
        'SCRIPTS\Core\FieldOps-Locale.psm1'
        'SCRIPTS\Compliance\Build-ANSSIData.ps1'
        'SCRIPTS\Templates\anssi-diagnostic.html'
        'CONFIG\lang\fr.json'
        'CONFIG\lang\en.json'
        'LICENSE'
        'NOTICE'
    )

    $missing = @()
    foreach ($rel in $script:FixtureFiles) {
        $src = Join-Path $script:RepoRoot $rel
        if (-not (Test-Path -LiteralPath $src)) { $missing += $rel; continue }
        Copy-Item -LiteralPath $src -Destination (Join-Path $script:Fresh $rel) -Force
    }

    if ($missing.Count -gt 0) {
        throw ("Fixture cannot be built; these files are missing from the tree: {0}. " +
               "If one was renamed, update the list in this test -- do not stub it." -f ($missing -join ', '))
    }

    function Invoke-SelfTest {
        param([string]$Root)
        # Run out of process so the script's exit code and console output are
        # observable without its top-level code running in this session.
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $Root 'SCRIPTS\Core\Test-Installation.ps1') 2>&1
        return ($out | Out-String)
    }
}

AfterAll {
    if ($script:Fresh -and (Test-Path -LiteralPath $script:Fresh)) {
        Remove-Item -LiteralPath $script:Fresh -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'The self-test ships and runs (6.4-D17)' {

    It 'exists in the deployed tree' {
        Test-Path -LiteralPath $script:SelfTest | Should -BeTrue
    }

    It 'produced output for the fresh-deployment fixture' {
        # Guard against every assertion below passing over an empty string.
        $script:FreshOut = Invoke-SelfTest -Root $script:Fresh
        $script:FreshOut | Should -Not -BeNullOrEmpty
        $script:FreshOut | Should -Match 'INSTALLATION SELF-TEST'
    }
}

Describe 'A freshly extracted release reports no caveats (6.4-D17)' {

    BeforeAll { $script:Out = Invoke-SelfTest -Root $script:Fresh }

    It 'reports zero failures' {
        $script:Out | Should -Match 'FAIL:\s*0'
    }

    It 'reports zero warnings' {
        # The one that got through to a release artifact: a customer's very
        # first run, on a correct stick, said "usable, with caveats".
        $script:Out | Should -Match 'WARN:\s*0' -Because `
            'a warning on a correct deployment teaches the reader to ignore warnings'
    }

    It 'reports READY, not USABLE WITH CAVEATS' {
        $script:Out | Should -Match 'READY'
        $script:Out | Should -Not -Match 'USABLE, WITH CAVEATS'
    }

    It 'treats an absent technician.json as OK rather than a warning' {
        # INSTALL.md states configuration is optional. The self-test must agree
        # with the documentation, or one of the two is lying to the customer.
        $script:Out | Should -Match '\[OK\s*\]\s*Configuration'
    }

    It 'treats absent optional payload directories as OK' {
        $script:Out | Should -Not -Match '\[WARN\].*DRIVERS'
        $script:Out | Should -Not -Match '\[WARN\].*ISOs'
    }
}

Describe 'The AI line is reported whether or not a config file exists (6.4-D17)' {

    # This check previously sat inside the branch taken only when a config file
    # was found, so a stick without one printed no AI line at all -- even with
    # ANTHROPIC_API_KEY set, which the config file does not govern. A check
    # that silently does not run is worse than one that reports wrongly,
    # because nothing on screen says it was skipped.

    It 'reports an AI configuration line with no config file present' {
        $out = Invoke-SelfTest -Root $script:Fresh
        $out | Should -Match 'AI configuration'
    }

    It 'reports an AI configuration line with a config file present' {
        $cfg = Join-Path $script:Fresh 'CONFIG\technician.json'
        try {
            '{ "TechnicianName": "Demo Technician", "Language": "fr" }' |
                Set-Content -LiteralPath $cfg -Encoding UTF8
            $out = Invoke-SelfTest -Root $script:Fresh
            $out | Should -Match 'AI configuration'
            $out | Should -Match 'WARN:\s*0'
        }
        finally {
            Remove-Item -LiteralPath $cfg -Force -ErrorAction SilentlyContinue
        }
    }

    It 'never prints anything key-shaped' {
        # The self-test reads the key to decide whether AI is available. It
        # must never echo it.
        $cfg = Join-Path $script:Fresh 'CONFIG\technician.json'
        try {
            '{ "AnthropicApiKey": "sk-ant-api03-TESTONLYNOTAREALKEY0000000000" }' |
                Set-Content -LiteralPath $cfg -Encoding UTF8
            $out = Invoke-SelfTest -Root $script:Fresh
            $out | Should -Match 'API key present'
            $out | Should -Not -Match 'TESTONLYNOTAREALKEY'
        }
        finally {
            Remove-Item -LiteralPath $cfg -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'A genuinely broken deployment still fails (6.4-D17)' {

    # The tests above push toward reporting fewer problems. This one guards the
    # opposite direction: the self-test must still be capable of failing, or
    # the previous assertions are satisfied by a script that says READY always.

    It 'reports FAIL when a required directory is missing' {
        $broken = Join-Path ([System.IO.Path]::GetTempPath()) ("fobroken-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        try {
            New-Item -ItemType Directory -Path (Join-Path $broken 'SCRIPTS\Core') -Force | Out-Null
            Copy-Item -LiteralPath $script:SelfTest -Destination (Join-Path $broken 'SCRIPTS\Core\') -Force

            # No CONFIG\, no DOCS\, no LICENSE, no locale bundles.
            $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass `
                -File (Join-Path $broken 'SCRIPTS\Core\Test-Installation.ps1') 2>&1 | Out-String

            $out | Should -Not -Match 'FAIL:\s*0' -Because `
                'a deployment missing CONFIG and DOCS is not READY'
        }
        finally {
            Remove-Item -LiteralPath $broken -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
