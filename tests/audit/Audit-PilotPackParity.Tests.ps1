#Requires -Version 5.1
<#
    FieldOps Pro - Phase 7, Stream 7.1

    Audit: the two pilot packs stay parallel.

    WHY THIS EXISTS

    DOCS\PILOT-FR.md and DOCS\PILOT-EN.md are the same document in two
    languages. They are sent to prospects. Two documents that must agree, and
    that nothing forces to agree, diverge the first time one of them is edited
    in a hurry -- and the divergence is invisible to whoever edited it, because
    they were only reading one of the two.

    This is the same class of defect the locale-parity test guards for the
    bundles, at a coarser grain. It cannot check that the translation is good.
    It can check that a section, a table row, a protocol step or a feedback
    question was not added to one file and forgotten in the other.

    It is also here because the parity was verified by hand twice while the
    packs were being written, and one of those two hand checks miscounted --
    it read the protocol's numbered steps as feedback questions and reported a
    mismatch that did not exist. A check worth running twice is worth writing
    down.

    WHAT IS CHECKED

      - Both packs exist and are UTF-8 without a BOM. These are client-facing
        documents, so unlike the ASCII-only sources under SCRIPTS\ they carry
        real accents -- the CONFIG\lang bundles set that precedent.
      - The same heading levels in the same order.
      - The same number of numbered sections, table rows, protocol steps and
        feedback questions.
      - Each cross-references the other, so a reader handed one can find the
        other.
      - Neither hardcodes a product version, which CONFIG\version.json owns.

    WHAT IS DELIBERATELY NOT CHECKED

    Word count and sentence structure. French runs longer than English for the
    same content, and a test that insisted otherwise would push the translation
    towards being literal rather than being good.
#>

BeforeAll {
    $script:RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:FrPath   = Join-Path $script:RepoRoot 'DOCS\PILOT-FR.md'
    $script:EnPath   = Join-Path $script:RepoRoot 'DOCS\PILOT-EN.md'

    function Get-PackText {
        param([string]$Path)
        if (-not (Test-Path -LiteralPath $Path)) { return $null }
        [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    }

    # Heading levels only. The text differs by design; the shape must not.
    function Get-HeadingLevels {
        param([string]$Text)
        $levels = @()
        foreach ($line in ($Text -split "`n")) {
            if ($line -match '^(#{1,6})\s') { $levels += $Matches[1].Length }
        }
        , $levels
    }

    # Numbered list items inside one '## N.' section, so protocol steps and
    # feedback questions are counted separately rather than as one pool.
    function Get-SectionItemCount {
        param([string]$Text, [int]$Section)
        $lines   = $Text -split "`n"
        $inside  = $false
        $count   = 0
        foreach ($line in $lines) {
            if ($line -match '^##\s+(\d+)\.') {
                $inside = ([int]$Matches[1] -eq $Section)
                continue
            }
            if ($inside -and $line -match '^\d+\.\s') { $count++ }
        }
        $count
    }

    # Content rows only: a line beginning with '|' that is not the ---|--- rule.
    function Get-TableRowCount {
        param([string]$Text)
        $count = 0
        foreach ($line in ($Text -split "`n")) {
            if ($line -match '^\s*\|' -and $line -notmatch '^\s*\|[\s\-:|]+$') { $count++ }
        }
        $count
    }

    $script:Fr = Get-PackText -Path $script:FrPath
    $script:En = Get-PackText -Path $script:EnPath
}

Describe 'The pilot packs are present and correctly encoded' {

    It 'ships a French pack' {
        Test-Path -LiteralPath $script:FrPath | Should -BeTrue
    }

    It 'ships an English pack' {
        Test-Path -LiteralPath $script:EnPath | Should -BeTrue
    }

    It 'stores both as UTF-8 without a BOM' {
        foreach ($p in @($script:FrPath, $script:EnPath)) {
            $bytes = [System.IO.File]::ReadAllBytes($p)
            $bom   = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and
                      $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
            $bom | Should -BeFalse -Because "$p is client-facing markdown, not a BOM-encoded template"
        }
    }

    It 'keeps real accents in the French pack rather than folding them to ASCII' {
        # The ASCII discipline applies to SCRIPTS\, not to a document sent to a
        # French company. CONFIG\lang\fr.json sets the precedent.
        $bytes = [System.IO.File]::ReadAllBytes($script:FrPath)
        ($bytes | Where-Object { $_ -gt 127 }).Count |
            Should -BeGreaterThan 0 -Because 'ASCII-folded French reads as broken to the reader it is addressed to'
    }
}

Describe 'The two packs stay structurally parallel' {

    It 'uses the same heading levels in the same order' {
        $fr = Get-HeadingLevels -Text $script:Fr
        $en = Get-HeadingLevels -Text $script:En
        ($fr -join ',') | Should -Be ($en -join ',')
    }

    It 'has the same number of numbered sections' {
        $fr = ([regex]::Matches($script:Fr, '(?m)^##\s+\d+\.')).Count
        $en = ([regex]::Matches($script:En, '(?m)^##\s+\d+\.')).Count
        $fr | Should -Be $en
        $fr | Should -BeGreaterThan 0
    }

    It 'has the same number of table rows' {
        # Counting '|---' counts TABLES, not rows: a verdict added to the French
        # table and forgotten in the English adds no separator line and would
        # pass. A mutation test caught that; this counts content rows instead.
        $fr = Get-TableRowCount -Text $script:Fr
        $en = Get-TableRowCount -Text $script:En
        $fr | Should -Be $en
        $fr | Should -BeGreaterThan 0
    }

    It 'has the same table shape' {
        # Separator segments, not tables: '|---|---|' matches twice for a
        # two-column table. That makes it a proxy for column count as well as
        # table count, which is why it is compared rather than asserted to a
        # literal. The row check above is the one that carries the weight.
        $fr = ([regex]::Matches($script:Fr, '\|---')).Count
        $en = ([regex]::Matches($script:En, '\|---')).Count
        $fr | Should -Be $en
    }

    It 'has the same number of protocol steps' {
        $fr = Get-SectionItemCount -Text $script:Fr -Section 4
        $en = Get-SectionItemCount -Text $script:En -Section 4
        $fr | Should -Be $en
        $fr | Should -BeGreaterThan 0
    }

    It 'has the same number of feedback questions' {
        $fr = Get-SectionItemCount -Text $script:Fr -Section 6
        $en = Get-SectionItemCount -Text $script:En -Section 6
        $fr | Should -Be $en
        $fr | Should -BeGreaterThan 0
    }

    It 'counts protocol steps and feedback questions separately' {
        # Guards the hand check that got this wrong: a document-wide count of
        # '^N. ' pools the two lists and reports a mismatch against either.
        $steps     = Get-SectionItemCount -Text $script:Fr -Section 4
        $questions = Get-SectionItemCount -Text $script:Fr -Section 6
        $whole     = ([regex]::Matches($script:Fr, '(?m)^\d+\.\s')).Count
        $whole | Should -BeGreaterThan $questions -Because 'a document-wide count includes the protocol steps'
        ($steps + $questions) | Should -BeLessOrEqual $whole
    }

    It 'cross-references the other pack from each' {
        $script:Fr | Should -Match 'PILOT-EN\.md'
        $script:En | Should -Match 'PILOT-FR\.md'
    }
}

Describe 'The packs do not restate what other files own' {

    It 'points at CONFIG\version.json rather than naming a version' {
        $declared = (Get-Content -LiteralPath (Join-Path $script:RepoRoot 'CONFIG\version.json') -Raw |
                     ConvertFrom-Json).product
        foreach ($text in @($script:Fr, $script:En)) {
            $text | Should -Not -Match ([regex]::Escape($declared))
            $text | Should -Match 'version\.json'
        }
    }

    It 'states the ANSSI non-affiliation that NOTICE requires' {
        $script:Fr | Should -Match 'aucune affiliation'
        $script:En | Should -Match 'no affiliation'
    }
}
