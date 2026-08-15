# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Ousman Dorley. See LICENSE at the repository root.
<#
.SYNOPSIS
    FieldOps Pro - ANSSI Hygiene Diagnostic Report Builder v0.4
.DESCRIPTION
    Reads report-data.json and the premium HTML template, generates the
    compliance spectrum, module bars, module detail pages and findings,
    writes a rendered HTML file, then converts to PDF via headless Edge
    (primary) with wkhtmltopdf fallback.

    Opens the resulting PDF by default. -NoOpen for batch runs.

    v0.4 changes:
      - New-SpectrumBlock: builds the 42-cell compliance spectrum (one row
        per ANSSI module) for the premium template's cover page.
      - Block generators rewritten for the premium template structure
        (module rows with CV/PV/HP counts, rule ribbons, module overview).
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
# BLOCK GENERATORS
# ===========================================================================

# The signature element: a 42-cell grid, one row per ANSSI module.
function New-SpectrumBlock {
    param($ModuleDetails, $Summary)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<div class="spectrum-wrap">')
    foreach ($m in $ModuleDetails) {
        $num   = ConvertTo-HtmlSafe $m.Number
        $title = ConvertTo-HtmlSafe $m.Title
        $cells = New-Object System.Text.StringBuilder
        foreach ($r in @($m.Rules)) {
            $st  = Get-StatusClass $r.Status
            $rnum = ConvertTo-HtmlSafe ($r.Id -replace '^R','')
            [void]$cells.Append("<span class=`"cell $st`">$rnum</span>")
        }
        [void]$sb.AppendLine("  <div class=`"spectrum-row`"><span class=`"spectrum-label`">$num</span><span class=`"spectrum-cells`">$($cells.ToString())</span><span class=`"spectrum-name`">$title</span></div>")
    }
    $cv = [int]$Summary.CountCV
    $pv = [int]$Summary.CountPV
    $hp = [int]$Summary.CountHP
    [void]$sb.AppendLine('  <div class="spectrum-legend">')
    [void]$sb.AppendLine("    <span class=`"key`"><span class=`"swatch cv`"></span><span class=`"count`">$cv</span>&nbsp;verifiees</span>")
    [void]$sb.AppendLine("    <span class=`"key`"><span class=`"swatch pv`"></span><span class=`"count`">$pv</span>&nbsp;partiellement verifiees</span>")
    [void]$sb.AppendLine("    <span class=`"key`"><span class=`"swatch hp`"></span><span class=`"count`">$hp</span>&nbsp;hors perimetre technique</span>")
    [void]$sb.AppendLine('  </div>')
    [void]$sb.AppendLine('</div>')
    return $sb.ToString()
}

function New-TopFindingsBlock {
    param($Findings)
    if (-not $Findings -or @($Findings).Count -eq 0) {
        return '<p style="font-size: 9pt; color: #5C5C5C;">Aucun point d''attention prioritaire identifie sur ce poste.</p>'
    }
    $sb = New-Object System.Text.StringBuilder
    $i = 1
    foreach ($f in $Findings) {
        $title = ConvertTo-HtmlSafe $f.Title
        $note  = ConvertTo-HtmlSafe $f.RuleNote
        $rid   = ConvertTo-HtmlSafe $f.RuleId
        $st    = Get-StatusClass $f.Status
        [void]$sb.AppendLine(@"
  <div class="finding">
    <span class="finding-num">$i</span>
    <div class="finding-body">
      <div class="finding-title">$title</div>
      <div class="finding-note">$note</div>
    </div>
    <span class="finding-pill"><span class="pill $st">$rid</span></span>
  </div>
"@)
        $i++
    }
    return $sb.ToString()
}

function New-ModuleBarsBlock {
    param($Modules)
    $sb = New-Object System.Text.StringBuilder
    foreach ($m in $Modules) {
        $total = [int]$m.RuleCount
        if ($total -le 0) { $total = 1 }
        $cv = [int]$m.Counts.Cv
        $pv = [int]$m.Counts.Pv
        $hp = [int]$m.Counts.Hp
        $cvPct = [math]::Round(($cv / $total) * 100, 2)
        $pvPct = [math]::Round(($pv / $total) * 100, 2)
        $hpPct = [math]::Round(($hp / $total) * 100, 2)
        $num   = ConvertTo-HtmlSafe $m.Number
        $title = ConvertTo-HtmlSafe $m.Title
        [void]$sb.AppendLine(@"
  <div class="module-row">
    <span class="module-roman">$num</span>
    <div class="module-info">
      <div class="module-title">$title</div>
      <div class="module-bar">
        <div class="module-seg cv" style="width:$cvPct%"></div>
        <div class="module-seg pv" style="width:$pvPct%"></div>
        <div class="module-seg hp" style="width:$hpPct%"></div>
      </div>
    </div>
    <div class="module-counts"><span class="c-cv">$cv</span> CV &middot; <span class="c-pv">$pv</span> PV &middot; <span class="c-hp">$hp</span> HP</div>
  </div>
"@)
    }
    return $sb.ToString()
}

function New-ModuleDetailsBlock {
    param($ModuleDetails, $PageStart, $PageTotal)
    $sb = New-Object System.Text.StringBuilder
    $pageNum = $PageStart
    foreach ($m in $ModuleDetails) {
        $num   = ConvertTo-HtmlSafe $m.Number
        $title = ConvertTo-HtmlSafe $m.Title
        $rules = @($m.Rules)
        $rc = $rules.Count
        if ($rc -le 0) { $rc = 1 }
        $cv = @($rules | Where-Object { $_.Status -eq 'cv' }).Count
        $pv = @($rules | Where-Object { $_.Status -eq 'pv' }).Count
        $hp = @($rules | Where-Object { $_.Status -eq 'hp' }).Count
        $cvPct = [math]::Round(($cv / $rc) * 100, 2)
        $pvPct = [math]::Round(($pv / $rc) * 100, 2)
        $hpPct = [math]::Round(($hp / $rc) * 100, 2)

        [void]$sb.AppendLine('<div class="page">')
        [void]$sb.AppendLine('  <div class="page-head">')
        [void]$sb.AppendLine('    <span class="brand-mark">FieldOps Pro &middot; Service Diagnostic</span>')
        [void]$sb.AppendLine("    <span class=`"page-num`">Page $pageNum / $PageTotal</span>")
        [void]$sb.AppendLine('  </div>')
        [void]$sb.AppendLine("  <div class=`"title-h2-meta`">Module $num</div>")
        [void]$sb.AppendLine("  <h2 class=`"title-h2 serif`">$title</h2>")
        [void]$sb.AppendLine('  <div class="module-overview">')
        [void]$sb.AppendLine('    <div class="module-overview-numbers">')
        [void]$sb.AppendLine("      <div class=`"mon-cell`"><span class=`"mon-num cv`">$cv</span><span class=`"mon-lbl`">Verif.</span></div>")
        [void]$sb.AppendLine("      <div class=`"mon-cell`"><span class=`"mon-num pv`">$pv</span><span class=`"mon-lbl`">Partiel</span></div>")
        [void]$sb.AppendLine("      <div class=`"mon-cell`"><span class=`"mon-num hp`">$hp</span><span class=`"mon-lbl`">H. perim.</span></div>")
        [void]$sb.AppendLine('    </div>')
        [void]$sb.AppendLine('    <div class="module-overview-bar">')
        [void]$sb.AppendLine("      <div class=`"module-seg cv`" style=`"width:$cvPct%`"></div>")
        [void]$sb.AppendLine("      <div class=`"module-seg pv`" style=`"width:$pvPct%`"></div>")
        [void]$sb.AppendLine("      <div class=`"module-seg hp`" style=`"width:$hpPct%`"></div>")
        [void]$sb.AppendLine('    </div>')
        [void]$sb.AppendLine('  </div>')

        foreach ($r in $rules) {
            $rid    = ConvertTo-HtmlSafe $r.Id
            $rname  = ConvertTo-HtmlSafe $r.Name
            $rmeta  = ConvertTo-HtmlSafe $r.Meta
            $rdet   = ConvertTo-HtmlSafe $r.Detail
            $rev    = ConvertTo-HtmlSafe $r.Evidence
            $rst    = Get-StatusClass $r.Status
            $rstLbl = ConvertTo-HtmlSafe $r.StatusLabel
            [void]$sb.AppendLine("  <div class=`"rule $rst`">")
            [void]$sb.AppendLine('    <div class="rule-head">')
            [void]$sb.AppendLine("      <span class=`"rule-id`">$rid</span>")
            [void]$sb.AppendLine("      <span class=`"rule-name`">$rname</span>")
            [void]$sb.AppendLine("      <span class=`"rule-pill`"><span class=`"pill $rst`">$rstLbl</span></span>")
            [void]$sb.AppendLine('    </div>')
            if ($rmeta) { [void]$sb.AppendLine("    <div class=`"rule-meta`">$rmeta</div>") }
            if ($rdet)  { [void]$sb.AppendLine("    <div class=`"rule-meta`">$rdet</div>") }
            if ($rev)   { [void]$sb.AppendLine("    <div class=`"rule-evidence`">$rev</div>") }
            [void]$sb.AppendLine('  </div>')
        }

        [void]$sb.AppendLine('  <div class="page-foot">')
        [void]$sb.AppendLine("    <span class=`"ref`">Referentiel &middot; ANSSI &middot; Guide d'Hygiene Informatique &middot; module $num</span>")
        [void]$sb.AppendLine('    <span class="rid">{{REPORT_ID}}</span>')
        [void]$sb.AppendLine('  </div>')
        [void]$sb.AppendLine('</div>')
        $pageNum++
    }
    return $sb.ToString()
}

# ===========================================================================
# PDF CONVERSION
# ===========================================================================
function ConvertTo-PdfWithEdge {
    param([string]$HtmlPath, [string]$PdfPath)
    $edge = Get-EdgePath
    if (-not $edge) { return $false }
    $uri = ([System.Uri]$HtmlPath).AbsoluteUri
    Write-Step "Edge: $edge"
    & $edge --headless=new --disable-gpu --no-pdf-header-footer "--print-to-pdf=$PdfPath" $uri 2>&1 | Out-Null
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) { Write-Warn "Edge exited with code $exitCode" }
    Start-Sleep -Milliseconds 500
    return (Test-Path $PdfPath)
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
Write-Host '  |  FIELDOPS PRO - ANSSI Diagnostic Report Builder v0.4           |' -ForegroundColor White
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

$moduleDetailCount = @($data.ModuleDetails).Count
$pageTotal = 2 + $moduleDetailCount + 1
Write-Step "Pages   : $pageTotal (1 couverture + 1 vue d'ensemble + $moduleDetailCount modules + 1 synthese)"

Write-Step 'Generating compliance spectrum...'
$spectrum = New-SpectrumBlock -ModuleDetails $data.ModuleDetails -Summary $data.Summary

Write-Step 'Generating findings block...'
$topFindings = New-TopFindingsBlock -Findings $data.TopFindings

Write-Step 'Generating module bars...'
$moduleBars = New-ModuleBarsBlock -Modules $data.Modules

Write-Step 'Generating module detail pages...'
$moduleDetails = New-ModuleDetailsBlock -ModuleDetails $data.ModuleDetails -PageStart 3 -PageTotal $pageTotal

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
    '{{SPECTRUM}}'          = $spectrum
    '{{TOP_FINDINGS}}'      = $topFindings
    '{{MODULE_BARS}}'       = $moduleBars
    '{{MODULE_DETAILS}}'    = $moduleDetails
    '{{REPORT_HASH}}'       = $hashPlaceholder
    # Single-brace placeholders carried in by the locale resolution above.
    # Counts are wrapped in <strong> so the perimeter sentence keeps emphasis
    # on its figures while remaining one translatable unit.
    '{cvCount}'             = ('<strong>' + [string]$data.Summary.CountCV + '</strong>')
    '{pvCount}'             = ('<strong>' + [string]$data.Summary.CountPV + '</strong>')
    '{hpCount}'             = ('<strong>' + [string]$data.Summary.CountHP + '</strong>')
    '{reportId}'            = (ConvertTo-HtmlSafe $data.Report.Id)
    '{dateHuman}'           = (ConvertTo-HtmlSafe $data.Report.GeneratedAtHuman)
}
foreach ($key in $replacements.Keys) { $html = $html.Replace($key, $replacements[$key]) }
# second pass: blocks may contain nested tokens (e.g. {{REPORT_ID}} in module footers)
foreach ($key in $replacements.Keys) {
    if ($key -eq '{{SPECTRUM}}' -or $key -eq '{{TOP_FINDINGS}}' -or $key -eq '{{MODULE_BARS}}' -or $key -eq '{{MODULE_DETAILS}}') { continue }
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
    if (Test-Path $pdfOutPath) { Remove-Item $pdfOutPath -Force }
    $pdfSuccess = ConvertTo-PdfWithEdge -HtmlPath $htmlOutPath -PdfPath $pdfOutPath
    if ($pdfSuccess) { $engineUsed = 'Edge headless' }
}
if (-not $pdfSuccess -and ($PdfEngine -eq 'Wkhtmltopdf' -or $PdfEngine -eq 'Auto')) {
    Write-Warn 'Edge failed or unavailable, trying wkhtmltopdf...'
    if (Test-Path $pdfOutPath) { Remove-Item $pdfOutPath -Force }
    $pdfSuccess = ConvertTo-PdfWithWkhtmltopdf -HtmlPath $htmlOutPath -PdfPath $pdfOutPath
    if ($pdfSuccess) { $engineUsed = 'wkhtmltopdf' }
}

if (-not $pdfSuccess) {
    Write-Warn 'PDF generation failed with all available engines.'
    Write-Host "  The rendered HTML is still available at: $htmlOutPath" -ForegroundColor White
    if (-not $NoOpen) { Write-Step 'Opening HTML instead...'; Start-Process -FilePath $htmlOutPath }
    return
}

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
