#Requires -Version 5.1
<#
================================================================================
Find-HardcodedStringsInTemplate.ps1 -- FieldOps Pro Phase 6, Stream 6.1 (R4)
================================================================================
Scans an HTML report template for hardcoded French strings that should be
routed through the locale bundle.

WHY A WORDLIST AND NOT ACCENT DETECTION
    The design doc (6.1.4.4) proposed detecting French by accented characters.
    That does not work here: SCRIPTS\Templates\anssi-diagnostic.html is pure
    ASCII apart from its BOM, so its French is accent-stripped ("securite",
    "Conformite", "perimetre"). Accent detection would report zero findings on
    a template that is largely untranslated French. Detection is therefore
    driven by a curated wordlist of French security/compliance terms, with
    accent folding applied first so the scanner still works if the template
    ever gains real diacritics.

WHAT IS SCANNED
    - Visible text nodes between tags
    - Attribute values that can surface as user-visible text
      (title, alt, aria-*, placeholder, data-*, content)

WHAT IS EXCLUDED (and why)
    - <style> and <script> blocks. CSS is full of words that collide with the
      French wordlist ("content", "module", "serie", "regle" appear in class
      names and properties). Scanning them buries real findings in noise.
    - HTML comments.
    - Locale tokens {{t:...}} and data tokens {{...}} -- already routed.
    - HTML entities (&mdash; &middot; &laquo; &nbsp;) -- stripped before
      analysis so entity names are not mistaken for words.
    - Whitelisted strings: brand marks, acronyms, and status codes that are
      identical in every locale and must not be translated.

USAGE
    Standalone report:
        .\Find-HardcodedStringsInTemplate.ps1
        .\Find-HardcodedStringsInTemplate.ps1 -IncludeWhitelisted

    As a library (for the R6 guard test):
        . .\Find-HardcodedStringsInTemplate.ps1
        $hits = Find-HardcodedStringsInTemplate -TemplatePath $path
        $hits.Count | Should -Be 0
================================================================================
#>
[CmdletBinding()]
param(
    [string]$TemplatePath,
    [switch]$IncludeWhitelisted
)

# ---------------------------------------------------------------------------
# Curated French security / compliance wordlist (accent-folded, lowercase).
# A candidate string is flagged when it contains any of these as a whole word.
# ---------------------------------------------------------------------------
$script:FrenchWords = @(
    'acces','affiliation','agrement','annexe','apporte','approbation','architecture'
    'attestable','attestation','attestees','audit','audite','autorite','automatiquement'
    'aucune','cartographie','certification','certifications','complementaire','conclusion'
    'conformite','constat','constitue','contextuelle','contractuelle','controle'
    'couverture','date','delivrer','diagnostic','document','donnees','elements'
    'employe','ensemble','etat','evaluation','exploitation','fabricant','formation'
    'generation','gouvernance','habilitee','hors','hygiene','informatique','instant'
    'invalident','invaliderait','isole','juridique','lecture','limitee','machines'
    'manuelle','materiel','mesures','methode','modele','modifications','module'
    'modules','necessitent','niveau','nom','numero','observation','observee','observes'
    'officielles','organisationnelle','organisationnelles','outil','partenariat'
    'partiellement','perimetre','poste','postes','posterieures','procedures','qualifications'
    'rapport','reference','referentiel','regle','regles','releve','relevent','reseau'
    'restantes','resultat','resultats','securite','separe','serie','seule','signature'
    'spectre','structure','supplementaires','synthese','systeme','technique','terme'
    'utilisateur','utilisateurs','verifie','verifier','vue'
)

# ---------------------------------------------------------------------------
# Whitelist: strings that are legitimately identical across locales.
# Each entry is a regex matched against the accent-folded candidate.
# ---------------------------------------------------------------------------
$script:Whitelist = @(
    '^FieldOps Pro'                 # brand name
    '^ANSSI$'                       # agency acronym
    '^SHA-256$'                     # algorithm name
    '^(CV|PV|HP)$'                  # status codes
    '^[\d\s\.\,\-:/]+$'             # pure numerics / dates / separators
    '^[A-Z]{2,6}$'                  # bare acronyms
)

# ---------------------------------------------------------------------------
# Attributes whose values can surface as user-visible text.
# ---------------------------------------------------------------------------
$script:TextBearingAttributes = @(
    'title','alt','placeholder','content','label','summary'
)

function ConvertTo-AsciiFold {
    <#
    .SYNOPSIS
        Fold accented Latin characters to their ASCII equivalents so the
        wordlist matches whether or not the template carries diacritics.
    #>
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $map = @{
        [char]0x00E0='a'; [char]0x00E2='a'; [char]0x00E4='a'
        [char]0x00E7='c'
        [char]0x00E8='e'; [char]0x00E9='e'; [char]0x00EA='e'; [char]0x00EB='e'
        [char]0x00EE='i'; [char]0x00EF='i'
        [char]0x00F4='o'; [char]0x00F6='o'
        [char]0x00F9='u'; [char]0x00FB='u'; [char]0x00FC='u'
        [char]0x00C0='A'; [char]0x00C2='A'; [char]0x00C7='C'
        [char]0x00C8='E'; [char]0x00C9='E'; [char]0x00CA='E'
        [char]0x00CE='I'; [char]0x00D4='O'; [char]0x00DB='U'
    }
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $Text.ToCharArray()) {
        if ($map.ContainsKey($ch)) { [void]$sb.Append($map[$ch]) }
        else { [void]$sb.Append($ch) }
    }
    return $sb.ToString()
}

function Get-TemplateScanText {
    <#
    .SYNOPSIS
        Return the template text with style blocks, script blocks and HTML
        comments masked out, preserving newlines so line numbers stay exact.
    .DESCRIPTION
        Masking replaces excluded regions with spaces rather than deleting
        them. Character offsets and line counts are therefore unchanged, so a
        match index in the masked text maps to the correct source line.
    #>
    param([Parameter(Mandatory=$true)][string]$Raw)

    $masker = {
        param($m)
        # Preserve newlines, blank everything else
        ($m.Value -replace '[^\r\n]', ' ')
    }
    $text = $Raw
    $text = [regex]::Replace($text, '(?is)<style\b.*?</style\s*>', $masker)
    $text = [regex]::Replace($text, '(?is)<script\b.*?</script\s*>', $masker)
    $text = [regex]::Replace($text, '(?s)<!--.*?-->', $masker)
    return $text
}

function Get-LineNumberForIndex {
    param([string]$Text, [int]$Index)
    if ($Index -le 0) { return 1 }
    $before = $Text.Substring(0, $Index)
    return ([regex]::Matches($before, "`n")).Count + 1
}

function Remove-NonLinguisticContent {
    <#
    .SYNOPSIS
        Strip tokens and entities so they are not mistaken for words.
    #>
    param([string]$Text)
    $t = $Text
    $t = [regex]::Replace($t, '\{\{[^}]*\}\}', ' ')   # {{t:key}} and {{DATA}}
    $t = [regex]::Replace($t, '&[a-zA-Z]+;', ' ')     # &mdash; &middot; &nbsp;
    $t = [regex]::Replace($t, '&#\d+;', ' ')          # numeric entities
    $t = [regex]::Replace($t, '\s+', ' ')
    return $t.Trim()
}

function Test-IsWhitelisted {
    param([string]$Candidate)
    $folded = ConvertTo-AsciiFold -Text $Candidate
    foreach ($pattern in $script:Whitelist) {
        if ($folded -match $pattern) { return $true }
    }
    return $false
}

function Get-FrenchWordHits {
    <#
    .SYNOPSIS
        Return the wordlist terms found in a candidate string.
    #>
    param([string]$Candidate)
    $folded = (ConvertTo-AsciiFold -Text $Candidate).ToLower()
    $hits = @()
    foreach ($w in $script:FrenchWords) {
        if ($folded -match ('\b' + [regex]::Escape($w) + '\b')) { $hits += $w }
    }
    return $hits
}

function Find-HardcodedStringsInTemplate {
    <#
    .SYNOPSIS
        Scan a template and return candidate hardcoded French strings.
    .OUTPUTS
        PSCustomObject with Line, Kind, Name, Text, Words, Whitelisted
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$TemplatePath
    )

    if (-not (Test-Path -LiteralPath $TemplatePath)) {
        throw "Template not found: $TemplatePath"
    }

    $raw  = [System.IO.File]::ReadAllText($TemplatePath)
    $scan = Get-TemplateScanText -Raw $raw
    $results = @()

    # --- 1. Visible text nodes -------------------------------------------
    foreach ($m in [regex]::Matches($scan, '>([^<>]+)<')) {
        $clean = Remove-NonLinguisticContent -Text $m.Groups[1].Value
        if ($clean.Length -lt 4) { continue }
        if ($clean -notmatch '[A-Za-z]{3,}') { continue }

        $words = Get-FrenchWordHits -Candidate $clean
        if ($words.Count -eq 0) { continue }

        $white = Test-IsWhitelisted -Candidate $clean

        $results += [PSCustomObject]@{
            Line        = Get-LineNumberForIndex -Text $scan -Index $m.Index
            Kind        = 'TextNode'
            Name        = ''
            Text        = $clean
            Words       = ($words -join ',')
            Whitelisted = $white
        }
    }

    # --- 2. Text-bearing attributes ---------------------------------------
    $attrPattern = '(?i)\b([a-z][a-z0-9-]*)\s*=\s*"([^"]*)"'
    foreach ($m in [regex]::Matches($scan, $attrPattern)) {
        $name = $m.Groups[1].Value.ToLower()
        $isTextBearing = ($script:TextBearingAttributes -contains $name) -or
                         ($name -like 'aria-*') -or ($name -like 'data-*')
        if (-not $isTextBearing) { continue }

        $clean = Remove-NonLinguisticContent -Text $m.Groups[2].Value
        if ($clean.Length -lt 4) { continue }
        if ($clean -notmatch '[A-Za-z]{3,}') { continue }

        $words = Get-FrenchWordHits -Candidate $clean
        if ($words.Count -eq 0) { continue }

        $white = Test-IsWhitelisted -Candidate $clean

        $results += [PSCustomObject]@{
            Line        = Get-LineNumberForIndex -Text $scan -Index $m.Index
            Kind        = 'Attribute'
            Name        = $name
            Text        = $clean
            Words       = ($words -join ',')
            Whitelisted = $white
        }
    }

    return @($results | Sort-Object Line, Kind)
}

function Resolve-DefaultTemplatePath {
    # tests\audit\ -> repo root -> SCRIPTS\Templates\anssi-diagnostic.html
    $auditDir = $PSScriptRoot
    if (-not $auditDir) { return $null }
    $repoRoot = Split-Path -Parent (Split-Path -Parent $auditDir)
    return (Join-Path $repoRoot 'SCRIPTS\Templates\anssi-diagnostic.html')
}

# ---------------------------------------------------------------------------
# Standalone report mode.
# Skipped when the file is dot-sourced (so tests can import the functions
# without triggering a console report).
# ---------------------------------------------------------------------------
if ($MyInvocation.InvocationName -ne '.') {

    $path = $TemplatePath
    if (-not $path) { $path = Resolve-DefaultTemplatePath }
    if (-not $path) {
        Write-Warning 'Cannot resolve template path; pass -TemplatePath explicitly.'
        return
    }

    Write-Host ''
    Write-Host '------------------------------------------------------------------------'
    Write-Host '  FieldOps Pro -- Hardcoded String Audit (6.1-R4)'
    Write-Host '------------------------------------------------------------------------'
    Write-Host "  Template : $path"
    Write-Host "  Wordlist : $($script:FrenchWords.Count) French terms"
    Write-Host '  Excluded : <style>, <script>, HTML comments, {{tokens}}, entities'
    Write-Host ''

    $all     = Find-HardcodedStringsInTemplate -TemplatePath $path
    $flagged = @($all | Where-Object { $_.Whitelisted })
    $hits    = if ($IncludeWhitelisted) { $all } else { @($all | Where-Object { -not $_.Whitelisted }) }

    if ($hits.Count -eq 0) {
        Write-Host '  RESULT: no hardcoded French strings found.'
        Write-Host ''
        return
    }

    foreach ($h in $hits) {
        $tag = if ($h.Kind -eq 'Attribute') { "$($h.Kind)[$($h.Name)]" } else { $h.Kind }
        $flag = if ($h.Whitelisted) { ' [whitelisted]' } else { '' }
        $shown = $h.Text
        if ($shown.Length -gt 96) { $shown = $shown.Substring(0, 93) + '...' }
        Write-Host ("  line {0,4}  {1,-18} {2}{3}" -f $h.Line, $tag, $shown, $flag)
    }

    $active = @($all | Where-Object { -not $_.Whitelisted })
    Write-Host ''
    Write-Host '------------------------------------------------------------------------'
    Write-Host ("  Candidates requiring routing : {0}" -f $active.Count)
    Write-Host ("  Whitelisted (shown only with -IncludeWhitelisted) : {0}" -f $flagged.Count)
    Write-Host '------------------------------------------------------------------------'
    Write-Host ''
}
