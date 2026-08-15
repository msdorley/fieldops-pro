# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Ousman Dorley. See LICENSE at the repository root.
<#
.SYNOPSIS
    FieldOps Pro - AI-Powered Master Command Center v2.0
.DESCRIPTION
    Runs all diagnostic engines, performs cross-domain AI analysis
    (risk chain mapping, degradation prediction, root cause identification),
    generates prioritized remediation roadmap, natural language insights,
    and a professional mega-dashboard report.
.PARAMETER Engines
    Comma-separated engines. Default: ALL.
.PARAMETER IncidentId
    Ticket/incident ID for the report.
.PARAMETER Notes
    Technician notes.
.NOTES
    Author  : FieldOps Pro
    Version : 2.0
    Location: E:\SCRIPTS\Core\Invoke-FieldOps.ps1
#>

[CmdletBinding()]
param(
    [string]$Engines = 'ALL',
    [string]$IncidentId = '',
    [string]$Notes = ''
)

#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ============================================================
# PATH SETUP (two levels up: Core -> SCRIPTS -> E:\)
# ============================================================
$ScriptRoot  = $PSScriptRoot
$ProjectRoot = Split-Path (Split-Path $ScriptRoot -Parent) -Parent
$ReportsPath = Join-Path $ProjectRoot 'REPORTS'
$LogsPath    = Join-Path $ProjectRoot 'LOGS'
$ConfigPath  = Join-Path $ProjectRoot 'CONFIG'
$HistoryDir  = Join-Path $ReportsPath 'History'
@($ReportsPath, $LogsPath, $HistoryDir) | ForEach-Object {
    if (-not (Test-Path $_)) { New-Item $_ -ItemType Directory -Force | Out-Null }
}

# ============================================================
# TECHNICIAN IDENTITY
# ============================================================
$script:TechName = "$env:USERDOMAIN\$env:USERNAME"
$script:TechId   = ''
try {
    $techJson = Join-Path $ConfigPath 'technician.json'
    if (Test-Path $techJson) {
        $td = Get-Content $techJson -Raw | ConvertFrom-Json
        if ($td.Name) { $script:TechName = $td.Name }
        if ($td.EmployeeId) { $script:TechId = $td.EmployeeId }
    }
} catch {}

$Hostname  = $env:COMPUTERNAME
$Timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$DateHuman = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$IsAdmin   = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# ============================================================
# SESSION TRACKING
# ============================================================
$script:ActionLog     = [System.Collections.ArrayList]::new()
$script:EngineResults = [System.Collections.ArrayList]::new()
$script:MasterSW      = [System.Diagnostics.Stopwatch]::StartNew()

function Log-Action {
    param([string]$Action,[string]$Detail,[string]$Result='OK')
    $null = $script:ActionLog.Add([PSCustomObject]@{Time=(Get-Date -Format 'HH:mm:ss');Action=$Action;Detail=$Detail;Result=$Result})
}

Log-Action 'SESSION_START' "Master v2.0 | $Hostname | $script:TechName"

# ============================================================
# SYSTEM SNAPSHOT
# ============================================================
$script:SysSnap = @{Manufacturer='Unknown';Model='Unknown';Serial='Unknown';OS='Unknown';Build='';RAM='Unknown';CPU='Unknown';Cores='';Domain='';UserName=$env:USERNAME}
try {
    $os   = Get-CimInstance Win32_OperatingSystem -EA Stop
    $cs   = Get-CimInstance Win32_ComputerSystem -EA Stop
    $bios = Get-CimInstance Win32_BIOS -EA Stop
    $cpu  = Get-CimInstance Win32_Processor -EA Stop | Select-Object -First 1
    $script:SysSnap.Manufacturer = $cs.Manufacturer
    $script:SysSnap.Model        = $cs.Model
    $script:SysSnap.Serial       = $bios.SerialNumber
    $script:SysSnap.OS           = "$($os.Caption) ($($os.Version))"
    $script:SysSnap.Build        = $os.BuildNumber
    $script:SysSnap.RAM          = "$([math]::Round($cs.TotalPhysicalMemory / 1GB, 1)) GB"
    $script:SysSnap.CPU          = $cpu.Name
    $script:SysSnap.Cores        = "$($cpu.NumberOfCores)C/$($cpu.NumberOfLogicalProcessors)T"
    $script:SysSnap.Domain       = $cs.Domain
} catch {}

# ============================================================
# ENGINE DEFINITIONS
# ============================================================
$engineDefs = @(
    @{Name='PCHealth';     Path=(Join-Path $ProjectRoot 'SCRIPTS\Diagnostics\Invoke-PCHealth.ps1');     Weight=1.0; Domain='Hardware'; Color='#2196f3'}
    @{Name='DiskAnalysis'; Path=(Join-Path $ProjectRoot 'SCRIPTS\Diagnostics\Invoke-DiskAnalysis.ps1'); Weight=0.8; Domain='Storage';  Color='#ff9800'}
    @{Name='NetRepair';    Path=(Join-Path $ProjectRoot 'SCRIPTS\Network\Invoke-NetRepair.ps1');        Weight=1.2; Domain='Network';  Color='#4caf50'}
    @{Name='SecurityScan'; Path=(Join-Path $ProjectRoot 'SCRIPTS\Security\Invoke-SecurityScan.ps1');    Weight=1.5; Domain='Security'; Color='#9c27b0'}
    @{Name='AzureADJoin';  Path=(Join-Path $ProjectRoot 'SCRIPTS\Deployment\Invoke-AzureADJoin.ps1');  Weight=1.0; Domain='Identity'; Color='#00bcd4'}
)

$selectedNames = if ($Engines -eq 'ALL') { $engineDefs | ForEach-Object {$_.Name} }
                 else { $Engines -split ',' | ForEach-Object {$_.Trim()} }
$selectedEngines = @($engineDefs | Where-Object { $_.Name -in $selectedNames })

# ============================================================
# BANNER
# ============================================================
$bw = 64
Write-Host ''
Write-Host ('=' * $bw) -ForegroundColor White
Write-Host '  FIELDOPS PRO -- AI-POWERED MASTER COMMAND CENTER v2.0' -ForegroundColor White
Write-Host ('=' * $bw) -ForegroundColor White
Write-Host ''
Write-Host "  Technician : $script:TechName$(if($script:TechId){" | $script:TechId"})" -ForegroundColor Cyan
Write-Host "  Target     : $Hostname ($($script:SysSnap.Manufacturer) $($script:SysSnap.Model))" -ForegroundColor Cyan
Write-Host "  OS         : $($script:SysSnap.OS)" -ForegroundColor Gray
Write-Host "  CPU/RAM    : $($script:SysSnap.CPU) | $($script:SysSnap.RAM)" -ForegroundColor Gray
Write-Host "  Date       : $DateHuman | Admin: $IsAdmin" -ForegroundColor Gray
if ($IncidentId) { Write-Host "  Incident   : $IncidentId" -ForegroundColor Yellow }
if ($Notes)      { Write-Host "  Notes      : $Notes" -ForegroundColor DarkGray }
Write-Host "  Root       : $ProjectRoot" -ForegroundColor DarkGray
Write-Host "  Engines    : $($selectedNames -join ' + ')" -ForegroundColor DarkCyan
Write-Host ''

# ============================================================
# ENGINE RUNNER (feeds SKIP to stdin for menus)
# ============================================================
function Run-Engine {
    param($Def)

    if (-not (Test-Path $Def.Path)) {
        Write-Host "  [SKIP] $($Def.Name) -- not found at: $($Def.Path)" -ForegroundColor Yellow
        Log-Action 'ENGINE_SKIP' "$($Def.Name) not found: $($Def.Path)" 'SKIP'
        return $null
    }

    Write-Host ('-' * $bw) -ForegroundColor DarkGray
    Write-Host "  RUNNING: $($Def.Name) ($($Def.Domain))" -ForegroundColor DarkCyan
    Write-Host ('-' * $bw) -ForegroundColor DarkGray
    Write-Host ''
    Log-Action 'ENGINE_START' $Def.Name

    $result = [PSCustomObject]@{
        Name=$Def.Name; Domain=$Def.Domain; Weight=$Def.Weight; Color=$Def.Color
        Duration=0; Status='Running'; Output=''; ReportFile=''; Error=''
        Grade='N/A'; Pct=0; PassCount=0; WarnCount=0; FailCount=0; InfoCount=0; CheckCount=0
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        # Run engine as a child process with SKIP piped to stdin
        # This prevents Read-Host from hanging on interactive menus
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'powershell.exe'
        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$($Def.Path)`""
        $psi.RedirectStandardInput  = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow  = $true

        $proc = [System.Diagnostics.Process]::Start($psi)

        # Feed SKIP multiple times to handle any Read-Host prompts
        try {
            for ($i = 0; $i -lt 10; $i++) { $proc.StandardInput.WriteLine('SKIP') }
            $proc.StandardInput.Close()
        } catch {}

        # Read output with timeout (5 minutes max per engine)
        $outputTask = $proc.StandardOutput.ReadToEndAsync()
        $errorTask  = $proc.StandardError.ReadToEndAsync()
        $completed  = $proc.WaitForExit(300000)

        if (-not $completed) {
            try { $proc.Kill() } catch {}
            $result.Status = 'Timeout'
            $result.Error  = 'Engine exceeded 5 minute timeout'
            Log-Action 'ENGINE_TIMEOUT' $Def.Name 'FAIL'
        } else {
            $result.Output = $outputTask.Result
            $stderr = $errorTask.Result
            $result.Status = 'Completed'

            # Display key output lines to console
            $outputLines = @($result.Output -split "`n")
            foreach ($line in $outputLines) {
                $lt = $line.Trim()
                if ($lt -match '^\[(PASS|WARN|FAIL|INFO)\]' -or $lt -match '^\[Section' -or $lt -match 'Grade:' -or $lt -match 'COMPLETE' -or $lt -match 'Report:' -or $lt -match '^\[[\d]+/[\d]+\]') {
                    $lineColor = if ($lt -match 'FAIL|CRITICAL') {'Red'} elseif ($lt -match 'WARN') {'Yellow'} elseif ($lt -match 'PASS|OK|COMPLETE') {'Green'} else {'Gray'}
                    Write-Host "  $lt" -ForegroundColor $lineColor
                }
            }
        }

        # Parse grade from output
        if ($result.Output -match 'Grade:\s*([A-F][+-]?)\s*\((\d+)%\)') {
            $result.Grade = $Matches[1]; $result.Pct = [int]$Matches[2]
        } elseif ($result.Output -match 'PASS:\s*(\d+)\s*WARNING:\s*(\d+)\s*CRITICAL:\s*(\d+)') {
            $p=[int]$Matches[1]; $w=[int]$Matches[2]; $c=[int]$Matches[3]
            $t=$p+$w+$c; $result.Pct = if($t -gt 0){[math]::Round((($p+($w*0.5))/$t)*100,0)}else{0}
        }

        # Parse pass/warn/fail/info counts
        if ($result.Output -match 'Pass:\s*(\d+)\s*\|\s*Warn:\s*(\d+)\s*\|\s*Fail:\s*(\d+)\s*\|\s*Info:\s*(\d+)') {
            $result.PassCount=[int]$Matches[1]; $result.WarnCount=[int]$Matches[2]
            $result.FailCount=[int]$Matches[3]; $result.InfoCount=[int]$Matches[4]
            $result.CheckCount=$result.PassCount+$result.WarnCount+$result.FailCount+$result.InfoCount
        } elseif ($result.Output -match '(\d+)\s*checks\s*in') {
            $result.CheckCount = [int]$Matches[1]
        }

        # Find generated report file
        $rptSearch = Get-ChildItem $ReportsPath -Filter '*.html' -EA SilentlyContinue |
            Where-Object { $_.Name -notmatch 'Master' -and $_.LastWriteTime -gt (Get-Date).AddMinutes(-5) } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($rptSearch) { $result.ReportFile = $rptSearch.FullName }

        Log-Action 'ENGINE_DONE' "$($Def.Name): $($result.Grade) ($($result.Pct)%) in $([math]::Round($sw.Elapsed.TotalSeconds,1))s"

    } catch {
        $result.Status = 'Failed'
        $result.Error = $_.Exception.Message
        Log-Action 'ENGINE_FAIL' "$($Def.Name): $($_.Exception.Message)" 'FAIL'
    }

    $sw.Stop()
    $result.Duration = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    Write-Host ''
    $sc = if ($result.Status -eq 'Completed') {'Green'} else {'Red'}
    Write-Host "  >> $($Def.Name): $($result.Status) | $($result.Grade) ($($result.Pct)%) | $($result.Duration)s" -ForegroundColor $sc
    Write-Host ''

    return $result
}

# ============================================================
# EXECUTE ENGINES
# ============================================================
$ei = 0
foreach ($eng in $selectedEngines) {
    $ei++
    Write-Host "  [$ei/$($selectedEngines.Count)] $($eng.Name)" -ForegroundColor Gray
    $r = Run-Engine -Def $eng
    if ($r) { $null = $script:EngineResults.Add($r) }
}

# ============================================================
# AI ANALYSIS ENGINE
# ============================================================
Write-Host ''
Write-Host ('=' * $bw) -ForegroundColor Magenta
Write-Host '  AI ANALYSIS ENGINE - Cross-Domain Intelligence' -ForegroundColor Magenta
Write-Host ('=' * $bw) -ForegroundColor Magenta
Write-Host ''

# --- Extract 26 risk indicators from engine outputs ---
$ind = @{}
$indNames = @('DiskLow','TempBloat','DefenderOff','FirewallOff','NoEncrypt','HighLatency','PacketLoss',
    'NoVPN','NotJoined','StalePatches','WeakWiFi','SMBv1','CredRisk','NoASR','PublicNet',
    'RDPOpen','AutoLogon','GuestOn','UACOff','PS2','NoScriptLog','HighPorts','SuspProcs','BadDrivers','BatLow','HighTemp')
foreach ($n in $indNames) { $ind[$n] = $false }

$allOutput = ($script:EngineResults | ForEach-Object { $_.Output }) -join "`n"
if ($allOutput) {
    if ($allOutput -match '\[WARN\].*\d+\.\d+ GB free.*\d+%')                     { $ind.DiskLow     = $true }
    if ($allOutput -match 'Temp.*Bloat.*[2-9]\.\d+ GB')                             { $ind.TempBloat   = $true }
    if ($allOutput -match 'Real-Time Protection.*DISABLED')                         { $ind.DefenderOff = $true }
    if ($allOutput -match 'Firewall.*DISABLED')                                     { $ind.FirewallOff = $true }
    if ($allOutput -match 'NOT encrypted.*OperatingSystem')                         { $ind.NoEncrypt   = $true }
    if ($allOutput -match 'SMBv1.*ENABLED')                                         { $ind.SMBv1       = $true }
    if ($allOutput -match 'LSA Protection.*Disabled|Credential Guard.*Not running') { $ind.CredRisk    = $true }
    if ($allOutput -match '1[0-5] of 15 ASR|ASR rules not configured')             { $ind.NoASR       = $true }
    if ($allOutput -match 'Guest.*ENABLED')                                         { $ind.GuestOn     = $true }
    if ($allOutput -match 'Auto.*[Ll]ogon.*ENABLED')                                { $ind.AutoLogon   = $true }
    if ($allOutput -match 'UAC.*without prompting')                                 { $ind.UACOff      = $true }
    if ($allOutput -match 'PowerShell v2.*INSTALLED|Downgrade.*possible')           { $ind.PS2         = $true }
    if ($allOutput -match 'Script Block Logging.*Not configured')                   { $ind.NoScriptLog = $true }
    if ($allOutput -match 'RDP.*Enabled')                                           { $ind.RDPOpen     = $true }
    if ($allOutput -match '([4-9]\d|[1-9]\d{2,}) port.*exposed')                   { $ind.HighPorts   = $true }
    if ($allOutput -match 'Suspicious Processes.*[1-9]')                            { $ind.SuspProcs   = $true }
    if ($allOutput -match 'Avg:.*[5-9]\d\dms|Avg:.*\d{4,}ms')                      { $ind.HighLatency = $true }
    if ($allOutput -match 'Loss:.*[1-9]\d%|Loss: 100%')                            { $ind.PacketLoss  = $true }
    if ($allOutput -match 'GlobalProtect.*Disabled|VPN.*not connected')             { $ind.NoVPN       = $true }
    if ($allOutput -match 'Signal.*[0-2]\d%')                                       { $ind.WeakWiFi    = $true }
    if ($allOutput -match 'Public.*IPv4|Public.*Internet')                           { $ind.PublicNet   = $true }
    if ($allOutput -match 'Not joined|Workplace Joined')                            { $ind.NotJoined   = $true }
    if ($allOutput -match 'Last.*Update.*[6-9]\d day|Last.*Update.*\d{3,} day')    { $ind.StalePatches= $true }
    if ($allOutput -match 'Battery.*[0-3]\d%.*capacity|Battery.*replacement')       { $ind.BatLow      = $true }
    if ($allOutput -match 'Temperature.*[7-9]\d C')                                 { $ind.HighTemp    = $true }
    if ($allOutput -match '19\.\d y.*old|[2-9]\d\.\d y.*old')                      { $ind.BadDrivers  = $true }
}

# --- Risk Chain Analysis (8 scenarios) ---
$script:RiskChains = [System.Collections.ArrayList]::new()

$chainDefs = @(
    @{ Name='Ransomware Exposure';     Conds=@('NoASR','NoEncrypt','DefenderOff'); Min=2; Sev='Critical'
       Root='Missing endpoint protection stack'; Impact='Complete data loss, file encryption, lateral spread'
       Fix='1) Enable Defender RT. 2) Enable ASR ransomware rule. 3) Enable BitLocker.'; Time=10; Domains='Security, Encryption' }
    @{ Name='Lateral Movement';        Conds=@('SMBv1','CredRisk','StalePatches'); Min=2; Sev='Critical'
       Root='Legacy protocol + unprotected credentials + missing patches'; Impact='Network-wide compromise via EternalBlue/WannaCry path'
       Fix='Disable SMBv1 immediately. Enable LSA PPL. Apply all Windows Updates.'; Time=15; Domains='Security, Patching' }
    @{ Name='Physical Theft Exposure'; Conds=@('NoEncrypt','AutoLogon','GuestOn'); Min=2; Sev='Critical'
       Root='No data-at-rest protection + authentication bypass'; Impact='Full data breach, GDPR non-compliance, identity theft'
       Fix='Enable BitLocker. Disable auto-logon. Disable Guest account.'; Time=15; Domains='Encryption, Identity' }
    @{ Name='Network Interception';    Conds=@('PublicNet','NoVPN','CredRisk','WeakWiFi'); Min=2; Sev='High'
       Root='Untrusted network + no tunnel + weak credential protection'; Impact='Credential theft, session hijacking'
       Fix='Connect VPN on untrusted networks. Enable LSA PPL.'; Time=5; Domains='Network, Security' }
    @{ Name='Compliance Failure';      Conds=@('NotJoined','NoEncrypt','StalePatches','FirewallOff'); Min=2; Sev='High'
       Root='Device not under management'; Impact='Blocked from corporate resources via Conditional Access'
       Fix='Azure AD Join. Enable BitLocker. Apply updates. Enable firewall.'; Time=30; Domains='Identity, Security' }
    @{ Name='Stealth Persistence';     Conds=@('NoScriptLog','PS2','NoASR','UACOff'); Min=2; Sev='High'
       Root='Missing detection and prevention controls'; Impact='Undetectable malware persistence, no forensic trail'
       Fix='Enable Script Block Logging. Remove PS v2. Enable ASR. Fix UAC.'; Time=10; Domains='Security, PowerShell' }
    @{ Name='Performance Degradation'; Conds=@('DiskLow','TempBloat','HighTemp','BadDrivers','HighLatency'); Min=2; Sev='Medium'
       Root='Accumulated maintenance debt'; Impact='Slow apps, long boot, potential hardware failure'
       Fix='Clean temp files. Free disk space. Update drivers. Check cooling.'; Time=15; Domains='Hardware, Storage' }
    @{ Name='Connectivity Fragility';  Conds=@('WeakWiFi','HighLatency','PacketLoss','PublicNet'); Min=2; Sev='Medium'
       Root='Poor WiFi signal quality'; Impact='App timeouts, VPN drops, Teams call issues'
       Fix='Move closer to AP. Switch to 5GHz. Consider Ethernet.'; Time=5; Domains='Network, WiFi' }
)

foreach ($ch in $chainDefs) {
    $matched = @($ch.Conds | Where-Object { $ind.ContainsKey($_) -and $ind[$_] })
    if ($matched.Count -ge $ch.Min) {
        $conf = [math]::Round(($matched.Count / $ch.Conds.Count) * 100, 0)
        $null = $script:RiskChains.Add([PSCustomObject]@{
            Name=$ch.Name; Severity=$ch.Sev; Confidence=$conf
            RootCause=$ch.Root; Impact=$ch.Impact; Remediation=$ch.Fix
            Domains=$ch.Domains; FixTime=$ch.Time
            Matched=($matched -join ', '); MatchCount=$matched.Count; Total=$ch.Conds.Count
        })
        $sc2 = switch($ch.Sev){'Critical'{'Red'}'High'{'Yellow'}default{'DarkYellow'}}
        Write-Host "  [CHAIN] $($ch.Sev.ToUpper()): $($ch.Name) ($($matched.Count)/$($ch.Conds.Count), ${conf}% confidence)" -ForegroundColor $sc2
    }
}

if ($script:RiskChains.Count -eq 0) {
    Write-Host '  No risk chains detected. System is well-defended.' -ForegroundColor Green
}

# --- Roadmap (priority = impact * confidence / effort) ---
Write-Host ''
Write-Host '  Building remediation roadmap...' -ForegroundColor Gray

$script:Roadmap = [System.Collections.ArrayList]::new()
foreach ($rc in $script:RiskChains) {
    $impScore = switch($rc.Severity){'Critical'{10}'High'{7}'Medium'{4}default{2}}
    $pri = [math]::Round(($impScore * $rc.Confidence) / [math]::Max($rc.FixTime, 1), 1)
    $null = $script:Roadmap.Add([PSCustomObject]@{
        Name=$rc.Name; Priority=$pri; Severity=$rc.Severity; FixTime=$rc.FixTime
        Confidence=$rc.Confidence; Remediation=$rc.Remediation; Domains=$rc.Domains
        QuickWin=($rc.FixTime -le 10)
    })
}
$script:Roadmap = [System.Collections.ArrayList]@($script:Roadmap | Sort-Object Priority -Descending)

$quickWins = @($script:Roadmap | Where-Object {$_.QuickWin})
if ($quickWins.Count -gt 0) {
    Write-Host "  QUICK WINS ($($quickWins.Count)):" -ForegroundColor Green
    foreach ($qw in $quickWins) { Write-Host "    - $($qw.Name): $($qw.Remediation)" -ForegroundColor White }
}

# --- Health Prediction ---
$activeInds = @($ind.GetEnumerator() | Where-Object {$_.Value -eq $true})
$healthTrend = if ($activeInds.Count -le 3){'STABLE'} elseif($activeInds.Count -le 7){'DEGRADING'} elseif($activeInds.Count -le 12){'AT RISK'} else {'CRITICAL'}
$trendColor  = if ($activeInds.Count -le 3){'#4caf50'} elseif($activeInds.Count -le 7){'#ff9800'} elseif($activeInds.Count -le 12){'#ff5722'} else {'#f44336'}
Write-Host ''
Write-Host "  Health: $healthTrend ($($activeInds.Count) indicators)" -ForegroundColor $(if($activeInds.Count -le 3){'Green'}else{'Yellow'})

# ============================================================
# UNIFIED SCORING (with null guards)
# ============================================================
$completedEngines = @($script:EngineResults | Where-Object { $_.Status -eq 'Completed' -and $_.Pct -gt 0 })
$weightedSum = 0; $weightTotal = 0
if ($completedEngines.Count -gt 0) {
    foreach ($er in $completedEngines) {
        $weightedSum += $er.Pct * $er.Weight
        $weightTotal += 100 * $er.Weight
    }
}
$unifiedPct = if ($weightTotal -gt 0) {[math]::Round(($weightedSum / $weightTotal) * 100, 0)} else {0}

# Chain penalty (with @() null guards)
$critChainCount = @($script:RiskChains | Where-Object {$_.Severity -eq 'Critical'}).Count
$highChainCount = @($script:RiskChains | Where-Object {$_.Severity -eq 'High'}).Count
$chainPenalty = ($critChainCount * 5) + ($highChainCount * 2)
$adjustedPct = [math]::Max($unifiedPct - $chainPenalty, 0)

$unifiedGrade = if($adjustedPct -ge 95){'A+'} elseif($adjustedPct -ge 90){'A'} elseif($adjustedPct -ge 85){'A-'} elseif($adjustedPct -ge 80){'B+'} elseif($adjustedPct -ge 75){'B'} elseif($adjustedPct -ge 70){'C+'} elseif($adjustedPct -ge 65){'C'} elseif($adjustedPct -ge 60){'D'} else {'F'}
$unifiedColor = if($adjustedPct -ge 80){'#4caf50'} elseif($adjustedPct -ge 60){'#ff9800'} else {'#f44336'}

$riskLevel = if($critChainCount -ge 2){'CRITICAL'} elseif($critChainCount -ge 1){'HIGH'} elseif($highChainCount -ge 2){'MEDIUM'} elseif($highChainCount -ge 1){'LOW'} else {'MINIMAL'}
$riskColor = switch($riskLevel){'CRITICAL'{'#f44336'}'HIGH'{'#ff5722'}'MEDIUM'{'#ff9800'}'LOW'{'#ffca28'}default{'#4caf50'}}

# Totals (with null guards)
$totalChecks = 0; $totalPass = 0; $totalWarn = 0; $totalFail = 0
if ($completedEngines.Count -gt 0) {
    $totalChecks = ($completedEngines | ForEach-Object {$_.CheckCount} | Measure-Object -Sum).Sum
    $totalPass   = ($completedEngines | ForEach-Object {$_.PassCount}  | Measure-Object -Sum).Sum
    $totalWarn   = ($completedEngines | ForEach-Object {$_.WarnCount}  | Measure-Object -Sum).Sum
    $totalFail   = ($completedEngines | ForEach-Object {$_.FailCount}  | Measure-Object -Sum).Sum
}

$script:MasterSW.Stop()
$totalElapsed = [math]::Round($script:MasterSW.Elapsed.TotalSeconds, 1)

# --- NL Insights ---
$nlInsights = [System.Collections.ArrayList]::new()
foreach ($er in $completedEngines) {
    $insight = switch ($er.Name) {
        'PCHealth'     { if($er.Pct -ge 90){"Hardware excellent."}elseif($er.Pct -ge 70){"Hardware OK, $($er.WarnCount) warning(s)."}else{"Hardware poor. $($er.FailCount) failure(s)."} }
        'DiskAnalysis' { if($er.Pct -ge 90){"Storage healthy."}elseif($er.Pct -ge 70){"Storage has minor issues.$(if($ind.TempBloat){' Cleanup recommended.'})"}else{"Storage at risk."} }
        'NetRepair'    { if($er.Pct -ge 90){"Network strong."}elseif($er.Pct -ge 70){"Network OK.$(if($ind.NoVPN){' VPN disconnected.'})"}else{"Network has problems."} }
        'SecurityScan' { if($er.Pct -ge 90){"Security strong."}elseif($er.Pct -ge 70){"Security needs work. $($er.WarnCount) gaps."}else{"Security weak. Harden urgently."} }
        'AzureADJoin'  { if($er.Pct -ge 90){"Enrollment ready."}elseif($er.Pct -ge 70){"Enrollment possible with prep."}else{"Enrollment blocked."} }
        default { "$($er.Name): $($er.Pct)%." }
    }
    $null = $nlInsights.Add([PSCustomObject]@{Engine=$er.Name;Domain=$er.Domain;Insight=$insight;Pct=$er.Pct;Color=$er.Color})
}

# --- Save History ---
$histEntry = @{Timestamp=$DateHuman;Hostname=$Hostname;Tech=$script:TechName;Grade=$unifiedGrade;Pct=$adjustedPct;Risk=$riskLevel;Chains=$script:RiskChains.Count;Indicators=$activeInds.Count;Checks=$totalChecks;Duration=$totalElapsed}
$histFile = Join-Path $HistoryDir "${Hostname}_${Timestamp}.json"
try { $histEntry | ConvertTo-Json -Depth 3 | Out-File $histFile -Encoding UTF8 -Force } catch {}

# Historical delta
$histDeltaHtml = ''
$prevFiles = @(Get-ChildItem $HistoryDir -Filter "${Hostname}_*.json" -EA SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -Skip 1 -First 1)
if ($prevFiles.Count -gt 0) {
    try {
        $prev = Get-Content $prevFiles[0].FullName -Raw | ConvertFrom-Json
        $delta = $adjustedPct - $prev.Pct
        $deltaStr = if($delta -gt 0){"+$delta%"}elseif($delta -lt 0){"$delta%"}else{'='}
        $dc = if($delta -gt 0){'#4caf50'}elseif($delta -lt 0){'#f44336'}else{'#888'}
        Write-Host "  History: $deltaStr vs $($prev.Timestamp)" -ForegroundColor $(if($delta -ge 0){'Green'}else{'Red'})
        $histDeltaHtml = "<div class='hbox'><span class='hbox-l'>vs $($prev.Timestamp)</span><span class='hbox-v' style='color:$dc'>$deltaStr</span><span class='hbox-d'>(was $($prev.Grade) $($prev.Pct)%)</span></div>"
    } catch {}
}

Log-Action 'DONE' "$unifiedGrade ($adjustedPct%) | Risk: $riskLevel | Chains: $($script:RiskChains.Count)"

# ============================================================
# CONSOLE SUMMARY
# ============================================================
Write-Host ''
Write-Host ('=' * $bw) -ForegroundColor White
Write-Host '  FIELDOPS PRO -- MASTER ASSESSMENT v2.0' -ForegroundColor White
Write-Host ('=' * $bw) -ForegroundColor White
Write-Host ''
Write-Host "  UNIFIED GRADE : $unifiedGrade ($adjustedPct%)$(if($chainPenalty -gt 0){" [raw ${unifiedPct}% - ${chainPenalty}pt penalty]"})" -ForegroundColor $(if($adjustedPct -ge 80){'Green'}elseif($adjustedPct -ge 60){'Yellow'}else{'Red'})
Write-Host "  RISK LEVEL    : $riskLevel ($($script:RiskChains.Count) chain(s))" -ForegroundColor $(if($riskLevel -eq 'MINIMAL'){'Green'}else{'Yellow'})
Write-Host "  HEALTH        : $healthTrend ($($activeInds.Count) indicators)" -ForegroundColor $(if($activeInds.Count -le 3){'Green'}else{'Yellow'})
Write-Host "  TOTAL         : $totalChecks checks | $($completedEngines.Count) engines | ${totalElapsed}s" -ForegroundColor Gray
Write-Host ''
foreach ($er in $completedEngines) {
    $gc = if($er.Pct -ge 80){'Green'}elseif($er.Pct -ge 60){'Yellow'}else{'Red'}
    $bar = ('#' * [math]::Max([math]::Round($er.Pct / 5, 0), 0)).PadRight(20, '-')
    Write-Host "  $($er.Name.PadRight(15)) [$bar] $($er.Pct)% ($($er.Grade))" -ForegroundColor $gc
}
Write-Host ''
foreach ($ni in $nlInsights) { Write-Host "  $($ni.Domain): $($ni.Insight)" -ForegroundColor DarkGray }
Write-Host ''

# ============================================================
# HTML REPORT
# ============================================================
Write-Host '  Generating Master Report...' -ForegroundColor Gray
$ReportFile = Join-Path $ReportsPath "FieldOps_Master_${Hostname}_${Timestamp}.html"

# Engine cards
$eCards = ''
foreach ($er in @($script:EngineResults | Where-Object {$_.Status -eq 'Completed'})) {
    $r2=36;$circ=[math]::Round(2*[math]::PI*$r2,2);$dash=[math]::Round(($er.Pct/100)*$circ,2)
    $ec2=if($er.Pct -ge 80){$er.Color}elseif($er.Pct -ge 60){'#ff9800'}else{'#f44336'}
    $rl=if($er.ReportFile -and (Test-Path $er.ReportFile)){$fn=Split-Path $er.ReportFile -Leaf;"<a href='$fn' class='rb2'>Open Report</a>"}else{''}
    $eCards+="<div class='ec'><svg viewBox='0 0 80 80' class='ecr'><circle cx='40' cy='40' r='$r2' fill='none' stroke='#151530' stroke-width='6'/><circle cx='40' cy='40' r='$r2' fill='none' stroke='$ec2' stroke-width='6' stroke-dasharray='$dash $circ' stroke-linecap='round' transform='rotate(-90 40 40)'/><text x='40' y='36' text-anchor='middle' fill='$ec2' font-size='13' font-weight='900'>$($er.Grade)</text><text x='40' y='50' text-anchor='middle' fill='#666' font-size='9'>$($er.Pct)%</text></svg><div class='eci'><div class='ecn'>$($er.Name)</div><div class='ecm'>$($er.Domain) | $($er.Duration)s | $($er.CheckCount) checks</div><div class='ecs'><span class='sp'>$($er.PassCount)P</span> <span class='sw'>$($er.WarnCount)W</span> <span class='sf'>$($er.FailCount)F</span></div>$rl</div></div>"
}

# Radar SVG
$radarSvg='';$rr=90;$rcx=100;$rcy=100;$pts=''
if($completedEngines.Count -gt 0){$step=360/$completedEngines.Count;$lines='';$lbls=''
for($i=0;$i -lt $completedEngines.Count;$i++){$ang=($i*$step - 90)*[math]::PI/180;$pct2=$completedEngines[$i].Pct/100
$x=[math]::Round($rcx+$rr*$pct2*[math]::Cos($ang),1);$y=[math]::Round($rcy+$rr*$pct2*[math]::Sin($ang),1);$pts+="$x,$y "
$gx=[math]::Round($rcx+$rr*[math]::Cos($ang),1);$gy=[math]::Round($rcy+$rr*[math]::Sin($ang),1)
$lx=[math]::Round($rcx+($rr+16)*[math]::Cos($ang),1);$ly=[math]::Round($rcy+($rr+16)*[math]::Sin($ang),1)
$lines+="<line x1='$rcx' y1='$rcy' x2='$gx' y2='$gy' stroke='#1a1a3a' stroke-width='1'/>"
$lbls+="<text x='$lx' y='$ly' text-anchor='middle' fill='$($completedEngines[$i].Color)' font-size='8' font-weight='700'>$($completedEngines[$i].Name)</text>"}
$radarSvg="<svg viewBox='0 0 200 200' style='width:200px;height:200px'><circle cx='$rcx' cy='$rcy' r='$rr' fill='none' stroke='#1a1a3a'/><circle cx='$rcx' cy='$rcy' r='$([math]::Round($rr*0.66))' fill='none' stroke='#1a1a30'/><circle cx='$rcx' cy='$rcy' r='$([math]::Round($rr*0.33))' fill='none' stroke='#1a1a28'/>$lines $lbls<polygon points='$pts' fill='${unifiedColor}20' stroke='$unifiedColor' stroke-width='2'/></svg>"}

# Chains
$chHtml='';if($script:RiskChains.Count -gt 0){foreach($rc in $script:RiskChains){$ccl=switch($rc.Severity){'Critical'{'cc'}'High'{'ch'}default{'cm'}}
$chHtml+="<div class='cx $ccl'><div class='cxh'><span class='cxs'>$($rc.Severity.ToUpper())</span> $($rc.Name) <span class='cxc'>$($rc.Confidence)%</span></div><div class='cxb'><b>Root:</b> $($rc.RootCause)<br/><b>Impact:</b> $($rc.Impact)<br/><b>Fix:</b> $($rc.Remediation)<br/><span class='cxm'>Domains: $($rc.Domains) | Factors: $($rc.Matched) ($($rc.MatchCount)/$($rc.Total)) | ~$($rc.FixTime)min</span></div></div>"
}}else{$chHtml="<div class='cx cg'><div class='cxh'>No risk chains - system well-defended</div></div>"}

# Roadmap
$rmHtml='';$ri=0;foreach($rm in $script:Roadmap){$ri++;$rc2=switch($rm.Severity){'Critical'{'#f44336'}'High'{'#ff9800'}default{'#ffca28'}};$qt=if($rm.QuickWin){"<span class='qw'>QUICK WIN</span>"}else{''}
$rmHtml+="<div class='rm'><div class='rmn' style='background:${rc2}15;color:$rc2;border-color:$rc2'>$ri</div><div class='rmb'><div class='rmt'>$($rm.Name) $qt</div><div class='rmd'>$($rm.Remediation)</div><div class='rmm'>Priority: $($rm.Priority) | ~$($rm.FixTime)min | $($rm.Domains)</div></div></div>"}

# Insights
$niHtml='';foreach($ni in $nlInsights){$nc=if($ni.Pct -ge 80){$ni.Color}elseif($ni.Pct -ge 60){'#ff9800'}else{'#f44336'};$niHtml+="<div class='ni'><span class='nid' style='color:$nc'>$($ni.Domain)</span><span class='nit'>$($ni.Insight)</span></div>"}

# Indicator grid
$igHtml='';foreach($iv in ($ind.GetEnumerator()|Sort-Object Value -Descending)){$ivc=if($iv.Value){'#f44336'}else{'#2e7d32'};$ivi=if($iv.Value){'&#9679;'}else{'&#9675;'}
$igHtml+="<span class='ic' style='color:$ivc'>$ivi $($iv.Key)</span>"}

# Action log
$alHtml='';foreach($al in $script:ActionLog){$arc=if($al.Result -eq 'OK'){'#4caf50'}else{'#f44336'};$alHtml+="<tr><td>$($al.Time)</td><td>$($al.Action)</td><td>$($al.Detail)</td><td style='color:$arc'>$($al.Result)</td></tr>"}

# System info
$siHtml='';foreach($sk in $script:SysSnap.Keys){$siHtml+="<tr><td class='sl'>$sk</td><td>$($script:SysSnap[$sk])</td></tr>"}

$Html = @"
<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>FieldOps Master | $Hostname</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}body{font-family:'Segoe UI',Tahoma,sans-serif;background:#040410;color:#c8cce0;padding:24px;line-height:1.5}.rc{max-width:1200px;margin:0 auto}
.hdr{background:linear-gradient(135deg,#080818,#101028,#080820);border-radius:16px;padding:32px 36px;margin-bottom:28px;border:1px solid #202050;position:relative;overflow:hidden}.hdr::before{content:'';position:absolute;top:0;left:0;right:0;height:4px;background:linear-gradient(90deg,#f44336,#ff9800,#4caf50,#2196f3,#9c27b0)}.ht{font-size:1.8em;font-weight:900;color:#e8e8f0}.hs{font-size:.88em;color:#6070a0;margin-top:4px}.hb{display:flex;flex-wrap:wrap;gap:20px;margin-top:18px;padding-top:14px;border-top:1px solid #202050}.hi{font-size:.8em}.hl{color:#4058a0;display:block;font-size:.82em}.hv{color:#a0b0d0;font-weight:700}
.mg{background:linear-gradient(135deg,#060612,#0c0c24);border-radius:16px;padding:28px 36px;margin-bottom:28px;border:1px solid #1a1a48;display:flex;align-items:center;gap:28px;flex-wrap:wrap}
.mgl{display:flex;align-items:center;gap:28px;flex:1;min-width:280px}.mgc{width:110px;height:110px;border-radius:50%;display:flex;align-items:center;justify-content:center;font-size:2.6em;font-weight:900;flex-shrink:0;border:6px solid}.mgd{flex:1}.mgs{font-size:1.3em;font-weight:800}
.rb{display:inline-block;padding:4px 14px;border-radius:20px;font-weight:800;font-size:.82em;margin-left:12px;letter-spacing:1px}
.mgt{width:100%;height:18px;background:#0a0a1a;border-radius:9px;overflow:hidden;margin:10px 0}.mgf{height:100%;border-radius:9px}
.mgst{display:flex;gap:16px;font-size:.82em;margin-top:6px;flex-wrap:wrap}.sp{color:#4caf50}.sw{color:#ff9800}.sf{color:#f44336}
.hbox{background:#0a0a1a;border:1px solid #1a1a40;border-radius:10px;padding:12px 18px;margin-bottom:24px;font-size:.85em;display:flex;align-items:center;gap:12px;flex-wrap:wrap}.hbox-l{color:#5060a0}.hbox-v{font-weight:800;font-size:1.2em}.hbox-d{color:#5060a0}
.trb{background:#0a0a1a;border:1px solid #1a1a40;border-radius:10px;padding:12px 18px;margin-bottom:24px}.trl{font-size:.8em;color:#5060a0}.trv{font-size:.95em;font-weight:700;margin-top:4px}
.ex{background:#060610;border:1px solid #181838;border-radius:12px;padding:18px 24px;margin-bottom:24px;font-size:.9em;color:#8898c0;line-height:1.7}.ext{font-weight:700;color:#b0b8d8;margin-bottom:6px}
.st{font-size:1.05em;font-weight:800;color:#b0b8d8;margin:24px 0 12px;padding-bottom:6px;border-bottom:1px solid #181838;display:flex;align-items:center;gap:8px}.st .bd{background:#181838;color:#5060a0;font-size:.68em;padding:2px 8px;border-radius:10px}
.eg{display:flex;flex-wrap:wrap;gap:14px;margin-bottom:24px}.ec{background:#080818;border:1px solid #181840;border-radius:12px;padding:16px;display:flex;align-items:center;gap:14px;flex:1;min-width:270px}.ecr{width:80px;height:80px;flex-shrink:0}.ecn{font-weight:700;color:#c0c8e0;font-size:.95em}.ecm{font-size:.73em;color:#5068a0;margin-top:2px}.ecs{font-size:.73em;margin-top:4px;display:flex;gap:8px}.eci{flex:1}
.rb2{display:inline-block;margin-top:6px;padding:3px 10px;background:#141440;color:#64b5f6;border:1px solid #2a2a60;border-radius:5px;font-size:.7em;text-decoration:none;font-weight:600}.rb2:hover{background:#1a1a50}
.ni{display:flex;gap:8px;margin-bottom:5px;font-size:.88em}.nid{font-weight:700;min-width:80px;flex-shrink:0}.nit{color:#8898b8}
.cx{border-radius:10px;padding:14px 18px;margin-bottom:12px;border-left:5px solid}.cc{background:#140808;border-color:#f44336}.ch{background:#141208;border-color:#ff9800}.cm{background:#141408;border-color:#ffca28}.cg{background:#081008;border-color:#4caf50}
.cxh{font-weight:700;font-size:.95em;display:flex;align-items:center;gap:8px;flex-wrap:wrap}.cxs{padding:2px 8px;border-radius:4px;font-size:.75em}.cc .cxs{background:#1a0808;color:#f44336}.ch .cxs{background:#1a1408;color:#ff9800}.cm .cxs{background:#1a1808;color:#ffca28}
.cxc{font-size:.75em;color:#6878a0;margin-left:auto}.cxb{margin-top:8px;font-size:.85em;color:#8898b0;line-height:1.6}.cxm{font-size:.78em;color:#5068a0;font-style:italic;margin-top:6px}
.rm{display:flex;gap:12px;margin-bottom:12px}.rmn{width:34px;height:34px;border-radius:50%;display:flex;align-items:center;justify-content:center;font-weight:900;font-size:.85em;border:2px solid;flex-shrink:0}.rmt{font-weight:700;font-size:.9em;color:#c0c8e0}.rmd{font-size:.82em;color:#8898b0;margin-top:2px}.rmm{font-size:.73em;color:#5068a0;margin-top:4px}
.qw{background:#1b5e20;color:#4caf50;padding:1px 6px;border-radius:4px;font-size:.72em;font-weight:600;margin-left:6px}
.ig{display:flex;flex-wrap:wrap;gap:5px;margin-bottom:16px}.ic{font-size:.72em;padding:3px 7px;background:#0a0a1a;border:1px solid #181838;border-radius:4px;font-weight:600}
table{width:100%;border-collapse:collapse;font-size:.78em}th{background:#080818;color:#7888c0;padding:8px 10px;text-align:left;font-weight:600;border-bottom:2px solid #181848}td{padding:6px 10px;border-bottom:1px solid #0c0c20}tr:hover{background:#0a0a1a}.sl{color:#4058a0;font-weight:600;width:110px}
details{background:#060612;border:1px solid #181838;border-radius:10px;margin-bottom:14px;overflow:hidden}summary{cursor:pointer;padding:12px 18px;font-weight:600;color:#7888b0;font-size:.9em;user-select:none;list-style:none;display:flex;align-items:center;gap:6px}summary:hover{background:#0a0a1a}summary::-webkit-details-marker{display:none}summary::before{content:'\\25B6';font-size:.6em;transition:transform .2s;display:inline-block;color:#4060a0}details[open] summary::before{transform:rotate(90deg)}details .sb{padding:14px 18px;overflow-x:auto}
.ft{text-align:center;padding:20px;color:#202040;font-size:.75em;border-top:1px solid #0c0c20;margin-top:28px}
@media print{body{background:#fff!important;color:#222!important;padding:8px}.hdr,.mg,.ex,details,.cx,.ec,.hbox,.trb{background:#f8f8fc!important;border-color:#ddd!important;color:#222!important;-webkit-print-color-adjust:exact;print-color-adjust:exact}.hdr::before{display:none!important}.rb2{display:none!important}th{background:#eef!important;color:#333!important}td{border-color:#ddd!important;color:#333!important}}
</style></head><body><div class="rc">
<div class="hdr"><div class="ht">FIELDOPS PRO -- AI-POWERED MASTER REPORT</div><div class="hs">Multi-engine cross-domain intelligence with risk chain analysis</div><div class="hb"><div class="hi"><span class="hl">Host</span><span class="hv">$Hostname</span></div><div class="hi"><span class="hl">Machine</span><span class="hv">$($script:SysSnap.Manufacturer) $($script:SysSnap.Model)</span></div><div class="hi"><span class="hl">Tech</span><span class="hv">$script:TechName</span></div><div class="hi"><span class="hl">Date</span><span class="hv">$DateHuman</span></div><div class="hi"><span class="hl">Duration</span><span class="hv">${totalElapsed}s</span></div><div class="hi"><span class="hl">Checks</span><span class="hv">$totalChecks</span></div><div class="hi"><span class="hl">Engines</span><span class="hv">$($completedEngines.Count)</span></div>$(if($IncidentId){"<div class='hi'><span class='hl'>Incident</span><span class='hv'>$IncidentId</span></div>"})</div></div>
<div class="mg"><div class="mgl"><div class="mgc" style="background:${unifiedColor}12;border-color:$unifiedColor;color:$unifiedColor">$unifiedGrade</div><div class="mgd"><div class="mgs">Unified: $adjustedPct%$(if($chainPenalty -gt 0){" <span style='font-size:.6em;color:#888'>(raw ${unifiedPct}% - ${chainPenalty}pt)</span>"}) <span class="rb" style="background:${riskColor}18;color:$riskColor;border:1px solid $riskColor">$riskLevel</span></div><div class="mgt"><div class="mgf" style="width:${adjustedPct}%;background:linear-gradient(90deg,$unifiedColor,${unifiedColor}55)"></div></div><div class="mgst"><span class="sp">$totalPass P</span><span class="sw">$totalWarn W</span><span class="sf">$totalFail F</span><span style="color:#9c27b0;font-weight:700">$($script:RiskChains.Count) chains</span><span style="color:$trendColor;font-weight:700">$($activeInds.Count) ind.</span></div></div></div><div>$radarSvg</div></div>
$histDeltaHtml
<div class="trb"><div class="trl">Health Prediction</div><div class="trv" style="color:$trendColor">$healthTrend ($($activeInds.Count) risk indicators active)</div></div>
<div class="ex"><div class="ext">Executive Summary</div>$Hostname ($($script:SysSnap.Manufacturer) $($script:SysSnap.Model)) assessed by $script:TechName on $DateHuman. $($completedEngines.Count) engines ran $totalChecks checks in ${totalElapsed}s. Grade: $unifiedGrade ($adjustedPct%). Risk: $riskLevel. $($script:RiskChains.Count) risk chain(s). $($activeInds.Count) indicators. $(if($quickWins.Count -gt 0){"$($quickWins.Count) quick win(s)."}) $(if($IncidentId){"Incident: $IncidentId."}) $(if($Notes){"Notes: $Notes"})</div>
<div class="st">Engine Results <span class="bd">$($completedEngines.Count)</span></div><div class="eg">$eCards</div>
<div class="st">AI Insights</div>$niHtml
$(if($script:RiskChains.Count -gt 0){"<div class='st'>Risk Chains <span class='bd'>$($script:RiskChains.Count)</span></div>$chHtml"})
$(if($script:Roadmap.Count -gt 0){"<div class='st'>Remediation Roadmap <span class='bd'>$($script:Roadmap.Count)</span></div>$rmHtml"})
<details><summary>Risk Indicators ($($activeInds.Count)/$($ind.Count) active)</summary><div class="sb"><div class="ig">$igHtml</div></div></details>
<details><summary>System Info</summary><div class="sb"><table>$siHtml</table></div></details>
<details><summary>Session Log ($($script:ActionLog.Count))</summary><div class="sb"><table><tr><th>Time</th><th>Action</th><th>Detail</th><th>Result</th></tr>$alHtml</table></div></details>
<div class="ft">FIELDOPS PRO v2.0 | $DateHuman | $totalChecks checks | $($completedEngines.Count) engines | ${totalElapsed}s | $Hostname | $script:TechName</div>
</div></body></html>
"@

$Html | Out-File -FilePath $ReportFile -Encoding UTF8 -Force
Write-Host ''
Write-Host "  Master Report: $ReportFile" -ForegroundColor Green
Write-Host "  Start-Process `"$ReportFile`"" -ForegroundColor Yellow
Write-Host ''

Log-Action 'SESSION_END' "Report: $ReportFile"
