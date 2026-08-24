#Requires -Version 5.1
<#
    FieldOps Pro - Phase 7, Stream 7.1

    THE GUARD: AN ENGLISH RENDER CONTAINS NO FRENCH

    Phase 7.1 has two halves. The first -- routing all 42 evaluators through
    their bundle keys -- is done. This is the second, and it exists because the
    first half can be completed without making the report bilingual at all.

    Build-ANSSIData.ps1 calls Initialize-Locale with 'fr' hardcoded. The
    evaluators therefore resolve their prose once, at collection time, in
    French, and report-data.json stores the resulting French sentences. The
    renderer only HTML-escapes that text. So `-Language en` produces English
    headings, English rule names and English measures wrapped around French
    findings, and nothing anywhere reports a problem.

    WHY THE OBVIOUS MEASUREMENT MISSED IT

    Counting diacritics in the rendered report was used as evidence that the
    evaluator wiring had worked. It had: Meta went from 0 of 42 accented to 42
    of 42. But that number measures how good the FRENCH is. It rises when the
    French improves and says nothing about whether the English render is
    English. A check that can only confirm the thing it was built to confirm
    proves nothing.

    HOW THIS DETECTS FRENCH

    Two signals, because either alone has a blind spot:

      1. French diacritics in visible text. Now that the prose comes from the
         bundle it carries real accents, so this is decisive -- but it misses
         accent-free French such as "Aucune connexion".
      2. The French-only wordlist from FrenchWordlist.ps1. Not the full list:
         a fifth of that is also English, and would flag a correct report.

    Tagged Slow: it invokes the real renderer.
#>

BeforeAll {
    $script:TestsRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:RepoRoot  = Split-Path $script:TestsRoot -Parent
    $script:Poc       = Join-Path $script:RepoRoot 'SCRIPTS\Compliance\Invoke-ANSSIDiagnostic-POC.ps1'

    . (Join-Path $script:TestsRoot 'audit\FrenchWordlist.ps1')

    $script:DataFile = $null
    foreach ($candidate in @(
        (Join-Path $script:RepoRoot 'SCRIPTS\Compliance\report-data.sample.json'),
        (Join-Path $script:RepoRoot 'REPORTS\report-data.sample.json'),
        (Join-Path $script:RepoRoot 'REPORTS\report-data.json')
    )) {
        if (Test-Path -LiteralPath $candidate) { $script:DataFile = $candidate; break }
    }

    function Invoke-EnglishRender {
        $outDir = Join-Path $env:TEMP ("fo-en-{0}" -f [guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
        & $script:Poc -DataFile $script:DataFile -OutputDir $outDir -Language 'en' -NoPdf -NoOpen *>&1 | Out-Null
        $html = Get-ChildItem -LiteralPath $outDir -Filter 'FOPS-*.html' -ErrorAction SilentlyContinue |
                Select-Object -First 1
        $content = ''
        if ($html) { $content = [System.IO.File]::ReadAllText($html.FullName) }
        return [PSCustomObject]@{ OutDir = $outDir; Content = $content }
    }

    # Visible text only. Style and script blocks are excluded for the same
    # reason the 6.1-R4a scanner excludes them: CSS is full of words that
    # collide with the wordlist, and the noise buries real findings.
    function Get-VisibleText {
        param([string]$Html)
        $t = $Html
        $t = [regex]::Replace($t, '(?is)<style.*?</style>', ' ')
        $t = [regex]::Replace($t, '(?is)<script.*?</script>', ' ')
        $t = [regex]::Replace($t, '(?s)<!--.*?-->', ' ')
        $t = [regex]::Replace($t, '(?s)<[^>]+>', ' ')
        $t = $t.Replace('&middot;', ' ').Replace('&mdash;', ' ').Replace('&nbsp;', ' ')
        $t = $t.Replace('&amp;', ' ').Replace('&lt;', ' ').Replace('&gt;', ' ')
        $t = [regex]::Replace($t, '&[a-z]+;', ' ')
        return $t
    }

    function ConvertTo-FoldedAscii {
        param([string]$Text)
        if (-not $Text) { return '' }
        $decomposed = $Text.Normalize([System.Text.NormalizationForm]::FormD)
        $sb = New-Object System.Text.StringBuilder
        foreach ($ch in $decomposed.ToCharArray()) {
            $cat = [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch)
            if ($cat -ne [System.Globalization.UnicodeCategory]::NonSpacingMark) {
                [void]$sb.Append($ch)
            }
        }
        return $sb.ToString().ToLowerInvariant()
    }
}

Describe '7.1 - an English render contains no French' -Tag 'Slow' {

    It 'has a data file to render from' {
        $script:DataFile | Should -Not -BeNullOrEmpty
    }

    It 'produces an English report' {
        $r = Invoke-EnglishRender
        try {
            $r.Content.Length | Should -BeGreaterThan 1000
        } finally {
            Remove-Item $r.OutDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'carries no French diacritics in visible text' {
        $r = Invoke-EnglishRender
        try {
            $text = Get-VisibleText -Html $r.Content
            # Sample the offending words rather than dumping the character
            # positions: the failure needs to name what leaked, not where.
            # The Latin-1 supplement range is written as escapes, not as literal
            # characters. PowerShell 5.1 reads a BOM-less .ps1 as the system ANSI
            # codepage, so a literal 'A-grave' here arrives as two mojibake
            # characters and the class becomes a reversed range that throws at
            # runtime. A test for encoding faults, defeated by one.
            $accented = '[\u00C0-\u00FF]'
            $bad = @()
            foreach ($w in ([regex]::Matches($text, '[^\s]+') | ForEach-Object { $_.Value })) {
                if ($w -match $accented) { $bad += $w }
            }
            $sample = (@($bad | Select-Object -Unique) -join ' ')
            if ($sample.Length -gt 400) { $sample = $sample.Substring(0, 400) + '...' }
            $sample | Should -Be '' -Because 'accented words in an English report are French prose that reached the reader'
        } finally {
            Remove-Item $r.OutDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'carries no French-only vocabulary in visible text' {
        $r = Invoke-EnglishRender
        try {
            $folded = ConvertTo-FoldedAscii (Get-VisibleText -Html $r.Content)
            $tokens = @([regex]::Matches($folded, "[a-z][a-z'-]{2,}") | ForEach-Object { $_.Value })
            $hits   = @($tokens | Where-Object { $script:FrenchOnlyWords -contains $_ } | Select-Object -Unique)
            (@($hits) -join ' ') | Should -Be '' -Because 'these words are French and cannot appear in an English report'
        } finally {
            Remove-Item $r.OutDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
