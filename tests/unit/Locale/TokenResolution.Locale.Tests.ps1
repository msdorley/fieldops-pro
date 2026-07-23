#Requires -Version 5.1
<#
    FieldOps Pro - Phase 6, Stream 6.1 (R4b)

    Template token resolution guard.

    This is the foundation of requirement 6.1-R7 ("zero unresolved tokens"),
    delivered early because it is the regression guard for a real defect:

    The R1 resolver patch routed rich-text values into a separate $richKeys
    map but left the original $null placeholder in $uniqueKeys. The
    replacement loop then counted an already-resolved key as unresolved, so
    every render reported a phantom "1 unresolved" while the output was
    actually correct. Any zero-unresolved guard built on that counter would
    have failed permanently on a healthy template.

    These tests assert the invariant that matters: after resolution, no
    {{t:...}} token survives in the output, in either locale, and the
    resolver raises no unresolved warning.
#>

BeforeAll {
    $script:TestsRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:RepoRoot  = Split-Path $script:TestsRoot -Parent
    $script:Template  = Join-Path $script:RepoRoot 'SCRIPTS\Templates\anssi-diagnostic.html'
    $script:BundleDir = Join-Path $script:RepoRoot 'CONFIG\lang'
    $script:Resolver  = Join-Path $script:RepoRoot 'SCRIPTS\Compliance\Resolve-LocaleTokens.ps1'

    . $script:Resolver

    function Invoke-TemplateRender {
        param([string]$Lang)
        $tmp = Join-Path $env:TEMP ("fo-tokens-{0}-{1}.html" -f $Lang, [guid]::NewGuid().ToString('N').Substring(0,8))
        Copy-Item $script:Template $tmp -Force
        $warnings = @()
        Resolve-LocaleTokensInFile -Path $tmp -BundleDir $script:BundleDir -Lang $Lang -WarningVariable warnings -WarningAction SilentlyContinue | Out-Null
        $content = [System.IO.File]::ReadAllText($tmp)
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        return [PSCustomObject]@{
            Content  = $content
            Warnings = @($warnings | ForEach-Object { "$_" })
        }
    }
}

Describe 'Template token resolution (6.1-R4b / R7 foundation)' -Tag 'Fast' {

    It 'FR render leaves no unresolved {{t:}} tokens' {
        $r = Invoke-TemplateRender -Lang 'fr'
        $left = [regex]::Matches($r.Content, '\{\{t:[\w.]+\}\}') |
                ForEach-Object { $_.Value }
        ($left -join ',') | Should -Be ''
    }

    It 'EN render leaves no unresolved {{t:}} tokens' {
        $r = Invoke-TemplateRender -Lang 'en'
        $left = [regex]::Matches($r.Content, '\{\{t:[\w.]+\}\}') |
                ForEach-Object { $_.Value }
        ($left -join ',') | Should -Be ''
    }

    It 'FR resolution reports no unresolved keys (guards the phantom-count defect)' {
        $r = Invoke-TemplateRender -Lang 'fr'
        $bad = @($r.Warnings | Where-Object { $_ -match 'unresolved' -and $_ -notmatch '0 unresolved' })
        ($bad -join ' | ') | Should -Be ''
    }

    It 'EN resolution reports no unresolved keys' {
        $r = Invoke-TemplateRender -Lang 'en'
        $bad = @($r.Warnings | Where-Object { $_ -match 'unresolved' -and $_ -notmatch '0 unresolved' })
        ($bad -join ' | ') | Should -Be ''
    }

    It 'the rich-text cover title renders as real HTML, not an escaped or literal token' {
        $r = Invoke-TemplateRender -Lang 'fr'
        $h1 = [regex]::Match($r.Content, '<h1 class="title-h1 serif">(.*?)</h1>')
        $h1.Success | Should -BeTrue
        $h1.Groups[1].Value | Should -Match '<br>'
        $h1.Groups[1].Value | Should -Not -Match '&lt;br&gt;'
        $h1.Groups[1].Value | Should -Not -Match '\{\{'
    }

    It 'FR and EN renders differ (proves locale actually switches the output)' {
        $fr = (Invoke-TemplateRender -Lang 'fr').Content
        $en = (Invoke-TemplateRender -Lang 'en').Content
        $fr | Should -Not -Be $en
    }

    It 'FR render carries French diacritics from the bundle' {
        $r = Invoke-TemplateRender -Lang 'fr'
        $accented = @($r.Content.ToCharArray() | Where-Object { [int]$_ -gt 127 })
        $accented.Count | Should -BeGreaterThan 0
    }
}
