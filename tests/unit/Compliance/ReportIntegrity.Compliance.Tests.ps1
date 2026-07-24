#Requires -Version 5.1
<#
    FieldOps Pro - Phase 6, Stream 6.1 (R4b part 2b)

    End-to-end report generation tests. Tagged Slow: they invoke the real
    renderer, so they run in the full suite (pre-push) rather than the fast
    pre-commit tier.

    WHY THE SIGNATURE TEST EXISTS

    The ANSSI report embeds a SHA-256 of its own content and states that any
    modification after generation invalidates that signature. Until 6.1-R4b the
    claim could not hold: the hash was computed, the file was written, and the
    locale resolver then rewrote that same file in place -- so the digest
    covered content that no longer existed. Separately, the hash was taken over
    BOM-less bytes while the write emitted a BOM, so even correct ordering
    would not have matched.

    A compliance artifact whose integrity claim cannot be verified is worse
    than one that makes no claim. These tests machine-verify it on every full
    suite run, using exactly the procedure a customer would follow:

        1. Read the delivered HTML.
        2. Replace the 64 hex characters in the hash block with 64 zeros.
        3. Encode UTF-8 with BOM.
        4. SHA-256 and compare against the embedded value.

    WHY THE ENGLISH TEST EXISTS

    The locale was hardcoded to 'fr' in the renderer, so an English report
    could not be produced at all regardless of bundle completeness. 6.1-R9
    requires a valid English render; this asserts it end to end.
#>

BeforeAll {
    $script:TestsRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:RepoRoot  = Split-Path $script:TestsRoot -Parent
    $script:Poc       = Join-Path $script:RepoRoot 'SCRIPTS\Compliance\Invoke-ANSSIDiagnostic-POC.ps1'

    # Prefer the committed sample; fall back to a generated data file.
    $script:DataFile = $null
    foreach ($candidate in @(
        (Join-Path $script:RepoRoot 'SCRIPTS\Compliance\report-data.sample.json'),
        (Join-Path $script:RepoRoot 'REPORTS\report-data.sample.json'),
        (Join-Path $script:RepoRoot 'REPORTS\report-data.json')
    )) {
        if (Test-Path -LiteralPath $candidate) { $script:DataFile = $candidate; break }
    }
    if (-not $script:DataFile) {
        $found = Get-ChildItem -LiteralPath $script:RepoRoot -Recurse -Filter 'report-data*.json' -ErrorAction SilentlyContinue |
                 Select-Object -First 1
        if ($found) { $script:DataFile = $found.FullName }
    }

    function Invoke-ReportRender {
        param([string]$Language)
        $outDir = Join-Path $env:TEMP ("fo-render-{0}-{1}" -f $Language, [guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
        & $script:Poc -DataFile $script:DataFile -OutputDir $outDir -Language $Language -NoPdf -NoOpen *>&1 | Out-Null
        $html = Get-ChildItem -LiteralPath $outDir -Filter 'FOPS-*.html' -ErrorAction SilentlyContinue |
                Select-Object -First 1
        $content = if ($html) { [System.IO.File]::ReadAllText($html.FullName) } else { $null }
        return [PSCustomObject]@{
            OutDir  = $outDir
            Path    = if ($html) { $html.FullName } else { $null }
            Content = $content
        }
    }

    function Test-EmbeddedSignature {
        param([string]$Content)
        $m = [regex]::Match($Content, '<div class="hash-block">([0-9a-f]{64})</div>')
        if (-not $m.Success) { return [PSCustomObject]@{ Found = $false; Valid = $false } }
        $embedded = $m.Groups[1].Value
        $restored = $Content.Replace($embedded, ('0' * 64))
        $enc      = New-Object System.Text.UTF8Encoding($true)
        $bytes    = $enc.GetPreamble() + [System.Text.Encoding]::UTF8.GetBytes($restored)
        $sha      = [System.Security.Cryptography.SHA256]::Create()
        $recomp   = ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-','').ToLower()
        return [PSCustomObject]@{
            Found      = $true
            Valid      = ($embedded -eq $recomp)
            Embedded   = $embedded
            Recomputed = $recomp
        }
    }
}

Describe 'Report integrity signature (6.1-R4b)' -Tag 'Slow' {

    It 'has a data file available to render from' {
        $script:DataFile | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $script:DataFile | Should -BeTrue
    }

    It 'renders a French report to disk' {
        $r = Invoke-ReportRender -Language 'fr'
        try {
            $r.Path | Should -Not -BeNullOrEmpty
            $r.Content.Length | Should -BeGreaterThan 1000
        } finally {
            Remove-Item $r.OutDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'the embedded SHA-256 validates against the delivered bytes' {
        $r = Invoke-ReportRender -Language 'fr'
        try {
            $sig = Test-EmbeddedSignature -Content $r.Content
            $sig.Found | Should -BeTrue
            # Surface both digests on failure rather than a bare $false
            "$($sig.Embedded) vs $($sig.Recomputed)" | Should -Be "$($sig.Embedded) vs $($sig.Embedded)"
        } finally {
            Remove-Item $r.OutDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'the rendered French report leaves no unresolved locale tokens' {
        $r = Invoke-ReportRender -Language 'fr'
        try {
            $left = [regex]::Matches($r.Content, '\{\{t:[\w.]+\}\}') | ForEach-Object { $_.Value }
            ($left -join ',') | Should -Be ''
        } finally {
            Remove-Item $r.OutDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'the rendered French report leaves no unsubstituted bundle placeholders' {
        # Single-brace placeholders such as {cvCount} arrive with bundle text and
        # must be consumed by the replacement pass. A survivor would print raw.
        $r = Invoke-ReportRender -Language 'fr'
        try {
            $body = $r.Content
            # Strip <style> so CSS braces are not mistaken for placeholders
            $body = [regex]::Replace($body, '(?is)<style\b.*?</style\s*>', ' ')
            $left = [regex]::Matches($body, '\{[a-zA-Z][a-zA-Z0-9]*\}') | ForEach-Object { $_.Value }
            ($left -join ',') | Should -Be ''
        } finally {
            Remove-Item $r.OutDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'English report render (6.1-R9)' -Tag 'Slow' {

    It 'renders an English report with a valid signature' {
        $r = Invoke-ReportRender -Language 'en'
        try {
            $r.Path | Should -Not -BeNullOrEmpty
            $sig = Test-EmbeddedSignature -Content $r.Content
            $sig.Found | Should -BeTrue
            "$($sig.Embedded) vs $($sig.Recomputed)" | Should -Be "$($sig.Embedded) vs $($sig.Embedded)"
        } finally {
            Remove-Item $r.OutDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'the English render leaves no unresolved locale tokens' {
        $r = Invoke-ReportRender -Language 'en'
        try {
            $left = [regex]::Matches($r.Content, '\{\{t:[\w.]+\}\}') | ForEach-Object { $_.Value }
            ($left -join ',') | Should -Be ''
        } finally {
            Remove-Item $r.OutDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'the English render carries English bundle text' {
        $r = Invoke-ReportRender -Language 'en'
        try {
            $r.Content | Should -Match 'IT Hygiene'
            $r.Content | Should -Match 'Verified \(CV\)'
        } finally {
            Remove-Item $r.OutDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'French and English renders differ' {
        $fr = Invoke-ReportRender -Language 'fr'
        $en = Invoke-ReportRender -Language 'en'
        try {
            $fr.Content | Should -Not -Be $en.Content
        } finally {
            Remove-Item $fr.OutDir -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item $en.OutDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
