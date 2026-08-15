#Requires -Version 5.1
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Ousman Dorley. See LICENSE at the repository root.
<#
.SYNOPSIS
    FieldOps Pro - Main Launcher v2.1 (Compact Pro layout)
.DESCRIPTION
    v2.1 layout improvements over v2.0:
      - Computed-padding grid (no hand-counted spaces) -> perfect alignment
      - 3-line header: logo / machine identity (with serial number) / live status
      - Two-column menu with 60+60 boundaries, every entry uniform width
      - Color-coded key brackets ([1] yellow, [N] magenta, [T] cyan, [Q] red)
      - Same visual language across all screens (banner / log viewer / quit menu)
      - Refreshable status bar (IP, RAM, time) between menu iterations
      - Constant W=122 -> change one value, all borders re-flow correctly

    Behavior is unchanged from v2.0:
      - Dynamic path resolution via $PSScriptRoot
      - -OutputRoot and -Language overrides
      - Dot-sources Core\FieldOps-Tools.ps1 for [T] menu
      - Dispatches [N] to Core\Invoke-AutoFixPlan.ps1 (AI plan-before-execute)

    Author : FieldOps Pro
    Version: 2.1
.PARAMETER OutputRoot
    Override the directory where REPORTS\ and LOGS\ are written.
.PARAMETER Language
    Override the auto-detected UI language ('en', 'fr').
.EXAMPLE
    PS> .\FieldOps-Launcher.ps1
.EXAMPLE
    PS> .\FieldOps-Launcher.ps1 -OutputRoot 'D:\Audits\Customer123' -Language fr
#>
[CmdletBinding()]
param(
    [string]$OutputRoot = '',
    [string]$Language   = ''
)

$ErrorActionPreference = 'Continue'

# ==============================================================================
# CONSTANTS -- change these and the whole UI re-flows
# ==============================================================================
$W       = 122          # Total inner width (between left and right border)
# MenuRow inner layout is: '  ' + Left(LCOL) + '  |  ' + Right(RCOL) + '  '
# So LCOL + RCOL must equal W - 9 = 113.
$LCOL    = 56           # Width of left menu column
$RCOL    = 57           # Width of right menu column (LCOL + RCOL = 113)
# Row2 same math.
# MenuRowWide inner layout is: '  ' + content(W-3) + '|' adjusted via PadRight to W-2.

# ==============================================================================
# PATH RESOLUTION
# ==============================================================================
$scriptsRoot = $PSScriptRoot
$usbRoot     = Split-Path -Parent $scriptsRoot
$coreDir     = Join-Path $scriptsRoot 'Core'
$configDir   = Join-Path $usbRoot     'CONFIG'

if ($OutputRoot -and $OutputRoot.Trim() -ne '') {
    $outRoot = $OutputRoot.TrimEnd('\','/')
} else {
    $outRoot = $usbRoot
}
$reportsDir  = Join-Path $outRoot 'REPORTS'
$logsDir     = Join-Path $outRoot 'LOGS'

foreach ($d in @($reportsDir, $logsDir)) {
    if (-not (Test-Path $d)) {
        New-Item -ItemType Directory -Path $d -Force -ErrorAction SilentlyContinue | Out-Null
    }
}

# ==============================================================================
# MODULE IMPORTS
# ==============================================================================
$_localeMod = Join-Path $coreDir 'FieldOps-Locale.psm1'
$_loggerMod = Join-Path $coreDir 'Logger.psm1'
$_utilsMod  = Join-Path $coreDir 'Utils.psm1'

$localeAvailable = $false
if (Test-Path $_localeMod) {
    try {
        Import-Module $_localeMod -Force -DisableNameChecking -ErrorAction Stop
        Initialize-Locale -Language $Language -ConfigDir $configDir
        $localeAvailable = $true
    } catch {
        Write-Warning "FieldOps-Locale.psm1 import failed: $_ -- falling back to English."
    }
}

if (Test-Path $_loggerMod) { Import-Module $_loggerMod -Force -DisableNameChecking -ErrorAction SilentlyContinue }
if (Test-Path $_utilsMod)  { Import-Module $_utilsMod  -Force -DisableNameChecking -ErrorAction SilentlyContinue }

# ==============================================================================
# LOCALE HELPER
# ==============================================================================
function L {
    param(
        [Parameter(Mandatory)] [string]$Key,
        [Parameter(Mandatory)] [string]$Default
    )
    if (-not $localeAvailable) { return $Default }
    try { return (Get-LocaleString $Key) } catch { return $Default }
}

# ==============================================================================
# CONSOLE SETUP
# ==============================================================================
# UTF-8 console encoding (Phase 5.2) -- enables accented French rendering
# without going through the OEM codepage (typically 850/1252 on Windows FR).
# Without this, "Systeme" with accents renders as mojibake on a fresh console.
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    [Console]::InputEncoding  = [System.Text.Encoding]::UTF8
} catch {}

$HOST.UI.RawUI.BackgroundColor = 'Black'
$HOST.UI.RawUI.ForegroundColor = 'White'
try { $HOST.UI.RawUI.WindowTitle = 'FIELDOPS PRO v2.1 - Enterprise Field IT Toolkit' } catch {}
try {
    $sz = $HOST.UI.RawUI.BufferSize; $sz.Width = ($W + 4); $HOST.UI.RawUI.BufferSize = $sz
    $wn = $HOST.UI.RawUI.WindowSize; $wn.Width = ($W + 4); $HOST.UI.RawUI.WindowSize = $wn
} catch {}

# ==============================================================================
# DRAWING PRIMITIVES -- compute-everything, hand-count-nothing
# ==============================================================================

# A horizontal rule of given width: '+----...----+' or with separator: '+----+----+'
function Hr {
    param([int]$Width = $W, [int[]]$SplitsAt = @())
    $line = '+' + ('-' * $Width) + '+'
    foreach ($s in ($SplitsAt | Sort-Object -Descending)) {
        if ($s -gt 0 -and $s -lt $Width) {
            $line = $line.Substring(0, $s + 1) + '+' + $line.Substring($s + 2)
        }
    }
    Write-Host "  $line" -ForegroundColor Cyan
}

# A bordered single-line row (no internal splits)
function Row {
    param(
        [string]$Content,
        [ConsoleColor]$Color = 'White',
        [int]$Width = $W
    )
    if ($Content.Length -gt $Width) {
        $Content = $Content.Substring(0, $Width - 1) + '~'
    }
    $padded = $Content.PadRight($Width)
    Write-Host '  |' -ForegroundColor Cyan -NoNewline
    Write-Host $padded -ForegroundColor $Color -NoNewline
    Write-Host '|' -ForegroundColor Cyan
}

# A bordered two-column row -- left column LCOL chars wide, right column RCOL chars wide
function Row2 {
    param(
        [string]$Left,
        [string]$Right,
        [int]$LeftWidth  = $LCOL,
        [int]$RightWidth = $RCOL
    )
    $totalInner = $LeftWidth + $RightWidth + 6  # 6 = ' ' + '|' + ' ' + ... padding chars
    if ($Left.Length  -gt $LeftWidth)  { $Left  = $Left.Substring(0, $LeftWidth - 1) + '~' }
    if ($Right.Length -gt $RightWidth) { $Right = $Right.Substring(0, $RightWidth - 1) + '~' }
    Write-Host '  |  ' -ForegroundColor Cyan -NoNewline
    Write-Host $Left.PadRight($LeftWidth) -NoNewline
    Write-Host '  |  ' -ForegroundColor Cyan -NoNewline
    Write-Host $Right.PadRight($RightWidth) -NoNewline
    Write-Host '  |' -ForegroundColor Cyan
}

# A bordered two-column row with COLORED key brackets (e.g. "[1]") at the start
function MenuRow {
    param(
        [string]$LeftKey,    [ConsoleColor]$LeftKeyColor    = 'Yellow', [string]$LeftLabel  = '',
        [string]$RightKey,   [ConsoleColor]$RightKeyColor   = 'Yellow', [string]$RightLabel = '',
        [int]$LeftWidth      = $LCOL,
        [int]$RightWidth     = $RCOL
    )
    # Build the segments
    $leftKeyStr  = if ($LeftKey)  { "[$LeftKey]" } else { '' }
    $rightKeyStr = if ($RightKey) { "[$RightKey]" } else { '' }

    # Compose: "[K] Label..." padded to width
    $leftFull  = if ($leftKeyStr)  { "$leftKeyStr $LeftLabel" }   else { $LeftLabel }
    $rightFull = if ($rightKeyStr) { "$rightKeyStr $RightLabel" } else { $RightLabel }

    # Truncation safety
    if ($leftFull.Length  -gt $LeftWidth)  { $leftFull  = $leftFull.Substring(0, $LeftWidth - 1) + '~' }
    if ($rightFull.Length -gt $RightWidth) { $rightFull = $rightFull.Substring(0, $RightWidth - 1) + '~' }

    Write-Host '  |  ' -ForegroundColor Cyan -NoNewline

    # Left key + label
    if ($leftKeyStr) {
        Write-Host $leftKeyStr -ForegroundColor $LeftKeyColor -NoNewline
        $rest = $leftFull.Substring($leftKeyStr.Length)
        Write-Host $rest.PadRight($LeftWidth - $leftKeyStr.Length) -NoNewline
    } else {
        Write-Host $leftFull.PadRight($LeftWidth) -NoNewline
    }

    Write-Host '  |  ' -ForegroundColor Cyan -NoNewline

    # Right key + label
    if ($rightKeyStr) {
        Write-Host $rightKeyStr -ForegroundColor $RightKeyColor -NoNewline
        $rest = $rightFull.Substring($rightKeyStr.Length)
        Write-Host $rest.PadRight($RightWidth - $rightKeyStr.Length) -NoNewline
    } else {
        Write-Host $rightFull.PadRight($RightWidth) -NoNewline
    }

    Write-Host '  |' -ForegroundColor Cyan
}

# A wide single-column menu row with colored key bracket
function MenuRowWide {
    param(
        [string]$Key,
        [ConsoleColor]$KeyColor = 'Yellow',
        [string]$Label,
        [int]$Width = $W
    )
    $keyStr = "[$Key]"
    $full   = "$keyStr $Label"
    if ($full.Length -gt $Width - 4) { $full = $full.Substring(0, $Width - 5) + '~' }

    Write-Host '  |  ' -ForegroundColor Cyan -NoNewline
    Write-Host $keyStr -ForegroundColor $KeyColor -NoNewline
    Write-Host (' ' + $Label).PadRight($Width - $keyStr.Length - 2) -NoNewline
    Write-Host '|' -ForegroundColor Cyan
}

# Blank padded line (for vertical breathing room inside a section)
function Blank {
    Write-Host ('  |' + (' ' * $W) + '|') -ForegroundColor Cyan
}

# Newline shortcut
function Nl { Write-Host '' }

# ==============================================================================
# MACHINE IDENTITY -- gathered ONCE per launcher start (these don't change)
# ==============================================================================
function Get-MachineIdentity {
    $id = @{
        Hostname = $env:COMPUTERNAME
        Serial   = '?'
        BiosVer  = '?'
        Model    = '?'
        Mfr      = '?'
        OsName   = '?'
        OsBuild  = '?'
    }
    try {
        $bios = Get-CimInstance Win32_BIOS -ErrorAction Stop
        $id.Serial  = $bios.SerialNumber
        $id.BiosVer = $bios.SMBIOSBIOSVersion
    } catch {}
    if ($id.Serial -eq '?' -or $id.Serial -match '^(System|To Be|Default|0+)$') {
        try {
            $encl = Get-CimInstance Win32_SystemEnclosure -ErrorAction Stop
            if ($encl.SerialNumber) { $id.Serial = $encl.SerialNumber }
        } catch {}
    }
    if ($id.Serial -eq '?' -or $id.Serial -match '^(System|To Be|Default|0+)$') {
        try {
            $bb = Get-CimInstance Win32_BaseBoard -ErrorAction Stop
            if ($bb.SerialNumber) { $id.Serial = $bb.SerialNumber }
        } catch {}
    }
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $id.Mfr   = $cs.Manufacturer
        $id.Model = $cs.Model
    } catch {}
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $id.OsName  = ($os.Caption -replace 'Microsoft ','').Trim()
        $id.OsBuild = $os.BuildNumber
    } catch {}
    return $id
}

# ==============================================================================
# LIVE STATUS -- gathered every redraw (these change)
# ==============================================================================
function Get-LiveStatus {
    $st = @{
        IP        = '?'
        FreeMem   = '?'
        Cpu       = '?'
        Aad       = '?'
        Time      = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    }
    try {
        $a = Get-CimInstance Win32_NetworkAdapterConfiguration -ErrorAction Stop |
             Where-Object { $_.IPEnabled } | Select-Object -First 1
        $ip = ($a.IPAddress | Select-Object -First 1)
        if ($ip) { $st.IP = $ip }
    } catch {}
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $st.FreeMem = "$([math]::Round($os.FreePhysicalMemory / 1MB, 1)) GB"
    } catch {}
    try {
        $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
        $st.Cpu = ($cpu.Name -replace '\s+',' ').Trim()
        if ($st.Cpu.Length -gt 36) { $st.Cpu = $st.Cpu.Substring(0, 36) + '~' }
    } catch {}
    try {
        $r = (& dsregcmd /status 2>$null) -join ' '
        $st.Aad = if     ($r -match 'AzureAdJoined\s*:\s*YES')   { (L 'launcher.bar.aad'       'Azure AD Joined') }
                  elseif ($r -match 'WorkplaceJoined\s*:\s*YES') { (L 'launcher.bar.wpj'       'Workplace Joined') }
                  else                                           { (L 'launcher.bar.workgroup' 'Workgroup') }
    } catch { $st.Aad = '?' }
    return $st
}

function Get-LogCount {
    if (Test-Path $logsDir) {
        @(Get-ChildItem $logsDir -Filter '*.json' -EA SilentlyContinue).Count
    } else { 0 }
}

# ==============================================================================
# HEADER RENDERER -- 3-line block (logo / identity / live status)
# ==============================================================================
function Draw-Header {
    param($id, $st)

    # --- Top rule
    Hr

    # --- Line 1: logo + version + role (centered-ish)
    $logoText = (L 'launcher.banner.title' 'FIELDOPS PRO  v2.1    ENTERPRISE FIELD IT TOOLKIT    EU DEPLOYMENT')
    Row $logoText 'Cyan'

    # --- Separator
    Hr

    # --- Line 2: machine identity (hostname, serial, model, BIOS, OS)
    $hostLabel = (L 'launcher.bar.host'   'HOST')
    $snLabel   = (L 'launcher.bar.serial' 'SERIAL')
    $modLabel  = (L 'launcher.bar.model'  'MODEL')
    $osLabel   = (L 'launcher.bar.os'     'OS')
    $biosLabel = (L 'launcher.bar.bios'   'BIOS')

    # First identity line: hostname + serial + bios
    Write-Host '  |  ' -ForegroundColor Cyan -NoNewline
    Write-Host ("$hostLabel ").PadRight(8)        -ForegroundColor DarkGray -NoNewline
    Write-Host $id.Hostname.PadRight(18)          -ForegroundColor Yellow   -NoNewline
    Write-Host ("$snLabel ").PadRight(10)         -ForegroundColor DarkGray -NoNewline
    Write-Host $id.Serial.PadRight(28)            -ForegroundColor White    -NoNewline
    Write-Host ("$biosLabel ").PadRight(8)        -ForegroundColor DarkGray -NoNewline
    $biosFmt = $id.BiosVer
    if ($biosFmt.Length -gt 12) { $biosFmt = $biosFmt.Substring(0, 12) }
    Write-Host $biosFmt                           -ForegroundColor White    -NoNewline
    # Pad to W
    $usedSoFar = 8 + 18 + 10 + 28 + 8 + $biosFmt.Length
    Write-Host (' ' * ($W - $usedSoFar))          -NoNewline
    Write-Host '|'                                -ForegroundColor Cyan

    # Second identity line: model + os
    Write-Host '  |  ' -ForegroundColor Cyan -NoNewline
    Write-Host ("$modLabel ").PadRight(8)         -ForegroundColor DarkGray -NoNewline
    $modelStr = "$($id.Mfr) $($id.Model)".Trim()
    if ($modelStr.Length -gt 48) { $modelStr = $modelStr.Substring(0, 48) }
    Write-Host $modelStr.PadRight(50)             -ForegroundColor White    -NoNewline
    Write-Host ("$osLabel ").PadRight(6)          -ForegroundColor DarkGray -NoNewline
    $osStr = "$($id.OsName) (build $($id.OsBuild))"
    if ($osStr.Length -gt 50) { $osStr = $osStr.Substring(0, 50) }
    Write-Host $osStr                             -ForegroundColor White    -NoNewline
    $usedSoFar = 8 + 50 + 6 + $osStr.Length
    Write-Host (' ' * ($W - $usedSoFar))          -NoNewline
    Write-Host '|'                                -ForegroundColor Cyan

    # --- Separator
    Hr

    # --- Line 3: live status (IP / RAM / CPU / status / time)
    $ipLab    = (L 'launcher.bar.ip'     'IP')
    $ramLab   = (L 'launcher.bar.ram'    'RAM')
    $cpuLab   = (L 'launcher.bar.cpu'    'CPU')
    $statLab  = (L 'launcher.bar.status' 'STATUS')
    $timeLab  = (L 'launcher.bar.time'   'TIME')

    Write-Host '  |  ' -ForegroundColor Cyan -NoNewline
    Write-Host ("$ipLab ").PadRight(4)            -ForegroundColor DarkGray -NoNewline
    Write-Host $st.IP.PadRight(18)                -ForegroundColor Cyan     -NoNewline
    Write-Host ("$ramLab ").PadRight(5)           -ForegroundColor DarkGray -NoNewline
    Write-Host $st.FreeMem.PadRight(12)           -ForegroundColor White    -NoNewline
    Write-Host ("$cpuLab ").PadRight(5)           -ForegroundColor DarkGray -NoNewline
    Write-Host $st.Cpu.PadRight(38)               -ForegroundColor White    -NoNewline
    Write-Host ("$statLab ").PadRight(8)          -ForegroundColor DarkGray -NoNewline
    $aadColor = if     ($st.Aad -match 'Azure|Joined') { 'Green' }
                elseif ($st.Aad -match 'Workplace')    { 'Yellow' }
                else                                   { 'Red' }
    # AAD field: 28 chars (covers French "Joint au lieu de travail" = 24 chars + headroom)
    Write-Host $st.Aad.PadRight(28)               -ForegroundColor $aadColor -NoNewline
    $usedSoFar = 4 + 18 + 5 + 12 + 5 + 38 + 8 + 28
    Write-Host (' ' * ($W - $usedSoFar))          -NoNewline
    Write-Host '|'                                -ForegroundColor Cyan

    # Second live line: just the time (small)
    Write-Host '  |  ' -ForegroundColor Cyan -NoNewline
    Write-Host ("$timeLab ").PadRight(6)          -ForegroundColor DarkGray -NoNewline
    Write-Host $st.Time                           -ForegroundColor DarkGray -NoNewline
    $usedSoFar = 6 + $st.Time.Length
    Write-Host (' ' * ($W - $usedSoFar))          -NoNewline
    Write-Host '|'                                -ForegroundColor Cyan

    Hr
}

# ==============================================================================
# MENU RENDERER
# ==============================================================================
function Draw-Menu {
    Nl

    # Section headers
    # Section headers indented 4 chars so they align with menu item labels (which start after "[K] " prefix)
    Row2 ('    ' + (L 'launcher.col.diag'   'DIAGNOSTIC & ANALYSIS')) ('    ' + (L 'launcher.col.deploy' 'DEPLOYMENT & REPORTING'))

    Hr

    # Menu rows 1-4 vs 5-8 -- two columns, perfectly aligned via MenuRow
    MenuRow '1' Yellow (L 'launcher.menu.pchealth'   'PC Health Diagnostic')           '5' Yellow (L 'launcher.menu.softdeploy' 'Software Deployment')
    MenuRow '2' Yellow (L 'launcher.menu.network'    'Network Repair & Testing')       '6' Yellow (L 'launcher.menu.aadjoin'    'Azure AD Join Workflow')
    MenuRow '3' Yellow (L 'launcher.menu.security'   'Security Scan')                  '7' Yellow (L 'launcher.menu.vpn'        'GlobalProtect VPN Setup')
    MenuRow '4' Yellow (L 'launcher.menu.disk'       'Disk Analysis & SMART Health')   '8' Yellow (L 'launcher.menu.incident'   'Incident Report (HTML)')

    Hr

    # Wide row for the larger features
    MenuRowWide '9' Yellow   (L 'launcher.menu.compliance' 'Compliance Snapshot & Diff (16 categories, MITRE ATT&CK mappings, GZip)')
    MenuRowWide 'D' Yellow   (L 'launcher.menu.dashboard'  'Build HTML Dashboard (single-file report from latest snapshots)')
    MenuRowWide 'F' Yellow   (L 'launcher.menu.fleet'      'Fleet Report (multi-host rollup of last 90 days)')
    MenuRowWide 'P' Yellow   (L 'launcher.menu.playbook'   'Run Playbook (hardware-audit, security-hardening, etc.)')
    MenuRowWide 'A' Yellow   (L 'launcher.menu.autofix'    'AutoFix (guided remediation)')
    MenuRowWide 'N' Magenta  (L 'launcher.menu.autofixplan' 'AutoFix Plan-Before-Execute (AI risk analysis per fix, full audit trail)')

    Hr

    # Bottom row: tools, logs, quit
    $logCount = Get-LogCount
    $logsLabel = (L 'launcher.menu.logs' 'View Session Logs') + "  ($logCount " + (L 'launcher.menu.logsuffix' 'log files on USB') + ')'
    MenuRowWide 'T' Cyan     (L 'launcher.menu.tools' 'Portable Tools Menu  [ HWiNFO64 | CrystalDiskInfo | Nmap | Wireshark | Sysinternals | NirSoft ]')
    MenuRowWide 'L' DarkCyan $logsLabel
    MenuRowWide 'Q' Red      (L 'launcher.menu.quit' 'Quit / Reboot / Shutdown')

    Hr
    Nl

    Write-Host ('  ' + (L 'launcher.prompt.option' 'Enter option') + ': ') -ForegroundColor DarkGray -NoNewline
}

# ==============================================================================
# MAIN SCREEN
# ==============================================================================
function Draw-Screen {
    param($id, $st)
    Clear-Host
    Nl
    Draw-Header -id $id -st $st
    Draw-Menu
}

# ==============================================================================
# SCRIPT RUNNER
# ==============================================================================
function Invoke-FieldScript {
    param(
        [Parameter(Mandatory)] [string]$RelativePath,
        [Parameter(Mandatory)] [string]$DisplayName,
        [hashtable]$Arguments = @{}
    )
    $scriptPath = Join-Path $scriptsRoot $RelativePath

    Clear-Host
    Nl
    Hr
    Row ("  " + (L 'launcher.run.running' 'Running') + ":  $DisplayName") 'Yellow'
    Row ("  " + (L 'launcher.run.path'    'Path'   ) + ":     $scriptPath") 'DarkGray'
    Hr
    Nl

    # Capture start time for "what's new" detection.
    # Subtract 2 seconds to be tolerant of clock skew / fast scripts.
    $runStart = (Get-Date).AddSeconds(-2)
    $hadError = $false

    if (-not (Test-Path $scriptPath)) {
        Write-Host ('  [X] ' + (L 'launcher.run.notfound' 'Script not found') + ": $scriptPath") -ForegroundColor Red
        Write-Host ('      ' + (L 'launcher.run.notfound.hint' 'Verify this file exists on the USB.')) -ForegroundColor DarkGray
        $hadError = $true
    } else {
        try {
            if ($Arguments -and $Arguments.Count -gt 0) {
                & $scriptPath @Arguments
            } else {
                & $scriptPath
            }
        } catch {
            Write-Host ('  [X] ' + (L 'launcher.run.error' 'Runtime error') + ": $_") -ForegroundColor Red
            Write-Host ('  ' + $_.ScriptStackTrace) -ForegroundColor DarkGray
            $hadError = $true
        }
    }

    # ----------------------------------------------------------------
    # POST-OPERATION PROMPT
    # Detect new files produced during this run, offer contextual actions.
    # ----------------------------------------------------------------
    if (-not $hadError) {
        Show-PostOpPrompt -RunStart $runStart
    } else {
        Nl
        Write-Host ('  ' + (L 'launcher.run.completed' 'Completed. Press any key to return to the menu...')) -ForegroundColor DarkGray
        $null = $HOST.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    }
}

function Show-PostOpPrompt {
    param([Parameter(Mandatory)] [datetime]$RunStart)

    # Find new files in REPORTS\ and LOGS\ since RunStart
    $newReports = @()
    $newLogs    = @()
    if (Test-Path $reportsDir) {
        $newReports = @(Get-ChildItem $reportsDir -File -Recurse -EA SilentlyContinue |
            Where-Object { $_.LastWriteTime -ge $RunStart })
    }
    if (Test-Path $logsDir) {
        $newLogs = @(Get-ChildItem $logsDir -File -Recurse -EA SilentlyContinue |
            Where-Object { $_.LastWriteTime -ge $RunStart })
    }

    $allNew = @($newReports) + @($newLogs)
    if ($allNew.Count -eq 0) {
        # No artifacts produced. Fall through to standard prompt.
        Nl
        Write-Host ('  ' + (L 'launcher.run.completed' 'Completed. Press any key to return to the menu...')) -ForegroundColor DarkGray
        $null = $HOST.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        return
    }

    # Pick the "primary" artifact: prefer .html, then most recent
    $primaryHtml = @($newReports | Where-Object { $_.Extension -eq '.html' } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1)
    $primary = if ($primaryHtml.Count -gt 0) { $primaryHtml[0] }
               else { @($allNew | Sort-Object LastWriteTime -Descending | Select-Object -First 1)[0] }

    # Detect snapshot files (Compliance produces .json.gz under REPORTS\Snapshots)
    $newSnapshot = @($newReports | Where-Object { $_.Name -like '*.json.gz' -or $_.Name -like 'snapshot_*.json' } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1)
    $hasSnapshot = ($newSnapshot.Count -gt 0)

    # ---- Render the prompt ----
    Nl
    Hr
    Row ('  ' + (L 'launcher.postop.title' 'Operation complete')) 'Green'
    Hr
    Nl

    # File summary
    foreach ($f in ($allNew | Sort-Object LastWriteTime -Descending | Select-Object -First 5)) {
        $kb = [math]::Round($f.Length / 1KB, 1)
        $rel = $f.FullName
        if ($rel.Length -gt 90) { $rel = '...' + $rel.Substring($rel.Length - 87) }
        Write-Host ('    ' + $rel) -ForegroundColor White -NoNewline
        Write-Host ('  (' + $kb + ' KB)') -ForegroundColor DarkGray
    }
    if ($allNew.Count -gt 5) {
        Write-Host ('    ... and ' + ($allNew.Count - 5) + ' more') -ForegroundColor DarkGray
    }

    Nl
    Hr
    Row ('  ' + (L 'launcher.postop.what' 'What next?')) 'Cyan'
    Hr

    # ---- Build the option menu dynamically based on what was produced ----
    $opts = New-Object System.Collections.ArrayList

    if ($primary.Extension -eq '.html') {
        [void]$opts.Add(@{ Key='O'; Color='Cyan';
            Label = (L 'launcher.postop.opt.open'   'Open the report in your browser') })
    }
    [void]$opts.Add(@{ Key='E'; Color='Cyan';
        Label = (L 'launcher.postop.opt.folder' 'Open the REPORTS folder in Explorer') })
    [void]$opts.Add(@{ Key='C'; Color='Cyan';
        Label = (L 'launcher.postop.opt.copy'   'Copy the file path to clipboard') })
    if ($hasSnapshot) {
        [void]$opts.Add(@{ Key='N'; Color='Magenta';
            Label = (L 'launcher.postop.opt.autofixplan' 'Run AutoFix Plan-Before-Execute on this snapshot') })
    }
    [void]$opts.Add(@{ Key='Enter'; Color='DarkGray';
        Label = (L 'launcher.postop.opt.menu' 'Return to main menu') })

    Nl
    foreach ($o in $opts) {
        Write-Host ('  [' + $o.Key + ']') -ForegroundColor $o.Color -NoNewline
        Write-Host ('  ' + $o.Label) -ForegroundColor White
    }
    Nl
    Write-Host ('  ' + (L 'launcher.postop.choice' 'Choice') + ': ') -ForegroundColor DarkGray -NoNewline

    $choice = (Read-Host).Trim().ToUpper()

    switch ($choice) {
        'O' {
            if ($primary.Extension -eq '.html') {
                try {
                    Start-Process $primary.FullName -ErrorAction Stop
                    Write-Host ('  [OK] ' + (L 'launcher.postop.opened' 'Opened') + ': ' + $primary.Name) -ForegroundColor Green
                } catch {
                    Write-Host ('  [X] ' + (L 'launcher.postop.openerr' 'Could not open file') + ': ' + $_) -ForegroundColor Red
                }
            } else {
                Write-Host ('  [!] ' + (L 'launcher.postop.nohtml' 'No HTML report to open from this run.')) -ForegroundColor Yellow
            }
        }
        'E' {
            try {
                Start-Process explorer.exe -ArgumentList $reportsDir -ErrorAction Stop
                Write-Host ('  [OK] ' + (L 'launcher.postop.foldopen' 'Opened folder') + ': ' + $reportsDir) -ForegroundColor Green
            } catch {
                Write-Host ('  [X] ' + (L 'launcher.postop.folderr' 'Could not open folder') + ': ' + $_) -ForegroundColor Red
            }
        }
        'C' {
            try {
                Set-Clipboard -Value $primary.FullName -ErrorAction Stop
                Write-Host ('  [OK] ' + (L 'launcher.postop.copied' 'Copied to clipboard') + ': ' + $primary.FullName) -ForegroundColor Green
            } catch {
                Write-Host ('  [X] ' + (L 'launcher.postop.copyerr' 'Could not copy to clipboard') + ': ' + $_) -ForegroundColor Red
            }
        }
        'N' {
            if ($hasSnapshot) {
                Write-Host ('  ' + (L 'launcher.postop.launchplan' 'Launching AutoFix Plan-Before-Execute...')) -ForegroundColor Magenta
                Start-Sleep -Milliseconds 600
                # Recurse into ourselves -- this will produce its own post-op prompt at the end
                Invoke-FieldScript 'Core\Invoke-AutoFixPlan.ps1' (L 'launcher.menu.autofixplan' 'AutoFix Plan-Before-Execute')
                return
            }
        }
        default {
            # Enter or anything else -> just return
            return
        }
    }

    # After action (except N which already returned), pause briefly then return
    Nl
    Write-Host ('  ' + (L 'launcher.run.completed' 'Press any key to return to the menu...')) -ForegroundColor DarkGray
    $null = $HOST.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
}

# ==============================================================================
# LOG VIEWER
# ==============================================================================
function Show-Logs {
    Clear-Host
    Nl
    Hr
    Row ('  ' + (L 'launcher.logs.title' 'SESSION LOGS (most recent 20)')) 'Cyan'
    Hr

    if (-not (Test-Path $logsDir)) {
        Row ('  ' + (L 'launcher.logs.notfound' 'LOGS folder not found.')) 'Red'
    } else {
        $logs = @(Get-ChildItem $logsDir -Filter '*.json' -EA SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 20)
        if ($logs.Count -eq 0) {
            Row ('  ' + (L 'launcher.logs.empty' 'No log files yet.')) 'DarkGray'
        } else {
            foreach ($log in $logs) {
                $age = (Get-Date) - $log.LastWriteTime
                $ageStr = if     ($age.TotalMinutes -lt 60) { "$([int]$age.TotalMinutes)m" }
                          elseif ($age.TotalHours   -lt 24) { "$([int]$age.TotalHours)h" }
                          else                              { "$([int]$age.TotalDays)d" }
                $kb = [math]::Round($log.Length / 1KB, 1)
                $name = $log.Name
                if ($name.Length -gt 78) { $name = $name.Substring(0, 78) + '~' }
                # Compose: "  filename.json                               12.3 KB    5m ago"
                $line = '  ' + $name.PadRight(80) + ('{0,8} KB' -f $kb) + '   ' + ('{0,6} ago' -f $ageStr)
                Row $line 'White'
            }
        }
    }
    Hr
    Nl
    Write-Host ('  ' + (L 'launcher.common.anykey' 'Press any key to return...')) -ForegroundColor DarkGray
    $null = $HOST.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
}

# ==============================================================================
# QUIT MENU
# ==============================================================================
function Invoke-Quit {
    Clear-Host
    Nl
    Hr
    Row ('  ' + (L 'launcher.quit.title' 'QUIT FIELDOPS PRO')) 'Red'
    Hr
    Row '' 'White'
    MenuRowWide '1' Cyan     (L 'launcher.quit.reboot'   'Reboot system')
    MenuRowWide '2' Cyan     (L 'launcher.quit.shutdown' 'Shutdown system')
    MenuRowWide '3' White    (L 'launcher.quit.exit'     'Exit to PowerShell')
    MenuRowWide '4' DarkGray (L 'launcher.quit.cancel'   'Cancel (return to menu)')
    Hr
    Nl
    Write-Host ('  ' + (L 'launcher.quit.choice' 'Choice') + ': ') -ForegroundColor DarkGray -NoNewline
    $choice = (Read-Host).Trim()
    switch ($choice) {
        '1' { Write-Host ''; Write-Host ('  ' + (L 'launcher.quit.rebooting'   'Rebooting...'))     -ForegroundColor Yellow; Start-Sleep 2; Restart-Computer -Force }
        '2' { Write-Host ''; Write-Host ('  ' + (L 'launcher.quit.shuttingdown' 'Shutting down...')) -ForegroundColor Yellow; Start-Sleep 2; Stop-Computer    -Force }
        '3' { exit 0 }
        default { return }
    }
}

# ==============================================================================
# DOT-SOURCE TOOLS MENU
# ==============================================================================
$_fieldOpsTools = Join-Path $coreDir 'FieldOps-Tools.ps1'
if (Test-Path $_fieldOpsTools) {
    try {
        . $_fieldOpsTools
    } catch {
        Write-Host "  [!] FieldOps-Tools.ps1 failed to load: $_" -ForegroundColor Red
        Write-Host '       [T] Portable Tools Menu will not be available.' -ForegroundColor Yellow
        Nl
    }
} else {
    Write-Host "  [!] FieldOps-Tools.ps1 not found at: $_fieldOpsTools" -ForegroundColor Red
    Write-Host '       [T] Portable Tools Menu will not be available.' -ForegroundColor Yellow
    Nl
}

# ==============================================================================
# MAIN LOOP
# ==============================================================================
$identity = Get-MachineIdentity   # gathered ONCE -- doesn't change

while ($true) {
    $status = Get-LiveStatus       # refreshed every iteration
    Draw-Screen -id $identity -st $status

    switch ((Read-Host).Trim().ToUpper()) {
        '1' { Invoke-FieldScript 'Diagnostics\Invoke-PCHealth.ps1'      (L 'launcher.menu.pchealth'   'PC Health Diagnostic') }
        '2' { Invoke-FieldScript 'Network\Invoke-NetRepair.ps1'         (L 'launcher.menu.network'    'Network Repair & Testing') }
        '3' { Invoke-FieldScript 'Security\Invoke-SecurityScan.ps1'     (L 'launcher.menu.security'   'Security Scan') }
        '4' { Invoke-FieldScript 'Diagnostics\Invoke-DiskAnalysis.ps1'  (L 'launcher.menu.disk'       'Disk Analysis & SMART Health') }
        '5' { Invoke-FieldScript 'Deployment\Invoke-SoftwareDeploy.ps1' (L 'launcher.menu.softdeploy' 'Software Deployment') }
        '6' { Invoke-FieldScript 'Deployment\Invoke-AzureADJoin.ps1'    (L 'launcher.menu.aadjoin'    'Azure AD Join Workflow') }
        '7' { Invoke-FieldScript 'Deployment\Invoke-VPNSetup.ps1'       (L 'launcher.menu.vpn'        'GlobalProtect VPN Setup') }
        '8' { Invoke-FieldScript 'Reporting\New-IncidentReport.ps1'     (L 'launcher.menu.incident'   'Incident Report (HTML)') }
        '9' { Invoke-FieldScript 'Core\Invoke-ComplianceDiff.ps1'       (L 'launcher.menu.compliance' 'Compliance Snapshot & Diff') }
        'D' { Invoke-FieldScript 'Core\Invoke-Dashboard.ps1'            (L 'launcher.menu.dashboard'  'HTML Dashboard') @{ OpenDashboard = $true } }
        'F' { Invoke-FieldScript 'Core\Invoke-FleetReport.ps1'          (L 'launcher.menu.fleet'      'Fleet Report') }
        'P' { Invoke-FieldScript 'Core\Invoke-Playbook.ps1'             (L 'launcher.menu.playbook'   'Playbook Runner') }
        'A' { Invoke-FieldScript 'Core\Invoke-AutoFix.ps1'              (L 'launcher.menu.autofix'    'AutoFix') }
        'N' { Invoke-FieldScript 'Core\Invoke-AutoFixPlan.ps1'          (L 'launcher.menu.autofixplan' 'AutoFix Plan-Before-Execute') }
        'T' {
            if (Get-Command Show-ToolsMenu -ErrorAction SilentlyContinue) {
                Show-ToolsMenu
            } else {
                Write-Host ('  [X] ' + (L 'launcher.tools.unavailable' 'Portable Tools Menu is unavailable -- FieldOps-Tools.ps1 was not loaded.')) -ForegroundColor Red
                Start-Sleep 2
            }
        }
        'L' { Show-Logs }
        'Q' { Invoke-Quit }
        ''  { }   # Enter alone -- redraw
        default {
            Write-Host ('  [!] ' + (L 'launcher.menu.invalid' 'Invalid option.')) -ForegroundColor Red
            Start-Sleep 1
        }
    }
}
