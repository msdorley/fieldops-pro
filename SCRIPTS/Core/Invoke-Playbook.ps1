#Requires -Version 5.1
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Ousman Dorley. See LICENSE at the repository root.
<#
.SYNOPSIS
    FieldOps Pro -- Deployment Playbook Orchestrator v1.0
.DESCRIPTION
    Runs multi-engine workflows defined in E:\PLAYBOOKS\*.json.
    Handles unattended scan engines, interactive action engines,
    score-based gate checks, halt-on-failure, step result tracking,
    and generates a combined HTML run report.
.PARAMETER Name
    Playbook name or filename (without .json). Opens selection menu if omitted.
.PARAMETER IncidentId
    Ticket number attached to this playbook run.
.PARAMETER DryRun
    Preview all steps without executing any engine.
.PARAMETER NoGates
    Ignore gate thresholds -- warn but never halt on score.
.PARAMETER Resume
    Resume the last interrupted playbook run for this host.
.PARAMETER OpenReport
    Open the HTML run report when playbook completes.
.EXAMPLE
    .\Invoke-Playbook.ps1
    .\Invoke-Playbook.ps1 -Name "new-hire-deployment"
    .\Invoke-Playbook.ps1 -Name "routine-maintenance" -IncidentId "INC-2026-04891"
    .\Invoke-Playbook.ps1 -DryRun
#>
[CmdletBinding()]
param(
    [string]$Name,
    [string]$IncidentId = '',
    [switch]$DryRun,
    [switch]$NoGates,
    [switch]$Resume,
    [switch]$OpenReport
)

$ErrorActionPreference = 'Continue'

# ==============================================================
# PATH RESOLUTION
# ==============================================================
$scriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path   # E:\SCRIPTS\Core
$scriptsDir  = Split-Path -Parent $scriptDir                      # E:\SCRIPTS
$usbRoot     = Split-Path -Parent $scriptsDir                     # E:\
$reportsDir  = Join-Path $usbRoot 'REPORTS'
$historyDir  = Join-Path $reportsDir 'History'
$playbooksDir= Join-Path $usbRoot 'PLAYBOOKS'
$configDir   = Join-Path $usbRoot 'CONFIG'
$logsDir     = Join-Path $usbRoot 'LOGS'

# ==============================================================
# CONFIG
# ==============================================================
$techName = 'Unknown Technician'
$cfgFile  = Join-Path $configDir 'FieldOps.config.json'
if (Test-Path $cfgFile) {
    try {
        $cfg = Get-Content $cfgFile -Raw | ConvertFrom-Json
        foreach ($f in @('TechnicianName','Technician','TechName','Tech','Name')) {
            $v = $cfg.$f
            if ($v -and $v.ToString().Trim() -ne '') { $techName = $v.ToString().Trim(); break }
        }
    } catch { }
}

# ==============================================================
# CONSTANTS
# ==============================================================
$VERSION   = '1.0'
$NOW       = Get-Date
$HOSTNAME  = $env:COMPUTERNAME
$W         = 72
$RUN_ID    = $NOW.ToString('yyyyMMdd_HHmmss')
$RUN_LOG   = Join-Path $logsDir "Playbook_$HOSTNAME`_$RUN_ID.json"
$REPORT_PATH = Join-Path $reportsDir "PlaybookRun_$HOSTNAME`_$RUN_ID.html"

# Step result constants
$SR_PASS  = 'PASS'
$SR_WARN  = 'WARN'
$SR_FAIL  = 'FAIL'
$SR_SKIP  = 'SKIP'
$SR_HALT  = 'HALT'

# ==============================================================
# DISPLAY HELPERS
# ==============================================================
function Write-Banner {
    Write-Host ('=' * $W) -ForegroundColor Cyan
    Write-Host "  FIELDOPS PRO -- PLAYBOOK ORCHESTRATOR v$VERSION" -ForegroundColor White
    if ($DryRun) {
        Write-Host "  *** DRY RUN MODE -- NO CHANGES WILL BE MADE ***" -ForegroundColor Yellow
    }
    Write-Host ('=' * $W) -ForegroundColor Cyan
    Write-Host "  Technician : $techName"
    Write-Host "  Host       : $HOSTNAME"
    Write-Host "  Date       : $($NOW.ToString('yyyy-MM-dd HH:mm:ss'))"
    Write-Host ('=' * $W) -ForegroundColor Cyan
}

function Write-Section { param([string]$T)
    Write-Host ''
    Write-Host "  $T" -ForegroundColor Yellow
    Write-Host ('  ' + ('-' * ($W - 2))) -ForegroundColor DarkGray
}

function Write-StepHeader {
    param([int]$Num, [int]$Total, [string]$Name, [string]$Engine, [string]$Mode)
    Write-Host ''
    Write-Host ('  ' + ('=' * ($W - 2))) -ForegroundColor DarkCyan
    Write-Host "  STEP $Num/$Total : $Name" -ForegroundColor Cyan
    Write-Host "  Engine     : $Engine  |  Mode: $Mode" -ForegroundColor DarkGray
    Write-Host ('  ' + ('=' * ($W - 2))) -ForegroundColor DarkCyan
}

function Write-StepResult {
    param([string]$Result, [string]$Detail = '')
    $color = switch ($Result) {
        $SR_PASS { 'Green'  }
        $SR_WARN { 'Yellow' }
        $SR_FAIL { 'Red'    }
        $SR_SKIP { 'DarkGray'}
        $SR_HALT { 'Red'    }
        default  { 'Gray'   }
    }
    Write-Host ''
    Write-Host "  [STEP $Result]  $Detail" -ForegroundColor $color
    Write-Host ''
}

function Write-GateAlert {
    param([string]$Level, [string]$Msg)
    $c = if ($Level -eq 'halt') { 'Red' } else { 'Yellow' }
    Write-Host ''
    Write-Host "  [GATE $($Level.ToUpper())] $Msg" -ForegroundColor $c
}

function Prompt-Continue {
    param([string]$Prompt = 'Continue to next step?')
    Write-Host "  $Prompt [Y/N] " -ForegroundColor Yellow -NoNewline
    $r = Read-Host
    return ($r.Trim().ToUpper() -eq 'Y' -or $r.Trim() -eq '')
}

# ==============================================================
# ENGINE MAP
# Engine -> Script name + execution mode
# Mode: UNATTENDED (stdin SKIP feeding) | INTERACTIVE (visible window, pause)
# ==============================================================
$ENGINE_MAP = @{
    PCHealth     = @{ Script='Invoke-PCHealth.ps1';      Mode='UNATTENDED'; Pattern='PCHealth*.html' }
    DiskAnalysis = @{ Script='Invoke-DiskAnalysis.ps1';  Mode='UNATTENDED'; Pattern='DiskAnalysis*.html' }
    NetRepair    = @{ Script='Invoke-NetRepair.ps1';     Mode='UNATTENDED'; Pattern='NetRepair*.html' }
    SecurityScan = @{ Script='Invoke-SecurityScan.ps1';  Mode='UNATTENDED'; Pattern='SecurityScan*.html' }
    AzureADJoin  = @{ Script='Invoke-AzureADJoin.ps1';  Mode='INTERACTIVE'; Pattern='AzureADJoin*.html' }
    SoftwareDeploy=@{ Script='Invoke-SoftwareDeploy.ps1';Mode='INTERACTIVE'; Pattern='Software*.html' }
    VPNSetup     = @{ Script='Invoke-VPNSetup.ps1';      Mode='INTERACTIVE'; Pattern='VPN*.html' }
    AutoFix      = @{ Script='Invoke-AutoFix.ps1';       Mode='INTERACTIVE'; Pattern='AutoFix*.html' }
    IncidentReport=@{ Script='New-IncidentReport.ps1';   Mode='UNATTENDED'; Pattern='Incident*.html' }
    FleetReport  = @{ Script='Invoke-FleetReport.ps1';   Mode='UNATTENDED'; Pattern='FleetReport*.html' }
    FieldOps     = @{ Script='Invoke-FieldOps.ps1';      Mode='UNATTENDED'; Pattern='FieldOps_Master*.html' }
}

# ==============================================================
# ENGINE SCORE EXTRACTION
# Reads most recent HTML or history JSON written after $After
# ==============================================================
function Get-EngineScore {
    param([string]$Pattern, [datetime]$After)

    # Strategy 1: history JSON written after step started
    $histFiles = @(Get-ChildItem -Path $historyDir -Filter '*.json' -ErrorAction SilentlyContinue |
                   Where-Object { $_.LastWriteTime -gt $After } |
                   Sort-Object LastWriteTime -Descending |
                   Select-Object -First 1)
    if ($histFiles.Count -gt 0) {
        try {
            $d = Get-Content $histFiles[0].FullName -Raw | ConvertFrom-Json
            foreach ($f in @('OverallScore','Score','TotalScore','HealthScore','Percentage')) {
                $v = $d.$f
                if ($null -ne $v) {
                    $n = [int]$v
                    if ($n -ge 0 -and $n -le 100) { return $n }
                }
            }
        } catch { }
    }

    # Strategy 2: HTML report written after step started
    $htmlFiles = @(Get-ChildItem -Path $reportsDir -Filter $Pattern -ErrorAction SilentlyContinue |
                   Where-Object { $_.LastWriteTime -gt $After } |
                   Sort-Object LastWriteTime -Descending |
                   Select-Object -First 1)
    if ($htmlFiles.Count -gt 0) {
        try {
            $html = Get-Content $htmlFiles[0].FullName -Raw
            # Pattern: score in a badge or large number element, e.g. ">88%<" or ">88 %<"
            $patterns = @(
                '>\s*(\d{1,3})\s*%\s*<',
                'score[^>]*>\s*(\d{1,3})',
                'grade[^>]*>\s*[A-F][+\-]?\s*\((\d{1,3})%\)',
                '(\d{1,3})%\s*overall',
                '"score"\s*:\s*(\d{1,3})'
            )
            foreach ($pat in $patterns) {
                if ($html -match $pat) {
                    $n = [int]$matches[1]
                    if ($n -ge 30 -and $n -le 100) { return $n }
                }
            }
        } catch { }
    }

    return $null
}

# ==============================================================
# GATE EVALUATION
# Returns: 'pass' | 'warn' | 'halt'
# ==============================================================
function Test-Gate {
    param($Gate, [int]$Score, [bool]$NoGates)

    if ($null -eq $Gate) { return 'pass' }

    $threshold = 0
    $action    = 'warn'
    $message   = ''

    if ($Gate.scoreBelow) { $threshold = [int]$Gate.scoreBelow }
    if ($Gate.action)     { $action    = $Gate.action.ToLower() }
    if ($Gate.message)    { $message   = $Gate.message }

    if ($Score -lt $threshold) {
        if ($action -eq 'halt' -and -not $NoGates) { return 'halt' }
        return 'warn'
    }

    return 'pass'
}

# ==============================================================
# UNATTENDED ENGINE INVOCATION
# Runs engine as child process, feeds SKIP to stdin, shows output
# ==============================================================
function Invoke-Unattended {
    param([string]$ScriptPath, [string[]]$ExtraArgs, [int]$TimeoutSec = 600)

    if (-not (Test-Path $ScriptPath)) {
        Write-Host "  [WARN] Script not found: $ScriptPath" -ForegroundColor Yellow
        return $false
    }

    $argParts = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$ScriptPath`"") + @($ExtraArgs)
    $argStr   = $argParts -join ' '

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName              = 'powershell.exe'
    $psi.Arguments             = $argStr
    $psi.UseShellExecute       = $false
    $psi.RedirectStandardInput = $true
    $psi.CreateNoWindow        = $false     # output visible in parent console

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi

    try {
        $null = $proc.Start()
    } catch {
        Write-Host "  [ERROR] Could not start engine: $_" -ForegroundColor Red
        return $false
    }

    # Feed SKIP every 400ms to suppress any Read-Host prompts
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while (-not $proc.HasExited -and (Get-Date) -lt $deadline) {
        try { $proc.StandardInput.WriteLine('SKIP') } catch { }
        Start-Sleep -Milliseconds 400
    }

    if (-not $proc.HasExited) {
        Write-Host "  [WARN] Engine timed out after $($TimeoutSec)s. Killing." -ForegroundColor Yellow
        try { $proc.Kill() } catch { }
        return $false
    }

    return ($proc.ExitCode -eq 0)
}

# ==============================================================
# INTERACTIVE ENGINE INVOCATION
# Launches engine in a new PowerShell window, waits for tech to finish
# ==============================================================
function Invoke-Interactive {
    param([string]$ScriptPath, [string[]]$ExtraArgs, [string]$StepName)

    if (-not (Test-Path $ScriptPath)) {
        Write-Host "  [WARN] Script not found: $ScriptPath" -ForegroundColor Yellow
        return $false
    }

    $argParts = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', "`"$ScriptPath`"") + @($ExtraArgs)
    $argStr   = $argParts -join ' '

    Write-Host ''
    Write-Host "  [INTERACTIVE STEP] $StepName" -ForegroundColor Cyan
    Write-Host "  A new PowerShell window will open. Complete the step, then close it." -ForegroundColor Yellow
    Write-Host "  Press ENTER to launch the engine..." -ForegroundColor DarkGray
    $null = Read-Host

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName        = 'powershell.exe'
    $psi.Arguments       = $argStr
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow  = $false

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi

    try {
        $null = $proc.Start()
        $proc.WaitForExit()
    } catch {
        Write-Host "  [ERROR] Could not start engine: $_" -ForegroundColor Red
        return $false
    }

    Write-Host ''
    Write-Host "  Engine window closed." -ForegroundColor DarkGray
    return $true
}

# ==============================================================
# PRE-BUILT PLAYBOOK DEFINITIONS
# Written to E:\PLAYBOOKS\ on first run
# ==============================================================
function Write-DefaultPlaybooks {
    param([string]$Dir)
    if (-not (Test-Path $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }

    $playbooks = @{

'new-hire-deployment.json' = @'
{
  "id": "new-hire-deployment",
  "name": "New Hire Deployment",
  "description": "Complete new hire machine setup: hardware check, network repair, Azure AD enrollment, software deployment, VPN, security hardening, and incident report.",
  "category": "Deployment",
  "estimatedMinutes": 50,
  "targetModels": ["Dell Latitude 3450", "Dell Latitude 3540"],
  "steps": [
    {
      "id": "S01", "name": "Hardware Health Check", "engine": "PCHealth",
      "description": "Verify hardware is deployment-ready",
      "args": [],
      "gate": { "scoreBelow": 65, "action": "halt", "message": "Hardware too degraded for deployment. Replace or repair the machine before proceeding." },
      "continueOnFail": false, "interactive": false, "timeoutMinutes": 8
    },
    {
      "id": "S02", "name": "Disk Health Verification", "engine": "DiskAnalysis",
      "description": "Verify disk is healthy and has sufficient space",
      "args": [],
      "gate": { "scoreBelow": 65, "action": "halt", "message": "Disk health too low. Risk of data loss during deployment. Replace drive first." },
      "continueOnFail": false, "interactive": false, "timeoutMinutes": 10
    },
    {
      "id": "S03", "name": "Network Repair and Verification", "engine": "NetRepair",
      "description": "Repair network stack and verify connectivity",
      "args": [],
      "gate": { "scoreBelow": 50, "action": "warn", "message": "Network issues detected. Enrollment may fail. Check VPN/LAN connection." },
      "continueOnFail": true, "interactive": false, "timeoutMinutes": 8
    },
    {
      "id": "S04", "name": "Azure AD Enrollment", "engine": "AzureADJoin",
      "description": "Enroll machine into Azure AD and Intune MDM",
      "args": [],
      "gate": null,
      "continueOnFail": false, "interactive": true, "timeoutMinutes": 20
    },
    {
      "id": "S05", "name": "Software Deployment", "engine": "SoftwareDeploy",
      "description": "Install required software packages from USB repository",
      "args": [],
      "gate": null,
      "continueOnFail": true, "interactive": true, "timeoutMinutes": 30
    },
    {
      "id": "S06", "name": "GlobalProtect VPN Setup", "engine": "VPNSetup",
      "description": "Install and configure GlobalProtect VPN client",
      "args": [],
      "gate": null,
      "continueOnFail": true, "interactive": true, "timeoutMinutes": 10
    },
    {
      "id": "S07", "name": "Security Hardening", "engine": "AutoFix",
      "description": "Apply SAFE security fixes automatically",
      "args": [],
      "gate": null,
      "continueOnFail": true, "interactive": true, "timeoutMinutes": 10
    },
    {
      "id": "S08", "name": "Security Verification", "engine": "SecurityScan",
      "description": "Verify security posture after hardening",
      "args": [],
      "gate": { "scoreBelow": 75, "action": "warn", "message": "Security score below target. Review SecurityScan report and apply additional hardening." },
      "continueOnFail": true, "interactive": false, "timeoutMinutes": 10
    },
    {
      "id": "S09", "name": "Incident Report and ZIP Export", "engine": "IncidentReport",
      "description": "Generate professional incident report and export ZIP package",
      "args": ["-Category", "Deployment", "-ExportZip"],
      "gate": null,
      "continueOnFail": true, "interactive": false, "timeoutMinutes": 5
    }
  ]
}
'@

'routine-maintenance.json' = @'
{
  "id": "routine-maintenance",
  "name": "Routine Maintenance",
  "description": "Periodic health assessment: full hardware and security scan, auto-fix safe issues, generate maintenance report.",
  "category": "Maintenance",
  "estimatedMinutes": 25,
  "steps": [
    {
      "id": "S01", "name": "Full System Scan", "engine": "FieldOps",
      "description": "Run all diagnostic engines via master orchestrator",
      "args": [],
      "gate": { "scoreBelow": 60, "action": "warn", "message": "Machine health significantly degraded. Escalate for full remediation." },
      "continueOnFail": true, "interactive": false, "timeoutMinutes": 20
    },
    {
      "id": "S02", "name": "Apply Safe Fixes", "engine": "AutoFix",
      "description": "Apply all safe, reversible fixes detected by AutoFix",
      "args": [],
      "gate": null,
      "continueOnFail": true, "interactive": true, "timeoutMinutes": 10
    },
    {
      "id": "S03", "name": "Maintenance Report", "engine": "IncidentReport",
      "description": "Generate maintenance incident report",
      "args": ["-Category", "Maintenance"],
      "gate": null,
      "continueOnFail": true, "interactive": false, "timeoutMinutes": 5
    }
  ]
}
'@

'security-hardening.json' = @'
{
  "id": "security-hardening",
  "name": "Security Hardening",
  "description": "Dedicated security hardening workflow: baseline scan, apply all fixes, verify improvement, generate security report.",
  "category": "Security",
  "estimatedMinutes": 20,
  "steps": [
    {
      "id": "S01", "name": "Security Baseline Scan", "engine": "SecurityScan",
      "description": "Capture current security posture before hardening",
      "args": [],
      "gate": null,
      "continueOnFail": false, "interactive": false, "timeoutMinutes": 10
    },
    {
      "id": "S02", "name": "Apply Security Fixes", "engine": "AutoFix",
      "description": "Apply security fixes -- select level in interactive menu",
      "args": [],
      "gate": null,
      "continueOnFail": true, "interactive": true, "timeoutMinutes": 10
    },
    {
      "id": "S03", "name": "Post-Hardening Verification", "engine": "SecurityScan",
      "description": "Re-scan to verify hardening was applied successfully",
      "args": [],
      "gate": { "scoreBelow": 80, "action": "warn", "message": "Security score still below target after hardening. Manual review required." },
      "continueOnFail": true, "interactive": false, "timeoutMinutes": 10
    },
    {
      "id": "S04", "name": "Security Report", "engine": "IncidentReport",
      "description": "Generate security hardening incident report",
      "args": ["-Category", "Security", "-ExportZip"],
      "gate": null,
      "continueOnFail": true, "interactive": false, "timeoutMinutes": 5
    }
  ]
}
'@

'hardware-audit.json' = @'
{
  "id": "hardware-audit",
  "name": "Hardware Audit",
  "description": "Quick hardware-only assessment: CPU, RAM, disk SMART, thermals. No network or security checks. Fast triage for suspected hardware issues.",
  "category": "Diagnostic",
  "estimatedMinutes": 12,
  "steps": [
    {
      "id": "S01", "name": "Hardware Health Check", "engine": "PCHealth",
      "description": "Full hardware diagnostic: CPU, RAM, disk, thermals, drivers",
      "args": [],
      "gate": { "scoreBelow": 60, "action": "warn", "message": "Hardware critically degraded. Recommend immediate replacement or repair." },
      "continueOnFail": true, "interactive": false, "timeoutMinutes": 8
    },
    {
      "id": "S02", "name": "Disk Analysis", "engine": "DiskAnalysis",
      "description": "In-depth disk SMART analysis, space usage, duplicate detection",
      "args": [],
      "gate": { "scoreBelow": 60, "action": "warn", "message": "Disk health critical. Back up data immediately before any further work." },
      "continueOnFail": true, "interactive": false, "timeoutMinutes": 10
    },
    {
      "id": "S03", "name": "Hardware Audit Report", "engine": "IncidentReport",
      "description": "Generate hardware audit report",
      "args": ["-Category", "Hardware Audit"],
      "gate": null,
      "continueOnFail": true, "interactive": false, "timeoutMinutes": 5
    }
  ]
}
'@

'malware-remediation.json' = @'
{
  "id": "malware-remediation",
  "name": "Post-Incident Malware Remediation",
  "description": "Post-compromise recovery: network isolation check, deep security scan, aggressive hardening, identity re-verification, incident report with ZIP export.",
  "category": "Security",
  "estimatedMinutes": 35,
  "steps": [
    {
      "id": "S01", "name": "Network Isolation Verification", "engine": "NetRepair",
      "description": "Verify network state and check for suspicious connections",
      "args": [],
      "gate": null,
      "continueOnFail": true, "interactive": false, "timeoutMinutes": 8
    },
    {
      "id": "S02", "name": "Deep Security Scan", "engine": "SecurityScan",
      "description": "Comprehensive security scan: scheduled tasks, certificates, event log IOCs, SMB shares",
      "args": [],
      "gate": { "scoreBelow": 50, "action": "warn", "message": "Severe security compromise indicators detected. Consider re-imaging the machine." },
      "continueOnFail": true, "interactive": false, "timeoutMinutes": 12
    },
    {
      "id": "S03", "name": "Aggressive Security Hardening", "engine": "AutoFix",
      "description": "Apply all available security fixes -- select Moderate or All level",
      "args": [],
      "gate": null,
      "continueOnFail": true, "interactive": true, "timeoutMinutes": 15
    },
    {
      "id": "S04", "name": "Identity Integrity Check", "engine": "AzureADJoin",
      "description": "Verify Azure AD join status and Intune enrollment integrity",
      "args": [],
      "gate": null,
      "continueOnFail": true, "interactive": true, "timeoutMinutes": 15
    },
    {
      "id": "S05", "name": "Post-Remediation Security Scan", "engine": "SecurityScan",
      "description": "Re-scan to confirm remediation was effective",
      "args": [],
      "gate": { "scoreBelow": 75, "action": "warn", "message": "Security score still low post-remediation. Consider re-imaging." },
      "continueOnFail": true, "interactive": false, "timeoutMinutes": 12
    },
    {
      "id": "S06", "name": "Incident Report with Full Export", "engine": "IncidentReport",
      "description": "Generate post-incident report and export complete audit ZIP",
      "args": ["-Category", "Security Incident", "-ExportZip"],
      "gate": null,
      "continueOnFail": true, "interactive": false, "timeoutMinutes": 5
    }
  ]
}
'@

    }   # end $playbooks hashtable

    foreach ($fn in $playbooks.Keys) {
        $dest = Join-Path $Dir $fn
        if (-not (Test-Path $dest)) {
            try {
                $playbooks[$fn] | Set-Content -Path $dest -Encoding UTF8
            } catch {
                Write-Host "  [WARN] Could not write playbook $fn`: $_" -ForegroundColor Yellow
            }
        }
    }
}

# ==============================================================
# PLAYBOOK LOADER
# ==============================================================
function Import-Playbook {
    param([string]$FilePath)
    try {
        $raw = Get-Content $FilePath -Raw | ConvertFrom-Json
        return $raw
    } catch {
        Write-Host "  [ERROR] Could not parse playbook: $FilePath" -ForegroundColor Red
        Write-Host "  $_" -ForegroundColor Red
        return $null
    }
}

function Get-PlaybookList {
    param([string]$Dir)
    if (-not (Test-Path $Dir)) { return @() }
    return @(Get-ChildItem -Path $Dir -Filter '*.json' -ErrorAction SilentlyContinue)
}

# ==============================================================
# INTERACTIVE PLAYBOOK SELECTOR
# ==============================================================
function Select-Playbook {
    param([string]$Dir, [string]$PreferredName)

    $files = Get-PlaybookList $Dir
    if ($files.Count -eq 0) {
        Write-Host "  [ERROR] No playbooks found in $Dir" -ForegroundColor Red
        return $null
    }

    # If a name was passed, try to match
    if ($PreferredName) {
        foreach ($f in $files) {
            $base = [IO.Path]::GetFileNameWithoutExtension($f.Name)
            if ($base -eq $PreferredName -or $f.Name -eq $PreferredName) {
                return Import-Playbook $f.FullName
            }
        }
        # Try partial match
        foreach ($f in $files) {
            if ($f.Name -like "*$PreferredName*") {
                return Import-Playbook $f.FullName
            }
        }
        Write-Host "  [WARN] Playbook '$PreferredName' not found. Showing menu." -ForegroundColor Yellow
    }

    # Load playbook metadata for display
    $entries = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($f in $files) {
        try {
            $d = Get-Content $f.FullName -Raw | ConvertFrom-Json
            $null = $entries.Add([PSCustomObject]@{
                File        = $f.FullName
                Name        = if ($d.name)        { $d.name }        else { $f.BaseName }
                Description = if ($d.description) { $d.description } else { '-' }
                Category    = if ($d.category)    { $d.category }    else { '-' }
                Minutes     = if ($d.estimatedMinutes) { $d.estimatedMinutes } else { '?' }
                Steps       = if ($d.steps)       { @($d.steps).Count } else { 0 }
            })
        } catch { }
    }

    Write-Host ''
    Write-Host ('  ' + ('=' * ($W - 2))) -ForegroundColor Cyan
    Write-Host '  AVAILABLE PLAYBOOKS' -ForegroundColor White
    Write-Host ('  ' + ('=' * ($W - 2))) -ForegroundColor Cyan
    Write-Host ''

    $i = 1
    foreach ($e in $entries) {
        Write-Host "  [$i] $($e.Name)" -ForegroundColor Cyan
        Write-Host "      $($e.Description)" -ForegroundColor DarkGray
        Write-Host "      Category: $($e.Category)  |  Steps: $($e.Steps)  |  Est. $($e.Minutes) min" -ForegroundColor DarkGray
        Write-Host ''
        $i++
    }
    Write-Host "  [Q] Quit" -ForegroundColor DarkGray
    Write-Host ''

    $entriesArr = @($entries)
    while ($true) {
        Write-Host "  Select playbook [1-$($entriesArr.Count)] : " -ForegroundColor Yellow -NoNewline
        $sel = Read-Host
        if ($sel.Trim().ToUpper() -eq 'Q') { return $null }
        try {
            $idx = [int]$sel.Trim() - 1
            if ($idx -ge 0 -and $idx -lt $entriesArr.Count) {
                return Import-Playbook $entriesArr[$idx].File
            }
        } catch { }
        Write-Host "  Invalid selection. Try again." -ForegroundColor Red
    }
}

# ==============================================================
# HTML REPORT GENERATOR
# ==============================================================
function New-PlaybookReport {
    param($Playbook, $StepResults, $RunMeta)

    $genTime = $NOW.ToString('yyyy-MM-dd HH:mm:ss')
    $totalSteps  = @($StepResults).Count
    $passed  = @($StepResults | Where-Object { $_.Result -eq $SR_PASS }).Count
    $warned  = @($StepResults | Where-Object { $_.Result -eq $SR_WARN }).Count
    $failed  = @($StepResults | Where-Object { $_.Result -eq $SR_FAIL }).Count
    $skipped = @($StepResults | Where-Object { $_.Result -in @($SR_SKIP,$SR_HALT) }).Count

    $overallColor = if ($failed -gt 0 -or $skipped -gt 0) { '#ef4444' } `
                    elseif ($warned -gt 0) { '#eab308' } else { '#22c55e' }
    $overallText  = if ($failed -gt 0 -or $skipped -gt 0) { 'INCOMPLETE' } `
                    elseif ($warned -gt 0) { 'COMPLETED WITH WARNINGS' } else { 'COMPLETED' }

    $rowsHtml = ''
    $rowNum   = 0
    foreach ($sr in @($StepResults)) {
        $rowNum++
        $rc = switch ($sr.Result) {
            $SR_PASS { '#22c55e' } $SR_WARN { '#eab308' }
            $SR_FAIL { '#ef4444' } $SR_SKIP { '#64748b' }
            $SR_HALT { '#ef4444' } default  { '#94a3b8' }
        }
        $scoreText = if ($null -ne $sr.Score) { "$($sr.Score)%" } else { 'N/A' }
        $elapsed   = if ($sr.ElapsedSec -gt 0) { "$([math]::Round($sr.ElapsedSec / 60, 1)) min" } else { '-' }

        $rowsHtml += @"
<tr>
  <td style="color:#475569;width:28px">$rowNum</td>
  <td><strong style="color:#e2e8f0">$($sr.StepName)</strong></td>
  <td style="color:#94a3b8">$($sr.Engine)</td>
  <td><span style="background:$($rc)22;color:$rc;border:1px solid $rc;padding:2px 8px;border-radius:4px;font-size:11px;font-weight:bold">$($sr.Result)</span></td>
  <td style="color:#94a3b8">$scoreText</td>
  <td style="color:#64748b;font-size:11px">$elapsed</td>
  <td style="color:#64748b;font-size:12px">$($sr.Note)</td>
</tr>
"@
    }

    $dryNote = if ($DryRun) { "<div style='background:#eab30833;border:1px solid #eab308;color:#eab308;padding:12px 16px;border-radius:6px;margin-bottom:24px;font-size:13px'>DRY RUN -- No engines were executed. This is a preview of the playbook execution plan.</div>" } else { '' }

    $pbName     = if ($Playbook.name) { $Playbook.name } else { 'Unknown Playbook' }
    $pbDesc     = if ($Playbook.description) { $Playbook.description } else { '' }
    $pbCategory = if ($Playbook.category) { $Playbook.category } else { '-' }
    $incText    = if ($IncidentId) { $IncidentId } else { 'N/A' }
    $elapsed    = [math]::Round(($RunMeta.EndTime - $RunMeta.StartTime).TotalMinutes, 1)

    return @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Playbook Run -- $pbName -- $($NOW.ToString('yyyy-MM-dd'))</title>
<style>
* { box-sizing:border-box; margin:0; padding:0; }
body { background:#0f172a; color:#e2e8f0; font-family:'Consolas','Courier New',monospace; padding:24px; }
.header { text-align:center; padding:32px 0 24px; border-bottom:2px solid #38bdf8; margin-bottom:32px; }
.header h1 { font-size:20px; color:#38bdf8; letter-spacing:3px; }
.header h2 { font-size:16px; color:#e2e8f0; margin-top:8px; }
.header .meta { font-size:12px; color:#94a3b8; margin-top:10px; display:flex; justify-content:center; gap:16px; flex-wrap:wrap; }
.header .meta span { background:#1e293b; border:1px solid #334155; padding:3px 10px; border-radius:4px; }
.kpi-grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(140px,1fr)); gap:12px; margin-bottom:32px; }
.kpi { background:#1e293b; border:1px solid #334155; border-radius:8px; padding:14px; text-align:center; }
.kpi .v { font-size:26px; font-weight:bold; }
.kpi .l { font-size:10px; color:#94a3b8; margin-top:4px; text-transform:uppercase; letter-spacing:1px; }
.section-title { font-size:12px; color:#38bdf8; border-bottom:1px solid #334155; padding-bottom:7px; margin:28px 0 14px; letter-spacing:2px; text-transform:uppercase; }
table { width:100%; border-collapse:collapse; font-size:12px; }
th { background:#0f172a; color:#94a3b8; text-align:left; padding:9px 10px; font-size:10px; text-transform:uppercase; letter-spacing:1px; }
td { padding:9px 10px; border-top:1px solid #1e293b; vertical-align:middle; }
tr:hover td { background:rgba(56,189,248,0.04); }
.status-banner { text-align:center; padding:20px; border-radius:10px; margin-bottom:24px; font-size:18px; font-weight:bold; letter-spacing:2px; border:2px solid; }
.footer { text-align:center; color:#475569; font-size:11px; margin-top:40px; padding-top:16px; border-top:1px solid #1e293b; }
</style>
</head>
<body>

<div class="header">
  <div style="font-size:12px;color:#64748b;letter-spacing:2px">FIELDOPS PRO -- PLAYBOOK RUN REPORT</div>
  <h1>$pbName</h1>
  <h2>$pbDesc</h2>
  <div class="meta">
    <span>Technician: $techName</span>
    <span>Host: $HOSTNAME</span>
    <span>Category: $pbCategory</span>
    <span>Ticket: $incText</span>
    <span>Duration: $elapsed min</span>
    <span>Generated: $genTime</span>
  </div>
</div>

$dryNote

<div class="status-banner" style="background:$($overallColor)11;color:$overallColor;border-color:$overallColor">
  $overallText
</div>

<div class="kpi-grid">
  <div class="kpi"><div class="v" style="color:#38bdf8">$totalSteps</div><div class="l">Total Steps</div></div>
  <div class="kpi"><div class="v" style="color:#22c55e">$passed</div><div class="l">Passed</div></div>
  <div class="kpi"><div class="v" style="color:#eab308">$warned</div><div class="l">Warnings</div></div>
  <div class="kpi"><div class="v" style="color:#ef4444">$failed</div><div class="l">Failed</div></div>
  <div class="kpi"><div class="v" style="color:#64748b">$skipped</div><div class="l">Skipped</div></div>
  <div class="kpi"><div class="v" style="color:#94a3b8">$elapsed min</div><div class="l">Duration</div></div>
</div>

<div class="section-title">Step Results</div>
<div style="overflow-x:auto">
<table>
<thead><tr>
  <th>#</th>
  <th>Step</th>
  <th>Engine</th>
  <th>Result</th>
  <th>Score</th>
  <th>Duration</th>
  <th>Notes</th>
</tr></thead>
<tbody>$rowsHtml</tbody>
</table>
</div>

<div class="footer">
  FieldOps Pro Playbook Run v$VERSION | $genTime | $techName | $HOSTNAME
</div>
</body>
</html>
"@
}

# ==============================================================
# SAVE STEP RESULTS LOG (for resume support)
# ==============================================================
function Save-RunState {
    param($Playbook, $StepResults, [int]$LastStepIdx)
    try {
        $state = [PSCustomObject]@{
            PlaybookId   = $Playbook.id
            Hostname     = $HOSTNAME
            StartedAt    = $NOW.ToString('o')
            LastStepIdx  = $LastStepIdx
            StepResults  = $StepResults
        }
        $state | ConvertTo-Json -Depth 10 | Set-Content -Path $RUN_LOG -Encoding UTF8
    } catch { }
}

# ==============================================================
# MAIN EXECUTION
# ==============================================================

Write-Banner

# Ensure PLAYBOOKS dir exists and pre-built playbooks are written
Write-Host "  Initializing playbooks directory..." -ForegroundColor DarkGray
Write-DefaultPlaybooks $playbooksDir
Write-Host "  Playbooks dir: $playbooksDir" -ForegroundColor DarkGray

# Select playbook
$playbook = Select-Playbook $playbooksDir $Name
if ($null -eq $playbook) {
    Write-Host ''
    Write-Host "  No playbook selected. Exiting." -ForegroundColor Yellow
    exit 0
}

$pbName     = if ($playbook.name) { $playbook.name } else { 'Unknown Playbook' }
$pbSteps    = @($playbook.steps)
$totalSteps = $pbSteps.Count

if ($totalSteps -eq 0) {
    Write-Host "  [ERROR] Playbook has no steps defined." -ForegroundColor Red
    exit 1
}

# Display playbook summary
Write-Section "PLAYBOOK: $pbName"
Write-Host "  Description : $($playbook.description)" -ForegroundColor Gray
Write-Host "  Category    : $($playbook.category)" -ForegroundColor Gray
Write-Host "  Steps       : $totalSteps" -ForegroundColor Gray
Write-Host "  Est. time   : $($playbook.estimatedMinutes) minutes" -ForegroundColor Gray
if ($IncidentId) { Write-Host "  Ticket      : $IncidentId" -ForegroundColor Gray }
Write-Host ''
Write-Host "  Steps to execute:" -ForegroundColor DarkGray
$stepNum = 1
foreach ($s in $pbSteps) {
    $mode = if ($s.interactive) { '[INTERACTIVE]' } else { '[UNATTENDED] ' }
    Write-Host "  $stepNum. $mode $($s.name)  -> $($s.engine)" -ForegroundColor DarkGray
    $stepNum++
}
Write-Host ''

if ($DryRun) {
    Write-Host "  *** DRY RUN: No engines will be executed. ***" -ForegroundColor Yellow
    Write-Host ''
}

Write-Host "  Ready to begin. Press ENTER to start, [Q] to quit: " -ForegroundColor Cyan -NoNewline
$startConfirm = Read-Host
if ($startConfirm.Trim().ToUpper() -eq 'Q') {
    Write-Host "  Cancelled." -ForegroundColor Yellow
    exit 0
}

# Ensure dirs exist
foreach ($d in @($reportsDir, $historyDir, $logsDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# ==============================================================
# EXECUTION LOOP
# ==============================================================
$stepResults = [System.Collections.Generic.List[PSCustomObject]]::new()
$runStart    = Get-Date
$haltFired   = $false

$stepNum = 0
foreach ($step in $pbSteps) {
    $stepNum++

    $stepName   = if ($step.name)   { $step.name }   else { "Step $stepNum" }
    $engineKey  = if ($step.engine) { $step.engine }  else { '' }
    $stepArgs   = if ($step.args)   { @($step.args) } else { @() }
    $isInteractive = ($step.interactive -eq $true)
    $continueOnFail= ($step.continueOnFail -ne $false)
    $gate       = $step.gate
    $timeoutSec = if ($step.timeoutMinutes) { [int]$step.timeoutMinutes * 60 } else { 600 }

    # Resolve engine entry
    $engineEntry = $null
    if ($ENGINE_MAP.ContainsKey($engineKey)) { $engineEntry = $ENGINE_MAP[$engineKey] }

    # Resolve script path
    $scriptPath = $null
    if ($engineEntry) {
        $scriptPath = Join-Path $scriptsDir "Core\$($engineEntry.Script)"
        if (-not (Test-Path $scriptPath)) {
            # USB-wide fallback scan
            $found = @(Get-ChildItem -Path $usbRoot -Recurse -Filter $engineEntry.Script -ErrorAction SilentlyContinue |
                       Select-Object -First 1)
            if ($found.Count -gt 0) { $scriptPath = $found[0].FullName }
        }
    }

    Write-StepHeader $stepNum $totalSteps $stepName $engineKey $(if ($isInteractive) { 'INTERACTIVE' } else { 'UNATTENDED' })

    $stepStart = Get-Date
    $result    = $SR_FAIL
    $stepScore = $null
    $stepNote  = ''
    $success   = $false

    if ($DryRun) {
        # Dry run: just simulate
        Write-Host "  [DRY RUN] Would execute: $engineKey" -ForegroundColor DarkYellow
        if ($engineEntry) {
            Write-Host "  [DRY RUN] Script: $($engineEntry.Script)" -ForegroundColor DarkYellow
        }
        if ($gate) {
            Write-Host "  [DRY RUN] Gate: halt if score < $($gate.scoreBelow)" -ForegroundColor DarkYellow
        }
        $result  = $SR_SKIP
        $stepNote = 'Dry run - not executed'
        Start-Sleep -Milliseconds 300

    } elseif (-not $engineEntry) {
        Write-Host "  [ERROR] Unknown engine: '$engineKey'" -ForegroundColor Red
        $result   = $SR_FAIL
        $stepNote = "Unknown engine: $engineKey"

    } elseif (-not $scriptPath) {
        Write-Host "  [WARN] Engine script not found on USB: $($engineEntry.Script)" -ForegroundColor Yellow
        $result   = $SR_FAIL
        $stepNote = "Script not found: $($engineEntry.Script)"

    } elseif ($isInteractive) {
        # Interactive mode: launch in new window, wait for tech
        $success  = Invoke-Interactive $scriptPath $stepArgs $stepName
        $stepScore= Get-EngineScore $engineEntry.Pattern $stepStart
        $result   = if ($success) { $SR_PASS } else { $SR_WARN }
        $stepNote = 'Interactive -- technician confirmed completion'

    } else {
        # Unattended mode: stdin SKIP feeding
        Write-Host "  Executing engine (unattended)..." -ForegroundColor DarkGray
        $success  = Invoke-Unattended $scriptPath $stepArgs $timeoutSec
        $stepScore= Get-EngineScore $engineEntry.Pattern $stepStart
        $result   = if ($success) { $SR_PASS } else { $SR_WARN }
        $stepNote = if ($null -ne $stepScore) { "Score: $stepScore%" } else { 'Completed (score not captured)' }
    }

    # Gate evaluation
    if (-not $DryRun -and $null -ne $gate -and $null -ne $stepScore) {
        $gateResult = Test-Gate $gate $stepScore $NoGates
        if ($gateResult -eq 'halt') {
            $msg = if ($gate.message) { $gate.message } else { "Score $stepScore% below threshold $($gate.scoreBelow)%." }
            Write-GateAlert 'halt' $msg
            $result    = $SR_HALT
            $stepNote  = "GATE HALT: $msg"
            $haltFired = $true
        } elseif ($gateResult -eq 'warn') {
            $msg = if ($gate.message) { $gate.message } else { "Score $stepScore% below target $($gate.scoreBelow)%. Proceeding with warning." }
            Write-GateAlert 'warn' $msg
            if ($result -eq $SR_PASS) {
                $result   = $SR_WARN
                $stepNote = "Gate warn: $msg"
            }
        }
    } elseif (-not $DryRun -and $null -ne $gate -and $null -eq $stepScore) {
        Write-Host "  [INFO] Gate defined but score not captured -- skipping gate check." -ForegroundColor DarkGray
    }

    $elapsed = [math]::Round(((Get-Date) - $stepStart).TotalSeconds)

    $null = $stepResults.Add([PSCustomObject]@{
        StepId     = if ($step.id) { $step.id } else { "S$stepNum" }
        StepName   = $stepName
        Engine     = $engineKey
        Result     = $result
        Score      = $stepScore
        Note       = $stepNote
        ElapsedSec = $elapsed
    })

    Write-StepResult $result $stepNote
    Save-RunState $playbook @($stepResults) $stepNum

    # Handle halt
    if ($haltFired) {
        Write-Host "  Playbook halted at step $stepNum/$totalSteps due to gate failure." -ForegroundColor Red
        Write-Host "  Remaining steps skipped." -ForegroundColor DarkGray
        # Mark remaining steps as skipped
        for ($r = $stepNum; $r -lt $totalSteps; $r++) {
            $rs = $pbSteps[$r]
            $null = $stepResults.Add([PSCustomObject]@{
                StepId     = if ($rs.id) { $rs.id } else { "S$($r+1)" }
                StepName   = if ($rs.name) { $rs.name } else { "Step $($r+1)" }
                Engine     = if ($rs.engine) { $rs.engine } else { '-' }
                Result     = $SR_SKIP
                Score      = $null
                Note       = 'Skipped -- playbook halted at previous step'
                ElapsedSec = 0
            })
        }
        break
    }

    # If step failed and continueOnFail = false, ask tech
    if ($result -in @($SR_FAIL) -and -not $continueOnFail -and -not $DryRun) {
        Write-Host "  This step is marked as required. Continue anyway? " -ForegroundColor Red -NoNewline
        if (-not (Prompt-Continue)) {
            Write-Host "  Playbook aborted by technician at step $stepNum." -ForegroundColor Yellow
            break
        }
    }
}

$runEnd = Get-Date

# ==============================================================
# FINAL SUMMARY
# ==============================================================
Write-Host ''
Write-Host ('=' * $W) -ForegroundColor Cyan
Write-Host "  PLAYBOOK COMPLETE: $pbName" -ForegroundColor Green
Write-Host ('=' * $W) -ForegroundColor Cyan

$resultsArr = @($stepResults)
$passed  = @($resultsArr | Where-Object { $_.Result -eq $SR_PASS }).Count
$warned  = @($resultsArr | Where-Object { $_.Result -eq $SR_WARN }).Count
$failed  = @($resultsArr | Where-Object { $_.Result -eq $SR_FAIL }).Count
$halted  = @($resultsArr | Where-Object { $_.Result -eq $SR_HALT }).Count
$skipped = @($resultsArr | Where-Object { $_.Result -in @($SR_SKIP,$SR_HALT) }).Count
$elapsed = [math]::Round(($runEnd - $runStart).TotalMinutes, 1)

Write-Host "  Steps     : $($resultsArr.Count)" -ForegroundColor Gray
Write-Host "  Passed    : $passed" -ForegroundColor Green
Write-Host "  Warnings  : $warned" -ForegroundColor Yellow
Write-Host "  Failed    : $failed" -ForegroundColor Red
Write-Host "  Skipped   : $skipped" -ForegroundColor DarkGray
Write-Host "  Duration  : $elapsed minutes"
Write-Host ''

# Per-step result table
Write-Host "  STEP RESULTS:" -ForegroundColor DarkGray
$n = 0
foreach ($sr in $resultsArr) {
    $n++
    $col = switch ($sr.Result) {
        $SR_PASS { 'Green' } $SR_WARN { 'Yellow' }
        $SR_FAIL { 'Red'   } $SR_SKIP { 'DarkGray' }
        $SR_HALT { 'Red'   } default { 'Gray' }
    }
    $scoreStr = if ($null -ne $sr.Score) { "[$($sr.Score)%]" } else { '[N/A]' }
    Write-Host "  $n. [$($sr.Result)]  $($sr.StepName)  $scoreStr" -ForegroundColor $col
}
Write-Host ''

# Generate HTML report
$runMeta = [PSCustomObject]@{ StartTime=$runStart; EndTime=$runEnd }
$html    = New-PlaybookReport $playbook $resultsArr $runMeta
$html | Set-Content -Path $REPORT_PATH -Encoding UTF8
Write-Host "  Report    : $REPORT_PATH" -ForegroundColor Gray
Write-Host ('=' * $W) -ForegroundColor Cyan
Write-Host "  Start-Process ""$REPORT_PATH"""

if ($OpenReport) {
    Start-Process $REPORT_PATH
}
