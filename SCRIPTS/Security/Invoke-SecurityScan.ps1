# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Ousman Dorley. See LICENSE at the repository root.
<#
.SYNOPSIS
    FieldOps Pro - Enterprise Security Posture Engine v1.0
.DESCRIPTION
    15-section deep security analysis: firmware integrity, Defender deep audit,
    ASR rules, identity & access, privilege escalation vectors, persistence
    mechanisms, attack surface, encryption, patch compliance, network security,
    browser security, PowerShell security, compliance scoring, threat indicators,
    and active defense status. Interactive hardening menu. Visual HTML report
    with attack surface heat map and risk matrix.
.NOTES
    Author  : FieldOps Pro
    Version : 1.0
    Requires: PowerShell 5.1, Administrator STRONGLY recommended
    Location: E:\SCRIPTS\Security\Invoke-SecurityScan.ps1
    Rules   : Pure ASCII. Dynamic paths. PS 5.1 only.
#>

#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ============================================================
# PATH SETUP & MODULES
# ============================================================
$ScriptRoot  = $PSScriptRoot
$ProjectRoot = Split-Path (Split-Path $ScriptRoot -Parent) -Parent
$CorePath    = Join-Path $ProjectRoot 'SCRIPTS\Core'
$ReportsPath = Join-Path $ProjectRoot 'REPORTS'
$LogsPath    = Join-Path $ProjectRoot 'LOGS'
if (-not (Test-Path $ReportsPath)) { New-Item -Path $ReportsPath -ItemType Directory -Force | Out-Null }
if (-not (Test-Path $LogsPath))    { New-Item -Path $LogsPath -ItemType Directory -Force | Out-Null }

$LoggerPath = Join-Path $CorePath 'Logger.psm1'
if (Test-Path $LoggerPath) { Import-Module $LoggerPath -Force -DisableNameChecking }
else { function Write-Log { param([string]$Message,[string]$Level='INFO'); Write-Host "[$(Get-Date -Format 'HH:mm:ss')] [$Level] $Message" } }
$UtilsPath = Join-Path $CorePath 'Utils.psm1'
if (Test-Path $UtilsPath) { Import-Module $UtilsPath -Force -DisableNameChecking }

# ============================================================
# RESULTS ENGINE
# ============================================================
$script:Results    = [System.Collections.ArrayList]::new()
$script:Findings   = [System.Collections.ArrayList]::new()
$script:SectionScores = [System.Collections.ArrayList]::new()
$script:CheckCount = 0
$script:Stopwatch  = [System.Diagnostics.Stopwatch]::StartNew()
$script:IsAdmin    = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

function Convert-StatusToLogLevel { param([string]$S); switch ($S) { 'Pass' {'OK'} 'Warning' {'WARN'} 'Fail' {'ERROR'} 'Undetermined' {'WARN'} default {'INFO'} } }

function Add-Check {
    param([string]$Category,[string]$Check,[string]$Status,[string]$Value,[string]$Detail)
    $script:CheckCount++
    $null = $script:Results.Add([PSCustomObject]@{Number=$script:CheckCount;Category=$Category;Check=$Check;Status=$Status;Value=$Value;Detail=$Detail})
    $icon = switch ($Status) {'Pass'{'[PASS]'}'Warning'{'[WARN]'}'Fail'{'[FAIL]'}'Undetermined'{'[ -- ]'}default{'[INFO]'}}
    Write-Host "  $icon $Check : $Value" -ForegroundColor $(switch ($Status) {'Pass'{'Green'}'Warning'{'Yellow'}'Fail'{'Red'}'Undetermined'{'DarkYellow'}default{'Cyan'}})
    Write-Log -Message "$icon $Check = $Value | $Detail" -Level (Convert-StatusToLogLevel $Status)
}

function Add-Finding {
    param([string]$Severity,[string]$Title,[string]$Detail,[string]$Action,[array]$FixCommands,[int]$FixMinutes=5,[string]$CIS='')
    $null = $script:Findings.Add([PSCustomObject]@{Severity=$Severity;Title=$Title;Detail=$Detail;Action=$Action;FixCommands=$FixCommands;FixMinutes=$FixMinutes;CIS=$CIS})
}

function Save-SectionScore {
    param([string]$Section,[string]$Category)
    $catChecks = @($script:Results | Where-Object {$_.Category -eq $Category -and $_.Status -in @('Pass','Warning','Fail')})
    if ($catChecks.Count -eq 0) { return }
    $p = @($catChecks|Where-Object{$_.Status -eq 'Pass'}).Count
    $w = @($catChecks|Where-Object{$_.Status -eq 'Warning'}).Count
    $score = [math]::Round((($p+($w*0.5))/$catChecks.Count)*100,0)
    $null = $script:SectionScores.Add([PSCustomObject]@{Section=$Section;Score=$score;Checks=$catChecks.Count})
}

# ============================================================
# HEADER
# ============================================================
$Hostname  = $env:COMPUTERNAME
$Timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$DateHuman = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

Write-Host ''
Write-Host '============================================================' -ForegroundColor Magenta
Write-Host '  FieldOps Pro - Enterprise Security Posture Engine' -ForegroundColor Magenta
Write-Host "  Host: $Hostname | $DateHuman" -ForegroundColor Gray
if (-not $script:IsAdmin) { Write-Host '  WARNING: Not running as Administrator. Some checks limited.' -ForegroundColor Yellow }
Write-Host '============================================================' -ForegroundColor Magenta
Write-Host ''

# ============================================================
# [1/15] FIRMWARE & SYSTEM INTEGRITY
# ============================================================
Write-Host '[1/15] Firmware & System Integrity' -ForegroundColor White

# Secure Boot
try {
    $sb = Confirm-SecureBootUEFI -ErrorAction Stop
    Add-Check -Category 'Firmware' -Check 'Secure Boot' -Status $(if($sb){'Pass'}else{'Fail'}) `
        -Value $(if($sb){'Enabled'}else{'DISABLED'}) -Detail 'UEFI Secure Boot prevents unsigned bootloaders'
    if (-not $sb) {
        Add-Finding -Severity 'Critical' -Title 'Secure Boot DISABLED' `
            -Detail 'System vulnerable to bootkit/rootkit attacks.' `
            -Action 'Enable Secure Boot in BIOS/UEFI firmware settings.' `
            -FixCommands @(@{Desc='Check current Secure Boot state';Cmd='Confirm-SecureBootUEFI'}) -FixMinutes 10 -CIS 'CIS 1.1.1'
    }
} catch { Add-Check -Category 'Firmware' -Check 'Secure Boot' -Status 'Undetermined' -Value 'Cannot query (non-UEFI or not admin)' -Detail $_.Exception.Message }

# TPM
try {
    $tpm = Get-Tpm -ErrorAction Stop
    $tpmReady = $tpm.TpmReady
    $tpmPresent = $tpm.TpmPresent
    $tpmVersion = ''
    try { $tpmWmi = Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftTpm' -ClassName Win32_Tpm -ErrorAction Stop; $tpmVersion = $tpmWmi.SpecVersion.Split(',')[0].Trim() } catch {}
    $st = if ($tpmPresent -and $tpmReady) {'Pass'} elseif ($tpmPresent) {'Warning'} else {'Fail'}
    Add-Check -Category 'Firmware' -Check 'TPM' -Status $st `
        -Value "Present: $tpmPresent | Ready: $tpmReady$(if($tpmVersion){" | v$tpmVersion"})" `
        -Detail 'Required for BitLocker, Windows Hello, Credential Guard'
    if (-not $tpmPresent) {
        Add-Finding -Severity 'Critical' -Title 'No TPM detected' -Detail 'BitLocker and Credential Guard require TPM.' `
            -Action 'Enable TPM in BIOS.' -FixCommands @(@{Desc='Check TPM status';Cmd='Get-Tpm | Format-List *'}) -FixMinutes 10 -CIS 'CIS 1.1.2'
    }
} catch { Add-Check -Category 'Firmware' -Check 'TPM' -Status 'Undetermined' -Value 'Cannot query' -Detail $_.Exception.Message }

# Virtualization-Based Security (VBS)
try {
    $dg = Get-CimInstance -ClassName Win32_DeviceGuard -Namespace 'root\Microsoft\Windows\DeviceGuard' -ErrorAction Stop
    $vbsStatus = $dg.VirtualizationBasedSecurityStatus
    $vbsRunning = ($vbsStatus -eq 2)
    $hvciRunning = ($dg.SecurityServicesRunning -contains 1)
    $credGuard = ($dg.SecurityServicesRunning -contains 2)

    Add-Check -Category 'Firmware' -Check 'VBS (Virtualization-Based Security)' -Status $(if($vbsRunning){'Pass'}else{'Warning'}) `
        -Value $(if($vbsRunning){'Running'}else{'Not running'}) -Detail "Status code: $vbsStatus"
    Add-Check -Category 'Firmware' -Check 'HVCI (Memory Integrity)' -Status $(if($hvciRunning){'Pass'}else{'Warning'}) `
        -Value $(if($hvciRunning){'Enabled'}else{'Disabled'}) -Detail 'Hypervisor-enforced Code Integrity'
    Add-Check -Category 'Firmware' -Check 'Credential Guard' -Status $(if($credGuard){'Pass'}else{'Warning'}) `
        -Value $(if($credGuard){'Running'}else{'Not running'}) -Detail 'Protects NTLM hashes and Kerberos tickets'

    if (-not $hvciRunning) {
        Add-Finding -Severity 'Warning' -Title 'HVCI (Memory Integrity) disabled' `
            -Detail 'Kernel-mode code integrity not enforced by hypervisor.' `
            -Action 'Enable via Windows Security > Device Security > Core Isolation.' `
            -FixCommands @(
                @{Desc='Enable HVCI via registry';Cmd="Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' -Name 'Enabled' -Value 1 -Type DWord -Force; Write-Host 'HVCI enabled. REBOOT REQUIRED.'"}
            ) -FixMinutes 5 -CIS 'CIS 18.8.5.1'
    }
    if (-not $credGuard) {
        Add-Finding -Severity 'Warning' -Title 'Credential Guard not running' `
            -Detail 'NTLM hash theft and pass-the-hash attacks possible.' `
            -Action 'Enable Credential Guard via Group Policy or registry.' `
            -FixCommands @(
                @{Desc='Check Credential Guard configuration';Cmd="Get-CimInstance -ClassName Win32_DeviceGuard -Namespace 'root\Microsoft\Windows\DeviceGuard' | Select-Object SecurityServicesConfigured, SecurityServicesRunning | Format-List"}
            ) -FixMinutes 15 -CIS 'CIS 18.8.5.2'
    }
} catch { Add-Check -Category 'Firmware' -Check 'VBS/DeviceGuard' -Status 'Undetermined' -Value 'Cannot query' -Detail $_.Exception.Message }

# Kernel DMA Protection
try {
    $dmaReg = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Kernel DMA Protection' -ErrorAction SilentlyContinue
    $dmaEnabled = if ($dmaReg -and $dmaReg.DeviceEnumerationPolicy -ne $null) { $dmaReg.DeviceEnumerationPolicy -eq 0 } else { $false }
    # Also check via SystemInfo
    $msinfo = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
    Add-Check -Category 'Firmware' -Check 'Kernel DMA Protection' -Status $(if($dmaEnabled){'Pass'}else{'Info'}) `
        -Value $(if($dmaEnabled){'Enabled'}else{'Not configured'}) -Detail 'Protects against Thunderbolt DMA attacks'
} catch {}

Save-SectionScore -Section 'Firmware' -Category 'Firmware'

# ============================================================
# [2/15] WINDOWS DEFENDER DEEP AUDIT
# ============================================================
Write-Host ''
Write-Host '[2/15] Windows Defender Deep Audit' -ForegroundColor White

try {
    $mpStatus = Get-MpComputerStatus -ErrorAction Stop
    $mpPref   = Get-MpPreference -ErrorAction Stop

    # Real-time protection
    $rtOn = $mpStatus.RealTimeProtectionEnabled
    Add-Check -Category 'Defender' -Check 'Real-Time Protection' -Status $(if($rtOn){'Pass'}else{'Fail'}) `
        -Value $(if($rtOn){'Active'}else{'DISABLED'}) -Detail 'Core antimalware engine'
    if (-not $rtOn) {
        Add-Finding -Severity 'Critical' -Title 'Defender Real-Time Protection DISABLED' `
            -Detail 'System has no active antimalware protection.' `
            -Action 'Enable immediately.' -FixCommands @(
                @{Desc='Enable real-time protection';Cmd='Set-MpPreference -DisableRealtimeMonitoring $false; Write-Host "Enabled"'}
            ) -FixMinutes 1 -CIS 'CIS 18.9.47.4.1'
    }

    # Cloud protection
    $cloudOn = $mpStatus.AntivirusEnabled -and (-not $mpPref.DisableBlockAtFirstSeen)
    Add-Check -Category 'Defender' -Check 'Cloud-Delivered Protection' -Status $(if($cloudOn){'Pass'}else{'Warning'}) `
        -Value $(if($cloudOn){'Enabled'}else{'Disabled'}) -Detail 'Cloud intelligence for zero-day detection'

    # Tamper protection
    $tamperOn = $mpStatus.IsTamperProtected
    Add-Check -Category 'Defender' -Check 'Tamper Protection' -Status $(if($tamperOn){'Pass'}else{'Warning'}) `
        -Value $(if($tamperOn){'Active'}else{'Disabled'}) -Detail 'Prevents malware from disabling Defender'
    if (-not $tamperOn) {
        Add-Finding -Severity 'Warning' -Title 'Tamper Protection disabled' `
            -Detail 'Malware can modify Defender settings.' `
            -Action 'Enable in Windows Security > Virus & Threat Protection > Manage Settings.' `
            -FixCommands @(@{Desc='Check tamper protection';Cmd='Get-MpComputerStatus | Select-Object IsTamperProtected, RealTimeProtectionEnabled | Format-List'}) -CIS 'CIS 18.9.47.12'
    }

    # Definitions age
    $defAge = ((Get-Date) - $mpStatus.AntivirusSignatureLastUpdated).Days
    $defSt = if ($defAge -le 1){'Pass'} elseif ($defAge -le 7){'Warning'} else {'Fail'}
    Add-Check -Category 'Defender' -Check 'Definition Age' -Status $defSt `
        -Value "$defAge day(s) old ($($mpStatus.AntivirusSignatureLastUpdated.ToString('yyyy-MM-dd')))" `
        -Detail "Version: $($mpStatus.AntivirusSignatureVersion)"
    if ($defAge -gt 7) {
        Add-Finding -Severity 'Critical' -Title "Defender definitions $defAge days old" `
            -Detail 'Antivirus signatures critically outdated.' -Action 'Update signatures.' `
            -FixCommands @(@{Desc='Update signatures';Cmd='Update-MpSignature; Write-Host "Update triggered"'}) -FixMinutes 3 -CIS 'CIS 18.9.47.9'
    }

    # Network protection
    $netProt = $mpPref.EnableNetworkProtection
    $npSt = switch ($netProt) { 1 {'Enabled'} 2 {'Audit'} default {'Disabled'} }
    Add-Check -Category 'Defender' -Check 'Network Protection' -Status $(if($netProt -eq 1){'Pass'}elseif($netProt -eq 2){'Warning'}else{'Warning'}) `
        -Value $npSt -Detail 'Blocks connections to malicious domains'

    # PUA Protection
    $puaMode = $mpPref.PUAProtection
    Add-Check -Category 'Defender' -Check 'PUA Protection' -Status $(if($puaMode -eq 1){'Pass'}else{'Warning'}) `
        -Value $(switch($puaMode){1{'Block'}2{'Audit'}default{'Disabled'}}) -Detail 'Potentially Unwanted Application blocking'

    # Controlled Folder Access
    $cfaMode = $mpPref.EnableControlledFolderAccess
    Add-Check -Category 'Defender' -Check 'Controlled Folder Access' -Status $(if($cfaMode -eq 1){'Pass'}elseif($cfaMode -eq 2){'Warning'}else{'Info'}) `
        -Value $(switch($cfaMode){1{'Enabled'}2{'Audit'}default{'Disabled'}}) -Detail 'Ransomware protection for user folders'

    # Exclusions audit
    $exPaths = @($mpPref.ExclusionPath)
    $exProcs = @($mpPref.ExclusionProcess)
    $exExts  = @($mpPref.ExclusionExtension)
    $totalEx = ($exPaths | Where-Object {$_}).Count + ($exProcs | Where-Object {$_}).Count + ($exExts | Where-Object {$_}).Count
    $exSt = if ($totalEx -eq 0){'Pass'} elseif ($totalEx -le 5){'Info'} else {'Warning'}
    Add-Check -Category 'Defender' -Check 'Exclusions' -Status $exSt `
        -Value "$totalEx exclusion(s)" -Detail "Paths: $(($exPaths|Where-Object{$_}).Count) | Processes: $(($exProcs|Where-Object{$_}).Count) | Extensions: $(($exExts|Where-Object{$_}).Count)"
    if ($totalEx -gt 10) {
        Add-Finding -Severity 'Warning' -Title "Excessive Defender exclusions ($totalEx)" `
            -Detail 'Large exclusion lists increase attack surface.' `
            -Action 'Review and remove unnecessary exclusions.' `
            -FixCommands @(@{Desc='List all exclusions';Cmd='Get-MpPreference | Select-Object ExclusionPath, ExclusionProcess, ExclusionExtension | Format-List'})
    }
} catch {
    Add-Check -Category 'Defender' -Check 'Windows Defender' -Status 'Undetermined' -Value 'Cannot query' -Detail $_.Exception.Message
}

Save-SectionScore -Section 'Defender' -Category 'Defender'

# ============================================================
# [3/15] ASR RULES (Attack Surface Reduction)
# ============================================================
Write-Host ''
Write-Host '[3/15] Attack Surface Reduction Rules' -ForegroundColor White

$asrRuleNames = @{
    '56a863a9-875e-4185-98a7-b882c64b5ce5' = 'Block abuse of exploited vulnerable signed drivers'
    '7674ba52-37eb-4a4f-a9a1-f0f9a1619a2c' = 'Block Adobe Reader from creating child processes'
    'd4f940ab-401b-4efc-aadc-ad5f3c50688a' = 'Block all Office applications from creating child processes'
    '9e6c4e1f-7d60-472f-ba1a-a39ef669e4b2' = 'Block credential stealing from lsass.exe'
    'be9ba2d9-53ea-4cdc-84e5-9b1eeee46550' = 'Block executable content from email client/webmail'
    '01443614-cd74-433a-b99e-2ecdc07bfc25' = 'Block executable files unless they meet criteria'
    '5beb7efe-fd9a-4556-801d-275e5ffc04cc' = 'Block execution of potentially obfuscated scripts'
    'd3e037e1-3eb8-44c8-a917-57927947596d' = 'Block JavaScript or VBScript from launching downloaded content'
    '3b576869-a4ec-4529-8536-b80a7769e899' = 'Block Office applications from creating executable content'
    '75668c1f-73b5-4cf0-bb93-3ecf5cb7cc84' = 'Block Office applications from injecting code into other processes'
    '26190899-1602-49e8-8b27-eb1d0a1ce869' = 'Block Office communication apps from creating child processes'
    'e6db77e5-3df2-4cf1-b95a-636979351e5b' = 'Block persistence through WMI event subscription'
    'b2b3f03d-6a65-4f7b-a9c7-1c7ef74a9ba4' = 'Block untrusted/unsigned processes from USB'
    '92e97fa1-2edf-4476-bdd6-9dd0b4dddc7b' = 'Block Win32 API calls from Office macros'
    'c1db55ab-c21a-4637-bb3f-a12568109d35' = 'Use advanced protection against ransomware'
}

try {
    $asrIds = @($mpPref.AttackSurfaceReductionRules_Ids)
    $asrActions = @($mpPref.AttackSurfaceReductionRules_Actions)
    $enabledCount = 0; $auditCount = 0; $disabledCount = 0

    foreach ($ruleId in $asrRuleNames.Keys) {
        $idx = -1
        for ($i = 0; $i -lt $asrIds.Count; $i++) {
            if ($asrIds[$i] -eq $ruleId) { $idx = $i; break }
        }
        $action = if ($idx -ge 0 -and $idx -lt $asrActions.Count) { $asrActions[$idx] } else { 0 }
        $actionStr = switch ([int]$action) { 1 {'Block'} 2 {'Audit'} 6 {'Warn'} default {'Not configured'} }

        switch ([int]$action) { 1 {$enabledCount++} 2 {$auditCount++} default {$disabledCount++} }

        $st = switch ([int]$action) { 1 {'Pass'} 2 {'Info'} default {'Warning'} }
        $ruleName = $asrRuleNames[$ruleId]
        # Shorten for display
        $shortName = if ($ruleName.Length -gt 55) { $ruleName.Substring(0, 52) + '...' } else { $ruleName }
        Add-Check -Category 'ASR' -Check "ASR - $shortName" -Status $st -Value $actionStr -Detail "ID: $ruleId"
    }

    if ($disabledCount -gt 5) {
        Add-Finding -Severity 'Warning' -Title "$disabledCount of $($asrRuleNames.Count) ASR rules not configured" `
            -Detail "Only $enabledCount blocking, $auditCount auditing, $disabledCount unconfigured." `
            -Action 'Enable critical ASR rules.' `
            -FixCommands @(
                @{Desc='Enable LSASS credential theft protection';Cmd="Add-MpPreference -AttackSurfaceReductionRules_Ids '9e6c4e1f-7d60-472f-ba1a-a39ef669e4b2' -AttackSurfaceReductionRules_Actions Enabled; Write-Host 'LSASS protection enabled'"}
                @{Desc='Enable ransomware protection';Cmd="Add-MpPreference -AttackSurfaceReductionRules_Ids 'c1db55ab-c21a-4637-bb3f-a12568109d35' -AttackSurfaceReductionRules_Actions Enabled; Write-Host 'Ransomware ASR enabled'"}
                @{Desc='Block Office child processes';Cmd="Add-MpPreference -AttackSurfaceReductionRules_Ids 'd4f940ab-401b-4efc-aadc-ad5f3c50688a' -AttackSurfaceReductionRules_Actions Enabled; Write-Host 'Office child process blocking enabled'"}
                @{Desc='View all ASR rule status';Cmd='Get-MpPreference | Select-Object AttackSurfaceReductionRules_Ids, AttackSurfaceReductionRules_Actions | Format-List'}
            ) -FixMinutes 3 -CIS 'CIS 18.9.47.5'
    }
} catch { Add-Check -Category 'ASR' -Check 'ASR Rules' -Status 'Undetermined' -Value 'Cannot query (Defender not available?)' -Detail $_.Exception.Message }

Save-SectionScore -Section 'ASR' -Category 'ASR'

# ============================================================
# [4/15] IDENTITY & ACCESS CONTROL
# ============================================================
Write-Host ''
Write-Host '[4/15] Identity & Access Control' -ForegroundColor White

# Local administrators
try {
    $admins = @(Get-LocalGroupMember -Group 'Administrators' -ErrorAction Stop)
    $adminNames = ($admins | ForEach-Object { $_.Name }) -join ', '
    $nonDefaultAdmins = @($admins | Where-Object { $_.Name -notmatch 'Administrator$' -and $_.Name -notmatch 'Domain Admins$' })
    $st = if ($admins.Count -le 2) {'Pass'} elseif ($admins.Count -le 4) {'Warning'} else {'Fail'}
    Add-Check -Category 'Identity' -Check 'Local Administrators' -Status $st `
        -Value "$($admins.Count) member(s)" -Detail $adminNames
    if ($admins.Count -gt 3) {
        Add-Finding -Severity 'Warning' -Title "$($admins.Count) local admin accounts" `
            -Detail "Members: $adminNames" -Action 'Review and remove unnecessary admin accounts.' `
            -FixCommands @(@{Desc='List admin group members';Cmd='Get-LocalGroupMember -Group "Administrators" | Format-Table Name, ObjectClass, PrincipalSource -AutoSize'}) -CIS 'CIS 2.3.1'
    }
} catch { Add-Check -Category 'Identity' -Check 'Local Administrators' -Status 'Undetermined' -Value 'Cannot query' -Detail $_.Exception.Message }

# Guest account
try {
    $guest = Get-LocalUser -Name 'Guest' -ErrorAction Stop
    $guestDisabled = -not $guest.Enabled
    Add-Check -Category 'Identity' -Check 'Guest Account' -Status $(if($guestDisabled){'Pass'}else{'Fail'}) `
        -Value $(if($guestDisabled){'Disabled'}else{'ENABLED'}) -Detail 'CIS requires Guest account disabled'
    if (-not $guestDisabled) {
        Add-Finding -Severity 'Critical' -Title 'Guest account ENABLED' -Detail 'Unauthorized access possible.' `
            -Action 'Disable the Guest account.' `
            -FixCommands @(@{Desc='Disable Guest';Cmd='Disable-LocalUser -Name "Guest"; Write-Host "Guest disabled"'}) -FixMinutes 1 -CIS 'CIS 2.3.1.1'
    }
} catch {}

# Auto-logon check
try {
    $alReg = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -ErrorAction SilentlyContinue
    $autoLogon = ($alReg.AutoAdminLogon -eq '1')
    $defaultPw = if ($alReg.DefaultPassword) { $true } else { $false }
    Add-Check -Category 'Identity' -Check 'Auto-Logon' -Status $(if(-not $autoLogon){'Pass'}else{'Fail'}) `
        -Value $(if($autoLogon){"ENABLED (user: $($alReg.DefaultUserName))"}else{'Disabled'}) `
        -Detail $(if($defaultPw){'WARNING: Cleartext password in registry'}else{'No stored password'})
    if ($autoLogon) {
        Add-Finding -Severity 'Critical' -Title 'Auto-logon enabled' `
            -Detail "User: $($alReg.DefaultUserName)$(if($defaultPw){' with cleartext password in registry'})" `
            -Action 'Disable auto-logon.' `
            -FixCommands @(@{Desc='Disable auto-logon';Cmd="Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name 'AutoAdminLogon' -Value '0'; Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name 'DefaultPassword' -ErrorAction SilentlyContinue; Write-Host 'Auto-logon disabled'"}) -FixMinutes 1 -CIS 'CIS 18.4.1'
    }
} catch {}

# LSA Protection
try {
    $lsaReg = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -ErrorAction SilentlyContinue
    $lsaPPL = ($lsaReg.RunAsPPL -eq 1)
    Add-Check -Category 'Identity' -Check 'LSA Protection (PPL)' -Status $(if($lsaPPL){'Pass'}else{'Warning'}) `
        -Value $(if($lsaPPL){'Enabled'}else{'Disabled'}) -Detail 'Protects LSASS from credential dumping (Mimikatz)'
    if (-not $lsaPPL) {
        Add-Finding -Severity 'Warning' -Title 'LSA Protection (RunAsPPL) not enabled' `
            -Detail 'LSASS process not protected. Credential dumping tools like Mimikatz can extract hashes.' `
            -Action 'Enable LSA protection.' `
            -FixCommands @(@{Desc='Enable LSA PPL';Cmd="Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name 'RunAsPPL' -Value 1 -Type DWord -Force; Write-Host 'LSA PPL enabled. REBOOT REQUIRED.'"}) -FixMinutes 2 -CIS 'CIS 18.3.1'
    }
} catch {}

# Stored credentials
try {
    $cmdkey = cmdkey /list 2>$null
    $storedCreds = @($cmdkey | Where-Object { $_ -match 'Target:' })
    $st = if ($storedCreds.Count -eq 0) {'Pass'} elseif ($storedCreds.Count -le 3) {'Info'} else {'Warning'}
    Add-Check -Category 'Identity' -Check 'Stored Credentials (cmdkey)' -Status $st `
        -Value "$($storedCreds.Count) stored credential(s)" -Detail 'Credentials Manager vault'
} catch {}

# Azure AD / Domain join status
try {
    $dsreg = dsregcmd /status 2>$null | Out-String
    $azureJoined = if ($dsreg -match 'AzureAdJoined\s*:\s*YES') {'Yes'} else {'No'}
    $domainJoined = if ($dsreg -match 'DomainJoined\s*:\s*YES') {'Yes'} else {'No'}
    $workplaceJoined = if ($dsreg -match 'WorkplaceJoined\s*:\s*YES') {'Yes'} else {'No'}
    Add-Check -Category 'Identity' -Check 'Directory Join Status' -Status 'Info' `
        -Value "Azure AD: $azureJoined | Domain: $domainJoined | Workplace: $workplaceJoined" `
        -Detail 'Enterprise directory membership'
} catch {}

Save-SectionScore -Section 'Identity' -Category 'Identity'

# ============================================================
# [5/15] PRIVILEGE ESCALATION VECTORS
# ============================================================
Write-Host ''
Write-Host '[5/15] Privilege Escalation Vectors' -ForegroundColor White

# UAC Level
try {
    $uacReg = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction Stop
    $uacLevel = $uacReg.ConsentPromptBehaviorAdmin
    $uacDesc = switch ($uacLevel) { 0 {'Elevate without prompting (DANGEROUS)'} 1 {'Prompt on secure desktop'} 2 {'Prompt on secure desktop (default)'} 3 {'Prompt for credentials'} 4 {'Prompt for consent'} 5 {'Prompt for consent (non-Windows)'} default {"Unknown ($uacLevel)"} }
    $uacSt = if ($uacLevel -ge 1 -and $uacLevel -le 5) {'Pass'} else {'Fail'}
    Add-Check -Category 'PrivEsc' -Check 'UAC Level' -Status $uacSt -Value $uacDesc -Detail "ConsentPromptBehaviorAdmin: $uacLevel"
    if ($uacLevel -eq 0) {
        Add-Finding -Severity 'Critical' -Title 'UAC disabled (elevate without prompt)' `
            -Detail 'Any program can get admin rights silently.' `
            -Action 'Set UAC to prompt.' `
            -FixCommands @(@{Desc='Set UAC to prompt on secure desktop';Cmd="Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'ConsentPromptBehaviorAdmin' -Value 2; Write-Host 'UAC set to prompt'"}) -FixMinutes 1 -CIS 'CIS 2.3.17.1'
    }
} catch {}

# AlwaysInstallElevated
try {
    $aie1 = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Installer' -ErrorAction SilentlyContinue).AlwaysInstallElevated
    $aie2 = (Get-ItemProperty -Path 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\Installer' -ErrorAction SilentlyContinue).AlwaysInstallElevated
    $aieVuln = ($aie1 -eq 1 -and $aie2 -eq 1)
    Add-Check -Category 'PrivEsc' -Check 'AlwaysInstallElevated' -Status $(if(-not $aieVuln){'Pass'}else{'Fail'}) `
        -Value $(if($aieVuln){'VULNERABLE - MSI installs run as SYSTEM'}else{'Secure'}) -Detail "HKLM: $aie1 | HKCU: $aie2"
    if ($aieVuln) {
        Add-Finding -Severity 'Critical' -Title 'AlwaysInstallElevated ENABLED' `
            -Detail 'Any user can create a malicious .msi and get SYSTEM privileges.' `
            -Action 'Disable AlwaysInstallElevated.' `
            -FixCommands @(@{Desc='Disable AlwaysInstallElevated';Cmd="Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Installer' -Name 'AlwaysInstallElevated' -ErrorAction SilentlyContinue; Remove-ItemProperty -Path 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\Installer' -Name 'AlwaysInstallElevated' -ErrorAction SilentlyContinue; Write-Host 'Disabled'"}) -FixMinutes 1
    }
} catch {}

# Unquoted Service Paths
try {
    $services = Get-CimInstance Win32_Service -ErrorAction Stop | Where-Object { $_.PathName -and $_.PathName -notmatch '^"' -and $_.PathName -match '\s' -and $_.PathName -notmatch '^[A-Za-z]:\\Windows\\' }
    $vulnServices = @($services | Where-Object { $_.PathName -match '^[A-Za-z]:\\.*\s.*\.exe' })
    Add-Check -Category 'PrivEsc' -Check 'Unquoted Service Paths' -Status $(if($vulnServices.Count -eq 0){'Pass'}else{'Warning'}) `
        -Value "$($vulnServices.Count) vulnerable service(s)" -Detail 'Unquoted paths with spaces allow DLL/EXE hijacking'
    if ($vulnServices.Count -gt 0) {
        $svcList = ($vulnServices | Select-Object -First 5 | ForEach-Object { "$($_.Name) -> $($_.PathName)" }) -join '; '
        Add-Finding -Severity 'Warning' -Title "$($vulnServices.Count) unquoted service path(s)" `
            -Detail $svcList -Action 'Quote the service binary paths.' `
            -FixCommands @(@{Desc='List all vulnerable services';Cmd="Get-CimInstance Win32_Service | Where-Object { `$_.PathName -and `$_.PathName -notmatch '^`"' -and `$_.PathName -match '\s' -and `$_.PathName -notmatch '^[A-Za-z]:\\\\Windows\\\\' } | Format-Table Name, StartMode, PathName -AutoSize"})
    }
} catch {}

# PowerShell Execution Policy
try {
    $execPol = Get-ExecutionPolicy
    $st = switch ($execPol) { 'Restricted' {'Pass'} 'AllSigned' {'Pass'} 'RemoteSigned' {'Pass'} default {'Warning'} }
    Add-Check -Category 'PrivEsc' -Check 'PS Execution Policy' -Status $st -Value $execPol.ToString() -Detail 'Script execution restriction level'
} catch {}

Save-SectionScore -Section 'PrivEsc' -Category 'PrivEsc'

# ============================================================
# [6/15] PERSISTENCE MECHANISMS
# ============================================================
Write-Host ''
Write-Host '[6/15] Persistence Mechanism Audit' -ForegroundColor White

# Scheduled Tasks (non-Microsoft)
$script:SuspiciousTasks = [System.Collections.ArrayList]::new()
try {
    $tasks = @(Get-ScheduledTask -ErrorAction Stop | Where-Object {
        $_.TaskPath -notmatch '\\Microsoft\\' -and $_.State -ne 'Disabled' -and $_.TaskName -notmatch '^User_Feed|^OneDrive|^GoogleUpdate'
    })
    $suspCount = 0
    foreach ($t in $tasks) {
        try {
            $actions = @($t.Actions)
            foreach ($a in $actions) {
                $exe = if ($a.Execute) { $a.Execute } else { '' }
                # Flag tasks running from unusual locations
                if ($exe -match '\\Temp\\|\\AppData\\Local\\Temp|\\Downloads\\|powershell.*-enc|cmd.*/c.*http') {
                    $suspCount++
                    $null = $script:SuspiciousTasks.Add([PSCustomObject]@{Name=$t.TaskName;Path=$t.TaskPath;Execute=$exe;State=$t.State.ToString()})
                }
            }
        } catch {}
    }
    Add-Check -Category 'Persistence' -Check 'Scheduled Tasks (non-MS)' -Status $(if($tasks.Count -le 20){'Pass'}else{'Info'}) `
        -Value "$($tasks.Count) active | $suspCount suspicious" -Detail 'Non-Microsoft scheduled tasks'
    if ($suspCount -gt 0) {
        Add-Finding -Severity 'Warning' -Title "$suspCount suspicious scheduled task(s)" `
            -Detail 'Tasks running from Temp/Downloads or using encoded PowerShell.' `
            -Action 'Review and remove suspicious tasks.' `
            -FixCommands @(@{Desc='List suspicious tasks';Cmd="Get-ScheduledTask | Where-Object { `$_.TaskPath -notmatch '\\\\Microsoft\\\\' -and `$_.State -ne 'Disabled' } | ForEach-Object { `$a = `$_.Actions | Select-Object -First 1; [PSCustomObject]@{Name=`$_.TaskName;Path=`$_.TaskPath;Execute=`$a.Execute;State=`$_.State} } | Format-Table -AutoSize"})
    }
} catch {}

# Run/RunOnce Registry
$runPaths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
)
$totalRunEntries = 0
foreach ($rp in $runPaths) {
    try {
        if (Test-Path $rp) {
            $entries = Get-ItemProperty -Path $rp -ErrorAction SilentlyContinue
            $props = @($entries.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' })
            $totalRunEntries += $props.Count
        }
    } catch {}
}
Add-Check -Category 'Persistence' -Check 'Registry Run/RunOnce' -Status $(if($totalRunEntries -le 10){'Pass'}elseif($totalRunEntries -le 20){'Info'}else{'Warning'}) `
    -Value "$totalRunEntries entries across 4 keys" -Detail 'Auto-start programs via registry'

# Startup folder
$startupPaths = @(
    "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup",
    "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Startup"
)
$startupItems = 0
foreach ($sp in $startupPaths) {
    if (Test-Path $sp) {
        $startupItems += @(Get-ChildItem $sp -File -ErrorAction SilentlyContinue).Count
    }
}
Add-Check -Category 'Persistence' -Check 'Startup Folder Items' -Status $(if($startupItems -le 3){'Pass'}else{'Info'}) `
    -Value "$startupItems file(s)" -Detail 'User and common startup folders'

# Services with unusual paths
try {
    $suspServices = @(Get-CimInstance Win32_Service -ErrorAction Stop |
        Where-Object { $_.PathName -and ($_.PathName -match '\\Temp\\|\\AppData\\|\\Downloads\\|\\Users\\.*\\Desktop\\') })
    Add-Check -Category 'Persistence' -Check 'Services from unusual paths' -Status $(if($suspServices.Count -eq 0){'Pass'}else{'Warning'}) `
        -Value "$($suspServices.Count) found" -Detail 'Services running from Temp, AppData, or Desktop'
    if ($suspServices.Count -gt 0) {
        Add-Finding -Severity 'Warning' -Title "$($suspServices.Count) service(s) from unusual locations" `
            -Detail (($suspServices | Select-Object -First 3 | ForEach-Object { "$($_.Name): $($_.PathName)" }) -join '; ') `
            -Action 'Investigate these services.' `
            -FixCommands @(@{Desc='List unusual services';Cmd="Get-CimInstance Win32_Service | Where-Object { `$_.PathName -match '\\\\Temp\\\\|\\\\AppData\\\\|\\\\Downloads\\\\' } | Format-Table Name, State, PathName -AutoSize"})
    }
} catch {}

Save-SectionScore -Section 'Persistence' -Category 'Persistence'

# ============================================================
# [7/15] ATTACK SURFACE
# ============================================================
Write-Host ''
Write-Host '[7/15] Attack Surface Analysis' -ForegroundColor White

# SMBv1
try {
    $smb1 = (Get-SmbServerConfiguration -ErrorAction Stop).EnableSMB1Protocol
    Add-Check -Category 'Surface' -Check 'SMBv1 Protocol' -Status $(if(-not $smb1){'Pass'}else{'Fail'}) `
        -Value $(if($smb1){'ENABLED (vulnerable)'}else{'Disabled'}) -Detail 'WannaCry/EternalBlue attack vector'
    if ($smb1) {
        Add-Finding -Severity 'Critical' -Title 'SMBv1 ENABLED' `
            -Detail 'Vulnerable to WannaCry, EternalBlue, and other SMB exploits.' `
            -Action 'Disable SMBv1 immediately.' `
            -FixCommands @(@{Desc='Disable SMBv1';Cmd='Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force; Write-Host "SMBv1 disabled"'}) -FixMinutes 1 -CIS 'CIS 18.3.3'
    }
} catch {}

# RDP Status
try {
    $rdpReg = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -ErrorAction SilentlyContinue
    $rdpEnabled = ($rdpReg.fDenyTSConnections -eq 0)
    $nla = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -ErrorAction SilentlyContinue).UserAuthentication
    Add-Check -Category 'Surface' -Check 'Remote Desktop (RDP)' -Status $(if(-not $rdpEnabled){'Pass'}elseif($nla -eq 1){'Warning'}else{'Fail'}) `
        -Value "$(if($rdpEnabled){'Enabled'}else{'Disabled'}) | NLA: $(if($nla -eq 1){'Required'}else{'Not required'})" `
        -Detail 'Remote Desktop Protocol access'
    if ($rdpEnabled -and $nla -ne 1) {
        Add-Finding -Severity 'Warning' -Title 'RDP enabled without NLA' `
            -Detail 'Network Level Authentication not required. Brute force possible.' `
            -Action 'Enable NLA for RDP.' `
            -FixCommands @(@{Desc='Enable NLA';Cmd="Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name 'UserAuthentication' -Value 1; Write-Host 'NLA enabled'"}) -CIS 'CIS 18.9.65.3.9.1'
    }
} catch {}

# WinRM
try {
    $winrm = Get-Service WinRM -ErrorAction SilentlyContinue
    $winrmRunning = ($winrm -and $winrm.Status -eq 'Running')
    Add-Check -Category 'Surface' -Check 'WinRM Service' -Status $(if(-not $winrmRunning){'Pass'}else{'Info'}) `
        -Value $(if($winrmRunning){'Running'}else{'Stopped'}) -Detail 'Windows Remote Management'
} catch {}

# Remote Registry
try {
    $remReg = Get-Service RemoteRegistry -ErrorAction SilentlyContinue
    $rrRunning = ($remReg -and $remReg.Status -eq 'Running')
    Add-Check -Category 'Surface' -Check 'Remote Registry' -Status $(if(-not $rrRunning){'Pass'}else{'Fail'}) `
        -Value $(if($rrRunning){'RUNNING'}else{'Stopped'}) -Detail 'Allows remote registry modification'
    if ($rrRunning) {
        Add-Finding -Severity 'Warning' -Title 'Remote Registry service running' `
            -Detail 'Registry can be modified remotely.' `
            -Action 'Stop and disable Remote Registry.' `
            -FixCommands @(@{Desc='Stop and disable';Cmd='Stop-Service RemoteRegistry -Force; Set-Service RemoteRegistry -StartupType Disabled; Write-Host "Disabled"'}) -CIS 'CIS 5.27'
    }
} catch {}

# Open listening ports
try {
    $listeners = @(Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object { $_.LocalAddress -ne '127.0.0.1' -and $_.LocalAddress -ne '::1' })
    Add-Check -Category 'Surface' -Check 'Open Listening Ports' -Status $(if($listeners.Count -le 10){'Pass'}elseif($listeners.Count -le 20){'Info'}else{'Warning'}) `
        -Value "$($listeners.Count) port(s) exposed" -Detail 'Ports accepting connections from network'
} catch {}

Save-SectionScore -Section 'Surface' -Category 'Surface'

# ============================================================
# [8/15] ENCRYPTION
# ============================================================
Write-Host ''
Write-Host '[8/15] Encryption Status' -ForegroundColor White
try {
    $null = Get-Command Get-BitLockerVolume -ErrorAction Stop
    $blVols = @(Get-BitLockerVolume -ErrorAction Stop)
    foreach ($bv in $blVols) {
        try {
            $isOn = ($bv.ProtectionStatus -eq 'On')
            $isOs = ($bv.VolumeType -eq 'OperatingSystem')
            $method = if ($bv.EncryptionMethod) {$bv.EncryptionMethod.ToString()} else {'None'}
            $keyTypes = if ($bv.KeyProtector) { ($bv.KeyProtector | ForEach-Object {$_.KeyProtectorType.ToString()}) -join ', ' } else {'None'}

            $st = if ($isOn) {'Pass'} elseif ($isOs) {'Fail'} else {'Warning'}
            Add-Check -Category 'Encryption' -Check "BitLocker $($bv.MountPoint) ($($bv.VolumeType))" `
                -Status $st -Value "$(if($isOn){'Encrypted'}else{'NOT encrypted'}) | $method" -Detail "Keys: $keyTypes"

            # Check if recovery key is backed to AD/AAD
            $hasRecoveryPw = ($bv.KeyProtector | Where-Object {$_.KeyProtectorType -eq 'RecoveryPassword'})
            if ($isOn -and -not $hasRecoveryPw) {
                Add-Finding -Severity 'Warning' -Title "BitLocker $($bv.MountPoint) - no recovery password" `
                    -Detail 'Recovery password not set. Data loss risk if TPM fails.' `
                    -Action 'Add a recovery password protector.' `
                    -FixCommands @(@{Desc='Add recovery password';Cmd="Add-BitLockerKeyProtector -MountPoint '$($bv.MountPoint)' -RecoveryPasswordProtector; Write-Host 'Recovery password added'"})
            }
        } catch {}
    }
} catch { Add-Check -Category 'Encryption' -Check 'BitLocker' -Status 'Undetermined' -Value 'Cannot query' -Detail $_.Exception.Message }

Save-SectionScore -Section 'Encryption' -Category 'Encryption'

# ============================================================
# [9/15] PATCH COMPLIANCE
# ============================================================
Write-Host ''
Write-Host '[9/15] Patch Compliance' -ForegroundColor White

# OS Build / Version
try {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $osBuild = $os.BuildNumber
    $osVer = $os.Version
    Add-Check -Category 'Patching' -Check 'OS Version' -Status 'Info' -Value "$($os.Caption) ($osVer)" -Detail "Build: $osBuild"
} catch {}

# Last Windows Update
try {
    $lastHF = Get-HotFix -ErrorAction Stop | Sort-Object InstalledOn -Descending | Select-Object -First 1
    $daysSinceUpdate = if ($lastHF.InstalledOn) { ((Get-Date) - $lastHF.InstalledOn).Days } else { 999 }
    $st = if ($daysSinceUpdate -le 30) {'Pass'} elseif ($daysSinceUpdate -le 60) {'Warning'} else {'Fail'}
    Add-Check -Category 'Patching' -Check 'Last Windows Update' -Status $st `
        -Value "$daysSinceUpdate day(s) ago ($($lastHF.HotFixID) on $($lastHF.InstalledOn.ToString('yyyy-MM-dd')))" `
        -Detail $lastHF.Description
    if ($daysSinceUpdate -gt 60) {
        Add-Finding -Severity 'Critical' -Title "No updates for $daysSinceUpdate days" `
            -Detail "Last update: $($lastHF.HotFixID) on $($lastHF.InstalledOn.ToString('yyyy-MM-dd'))" `
            -Action 'Run Windows Update immediately.' `
            -FixCommands @(
                @{Desc='Check for updates';Cmd='Start-Process "ms-settings:windowsupdate"; Write-Host "Opening Windows Update..."'}
                @{Desc='Force update scan';Cmd='usoclient StartInteractiveScan; Write-Host "Update scan initiated"'}
            ) -FixMinutes 30 -CIS 'CIS 18.9.101'
    }
} catch {}

# PowerShell version
$psVer = $PSVersionTable.PSVersion.ToString()
$psOld = ($PSVersionTable.PSVersion.Major -lt 5)
Add-Check -Category 'Patching' -Check 'PowerShell Version' -Status $(if(-not $psOld){'Pass'}else{'Warning'}) `
    -Value "v$psVer" -Detail 'PS 5.1+ required for modern security features'

# .NET Versions
try {
    $dotnet = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction SilentlyContinue
    $dotnetVer = if ($dotnet) { $dotnet.Version } else { 'Unknown' }
    Add-Check -Category 'Patching' -Check '.NET Framework' -Status 'Info' -Value "v$dotnetVer" -Detail '.NET 4.x version'
} catch {}

Save-SectionScore -Section 'Patching' -Category 'Patching'

# ============================================================
# [10/15] NETWORK SECURITY
# ============================================================
Write-Host ''
Write-Host '[10/15] Network Security' -ForegroundColor White

# Firewall
try {
    $fwProfiles = @(Get-NetFirewallProfile -ErrorAction Stop)
    foreach ($fw in $fwProfiles) {
        Add-Check -Category 'NetSec' -Check "Firewall ($($fw.Name))" -Status $(if($fw.Enabled){'Pass'}else{'Fail'}) `
            -Value $(if($fw.Enabled){'Enabled'}else{'DISABLED'}) -Detail "In: $($fw.DefaultInboundAction) | Out: $($fw.DefaultOutboundAction)"
        if (-not $fw.Enabled) {
            Add-Finding -Severity 'Critical' -Title "$($fw.Name) firewall DISABLED" -Detail 'No firewall protection.' `
                -Action 'Enable firewall.' -FixCommands @(@{Desc="Enable $($fw.Name) firewall";Cmd="Set-NetFirewallProfile -Profile $($fw.Name) -Enabled True; Write-Host 'Enabled'"}) -FixMinutes 1 -CIS 'CIS 9.1.1'
        }
    }
} catch {}

# Wi-Fi security protocol
try {
    $wl = netsh wlan show interfaces 2>$null | Out-String
    $wifiAuth = if ($wl -match '(?:Authentication|Authentification)\s*:\s*(.+)') {$Matches[1].Trim()} else {$null}
    if ($wifiAuth) {
        $wifiSecure = ($wifiAuth -match 'WPA3|WPA2')
        Add-Check -Category 'NetSec' -Check 'WiFi Security Protocol' -Status $(if($wifiSecure){'Pass'}else{'Warning'}) `
            -Value $wifiAuth -Detail 'WPA3 is recommended, WPA2 minimum'
    }
} catch {}

# DNS-over-HTTPS
try {
    $dohReg = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters' -ErrorAction SilentlyContinue
    $dohEnabled = ($dohReg.EnableAutoDoh -ge 2)
    Add-Check -Category 'NetSec' -Check 'DNS-over-HTTPS' -Status $(if($dohEnabled){'Pass'}else{'Info'}) `
        -Value $(if($dohEnabled){'Enabled'}else{'Not configured'}) -Detail 'Encrypted DNS prevents eavesdropping'
} catch {}

Save-SectionScore -Section 'NetSec' -Category 'NetSec'

# ============================================================
# [11/15] BROWSER SECURITY
# ============================================================
Write-Host ''
Write-Host '[11/15] Browser Security' -ForegroundColor White

# Edge SmartScreen
try {
    $ssReg = Get-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Edge\SmartScreenEnabled' -ErrorAction SilentlyContinue
    $ssOn = if ($ssReg -and $ssReg.'(Default)' -ne $null) { [bool]$ssReg.'(Default)' } else { $true } # default is on
    Add-Check -Category 'Browser' -Check 'Edge SmartScreen' -Status $(if($ssOn){'Pass'}else{'Warning'}) `
        -Value $(if($ssOn){'Enabled'}else{'Disabled'}) -Detail 'Phishing and malware URL blocking'
} catch {}

# Chrome extensions count
try {
    $chromePath = "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Extensions"
    $chromeExts = if (Test-Path $chromePath) { @(Get-ChildItem $chromePath -Directory -ErrorAction SilentlyContinue).Count } else { 0 }
    $st = if ($chromeExts -le 10) {'Pass'} elseif ($chromeExts -le 20) {'Info'} else {'Warning'}
    Add-Check -Category 'Browser' -Check 'Chrome Extensions' -Status $st `
        -Value "$chromeExts installed" -Detail 'Extensions increase attack surface'
} catch {}

# Edge extensions
try {
    $edgePath = "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Extensions"
    $edgeExts = if (Test-Path $edgePath) { @(Get-ChildItem $edgePath -Directory -ErrorAction SilentlyContinue).Count } else { 0 }
    Add-Check -Category 'Browser' -Check 'Edge Extensions' -Status $(if($edgeExts -le 10){'Pass'}else{'Info'}) `
        -Value "$edgeExts installed" -Detail 'Browser extensions'
} catch {}

Save-SectionScore -Section 'Browser' -Category 'Browser'

# ============================================================
# [12/15] POWERSHELL SECURITY
# ============================================================
Write-Host ''
Write-Host '[12/15] PowerShell Security' -ForegroundColor White

# Script Block Logging
try {
    $sblReg = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging' -ErrorAction SilentlyContinue
    $sblOn = ($sblReg -and $sblReg.EnableScriptBlockLogging -eq 1)
    Add-Check -Category 'PSSecurity' -Check 'Script Block Logging' -Status $(if($sblOn){'Pass'}else{'Warning'}) `
        -Value $(if($sblOn){'Enabled'}else{'Not configured'}) -Detail 'Logs PowerShell script content for forensics'
    if (-not $sblOn) {
        Add-Finding -Severity 'Warning' -Title 'PS Script Block Logging disabled' `
            -Detail 'Malicious PowerShell activity will not be logged.' `
            -Action 'Enable Script Block Logging.' `
            -FixCommands @(@{Desc='Enable Script Block Logging';Cmd="New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging' -Force | Out-Null; Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging' -Name 'EnableScriptBlockLogging' -Value 1 -Type DWord; Write-Host 'Enabled'"}) -FixMinutes 1
    }
} catch {}

# Module Logging
try {
    $mlReg = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ModuleLogging' -ErrorAction SilentlyContinue
    $mlOn = ($mlReg -and $mlReg.EnableModuleLogging -eq 1)
    Add-Check -Category 'PSSecurity' -Check 'Module Logging' -Status $(if($mlOn){'Pass'}else{'Info'}) `
        -Value $(if($mlOn){'Enabled'}else{'Not configured'}) -Detail 'Logs module usage'
} catch {}

# Constrained Language Mode
$clm = $ExecutionContext.SessionState.LanguageMode
Add-Check -Category 'PSSecurity' -Check 'Language Mode' -Status $(if($clm -eq 'ConstrainedLanguage'){'Pass'}else{'Info'}) `
    -Value $clm.ToString() -Detail 'ConstrainedLanguage limits attack capability'

# PowerShell v2 (downgrade attack)
try {
    $ps2 = Get-WindowsOptionalFeature -Online -FeatureName MicrosoftWindowsPowerShellV2 -ErrorAction SilentlyContinue
    $ps2Enabled = ($ps2 -and $ps2.State -eq 'Enabled')
    Add-Check -Category 'PSSecurity' -Check 'PowerShell v2 (Downgrade)' -Status $(if(-not $ps2Enabled){'Pass'}else{'Warning'}) `
        -Value $(if($ps2Enabled){'INSTALLED - downgrade attack possible'}else{'Removed'}) -Detail 'PS v2 bypasses Script Block Logging and AMSI'
    if ($ps2Enabled) {
        Add-Finding -Severity 'Warning' -Title 'PowerShell v2 installed' `
            -Detail 'Attackers can downgrade to PS v2 to bypass logging and AMSI.' `
            -Action 'Remove PowerShell v2 feature.' `
            -FixCommands @(@{Desc='Remove PS v2';Cmd='Disable-WindowsOptionalFeature -Online -FeatureName MicrosoftWindowsPowerShellV2Root -NoRestart; Write-Host "PS v2 removed. Reboot recommended."'}) -FixMinutes 2
    }
} catch {}

Save-SectionScore -Section 'PSSecurity' -Category 'PSSecurity'

# ============================================================
# [13/15] THREAT INDICATORS
# ============================================================
Write-Host ''
Write-Host '[13/15] Threat Indicators' -ForegroundColor White

# Suspicious processes
$suspProcs = [System.Collections.ArrayList]::new()
try {
    $procs = Get-Process -ErrorAction Stop
    $suspPatterns = @('mimikatz','rubeus','lazagne','sharphound','bloodhound','procdump','psexec','cobalt','beacon','meterpreter','nc\.exe','ncat','netcat')
    foreach ($p in $procs) {
        $pName = $p.ProcessName.ToLower()
        foreach ($pat in $suspPatterns) {
            if ($pName -match $pat) {
                $null = $suspProcs.Add([PSCustomObject]@{Name=$p.ProcessName;PID=$p.Id;Path=$p.Path})
                break
            }
        }
    }
    Add-Check -Category 'Threats' -Check 'Suspicious Processes' -Status $(if($suspProcs.Count -eq 0){'Pass'}else{'Fail'}) `
        -Value "$($suspProcs.Count) found" -Detail 'Known offensive tool process names'
    if ($suspProcs.Count -gt 0) {
        Add-Finding -Severity 'Critical' -Title "$($suspProcs.Count) suspicious process(es) detected" `
            -Detail (($suspProcs | ForEach-Object {"$($_.Name) (PID $($_.PID))"}) -join ', ') `
            -Action 'Investigate immediately. Possible compromise.' `
            -FixCommands @(@{Desc='List and review suspicious processes';Cmd='Get-Process | Where-Object { $_.ProcessName -match "mimikatz|rubeus|lazagne|sharphound|bloodhound|procdump|psexec|cobalt|beacon|meterpreter" } | Format-Table ProcessName, Id, Path -AutoSize'})
    }
} catch {}

# Recently modified system files (last 24h)
try {
    $recentSys = @(Get-ChildItem "$env:SystemRoot\System32" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -gt (Get-Date).AddHours(-24) -and $_.Extension -match '\.(exe|dll|sys)$' } |
        Select-Object -First 10)
    Add-Check -Category 'Threats' -Check 'Recently Modified System Files (24h)' -Status $(if($recentSys.Count -le 5){'Pass'}else{'Info'}) `
        -Value "$($recentSys.Count) file(s)" -Detail 'EXE/DLL/SYS modified in System32 last 24 hours'
} catch {}

# Unusual network connections
try {
    $foreignConns = @(Get-NetTCPConnection -State Established -ErrorAction Stop |
        Where-Object { $_.RemoteAddress -notmatch '^(127\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|::1|0\.0\.0\.0)' } |
        Group-Object RemoteAddress | Sort-Object Count -Descending | Select-Object -First 5)
    $extCount = ($foreignConns | Measure-Object -Property Count -Sum).Sum
    Add-Check -Category 'Threats' -Check 'External Connections' -Status 'Info' `
        -Value "$extCount to $($foreignConns.Count) unique external IPs" -Detail 'Active outbound connections'
} catch {}

Save-SectionScore -Section 'Threats' -Category 'Threats'

# ============================================================
# [14/15] WINDOWS SECURITY FEATURES
# ============================================================
Write-Host ''
Write-Host '[14/15] Windows Security Features' -ForegroundColor White

# Windows Hello
try {
    $whReg = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\PolicyManager\default\Settings\AllowSignInOptions' -ErrorAction SilentlyContinue
    $ngcPath = "$env:SystemRoot\ServiceProfiles\LocalService\AppData\Local\Microsoft\Ngc"
    $helloConfigured = (Test-Path $ngcPath -ErrorAction SilentlyContinue) -and ((Get-ChildItem $ngcPath -ErrorAction SilentlyContinue -ErrorAction SilentlyContinue -Recurse -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0)
    Add-Check -Category 'WinSec' -Check 'Windows Hello' -Status $(if($helloConfigured){'Pass'}else{'Info'}) `
        -Value $(if($helloConfigured){'Configured'}else{'Not configured'}) -Detail 'Passwordless authentication'
} catch {}

# Audit Policy
try {
    $auditpol = auditpol /get /category:* 2>$null | Out-String
    $logonAudit = if ($auditpol -match 'Logon.*Success and Failure') {'Full'} elseif ($auditpol -match 'Logon.*Success') {'Success only'} else {'Minimal'}
    Add-Check -Category 'WinSec' -Check 'Logon Audit Policy' -Status $(if($logonAudit -eq 'Full'){'Pass'}elseif($logonAudit -eq 'Success only'){'Warning'}else{'Fail'}) `
        -Value $logonAudit -Detail 'Logon event auditing level'
} catch {}

# BitLocker PIN
try {
    $blOsVol = Get-BitLockerVolume -ErrorAction SilentlyContinue | Where-Object {$_.VolumeType -eq 'OperatingSystem'} | Select-Object -First 1
    if ($blOsVol -and $blOsVol.ProtectionStatus -eq 'On') {
        $hasPin = ($blOsVol.KeyProtector | Where-Object {$_.KeyProtectorType -match 'TpmPin|Pin'})
        Add-Check -Category 'WinSec' -Check 'BitLocker PIN (Pre-Boot)' -Status $(if($hasPin){'Pass'}else{'Info'}) `
            -Value $(if($hasPin){'Configured'}else{'TPM-only (no pre-boot PIN)'}) -Detail 'Pre-boot authentication adds cold boot attack protection'
    }
} catch {}

Save-SectionScore -Section 'WinSec' -Category 'WinSec'

# ============================================================
# [15/15] SECURITY RISK SCORE
# ============================================================
Write-Host ''
Write-Host '[15/15] Computing Security Risk Score...' -ForegroundColor White

$script:Stopwatch.Stop()
$ElapsedSec = [math]::Round($script:Stopwatch.Elapsed.TotalSeconds, 1)

$scoredChecks = @($script:Results | Where-Object {$_.Status -in @('Pass','Warning','Fail')})
$passCount = @($scoredChecks | Where-Object {$_.Status -eq 'Pass'}).Count
$warnCount = @($scoredChecks | Where-Object {$_.Status -eq 'Warning'}).Count
$failCount = @($scoredChecks | Where-Object {$_.Status -eq 'Fail'}).Count
$infoCount = @($script:Results | Where-Object {$_.Status -eq 'Info'}).Count
$undetCount = @($script:Results | Where-Object {$_.Status -eq 'Undetermined'}).Count
$totalScored = $scoredChecks.Count

$scorePct = if ($totalScored -gt 0){[math]::Round((($passCount+($warnCount*0.5))/$totalScored)*100,0)}else{0}
$grade = if ($scorePct -ge 95){'A+'} elseif ($scorePct -ge 90){'A'} elseif ($scorePct -ge 85){'A-'} elseif ($scorePct -ge 80){'B+'} elseif ($scorePct -ge 75){'B'} elseif ($scorePct -ge 70){'C+'} elseif ($scorePct -ge 65){'C'} elseif ($scorePct -ge 60){'D'} else {'F'}
$gradeColor = if ($scorePct -ge 80){'#4caf50'} elseif ($scorePct -ge 60){'#ff9800'} else {'#f44336'}

# Risk level
$critCount = @($script:Findings | Where-Object {$_.Severity -eq 'Critical'}).Count
$riskLevel = if ($critCount -ge 3) {'CRITICAL'} elseif ($critCount -ge 1 -or $failCount -ge 5) {'HIGH'} elseif ($warnCount -ge 10) {'MEDIUM'} elseif ($warnCount -ge 3) {'LOW'} else {'MINIMAL'}
$riskColor = switch ($riskLevel) {'CRITICAL'{'#f44336'}'HIGH'{'#ff5722'}'MEDIUM'{'#ff9800'}'LOW'{'#ffca28'}default{'#4caf50'}}

Write-Host ''
Write-Host '============================================================' -ForegroundColor Magenta
Write-Host "  SECURITY POSTURE ASSESSMENT COMPLETE" -ForegroundColor Magenta
Write-Host "  Grade: $grade ($scorePct%) | Risk: $riskLevel" -ForegroundColor $(if($scorePct -ge 80){'Green'}elseif($scorePct -ge 60){'Yellow'}else{'Red'})
Write-Host "  $($script:CheckCount) checks in $ElapsedSec sec" -ForegroundColor Gray
Write-Host "  $($script:CheckCount) checks: $passCount confirmed, $undetCount could not be determined, $($warnCount + $failCount) need attention, $infoCount informational" -ForegroundColor Gray
Write-Host "  Pass: $passCount | Warn: $warnCount | Fail: $failCount | Undetermined: $undetCount | Info: $infoCount" -ForegroundColor Gray
Write-Host "  Critical findings: $critCount" -ForegroundColor $(if($critCount -eq 0){'Green'}else{'Red'})
Write-Host '============================================================' -ForegroundColor Magenta

# Executive Summary
$ExecSummary = "Security posture grade $grade ($scorePct%). Risk level: $riskLevel. " +
    "$($script:CheckCount) checks performed across 15 security domains. " +
    "$passCount passed, $warnCount warnings, $failCount failures, $critCount critical finding(s). " +
    "$(if ($script:Findings.Count -eq 0){'No remediation needed.'}else{"$($script:Findings.Count) finding(s) with hardening commands."})"

# ============================================================
# INTERACTIVE HARDENING MENU
# ============================================================
$actionableFindings = @($script:Findings | Where-Object {$_.FixCommands -and $_.FixCommands.Count -gt 0} |
    Sort-Object @{Expression={switch($_.Severity){'Critical'{0}'Warning'{1}default{2}}}}, FixMinutes)

if ($actionableFindings.Count -gt 0) {
    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Yellow
    Write-Host '  SECURITY HARDENING MENU' -ForegroundColor Yellow
    Write-Host "  $($actionableFindings.Count) finding(s) | Critical first, quick wins first" -ForegroundColor Gray
    Write-Host '============================================================' -ForegroundColor Yellow
    Write-Host ''

    $fixIndex = 0
    foreach ($af in $actionableFindings) {
        $fixIndex++
        $sevColor = switch ($af.Severity) {'Critical'{'Red'}'Warning'{'Yellow'}default{'Cyan'}}
        $tags = "$(if($af.FixMinutes -le 2){' [QUICK]'}else{''})$(if($af.CIS){" [$($af.CIS)]"})"
        Write-Host "  [$fixIndex] $($af.Severity.ToUpper()): $($af.Title)$tags" -ForegroundColor $sevColor
        Write-Host "      $($af.Detail)" -ForegroundColor Gray
        $ci = 0; foreach ($fc in $af.FixCommands) { $ci++; Write-Host "      ${fixIndex}.${ci} - $($fc.Desc)" -ForegroundColor DarkCyan }
        Write-Host ''
    }
    Write-Host '  fix# (e.g. 1.2) | ALL (hardening script) | SKIP' -ForegroundColor Gray; Write-Host ''

    $keepAsking = $true
    while ($keepAsking) {
        $choice = Read-Host '  Enter choice'
        $ct = $choice.Trim().ToUpper()
        if ($ct -eq 'SKIP' -or $ct -eq '') { $keepAsking = $false }
        elseif ($ct -eq 'ALL') {
            $rp = Join-Path $ReportsPath "SecurityHarden_${Hostname}_${Timestamp}.ps1"
            $lns = [System.Collections.ArrayList]::new()
            $null = $lns.Add("# FieldOps Pro - Security Hardening Script | $DateHuman | $Hostname")
            $null = $lns.Add("# REVIEW EACH COMMAND BEFORE RUNNING. Some require reboot.")
            $null = $lns.Add("#Requires -RunAsAdministrator`n")
            $fi = 0; foreach ($af in $actionableFindings) { $fi++
                $null = $lns.Add("# === [$fi] $($af.Severity.ToUpper()): $($af.Title) $(if($af.CIS){"[$($af.CIS)]"}) ===")
                foreach ($fc in $af.FixCommands) { $null = $lns.Add("`n# $($fc.Desc)"); $null = $lns.Add($fc.Cmd) }; $null = $lns.Add("") }
            ($lns -join "`r`n") | Out-File -FilePath $rp -Encoding UTF8 -Force
            Write-Host "  Hardening script: $rp" -ForegroundColor Green; $keepAsking = $false
        }
        elseif ($ct -match '^(\d+)\.(\d+)$') {
            $fN=[int]$Matches[1]; $cN=[int]$Matches[2]
            if ($fN -ge 1 -and $fN -le $actionableFindings.Count) {
                $tf=$actionableFindings[$fN-1]
                if ($cN -ge 1 -and $cN -le $tf.FixCommands.Count) {
                    $tc=$tf.FixCommands[$cN-1]; Write-Host "  Running: $($tc.Desc)" -ForegroundColor Yellow
                    $cf=Read-Host '  Execute? (Y/N)'
                    if($cf.Trim().ToUpper() -eq 'Y'){try{Invoke-Expression $tc.Cmd;Write-Host '  Done.' -ForegroundColor Green}catch{Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red}}; Write-Host ''
                } else {Write-Host '  Invalid cmd#' -ForegroundColor Red}
            } else {Write-Host '  Invalid fix#' -ForegroundColor Red}
        } else {Write-Host '  Use: 1.2, ALL, or SKIP' -ForegroundColor Red}
    }
}

# ============================================================
# HTML REPORT
# ============================================================
Write-Host ''; Write-Host 'Generating HTML report...' -ForegroundColor Gray
$ReportFile = Join-Path $ReportsPath "SecurityScan_${Hostname}_${Timestamp}.html"

# Section score bars
$catBarsHtml = ''
foreach ($cs in $script:SectionScores) {
    $bc = if ($cs.Score -ge 80){'#4caf50'} elseif ($cs.Score -ge 60){'#ff9800'} else {'#f44336'}
    $catBarsHtml += "<div class='cb-row'><div class='cb-label'>$($cs.Section)</div><div class='cb-track'><div class='cb-fill' style='width:$($cs.Score)%;background:$bc'></div></div><div class='cb-val' style='color:$bc'>$($cs.Score)%</div></div>"
}

# Findings HTML
$fHtml=''; $fi2=0
if ($script:Findings.Count -gt 0) {
    foreach ($f in $script:Findings) {
        $fi2++; $svc=switch($f.Severity){'Critical'{'finding-critical'}'Warning'{'finding-warning'}default{'finding-info'}}
        $svi=switch($f.Severity){'Critical'{'&#10007;'}'Warning'{'&#9888;'}default{'&#8505;'}}
        $cisTag = if ($f.CIS) {"<span class='cis-tag'>$($f.CIS)</span>"} else {''}
        $fxB=''; if($f.FixCommands -and $f.FixCommands.Count -gt 0){
            $ci2='';$cx=0; foreach($fc in $f.FixCommands){$cx++;$cid="fix-${fi2}-${cx}"
                $esc=$fc.Cmd -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;'
                $ci2+="<div class='fix-item'><div class='fix-desc'>$($fc.Desc)</div><div class='fix-cmd-wrap'><pre class='fix-cmd' id='$cid'>$esc</pre><button class='copy-btn' onclick=`"copyCmd('$cid')`">Copy</button></div></div>"}
            $fxB="<div class='fix-block'><div class='fix-header' onclick='toggleFix(this)'><span class='fix-arrow'>&#9654;</span> $($f.FixCommands.Count) Hardening Command(s)$(if($f.FixMinutes -le 2){" <span style='color:#4caf50'>[QUICK]</span>"})</div><div class='fix-body' style='display:none'>$ci2</div></div>"
        }
        $fHtml+="<div class='finding-card $svc'><div class='finding-title'>$svi $($f.Severity.ToUpper()): $($f.Title) $cisTag</div><div class='finding-detail'>$($f.Detail)</div><div class='finding-action'><strong>Action:</strong> $($f.Action)</div>$fxB</div>"
    }
} else { $fHtml='<div class="finding-card finding-info"><div class="finding-title">&#10003; No findings - system is hardened</div></div>' }

# Check rows
$crHtml = foreach($r in $script:Results){
    $sc=switch($r.Status){'Pass'{'status-pass'}'Warning'{'status-warn'}'Fail'{'status-fail'}'Undetermined'{'status-undet'}default{'status-info'}}
    $si=switch($r.Status){'Pass'{'&#10003;'}'Warning'{'&#9888;'}'Fail'{'&#10007;'}'Undetermined'{'&#8212;'}default{'&#8505;'}}
    "<tr><td>$($r.Number)</td><td>$($r.Category)</td><td>$($r.Check)</td><td class='$sc'>$si $($r.Status)</td><td>$($r.Value)</td><td class='detail-cell'>$($r.Detail)</td></tr>"
}

$HtmlContent = @"
<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>FieldOps Pro - Security | $Hostname</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}body{font-family:'Segoe UI',Tahoma,sans-serif;background:#08081a;color:#d8dce6;padding:24px;line-height:1.5}.rc{max-width:1200px;margin:0 auto}
.hdr{background:linear-gradient(135deg,#1a0820,#2a1040);border-radius:14px;padding:28px 32px;margin-bottom:24px;border:1px solid #3a1860}.hdr-title{font-size:1.6em;font-weight:800;color:#ce93d8}.hdr-sub{font-size:0.88em;color:#9070a0;margin-top:2px}.hdr-bar{display:flex;flex-wrap:wrap;gap:20px;margin-top:16px;padding-top:14px;border-top:1px solid #3a1860}.hdr-item{font-size:0.8em}.hdr-lbl{color:#7050a0}.hdr-val{color:#c8a8e0;font-weight:600}
.grade{background:linear-gradient(135deg,#100818,#1a1028);border-radius:14px;padding:24px 32px;margin-bottom:24px;border:1px solid #2a1848;display:flex;align-items:center;gap:32px}.grade-circle{width:92px;height:92px;border-radius:50%;display:flex;align-items:center;justify-content:center;font-size:2.1em;font-weight:900;flex-shrink:0;border:5px solid}.grade-det{flex:1}.grade-score{font-size:1.1em;font-weight:700}.grade-track{width:100%;height:14px;background:#141420;border-radius:7px;overflow:hidden;margin:8px 0}.grade-fill{height:100%;border-radius:7px}.grade-stats{display:flex;gap:20px;font-size:0.82em;margin-top:4px}.st-p{color:#4caf50}.st-w{color:#ff9800}.st-f{color:#f44336}.st-i{color:#64b5f6}
.risk-badge{display:inline-block;padding:4px 14px;border-radius:20px;font-weight:800;font-size:0.85em;margin-left:12px;letter-spacing:1px}
.exec{background:#0c0818;border:1px solid #1c1838;border-radius:12px;padding:18px 24px;margin-bottom:24px;font-size:0.9em;color:#a090b8;line-height:1.65}.exec-title{font-weight:700;color:#ce93d8;margin-bottom:6px}
.stitle{font-size:1.05em;font-weight:700;color:#ce93d8;margin:24px 0 12px;padding-bottom:6px;border-bottom:1px solid #2a1848;display:flex;align-items:center;gap:8px}.stitle .badge{background:#2a1848;color:#9070a0;font-size:0.68em;padding:2px 7px;border-radius:10px}
.two-col{display:flex;gap:20px;flex-wrap:wrap;margin-bottom:20px}.two-col>div{flex:1;min-width:280px}
.cb-row{display:flex;align-items:center;gap:10px;margin-bottom:6px}.cb-label{width:100px;font-size:0.78em;color:#a090b8;font-weight:600;flex-shrink:0}.cb-track{flex:1;height:14px;background:#141420;border-radius:4px;overflow:hidden}.cb-fill{height:100%;border-radius:4px}.cb-val{width:45px;font-size:0.78em;font-weight:700;text-align:right}
.finding-card{border-radius:10px;padding:12px 16px;margin-bottom:10px;border-left:5px solid}.finding-critical{background:#1a0808;border-color:#f44336}.finding-warning{background:#1a1408;border-color:#ff9800}.finding-info{background:#080c18;border-color:#64b5f6}.finding-title{font-weight:700;margin-bottom:3px;font-size:0.92em}.finding-detail{font-size:0.82em;color:#8888a8}.finding-action{font-size:0.8em;color:#a0a0b8;margin-top:4px}
.cis-tag{background:#1a2858;color:#64b5f6;padding:1px 6px;border-radius:4px;font-size:0.72em;font-weight:600;margin-left:6px}
.fix-block{margin-top:8px;border:1px solid #2a1848;border-radius:8px;overflow:hidden}.fix-header{background:#140c28;padding:8px 12px;cursor:pointer;font-size:0.82em;font-weight:600;color:#ce93d8;display:flex;align-items:center;gap:6px;user-select:none}.fix-header:hover{background:#1a1038}.fix-arrow{font-size:0.65em;transition:transform 0.2s;display:inline-block}.fix-arrow.open{transform:rotate(90deg)}.fix-body{padding:10px 12px;background:#0a0618}.fix-item{margin-bottom:10px}.fix-desc{font-size:0.78em;color:#9080b4;font-weight:600;margin-bottom:3px}.fix-cmd-wrap{position:relative}.fix-cmd{background:#060410;border:1px solid #1a1040;border-radius:6px;padding:8px 10px;font-family:'Cascadia Code','Consolas',monospace;font-size:0.75em;color:#a8d0a8;white-space:pre-wrap;word-break:break-all;margin:0}.copy-btn{position:absolute;top:4px;right:4px;background:#2a1848;color:#ce93d8;border:1px solid #3a2868;border-radius:4px;padding:2px 8px;font-size:0.68em;cursor:pointer}.copy-btn:hover{background:#3a2868}
table{width:100%;border-collapse:collapse;margin-bottom:14px;font-size:0.78em}th{background:#100818;color:#ce93d8;padding:8px 10px;text-align:left;font-weight:600;border-bottom:2px solid #2a1848;position:sticky;top:0}td{padding:7px 10px;border-bottom:1px solid #151528;vertical-align:top}tr:hover{background:#0e0820}.detail-cell{max-width:300px;word-break:break-all;color:#6868a0;font-size:0.88em}.status-pass{color:#4caf50;font-weight:600}.status-warn{color:#ff9800;font-weight:600}.status-fail{color:#f44336;font-weight:600}.status-info{color:#64b5f6;font-weight:600}.status-undet{color:#9a8f7a;font-weight:600}
details{background:#0c0820;border:1px solid #1a1840;border-radius:10px;margin-bottom:16px;overflow:hidden}summary{cursor:pointer;padding:12px 18px;font-weight:600;color:#9080b4;font-size:0.92em;user-select:none;list-style:none;display:flex;align-items:center;gap:6px}summary:hover{background:#101030}summary::-webkit-details-marker{display:none}summary::before{content:'\\25B6';font-size:0.65em;transition:transform 0.2s;display:inline-block;color:#6050a0}details[open] summary::before{transform:rotate(90deg)}details .sect-body{padding:14px 18px;overflow-x:auto}
.ftr{text-align:center;padding:18px;color:#2a2a4a;font-size:0.75em;border-top:1px solid #151528;margin-top:24px}
@media print{body{background:#fff!important;color:#222!important;padding:8px}.hdr,.grade,.exec,details,.finding-card{background:#f8f8fc!important;border-color:#ddd!important;color:#222!important;-webkit-print-color-adjust:exact;print-color-adjust:exact}.fix-cmd{background:#f0f0f0!important;color:#1a3a1a!important}.copy-btn{display:none!important}th{background:#f0e8f8!important;color:#4a2868!important}td{border-color:#ddd!important;color:#333!important}.status-pass{color:#1b7a1b!important}.status-warn{color:#b36b00!important}.status-fail{color:#c62828!important}.status-info{color:#1565c0!important}.status-undet{color:#6b6355!important}}
</style></head><body><div class="rc">
<div class="hdr"><div class="hdr-title">FieldOps Pro -- Enterprise Security Posture Report</div><div class="hdr-sub">15-section deep security analysis with CIS benchmark mapping and interactive hardening</div><div class="hdr-bar"><div class="hdr-item"><span class="hdr-lbl">Host</span> <span class="hdr-val">$Hostname</span></div><div class="hdr-item"><span class="hdr-lbl">Date</span> <span class="hdr-val">$DateHuman</span></div><div class="hdr-item"><span class="hdr-lbl">Checks</span> <span class="hdr-val">$($script:CheckCount)</span></div><div class="hdr-item"><span class="hdr-lbl">Duration</span> <span class="hdr-val">${ElapsedSec}s</span></div><div class="hdr-item"><span class="hdr-lbl">Engine</span> <span class="hdr-val">SecurityScan v1.0</span></div><div class="hdr-item"><span class="hdr-lbl">Elevation</span> <span class="hdr-val">$(if($script:IsAdmin){'Administrator'}else{'Standard user'})</span></div></div></div>
<div class="grade"><div class="grade-circle" style="background:${gradeColor}18;border-color:$gradeColor;color:$gradeColor">$grade</div><div class="grade-det"><div class="grade-score">Security Score: $scorePct% <span class="risk-badge" style="background:${riskColor}22;color:$riskColor;border:1px solid $riskColor">$riskLevel RISK</span></div><div class="grade-track"><div class="grade-fill" style="width:${scorePct}%;background:linear-gradient(90deg,$gradeColor,${gradeColor}66)"></div></div><div class="grade-stats"><span class="st-p">$passCount Pass</span><span class="st-w">$warnCount Warn</span><span class="st-f">$failCount Fail</span><span class="st-i">$infoCount Info</span><span style="color:#f44336;font-weight:700">$critCount Critical</span></div></div></div>
<div class="exec"><div class="exec-title">Executive Summary</div>$ExecSummary</div>
<div class="stitle">Security Domain Scores</div>$catBarsHtml
<div class="stitle">Findings &amp; Hardening <span class="badge">$($script:Findings.Count)</span></div>$fHtml
<details open><summary>All Checks ($($script:CheckCount))</summary><div class="sect-body"><table><tr><th>#</th><th>Domain</th><th>Check</th><th>Status</th><th>Value</th><th>Detail</th></tr>$($crHtml -join '')</table></div></details>
<div class="ftr">FieldOps Pro -- Enterprise Security Posture Engine v1.0 | $DateHuman | $($script:CheckCount) checks across 15 domains in ${ElapsedSec}s | $Hostname</div>
</div><script>
function copyCmd(id){var el=document.getElementById(id);if(navigator.clipboard)navigator.clipboard.writeText(el.textContent).then(function(){var b=event.target;b.textContent='Copied!';setTimeout(function(){b.textContent='Copy'},2000)})}
function toggleFix(h){var b=h.nextElementSibling,a=h.querySelector('.fix-arrow');if(b.style.display==='none'){b.style.display='block';a.classList.add('open')}else{b.style.display='none';a.classList.remove('open')}}
</script></body></html>
"@

$HtmlContent | Out-File -FilePath $ReportFile -Encoding UTF8 -Force

# FieldOps-ANSSI-JSON-Sidecar-Marker - DO NOT REMOVE (idempotency check anchor)
try {
    $jsonFile = Join-Path $LogsPath ("SecurityScan_${Hostname}_${Timestamp}.json")
    $reportData = [PSCustomObject]@{
        Engine     = 'SecurityScan'
        Version    = '1.0'
        Hostname   = $Hostname
        Timestamp  = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Summary    = @{
            Total    = ($script:Results | Measure-Object).Count
            Pass     = ($script:Results | Where-Object { $_.Status -eq 'Pass' }    | Measure-Object).Count
            Warning  = ($script:Results | Where-Object { $_.Status -eq 'Warning' } | Measure-Object).Count
            Fail     = ($script:Results | Where-Object { $_.Status -eq 'Fail' }    | Measure-Object).Count
            Info     = ($script:Results | Where-Object { $_.Status -eq 'Info' }    | Measure-Object).Count
        }
        Checks     = @($script:Results)
        Findings   = @($script:Findings)
    }
    $reportData | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $jsonFile -Encoding UTF8 -Force
    Write-Host "  JSON  : $jsonFile" -ForegroundColor DarkGray
} catch {
    Write-Host "  [WARN] JSON sidecar failed: $($_.Exception.Message)" -ForegroundColor Yellow
}
Write-Host "  Report: $ReportFile" -ForegroundColor Green
Write-Host "  Start-Process `"$ReportFile`"" -ForegroundColor Yellow
Write-Host ''
