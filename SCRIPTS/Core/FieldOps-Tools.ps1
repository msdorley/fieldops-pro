#Requires -Version 5.1
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Ousman Dorley. See LICENSE at the repository root.
<#
.SYNOPSIS
    FieldOps Pro - Portable Tools Menu v3.2
.DESCRIPTION
    Interactive launcher for all portable tools on the USB.
    Author: Ousman Dorley | EU Deployment | FieldOps Pro v3.2

    v3.2 Fixes:
      - Replaced '& $fn' string dispatch with direct switch statement
        (eliminates non-terminating error + scope resolution failures)
      - All Start-Process calls use -WorkingDirectory via Start-Tool
      - Reserved variables $args/$profile renamed in Start-Nmap
      - UTF-8 encoding fixed throughout
      - Error logging to E:\LOGS\tool_errors.log
#>

# ==============================================================================
# PATH RESOLUTION
# ==============================================================================
$_scriptDir  = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path $MyInvocation.MyCommand.Path -Parent }
$_scriptsDir = Split-Path $_scriptDir -Parent
$_usbRoot    = Split-Path $_scriptsDir -Parent
$_toolsRoot  = Join-Path $_usbRoot 'TOOLS'
$_logRoot    = Join-Path $_usbRoot 'LOGS'

# ==============================================================================
# COLOR HELPERS
# ==============================================================================
function c  ($text, $fg = 'White', $bg = 'Black') { Write-Host $text -ForegroundColor $fg -BackgroundColor $bg -NoNewline }
function cn ($text, $fg = 'White', $bg = 'Black') { Write-Host $text -ForegroundColor $fg -BackgroundColor $bg }
function nl { Write-Host '' }
function sep { cn ('  ' + ('-' * 68)) DarkGray }
function hdr ($title) {
    nl
    cn ('  +' + ('-' * 66) + '+') Magenta
    cn ("  |  {0,-64}|" -f $title) Magenta
    cn ('  +' + ('-' * 66) + '+') Magenta
    nl
}

# ==============================================================================
# ELEVATION CHECK
# ==============================================================================
function Test-IsAdmin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Start-Elevated {
    param([string]$Path, [string]$ElArgs = '', [string]$WorkDir = '')
    try {
        $splat = @{ FilePath = $Path; Verb = 'RunAs'; ErrorAction = 'Stop' }
        if ($ElArgs)  { $splat['ArgumentList']     = $ElArgs }
        if ($WorkDir) { $splat['WorkingDirectory']  = $WorkDir }
        Start-Process @splat
        return $true
    } catch {
        cn "  [X] Elevation failed: $_" Red
        return $false
    }
}

# ==============================================================================
# SAFE LOG WRITER
# ==============================================================================
function ToolLog {
    param([string]$Tool, [string]$Action, [string]$Detail = '')
    try {
        if (-not (Test-Path $_logRoot)) { New-Item $_logRoot -ItemType Directory -Force | Out-Null }
        $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [TOOLS] [$Tool] $Action $Detail"
        Add-Content (Join-Path $_logRoot "$(Get-Date -Format 'yyyyMMdd')_$($env:COMPUTERNAME)_Tools.log") $entry -EA SilentlyContinue
    } catch {}
}

function Write-ToolError {
    param([string]$Tool, [string]$Message, [string]$Stack = '')
    try {
        if (-not (Test-Path $_logRoot)) { New-Item $_logRoot -ItemType Directory -Force | Out-Null }
        $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [ERROR] [$Tool] $Message"
        if ($Stack) { $entry += "`n  Stack: $Stack" }
        Add-Content (Join-Path $_logRoot 'tool_errors.log') $entry -EA SilentlyContinue
    } catch {}
}

# ==============================================================================
# SAFE LAUNCHER -- wraps Start-Process with WorkingDirectory + error handling
# ==============================================================================
function Start-Tool {
    param(
        [string]$Exe,
        [string]$ToolName,
        [string]$LaunchArgs = '',
        [switch]$Wait,
        [switch]$NeedAdmin
    )
    $workDir = Split-Path $Exe -Parent
    try {
        if ($NeedAdmin -and -not (Test-IsAdmin)) {
            Start-Elevated -Path $Exe -ElArgs $LaunchArgs -WorkDir $workDir
        } else {
            $splat = @{
                FilePath         = $Exe
                WorkingDirectory = $workDir
                ErrorAction      = 'Stop'
            }
            if ($LaunchArgs) { $splat['ArgumentList'] = $LaunchArgs }
            if ($Wait)       { $splat['Wait']         = $true }
            Start-Process @splat
        }
        cn "  [OK] $ToolName launched." Green
        ToolLog $ToolName 'LAUNCHED'
        return $true
    } catch {
        cn "  [X] Failed to launch ${ToolName}: $_" Red
        Write-ToolError $ToolName $_.ToString() $_.ScriptStackTrace
        return $false
    }
}

# ==============================================================================
# PAUSE HELPER
# ==============================================================================
function Pause-ForKey {
    param([string]$Msg = '  Press any key to return to tools menu...')
    nl; cn $Msg DarkGray
    $null = $HOST.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
}

# ==============================================================================
# TOOL PATH RESOLVER
# ==============================================================================
function Resolve-ToolPath {
    param([string[]]$ExplicitPaths, [string[]]$SearchPatterns = @())
    foreach ($p in $ExplicitPaths) {
        if ($p -and (Test-Path $p)) { return $p }
    }
    foreach ($pattern in $SearchPatterns) {
        $found = Get-ChildItem $_usbRoot -Recurse -Filter $pattern -EA SilentlyContinue | Select-Object -First 1
        if ($found) { return $found.FullName }
    }
    return $null
}

# ==============================================================================
#   TOOL WRAPPERS
# ==============================================================================

function Start-HWiNFO {
    hdr 'HWiNFO64 -- Hardware Info & Real-Time Sensors'
    $exe = Resolve-ToolPath @("$_toolsRoot\Diagnostics\HWiNFO64.exe") @('HWiNFO64.exe')
    if (-not $exe) { cn '  [X] HWiNFO64.exe not found on USB.' Red; Pause-ForKey; return }

    cn '  [1]  Normal mode (GUI with sensors)' Cyan
    cn '  [2]  Sensors-only mode (lightweight)' Cyan
    cn '  [3]  Summary only' Cyan
    nl; c '  Mode: ' DarkGray
    $launchArgs = switch ((Read-Host).Trim()) {
        '2' { '-sensors' }
        '3' { '-summary' }
        default { '' }
    }
    Start-Tool -Exe $exe -ToolName 'HWiNFO64' -LaunchArgs $launchArgs
    Pause-ForKey
}

function Start-CrystalDiskInfo {
    hdr 'CrystalDiskInfo -- Disk SMART Health'
    $exe = Resolve-ToolPath @(
        "$_toolsRoot\Diagnostics\DiskInfo64S.exe",
        "$_toolsRoot\Diagnostics\DiskInfo64.exe"
    ) @('DiskInfo64*.exe')
    if (-not $exe) { cn '  [X] CrystalDiskInfo not found.' Red; Pause-ForKey; return }
    cn '  Launching CrystalDiskInfo...' Yellow
    Start-Tool -Exe $exe -ToolName 'CrystalDiskInfo'
    nl
    cn '  What to look for:' DarkGray
    cn '  GREEN = Good    YELLOW = Caution    RED = Bad (replace immediately)' DarkGray
    cn '  Key values: Reallocated Sectors, Pending Sectors, Uncorrectable Errors' DarkGray
    Pause-ForKey
}

function Start-CPUZ {
    hdr 'CPU-Z -- Processor, RAM & Motherboard Details'
    $exe = Resolve-ToolPath @(
        "$_toolsRoot\Diagnostics\cpuz_x64.exe",
        "$_toolsRoot\Diagnostics\cpuz_x32.exe"
    ) @('cpuz_x64.exe','cpuz*.exe')
    if (-not $exe) { cn '  [X] CPU-Z not found.' Red; Pause-ForKey; return }
    Start-Tool -Exe $exe -ToolName 'CPU-Z'
    Pause-ForKey
}

function Start-Nmap {
    $nmapExe = Resolve-ToolPath @("$_toolsRoot\NetworkTools\nmap.exe") @('nmap.exe')
    if (-not $nmapExe) { cn '  [X] nmap.exe not found.' Red; Pause-ForKey; return }

    $nmapDir = Split-Path $nmapExe -Parent

    while ($true) {
        hdr 'Nmap -- Network Scanner'
        cn '  SCAN PROFILES:' DarkCyan
        cn '  [1]  Host Discovery       Ping sweep -- find all live hosts on subnet' White
        cn '  [2]  Port Scan (Quick)    Top 100 ports on a single host' White
        cn '  [3]  Port Scan (Full)     All 65535 ports on a single host' White
        cn '  [4]  Service Detection    Detect services + versions on open ports' White
        cn '  [5]  OS Detection         Guess operating system of target' White
        cn '  [6]  Vulnerability Scan   Run NSE vuln scripts against target' White
        cn '  [7]  Full Aggressive      OS + Services + Scripts + Traceroute (-A)' White
        cn '  [8]  Custom command       Enter your own nmap arguments' White
        cn '  [Q]  Back' DarkGray
        nl; c '  Profile: ' DarkGray
        $scanProfile = (Read-Host).Trim().ToUpper()
        if ($scanProfile -eq 'Q') { return }

        nl; c '  Target IP / range / hostname' DarkGray
        cn '  (examples: 192.168.1.1  |  192.168.1.0/24  |  hostname.local): ' DarkGray
        $target = (Read-Host).Trim()
        if ([string]::IsNullOrWhiteSpace($target)) { cn '  [!] Target required.' Red; Start-Sleep 1; continue }

        if (-not (Test-Path $_logRoot)) { New-Item $_logRoot -ItemType Directory -Force | Out-Null }
        $outFile = Join-Path $_logRoot ("nmap_$(Get-Date -Format 'yyyyMMdd_HHmmss')_$($env:COMPUTERNAME).txt")

        $nmapArgs = switch ($scanProfile) {
            '1' { "-sn $target" }
            '2' { "--top-ports 100 $target" }
            '3' { "-p- $target" }
            '4' { "-sV $target" }
            '5' { "-O $target" }
            '6' { "--script vuln $target" }
            '7' { "-A $target" }
            '8' { nl; c '  nmap ' Cyan; $custom = Read-Host; $custom.Trim() }
            default { "-sn $target" }
        }

        nl; sep
        cn "  Running: nmap $nmapArgs" Yellow
        cn "  Output will also be saved to: $outFile" DarkGray
        sep; nl

        ToolLog 'Nmap' 'SCAN' "Args: nmap $nmapArgs | Target: $target"

        try {
            Push-Location $nmapDir
            $output = & $nmapExe ($nmapArgs -split ' ') 2>&1
            Pop-Location

            $output | ForEach-Object {
                $line = $_.ToString()
                if     ($line -match 'open')    { cn "  $line" Green }
                elseif ($line -match 'closed')  { cn "  $line" DarkGray }
                elseif ($line -match 'filtered'){ cn "  $line" Yellow }
                elseif ($line -match 'ERROR|WARNING') { cn "  $line" Red }
                else                            { cn "  $line" White }
            }

            $output | Out-File $outFile -Encoding UTF8 -Force
            nl; cn "  [OK] Scan complete. Results saved to:" Green
            cn "       $outFile" DarkGray
        } catch {
            cn "  [X] Nmap error: $_" Red
            Write-ToolError 'Nmap' $_.ToString() $_.ScriptStackTrace
        }

        nl; sep
        c '  Run another scan? (Y/N): ' DarkGray
        if ((Read-Host).Trim().ToUpper() -ne 'Y') { return }
    }
}

function Start-Wireshark {
    hdr 'Wireshark Portable -- Packet Capture'
    $exe = Resolve-ToolPath @(
        "$_toolsRoot\NetworkTools\WiresharkPortable64\WiresharkPortable64.exe"
    ) @('WiresharkPortable64.exe','Wireshark.exe')
    if (-not $exe) { cn '  [X] Wireshark not found.' Red; Pause-ForKey; return }

    cn '  [1]  Launch GUI (full Wireshark)' Cyan
    cn '  [2]  Launch on specific interface' Cyan
    nl; c '  Choice: ' DarkGray
    $choice = (Read-Host).Trim()

    if ($choice -eq '2') {
        nl; cn '  Available network interfaces:' Yellow
        try {
            Get-NetAdapter -EA SilentlyContinue | Where-Object { $_.Status -eq 'Up' } |
            ForEach-Object { cn "    $($_.InterfaceIndex)  $($_.Name)  [$($_.InterfaceDescription)]" Cyan }
        } catch {}
        nl; c '  Interface name: ' DarkGray
        $iface = (Read-Host).Trim()
        Start-Tool -Exe $exe -ToolName 'Wireshark' -LaunchArgs "-i `"$iface`" -k"
    } else {
        Start-Tool -Exe $exe -ToolName 'Wireshark'
    }
    Pause-ForKey
}

function Start-AdwCleaner {
    hdr 'AdwCleaner -- Adware & PUP Removal'
    $exe = Resolve-ToolPath @("$_toolsRoot\Security\adwcleaner.exe") @('adwcleaner*.exe')
    if (-not $exe) { cn '  [X] AdwCleaner not found.' Red; Pause-ForKey; return }

    cn '  [1]  Scan only (review results before cleaning)' Cyan
    cn '  [2]  Scan + Clean automatically' Cyan
    nl; c '  Mode: ' DarkGray
    $mode = (Read-Host).Trim()

    $launchArgs = if ($mode -eq '2') { '/scan /clean /noreboot' } else { '/scan' }
    Start-Tool -Exe $exe -ToolName 'AdwCleaner' -LaunchArgs $launchArgs -Wait -NeedAdmin
    ToolLog 'AdwCleaner' "MODE:$mode"
    Pause-ForKey
}

function Start-RKill {
    hdr 'RKill -- Malware Process Terminator'
    $exe = Resolve-ToolPath @("$_toolsRoot\Security\rkill.exe") @('rkill*.exe')
    if (-not $exe) { cn '  [X] RKill not found.' Red; Pause-ForKey; return }

    nl
    cn '  What RKill does:' DarkGray
    cn '  Terminates known malware processes so other scanners can clean them.' DarkGray
    cn '  Run this BEFORE Malwarebytes or AdwCleaner on infected machines.' DarkGray
    nl; cn '  WARNING: Some AV may flag RKill -- this is a false positive.' Yellow
    nl; c '  Run RKill now? (Y/N): ' DarkGray
    if ((Read-Host).Trim().ToUpper() -ne 'Y') { return }

    cn '  Running RKill...' Yellow
    ToolLog 'RKill' 'STARTED'
    Start-Tool -Exe $exe -ToolName 'RKill' -Wait
    Pause-ForKey
}

function Start-Malwarebytes {
    hdr 'Malwarebytes -- Full Malware Scanner'

    $installerExe = Resolve-ToolPath @("$_toolsRoot\Security\MalwareBytes.exe") @('MalwareBytes*.exe','MBAMSetup*.exe')
    $installedExe = @(
        "$env:ProgramFiles\Malwarebytes\Anti-Malware\mbam.exe",
        "${env:ProgramFiles(x86)}\Malwarebytes\Anti-Malware\mbam.exe",
        "$env:ProgramFiles\Malwarebytes Anti-Malware\mbam.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1

    $isInstalled = $null -ne $installedExe

    cn '  Status:' DarkGray
    if ($isInstalled) {
        cn '    Malwarebytes is INSTALLED on this machine.' Green
    } else {
        cn '    Malwarebytes is NOT installed on this machine.' Yellow
        if ($installerExe) { cn "    Installer found on USB: $installerExe" DarkGray }
        else               { cn '    Installer NOT found on USB.' Red }
    }

    nl
    if ($isInstalled) {
        cn '  [1]  Launch Malwarebytes (already installed)' Green
        cn '  [2]  Run silent scan' Green
        cn '  [3]  Uninstall Malwarebytes from this machine' Red
    } else {
        if ($installerExe) {
            cn '  [1]  Install Malwarebytes on this machine' Yellow
            cn '  [2]  Install + Launch' Yellow
        } else {
            cn '  [!]  No installer on USB.' Red
            cn "       Place MalwareBytes.exe in: $_toolsRoot\Security\" Yellow
            nl; cn '  [A]  Use AdwCleaner instead (portable, already on USB)' Cyan
        }
    }
    cn '  [Q]  Back' DarkGray
    nl; c '  Choice: ' DarkGray
    $choice = (Read-Host).Trim().ToUpper()

    if ($isInstalled) {
        switch ($choice) {
            '1' { Start-Tool -Exe $installedExe -ToolName 'Malwarebytes' }
            '2' { Start-Tool -Exe $installedExe -ToolName 'Malwarebytes' -LaunchArgs '/scan' -Wait }
            '3' {
                c '  Uninstall Malwarebytes? (YES to confirm): ' Red
                if ((Read-Host).Trim() -eq 'YES') {
                    $unStr = (Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' -EA SilentlyContinue |
                              Get-ItemProperty -EA SilentlyContinue |
                              Where-Object { $_.DisplayName -match 'Malwarebytes' } |
                              Select-Object -First 1).UninstallString
                    if ($unStr) {
                        Start-Process 'cmd.exe' -ArgumentList "/c $unStr /S" -Wait -WindowStyle Hidden
                        cn '  [OK] Uninstalled.' Green
                    } else { cn '  [!] Uninstall string not found. Use Control Panel.' Yellow }
                    ToolLog 'Malwarebytes' 'UNINSTALLED'
                }
            }
        }
    } else {
        switch ($choice) {
            '1' {
                if ($installerExe) {
                    cn '  Installing Malwarebytes...' Yellow
                    Start-Tool -Exe $installerExe -ToolName 'Malwarebytes-Install' -Wait
                }
            }
            '2' {
                if ($installerExe) {
                    cn '  Installing...' Yellow
                    Start-Tool -Exe $installerExe -ToolName 'Malwarebytes-Install' -Wait
                    $newExe = @(
                        "$env:ProgramFiles\Malwarebytes\Anti-Malware\mbam.exe",
                        "${env:ProgramFiles(x86)}\Malwarebytes\Anti-Malware\mbam.exe"
                    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
                    if ($newExe) { Start-Tool -Exe $newExe -ToolName 'Malwarebytes' }
                }
            }
            'A' { Start-AdwCleaner }
        }
    }
    Pause-ForKey
}

function Start-TestDisk {
    hdr 'TestDisk -- Partition & Boot Repair'
    $exe = Resolve-ToolPath @(
        "$_toolsRoot\Recovery\testdisk-7.3-WIP\testdisk_win.exe"
    ) @('testdisk_win.exe','testdisk*.exe')
    if (-not $exe) { cn '  [X] TestDisk not found.' Red; Pause-ForKey; return }

    nl
    cn '  TestDisk can:' DarkGray
    cn '    - Recover lost/deleted partitions' DarkGray
    cn '    - Fix MBR and partition tables' DarkGray
    cn '    - Rebuild boot sectors' DarkGray
    cn '    - Undelete files (use PhotoRec for files)' DarkGray
    nl
    cn '  [1]  Launch TestDisk (partition recovery)' Cyan
    cn '  [2]  Launch PhotoRec (file recovery)' Cyan
    nl; c '  Choice: ' DarkGray
    $choice = (Read-Host).Trim()

    $dir = Split-Path $exe -Parent
    if ($choice -eq '2') {
        $photorec = Join-Path $dir 'photorec_win.exe'
        if (Test-Path $photorec) { Start-Tool -Exe $photorec -ToolName 'PhotoRec' }
        else { cn '  [X] PhotoRec not found.' Red }
    } else {
        Start-Tool -Exe $exe -ToolName 'TestDisk' -NeedAdmin
    }
    ToolLog 'TestDisk' "CHOICE:$choice"
    Pause-ForKey
}

function Start-Recuva {
    hdr 'Recuva -- Deleted File Recovery'
    $exe = Resolve-ToolPath @(
        "$_toolsRoot\Recovery\recuva64.exe",
        "$_toolsRoot\Recovery\recuva.exe"
    ) @('recuva64.exe','recuva.exe')
    if (-not $exe) { cn '  [X] Recuva not found.' Red; Pause-ForKey; return }

    cn '  [1]  Launch GUI (recommended)' Cyan
    cn '  [2]  Scan specific drive for all files' Cyan
    cn '  [3]  Scan specific drive for documents only' Cyan
    nl; c '  Choice: ' DarkGray
    $choice = (Read-Host).Trim()

    switch ($choice) {
        '2' {
            c '  Drive letter to scan (e.g. C): ' DarkGray
            $drive = (Read-Host).Trim().TrimEnd(':').ToUpper()
            Start-Tool -Exe $exe -ToolName 'Recuva' -LaunchArgs "/drive $drive`: /all"
        }
        '3' {
            c '  Drive letter to scan (e.g. C): ' DarkGray
            $drive = (Read-Host).Trim().TrimEnd(':').ToUpper()
            Start-Tool -Exe $exe -ToolName 'Recuva' -LaunchArgs "/drive $drive`: /type documents"
        }
        default { Start-Tool -Exe $exe -ToolName 'Recuva' }
    }
    ToolLog 'Recuva' "CHOICE:$choice"
    Pause-ForKey
}

function Start-ProcessExplorer {
    hdr 'Process Explorer -- Advanced Task Manager (Sysinternals)'
    $exe = Resolve-ToolPath @(
        "$_toolsRoot\SysAdmin\Sysinternals_Suite\procexp64.exe"
    ) @('procexp64.exe','procexp.exe')
    if (-not $exe) { cn '  [X] Process Explorer not found.' Red; Pause-ForKey; return }

    cn '  Launching elevated...' Yellow
    Start-Tool -Exe $exe -ToolName 'ProcessExplorer' -NeedAdmin
    cn '  Tip: View > VirusTotal column to check suspicious processes online.' DarkGray
    Pause-ForKey
}

function Start-Autoruns {
    hdr 'Autoruns -- Startup Manager (Sysinternals)'
    $exe = Resolve-ToolPath @(
        "$_toolsRoot\SysAdmin\Sysinternals_Suite\Autoruns64.exe"
    ) @('Autoruns64.exe','Autoruns.exe')
    if (-not $exe) { cn '  [X] Autoruns not found.' Red; Pause-ForKey; return }

    cn '  [1]  Launch GUI (full Autoruns)' Cyan
    cn '  [2]  Export all autorun entries to CSV' Cyan
    nl; c '  Choice: ' DarkGray
    $choice = (Read-Host).Trim()

    if ($choice -eq '2') {
        if (-not (Test-Path $_logRoot)) { New-Item $_logRoot -ItemType Directory -Force | Out-Null }
        $csvOut = Join-Path $_logRoot ("autoruns_$(Get-Date -Format 'yyyyMMdd_HHmmss')_$($env:COMPUTERNAME).csv")
        $autorunsCLI = Resolve-ToolPath @(
            "$_toolsRoot\SysAdmin\Sysinternals_Suite\autorunsc64.exe"
        ) @('autorunsc64.exe')
        if ($autorunsCLI) {
            $cliDir = Split-Path $autorunsCLI -Parent
            cn "  Exporting to: $csvOut" DarkGray
            try {
                Push-Location $cliDir
                $output = & $autorunsCLI -a * -c -h -s '*' 2>&1
                Pop-Location
                $output | Out-File $csvOut -Encoding UTF8 -Force
                cn "  [OK] Exported: $csvOut" Green
            } catch {
                cn "  [X] Export error: $_" Red
                Write-ToolError 'Autoruns-CLI' $_.ToString()
            }
        } else {
            cn '  [!] autorunsc64.exe not found for CLI export.' Yellow
            Start-Tool -Exe $exe -ToolName 'Autoruns' -NeedAdmin
        }
    } else {
        Start-Tool -Exe $exe -ToolName 'Autoruns' -NeedAdmin
        cn '  Tip: Yellow = file not found, Red = VirusTotal hit.' DarkGray
    }
    ToolLog 'Autoruns' "CHOICE:$choice"
    Pause-ForKey
}

function Start-ProcMon {
    hdr 'Process Monitor -- Real-Time System Activity'
    $exe = Resolve-ToolPath @(
        "$_toolsRoot\SysAdmin\Sysinternals_Suite\Procmon64.exe"
    ) @('Procmon64.exe','Procmon.exe')
    if (-not $exe) { cn '  [X] Process Monitor not found.' Red; Pause-ForKey; return }

    cn '  [1]  Launch GUI (live monitoring)' Cyan
    cn '  [2]  Capture 30 seconds, save to PML log' Cyan
    nl; c '  Choice: ' DarkGray
    $choice = (Read-Host).Trim()

    if ($choice -eq '2') {
        if (-not (Test-Path $_logRoot)) { New-Item $_logRoot -ItemType Directory -Force | Out-Null }
        $pmlOut = Join-Path $_logRoot ("procmon_$(Get-Date -Format 'yyyyMMdd_HHmmss')_$($env:COMPUTERNAME).pml")
        cn "  Capturing 30 seconds to: $pmlOut" Yellow
        $workDir = Split-Path $exe -Parent
        if (Test-IsAdmin) {
            Start-Process $exe -ArgumentList "/Quiet /Minimized /BackingFile `"$pmlOut`"" -WorkingDirectory $workDir
            Start-Sleep 30
            Stop-Process -Name 'Procmon64','Procmon' -EA SilentlyContinue
            cn "  [OK] Capture saved: $pmlOut" Green
        } else {
            cn '  [!] Requires admin for silent capture.' Yellow
            Start-Elevated -Path $exe -ElArgs "/Quiet /Minimized /BackingFile `"$pmlOut`"" -WorkDir $workDir
        }
    } else {
        Start-Tool -Exe $exe -ToolName 'ProcMon' -NeedAdmin
    }
    ToolLog 'ProcMon' "CHOICE:$choice"
    Pause-ForKey
}

function Start-TCPView {
    hdr 'TCPView -- Network Connection Viewer'
    $exe = Resolve-ToolPath @(
        "$_toolsRoot\SysAdmin\Sysinternals_Suite\tcpview64.exe"
    ) @('tcpview64.exe','tcpview.exe')
    if (-not $exe) { cn '  [X] TCPView not found.' Red; Pause-ForKey; return }

    cn '  [1]  Launch GUI' Cyan
    cn '  [2]  Show current connections in console (no GUI)' Cyan
    nl; c '  Choice: ' DarkGray
    $choice = (Read-Host).Trim()

    if ($choice -eq '2') {
        nl; sep
        cn '  Active TCP/UDP connections:' Yellow
        try {
            Get-NetTCPConnection -State Established,Listen -EA SilentlyContinue |
            Sort-Object State,RemotePort |
            ForEach-Object {
                $proc = try { (Get-Process -Id $_.OwningProcess -EA SilentlyContinue).Name } catch { 'Unknown' }
                $state = $_.State.ToString().PadRight(12)
                $sc = if ($_.State -eq 'Established') { 'Green' } else { 'DarkGray' }
                c "  $state" $sc
                c " $($_.LocalAddress):$($_.LocalPort)".PadRight(26) White
                c " -> $($_.RemoteAddress):$($_.RemotePort)".PadRight(30) Cyan
                cn " [$proc]" DarkGray
            }
        } catch { cn '  Get-NetTCPConnection failed.' Red }
        sep
        ToolLog 'TCPView' 'CONSOLE_MODE'
        Pause-ForKey
    } else {
        Start-Tool -Exe $exe -ToolName 'TCPView' -NeedAdmin
        Pause-ForKey
    }
}

function Start-NirLauncher {
    hdr 'NirLauncher -- Full NirSoft Portable Suite (160+ tools)'
    $exe = Resolve-ToolPath @(
        "$_toolsRoot\SysAdmin\NirSoft\NirLauncher.exe"
    ) @('NirLauncher.exe')
    if (-not $exe) { cn '  [X] NirLauncher not found.' Red; Pause-ForKey; return }

    nl
    cn '  NirSoft categories: Password Recovery, Network Tools, Browser Tools,' DarkGray
    cn '  System Info, Disk Utils, Registry Tools, and more.' DarkGray
    nl
    cn '  Launching NirLauncher...' Yellow
    Start-Tool -Exe $exe -ToolName 'NirLauncher'
    Pause-ForKey
}

function Start-ChromePortable {
    hdr 'Chrome Portable -- Standalone Browser'
    $exe = Resolve-ToolPath @(
        "$_toolsRoot\Browser\chrome-win\chrome.exe"
    ) @('chrome.exe')
    if (-not $exe) { cn '  [X] Chrome portable not found.' Red; Pause-ForKey; return }

    cn '  [1]  Launch Chrome (normal)' Cyan
    cn '  [2]  Launch in Incognito mode' Cyan
    cn '  [3]  Launch to specific URL' Cyan
    nl; c '  Choice: ' DarkGray
    $choice = (Read-Host).Trim()

    $launchArgs = switch ($choice) {
        '2' { '--incognito' }
        '3' { c '  URL: ' DarkGray; $url = (Read-Host).Trim(); if ($url) { $url } else { '' } }
        default { '' }
    }
    Start-Tool -Exe $exe -ToolName 'Chrome' -LaunchArgs $launchArgs
    ToolLog 'Chrome' "CHOICE:$choice"
    Pause-ForKey
}

function Show-QuickDiagnostics {
    hdr 'Quick Diagnostics -- Live System Overview'
    cn '  Collecting system information...' DarkGray; nl

    try {
        $cpu = Get-CimInstance Win32_Processor -EA SilentlyContinue | Select-Object -First 1
        c '  CPU:        ' DarkGray; cn "$($cpu.Name) [$($cpu.NumberOfCores)C/$($cpu.NumberOfLogicalProcessors)T]" Cyan
        c '  CPU Load:   ' DarkGray
        $load = $cpu.LoadPercentage
        $lc = if ($load -gt 80) { 'Red' } elseif ($load -gt 50) { 'Yellow' } else { 'Green' }
        cn "$load%" $lc
    } catch {}

    try {
        $os  = Get-CimInstance Win32_OperatingSystem -EA SilentlyContinue
        $tot = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
        $free= [math]::Round($os.FreePhysicalMemory / 1MB, 1)
        $used= [math]::Round($tot - $free, 1)
        $pct = [math]::Round(($used / $tot) * 100)
        $rc  = if ($pct -gt 85) { 'Red' } elseif ($pct -gt 65) { 'Yellow' } else { 'Green' }
        c '  RAM:        ' DarkGray; cn "${used}GB / ${tot}GB used ($pct%)" $rc
    } catch {}

    nl; cn '  Disks:' DarkGray
    try {
        Get-PSDrive -PSProvider FileSystem -EA SilentlyContinue | Where-Object { $_.Used -gt 0 } |
        ForEach-Object {
            $total = [math]::Round(($_.Used + $_.Free) / 1GB, 1)
            $used  = [math]::Round($_.Used / 1GB, 1)
            $free  = [math]::Round($_.Free / 1GB, 1)
            $pct   = [math]::Round(($_.Used / ($_.Used + $_.Free)) * 100)
            $dc    = if ($pct -gt 90) { 'Red' } elseif ($pct -gt 75) { 'Yellow' } else { 'Green' }
            $bar   = '#' * [math]::Round($pct / 5)
            $empty = '-' * (20 - [math]::Round($pct / 5))
            c "    $($_.Name):\ " DarkGray; c "[$bar$empty]" $dc
            cn (" ${used}GB / ${total}GB ($pct% used) | ${free}GB free") $dc
        }
    } catch {}

    nl; cn '  Network Adapters (active):' DarkGray
    try {
        Get-CimInstance Win32_NetworkAdapterConfiguration -EA SilentlyContinue |
        Where-Object { $_.IPEnabled } | ForEach-Object {
            c "    $($_.Description.Substring(0,[Math]::Min(40,$_.Description.Length))):  " DarkGray
            cn ($_.IPAddress -join ', ') Cyan
        }
    } catch {}

    try {
        $bat = Get-CimInstance Win32_Battery -EA SilentlyContinue | Select-Object -First 1
        if ($bat) {
            nl; c '  Battery:    ' DarkGray
            $bc = if ($bat.EstimatedChargeRemaining -lt 20) { 'Red' } elseif ($bat.EstimatedChargeRemaining -lt 50) { 'Yellow' } else { 'Green' }
            cn "$($bat.EstimatedChargeRemaining)% | Status: $($bat.BatteryStatus)" $bc
        }
    } catch {}

    try {
        $boot = (Get-CimInstance Win32_OperatingSystem -EA SilentlyContinue).LastBootUpTime
        $up   = (Get-Date) - $boot
        nl; c '  Uptime:     ' DarkGray; cn "$([int]$up.TotalHours)h $($up.Minutes)m" White
        c '  Last Boot:  ' DarkGray; cn $boot.ToString('yyyy-MM-dd HH:mm') White
    } catch {}

    nl; cn '  Top 5 CPU processes:' DarkGray
    try {
        Get-Process -EA SilentlyContinue | Sort-Object CPU -Descending | Select-Object -First 5 |
        ForEach-Object {
            $cpuPct = [math]::Round($_.CPU, 1)
            $memMB  = [math]::Round($_.WorkingSet / 1MB, 1)
            c "    $($_.Name.PadRight(25))" White
            c "CPU: $($cpuPct.ToString().PadLeft(8))s  " DarkGray
            cn "RAM: $memMB MB" DarkGray
        }
    } catch {}

    nl; ToolLog 'QuickDiag' 'COMPLETED'
    Pause-ForKey
}

# ==============================================================================
# MAIN TOOLS MENU
# ==============================================================================
function Show-ToolsMenu {
    while ($true) {
        Clear-Host
        nl
        cn '  +------------------------------------------------------------------+' Magenta
        cn '  |               FIELDOPS PRO -- PORTABLE TOOLS MENU                |' Magenta
        cn '  +------------------------------------------------------------------+' Magenta
        nl

        # Status display -- shows which tools are present on USB
        $statusList = [ordered]@{
            '1' = @{ Name='HWiNFO64';          Desc='Hardware Info & Real-Time Sensors';          Path="$_toolsRoot\Diagnostics\HWiNFO64.exe" }
            '2' = @{ Name='CrystalDiskInfo';    Desc='Disk SMART Health & Temperature';            Path="$_toolsRoot\Diagnostics\DiskInfo64S.exe" }
            '3' = @{ Name='CPU-Z';              Desc='CPU, RAM & Motherboard Details';              Path="$_toolsRoot\Diagnostics\cpuz_x64.exe" }
            '0' = @{ Name='Quick Diagnostics';  Desc='Live CPU/RAM/Disk/Net overview (in-console)'; Path='__BUILTIN__' }
        }
        $statusList2 = [ordered]@{
            '4' = @{ Name='Nmap';               Desc='Network Scanner (interactive profiles)';     Path="$_toolsRoot\NetworkTools\nmap.exe" }
            '5' = @{ Name='Wireshark Portable'; Desc='Packet Capture';                             Path="$_toolsRoot\NetworkTools\WiresharkPortable64\WiresharkPortable64.exe" }
            '6' = @{ Name='TCPView';            Desc='Live Connection Viewer (GUI + Console)';    Path="$_toolsRoot\SysAdmin\Sysinternals_Suite\tcpview64.exe" }
        }
        $statusList3 = [ordered]@{
            '7' = @{ Name='AdwCleaner';         Desc='Adware & PUP Removal (portable)';           Path="$_toolsRoot\Security\adwcleaner.exe" }
            '8' = @{ Name='RKill';              Desc='Kill malware processes before scanning';    Path="$_toolsRoot\Security\rkill.exe" }
            '9' = @{ Name='Malwarebytes';       Desc='Full Scanner (install/scan/uninstall)';    Path="$_toolsRoot\Security\MalwareBytes.exe" }
        }
        $statusList4 = [ordered]@{
            'A' = @{ Name='TestDisk';           Desc='Partition & Boot Repair';                   Path="$_toolsRoot\Recovery\testdisk-7.3-WIP\testdisk_win.exe" }
            'B' = @{ Name='Recuva 64';          Desc='Deleted File Recovery';                     Path="$_toolsRoot\Recovery\recuva64.exe" }
        }
        $statusList5 = [ordered]@{
            'C' = @{ Name='Process Explorer';   Desc='Advanced Task Manager (auto-elevated)';    Path="$_toolsRoot\SysAdmin\Sysinternals_Suite\procexp64.exe" }
            'D' = @{ Name='Autoruns';           Desc='Startup Manager + CSV export';             Path="$_toolsRoot\SysAdmin\Sysinternals_Suite\Autoruns64.exe" }
            'E' = @{ Name='Process Monitor';    Desc='System Activity (GUI + 30s capture)';      Path="$_toolsRoot\SysAdmin\Sysinternals_Suite\Procmon64.exe" }
            'F' = @{ Name='NirLauncher';        Desc='Full NirSoft Suite (passwords, network...)'; Path="$_toolsRoot\SysAdmin\NirSoft\NirLauncher.exe" }
        }
        $statusList6 = [ordered]@{
            'G' = @{ Name='Chrome Portable';    Desc='Standalone Browser (normal/incognito/URL)'; Path="$_toolsRoot\Browser\chrome-win\chrome.exe" }
        }

        # Render function for each group
        $renderGroup = {
            param($group)
            foreach ($key in $group.Keys) {
                $t = $group[$key]
                $found = ($t.Path -eq '__BUILTIN__') -or (Test-Path $t.Path)
                $sc     = if ($found) { 'Green'   } else { 'DarkGray' }
                $status = if ($found) { ' OK ' }    else { ' -- ' }
                c  '  | '   Magenta
                c  " $key "  Yellow
                c  " $status " $sc
                c  (" {0,-18}" -f $t.Name) White
                cn ("  {0}" -f $t.Desc) DarkGray
            }
        }

        & $renderGroup $statusList
        sep
        & $renderGroup $statusList2
        sep
        & $renderGroup $statusList3
        sep
        & $renderGroup $statusList4
        sep
        & $renderGroup $statusList5
        sep
        & $renderGroup $statusList6

        nl
        cn '  | [Q]  Back to main menu' DarkGray
        cn '  +------------------------------------------------------------------+' Magenta
        nl
        c '  Launch: ' DarkGray
        $choice = (Read-Host).Trim().ToUpper()

        if ($choice -eq 'Q' -or $choice -eq '') { return }

        # ================================================================
        # DIRECT SWITCH DISPATCH -- no '& $fn' string resolution.
        # Each function is called DIRECTLY by name, which PowerShell
        # resolves at the call site. This eliminates scope/non-terminating
        # error issues that plagued the '& $fn' pattern.
        # ================================================================
        $ErrorActionPreference = 'Stop'
        try {
            switch ($choice) {
                '1' { Start-HWiNFO }
                '2' { Start-CrystalDiskInfo }
                '3' { Start-CPUZ }
                '0' { Show-QuickDiagnostics }
                '4' { Start-Nmap }
                '5' { Start-Wireshark }
                '6' { Start-TCPView }
                '7' { Start-AdwCleaner }
                '8' { Start-RKill }
                '9' { Start-Malwarebytes }
                'A' { Start-TestDisk }
                'B' { Start-Recuva }
                'C' { Start-ProcessExplorer }
                'D' { Start-Autoruns }
                'E' { Start-ProcMon }
                'F' { Start-NirLauncher }
                'G' { Start-ChromePortable }
                default { cn '  [!] Invalid option.' Red; Start-Sleep 1 }
            }
        } catch {
            cn "  [X] Error: $_" Red
            cn "  Stack: $($_.ScriptStackTrace)" DarkGray
            Write-ToolError 'Dispatch' $_.ToString() $_.ScriptStackTrace
            Pause-ForKey
        }
        $ErrorActionPreference = 'Continue'
    }
}

# ==============================================================================
# ENTRY POINT
# ==============================================================================
if ($MyInvocation.InvocationName -ne '.') {
    Show-ToolsMenu
}
