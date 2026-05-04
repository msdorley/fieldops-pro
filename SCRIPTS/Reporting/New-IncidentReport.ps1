<#
.SYNOPSIS
    FieldOps Pro - Incident Report Generator v1.0
.DESCRIPTION
    Generates a professional incident report by collecting results from all
    diagnostic engines, session logs, and technician identity. Produces a
    print-ready HTML document suitable for management review, ticket attachment,
    or compliance audit. Optionally exports a complete session package (ZIP).
.PARAMETER IncidentId
    Ticket or incident reference number.
.PARAMETER Category
    Incident category: Deployment, Maintenance, Troubleshooting, Security, Audit.
.PARAMETER Summary
    Brief description of why the technician visited this machine.
.PARAMETER Actions
    Description of actions taken during the visit.
.PARAMETER Recommendations
    Follow-up recommendations for the machine or user.
.PARAMETER ExportZip
    Create a ZIP package containing all reports, logs, and session data.
.PARAMETER Since
    Only include reports generated after this datetime. Default: last 24 hours.
.NOTES
    Author  : FieldOps Pro
    Version : 1.0
    Location: E:\SCRIPTS\Core\New-IncidentReport.ps1
#>

[CmdletBinding()]
param(
    [string]$IncidentId = '',
    [string]$Category = 'Maintenance',
    [string]$Summary = '',
    [string]$Actions = '',
    [string]$Recommendations = '',
    [switch]$ExportZip,
    [datetime]$Since = (Get-Date).AddHours(-24)
)

#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ============================================================
# PATH SETUP
# ============================================================
$ScriptRoot  = $PSScriptRoot
$ProjectRoot = Split-Path (Split-Path $ScriptRoot -Parent) -Parent
$ReportsPath = Join-Path $ProjectRoot 'REPORTS'
$LogsPath    = Join-Path $ProjectRoot 'LOGS'
$ConfigPath  = Join-Path $ProjectRoot 'CONFIG'
$HistoryDir  = Join-Path $ReportsPath 'History'

@($ReportsPath, $LogsPath) | ForEach-Object {
    if (-not (Test-Path $_)) { New-Item $_ -ItemType Directory -Force | Out-Null }
}

$Hostname  = $env:COMPUTERNAME
$Timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$DateHuman = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$DateShort = Get-Date -Format 'yyyy-MM-dd'
$IsAdmin   = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# ============================================================
# TECHNICIAN IDENTITY
# ============================================================
$tech = @{Name="$env:USERDOMAIN\$env:USERNAME"; Email=''; EmployeeId=''; Region=''; Role=''}
try {
    $techJson = Join-Path $ConfigPath 'technician.json'
    if (Test-Path $techJson) {
        $td = Get-Content $techJson -Raw | ConvertFrom-Json
        if ($td.Name)       { $tech.Name       = $td.Name }
        if ($td.Email)      { $tech.Email      = $td.Email }
        if ($td.EmployeeId) { $tech.EmployeeId = $td.EmployeeId }
        if ($td.Region)     { $tech.Region     = $td.Region }
        if ($td.Role)       { $tech.Role       = $td.Role }
    }
} catch {}

# ============================================================
# SYSTEM IDENTITY
# ============================================================
$machine = @{Manufacturer='Unknown';Model='Unknown';Serial='Unknown';OS='Unknown';Build='';RAM='';CPU='';Domain=''}
try {
    $os   = Get-CimInstance Win32_OperatingSystem -EA Stop
    $cs   = Get-CimInstance Win32_ComputerSystem -EA Stop
    $bios = Get-CimInstance Win32_BIOS -EA Stop
    $cpu  = Get-CimInstance Win32_Processor -EA Stop | Select-Object -First 1
    $machine.Manufacturer = $cs.Manufacturer
    $machine.Model        = $cs.Model
    $machine.Serial       = $bios.SerialNumber
    $machine.OS           = "$($os.Caption) ($($os.Version))"
    $machine.Build        = $os.BuildNumber
    $machine.RAM          = "$([math]::Round($cs.TotalPhysicalMemory / 1GB, 1)) GB"
    $machine.CPU          = $cpu.Name
    $machine.Domain       = $cs.Domain
} catch {}

# ============================================================
# BANNER
# ============================================================
Write-Host ''
Write-Host '============================================================' -ForegroundColor White
Write-Host '  FieldOps Pro - Incident Report Generator v1.0' -ForegroundColor White
Write-Host '============================================================' -ForegroundColor White
Write-Host ''
Write-Host "  Technician : $($tech.Name)$(if($tech.EmployeeId){" | $($tech.EmployeeId)"})" -ForegroundColor Cyan
Write-Host "  Machine    : $Hostname ($($machine.Manufacturer) $($machine.Model))" -ForegroundColor Cyan
Write-Host "  Date       : $DateHuman" -ForegroundColor Gray
if ($IncidentId) { Write-Host "  Incident   : $IncidentId" -ForegroundColor Yellow }
if ($Category)   { Write-Host "  Category   : $Category" -ForegroundColor Gray }
Write-Host ''

# ============================================================
# DISCOVER ENGINE REPORTS
# ============================================================
Write-Host '  Discovering engine reports...' -ForegroundColor Gray

$enginePatterns = @(
    @{Name='PCHealth';      Pattern="PCHealth_${Hostname}_*";     Domain='Hardware';  Color='#2196f3'; Weight=1.0}
    @{Name='DiskAnalysis';  Pattern="DiskAnalysis_${Hostname}_*"; Domain='Storage';   Color='#ff9800'; Weight=0.8}
    @{Name='NetRepair';     Pattern="NetRepair_${Hostname}_*";    Domain='Network';   Color='#4caf50'; Weight=1.2}
    @{Name='SecurityScan';  Pattern="SecurityScan_${Hostname}_*"; Domain='Security';  Color='#9c27b0'; Weight=1.5}
    @{Name='AzureADJoin';   Pattern="AzureADJoin_${Hostname}_*";  Domain='Identity';  Color='#00bcd4'; Weight=1.0}
    @{Name='FieldOps_Master'; Pattern="FieldOps_Master_${Hostname}_*"; Domain='Master'; Color='#fff'; Weight=0}
)

$discoveredReports = [System.Collections.ArrayList]::new()

foreach ($ep in $enginePatterns) {
    $found = Get-ChildItem $ReportsPath -Filter "$($ep.Pattern).html" -EA SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $Since } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1

    if ($found) {
        $reportData = @{
            Name    = $ep.Name
            Domain  = $ep.Domain
            Color   = $ep.Color
            Weight  = $ep.Weight
            File    = $found.FullName
            FileName = $found.Name
            Time    = $found.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
            Size    = "$([math]::Round($found.Length / 1KB, 1)) KB"
            Grade   = 'N/A'
            Pct     = 0
            Pass    = 0; Warn = 0; Fail = 0; Info = 0; Checks = 0
            Findings = [System.Collections.ArrayList]::new()
        }

        # Parse the HTML report for key metrics
        try {
            $htmlContent = Get-Content $found.FullName -Raw -Encoding UTF8 -EA Stop

            # Extract grade
            if ($htmlContent -match 'Grade:\s*([A-F][+-]?)\s*\((\d+)%\)' -or
                $htmlContent -match '>([A-F][+-]?)</text>' -or
                $htmlContent -match '>([A-F][+-]?)</div>') {
                $reportData.Grade = $Matches[1]
            }
            if ($htmlContent -match '(\d+)%') {
                # Find percentage near grade context
                $pctMatches = [regex]::Matches($htmlContent, '(\d+)%')
                foreach ($pm in $pctMatches) {
                    $v = [int]$pm.Groups[1].Value
                    if ($v -ge 40 -and $v -le 100 -and $reportData.Pct -eq 0) { $reportData.Pct = $v; break }
                }
            }

            # Extract pass/warn/fail from stats
            if ($htmlContent -match '(\d+)\s*Pass.*?(\d+)\s*Warn.*?(\d+)\s*Fail') {
                $reportData.Pass = [int]$Matches[1]; $reportData.Warn = [int]$Matches[2]; $reportData.Fail = [int]$Matches[3]
                $reportData.Checks = $reportData.Pass + $reportData.Warn + $reportData.Fail
            }

            # Extract findings (Warning/Fail rows from the checks table)
            $findingMatches = [regex]::Matches($htmlContent, 'status-(?:warn|fail)[^>]*>[^<]*(?:Warning|Fail)[^<]*</td>\s*<td>([^<]+)</td>\s*<td>([^<]+)</td>')
            foreach ($fm in $findingMatches) {
                if ($reportData.Findings.Count -lt 20) {
                    $null = $reportData.Findings.Add(@{Check=$fm.Groups[1].Value; Value=$fm.Groups[2].Value})
                }
            }
        } catch {}

        $null = $discoveredReports.Add([PSCustomObject]$reportData)
        Write-Host "  [FOUND] $($ep.Name) : $($reportData.Grade) ($($reportData.Pct)%) | $($reportData.Time)" -ForegroundColor Green
    } else {
        Write-Host "  [----] $($ep.Name) : No recent report (since $($Since.ToString('yyyy-MM-dd HH:mm')))" -ForegroundColor DarkGray
    }
}

$engineReports = @($discoveredReports | Where-Object { $_.Domain -ne 'Master' })
$masterReport  = $discoveredReports | Where-Object { $_.Domain -eq 'Master' } | Select-Object -First 1

Write-Host ''
Write-Host "  Found $($engineReports.Count) engine report(s) and $(if($masterReport){'1 master report'}else{'no master report'})" -ForegroundColor White

# ============================================================
# DISCOVER SESSION LOGS
# ============================================================
Write-Host '  Discovering session data...' -ForegroundColor Gray

$sessionFiles = @(Get-ChildItem $LogsPath -Filter "*.json" -EA SilentlyContinue |
    Where-Object { $_.LastWriteTime -ge $Since -and $_.Name -match $Hostname } |
    Sort-Object LastWriteTime -Descending | Select-Object -First 5)

$historyFiles = @(Get-ChildItem $HistoryDir -Filter "${Hostname}_*.json" -EA SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 2)

# Load latest history for unified grade
$latestHistory = $null
if ($historyFiles.Count -gt 0) {
    try { $latestHistory = Get-Content $historyFiles[0].FullName -Raw | ConvertFrom-Json } catch {}
}

$unifiedGrade = if ($latestHistory -and $latestHistory.Grade) { $latestHistory.Grade } else { 'N/A' }
$unifiedPct   = if ($latestHistory -and $latestHistory.Pct)   { $latestHistory.Pct } else { 0 }
$riskLevel    = if ($latestHistory -and $latestHistory.Risk)   { $latestHistory.Risk } else { 'Unknown' }

Write-Host "  Latest unified: $unifiedGrade ($unifiedPct%) | Risk: $riskLevel" -ForegroundColor $(if($unifiedPct -ge 80){'Green'}elseif($unifiedPct -ge 60){'Yellow'}else{'Red'})

# ============================================================
# COMPUTE INCIDENT METRICS
# ============================================================
$totalChecks   = 0; $totalPass = 0; $totalWarn = 0; $totalFail = 0
$allFindings   = [System.Collections.ArrayList]::new()
$engineSummary = [System.Collections.ArrayList]::new()

foreach ($rpt in $engineReports) {
    $totalChecks += $rpt.Checks
    $totalPass   += $rpt.Pass
    $totalWarn   += $rpt.Warn
    $totalFail   += $rpt.Fail
    foreach ($f in $rpt.Findings) { $null = $allFindings.Add([PSCustomObject]@{Engine=$rpt.Name;Domain=$rpt.Domain;Check=$f.Check;Value=$f.Value}) }
    $null = $engineSummary.Add([PSCustomObject]@{Name=$rpt.Name;Domain=$rpt.Domain;Grade=$rpt.Grade;Pct=$rpt.Pct;Pass=$rpt.Pass;Warn=$rpt.Warn;Fail=$rpt.Fail;Checks=$rpt.Checks;Color=$rpt.Color;Time=$rpt.Time})
}

# Auto-generate summary if not provided
if (-not $Summary) {
    $Summary = "Routine $($Category.ToLower()) assessment of $Hostname ($($machine.Manufacturer) $($machine.Model)). " +
               "$($engineReports.Count) diagnostic engine(s) executed with $totalChecks total checks. " +
               "Unified grade: $unifiedGrade ($unifiedPct%). Risk level: $riskLevel."
}

# Auto-generate recommendations if not provided
if (-not $Recommendations -and $allFindings.Count -gt 0) {
    $recParts = [System.Collections.ArrayList]::new()
    if ($totalFail -gt 0) { $null = $recParts.Add("Address $totalFail critical failure(s) immediately.") }
    if ($totalWarn -gt 5) { $null = $recParts.Add("Review $totalWarn warning(s) and remediate within 1 week.") }

    # Domain-specific recs
    $secFindings = @($allFindings | Where-Object {$_.Domain -eq 'Security'}).Count
    $idFindings  = @($allFindings | Where-Object {$_.Domain -eq 'Identity'}).Count
    if ($secFindings -gt 5)  { $null = $recParts.Add("Security posture needs hardening - run SecurityScan with AutoFix.") }
    if ($idFindings -gt 0)   { $null = $recParts.Add("Complete Azure AD enrollment for central management.") }

    $null = $recParts.Add("Schedule follow-up assessment in 2 weeks.")
    $Recommendations = $recParts -join ' '
}

# ============================================================
# INTERACTIVE PROMPTS (if fields missing)
# ============================================================
if (-not $IncidentId) {
    $IncidentId = Read-Host '  Incident/Ticket ID (or press Enter to skip)'
    if (-not $IncidentId) { $IncidentId = "FR-$($Timestamp.Substring(0,8))-$($Hostname)" }
}

if (-not $Actions) {
    Write-Host ''
    Write-Host '  Describe actions taken (or press Enter for auto-summary):' -ForegroundColor Yellow
    $Actions = Read-Host '  '
    if (-not $Actions) {
        $actionParts = [System.Collections.ArrayList]::new()
        foreach ($rpt in $engineReports) {
            $null = $actionParts.Add("Ran $($rpt.Name) diagnostic ($($rpt.Grade) $($rpt.Pct)%)")
        }
        $Actions = ($actionParts -join '. ') + '.'
    }
}

# ============================================================
# GENERATE HTML INCIDENT REPORT
# ============================================================
Write-Host ''
Write-Host '  Generating incident report...' -ForegroundColor Gray

$ReportFile = Join-Path $ReportsPath "IncidentReport_${Hostname}_${Timestamp}.html"

# Severity color helper
$overallColor = if ($unifiedPct -ge 80) {'#4caf50'} elseif ($unifiedPct -ge 60) {'#ff9800'} else {'#f44336'}
$riskBadgeColor = switch ($riskLevel) {'CRITICAL'{'#f44336'}'HIGH'{'#ff5722'}'MEDIUM'{'#ff9800'}'LOW'{'#ffca28'}default{'#4caf50'}}

# Engine summary table rows
$engineTableRows = ''
foreach ($es in $engineSummary) {
    $gc = if ($es.Pct -ge 80) {'#4caf50'} elseif ($es.Pct -ge 60) {'#ff9800'} else {'#f44336'}
    $barW = [math]::Max($es.Pct, 0)
    $engineTableRows += @"
<tr>
  <td style="font-weight:700;color:$($es.Color)">$($es.Name)</td>
  <td>$($es.Domain)</td>
  <td style="font-weight:700;color:$gc">$($es.Grade)</td>
  <td><div class="bar-track"><div class="bar-fill" style="width:${barW}%;background:$gc"></div></div></td>
  <td style="text-align:center">$($es.Pct)%</td>
  <td class="sp">$($es.Pass)</td>
  <td class="sw">$($es.Warn)</td>
  <td class="sf">$($es.Fail)</td>
  <td>$($es.Checks)</td>
  <td style="font-size:0.8em;color:#888">$($es.Time)</td>
</tr>
"@
}

# Findings table rows
$findingsTableRows = ''
$fi = 0
foreach ($af in $allFindings) {
    $fi++
    if ($fi -gt 30) { $findingsTableRows += "<tr><td colspan='4' style='color:#888;font-style:italic'>... and $($allFindings.Count - 30) more findings</td></tr>"; break }
    $findingsTableRows += "<tr><td>$($af.Engine)</td><td>$($af.Domain)</td><td>$($af.Check)</td><td>$($af.Value)</td></tr>"
}

# Linked reports
$linkedReportsHtml = ''
foreach ($rpt in $discoveredReports) {
    $linkedReportsHtml += "<a href='$($rpt.FileName)' class='rpt-link'>$($rpt.Name) ($($rpt.Grade)) - $($rpt.Size)</a> "
}

# Machine info rows
$machineRows = ''
foreach ($mk in @('Manufacturer','Model','Serial','OS','Build','RAM','CPU','Domain')) {
    $machineRows += "<tr><td class='mi-label'>$mk</td><td>$($machine[$mk])</td></tr>"
}
$machineRows += "<tr><td class='mi-label'>Hostname</td><td>$Hostname</td></tr>"
$machineRows += "<tr><td class='mi-label'>User</td><td>$env:USERNAME</td></tr>"
$machineRows += "<tr><td class='mi-label'>Admin</td><td>$IsAdmin</td></tr>"

# Build the report
$Html = @"
<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>Incident Report $IncidentId | $Hostname</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:'Segoe UI',Tahoma,sans-serif;background:#fff;color:#222;padding:0;line-height:1.6;font-size:11pt}
.page{max-width:900px;margin:0 auto;padding:32px 40px}

/* Header band */
.header-band{background:linear-gradient(135deg,#1a237e,#283593);color:#fff;padding:28px 40px;margin:-32px -40px 28px;border-radius:0 0 8px 8px}
.header-band h1{font-size:1.5em;font-weight:800;letter-spacing:0.5px;margin-bottom:2px}
.header-band .subtitle{font-size:0.88em;opacity:0.8}
.header-meta{display:flex;flex-wrap:wrap;gap:24px;margin-top:16px;padding-top:14px;border-top:1px solid rgba(255,255,255,0.2)}
.header-meta .item{font-size:0.82em}
.header-meta .label{opacity:0.6;display:block;font-size:0.88em;text-transform:uppercase;letter-spacing:0.5px}
.header-meta .value{font-weight:700}

/* Grade badge */
.grade-section{display:flex;align-items:center;gap:28px;background:#f5f7ff;border:1px solid #e0e4f0;border-radius:10px;padding:20px 28px;margin-bottom:24px}
.grade-circle{width:80px;height:80px;border-radius:50%;display:flex;align-items:center;justify-content:center;font-size:1.8em;font-weight:900;flex-shrink:0;border:4px solid;color:#fff}
.grade-info{flex:1}
.grade-info h2{font-size:1.1em;font-weight:700;color:#333;margin-bottom:4px}
.grade-bar{width:100%;height:12px;background:#e0e4f0;border-radius:6px;overflow:hidden;margin:6px 0}
.grade-bar-fill{height:100%;border-radius:6px}
.grade-stats{display:flex;gap:16px;font-size:0.85em;color:#666}
.risk-badge{display:inline-block;padding:3px 12px;border-radius:16px;font-weight:700;font-size:0.8em;margin-left:10px;color:#fff}

/* Sections */
.section{margin-bottom:24px}
.section h3{font-size:1em;font-weight:700;color:#1a237e;border-bottom:2px solid #e0e4f0;padding-bottom:6px;margin-bottom:12px}
.section p{font-size:0.92em;color:#444;line-height:1.7;margin-bottom:8px}

/* Tables */
table{width:100%;border-collapse:collapse;font-size:0.88em;margin-bottom:16px}
th{background:#f0f2f8;color:#333;padding:8px 10px;text-align:left;font-weight:600;border-bottom:2px solid #dde}
td{padding:7px 10px;border-bottom:1px solid #eee;vertical-align:top}
tr:hover{background:#f8f9ff}
.mi-label{color:#666;font-weight:600;width:120px}
.sp{color:#2e7d32;font-weight:600;text-align:center}
.sw{color:#e65100;font-weight:600;text-align:center}
.sf{color:#c62828;font-weight:600;text-align:center}

/* Bars */
.bar-track{width:100%;height:10px;background:#e8eaf0;border-radius:5px;overflow:hidden;min-width:80px}
.bar-fill{height:100%;border-radius:5px}

/* Links */
.rpt-link{display:inline-block;margin:4px 6px 4px 0;padding:6px 14px;background:#f0f2f8;border:1px solid #dde;border-radius:6px;color:#1a237e;text-decoration:none;font-weight:600;font-size:0.85em}
.rpt-link:hover{background:#e0e4f0}

/* Signature */
.signature{margin-top:40px;padding-top:20px;border-top:2px solid #dde}
.sig-grid{display:flex;gap:40px;flex-wrap:wrap}
.sig-box{flex:1;min-width:200px}
.sig-label{font-size:0.82em;color:#888;text-transform:uppercase;letter-spacing:0.5px}
.sig-value{font-size:0.95em;font-weight:600;color:#222;margin-top:2px}
.sig-line{border-bottom:1px solid #333;margin-top:40px;margin-bottom:4px}

/* Footer */
.footer{text-align:center;padding:20px 0;color:#aaa;font-size:0.78em;border-top:1px solid #eee;margin-top:32px}

/* Print */
@media print{
  body{font-size:10pt}
  .page{padding:20px 24px;max-width:100%}
  .header-band{margin:-20px -24px 20px;-webkit-print-color-adjust:exact;print-color-adjust:exact}
  .grade-circle{-webkit-print-color-adjust:exact;print-color-adjust:exact}
  .grade-bar-fill,.bar-fill{-webkit-print-color-adjust:exact;print-color-adjust:exact}
  .risk-badge{-webkit-print-color-adjust:exact;print-color-adjust:exact}
  .rpt-link{display:none}
  .no-print{display:none}
}
</style></head><body>
<div class="page">

<!-- HEADER -->
<div class="header-band">
  <h1>FIELDOPS PRO -- INCIDENT REPORT</h1>
  <div class="subtitle">Field Operations Diagnostic Assessment</div>
  <div class="header-meta">
    <div class="item"><span class="label">Incident ID</span><span class="value">$IncidentId</span></div>
    <div class="item"><span class="label">Category</span><span class="value">$Category</span></div>
    <div class="item"><span class="label">Date</span><span class="value">$DateHuman</span></div>
    <div class="item"><span class="label">Hostname</span><span class="value">$Hostname</span></div>
    <div class="item"><span class="label">Technician</span><span class="value">$($tech.Name)$(if($tech.EmployeeId){" ($($tech.EmployeeId))"})</span></div>
    $(if($tech.Region){"<div class='item'><span class='label'>Region</span><span class='value'>$($tech.Region)</span></div>"})
  </div>
</div>

<!-- UNIFIED GRADE -->
<div class="grade-section">
  <div class="grade-circle" style="background:$overallColor;border-color:$overallColor">$unifiedGrade</div>
  <div class="grade-info">
    <h2>Unified Health Score: $unifiedPct%
      <span class="risk-badge" style="background:$riskBadgeColor">$riskLevel RISK</span>
    </h2>
    <div class="grade-bar"><div class="grade-bar-fill" style="width:${unifiedPct}%;background:$overallColor"></div></div>
    <div class="grade-stats">
      <span class="sp">$totalPass Passed</span>
      <span class="sw">$totalWarn Warnings</span>
      <span class="sf">$totalFail Failures</span>
      <span style="color:#888">$totalChecks Total Checks</span>
      <span style="color:#888">$($engineReports.Count) Engines</span>
    </div>
  </div>
</div>

<!-- EXECUTIVE SUMMARY -->
<div class="section">
  <h3>1. Executive Summary</h3>
  <p>$Summary</p>
</div>

<!-- MACHINE IDENTITY -->
<div class="section">
  <h3>2. Machine Identity</h3>
  <table>$machineRows</table>
</div>

<!-- ENGINE RESULTS -->
<div class="section">
  <h3>3. Diagnostic Engine Results</h3>
  <table>
    <tr><th>Engine</th><th>Domain</th><th>Grade</th><th>Score</th><th>%</th><th>Pass</th><th>Warn</th><th>Fail</th><th>Checks</th><th>Scan Time</th></tr>
    $engineTableRows
  </table>
</div>

<!-- FINDINGS -->
$(if($allFindings.Count -gt 0){@"
<div class="section">
  <h3>4. Findings ($($allFindings.Count) total)</h3>
  <table>
    <tr><th>Engine</th><th>Domain</th><th>Check</th><th>Finding</th></tr>
    $findingsTableRows
  </table>
</div>
"@} else {
"<div class='section'><h3>4. Findings</h3><p>No warnings or failures detected across all engines.</p></div>"
})

<!-- ACTIONS TAKEN -->
<div class="section">
  <h3>5. Actions Taken</h3>
  <p>$Actions</p>
</div>

<!-- RECOMMENDATIONS -->
<div class="section">
  <h3>6. Recommendations</h3>
  <p>$Recommendations</p>
</div>

<!-- LINKED REPORTS -->
$(if($linkedReportsHtml){@"
<div class="section no-print">
  <h3>7. Linked Reports</h3>
  <p>$linkedReportsHtml</p>
</div>
"@})

<!-- SIGNATURE -->
<div class="signature">
  <div class="sig-grid">
    <div class="sig-box">
      <div class="sig-label">Technician</div>
      <div class="sig-value">$($tech.Name)</div>
      $(if($tech.EmployeeId){"<div class='sig-value' style='font-size:0.82em;color:#666'>$($tech.EmployeeId)</div>"})
      $(if($tech.Region){"<div class='sig-value' style='font-size:0.82em;color:#666'>$($tech.Region)</div>"})
      <div class="sig-line"></div>
      <div class="sig-label" style="margin-top:4px">Signature</div>
    </div>
    <div class="sig-box">
      <div class="sig-label">Date</div>
      <div class="sig-value">$DateShort</div>
      <div class="sig-label" style="margin-top:16px">Incident Reference</div>
      <div class="sig-value">$IncidentId</div>
    </div>
    <div class="sig-box">
      <div class="sig-label">Machine</div>
      <div class="sig-value">$Hostname</div>
      <div class="sig-label" style="margin-top:16px">Serial</div>
      <div class="sig-value">$($machine.Serial)</div>
    </div>
  </div>
</div>

<div class="footer">
  FieldOps Pro -- Incident Report Generator v1.0 | $DateHuman | $IncidentId | $Hostname | $($tech.Name)
</div>

</div></body></html>
"@

$Html | Out-File -FilePath $ReportFile -Encoding UTF8 -Force
Write-Host "  Report: $ReportFile" -ForegroundColor Green

# ============================================================
# EXPORT SESSION PACKAGE (ZIP)
# ============================================================
if ($ExportZip) {
    Write-Host ''
    Write-Host '  Creating session package...' -ForegroundColor Gray

    $zipName = "FieldOps_${Hostname}_${Timestamp}.zip"
    $zipPath = Join-Path $ReportsPath $zipName
    $tempStaging = Join-Path $env:TEMP "FieldOps_Export_${Timestamp}"

    try {
        # Create staging folder
        New-Item $tempStaging -ItemType Directory -Force | Out-Null

        # Copy incident report
        Copy-Item $ReportFile $tempStaging -Force

        # Copy all discovered engine reports
        foreach ($rpt in $discoveredReports) {
            if (Test-Path $rpt.File) {
                Copy-Item $rpt.File $tempStaging -Force
            }
        }

        # Copy session/history JSON files
        foreach ($sf in $sessionFiles) { Copy-Item $sf.FullName $tempStaging -Force -EA SilentlyContinue }
        foreach ($hf in $historyFiles) { Copy-Item $hf.FullName $tempStaging -Force -EA SilentlyContinue }

        # Copy Autopilot hash if exists
        $apHash = Get-ChildItem $ReportsPath -Filter "AutopilotHash_${Hostname}*" -EA SilentlyContinue | Select-Object -First 1
        if ($apHash) { Copy-Item $apHash.FullName $tempStaging -Force }

        # Copy snapshot files
        $snapDir = Join-Path $ReportsPath 'Snapshots'
        if (Test-Path $snapDir) {
            $snaps = Get-ChildItem $snapDir -Filter "*${Hostname}*" -EA SilentlyContinue | Where-Object { $_.LastWriteTime -ge $Since }
            foreach ($s in $snaps) { Copy-Item $s.FullName $tempStaging -Force -EA SilentlyContinue }
        }

        # Create manifest
        $manifest = [PSCustomObject]@{
            GeneratedAt = $DateHuman
            IncidentId  = $IncidentId
            Hostname    = $Hostname
            Technician  = $tech.Name
            Category    = $Category
            UnifiedGrade = $unifiedGrade
            RiskLevel   = $riskLevel
            Files       = @(Get-ChildItem $tempStaging -File | ForEach-Object { $_.Name })
        }
        $manifest | ConvertTo-Json -Depth 3 | Out-File (Join-Path $tempStaging 'manifest.json') -Encoding UTF8 -Force

        # Compress
        Compress-Archive -Path "$tempStaging\*" -DestinationPath $zipPath -Force
        $zipSize = [math]::Round((Get-Item $zipPath).Length / 1KB, 1)

        Write-Host "  Package: $zipPath ($zipSize KB)" -ForegroundColor Green
        Write-Host "  Contains $(@(Get-ChildItem $tempStaging -File).Count) files" -ForegroundColor Gray

        # Cleanup staging
        Remove-Item $tempStaging -Recurse -Force -EA SilentlyContinue
    } catch {
        Write-Host "  ZIP export failed: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ============================================================
# FINAL SUMMARY
# ============================================================
Write-Host ''
Write-Host '============================================================' -ForegroundColor White
Write-Host '  INCIDENT REPORT COMPLETE' -ForegroundColor White
Write-Host '============================================================' -ForegroundColor White
Write-Host ''
Write-Host "  Incident  : $IncidentId" -ForegroundColor Yellow
Write-Host "  Grade     : $unifiedGrade ($unifiedPct%) | Risk: $riskLevel" -ForegroundColor $(if($unifiedPct -ge 80){'Green'}elseif($unifiedPct -ge 60){'Yellow'}else{'Red'})
Write-Host "  Engines   : $($engineReports.Count) | Checks: $totalChecks | Findings: $($allFindings.Count)" -ForegroundColor Gray
Write-Host "  Report    : $ReportFile" -ForegroundColor Cyan
if ($ExportZip) { Write-Host "  Package   : $zipPath" -ForegroundColor Cyan }
Write-Host ''
Write-Host "  Start-Process `"$ReportFile`"" -ForegroundColor DarkGray
Write-Host ''
