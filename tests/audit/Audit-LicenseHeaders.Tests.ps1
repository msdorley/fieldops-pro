#Requires -Version 5.1
<#
    FieldOps Pro - Phase 6, Stream 6.4 (6.4-D1, 6.4-D3)

    Audit: every deployed script carries an SPDX licence header.

    WHY THIS EXISTS

    tools/Apply-LicenseHeaders.ps1 stamps the tree, but a stamping script only
    helps if somebody remembers to run it. A file added next month and shipped
    on the USB without a licence header is a distribution defect that nobody
    notices until a customer's licence scanner reports an unlicensed file in a
    product they are evaluating.

    This turns "run the script" into "the suite fails if you did not".

    WHAT IS CHECKED

      - Every deployed .ps1 / .psm1 under SCRIPTS\ carries the SPDX identifier.
      - LICENSE exists, and is Apache 2.0 rather than the MIT text it replaced.
      - NOTICE exists. Apache section 4(d) gives it legal effect for attribution
        in derivative works, so its absence is not cosmetic.
      - Files that must NOT be stamped are still unstamped: .bak snapshots and
        the UTF-8-with-BOM HTML template. A header sweep that widened its own
        scope would break the encoding contract, and audits A1/A2 would report
        that as an encoding fault rather than as the licence sweep it was.

    SCOPE

    Matches the D14 audit convention: Archive\ is retired code, Patch-/Debug-/
    Apply- are dev tooling, neither deployed. Extension is matched exactly, not
    by pattern -- 'Invoke-NetRepair.ps1.jsonpatch.bak' is a .bak file, and an
    earlier version of the stamping script mistook 55 files for 29 by relying
    on -Include, which PowerShell silently ignores alongside -LiteralPath.
#>

BeforeAll {
    $script:RepoRoot   = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:ScriptsDir = Join-Path $script:RepoRoot 'SCRIPTS'
    $script:SpdxTag    = 'SPDX-License-Identifier: Apache-2.0'

    function Get-DeployedSources {
        Get-ChildItem -LiteralPath $script:ScriptsDir -Recurse -File |
            Where-Object { $_.Extension -eq '.ps1' -or $_.Extension -eq '.psm1' } |
            Where-Object {
                $_.FullName -notmatch '\\Archive\\' -and
                $_.Name -notmatch '^(Patch|Debug|Apply)-' -and
                $_.Name -notmatch '\.bak$'
            }
    }
}

Describe 'Licence headers on deployed sources (6.4-D3)' -Tag 'Slow' {

    It 'finds a non-empty set of deployed sources' {
        # Without this, every assertion below passes vacuously if the glob
        # breaks -- a green suite proving nothing, which is the same failure
        # shape the fixture and severity guards exist to prevent.
        @(Get-DeployedSources).Count | Should -BeGreaterThan 20
    }

    It 'every deployed script carries the SPDX identifier' {
        $missing = @()
        foreach ($f in Get-DeployedSources) {
            $raw = Get-Content -LiteralPath $f.FullName -Raw
            if ($raw -notmatch [regex]::Escape($script:SpdxTag)) {
                $missing += $f.FullName.Replace($script:RepoRoot + '\', '')
            }
        }
        if ($missing.Count -gt 0) {
            Write-Host "  Unlicensed deployed scripts (run tools\Apply-LicenseHeaders.ps1):"
            $missing | ForEach-Object { Write-Host "    $_" }
        }
        $missing.Count | Should -Be 0
    }

    It 'every deployed script also carries a copyright line' {
        # SPDX alone identifies the licence; the copyright line identifies the
        # holder. A scanner wants the first, a court wants the second.
        $missing = @()
        foreach ($f in Get-DeployedSources) {
            $raw = Get-Content -LiteralPath $f.FullName -Raw
            if ($raw -notmatch '(?m)^#\s*Copyright\s+\d{4}\s+\S') {
                $missing += $f.Name
            }
        }
        $missing.Count | Should -Be 0 -Because "missing copyright: $($missing -join ', ')"
    }
}

Describe 'Licence files at the repository root (6.4-D1)' -Tag 'Slow' {

    It 'LICENSE exists and is the Apache 2.0 text' {
        $path = Join-Path $script:RepoRoot 'LICENSE'
        Test-Path $path | Should -BeTrue
        $raw = Get-Content -LiteralPath $path -Raw
        $raw | Should -Match 'Apache License'
        $raw | Should -Match 'Version 2\.0, January 2004'
        # The patent grant is the substantive reason Apache was chosen over
        # MIT for a dual-licensed product. Its absence would mean the file is
        # not what the project claims it is.
        $raw | Should -Match 'Grant of Patent License'
    }

    It 'LICENSE is no longer the MIT text it replaced' {
        $raw = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'LICENSE') -Raw
        $raw | Should -Not -Match 'MIT License'
    }

    It 'NOTICE exists and names the licence and the holder' {
        $path = Join-Path $script:RepoRoot 'NOTICE'
        Test-Path $path | Should -BeTrue
        $raw = Get-Content -LiteralPath $path -Raw
        $raw | Should -Match 'Apache License'
        $raw | Should -Match '(?m)^Copyright\s+\d{4}\s+\S'
    }

    It 'NOTICE disclaims endorsement by ANSSI' {
        # The product is measured against a national agency's published guide.
        # Implying endorsement by that agency is the kind of claim that ends a
        # procurement conversation badly, so its denial is asserted, not left
        # to whoever edits the file next.
        $raw = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'NOTICE') -Raw
        $raw | Should -Match 'not endorsed by'
    }
}

Describe 'The stamp did not widen its own scope (6.4-D3)' -Tag 'Slow' {

    It 'leaves .bak snapshots unstamped' {
        $baks = @(Get-ChildItem -LiteralPath $script:ScriptsDir -Recurse -File |
                    Where-Object { $_.Name -match '\.bak$' })
        $stamped = @()
        foreach ($f in $baks) {
            $raw = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction SilentlyContinue
            if ($raw -and $raw -match [regex]::Escape($script:SpdxTag)) { $stamped += $f.Name }
        }
        $stamped.Count | Should -Be 0 -Because "retired snapshots must not be stamped: $($stamped -join ', ')"
    }

    It 'leaves the BOM-encoded HTML template untouched by the stamp' {
        # SCRIPTS\Templates\*.html is UTF-8 WITH BOM by design and carries
        # French accented text. A stamp there breaks the encoding contract that
        # the locale pipeline depends on.
        $tpl = Join-Path $script:ScriptsDir 'Templates\anssi-diagnostic.html'
        if (Test-Path $tpl) {
            $raw = Get-Content -LiteralPath $tpl -Raw
            $raw | Should -Not -Match [regex]::Escape($script:SpdxTag)
        }
    }
}
