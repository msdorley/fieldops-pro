#Requires -Version 5.1
<#
.SYNOPSIS
    Dump how each FieldOps report formats its grade, so we can fix
    the dashboard grade extractor with certainty instead of guessing.
.DESCRIPTION
    Reads the most recent report for each engine, strips HTML, and prints
    ~200 characters of context around any letter-grade-like pattern.
    Run this once and paste the output back -- I'll write the exact regex
    that matches YOUR reports.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
$scriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$scriptsDir = Split-Path -Parent $scriptDir
$usbRoot    = Split-Path -Parent $scriptsDir
$reportsDir = Join-Path $usbRoot 'REPORTS'

Write-Host ''
Write-Host '  FIELDOPS PRO -- GRADE EXTRACTION DIAGNOSTIC' -ForegroundColor Cyan
Write-Host '  ======================================================================' -ForegroundColor Cyan
Write-Host ''

$engines = @(
    'PCHealth'
    'DiskAnalysis'
    'NetRepair'
    'SecurityScan'
    'AzureADJoin'
    'ComplianceDiff'
    'FieldOps_Master'
)

foreach ($engine in $engines) {
    Write-Host "  [$engine]" -ForegroundColor Yellow
    $files = @(Get-ChildItem -Path $reportsDir -Filter "$engine`_*.html" -ErrorAction SilentlyContinue |
               Sort-Object LastWriteTime -Descending)
    if ($files.Count -eq 0) {
        Write-Host "    (no reports)" -ForegroundColor DarkGray
        Write-Host ''
        continue
    }
    $f = $files[0]
    Write-Host "    File: $($f.Name) ($([math]::Round($f.Length / 1KB, 1)) KB)" -ForegroundColor DarkGray

    try {
        $whole = Get-Content $f.FullName -Raw
        $plain = ($whole -replace '<[^>]+>',' ' -replace '&nbsp;',' ' -replace '\s+',' ')

        # Strategy 1: find any "Grade" word and show 150 chars of context
        $gradeMatches = [regex]::Matches($plain, '(?i)\bgrade\b')
        if ($gradeMatches.Count -gt 0) {
            Write-Host "    'Grade' keyword found $($gradeMatches.Count) time(s):" -ForegroundColor Green
            $shown = 0
            foreach ($m in $gradeMatches) {
                if ($shown -ge 3) { break }
                $start = [math]::Max(0, $m.Index - 20)
                $end   = [math]::Min($plain.Length, $m.Index + 150)
                $ctx = $plain.Substring($start, $end - $start)
                Write-Host "      -> ...$ctx..." -ForegroundColor White
                $shown++
            }
        } else {
            Write-Host "    'Grade' keyword NOT found" -ForegroundColor Red
        }

        # Strategy 2: find any standalone letter-grade patterns
        $letterMatches = [regex]::Matches($plain, '(?:^|\s|>)([A-F][+-]?)(?:\s*\(?\s*(\d{1,3})\s*%\)?|\s|<)')
        if ($letterMatches.Count -gt 0) {
            Write-Host "    Letter grade candidates: $($letterMatches.Count)" -ForegroundColor Green
            $i = 0
            foreach ($m in $letterMatches) {
                if ($i -ge 5) { break }
                $start = [math]::Max(0, $m.Index - 15)
                $end   = [math]::Min($plain.Length, $m.Index + 60)
                $ctx = $plain.Substring($start, $end - $start)
                Write-Host "      #$i grade='$($m.Groups[1].Value)' score='$($m.Groups[2].Value)' ctx=...$ctx..." -ForegroundColor White
                $i++
            }
        }

        # Strategy 3: find any XX% patterns to see what's around them
        $pctMatches = [regex]::Matches($plain, '(\d{1,3})\s*%')
        Write-Host "    Total '%' patterns found: $($pctMatches.Count)" -ForegroundColor DarkGray
        if ($pctMatches.Count -gt 0 -and $pctMatches.Count -le 20) {
            foreach ($m in $pctMatches) {
                $start = [math]::Max(0, $m.Index - 30)
                $end   = [math]::Min($plain.Length, $m.Index + 10)
                $ctx = $plain.Substring($start, $end - $start)
                Write-Host "      -> ...$ctx..." -ForegroundColor DarkGray
            }
        }

        # Strategy 4: look for common keywords the reports might use
        foreach ($kw in @('SCORE','ASSESSMENT','OVERALL','RESULT','HEALTH','STATUS','COMPLETE')) {
            if ($plain -match "(?i)\b$kw\b[\s:]+([^<>\n]{0,80})") {
                Write-Host "    '$kw' -> $($Matches[1])" -ForegroundColor Cyan
            }
        }
    } catch {
        Write-Host "    ERROR: $_" -ForegroundColor Red
    }

    Write-Host ''
}

Write-Host '  ======================================================================' -ForegroundColor Cyan
Write-Host '  Please paste this entire output in your next message.' -ForegroundColor Yellow
Write-Host '  ======================================================================' -ForegroundColor Cyan
Write-Host ''
