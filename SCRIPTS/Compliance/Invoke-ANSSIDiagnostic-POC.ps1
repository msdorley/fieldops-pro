# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Ousman Dorley. See LICENSE at the repository root.
<#
.SYNOPSIS
    FieldOps Pro - ANSSI Hygiene Diagnostic Report Builder
.DESCRIPTION
    Reads report-data.json and the premium HTML template, generates the
    compliance spectrum, module bars, module detail pages and findings,
    writes a rendered HTML file, then converts to PDF via headless Edge
    (primary) with wkhtmltopdf fallback.

    Opens the resulting PDF by default. -NoOpen for batch runs.

    The product version is CONFIG\version.json and is displayed by the
    launcher alone. This header carried "v0.4" while that file said 0.6.1,
    which is the defect audit A8 exists to catch.

    This revision:
      - Block generators emit the markup of the 17/08 A4 prototype
        (REPORTS/FieldOps-Rapport-A4.html): cover, contents, management
        summary, action plan, spectrum, findings, module detail, out of
        scope, conclusion, attestation. Pagination is measured, not assumed.
      - Carries the v0.3 fixes: --headless=new, call-operator invocation,
        Set-StrictMode 1.0, reports auto-open by default.
.PARAMETER DataFile      JSON data file. Default: bundled sample.
.PARAMETER TemplateFile  HTML template. Default: SCRIPTS\Templates\anssi-diagnostic.html
.PARAMETER OutputDir     Output directory. Default: REPORTS\
.PARAMETER NoOpen        Do not open the resulting PDF.
.PARAMETER PdfEngine     'Auto' (default), 'Edge', 'Wkhtmltopdf'.
.PARAMETER NoPdf         Generate only the rendered HTML.
.NOTES
    Author : FieldOps Pro
    Version: 0.4
    Requires: PowerShell 5.1
#>

#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$DataFile,
    [string]$TemplateFile,
    [string]$OutputDir,
    [switch]$NoOpen,
    [ValidateSet('Auto','Edge','Wkhtmltopdf')]
    [string]$PdfEngine = 'Auto',
    [switch]$NoPdf,
    [string]$Language = 'fr'
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

# ===========================================================================
# PATHS
# ===========================================================================
$ScriptRoot  = $PSScriptRoot
if (-not $ScriptRoot) { $ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
$ProjectRoot = Split-Path (Split-Path $ScriptRoot -Parent) -Parent

if (-not $DataFile)     { $DataFile     = Join-Path $ScriptRoot 'report-data.sample.json' }
if (-not $TemplateFile) { $TemplateFile = Join-Path $ProjectRoot 'SCRIPTS\Templates\anssi-diagnostic.html' }
if (-not $OutputDir)    { $OutputDir    = Join-Path $ProjectRoot 'REPORTS' }

if (-not (Test-Path $DataFile))     { throw "Data file not found: $DataFile" }
if (-not (Test-Path $TemplateFile)) { throw "Template not found: $TemplateFile" }
if (-not (Test-Path $OutputDir))    { New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null }

# ===========================================================================
# HELPERS
# ===========================================================================
function Write-Step { param([string]$m) Write-Host "  [+] $m" -ForegroundColor Cyan }
function Write-OK   { param([string]$m) Write-Host "  [OK] $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "  [WARN] $m" -ForegroundColor Yellow }

function ConvertTo-HtmlSafe {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    return ($Text -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;')
}

function Get-StatusClass {
    param([string]$Status)
    if ($Status -match '^(cv|pv|hp)$') { return $Status }
    return 'hp'
}

# report-data.json now carries the localised fields as { fr = ..., en = ... },
# because the evaluators resolve their prose when they run and a single pass
# froze the whole report to one language.
#
# Older data files and all 20 test fixtures carry a plain string. Those must
# still render, so a string is returned unchanged rather than being treated as
# a missing translation -- and a missing language falls back to French rather
# than to empty, so an untranslated field reads as untranslated instead of
# vanishing from the report.
function Get-LocalizedValue {
    param($Value, [string]$Language)
    if ($null -eq $Value) { return '' }
    if ($Value -is [string]) { return $Value }
    $names = @($Value.PSObject.Properties.Name)
    if ($names -contains $Language) {
        $v = "$($Value.$Language)"
        if ($v) { return $v }
    }
    if ($names -contains 'fr') { return "$($Value.fr)" }
    return "$Value"
}

function Get-EdgePath {
    $candidates = @(
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "${env:ProgramFiles}\Microsoft\Edge\Application\msedge.exe",
        "${env:LocalAppData}\Microsoft\Edge\Application\msedge.exe"
    )
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
    return $null
}

function Get-WkhtmltopdfPath {
    $bundled = Join-Path $ProjectRoot 'TOOLS\wkhtmltopdf\wkhtmltopdf.exe'
    if (Test-Path $bundled) { return $bundled }
    $cmd = Get-Command 'wkhtmltopdf.exe' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $candidates = @(
        "${env:ProgramFiles}\wkhtmltopdf\bin\wkhtmltopdf.exe",
        "${env:ProgramFiles(x86)}\wkhtmltopdf\bin\wkhtmltopdf.exe"
    )
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
    return $null
}

# ===========================================================================
# BLOCK GENERATORS -- vocabulaire du prototype A4 (REPORTS/FieldOps-Rapport-A4.html)
# ===========================================================================
# Aucune mise en page n'est inventee ici. Les classes (.pg .rh .bd .fo .big .kf
# .tbl .spr .fd .tk .colo) et leurs regles sont celles du prototype du 17/08.
#
# CE QUI A CHANGE, ET POURQUOI
#   Le premier portage estimait la hauteur des blocs a 88 caracteres par ligne,
#   chiffre repris d'un prototype dont les colonnes n'avaient pas cette largeur.
#   Resultat : 22 pages annoncees, 37 feuilles imprimees, chaque section
#   debordant sur une deuxieme feuille sans folio. Le modele ci-dessous est
#   derive des boites CSS reelles (police, interligne, largeur utile) et a ete
#   valide contre le PDF produit : il predit correctement les 14 debordements
#   observes. Toute section est desormais paginee par le meme empaqueteur --
#   plus seulement les constats -- de sorte qu'aucune ne peut deborder.

# La hauteur utile reelle est d'environ 250 mm (297 - 20 haut - 18 bas - 9 le
# filet de tete). Le budget est volontairement fixe plus bas : une sous-estimation
# de quelques pour cent fait deborder la feuille et casse le contrat des folios,
# alors qu'une surestimation ne coute qu'un peu de blanc en pied de page. Les
# deux erreurs ne sont pas symetriques, le budget penche donc du bon cote.
$script:UsablePageMm = 232.0
$script:PtMm         = 0.3528  # 1 pt = 0.3528 mm


# --------------------------------------------------------------------------
# Acces au bundle de langue
# --------------------------------------------------------------------------
# Les generateurs emettent le texte deja resolu plutot que des jetons {{t:}}.
# Ce n'est pas un raccourci : la hauteur d'un bloc depend de la LONGUEUR de sa
# prose, et un jeton non resolu n'a pas de longueur. Mesurer suppose de lire.
function Get-BundleValue {
    param($Root, [string]$Path)
    $node = $Root
    foreach ($p in $Path.Split('.')) {
        if ($null -eq $node) { return '' }
        $names = @($node.PSObject.Properties.Name)
        if ($names -notcontains $p) { return '' }
        $node = $node.$p
    }
    if ($null -eq $node) { return '' }
    return "$node"
}

function TX {
    param([string]$Path, $Vars)
    $s = Get-BundleValue -Root $script:Bundle -Path $Path
    if (-not $s) {
        Write-Warn "Locale key missing: report.anssi.$Path"
        return ''
    }
    if ($Vars) {
        foreach ($k in @($Vars.Keys)) { $s = $s.Replace(('{' + $k + '}'), [string]$Vars[$k]) }
    }
    return $s
}

# Les nombres partent dans du HTML et du SVG : ils doivent etre ecrits en
# culture invariante. Sur un Windows francais, [string]0.85 vaut "0,85", ce qui
# produit un attribut SVG invalide et une empreinte qui ne s'affiche pas.
function Format-Invariant {
    param([double]$Value, [string]$Format = '0.##')
    return $Value.ToString($Format, [System.Globalization.CultureInfo]::InvariantCulture)
}

# --------------------------------------------------------------------------
# Mesure
# --------------------------------------------------------------------------
function Get-Lines {
    param([string]$Text, [double]$Cpl)
    if (-not $Text) { return 0 }
    return [math]::Max(1, [math]::Ceiling($Text.Length / $Cpl))
}
function Get-TextMm {
    param([string]$Text, [double]$Pt, [double]$Lh, [double]$Cpl)
    return ((Get-Lines -Text $Text -Cpl $Cpl) * $Pt * $Lh * $script:PtMm)
}

# Un bloc : le HTML et la place qu'il prend. Rien d'autre ne circule entre les
# generateurs et l'empaqueteur.
function New-Block {
    param([string]$Html, [double]$HeightMm, [string]$Wrap = '', [string]$Tag = '', [bool]$IsHead = $false)
    return [PSCustomObject]@{ Html = $Html; HeightMm = $HeightMm; Wrap = $Wrap; Tag = $Tag; IsHead = $IsHead }
}

# Regroupe en pages sans depasser le budget. Un bloc plus grand qu'une feuille
# entiere ne peut pas etre coupe : il obtient sa propre feuille.
function Split-IntoPages {
    param($Items, [double]$Budget)
    $pages   = @()
    $current = @()
    $used    = 0.0
    foreach ($item in $Items) {
        $h = [double]$item.HeightMm
        if ((($used + $h) -gt $Budget) -and (@($current).Count -gt 0)) {
            $pages += ,@($current)
            $current = @()
            $used = 0.0
        }
        $current += $item
        $used += $h
    }
    if (@($current).Count -gt 0) { $pages += ,@($current) }
    return ,@($pages)
}

# En-tete courant et folio, identiques sur chaque feuille.
function New-RunningHead {
    param([string]$RhKey, [string]$Suffix = '')
    $right = ConvertTo-HtmlSafe (TX "rh.$RhKey")
    if ($Suffix) { $right = $right + ' ' + $Suffix }
    return ('<div class="rh"><span class="rhl">' + $script:Mark +
            '<b>' + $script:BrandNameHtml + '</b><i>' + (ConvertTo-HtmlSafe (TX 'brand.docLine')) + '</i></span>' +
            "<span class=`"rhr`">$right</span></div>")
}

function New-Folio {
    param([int]$Page, [int]$Total)
    # Le marquage de diffusion figure sur CHAQUE feuille, pas seulement en
    # couverture : une page detachee d'un rapport doit porter sa propre
    # restriction, sinon la restriction ne protege que la reliure.
    $cls = ConvertTo-HtmlSafe $script:Classification
    return ("<div class=`"fo`"><span>{{REPORT_ID}}</span><span class=`"cls`">$cls</span>" +
            "<span>Page $Page / $Total</span></div>")
}

# Emet une section : une feuille par page empaquetee, en-tete et folio sur
# chacune. Les blocs consecutifs partageant un Wrap (une table) sont
# re-enveloppes a chaque page, de sorte qu'une table qui traverse une feuille
# emporte son en-tete de colonnes avec elle.
function Out-Section {
    param([string]$RhKey, [string]$Anchor, $Pages, [int]$PageStart, [int]$Total, [bool]$UseTags = $false)
    $sb = New-Object System.Text.StringBuilder
    $pn = $PageStart
    $i  = 1
    $n  = @($Pages).Count
    foreach ($page in $Pages) {
        $id = ''
        if ($i -eq 1) { $id = " id=`"$Anchor`"" }
        $suffix = ''
        if ($n -gt 1) { $suffix = "$i/$n" }
        if ($UseTags) {
            $tags = @()
            foreach ($b in $page) { if ($b.Tag -and ($tags -notcontains $b.Tag)) { $tags += $b.Tag } }
            if (@($tags).Count -eq 1)      { $suffix = $tags[0] }
            elseif (@($tags).Count -gt 1)  { $suffix = $tags[0] + [char]0x2013 + $tags[-1] }
        }
        [void]$sb.AppendLine("<section class=`"pg`"$id>$(New-RunningHead -RhKey $RhKey -Suffix $suffix)<div class=`"bd`">")
        $openWrap = ''
        foreach ($b in $page) {
            if ($b.Wrap -ne $openWrap) {
                if ($openWrap) { [void]$sb.AppendLine($script:WrapClose[$openWrap]) }
                if ($b.Wrap)   { [void]$sb.AppendLine($script:WrapOpen[$b.Wrap]) }
                $openWrap = $b.Wrap
            }
            [void]$sb.AppendLine($b.Html)
        }
        if ($openWrap) { [void]$sb.AppendLine($script:WrapClose[$openWrap]) }
        [void]$sb.AppendLine("</div>$(New-Folio -Page $pn -Total $Total)</section>")
        $pn++
        $i++
    }
    return $sb.ToString()
}

# Bandeau de tete d'une section : sur-titre, titre, chapeau. Sa hauteur est
# comptee comme celle de n'importe quel bloc, donc il ne fait pas deborder la
# premiere feuille.
function New-IntroBlock {
    param([string]$Eyebrow, [string]$Title, [string]$Lead = '')
    $h = (8.4 * $script:PtMm) + 4.5
    $h += (Get-TextMm -Text $Title -Pt 25.6 -Lh 1.12 -Cpl 30) + 2.25
    $html = '<p class="eb">' + (ConvertTo-HtmlSafe $Eyebrow) + '</p><h2>' + (ConvertTo-HtmlSafe $Title) + '</h2>'
    if ($Lead) {
        $h += (Get-TextMm -Text $Lead -Pt 16.4 -Lh 1.5 -Cpl 42) + 4.5
        $html += '<p class="lead" style="margin-bottom:var(--u)">' + (ConvertTo-HtmlSafe $Lead) + '</p>'
    }
    return (New-Block -Html $html -HeightMm $h)
}

# Hauteur d'un constat, derivee des boites CSS reelles et validee contre le PDF.
function Get-FindingHeightMm {
    param([string]$Title, [string]$Body, [string]$Evidence, [string]$Act)
    $h = 9.0                                                    # .fd padding
    $h += Get-TextMm -Text $Title -Pt 13.1 -Lh 1.35 -Cpl 46     # h4
    $h += 5.6                                                   # .tags
    if ($Body)     { $h += 2.25 + (Get-TextMm -Text $Body -Pt 9.2 -Lh 1.55 -Cpl 62) }
    if ($Evidence) { $h += 1.125 + (8.4 * 1.5 * $script:PtMm) }
    if ($Act) {
        $h += 6.75                                              # marge + padding .act
        $h += (8.4 * $script:PtMm) + 1.125                      # .lb
        $h += Get-TextMm -Text $Act -Pt 9.2 -Lh 1.5 -Cpl 64     # .act p
        $h += 1.125 + (8.4 * $script:PtMm)                      # .actm
    }
    return ($h + 0.5)
}

# Hauteur d'une ligne de table : la cellule la plus haute commande.
function Get-RowHeightMm {
    param([string[]]$Cells, [int[]]$Widths, [bool]$Tight = $false)
    $max = 1
    for ($i = 0; $i -lt $Cells.Length; $i++) {
        $l = Get-Lines -Text $Cells[$i] -Cpl $Widths[$i]
        if ($l -gt $max) { $max = $l }
    }
    $pad = 4.5
    if ($Tight) { $pad = 2.25 }
    return (($max * 9.2 * 1.5 * $script:PtMm) + $pad + 0.3)
}


# --------------------------------------------------------------------------
# Identite de marque : une configuration, pas un litteral
# --------------------------------------------------------------------------
# Le nom du produit etait ecrit en dur dans le modele, dans l'en-tete courant,
# dans les metadonnees PDF et dans cinq chaines traduites par langue. Une
# livraison en marque blanche aurait affiche "Acme Audit" partout et
# "FieldOps Pro" au detour de la regle R38 -- le genre d'incoherence qu'un
# client remarque avant tout le reste.
#
# CONFIG\brand.json porte ce qui ne se traduit pas : un nom, une couleur, une
# marque. Les bundles portent la prose et y renvoient par {product}. Le nom
# n'existe donc qu'a un seul endroit.
function Get-BrandProfile {
    param([string]$ConfigDir)
    # Valeurs de repli : le rapport doit sortir meme si le fichier manque.
    $brand = [PSCustomObject]@{
        ProductName = 'FieldOps Pro'
        SealColor   = '#7A2B2B'
        MarkSvg     = ''
    }
    $path = Join-Path $ConfigDir 'brand.json'
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Warn 'CONFIG\brand.json not found: the report carries the built-in identity.'
        return $brand
    }
    try {
        $j = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        $names = @($j.PSObject.Properties.Name)
        if ($names -contains 'productName' -and $j.productName) { $brand.ProductName = "$($j.productName)" }
        if ($names -contains 'sealColor'   -and $j.sealColor)   { $brand.SealColor   = "$($j.sealColor)" }
        if ($names -contains 'markSvg'     -and $j.markSvg)     { $brand.MarkSvg     = "$($j.markSvg)" }
        if ($brand.SealColor -notmatch '^#[0-9A-Fa-f]{6}$') {
            Write-Warn "brand.json: sealColor '$($brand.SealColor)' is not a #rrggbb colour; the built-in one is used."
            $brand.SealColor = '#7A2B2B'
        }
        Write-OK "Brand profile: $($brand.ProductName)"
    } catch {
        Write-Warn "brand.json could not be read ($($_.Exception.Message)): the built-in identity is used."
    }
    return $brand
}

# La marque, a la taille demandee. Un nom compose ne doit pas se couper en fin
# de ligne : l'espace interne devient insecable dans le HTML.
function Get-BrandMark {
    param($Brand, [int]$Size)
    if (-not $Brand.MarkSvg) { return '' }
    return $Brand.MarkSvg.Replace('{size}', [string]$Size)
}
function Get-BrandNameHtml {
    param($Brand)
    return (ConvertTo-HtmlSafe $Brand.ProductName).Replace(' ', '&nbsp;')
}

# --------------------------------------------------------------------------
# Fontes : l'identite typographique doit VOYAGER avec le rapport
# --------------------------------------------------------------------------
# Le modele demande Spectral, Inter et JetBrains Mono. Aucune n'est installee
# sur un poste Windows courant, et aucune ne peut etre chargee depuis un CDN :
# l'outil travaille hors ligne. Sans embarquement, le navigateur retombait
# silencieusement sur Cambria, Segoe UI et Consolas -- verifie au pdffonts sur
# le tirage du 24/08, ou pas un seul glyphe n'etait celui du modele.
#
# Deux consequences, la seconde pire que la premiere : le document ne
# ressemblait pas a la maquette, et il ne ressemblait PAS AU MEME DOCUMENT d'un
# poste a l'autre, selon les fontes qui s'y trouvaient. Pour une piece signee
# dont deux exemplaires doivent etre comparables, c'est un defaut.
#
# Les fontes sont donc des ressources versionnees (ASSETS\fonts), sous-ensemble
# aux glyphes utiles, encodees en base64 dans le document. Le rapport devient
# identique partout et reste hors ligne. Leur absence est SIGNALEE, jamais
# subie : une degradation silencieuse est ce qui a permis au defaut de durer.
$script:ExpectedFaces = @(
    'spectral-300-normal','spectral-400-normal','spectral-500-normal','spectral-400-italic',
    'inter-400-normal','inter-500-normal','inter-600-normal','inter-400-italic',
    'jetbrains-mono-400-normal','jetbrains-mono-500-normal','jetbrains-mono-600-normal'
)
$script:FontFamilyNames = @{
    'spectral'       = 'Spectral'
    'inter'          = 'Inter'
    'jetbrains-mono' = 'JetBrains Mono'
}

function Get-FontFaceCss {
    param([string]$FontDir)
    if (-not (Test-Path -LiteralPath $FontDir)) {
        Write-Warn "Font directory not found: $FontDir"
        Write-Warn 'The report will render in system fallback fonts and will NOT look the same on another machine.'
        return ''
    }
    $sb = New-Object System.Text.StringBuilder
    $found = 0
    $bytes = 0
    foreach ($face in $script:ExpectedFaces) {
        $path = Join-Path $FontDir ($face + '.woff2')
        if (-not (Test-Path -LiteralPath $path)) {
            Write-Warn "Missing font face: $face.woff2 (this weight will fall back to a system font)"
            continue
        }
        # spectral-400-italic -> famille 'spectral', graisse 400, style italic
        if ($face -notmatch '^(.+)-(\d{3})-(normal|italic)$') {
            Write-Warn "Font file name not understood, skipped: $face.woff2"
            continue
        }
        $famKey = $Matches[1]; $weight = $Matches[2]; $style = $Matches[3]
        $family = $famKey
        if ($script:FontFamilyNames.ContainsKey($famKey)) { $family = $script:FontFamilyNames[$famKey] }
        $raw = [System.IO.File]::ReadAllBytes($path)
        $bytes += $raw.Length
        $b64 = [Convert]::ToBase64String($raw)
        [void]$sb.Append("@font-face{font-family:'$family';font-style:$style;font-weight:$weight;")
        # font-display:block -- l'impression sans interface ne doit jamais partir
        # sur une fonte de substitution en attendant la bonne.
        [void]$sb.Append("font-display:block;src:url(data:font/woff2;base64,$b64) format('woff2')}")
        [void]$sb.AppendLine()
        $found++
    }
    if ($found -eq 0) {
        Write-Warn 'No font embedded: the report falls back to system fonts.'
        return ''
    }
    Write-OK ("Fonts embedded: {0}/{1} faces, {2} KB" -f $found, @($script:ExpectedFaces).Count, [math]::Round($bytes / 1024))
    if ($found -lt @($script:ExpectedFaces).Count) {
        Write-Warn 'Some faces are missing: the document will not be typographically identical elsewhere.'
    }
    return $sb.ToString()
}

# --------------------------------------------------------------------------
# Empreinte visuelle deterministe
# --------------------------------------------------------------------------
# Une grille 5x5 symetrique derivee de l'empreinte des constats. Deux rapports
# du meme poste dans le meme etat portent le meme motif ; un seul verdict qui
# change le transforme. Un lecteur compare deux motifs d'un coup d'oeil la ou
# il ne comparera jamais 64 caracteres hexadecimaux.
#
# Genere en PowerShell, pas en JavaScript : le PDF est imprime en mode sans
# interface et rien ne garantit qu'un script se soit execute avant l'impression.
function New-FingerprintSvg {
    param([string]$Hash, [int]$Cell = 17, [string]$Ink = '#7A2B2B')
    if (-not $Hash) { return '' }
    $n = 5
    $q = 3
    $bytes = @()
    for ($i = 0; $i -lt ($Hash.Length - 1); $i += 2) {
        $bytes += [Convert]::ToInt32($Hash.Substring($i, 2), 16)
    }
    if (@($bytes).Count -eq 0) { return '' }
    $size = $n * $Cell
    $rx   = Format-Invariant ($Cell * 0.15) '0.0'
    $w    = $Cell - 2
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("<svg width=`"$size`" height=`"$size`" viewBox=`"0 0 $size $size`" role=`"img`" aria-label=`"empreinte`">")
    for ($y = 0; $y -lt $n; $y++) {
        for ($x = 0; $x -lt $q; $x++) {
            $v = $bytes[((($y * $q) + $x) % @($bytes).Count)]
            if (($v -band 1) -ne 1) { continue }
            $o = 0.30 + (((($v -shr 1) -band 7)) / 7.0) * 0.70
            $op = Format-Invariant $o '0.00'
            $cols = @($x)
            if (($n - 1 - $x) -ne $x) { $cols += ($n - 1 - $x) }
            foreach ($cx in $cols) {
                $px = ($cx * $Cell) + 1
                $py = ($y * $Cell) + 1
                [void]$sb.Append("<rect x=`"$px`" y=`"$py`" width=`"$w`" height=`"$w`" rx=`"$rx`" fill=`"$Ink`" opacity=`"$op`"/>")
            }
        }
    }
    [void]$sb.Append('</svg>')
    return $sb.ToString()
}

# --------------------------------------------------------------------------
# Mesures : cherchees par regle ET par classe de constat
# --------------------------------------------------------------------------
function Get-MeasureNode {
    param($Measures, [string]$RuleId, [string]$Class)
    if (-not $Measures -or -not $Class) { return $null }
    $names = @($Measures.PSObject.Properties.Name)
    if ($names -contains $RuleId) {
        $forRule = $Measures.$RuleId
        if (@($forRule.PSObject.Properties.Name) -contains $Class) { return $forRule.$Class }
    }
    if ($names -contains 'generic') {
        $generic = $Measures.generic
        if (@($generic.PSObject.Properties.Name) -contains $Class) { return $generic.$Class }
    }
    return $null
}

# Les paliers de charge sont un vocabulaire ferme, donc totalisables. Si un
# palier ne se lit pas, le total est omis plutot que devine.
function ConvertTo-EffortMinutes {
    param([string]$Effort)
    if (-not $Effort -or $Effort -eq '-') { return 0 }
    $e = $Effort.Trim().ToLowerInvariant()
    if ($e -match '^(\d+)\s*min') { return [int]$Matches[1] }
    if ($e -match '^(\d+)\s*h')   { return ([int]$Matches[1]) * 60 }
    if ($e -match '^1/2\s*[jd]')  { return 240 }
    if ($e -match '^(\d+)\s*[jd]'){ return ([int]$Matches[1]) * 480 }
    return -1
}

function Format-EffortTotal {
    param([int]$Minutes, [string]$Language)
    if ($Minutes -le 0) { return '-' }
    if ($Minutes -ge 480) {
        $txt = Format-Invariant ([math]::Round($Minutes / 480.0, 1)) '0.0'
        if ($Language -eq 'fr') { return ($txt.Replace('.', ',') + ' j') }
        return "$txt d"
    }
    $txt = Format-Invariant ([math]::Round($Minutes / 60.0, 1)) '0.0'
    if ($Language -eq 'fr') { return ($txt.Replace('.', ',') + ' h') }
    return "$txt h"
}

# --------------------------------------------------------------------------
# Constats : la severite est LUE dans report-data.json, jamais rededuite
# --------------------------------------------------------------------------
function Get-FindingItems {
    param($ModuleDetails, $Measures, [string]$Language)
    $items = @()
    $sawSeverity = $false
    foreach ($m in $ModuleDetails) {
        foreach ($r in @($m.Rules)) {
            $props = @($r.PSObject.Properties.Name)
            $sv = 0
            if ($props -contains 'Severity') { $sawSeverity = $true; $sv = [int]$r.Severity }
            $fcls = ''
            if ($props -contains 'FindingClass') { $fcls = [string]$r.FindingClass }
            $node = Get-MeasureNode -Measures $Measures -RuleId $r.Id -Class $fcls
            $act  = ''
            if ($node) { $act = "$($node.act)" }
            $items += [PSCustomObject]@{
                Rule = $r; Severity = $sv; FindingClass = $fcls; Measure = $node
                ModuleNumber = $m.Number; ModuleTitle = $m.Title
                Order = [int]($r.Id -replace '\D','')
                Name = (Get-LocalizedValue $r.Name $Language)
                Body = (Get-LocalizedValue $r.Meta $Language)
                Act  = $act
            }
        }
    }
    if (-not $sawSeverity) {
        Write-Warn 'report-data.json carries no Severity field: findings cannot be ranked. Rebuild it with Build-ANSSIData.ps1.'
    }
    return ,@($items)
}

function Get-RankedFindings {
    param($Items)
    return ,@($Items | Where-Object { [int]$_.Severity -ge 1 } | Sort-Object -Property `
        @{ Expression = 'Severity'; Descending = $true }, `
        @{ Expression = 'Order';    Descending = $false })
}

function New-FindingBlock {
    param($F, [int]$Index, [string]$Language)
    $r    = $F.Rule
    $sv   = [int]$F.Severity
    $st   = Get-StatusClass $r.Status
    $rid  = ConvertTo-HtmlSafe $r.Id
    $name = ConvertTo-HtmlSafe $F.Name
    $meta = ConvertTo-HtmlSafe $F.Body
    $ev   = ConvertTo-HtmlSafe $r.Evidence
    $mnum = ConvertTo-HtmlSafe $F.ModuleNumber
    $num  = '{0:D2}' -f $Index
    $cls  = 'fd'
    if ($sv -ge 3) { $cls = 'fd s3' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("<div class=`"$cls`"><div class=`"fdh`"><div class=`"fdn`">$num</div><div><h4>$name</h4>")
    [void]$sb.Append("<div class=`"tags`"><span class=`"rid`">$rid</span>")
    [void]$sb.Append("<span class=`"sv s$sv`">$(ConvertTo-HtmlSafe (TX ("severity.s" + $sv)))</span>")
    [void]$sb.Append("<span class=`"pl $st`"><u></u>$(ConvertTo-HtmlSafe (TX ("status." + $st + "Abbrev")))</span>")
    [void]$sb.Append("<span class=`"mo`">$(ConvertTo-HtmlSafe (TX 'modulePage.label')) $mnum</span></div></div></div>")
    if ($meta) { [void]$sb.Append("<p class=`"obs`">$meta</p>") }
    if ($ev)   { [void]$sb.Append("<p class=`"ev`">$ev</p>") }
    if ($F.Measure) {
        $act = ConvertTo-HtmlSafe $F.Measure.act
        $who = ConvertTo-HtmlSafe $F.Measure.who
        $eff = ConvertTo-HtmlSafe $F.Measure.eff
        [void]$sb.Append("<div class=`"act`"><span class=`"lb`">$(ConvertTo-HtmlSafe (TX 'actionPlan.measureLabel'))</span><p>$act</p><div class=`"actm`"><span>$(ConvertTo-HtmlSafe (TX 'actionPlan.byLabel'))&nbsp;<b>$who</b></span><span>$(ConvertTo-HtmlSafe (TX 'actionPlan.effortLabel'))&nbsp;<b>$eff</b></span></div></div>")
    }
    [void]$sb.Append('</div>')
    $h = Get-FindingHeightMm -Title $F.Name -Body $F.Body -Evidence $r.Evidence -Act $F.Act
    return (New-Block -Html $sb.ToString() -HeightMm $h)
}

# --------------------------------------------------------------------------
# Les sections, chacune rendue comme une liste de blocs mesures
# --------------------------------------------------------------------------
$script:WrapOpen = @{}
$script:WrapClose = @{}

function Register-TableWrap {
    param([string]$Name, [string]$Class, [string[]]$Headers)
    $th = ''
    foreach ($h in $Headers) { $th += '<th>' + (ConvertTo-HtmlSafe $h) + '</th>' }
    $script:WrapOpen[$Name]  = "<table class=`"$Class`"><thead><tr>$th</tr></thead><tbody>"
    $script:WrapClose[$Name] = '</tbody></table>'
}

function Get-SummaryBlocks {
    param($Summary, $ModuleDetails, $Ranked, [int]$Evaluable, [int]$BlindCount,
          [string]$EffortTotal, $Sources, [string]$Language)
    $b = @()
    $b += New-IntroBlock -Eyebrow (TX 'summary.eyebrow') -Title (TX 'summary.title')

    $cv = [int]$Summary.CountCV; $pv = [int]$Summary.CountPV; $hp = [int]$Summary.CountHP
    $big = '<div class="big">' +
      "<div><b>$cv</b><span>$(ConvertTo-HtmlSafe (TX 'summary.cvLabel'))</span><em>$(ConvertTo-HtmlSafe (TX 'summary.cvBody'))</em></div>" +
      "<div><b>$pv</b><span>$(ConvertTo-HtmlSafe (TX 'summary.pvLabel'))</span><em>$(ConvertTo-HtmlSafe (TX 'summary.pvBody'))</em></div>" +
      "<div><b>$hp</b><span>$(ConvertTo-HtmlSafe (TX 'summary.hpLabel'))</span><em>$(ConvertTo-HtmlSafe (TX 'summary.hpBody'))</em></div></div>"
    $b += New-Block -Html $big -HeightMm 34.0

    $kfVars = @{ evaluable = "<b>$Evaluable</b>"; cvCount = "<b>$cv</b>"; pvCount = "<b>$pv</b>"; blindCount = "<b>$BlindCount</b>" }
    $kfBody = TX 'summary.keyFigureBody' $kfVars
    $kfEff  = TX 'summary.effortLine' @{ effortTotal = $EffortTotal }
    $kf = '<div class="kf"><p><b>' + (ConvertTo-HtmlSafe (TX 'summary.keyFigureLead')) + '</b> ' +
          $kfBody + ' <b>' + (ConvertTo-HtmlSafe $kfEff) + '</b></p></div>'
    $b += New-Block -Html $kf -HeightMm ((Get-TextMm -Text ($kfBody + $kfEff) -Pt 10.5 -Lh 1.5 -Cpl 88) + 9.0)

    # LA PAGE QUE LIT UN DIRIGEANT DOIT DIRE L'AGE DE CE QU'ELLE RESUME.
    # "7 conformes" sans "observe il y a 99 jours" surestime la confiance, et
    # la page de provenance arrive trente feuilles trop tard pour corriger.
    if ($Sources -and @($Sources).Count -gt 0) {
        # Trier par age en jours laisse les ex aequo se departager au hasard : le
        # 24/08, deux sources du 14/05 avaient toutes deux 101 jours et la ligne
        # a nomme celle de 20h31 alors que celle de 20h30 est anterieure. Le
        # nombre etait juste, la date citee ne l'etait pas. L'horodatage complet
        # ne connait pas d'ex aequo.
        $oldest = @($Sources | Sort-Object { [datetime]$_.ObservedAt })[0]
        $age = [int]$oldest.AgeDays
        if ($age -ge 30) {
            $fb = TX 'summary.freshnessBody' @{ oldestDate = "$($oldest.ObservedAtHuman)"; oldestAge = $age; page = '{{PROV_PAGE}}' }
            $html = '<div class="kf stale"><p><b>' + (ConvertTo-HtmlSafe (TX 'summary.freshnessLead')) + '</b> ' + (ConvertTo-HtmlSafe $fb) + '</p></div>'
        } else {
            $fb = TX 'summary.freshnessFresh' @{ page = '{{PROV_PAGE}}' }
            $html = '<p class="sm">' + (ConvertTo-HtmlSafe $fb) + '</p>'
        }
        $b += New-Block -Html $html -HeightMm ((Get-TextMm -Text $fb -Pt 10.5 -Lh 1.5 -Cpl 88) + 9.0)
    }

    $b += New-Block -Html ('<h3 style="margin-top:var(--u)">' + (ConvertTo-HtmlSafe (TX 'summary.urgentTitle')) + '</h3>') -HeightMm 8.0
    $urgent = @($Ranked | Where-Object { [int]$_.Severity -ge 3 })
    if (@($urgent).Count -eq 0) {
        $b += New-Block -Html ('<p class="none">' + (ConvertTo-HtmlSafe (TX 'summary.noUrgent')) + '</p>') -HeightMm 8.0
    } else {
        Register-TableWrap -Name 'urgent' -Class 'tbl' -Headers @(
            (TX 'summary.thRule'), (TX 'summary.thObject'),
            (TX 'actionPlan.measureLabel'), (TX 'actionPlan.effortLabel'))
        foreach ($f in $urgent) {
            $rid = ConvertTo-HtmlSafe $f.Rule.Id
            $act = '-' ; $eff = '-'
            if ($f.Measure) { $act = "$($f.Measure.act)"; $eff = "$($f.Measure.eff)" }
            $row = "<tr><td class=`"n`">$rid</td><td>$(ConvertTo-HtmlSafe $f.Name)</td><td>$(ConvertTo-HtmlSafe $act)</td><td class=`"n`">$(ConvertTo-HtmlSafe $eff)</td></tr>"
            $h = Get-RowHeightMm -Cells @($f.Rule.Id, $f.Name, $act, $eff) -Widths @(10, 44, 46, 10)
            $b += New-Block -Html $row -HeightMm $h -Wrap 'urgent'
        }
    }

    $b += New-Block -Html ('<h3 style="margin-top:var(--u)">' + (ConvertTo-HtmlSafe (TX 'overview.moduleCoverageTitle')) + '</h3>') -HeightMm 8.0
    Register-TableWrap -Name 'coverage' -Class 'tbl tight' -Headers @(
        (TX 'summary.thModule'), (TX 'summary.thTitle'),
        (TX 'status.cvAbbrev'), (TX 'status.pvAbbrev'), (TX 'status.hpAbbrev'))
    foreach ($m in $ModuleDetails) {
        $rules = @($m.Rules)
        $c = @($rules | Where-Object { $_.Status -eq 'cv' }).Count
        $p = @($rules | Where-Object { $_.Status -eq 'pv' }).Count
        $x = @($rules | Where-Object { $_.Status -eq 'hp' }).Count
        $num   = ConvertTo-HtmlSafe $m.Number
        $title = Get-LocalizedValue $m.Title $Language
        $row = "<tr><td class=`"n`">$num</td><td>$(ConvertTo-HtmlSafe $title)</td><td class=`"n`">$c</td><td class=`"n`">$p</td><td class=`"n`">$x</td></tr>"
        $b += New-Block -Html $row -HeightMm (Get-RowHeightMm -Cells @($m.Number, $title, '0','0','0') -Widths @(8, 70, 6, 6, 6) -Tight $true) -Wrap 'coverage'
    }
    $tot = "<tr class=`"tot`"><td></td><td>$(ConvertTo-HtmlSafe (TX 'summary.total'))</td><td class=`"n`">$cv</td><td class=`"n`">$pv</td><td class=`"n`">$hp</td></tr>"
    $b += New-Block -Html $tot -HeightMm 6.0 -Wrap 'coverage'
    return ,@($b)
}

function Get-ActionPlanBlocks {
    param($Ranked, [string]$Language)
    $groups = @{}
    $order  = @()
    foreach ($f in $Ranked) {
        if (-not $f.Measure) { continue }
        $who = "$($f.Measure.who)"
        if (-not $who -or $who -eq '-') { continue }
        if (-not $groups.ContainsKey($who)) { $groups[$who] = @(); $order += $who }
        $groups[$who] += $f
    }
    $b = @()
    $b += New-IntroBlock -Eyebrow (TX 'rh.plan') -Title (TX 'actionPlan.title') -Lead (TX 'actionPlan.lead')
    foreach ($who in $order) {
        $mins = 0
        $unknown = $false
        foreach ($f in $groups[$who]) {
            $m = ConvertTo-EffortMinutes ("$($f.Measure.eff)")
            if ($m -lt 0) { $unknown = $true } else { $mins += $m }
        }
        $tot = '-'
        if (-not $unknown) { $tot = Format-EffortTotal -Minutes $mins -Language $Language }
        $count = @($groups[$who]).Count
        $head = "<div class=`"pl3`"><h4>$(ConvertTo-HtmlSafe $who) &mdash; $count $(ConvertTo-HtmlSafe (TX 'actionPlan.unit')) &middot; $tot</h4></div>"
        $b += New-Block -Html $head -HeightMm 10.0
        foreach ($f in $groups[$who]) {
            $rid  = ConvertTo-HtmlSafe $f.Rule.Id
            $name = ConvertTo-HtmlSafe $f.Name
            $act  = "$($f.Measure.act)"
            $eff  = ConvertTo-HtmlSafe $f.Measure.eff
            $row = "<div class=`"tk`"><span class=`"bx`"></span><span class=`"t`"><b>$rid &middot; $name</b><span>$(ConvertTo-HtmlSafe $act)</span></span><span class=`"w`">$eff</span><span class=`"c`">$(ConvertTo-HtmlSafe (TX 'actionPlan.doneLabel'))</span></div>"
            $h = 4.5 + (Get-TextMm -Text ($f.Rule.Id + $f.Name) -Pt 9.2 -Lh 1.5 -Cpl 62) +
                       (Get-TextMm -Text $act -Pt 8.4 -Lh 1.5 -Cpl 68) + 0.3
            $b += New-Block -Html $row -HeightMm $h
        }
    }
    return ,@($b)
}

function Get-SpectrumBlocks {
    param($ModuleDetails, $Summary, [string]$Language)
    $b = @()
    $b += New-IntroBlock -Eyebrow (TX 'overview.sectionTitle') -Title (TX 'spectrum.title') -Lead (TX 'spectrum.lead')
    foreach ($m in $ModuleDetails) {
        $num   = ConvertTo-HtmlSafe $m.Number
        $title = ConvertTo-HtmlSafe (Get-LocalizedValue $m.Title $Language)
        $row = "<div class=`"spr`"><span class=`"spn`">$num</span><span class=`"spq`">"
        foreach ($r in @($m.Rules)) {
            $st   = Get-StatusClass $r.Status
            $rid  = ConvertTo-HtmlSafe $r.Id
            $name = ConvertTo-HtmlSafe (Get-LocalizedValue $r.Name $Language)
            $row += "<span class=`"sqw`"><i class=`"sq $st`" title=`"$rid &mdash; $name`"></i></span>"
        }
        $row += "</span><span class=`"spt`">$title</span></div>"
        $b += New-Block -Html $row -HeightMm 12.0
    }
    $leg = '<div class="leg">' +
      "<span><i style=`"background:var(--cv)`"></i>$(ConvertTo-HtmlSafe (TX 'status.cvLong')) &mdash; $($Summary.CountCV)</span>" +
      "<span><i style=`"background:var(--pv)`"></i>$(ConvertTo-HtmlSafe (TX 'status.pvLong')) &mdash; $($Summary.CountPV)</span>" +
      "<span><i style=`"background:#CFC9BB`"></i>$(ConvertTo-HtmlSafe (TX 'status.hpLong')) &mdash; $($Summary.CountHP)</span></div>"
    $b += New-Block -Html $leg -HeightMm 12.0
    $why = TX 'spectrum.whyBody'
    $b += New-Block -Html ('<div class="kf" style="margin-top:var(--u)"><p><b>' + (ConvertTo-HtmlSafe (TX 'spectrum.whyLead')) + '</b> ' + (ConvertTo-HtmlSafe $why) + '</p></div>') `
                    -HeightMm ((Get-TextMm -Text $why -Pt 10.5 -Lh 1.5 -Cpl 88) + 9.0)
    return ,@($b)
}

function Get-ModuleBlocks {
    param($Items, [string]$Language)
    $b = @()
    $last = ''
    foreach ($f in $Items) {
        $mnum = ConvertTo-HtmlSafe $f.ModuleNumber
        $mtit = Get-LocalizedValue $f.ModuleTitle $Language
        if ($mnum -ne $last) {
            $mh = "<div class=`"mh`"><p class=`"eb`">$(ConvertTo-HtmlSafe (TX 'modulePage.label')) $mnum</p><h2 style=`"font-size:var(--t4)`">$(ConvertTo-HtmlSafe $mtit)</h2></div>"
            $b += New-Block -Html $mh -HeightMm 18.0 -Tag $mnum -IsHead $true
            $last = $mnum
        }
        $r    = $f.Rule
        $st   = Get-StatusClass $r.Status
        $rid  = ConvertTo-HtmlSafe $r.Id
        $name = ConvertTo-HtmlSafe $f.Name
        $meta = ConvertTo-HtmlSafe $f.Body
        $ev   = ConvertTo-HtmlSafe $r.Evidence
        $html = "<div class=`"fd`" id=`"$rid`"><div class=`"fdh`"><div class=`"fdn`" style=`"font-size:var(--t3);color:var(--seal)`">$rid</div><div><h4>$name</h4></div><span><span class=`"pl $st`"><u></u>$(ConvertTo-HtmlSafe (TX ('status.' + $st + 'Long')))</span></span></div>"
        if ($meta) { $html += "<p class=`"obs`">$meta</p>" }
        if ($ev)   { $html += "<p class=`"ev`">$ev</p>" }
        # Une regle hors perimetre ne porte pas de mesure technique, et la
        # section qui leur est consacree le dit une fois. Repeter ici la meme
        # phrase generique seize fois n'apprend rien et coute deux feuilles.
        $actText = $f.Act
        if ($st -eq 'hp') { $actText = '' }
        if ($f.Measure -and $actText) {
            $act = ConvertTo-HtmlSafe $f.Measure.act
            $who = ConvertTo-HtmlSafe $f.Measure.who
            $eff = ConvertTo-HtmlSafe $f.Measure.eff
            $acls = 'act'
            if ($who -eq '-') { $acls = 'act none' }
            $html += "<div class=`"$acls`"><span class=`"lb`">$(ConvertTo-HtmlSafe (TX 'actionPlan.measureLabel'))</span><p>$act</p><div class=`"actm`"><span>$(ConvertTo-HtmlSafe (TX 'actionPlan.byLabel'))&nbsp;<b>$who</b></span><span>$(ConvertTo-HtmlSafe (TX 'actionPlan.effortLabel'))&nbsp;<b>$eff</b></span></div></div>"
        }
        $html += '</div>'
        $b += New-Block -Html $html -HeightMm (Get-FindingHeightMm -Title $f.Name -Body $f.Body -Evidence $r.Evidence -Act $actText) -Tag $mnum
    }
    return ,@($b)
}

# Une feuille qui reprend un module commence sous son titre, marque "suite".
# Sans cela, la feuille 23 s'ouvre sur une regle sans dire de quel module elle
# releve -- le lecteur doit remonter deux pages pour le savoir.
#
# Le cout de ce titre est reserve AVANT l'empaquetage (le budget du module est
# reduit d'autant), de sorte que l'inserer apres coup ne peut pas faire deborder
# la feuille.
function Add-ModuleContinuations {
    param($Pages, $Items, [string]$Language)
    $titles = @{}
    foreach ($f in $Items) {
        $k = ConvertTo-HtmlSafe $f.ModuleNumber
        if (-not $titles.ContainsKey($k)) { $titles[$k] = Get-LocalizedValue $f.ModuleTitle $Language }
    }
    $out = @()
    foreach ($page in $Pages) {
        $first = @($page)[0]
        if ($first.IsHead -or -not $first.Tag) { $out += ,@($page); continue }
        $mnum = $first.Tag
        $mtit = ''
        if ($titles.ContainsKey($mnum)) { $mtit = $titles[$mnum] }
        # Une ligne suffit : l'en-tete courant de la feuille porte deja le numero
        # du module. Reprendre le titre entier couterait deux feuilles pour
        # redire ce qui est ecrit dix millimetres plus haut.
        $mh = "<p class=`"eb cont`">$(ConvertTo-HtmlSafe (TX 'modulePage.label')) $mnum &mdash; $(ConvertTo-HtmlSafe (TX 'modulePage.continued')) &middot; $(ConvertTo-HtmlSafe $mtit)</p>"
        $out += ,@(@(New-Block -Html $mh -HeightMm 9.0 -Tag $mnum -IsHead $true) + @($page))
    }
    return ,@($out)
}

function Get-OutOfScopeBlocks {
    param($ModuleDetails, [int]$HpCount, [string]$Language)
    $b = @()
    $b += New-IntroBlock -Eyebrow (TX 'rh.outOfScope') -Title (TX 'outOfScope.title' @{ hpCount = $HpCount }) -Lead (TX 'outOfScope.lead')
    Register-TableWrap -Name 'oos' -Class 'tbl tight' -Headers @(
        (TX 'outOfScope.thRule'), (TX 'outOfScope.thTitle'),
        (TX 'outOfScope.thModule'), (TX 'outOfScope.thReason'))
    foreach ($m in $ModuleDetails) {
        foreach ($r in @($m.Rules)) {
            if ($r.Status -ne 'hp') { continue }
            $rid  = ConvertTo-HtmlSafe $r.Id
            $name = Get-LocalizedValue $r.Name $Language
            $mnum = ConvertTo-HtmlSafe $m.Number
            $why  = Get-LocalizedValue $r.Meta $Language
            $row = "<tr><td class=`"n`">$rid</td><td>$(ConvertTo-HtmlSafe $name)</td><td class=`"n`">$mnum</td><td>$(ConvertTo-HtmlSafe $why)</td></tr>"
            $b += New-Block -Html $row -HeightMm (Get-RowHeightMm -Cells @($r.Id, $name, $m.Number, $why) -Widths @(8, 40, 8, 46) -Tight $true) -Wrap 'oos'
        }
    }
    return ,@($b)
}

# --------------------------------------------------------------------------
# Provenance et integrite
# --------------------------------------------------------------------------
# La section que ce rapport n'avait pas et qu'un auditeur reclame en premier :
# d'ou viennent les constats, quand ont-ils ete OBSERVES, et comment verifier
# que le document n'a pas bouge depuis.
#
# La date d'observation n'est pas la date d'emission. Un rapport emis
# aujourd'hui a partir d'un scan de mai decrit l'etat du poste en mai. Le
# taire serait une faute : la fraicheur de chaque source est imprimee, et
# l'ecart en jours avec l'emission avec elle.
function Get-ProvenanceBlocks {
    param($Sources, [string]$VerdictDigest, [string]$Language)
    $b = @()
    $b += New-IntroBlock -Eyebrow (TX 'rh.provenance') -Title (TX 'provenance.title') -Lead (TX 'provenance.lead')

    if (-not $Sources -or @($Sources).Count -eq 0) {
        $b += New-Block -Html ('<p class="none">' + (ConvertTo-HtmlSafe (TX 'provenance.noSources')) + '</p>') -HeightMm 8.0
    } else {
        Register-TableWrap -Name 'prov' -Class 'tbl tight' -Headers @(
            (TX 'provenance.thEngine'), (TX 'provenance.thObserved'),
            (TX 'provenance.thAge'), (TX 'provenance.thHash'))
        foreach ($s in $Sources) {
            $eng  = ConvertTo-HtmlSafe "$($s.Engine)"
            $file = ConvertTo-HtmlSafe "$($s.File)"
            $obs  = ConvertTo-HtmlSafe "$($s.ObservedAtHuman)"
            $age  = [int]$s.AgeDays
            $ageTxt = TX 'provenance.ageDays' @{ days = $age }
            $cls = 'n'
            if ($age -ge 30) { $cls = 'n stale' }
            $hash = ConvertTo-HtmlSafe "$($s.Sha256)"
            $short = $hash
            if ($short.Length -gt 24) { $short = $short.Substring(0, 24) + [char]0x2026 }
            $row = "<tr><td><b>$eng</b><br><span class=`"fnm`">$file</span></td><td class=`"n`">$obs</td><td class=`"$cls`">$(ConvertTo-HtmlSafe $ageTxt)</td><td class=`"n hsh`">$short</td></tr>"
            $b += New-Block -Html $row -HeightMm 12.0 -Wrap 'prov'
        }
        $b += New-Block -Html ('<p class="sm" style="margin-top:var(--u2)">' + (ConvertTo-HtmlSafe (TX 'provenance.staleNote')) + '</p>') -HeightMm 10.0
    }

    # Empreinte des constats : independante de la langue et de la mise en page.
    $fp = New-FingerprintSvg -Hash $VerdictDigest -Cell 17
    $vd = '<h3 style="margin-top:var(--u)">' + (ConvertTo-HtmlSafe (TX 'provenance.verdictTitle')) + '</h3>' +
          '<p class="sm">' + (ConvertTo-HtmlSafe (TX 'provenance.verdictBody')) + '</p>' +
          '<div class="fpwrap"><div class="fpb">' + $fp + '</div><div><div class="digest-block">' +
          (ConvertTo-HtmlSafe $VerdictDigest) + '</div></div></div>'
    $b += New-Block -Html $vd -HeightMm 58.0

    $eng = TX 'provenance.engineBody' @{ version = $script:ProductVersion }
    $b += New-Block -Html ('<h3 style="margin-top:var(--u)">' + (ConvertTo-HtmlSafe (TX 'provenance.engineTitle')) + '</h3>' +
                           '<p class="sm">' + (ConvertTo-HtmlSafe $eng) + '</p>') `
                    -HeightMm (12.0 + (Get-TextMm -Text $eng -Pt 9.2 -Lh 1.5 -Cpl 86) + 4.5)

    $doc = '<h3>' + (ConvertTo-HtmlSafe (TX 'provenance.documentTitle')) + '</h3>' +
           '<p class="sm">' + (ConvertTo-HtmlSafe (TX 'provenance.documentBody')) + '</p>' +
           '<div class="hash-block">{{REPORT_HASH}}</div>' +
           '<p class="sm" style="margin-top:var(--u2)">' + (ConvertTo-HtmlSafe (TX 'provenance.verifyLead')) + '</p>' +
           '<div class="cmd"><code>certutil -hashfile "{{REPORT_ID}}.html" SHA256</code></div>'
    $b += New-Block -Html $doc -HeightMm 62.0

    # Un rapport qu'on peut signer et une empreinte qui tient : les deux ne se
    # contredisent que si l'on ne dit pas sur quoi chaque empreinte porte.
    $sc = TX 'provenance.signedCopyBody'
    $b += New-Block -Html ('<h3 style="margin-top:var(--u)">' + (ConvertTo-HtmlSafe (TX 'provenance.signedCopyTitle')) + '</h3>' +
                           '<p class="sm">' + (ConvertTo-HtmlSafe $sc) + '</p>') `
                    -HeightMm (12.0 + (Get-TextMm -Text $sc -Pt 9.2 -Lh 1.5 -Cpl 86) + 4.5)
    return ,@($b)
}

# --------------------------------------------------------------------------
# Sommaire
# --------------------------------------------------------------------------
# Derive de la meme liste de sections qui place les pages : il ne peut donc pas
# les contredire.
function Get-TocBlocks {
    param($Sections, [int]$PageTotal, [string]$Hostname, [string]$ReportId, [string]$DateHuman)
    $b = @()
    $b += New-IntroBlock -Eyebrow (TX 'toc.eyebrow') -Title (TX 'toc.title')
    $n = 1
    foreach ($s in $Sections) {
        $anchor = ConvertTo-HtmlSafe $s.Anchor
        $label  = ConvertTo-HtmlSafe (TX ('toc.sections.' + $s.Key))
        $p      = [int]$s.Page
        $b += New-Block -Html "<a href=`"#$anchor`"><span class=`"tl`"><span class=`"tn`">$n</span><span class=`"tt`">$label</span></span><span class=`"tf`">$p</span></a>" `
                        -HeightMm 9.0 -Wrap 'toc'
        $n++
    }
    $sum = TX 'toc.summary' @{ pages = $PageTotal; hostname = $Hostname; reportId = $ReportId; dateHuman = $DateHuman }
    $b += New-Block -Html ('<p class="sm" style="margin-top:var(--u)">' + (ConvertTo-HtmlSafe $sum) + '</p>') -HeightMm 12.0
    return ,@($b)
}


# --------------------------------------------------------------------------
# Conclusion et attestation
# --------------------------------------------------------------------------
# Ces deux pages vivaient dans le modele, hors de l'empaqueteur, et etaient
# donc les deux seules du document dont personne ne mesurait la hauteur. Une
# traduction plus longue ou un nom d'organisation etendu les faisait deborder
# en silence -- exactement le defaut que le reste de cette refonte elimine.
# Elles sont dimensionnees pour tenir sur une feuille chacune ; si un jour
# elles n'y tiennent plus, elles se paginent et le disent.
function Get-ConclusionBlocks {
    param($Summary, [int]$BlindCount, [string]$EffortTotal, [string]$Language)
    $cv = [int]$Summary.CountCV; $pv = [int]$Summary.CountPV; $hp = [int]$Summary.CountHP
    $v = @{ cvCount = "<b>$cv</b>"; pvCount = "<b>$pv</b>"; hpCount = "<b>$hp</b>"; blindCount = "<b>$BlindCount</b>" }
    $b = @()
    $lead = TX 'conclusion.lead' $v
    $intro = New-IntroBlock -Eyebrow (TX 'rh.conclusion') -Title (TX 'conclusion.title')
    $b += $intro
    $b += New-Block -Html ('<p class="lead">' + $lead + '</p>') -HeightMm ((Get-TextMm -Text $lead -Pt 16.4 -Lh 1.5 -Cpl 42) + 4.5)
    foreach ($pair in @(
        @('conclusion.saysTitle',    'conclusion.saysBody'),
        @('conclusion.notSaysTitle', 'conclusion.notSaysBody'),
        @('conclusion.otherTitle',   'conclusion.otherBody'))) {
        $body = TX $pair[1] $v
        $html = '<h3 style="margin-top:var(--u)">' + (ConvertTo-HtmlSafe (TX $pair[0])) + '</h3><p>' + $body + '</p>'
        $b += New-Block -Html $html -HeightMm (12.0 + (Get-TextMm -Text $body -Pt 10.5 -Lh 1.5 -Cpl 88) + 4.5)
    }
    $b += New-Block -Html ('<h3 style="margin-top:var(--u)">' + (ConvertTo-HtmlSafe (TX 'conclusion.limitsLabel')) + '</h3>') -HeightMm 12.0
    $li = ''
    $liH = 0.0
    foreach ($k in @('conclusion.limit1','conclusion.limit2','conclusion.limit3','conclusion.limit4','conclusion.limit5')) {
        $txt = TX $k
        $li += '<li>' + (ConvertTo-HtmlSafe $txt) + '</li>'
        $liH += (Get-TextMm -Text $txt -Pt 9.2 -Lh 1.5 -Cpl 86) + 4.8
    }
    $b += New-Block -Html ('<ul class="li">' + $li + '</ul>') -HeightMm $liH
    return ,@($b)
}

function Get-AttestationBlocks {
    param($VerdictDigest, [int]$PageTotal, [int]$ProvenancePage, [string]$Hostname,
          [string]$DateHuman, [string]$Technician, [string]$Contact, [string]$Language)
    $b = @()
    $b += New-IntroBlock -Eyebrow (TX 'rh.attestation') -Title (TX 'attestation.title')

    # Ce que le signataire atteste, et sur quelle etendue. Une page de
    # signatures qui ne dit pas de combien de pages elle repond n'atteste rien :
    # il suffit d'en retirer une.
    $decl = TX 'attestation.declarationBody' @{ hostname = $Hostname; dateHuman = $DateHuman }
    $ext  = TX 'attestation.extent' @{ pages = $PageTotal }
    $html = '<div class="kf"><p>' + (ConvertTo-HtmlSafe $decl) + '</p>' +
            '<p style="margin-top:var(--u2)"><b>' + (ConvertTo-HtmlSafe $ext) + '</b></p></div>'
    $b += New-Block -Html $html -HeightMm ((Get-TextMm -Text $decl -Pt 10.5 -Lh 1.5 -Cpl 88) +
                                           (Get-TextMm -Text $ext  -Pt 10.5 -Lh 1.5 -Cpl 88) + 11.0)

    # L'empreinte des constats, avec son motif. C'est elle que les signatures
    # engagent, pas celle du fichier : une correction de mise en page ne doit
    # pas rendre une signature caduque.
    $hint = TX 'attestation.verdictHint' @{ page = $ProvenancePage }
    $fp = New-FingerprintSvg -Hash $VerdictDigest -Cell 17
    $html = '<h3 style="margin-top:var(--u)">' + (ConvertTo-HtmlSafe (TX 'attestation.verdictLabel')) + '</h3>' +
            '<div class="fpwrap"><div class="fpb">' + $fp + '</div><div class="fpx">' +
            '<div class="digest-block">' + (ConvertTo-HtmlSafe $VerdictDigest) + '</div>' +
            '<p class="fph">' + (ConvertTo-HtmlSafe $hint) + '</p></div></div>'
    # Hauteur gouvernee par le motif : 5 x 17 px = 22,5 mm, plus le cadre
    # (2 x 2,25 mm) et les marges, soit 31,5 mm. La colonne de droite est plus
    # courte : l'empreinte tient sur une ligne (64 caracteres de mono 8,4 pt
    # dans 115 mm) et sa note sur deux. Mesure relevee sur la page 37 imprimee,
    # ou l'estimation precedente de 45 mm surevaluait de treize millimetres.
    $b += New-Block -Html $html -HeightMm 33.0

    # Ce que le lecteur doit pouvoir constater sans nous croire sur parole :
    # ou s'arrete l'inscriptible et ou commence le fige.
    $wn = TX 'attestation.writableNote' @{ count = 12 }
    $b += New-Block -Html ('<h3 style="margin-top:var(--u)">' + (ConvertTo-HtmlSafe (TX 'attestation.signaturesTitle')) + '</h3>' +
                           '<p class="sm" style="max-width:150mm">' + (ConvertTo-HtmlSafe $wn) + '</p>') `
                    -HeightMm (12.0 + (Get-TextMm -Text $wn -Pt 9.2 -Lh 1.5 -Cpl 86) + 4.5)

    # SMART, MAIS SANS TOUCHER A L'AUTHENTIFICATION
    # Trois regles tenues ici :
    #   1. l'outil ne pre-remplit que ce qu'il a observe. Le nom du technicien
    #      vient de l'execution ; le destinataire, l'outil ne le connait pas,
    #      donc le champ reste VIDE. Ecrire "A completer" dans une valeur en
    #      fait une donnee du document, imprimee puis signee comme si c'en
    #      etait une. Un filigrane n'est pas un nom.
    #   2. rien de ce que l'outil pre-remplit n'entre dans le lien de signature.
    #      Le champ d'empreinte reste vide par construction : c'est la main du
    #      signataire qui lie la page a ce rapport-ci, et une machine ne peut
    #      pas produire cette main.
    #   3. chaque bloc dit ce que signer y engage. Une contre-signature muette
    #      se lit comme un aval sur le fond ; le destinataire accuse reception,
    #      il n'atteste pas les constats.
    $fName = ConvertTo-HtmlSafe (TX 'attestation.nameLabel')
    $fOrg  = ConvertTo-HtmlSafe (TX 'attestation.orgLabel')
    $fOrgP = ConvertTo-HtmlSafe (TX 'attestation.orgPlaceholder')
    $fRole = ConvertTo-HtmlSafe (TX 'attestation.roleLabel')
    $fRoleP= ConvertTo-HtmlSafe (TX 'attestation.rolePlaceholder')
    $fDig  = ConvertTo-HtmlSafe (TX 'attestation.digestFieldLabel')
    $d8    = ''
    if ($VerdictDigest -and $VerdictDigest.Length -ge 8) { $d8 = $VerdictDigest.Substring(0,8) }
    $fDigP = ConvertTo-HtmlSafe (TX 'attestation.digestFieldHint' @{ digest8 = $d8 })
    $fPl   = ConvertTo-HtmlSafe (TX 'attestation.placeLabel')
    $fPlP  = ConvertTo-HtmlSafe (TX 'attestation.placePlaceholder')
    $fDt   = ConvertTo-HtmlSafe (TX 'attestation.dateLabel')
    $fDtP  = ConvertTo-HtmlSafe (TX 'attestation.datePlaceholder')
    $fSg   = ConvertTo-HtmlSafe (TX 'attestation.signLabel')
    $atr   = 'data-sig="1" autocomplete="off" spellcheck="false"'
    $datr  = $atr + ' maxlength="8" pattern="[0-9a-f]{8}" inputmode="latin" autocapitalize="off"'

    # Une valeur connue est ecrite ; une valeur inconnue laisse parler le
    # placeholder, qui ne s'imprime pas comme une donnee.
    $techVal = ''
    if ($Technician) { $techVal = " value=`"$(ConvertTo-HtmlSafe $Technician)`"" }
    $contactVal = ''
    if ($Contact -and ($Contact -notmatch '^(A completer|A compl.ter|To be completed|-)$')) {
        $contactVal = " value=`"$(ConvertTo-HtmlSafe $Contact)`""
    }
    $contactP = ConvertTo-HtmlSafe (TX 'conclusion.contactPlaceholder')

    $sig = '<div class="sig">' +
      '<div class="sgb"><p class="l">' + (ConvertTo-HtmlSafe (TX 'conclusion.technicianLabel')) +
        '<span class="rl">' + (ConvertTo-HtmlSafe (TX 'attestation.technicianRole')) + '</span></p>' +
      "<label class=`"fk`" for=`"t1`">$fName</label><input class=`"fi`" id=`"t1`" name=`"tech.name`" $atr$techVal>" +
      "<label class=`"fk`" for=`"t2`">$fOrg</label><input class=`"fi`" id=`"t2`" name=`"tech.org`" $atr placeholder=`"$fOrgP`">" +
      "<label class=`"fk`" for=`"t4`">$fDig</label><input class=`"fi mono8`" id=`"t4`" name=`"tech.digest8`" $datr placeholder=`"$fDigP`">" +
      '<div class="pd">' +
        "<div><label class=`"fk`" for=`"t5`">$fPl</label><input class=`"fi`" id=`"t5`" name=`"tech.place`" $atr placeholder=`"$fPlP`"></div>" +
        "<div><label class=`"fk`" for=`"t6`">$fDt</label><input class=`"fi`" id=`"t6`" name=`"tech.date`" $atr placeholder=`"$fDtP`"></div></div>" +
      "<label class=`"fk`" for=`"t3`">$fSg</label><input class=`"fi sg`" id=`"t3`" name=`"tech.sign`" $atr></div>" +
      '<div class="sgb"><p class="l">' + (ConvertTo-HtmlSafe (TX 'conclusion.contactLabel')) +
        '<span class="rl">' + (ConvertTo-HtmlSafe (TX 'attestation.recipientRole')) + '</span></p>' +
      "<label class=`"fk`" for=`"d1`">$fName</label><input class=`"fi`" id=`"d1`" name=`"recip.name`" $atr$contactVal placeholder=`"$contactP`">" +
      "<label class=`"fk`" for=`"d2`">$fRole</label><input class=`"fi`" id=`"d2`" name=`"recip.role`" $atr placeholder=`"$fRoleP`">" +
      "<label class=`"fk`" for=`"d4`">$fDig</label><input class=`"fi mono8`" id=`"d4`" name=`"recip.digest8`" $datr placeholder=`"$fDigP`">" +
      '<div class="pd">' +
        "<div><label class=`"fk`" for=`"d5`">$fPl</label><input class=`"fi`" id=`"d5`" name=`"recip.place`" $atr placeholder=`"$fPlP`"></div>" +
        "<div><label class=`"fk`" for=`"d6`">$fDt</label><input class=`"fi`" id=`"d6`" name=`"recip.date`" $atr placeholder=`"$fDtP`"></div></div>" +
      "<label class=`"fk`" for=`"d3`">$fSg</label><input class=`"fi sg`" id=`"d3`" name=`"recip.sign`" $atr></div></div>"
    $b += New-Block -Html $sig -HeightMm 92.0

    $colo = '<div class="colo">' +
      '<div><b>' + (ConvertTo-HtmlSafe (TX 'attestation.coloFramework')) + '</b>' + (ConvertTo-HtmlSafe (TX 'attestation.frameworkName')) + '<br>' + (ConvertTo-HtmlSafe (TX 'attestation.frameworkEdition')) + '</div>' +
      '<div><b>' + (ConvertTo-HtmlSafe (TX 'attestation.coloTool')) + '</b>' + (ConvertTo-HtmlSafe (TX 'attestation.toolName' @{ version = $script:ProductVersion })) + '<br>' + (ConvertTo-HtmlSafe (TX 'attestation.toolMode')) + '</div>' +
      '<div><b>' + (ConvertTo-HtmlSafe (TX 'attestation.coloDoc')) + '</b>{{REPORT_ID}}<br>' + (ConvertTo-HtmlSafe $DateHuman) + '<br>' + (ConvertTo-HtmlSafe (TX 'attestation.pagesLine' @{ pages = $PageTotal })) + '</div></div>'
    $b += New-Block -Html $colo -HeightMm 24.0
    return ,@($b)
}


# ===========================================================================
# PDF : IDENTITE DU DOCUMENT ET NAVIGATION
# ===========================================================================
# Chrome ecrit un PDF correct mais anonyme : Creator "HeadlessChrome", Producer
# "Skia/PDF", ni auteur, ni objet, ni mots-cles, et aucun signet sur 37 pages.
# Une piece d'audit qui se presente comme produite par un moteur de rendu, et
# qu'on ne peut parcourir qu'en faisant defiler, n'est pas une piece livrable.
#
# Chrome n'expose aucun moyen de renseigner ces champs. Ils sont donc ajoutes
# apres coup, par une MISE A JOUR INCREMENTALE : les octets existants ne sont
# jamais reecrits, on ajoute en fin de fichier une nouvelle version des objets
# concernes, une table xref pour eux seuls, et une bande-annonce qui pointe la
# precedente. C'est l'operation prevue par le format pour cela.
#
# Le procede a ete valide octet a octet sur un tirage reel avant d'etre ecrit
# ici : neuf signets pointant chacun sur la feuille dont le folio imprime
# correspond, et qpdf --check sans erreur. En cas de doute, la fonction ne
# touche a rien : un PDF sans metadonnees vaut infiniment mieux qu'un PDF casse.

$script:Latin1 = [System.Text.Encoding]::GetEncoding('ISO-8859-1')

# Chaine PDF en UTF-16BE avec BOM : sans cela "Conformite" perd ses accents
# dans le panneau Proprietes du lecteur.
function ConvertTo-PdfString {
    param([string]$Text)
    if ($null -eq $Text) { $Text = '' }
    $bytes = [System.Text.Encoding]::BigEndianUnicode.GetBytes($Text)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('(')
    [void]$sb.Append([char]0xFE); [void]$sb.Append([char]0xFF)
    foreach ($b in $bytes) {
        if ($b -eq 0x28 -or $b -eq 0x29 -or $b -eq 0x5C) { [void]$sb.Append('\') }
        [void]$sb.Append([char]$b)
    }
    [void]$sb.Append(')')
    return $sb.ToString()
}

# Derniere definition d'un objet : une mise a jour incrementale peut en contenir
# plusieurs, et c'est la derniere qui fait foi.
function Get-PdfObjectBody {
    param([string]$Doc, [int]$Num)
    $ms = [regex]::Matches($Doc, "(?m)^\s*$Num\s+0\s+obj")
    if ($ms.Count -eq 0) { return $null }
    $m = $ms[$ms.Count - 1]
    $e = $Doc.IndexOf('endobj', $m.Index)
    if ($e -lt 0) { return $null }
    return $Doc.Substring($m.Index, $e - $m.Index)
}

# Numeros des objets Page, dans l'ordre du document.
function Get-PdfPageObjects {
    param([string]$Doc, [int]$PagesRoot)
    $order = New-Object System.Collections.ArrayList
    $stack = New-Object System.Collections.Stack
    $stack.Push(@{ N = $PagesRoot; D = 0 })
    $seen = @{}
    while ($stack.Count -gt 0) {
        $cur = $stack.Pop()
        if ($cur.D -gt 12) { continue }
        if ($seen.ContainsKey($cur.N)) { continue }
        $seen[$cur.N] = $true
        $body = Get-PdfObjectBody -Doc $Doc -Num $cur.N
        if (-not $body) { continue }
        if ($body -match '/Type\s*/Page[^s]') { [void]$order.Add($cur.N); continue }
        $km = [regex]::Match($body, '/Kids\s*\[(.*?)\]', 'Singleline')
        if (-not $km.Success) { continue }
        $kids = @([regex]::Matches($km.Groups[1].Value, '(\d+)\s+0\s+R') | ForEach-Object { [int]$_.Groups[1].Value })
        [array]::Reverse($kids)
        foreach ($k in $kids) { $stack.Push(@{ N = $k; D = $cur.D + 1 }) }
    }
    return ,@($order.ToArray())
}

function Add-PdfMetadataAndOutline {
    param([string]$PdfPath, $Info, $Bookmarks)
    if (-not (Test-Path -LiteralPath $PdfPath)) { return $false }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($PdfPath)
        $doc   = $script:Latin1.GetString($bytes)

        $sx = [regex]::Match($doc, 'startxref\s+(\d+)\s*%%EOF\s*$')
        if (-not $sx.Success) { Write-Warn 'PDF: no final startxref; metadata left untouched.'; return $false }
        $prev = [int]$sx.Groups[1].Value
        if ($doc.Substring($prev, 4) -ne 'xref') {
            Write-Warn 'PDF: cross-reference stream (not a classic table); metadata left untouched.'
            return $false
        }
        $ti = $doc.LastIndexOf('trailer')
        if ($ti -lt 0) { Write-Warn 'PDF: no trailer; metadata left untouched.'; return $false }
        $tail = $doc.Substring($ti)
        $mInfo = [regex]::Match($tail, '/Info\s+(\d+)\s+0\s+R')
        $mRoot = [regex]::Match($tail, '/Root\s+(\d+)\s+0\s+R')
        $mSize = [regex]::Match($tail, '/Size\s+(\d+)')
        if (-not ($mInfo.Success -and $mRoot.Success -and $mSize.Success)) {
            Write-Warn 'PDF: trailer incomplete; metadata left untouched.'; return $false
        }
        $infoNo = [int]$mInfo.Groups[1].Value
        $rootNo = [int]$mRoot.Groups[1].Value
        $size   = [int]$mSize.Groups[1].Value

        $cat = Get-PdfObjectBody -Doc $doc -Num $rootNo
        if (-not $cat) { Write-Warn 'PDF: catalog not found; metadata left untouched.'; return $false }
        $mPages = [regex]::Match($cat, '/Pages\s+(\d+)\s+0\s+R')
        if (-not $mPages.Success) { Write-Warn 'PDF: page tree not found; metadata left untouched.'; return $false }
        $pages = Get-PdfPageObjects -Doc $doc -PagesRoot ([int]$mPages.Groups[1].Value)

        $marks = @($Bookmarks | Where-Object { [int]$_.Page -ge 1 -and [int]$_.Page -le @($pages).Count })
        if (@($marks).Count -ne @($Bookmarks).Count) {
            Write-Warn ('PDF: {0} of {1} bookmarks fall outside the {2} pages found; outline skipped.' -f `
                        (@($Bookmarks).Count - @($marks).Count), @($Bookmarks).Count, @($pages).Count)
            $marks = @()
        }

        $sb = New-Object System.Text.StringBuilder
        $newNums = New-Object System.Collections.ArrayList
        $newBody = @{}

        $infoStr = New-Object System.Text.StringBuilder
        [void]$infoStr.Append('<<')
        foreach ($k in @('Title','Author','Subject','Keywords','Creator','Producer')) {
            if ($Info.ContainsKey($k) -and $Info[$k]) {
                [void]$infoStr.Append('/').Append($k).Append(' ').Append((ConvertTo-PdfString $Info[$k]))
            }
        }
        [void]$infoStr.Append('>>')
        $newBody[$infoNo] = $infoStr.ToString()
        [void]$newNums.Add($infoNo)

        if (@($marks).Count -gt 0) {
            $firstItem = $size
            $outlineNo = $firstItem + @($marks).Count
            for ($i = 0; $i -lt @($marks).Count; $i++) {
                $n = $firstItem + $i
                $s = New-Object System.Text.StringBuilder
                [void]$s.Append('<</Title ').Append((ConvertTo-PdfString $marks[$i].Title))
                [void]$s.Append('/Parent ').Append($outlineNo).Append(' 0 R')
                if ($i -gt 0) { [void]$s.Append('/Prev ').Append($firstItem + $i - 1).Append(' 0 R') }
                if ($i -lt (@($marks).Count - 1)) { [void]$s.Append('/Next ').Append($firstItem + $i + 1).Append(' 0 R') }
                [void]$s.Append('/Dest [').Append($pages[[int]$marks[$i].Page - 1]).Append(' 0 R /XYZ null null null]>>')
                $newBody[$n] = $s.ToString()
                [void]$newNums.Add($n)
            }
            $newBody[$outlineNo] = ('<</Type /Outlines/First {0} 0 R/Last {1} 0 R/Count {2}>>' -f `
                                    $firstItem, ($firstItem + @($marks).Count - 1), @($marks).Count)
            [void]$newNums.Add($outlineNo)

            $inner = [regex]::Match($cat, 'obj\s*(<<.*>>)\s*$', 'Singleline')
            if ($inner.Success) {
                $c = $inner.Groups[1].Value
                $c = $c.Substring(0, $c.Length - 2) + ('/Outlines {0} 0 R/PageMode /UseOutlines>>' -f $outlineNo)
                $newBody[$rootNo] = $c
                [void]$newNums.Add($rootNo)
            } else {
                Write-Warn 'PDF: catalog body not parsed; bookmarks omitted.'
                foreach ($n in @($newNums)) { if ($n -ge $size) { $newBody.Remove($n) } }
                $newNums = New-Object System.Collections.ArrayList
                [void]$newNums.Add($infoNo)
            }
        }

        $out = New-Object System.Text.StringBuilder
        [void]$out.Append($doc)
        if (-not $doc.EndsWith("`n")) { [void]$out.Append("`n") }
        $sorted = @($newNums | Sort-Object)
        $offsets = @{}
        foreach ($n in $sorted) {
            $offsets[$n] = $out.Length
            [void]$out.Append($n).Append(" 0 obj`n").Append($newBody[$n]).Append("`nendobj`n")
        }
        $xrefAt = $out.Length
        [void]$out.Append("xref`n")
        foreach ($n in $sorted) {
            [void]$out.Append($n).Append(" 1`n")
            [void]$out.Append(('{0:D10} 00000 n ' -f $offsets[$n])).Append("`n")
        }
        $maxNo = ($sorted | Measure-Object -Maximum).Maximum
        $newSize = [math]::Max($size, $maxNo + 1)
        [void]$out.Append("trailer`n<</Size ").Append($newSize)
        [void]$out.Append("`n/Root ").Append($rootNo).Append(' 0 R')
        [void]$out.Append("`n/Info ").Append($infoNo).Append(' 0 R')
        [void]$out.Append("`n/Prev ").Append($prev).Append(">>`nstartxref`n").Append($xrefAt).Append("`n%%EOF`n")

        $tmp = $PdfPath + '.tmp'
        [System.IO.File]::WriteAllBytes($tmp, $script:Latin1.GetBytes($out.ToString()))

        # Relire ce qui a ete ecrit plutot que faire confiance a ce qui a ete
        # calcule : un PDF illisible produit en silence serait pire que l'absence
        # de metadonnees.
        $check = $script:Latin1.GetString([System.IO.File]::ReadAllBytes($tmp))
        $cx = [regex]::Match($check, 'startxref\s+(\d+)\s*%%EOF\s*$')
        if (-not $cx.Success -or $check.Substring([int]$cx.Groups[1].Value, 4) -ne 'xref') {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            Write-Warn 'PDF: verification of the rewritten file failed; the original is kept as is.'
            return $false
        }
        Move-Item -LiteralPath $tmp -Destination $PdfPath -Force
        if (@($marks).Count -gt 0) {
            Write-OK ("PDF identity set and {0} bookmarks added" -f @($marks).Count)
        } else {
            Write-OK 'PDF identity set (no bookmarks)'
        }
        return $true
    } catch {
        Write-Warn "PDF metadata step skipped: $($_.Exception.Message)"
        return $false
    }
}

# ===========================================================================
# PDF CONVERSION
# ===========================================================================
# Re-running a diagnostic with the previous PDF still open in a viewer is the
# normal case in the field, not an edge case. Deleting the target then throws
# and the run dies after every expensive step has already succeeded. Losing a
# completed diagnostic to a file lock is not an acceptable outcome, so if the
# target cannot be cleared the report is written alongside it and the technician
# is told which file to open.
function Clear-PdfTarget {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $Path }
    try {
        Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
        return $Path
    } catch {
        $dir  = Split-Path -Parent $Path
        $base = [System.IO.Path]::GetFileNameWithoutExtension($Path)
        $alt  = Join-Path $dir ("{0}-{1}.pdf" -f $base, (Get-Date -Format 'HHmmss'))
        Write-Warn "The existing PDF is open in another program and cannot be replaced."
        Write-Warn "Writing to $(Split-Path -Leaf $alt) instead. Close the open copy to reuse the original name."
        return $alt
    }
}

function ConvertTo-PdfWithEdge {
    param([string]$HtmlPath, [string]$PdfPath)
    $edge = Get-EdgePath
    if (-not $edge) { return $false }
    $uri = ([System.Uri]$HtmlPath).AbsoluteUri
    Write-Step "Edge: $edge"

    $tempRoot   = [System.IO.Path]::GetTempPath()
    $stamp      = [guid]::NewGuid().ToString('N').Substring(0,8)
    $profileDir = Join-Path $tempRoot "fo-edge-profile-$stamp"
    $errLog     = Join-Path $tempRoot "fo-edge-$stamp.log"

    $edgeArgs = @(
        '--headless=new'
        '--disable-gpu'
        '--no-pdf-header-footer'
        # A private profile directory is not optional. When headless Edge shares
        # the default profile with a running Edge it attaches to that instance,
        # returns exit code 0 and writes nothing -- a success code and no file,
        # which is precisely the silent failure this function used to report.
        "--user-data-dir=$profileDir"
        # The conclusion page describes a fingerprint that the template draws
        # from the report hash in script. Printing before script has run yields
        # a document whose own text refers to something not on the page.
        '--virtual-time-budget=15000'
        "--print-to-pdf=$PdfPath"
        $uri
    )

    $exitCode = -1
    try {
        $proc = Start-Process -FilePath $edge -ArgumentList $edgeArgs -NoNewWindow -Wait -PassThru `
                              -RedirectStandardError $errLog -ErrorAction Stop
        $exitCode = $proc.ExitCode
    } catch {
        Write-Warn "Edge could not be started: $($_.Exception.Message)"
        Remove-Item -LiteralPath $profileDir -Recurse -Force -ErrorAction SilentlyContinue
        return $false
    }

    # Poll instead of sleeping a fixed 500 ms. Edge returns before the write has
    # landed, and a 15-page render on a cold profile takes longer than that, so
    # the old fixed wait declared failure for PDFs that arrived a moment later.
    $deadline = (Get-Date).AddSeconds(30)
    while (((Get-Date) -lt $deadline) -and -not (Test-Path -LiteralPath $PdfPath)) {
        Start-Sleep -Milliseconds 250
    }
    $ok = Test-Path -LiteralPath $PdfPath

    if (-not $ok) {
        Write-Warn "Edge exited with code $exitCode and wrote no PDF."
        # Report what Edge said. The previous version piped stderr to Out-Null,
        # so every failure looked identical and none of them were diagnosable.
        if (Test-Path -LiteralPath $errLog) {
            $text = Get-Content -LiteralPath $errLog -Raw -ErrorAction SilentlyContinue
            if ($text) {
                $lines = @($text -split "`r?`n" | Where-Object { $_ -match '\S' })
                if ($lines.Count -gt 0) {
                    $tail = ($lines | Select-Object -Last 4) -join ' | '
                    Write-Warn "Edge reported: $tail"
                }
            }
        }
    }

    Remove-Item -LiteralPath $profileDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $errLog -Force -ErrorAction SilentlyContinue
    return $ok
}

function ConvertTo-PdfWithWkhtmltopdf {
    param([string]$HtmlPath, [string]$PdfPath)
    $wk = Get-WkhtmltopdfPath
    if (-not $wk) { return $false }
    Write-Step "wkhtmltopdf: $wk"
    & $wk --enable-local-file-access `
          --page-size A4 `
          --margin-top 14mm --margin-bottom 14mm --margin-left 14mm --margin-right 14mm `
          --print-media-type --encoding UTF-8 `
          $HtmlPath $PdfPath 2>&1 | Out-Null
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0 -and $exitCode -ne 1) {
        Write-Warn "wkhtmltopdf exited with code $exitCode"
        if (-not (Test-Path $PdfPath)) { return $false }
    }
    return (Test-Path $PdfPath)
}

# ===========================================================================
# MAIN PIPELINE
# ===========================================================================
Write-Host ''
Write-Host '  +----------------------------------------------------------------+' -ForegroundColor White
Write-Host '  |         FIELDOPS PRO - ANSSI Diagnostic Report Builder         |' -ForegroundColor White
Write-Host '  +----------------------------------------------------------------+' -ForegroundColor White
Write-Host ''
Write-Step "Data    : $DataFile"
Write-Step "Template: $TemplateFile"
Write-Step "Output  : $OutputDir"
Write-Host ''

Write-Step 'Loading JSON data...'
try {
    $data = Get-Content -LiteralPath $DataFile -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    throw "Cannot parse data file '$DataFile': $($_.Exception.Message)"
}
Write-OK "Loaded report '$($data.Report.Id)' for host '$($data.Machine.Hostname)'"

Write-Step 'Loading HTML template...'
$template = Get-Content -LiteralPath $TemplateFile -Raw -Encoding UTF8
Write-OK "Template loaded ($($template.Length) chars)"

. (Join-Path $PSScriptRoot 'Resolve-LocaleTokens.ps1')
$localeBundleDir = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'CONFIG\lang'

# Le bundle entier, pas seulement les mesures : les generateurs emettent du
# texte resolu parce qu'une hauteur se mesure sur une prose, pas sur un jeton.
$script:Bundle = $null
$measures = $null
try {
    $bundleFile = Join-Path $localeBundleDir "$Language.json"
    $script:Bundle = (Get-Content -LiteralPath $bundleFile -Raw -Encoding UTF8 | ConvertFrom-Json).report.anssi
    $measures = $script:Bundle.measures
    Write-OK "Locale bundle loaded ($Language)"
} catch {
    throw "Locale bundle could not be loaded: $($_.Exception.Message)"
}
if (-not $measures) { Write-Warn 'No measures in the locale bundle: findings will carry no action.' }

# LA VERSION QUI A PRODUIT LES VERDICTS
# Un rapport de conformite sans numero de build n'est pas verifiable dans le
# temps : l'evaluation d'une regle change d'une version a l'autre, donc un
# "conforme" ne veut rien dire tant qu'on ignore sous quelles regles il a ete
# prononce. Le numero vient de CONFIG\version.json -- source unique -- via le
# mecanisme deja prevu pour cela, jamais d'un litteral tape dans un modele.
$productVersion = ''
try {
    # -DisableNameChecking: Utils exports Render-RichTextValue, and 'Render' is
    # not an approved verb. Without this, PowerShell prints a wall of warning
    # text mid-run in a tool a technician is watching, where it reads as an
    # error. Every other call site in the tree already passes this.
    Import-Module (Join-Path $ProjectRoot 'SCRIPTS\Core\Utils.psm1') -Force -DisableNameChecking -ErrorAction Stop
    $v = Get-FieldOpsVersion -From $PSScriptRoot
    if ($v) { $productVersion = 'v' + $v }
} catch {
    Write-Warn "Product version unavailable: $($_.Exception.Message)"
}
$script:ProductVersion = $productVersion

$brand = Get-BrandProfile -ConfigDir (Join-Path $ProjectRoot 'CONFIG')
$script:Mark          = Get-BrandMark -Brand $brand -Size 11
$script:BrandNameHtml = Get-BrandNameHtml -Brand $brand

# Marquage de diffusion : celui demande a la collecte, sinon celui du bundle.
$script:Classification = ''
if (@($data.Report.PSObject.Properties.Name) -contains 'Classification') {
    $script:Classification = "$($data.Report.Classification)"
}
if (-not $script:Classification) { $script:Classification = TX 'classification.default' }

# Commanditaire : affiche s'il est connu, omis sinon. Jamais un texte de
# remplissage -- la meme regle que pour le destinataire de la signature.
$clientRow = ''
$clientName = ''
if (@($data.Report.PSObject.Properties.Name) -contains 'Client') { $clientName = "$($data.Report.Client)" }
if ($clientName) {
    $clientRow = '<dt>' + (ConvertTo-HtmlSafe (TX 'cover.clientLabel')) + '</dt><dd>' + (ConvertTo-HtmlSafe $clientName) + '</dd>'
} else {
    Write-Warn 'No commissioning organisation was given (-ClientOrganisation): the cover will not name one.'
}
if ($productVersion) { Write-OK "Engine version: $productVersion" }
else { Write-Warn 'The report will not name the build that produced it.' }


$script:WrapOpen['toc']  = '<div class="toc">'
$script:WrapClose['toc'] = '</div>'

# --- Provenance et empreinte des constats ---------------------------------
$sources = @()
if (@($data.Report.PSObject.Properties.Name) -contains 'Sources') { $sources = @($data.Report.Sources) }
$verdictDigest = ''
if (@($data.Report.PSObject.Properties.Name) -contains 'VerdictDigest') { $verdictDigest = "$($data.Report.VerdictDigest)" }
if (-not $verdictDigest) {
    Write-Warn 'report-data.json carries no VerdictDigest: rebuild it with Build-ANSSIData.ps1 to get a language-independent findings fingerprint.'
}

# --- Chiffres, calcules une seule fois ------------------------------------
$allItems = Get-FindingItems -ModuleDetails $data.ModuleDetails -Measures $measures -Language $Language
$ranked   = Get-RankedFindings -Items $allItems
$evaluable  = [int]$data.Summary.CountCV + [int]$data.Summary.CountPV
$blindCount = @($ranked | Where-Object { $_.FindingClass -eq 'blind' }).Count
$effortMins = 0
$effortKnown = $true
foreach ($f in $ranked) {
    if (-not $f.Measure) { continue }
    $m = ConvertTo-EffortMinutes ("$($f.Measure.eff)")
    if ($m -lt 0) { $effortKnown = $false } else { $effortMins += $m }
}
$effortTotal = '-'
if ($effortKnown) { $effortTotal = Format-EffortTotal -Minutes $effortMins -Language $Language }

# --- Blocs, puis pagination mesuree ---------------------------------------
Write-Step 'Measuring sections...'
$summaryBlocks = Get-SummaryBlocks   -Summary $data.Summary -ModuleDetails $data.ModuleDetails -Ranked $ranked `
                                     -Evaluable $evaluable -BlindCount $blindCount -EffortTotal $effortTotal `
                                     -Sources $sources -Language $Language
$planBlocks    = Get-ActionPlanBlocks -Ranked $ranked -Language $Language
$specBlocks    = Get-SpectrumBlocks  -ModuleDetails $data.ModuleDetails -Summary $data.Summary -Language $Language

$findBlocks = @()
$findBlocks += New-IntroBlock -Eyebrow (TX 'rh.findings') -Title (TX 'findings.title') `
                              -Lead (TX 'findings.lead' @{ findingCount = @($ranked).Count; evaluable = $evaluable })
$i = 1
foreach ($f in $ranked) { $findBlocks += New-FindingBlock -F $f -Index $i -Language $Language; $i++ }

$modBlocks  = Get-ModuleBlocks     -Items $allItems -Language $Language
$oosBlocks  = Get-OutOfScopeBlocks -ModuleDetails $data.ModuleDetails -HpCount ([int]$data.Summary.CountHP) -Language $Language
$provBlocks = Get-ProvenanceBlocks -Sources $sources -VerdictDigest $verdictDigest -Language $Language

$summaryPages = Split-IntoPages -Items $summaryBlocks -Budget $script:UsablePageMm
$planPages    = Split-IntoPages -Items $planBlocks    -Budget $script:UsablePageMm
# Le spectre est la seule section dont la taille ne depend pas du poste :
# 10 modules, 42 carres, toujours. Il recoit la hauteur utile pleine pour que
# "d'un seul regard" reste litteralement vrai -- un regard sur deux feuilles
# n'en est pas un.
$specPages    = Split-IntoPages -Items $specBlocks    -Budget 244.0
$findPages    = Split-IntoPages -Items $findBlocks    -Budget $script:UsablePageMm
# 9 mm reserves pour la ligne de reprise ajoutee juste apres, de sorte que
# l'inserer ne puisse pas faire deborder la feuille.
$modPages     = Split-IntoPages -Items $modBlocks     -Budget ($script:UsablePageMm - 9.0)
$modPages     = Add-ModuleContinuations -Pages $modPages -Items $allItems -Language $Language
$oosPages     = Split-IntoPages -Items $oosBlocks     -Budget $script:UsablePageMm
$provPages    = Split-IntoPages -Items $provBlocks    -Budget $script:UsablePageMm

# Le sommaire tient sur une feuille par construction (une ligne par section) ;
# il est neanmoins empaquete comme les autres, pour que personne n'ait a le
# supposer.
# Une ligne par section : le sommaire tient sur une feuille. Le controle plus
# bas verifie cette affirmation au lieu de la supposer.
$tocCount = 1

$nSummary = @($summaryPages).Count
$nPlan    = @($planPages).Count
$nSpec    = @($specPages).Count
$nFind    = @($findPages).Count
$nMod     = @($modPages).Count
$nOos     = @($oosPages).Count
$nProv    = @($provPages).Count

$tocPage        = 2
$summaryPage    = $tocPage + $tocCount
$planPage       = $summaryPage + $nSummary
$spectrumPage   = $planPage + $nPlan
$findingsPage   = $spectrumPage + $nSpec
$modulePage     = $findingsPage + $nFind
$outOfScopePage = $modulePage + $nMod
$provenancePage = $outOfScopePage + $nOos
$conclusionBlocks = Get-ConclusionBlocks -Summary $data.Summary -BlindCount $blindCount `
                                         -EffortTotal $effortTotal -Language $Language
$conclusionPages  = Split-IntoPages -Items $conclusionBlocks -Budget $script:UsablePageMm
$nConc = @($conclusionPages).Count
$conclusionPage = $provenancePage + $nProv
# L'attestation cite le nombre total de pages, qui depend de sa propre etendue.
# Elle est donc mesuree une premiere fois pour connaitre ce nombre, puis
# reconstruite avec lui. Une seule iteration suffit : seuls des chiffres
# changent, jamais la structure -- et le controle plus bas le verifie.
$attProbe  = Get-AttestationBlocks -VerdictDigest $verdictDigest -PageTotal 0 -ProvenancePage $provenancePage `
                                   -Hostname "$($data.Machine.Hostname)" -DateHuman "$($data.Report.GeneratedAtHuman)" `
                                   -Technician "$($data.Report.Technician)" -Contact "$($data.Report.CustomerContact)" -Language $Language
$nAtt      = @(Split-IntoPages -Items $attProbe -Budget 244.0).Count
$attestationPage = $conclusionPage + $nConc
$pageTotal       = $attestationPage + $nAtt - 1
$attBlocks = Get-AttestationBlocks -VerdictDigest $verdictDigest -PageTotal $pageTotal -ProvenancePage $provenancePage `
                                   -Hostname "$($data.Machine.Hostname)" -DateHuman "$($data.Report.GeneratedAtHuman)" `
                                   -Technician "$($data.Report.Technician)" -Contact "$($data.Report.CustomerContact)" -Language $Language
# Comme le spectre, l'attestation a une taille qui ne depend pas du poste :
# prose fixe, nombre de champs fixe. Elle recoit la hauteur utile pleine pour
# rester une feuille unique, et le controle ci-dessous avertit si elle cesse
# de l'etre.
$attPages  = Split-IntoPages -Items $attBlocks -Budget 244.0
if (@($attPages).Count -ne $nAtt) {
    Write-Warn ("Attestation span changed after numbering ({0} -> {1}); folios would drift." -f $nAtt, @($attPages).Count)
}
# Une page de signatures repartie sur deux feuilles n'atteste plus rien de sur :
# il suffit d'en retirer une. La declaration d'etendue le dit, ce controle le
# verifie.
if (@($attPages).Count -gt 1) {
    Write-Warn ("The signature sheet spans {0} pages. A signature page split across sheets weakens the extent statement -- shorten the attestation copy." -f @($attPages).Count)
}

Write-Step "Pages   : $pageTotal"
Write-OK   ("Mesure : sommaire {0} | synthese {1} | plan {2} | spectre {3} | constats {4} | modules {5} | hors perimetre {6} | provenance {7} | conclusion 1 | attestation 1" -f `
            $tocCount, $nSummary, $nPlan, $nSpec, $nFind, $nMod, $nOos, $nProv)

$tocSections = @(
    [PSCustomObject]@{ Key = 'summary';      Anchor = 'summary';     Page = $summaryPage }
    [PSCustomObject]@{ Key = 'actionPlan';   Anchor = 'plan';        Page = $planPage }
    [PSCustomObject]@{ Key = 'spectrum';     Anchor = 'spectrum';    Page = $spectrumPage }
    [PSCustomObject]@{ Key = 'findings';     Anchor = 'findings';    Page = $findingsPage }
    [PSCustomObject]@{ Key = 'moduleDetail'; Anchor = 'modules';     Page = $modulePage }
    [PSCustomObject]@{ Key = 'outOfScope';   Anchor = 'outofscope';  Page = $outOfScopePage }
    [PSCustomObject]@{ Key = 'provenance';   Anchor = 'provenance';  Page = $provenancePage }
    [PSCustomObject]@{ Key = 'conclusion';   Anchor = 'conclusion';  Page = $conclusionPage }
    [PSCustomObject]@{ Key = 'attestation';  Anchor = 'attestation'; Page = $attestationPage }
)
$tocBlocks = Get-TocBlocks -Sections $tocSections -PageTotal $pageTotal `
                           -Hostname "$($data.Machine.Hostname)" -ReportId "$($data.Report.Id)" `
                           -DateHuman "$($data.Report.GeneratedAtHuman)"
$tocPages = Split-IntoPages -Items $tocBlocks -Budget $script:UsablePageMm
if (@($tocPages).Count -ne $tocCount) {
    Write-Warn ("Contents page span changed after numbering ({0} -> {1}); folios would drift. Reduce the section list." -f $tocCount, @($tocPages).Count)
}

Write-Step 'Emitting sections...'
$tocBlock        = Out-Section -RhKey 'toc'        -Anchor 'toc'        -Pages $tocPages     -PageStart $tocPage        -Total $pageTotal
$summaryBlock    = Out-Section -RhKey 'summary'    -Anchor 'summary'    -Pages $summaryPages -PageStart $summaryPage    -Total $pageTotal
$planBlock       = Out-Section -RhKey 'plan'       -Anchor 'plan'       -Pages $planPages    -PageStart $planPage       -Total $pageTotal
$spectrumBlock   = Out-Section -RhKey 'spectrum'   -Anchor 'spectrum'   -Pages $specPages    -PageStart $spectrumPage   -Total $pageTotal
$findingsBlock   = Out-Section -RhKey 'findings'   -Anchor 'findings'   -Pages $findPages    -PageStart $findingsPage   -Total $pageTotal
$moduleBlock     = Out-Section -RhKey 'module'     -Anchor 'modules'    -Pages $modPages     -PageStart $modulePage     -Total $pageTotal -UseTags $true
$outOfScopeBlock = Out-Section -RhKey 'outOfScope' -Anchor 'outofscope' -Pages $oosPages     -PageStart $outOfScopePage -Total $pageTotal
$provenanceBlock = Out-Section -RhKey 'provenance' -Anchor 'provenance' -Pages $provPages    -PageStart $provenancePage -Total $pageTotal
$conclusionBlock = Out-Section -RhKey 'conclusion' -Anchor 'conclusion' -Pages $conclusionPages -PageStart $conclusionPage  -Total $pageTotal
$attestationBlock= Out-Section -RhKey 'attestation' -Anchor 'attestation' -Pages $attPages     -PageStart $attestationPage -Total $pageTotal

$fontDir   = Join-Path $ProjectRoot 'ASSETS\fonts'
$fontFaces = Get-FontFaceCss -FontDir $fontDir

# Les signets sont la meme liste que le sommaire. Deux listes finiraient par se
# contredire, et c'est le sommaire qui a raison puisque les folios en decoulent.
$pdfBookmarks = @($tocSections | ForEach-Object {
    [PSCustomObject]@{ Title = (TX ('toc.sections.' + $_.Key)); Page = [int]$_.Page }
})
$pdfInfo = @{
    Title    = "$($data.Report.Id) - " + (TX 'brand.docLine')
    Author   = "$($data.Report.Technician)"
    Subject  = TX 'cover.subtitle'
    Keywords = ((@('ANSSI', (TX 'brand.docLine'), "$($data.Machine.Hostname)", $script:Classification) |
                 Where-Object { $_ }) -join ', ')
    Creator  = ($brand.ProductName + ' ' + $script:ProductVersion).Trim()
    Producer = (($brand.ProductName + ' ' + $script:ProductVersion).Trim() + ' - ' + (TX 'attestation.toolMode'))
}

$coverFingerprint = New-FingerprintSvg -Hash $verdictDigest -Cell 13


Write-Step 'Performing token replacement...'
$html = $template

# === Phase 6.1-R4b: resolve locale tokens IN MEMORY, before hashing =====
# The bundle text must be present in $html before the SHA-256 is computed,
# or the embedded signature covers content that never reaches disk. This
# ordering also lets bundle placeholders such as {cvCount} flow through the
# normal replacement pass below, so no separate substitution pass is needed.
try {
    . (Join-Path $PSScriptRoot 'Resolve-LocaleTokens.ps1')
    $localeBundleDir = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'CONFIG\lang'
    $html = Resolve-LocaleTokensInString -Content $html -BundleDir $localeBundleDir -Lang $Language
    Write-OK "Locale tokens resolved ($Language)"
} catch {
    Write-Warn "Locale token resolution failed: $($_.Exception.Message)"
}
$hashPlaceholder = '0' * 64
$replacements = @{
    '{{LANG}}'              = $Language
    '{{FONT_FACES}}'        = $fontFaces
    '{{CLIENT_ROW}}'        = $clientRow
    '{{BRAND_NAME}}'        = $script:BrandNameHtml
    '{{BRAND_MARK_LARGE}}'  = (Get-BrandMark -Brand $brand -Size 30)
    '{{BRAND_SEAL}}'        = $brand.SealColor
    '{product}'             = (ConvertTo-HtmlSafe $brand.ProductName)
    '{{CLASSIFICATION}}'    = (ConvertTo-HtmlSafe $script:Classification)
    '{{REPORT_ID}}'         = (ConvertTo-HtmlSafe $data.Report.Id)
    '{{REPORT_DATE_HUMAN}}' = (ConvertTo-HtmlSafe $data.Report.GeneratedAtHuman)
    '{{TECHNICIAN}}'        = (ConvertTo-HtmlSafe $data.Report.Technician)
    '{{CUSTOMER_CONTACT}}'  = (ConvertTo-HtmlSafe $data.Report.CustomerContact)
    '{{HOSTNAME}}'          = (ConvertTo-HtmlSafe $data.Machine.Hostname)
    '{{MAKE_MODEL}}'        = (ConvertTo-HtmlSafe $data.Machine.MakeModel)
    '{{SERIAL}}'            = (ConvertTo-HtmlSafe $data.Machine.Serial)
    '{{OS}}'                = (ConvertTo-HtmlSafe $data.Machine.Os)
    '{{DIRECTORY}}'         = (ConvertTo-HtmlSafe $data.Machine.Directory)
    '{{COUNT_CV}}'          = [string]$data.Summary.CountCV
    '{{COUNT_PV}}'          = [string]$data.Summary.CountPV
    '{{COUNT_HP}}'          = [string]$data.Summary.CountHP
    '{{PAGE_TOTAL}}'        = [string]$pageTotal
    '{{VERDICT_DIGEST}}'    = (ConvertTo-HtmlSafe $verdictDigest)
    '{{FINGERPRINT}}'       = $coverFingerprint
    '{{TOC_PAGE}}'          = $tocBlock
    '{{SUMMARY_PAGE}}'      = $summaryBlock
    '{{ACTION_PLAN_PAGE}}'  = $planBlock
    '{{SPECTRUM_PAGE}}'     = $spectrumBlock
    '{{TOP_FINDINGS}}'      = $findingsBlock
    '{{MODULE_DETAILS}}'    = $moduleBlock
    '{{OUT_OF_SCOPE_PAGE}}' = $outOfScopeBlock
    '{{PROVENANCE_PAGE}}'   = $provenanceBlock
    '{{PROV_PAGE}}'         = [string]$provenancePage
    '{{CONCLUSION_SECTION}}'= $conclusionBlock
    '{{ATTESTATION_PAGE}}'  = $attestationBlock
    '{{REPORT_HASH}}'       = $hashPlaceholder
    # Placeholders a accolade simple apportes par le texte du bundle.
    '{cvCount}'             = ('<strong>' + [string]$data.Summary.CountCV + '</strong>')
    '{pvCount}'             = ('<strong>' + [string]$data.Summary.CountPV + '</strong>')
    '{hpCount}'             = ('<strong>' + [string]$data.Summary.CountHP + '</strong>')
    '{blindCount}'          = ('<strong>' + [string]$blindCount + '</strong>')
    '{evaluable}'           = ('<strong>' + [string]$evaluable + '</strong>')
    '{effortTotal}'         = (ConvertTo-HtmlSafe $effortTotal)
    '{findingCount}'        = [string](@($ranked).Count)
    '{reportId}'            = (ConvertTo-HtmlSafe $data.Report.Id)
    '{dateHuman}'           = (ConvertTo-HtmlSafe $data.Report.GeneratedAtHuman)
    '{pages}'               = [string]$pageTotal
    '{page}'                = [string]$provenancePage
    '{hostname}'            = (ConvertTo-HtmlSafe $data.Machine.Hostname)
}
foreach ($key in $replacements.Keys) { $html = $html.Replace($key, $replacements[$key]) }
# second pass: blocks may contain nested tokens (e.g. {{REPORT_ID}} in module footers)
foreach ($key in $replacements.Keys) {
    if ($key -in @('{{TOC_PAGE}}','{{SUMMARY_PAGE}}','{{ACTION_PLAN_PAGE}}','{{SPECTRUM_PAGE}}','{{TOP_FINDINGS}}','{{MODULE_DETAILS}}','{{OUT_OF_SCOPE_PAGE}}','{{PROVENANCE_PAGE}}','{{CONCLUSION_SECTION}}','{{ATTESTATION_PAGE}}','{{FINGERPRINT}}','{{FONT_FACES}}')) { continue }
    $html = $html.Replace($key, $replacements[$key])
}

# real SHA-256 over the fully-rendered content
$sha   = [System.Security.Cryptography.SHA256]::Create()
# Hash the exact byte sequence that will be written: UTF-8 WITH BOM, matching
# the write below. Hashing BOM-less bytes while writing BOM-prefixed bytes
# would leave the signature unverifiable against the delivered file.
$utf8BomEnc = New-Object System.Text.UTF8Encoding($true)
$bytes = $utf8BomEnc.GetPreamble() + [System.Text.Encoding]::UTF8.GetBytes($html)
$hash  = ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-','').ToLower()
$html  = $html.Replace($hashPlaceholder, $hash)
Write-OK "Token replacement complete - hash $($hash.Substring(0,16))..."

$reportId    = $data.Report.Id
$htmlOutPath = Join-Path $OutputDir "$reportId.html"
$pdfOutPath  = Join-Path $OutputDir "$reportId.pdf"

Write-Step "Writing HTML: $htmlOutPath"
# Single write, explicit UTF-8 with BOM -- the exact bytes hashed above.
# Nothing may modify this file afterwards or the signature is invalidated.
# [System.IO.File] static methods ignore the PowerShell location and resolve
# relative paths against the process working directory, so -OutputDir '.\REPORTS'
# would land in the wrong place. Convert to a full filesystem path first.
$htmlOutFull = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($htmlOutPath)
[System.IO.File]::WriteAllText($htmlOutFull, $html, $utf8BomEnc)
Write-OK "HTML written ($((Get-Item $htmlOutPath).Length) bytes)"

    # Locale token resolution moved into the in-memory pipeline above
    # (Phase 6.1-R4b) so the integrity hash covers the delivered content.

if ($NoPdf) {
    Write-Host ''
    Write-OK 'HTML-only mode. Skipping PDF conversion.'
    Write-Host "  Output: $htmlOutPath" -ForegroundColor White
    if (-not $NoOpen) { Write-Step 'Opening HTML...'; Start-Process -FilePath $htmlOutPath }
    return
}

Write-Host ''
Write-Step "Converting HTML to PDF (engine: $PdfEngine)..."
$pdfSuccess = $false
$engineUsed = ''
if ($PdfEngine -eq 'Edge' -or $PdfEngine -eq 'Auto') {
    $pdfOutPath = Clear-PdfTarget -Path $pdfOutPath
    $pdfSuccess = ConvertTo-PdfWithEdge -HtmlPath $htmlOutPath -PdfPath $pdfOutPath
    if ($pdfSuccess) { $engineUsed = 'Edge headless' }
}
if (-not $pdfSuccess -and ($PdfEngine -eq 'Wkhtmltopdf' -or $PdfEngine -eq 'Auto')) {
    Write-Warn 'Edge failed or unavailable, trying wkhtmltopdf...'
    $pdfOutPath = Clear-PdfTarget -Path $pdfOutPath
    $pdfSuccess = ConvertTo-PdfWithWkhtmltopdf -HtmlPath $htmlOutPath -PdfPath $pdfOutPath
    if ($pdfSuccess) { $engineUsed = 'wkhtmltopdf' }
}

if (-not $pdfSuccess) {
    Write-Warn 'PDF generation failed with all available engines.'
    Write-Host "  The rendered HTML is still available at: $htmlOutPath" -ForegroundColor White
    if (-not $NoOpen) { Write-Step 'Opening HTML instead...'; Start-Process -FilePath $htmlOutPath }
    return
}

# Le PDF sort de Chrome anonyme et sans signets : on lui donne son identite et
# sa navigation avant d'annoncer qu'il est pret.
[void](Add-PdfMetadataAndOutline -PdfPath $pdfOutPath -Info $pdfInfo -Bookmarks $pdfBookmarks)

$pdfSize = [math]::Round((Get-Item $pdfOutPath).Length / 1KB, 1)
Write-OK "PDF generated via $engineUsed ($pdfSize KB)"
Write-Host ''
Write-Host '  +----------------------------------------------------------------+' -ForegroundColor Green
Write-Host '  |  PDF READY                                                     |' -ForegroundColor Green
Write-Host '  +----------------------------------------------------------------+' -ForegroundColor Green
Write-Host "     HTML : $htmlOutPath" -ForegroundColor White
Write-Host "     PDF  : $pdfOutPath" -ForegroundColor White
Write-Host "     Hash : $hash" -ForegroundColor DarkGray
Write-Host ''
Write-Host "  Start-Process `"$pdfOutPath`"" -ForegroundColor Yellow
Write-Host ''

if (-not $NoOpen) {
    Write-Step 'Opening PDF...'
    Start-Process -FilePath $pdfOutPath
}
