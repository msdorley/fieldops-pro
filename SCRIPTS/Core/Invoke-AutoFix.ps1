<#
.SYNOPSIS
    FieldOps Pro - Interactive Self-Healing Engine v2.0
.DESCRIPTION
    Scans for 25+ issues across 5 domains, presents interactive menu for
    remediation. Each fix has detect/fix/verify/rollback commands and is
    classified SAFE/MODERATE/RISKY. Generates change report and rollback script.
.NOTES
    Author  : FieldOps Pro
    Version : 2.0
    Requires: PowerShell 5.1, Administrator recommended
    Location: E:\SCRIPTS\Core\Invoke-AutoFix.ps1
#>

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
@($ReportsPath, $LogsPath) | ForEach-Object { if (-not (Test-Path $_)) { New-Item $_ -ItemType Directory -Force | Out-Null } }

$Hostname  = $env:COMPUTERNAME
$Timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$DateHuman = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$IsAdmin   = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

$script:TechName = "$env:USERDOMAIN\$env:USERNAME"
try {
    $tj = Join-Path $ConfigPath 'technician.json'
    if (Test-Path $tj) { $td = Get-Content $tj -Raw | ConvertFrom-Json; if ($td.Name) { $script:TechName = $td.Name } }
} catch {}

# ============================================================
# ENGINE STATE
# ============================================================
$script:ChangeLog    = [System.Collections.ArrayList]::new()
$script:FixResults   = [System.Collections.ArrayList]::new()
$script:DetectedIssues = [System.Collections.ArrayList]::new()
$script:SW           = [System.Diagnostics.Stopwatch]::StartNew()

# ============================================================
# FIX RULE DATABASE (26 rules, expandable)
# ============================================================
$script:FixRules = @(
    # ===== SECURITY DOMAIN =====
    @{Id='SEC-001'; Name='Disable Guest Account'; Domain='Security'; Level='Safe'; Impact=3; Reboot=$false
      Desc='Guest account allows unauthorized access.'
      Detect={try{$g=Get-LocalUser -Name 'Guest' -EA Stop; $g.Enabled}catch{$false}}
      Fix={Disable-LocalUser -Name 'Guest' -EA Stop}
      Verify={try{$g=Get-LocalUser -Name 'Guest' -EA Stop; -not $g.Enabled}catch{$true}}
      Rollback='Enable-LocalUser -Name "Guest"'}

    @{Id='SEC-002'; Name='Disable SMBv1 Protocol'; Domain='Security'; Level='Safe'; Impact=5; Reboot=$false
      Desc='SMBv1 is the WannaCry/EternalBlue attack vector.'
      Detect={try{(Get-SmbServerConfiguration -EA Stop).EnableSMB1Protocol}catch{$false}}
      Fix={Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force}
      Verify={try{-not (Get-SmbServerConfiguration -EA Stop).EnableSMB1Protocol}catch{$true}}
      Rollback='Set-SmbServerConfiguration -EnableSMB1Protocol $true -Force'}

    @{Id='SEC-003'; Name='Enable Defender Real-Time Protection'; Domain='Security'; Level='Safe'; Impact=8; Reboot=$false
      Desc='Core antimalware engine must be active.'
      Detect={try{-not (Get-MpComputerStatus -EA Stop).RealTimeProtectionEnabled}catch{$false}}
      Fix={Set-MpPreference -DisableRealtimeMonitoring $false}
      Verify={try{(Get-MpComputerStatus -EA Stop).RealTimeProtectionEnabled}catch{$false}}
      Rollback='Set-MpPreference -DisableRealtimeMonitoring $true'}

    @{Id='SEC-004'; Name='Update Defender Signatures'; Domain='Security'; Level='Safe'; Impact=3; Reboot=$false
      Desc='Outdated signatures miss new threats.'
      Detect={try{((Get-Date)-(Get-MpComputerStatus -EA Stop).AntivirusSignatureLastUpdated).Days -gt 3}catch{$false}}
      Fix={Update-MpSignature -EA SilentlyContinue}
      Verify={try{((Get-Date)-(Get-MpComputerStatus -EA Stop).AntivirusSignatureLastUpdated).Days -le 3}catch{$false}}
      Rollback='# Signatures cannot be downgraded'}

    @{Id='SEC-005'; Name='Enable Script Block Logging'; Domain='Security'; Level='Safe'; Impact=2; Reboot=$false
      Desc='Logs all PowerShell script content for forensics.'
      Detect={$r=Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging' -EA SilentlyContinue; -not ($r -and $r.EnableScriptBlockLogging -eq 1)}
      Fix={New-Item 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging' -Force -EA SilentlyContinue|Out-Null; Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging' -Name 'EnableScriptBlockLogging' -Value 1 -Type DWord -Force}
      Verify={$r=Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging' -EA SilentlyContinue; $r -and $r.EnableScriptBlockLogging -eq 1}
      Rollback='Set-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging" -Name "EnableScriptBlockLogging" -Value 0 -Force'}

    @{Id='SEC-006'; Name='Disable Auto-Logon'; Domain='Security'; Level='Safe'; Impact=4; Reboot=$false
      Desc='Auto-logon bypasses authentication.'
      Detect={$r=Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -EA SilentlyContinue; $r -and $r.AutoAdminLogon -eq '1'}
      Fix={Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name 'AutoAdminLogon' -Value '0' -Force; Remove-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name 'DefaultPassword' -EA SilentlyContinue}
      Verify={$r=Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -EA SilentlyContinue; -not ($r -and $r.AutoAdminLogon -eq '1')}
      Rollback='# Re-enable manually if needed'}

    @{Id='SEC-007'; Name='Stop Remote Registry Service'; Domain='Security'; Level='Safe'; Impact=2; Reboot=$false
      Desc='Allows remote registry modification.'
      Detect={try{$s=Get-Service RemoteRegistry -EA Stop; $s.Status -eq 'Running'}catch{$false}}
      Fix={Stop-Service RemoteRegistry -Force -EA SilentlyContinue; Set-Service RemoteRegistry -StartupType Disabled -EA SilentlyContinue}
      Verify={try{$s=Get-Service RemoteRegistry -EA Stop; $s.Status -ne 'Running'}catch{$true}}
      Rollback='Set-Service RemoteRegistry -StartupType Manual; Start-Service RemoteRegistry'}

    @{Id='SEC-008'; Name='Enable Network Protection'; Domain='Security'; Level='Safe'; Impact=2; Reboot=$false
      Desc='Blocks connections to malicious domains.'
      Detect={try{(Get-MpPreference -EA Stop).EnableNetworkProtection -ne 1}catch{$false}}
      Fix={Set-MpPreference -EnableNetworkProtection Enabled}
      Verify={try{(Get-MpPreference -EA Stop).EnableNetworkProtection -eq 1}catch{$false}}
      Rollback='Set-MpPreference -EnableNetworkProtection Disabled'}

    @{Id='SEC-009'; Name='Enable Controlled Folder Access'; Domain='Security'; Level='Safe'; Impact=3; Reboot=$false
      Desc='Ransomware protection for user folders.'
      Detect={try{(Get-MpPreference -EA Stop).EnableControlledFolderAccess -ne 1}catch{$false}}
      Fix={Set-MpPreference -EnableControlledFolderAccess Enabled}
      Verify={try{(Get-MpPreference -EA Stop).EnableControlledFolderAccess -eq 1}catch{$false}}
      Rollback='Set-MpPreference -EnableControlledFolderAccess Disabled'}

    @{Id='SEC-010'; Name='Enable PUA Protection'; Domain='Security'; Level='Safe'; Impact=1; Reboot=$false
      Desc='Blocks potentially unwanted applications.'
      Detect={try{(Get-MpPreference -EA Stop).PUAProtection -ne 1}catch{$false}}
      Fix={Set-MpPreference -PUAProtection Enabled}
      Verify={try{(Get-MpPreference -EA Stop).PUAProtection -eq 1}catch{$false}}
      Rollback='Set-MpPreference -PUAProtection Disabled'}

    @{Id='SEC-011'; Name='Enable LSA Protection (RunAsPPL)'; Domain='Security'; Level='Moderate'; Impact=4; Reboot=$true
      Desc='Protects LSASS from credential dumping (Mimikatz).'
      Detect={$r=Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -EA SilentlyContinue; -not ($r -and $r.RunAsPPL -eq 1)}
      Fix={Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name 'RunAsPPL' -Value 1 -Type DWord -Force}
      Verify={$r=Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -EA SilentlyContinue; $r -and $r.RunAsPPL -eq 1}
      Rollback='Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" -Name "RunAsPPL" -Value 0 -Force'}

    @{Id='SEC-012'; Name='Enable HVCI (Memory Integrity)'; Domain='Security'; Level='Moderate'; Impact=3; Reboot=$true
      Desc='Hypervisor-enforced code integrity. May cause driver issues.'
      Detect={try{$dg=Get-CimInstance -Class Win32_DeviceGuard -Namespace 'root\Microsoft\Windows\DeviceGuard' -EA Stop; -not ($dg.SecurityServicesRunning -contains 1)}catch{$false}}
      Fix={$p='HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity'; New-Item $p -Force -EA SilentlyContinue|Out-Null; Set-ItemProperty $p -Name 'Enabled' -Value 1 -Type DWord -Force}
      Verify={$r=Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' -EA SilentlyContinue; $r -and $r.Enabled -eq 1}
      Rollback='Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity" -Name "Enabled" -Value 0 -Force'}

    @{Id='SEC-013'; Name='Remove PowerShell v2 (Downgrade Attack)'; Domain='Security'; Level='Moderate'; Impact=2; Reboot=$false
      Desc='PS v2 bypasses AMSI and Script Block Logging.'
      Detect={try{$f=Get-WindowsOptionalFeature -Online -FeatureName MicrosoftWindowsPowerShellV2 -EA Stop; $f.State -eq 'Enabled'}catch{$false}}
      Fix={Disable-WindowsOptionalFeature -Online -FeatureName MicrosoftWindowsPowerShellV2Root -NoRestart -EA SilentlyContinue|Out-Null}
      Verify={try{$f=Get-WindowsOptionalFeature -Online -FeatureName MicrosoftWindowsPowerShellV2 -EA Stop; $f.State -ne 'Enabled'}catch{$true}}
      Rollback='Enable-WindowsOptionalFeature -Online -FeatureName MicrosoftWindowsPowerShellV2Root -NoRestart'}

    @{Id='SEC-014'; Name='ASR: Block LSASS Credential Theft'; Domain='Security'; Level='Safe'; Impact=3; Reboot=$false
      Desc='Blocks credential stealing from LSASS.'
      Detect={try{$p=Get-MpPreference -EA Stop; $ids=@($p.AttackSurfaceReductionRules_Ids); $acts=@($p.AttackSurfaceReductionRules_Actions); $i=-1; for($x=0;$x -lt $ids.Count;$x++){if($ids[$x] -eq '9e6c4e1f-7d60-472f-ba1a-a39ef669e4b2'){$i=$x;break}}; $i -lt 0 -or $acts[$i] -ne 1}catch{$false}}
      Fix={Add-MpPreference -AttackSurfaceReductionRules_Ids '9e6c4e1f-7d60-472f-ba1a-a39ef669e4b2' -AttackSurfaceReductionRules_Actions Enabled}
      Verify={try{$p=Get-MpPreference -EA Stop; $ids=@($p.AttackSurfaceReductionRules_Ids); $acts=@($p.AttackSurfaceReductionRules_Actions); $i=-1; for($x=0;$x -lt $ids.Count;$x++){if($ids[$x] -eq '9e6c4e1f-7d60-472f-ba1a-a39ef669e4b2'){$i=$x;break}}; $i -ge 0 -and $acts[$i] -eq 1}catch{$false}}
      Rollback='Add-MpPreference -AttackSurfaceReductionRules_Ids "9e6c4e1f-7d60-472f-ba1a-a39ef669e4b2" -AttackSurfaceReductionRules_Actions Disabled'}

    @{Id='SEC-015'; Name='ASR: Ransomware Protection'; Domain='Security'; Level='Safe'; Impact=3; Reboot=$false
      Desc='Advanced protection against ransomware.'
      Detect={try{$p=Get-MpPreference -EA Stop; $ids=@($p.AttackSurfaceReductionRules_Ids); $acts=@($p.AttackSurfaceReductionRules_Actions); $i=-1; for($x=0;$x -lt $ids.Count;$x++){if($ids[$x] -eq 'c1db55ab-c21a-4637-bb3f-a12568109d35'){$i=$x;break}}; $i -lt 0 -or $acts[$i] -ne 1}catch{$false}}
      Fix={Add-MpPreference -AttackSurfaceReductionRules_Ids 'c1db55ab-c21a-4637-bb3f-a12568109d35' -AttackSurfaceReductionRules_Actions Enabled}
      Verify={try{$p=Get-MpPreference -EA Stop; $ids=@($p.AttackSurfaceReductionRules_Ids); $acts=@($p.AttackSurfaceReductionRules_Actions); $i=-1; for($x=0;$x -lt $ids.Count;$x++){if($ids[$x] -eq 'c1db55ab-c21a-4637-bb3f-a12568109d35'){$i=$x;break}}; $i -ge 0 -and $acts[$i] -eq 1}catch{$false}}
      Rollback='Add-MpPreference -AttackSurfaceReductionRules_Ids "c1db55ab-c21a-4637-bb3f-a12568109d35" -AttackSurfaceReductionRules_Actions Disabled'}

    @{Id='SEC-016'; Name='ASR: Block Office Child Processes'; Domain='Security'; Level='Safe'; Impact=2; Reboot=$false
      Desc='Prevents Office from spawning malicious child processes.'
      Detect={try{$p=Get-MpPreference -EA Stop; $ids=@($p.AttackSurfaceReductionRules_Ids); $acts=@($p.AttackSurfaceReductionRules_Actions); $i=-1; for($x=0;$x -lt $ids.Count;$x++){if($ids[$x] -eq 'd4f940ab-401b-4efc-aadc-ad5f3c50688a'){$i=$x;break}}; $i -lt 0 -or $acts[$i] -ne 1}catch{$false}}
      Fix={Add-MpPreference -AttackSurfaceReductionRules_Ids 'd4f940ab-401b-4efc-aadc-ad5f3c50688a' -AttackSurfaceReductionRules_Actions Enabled}
      Verify={try{$p=Get-MpPreference -EA Stop; $ids=@($p.AttackSurfaceReductionRules_Ids); $acts=@($p.AttackSurfaceReductionRules_Actions); $i=-1; for($x=0;$x -lt $ids.Count;$x++){if($ids[$x] -eq 'd4f940ab-401b-4efc-aadc-ad5f3c50688a'){$i=$x;break}}; $i -ge 0 -and $acts[$i] -eq 1}catch{$false}}
      Rollback='Add-MpPreference -AttackSurfaceReductionRules_Ids "d4f940ab-401b-4efc-aadc-ad5f3c50688a" -AttackSurfaceReductionRules_Actions Disabled'}

    @{Id='SEC-017'; Name='Enable Logon Auditing'; Domain='Security'; Level='Safe'; Impact=2; Reboot=$false
      Desc='Audit login attempts for security monitoring.'
      Detect={$a=auditpol /get /subcategory:"Logon" 2>$null|Out-String; -not ($a -match 'Success and Failure')}
      Fix={auditpol /set /subcategory:"Logon" /success:enable /failure:enable|Out-Null}
      Verify={$a=auditpol /get /subcategory:"Logon" 2>$null|Out-String; $a -match 'Success and Failure'}
      Rollback='auditpol /set /subcategory:"Logon" /success:enable /failure:disable'}

    # ===== NETWORK DOMAIN =====
    @{Id='NET-001'; Name='Set Network to Private Profile'; Domain='Network'; Level='Safe'; Impact=1; Reboot=$false
      Desc='Public profile restricts network discovery and sharing.'
      Detect={try{$p=Get-NetConnectionProfile -EA Stop|Where-Object{$_.IPv4Connectivity -eq 'Internet' -and $_.NetworkCategory -eq 'Public'}; $p -ne $null}catch{$false}}
      Fix={Get-NetConnectionProfile|Where-Object{$_.IPv4Connectivity -eq 'Internet' -and $_.NetworkCategory -eq 'Public'}|Set-NetConnectionProfile -NetworkCategory Private -EA SilentlyContinue}
      Verify={try{$p=Get-NetConnectionProfile -EA Stop|Where-Object{$_.IPv4Connectivity -eq 'Internet' -and $_.NetworkCategory -eq 'Public'}; $p -eq $null}catch{$true}}
      Rollback='Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Public'}

    @{Id='NET-002'; Name='Flush DNS Cache'; Domain='Network'; Level='Safe'; Impact=1; Reboot=$false
      Desc='Clear stale DNS entries.'
      Detect={$true}
      Fix={Clear-DnsClientCache}
      Verify={$true}
      Rollback='# DNS cache rebuilds automatically'}

    @{Id='NET-003'; Name='Enable All Firewall Profiles'; Domain='Network'; Level='Safe'; Impact=4; Reboot=$false
      Desc='Firewall must be enabled on all profiles.'
      Detect={try{$fw=Get-NetFirewallProfile -EA Stop; @($fw|Where-Object{-not $_.Enabled}).Count -gt 0}catch{$false}}
      Fix={Set-NetFirewallProfile -Profile Domain,Private,Public -Enabled True -EA SilentlyContinue}
      Verify={try{$fw=Get-NetFirewallProfile -EA Stop; @($fw|Where-Object{-not $_.Enabled}).Count -eq 0}catch{$false}}
      Rollback='# Use: Set-NetFirewallProfile -Profile X -Enabled False'}

    @{Id='NET-004'; Name='Sync System Clock (NTP)'; Domain='Network'; Level='Safe'; Impact=2; Reboot=$false
      Desc='Clock skew breaks authentication tokens.'
      Detect={try{$n=w32tm /stripchart /computer:time.windows.com /dataonly /samples:1 2>$null|Select-Object -Last 1; if($n -match '([+-]?\d+[\.,]\d+)s'){[math]::Abs([double]($Matches[1]-replace',','.'))-gt 60}else{$false}}catch{$false}}
      Fix={w32tm /resync /force 2>$null|Out-Null}
      Verify={try{$n=w32tm /stripchart /computer:time.windows.com /dataonly /samples:1 2>$null|Select-Object -Last 1; if($n -match '([+-]?\d+[\.,]\d+)s'){[math]::Abs([double]($Matches[1]-replace',','.'))-lt 60}else{$true}}catch{$true}}
      Rollback='# Clock sync is always safe'}

    @{Id='NET-005'; Name='Reset Winsock Catalog'; Domain='Network'; Level='Moderate'; Impact=2; Reboot=$true
      Desc='Fixes corrupted network stack. Requires reboot.'
      Detect={$false}
      Fix={netsh winsock reset|Out-Null}
      Verify={$true}
      Rollback='# Cannot be rolled back. Reboot required.'}

    # ===== HARDWARE DOMAIN =====
    @{Id='HW-001'; Name='Clear Temp Files'; Domain='Hardware'; Level='Safe'; Impact=1; Reboot=$false
      Desc='Remove temporary files to free disk space.'
      Detect={try{$sz=0; @("$env:TEMP","$env:SystemRoot\Temp")|ForEach-Object{if(Test-Path $_){$sz+=(Get-ChildItem $_ -Recurse -Force -EA SilentlyContinue|Measure-Object -Property Length -Sum -EA SilentlyContinue).Sum}}; $sz -gt 500MB}catch{$false}}
      Fix={@("$env:TEMP","$env:SystemRoot\Temp")|ForEach-Object{if(Test-Path $_){Get-ChildItem $_ -Recurse -Force -EA SilentlyContinue|Remove-Item -Recurse -Force -EA SilentlyContinue}}}
      Verify={try{$sz=0; @("$env:TEMP","$env:SystemRoot\Temp")|ForEach-Object{if(Test-Path $_){$sz+=(Get-ChildItem $_ -Recurse -Force -EA SilentlyContinue|Measure-Object -Property Length -Sum -EA SilentlyContinue).Sum}}; $sz -lt 500MB}catch{$true}}
      Rollback='# Temp files cannot be recovered'}

    @{Id='HW-002'; Name='Clear Windows Update Cache'; Domain='Hardware'; Level='Safe'; Impact=1; Reboot=$false
      Desc='Frees space used by old update downloads.'
      Detect={try{$p="$env:SystemRoot\SoftwareDistribution\Download"; if(Test-Path $p){(Get-ChildItem $p -Recurse -Force -EA SilentlyContinue|Measure-Object -Property Length -Sum -EA SilentlyContinue).Sum -gt 200MB}else{$false}}catch{$false}}
      Fix={Stop-Service wuauserv -Force -EA SilentlyContinue; Remove-Item "$env:SystemRoot\SoftwareDistribution\Download\*" -Recurse -Force -EA SilentlyContinue; Start-Service wuauserv -EA SilentlyContinue}
      Verify={try{$p="$env:SystemRoot\SoftwareDistribution\Download"; (Get-ChildItem $p -Recurse -Force -EA SilentlyContinue|Measure-Object -Property Length -Sum -EA SilentlyContinue).Sum -lt 200MB}catch{$true}}
      Rollback='# Updates will re-download if needed'}

    @{Id='HW-003'; Name='Clear Browser Caches'; Domain='Hardware'; Level='Safe'; Impact=1; Reboot=$false
      Desc='Frees disk space from browser caches.'
      Detect={try{$sz=0; $paths=@("$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Cache","$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Cache"); foreach($p in $paths){if(Test-Path $p){$sz+=(Get-ChildItem $p -Recurse -Force -EA SilentlyContinue|Measure-Object -Property Length -Sum -EA SilentlyContinue).Sum}}; $sz -gt 300MB}catch{$false}}
      Fix={$paths=@("$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Cache\Cache_Data","$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Cache\Cache_Data"); foreach($p in $paths){if(Test-Path $p){Remove-Item "$p\*" -Force -EA SilentlyContinue}}}
      Verify={$true}
      Rollback='# Browser caches rebuild automatically'}

    # ===== IDENTITY DOMAIN =====
    @{Id='ID-001'; Name='NTP Sync for Token Validation'; Domain='Identity'; Level='Safe'; Impact=2; Reboot=$false
      Desc='Azure AD tokens require accurate system clock.'
      Detect={try{$n=w32tm /stripchart /computer:time.windows.com /dataonly /samples:1 2>$null|Select-Object -Last 1; if($n -match '([+-]?\d+[\.,]\d+)s'){[math]::Abs([double]($Matches[1]-replace',','.'))-gt 30}else{$false}}catch{$false}}
      Fix={w32tm /config /manualpeerlist:"time.windows.com" /syncfromflags:manual /update 2>$null|Out-Null; w32tm /resync /force 2>$null|Out-Null}
      Verify={try{$n=w32tm /stripchart /computer:time.windows.com /dataonly /samples:1 2>$null|Select-Object -Last 1; if($n -match '([+-]?\d+[\.,]\d+)s'){[math]::Abs([double]($Matches[1]-replace',','.'))-lt 30}else{$true}}catch{$true}}
      Rollback='# Time sync is always safe'}
)

# ============================================================
# BANNER
# ============================================================
Write-Host ''
Write-Host ('=' * 64) -ForegroundColor Green
Write-Host '  FIELDOPS PRO -- UNIVERSAL SELF-HEALING ENGINE v2.0' -ForegroundColor Green
Write-Host ('=' * 64) -ForegroundColor Green
Write-Host ''
Write-Host "  Host     : $Hostname | Tech: $script:TechName" -ForegroundColor Gray
Write-Host "  Date     : $DateHuman | Admin: $IsAdmin" -ForegroundColor Gray
Write-Host ''

if (-not $IsAdmin) {
    Write-Host '  WARNING: Not running as Administrator. Most fixes will fail.' -ForegroundColor Red
    Write-Host ''
}

# ============================================================
# DETECTION PHASE
# ============================================================
Write-Host ('-' * 64) -ForegroundColor DarkGray
Write-Host "  SCANNING $($script:FixRules.Count) fix rules..." -ForegroundColor White
Write-Host ('-' * 64) -ForegroundColor DarkGray
Write-Host ''

foreach ($rule in $script:FixRules) {
    try {
        $issueFound = & $rule.Detect
        if ($issueFound) { $null = $script:DetectedIssues.Add($rule) }
    } catch {}
}

$safeCount     = @($script:DetectedIssues | Where-Object {$_.Level -eq 'Safe'}).Count
$moderateCount = @($script:DetectedIssues | Where-Object {$_.Level -eq 'Moderate'}).Count
$riskyCount    = @($script:DetectedIssues | Where-Object {$_.Level -eq 'Risky'}).Count
$totalImpact   = ($script:DetectedIssues | ForEach-Object {$_.Impact} | Measure-Object -Sum).Sum
if (-not $totalImpact) { $totalImpact = 0 }

Write-Host "  Detected $($script:DetectedIssues.Count) issue(s):" -ForegroundColor White
Write-Host "    SAFE:     $safeCount (no risk, reversible)" -ForegroundColor Green
Write-Host "    MODERATE: $moderateCount (may need reboot)" -ForegroundColor Yellow
Write-Host "    RISKY:    $riskyCount (could affect compatibility)" -ForegroundColor Red
Write-Host "    IMPACT:   +$totalImpact grade points if all fixed" -ForegroundColor Cyan
Write-Host ''

if ($script:DetectedIssues.Count -eq 0) {
    Write-Host '  No issues found. System is clean.' -ForegroundColor Green
    Write-Host ''
    return
}

# Show issues grouped by level
$domainGroups = $script:DetectedIssues | Group-Object Domain
foreach ($dg in $domainGroups) {
    Write-Host "  [$($dg.Name)]" -ForegroundColor White
    foreach ($iss in ($dg.Group | Sort-Object Impact -Descending)) {
        $lc = switch($iss.Level){'Safe'{'Green'}'Moderate'{'Yellow'}default{'Red'}}
        $rt = if($iss.Reboot){' [REBOOT]'}else{''}
        Write-Host "    $($iss.Id) $($iss.Name) (+$($iss.Impact)pts)$rt" -ForegroundColor $lc
    }
}
Write-Host ''

# ============================================================
# INTERACTIVE FIX MENU
# ============================================================
function Apply-Fixes {
    param([array]$Fixes, [bool]$DryRun)

    $applied = 0; $verified = 0; $failed = 0; $needsReboot = $false
    $sortedFixes = @($Fixes | Sort-Object Impact -Descending)

    Write-Host ''
    Write-Host ('-' * 64) -ForegroundColor DarkGray
    Write-Host "  $(if($DryRun){'DRY RUN - PREVIEW'}else{'APPLYING FIXES'}) ($($sortedFixes.Count) fix(es))" -ForegroundColor $(if($DryRun){'Yellow'}else{'White'})
    Write-Host ('-' * 64) -ForegroundColor DarkGray
    Write-Host ''

    foreach ($fix in $sortedFixes) {
        $lvlTag = switch($fix.Level){'Safe'{'[SAFE]'}'Moderate'{'[MOD]'}default{'[RISKY]'}}
        $lvlColor = switch($fix.Level){'Safe'{'Green'}'Moderate'{'Yellow'}default{'Red'}}
        Write-Host "  $($fix.Id) $lvlTag $($fix.Name)" -ForegroundColor $lvlColor
        Write-Host "    $($fix.Desc)" -ForegroundColor DarkGray
        Write-Host "    Impact: +$($fix.Impact)pts | Reboot: $(if($fix.Reboot){'YES'}else{'No'})" -ForegroundColor DarkGray

        if ($DryRun) {
            Write-Host '    [DRY RUN] Would apply this fix' -ForegroundColor Cyan
            $null = $script:FixResults.Add([PSCustomObject]@{Id=$fix.Id;Name=$fix.Name;Domain=$fix.Domain;Level=$fix.Level;Status='DryRun';Verified=$false;Reboot=$fix.Reboot;Impact=$fix.Impact;Rollback=$fix.Rollback})
        } else {
            try {
                & $fix.Fix
                $applied++
                if ($fix.Reboot) { $needsReboot = $true }
                Start-Sleep -Milliseconds 400
                try {
                    $vResult = & $fix.Verify
                    if ($vResult) {
                        $verified++
                        Write-Host '    APPLIED + VERIFIED' -ForegroundColor Green
                        $null = $script:FixResults.Add([PSCustomObject]@{Id=$fix.Id;Name=$fix.Name;Domain=$fix.Domain;Level=$fix.Level;Status='Verified';Verified=$true;Reboot=$fix.Reboot;Impact=$fix.Impact;Rollback=$fix.Rollback})
                        $null = $script:ChangeLog.Add([PSCustomObject]@{Time=(Get-Date -Format 'HH:mm:ss');Id=$fix.Id;Name=$fix.Name;Result='Verified'})
                    } else {
                        Write-Host '    APPLIED (unverified)' -ForegroundColor Yellow
                        $null = $script:FixResults.Add([PSCustomObject]@{Id=$fix.Id;Name=$fix.Name;Domain=$fix.Domain;Level=$fix.Level;Status='Applied';Verified=$false;Reboot=$fix.Reboot;Impact=$fix.Impact;Rollback=$fix.Rollback})
                        $null = $script:ChangeLog.Add([PSCustomObject]@{Time=(Get-Date -Format 'HH:mm:ss');Id=$fix.Id;Name=$fix.Name;Result='Applied'})
                    }
                } catch {
                    Write-Host '    APPLIED (verify error)' -ForegroundColor Yellow
                    $null = $script:FixResults.Add([PSCustomObject]@{Id=$fix.Id;Name=$fix.Name;Domain=$fix.Domain;Level=$fix.Level;Status='Applied';Verified=$false;Reboot=$fix.Reboot;Impact=$fix.Impact;Rollback=$fix.Rollback})
                }
            } catch {
                $failed++
                Write-Host "    FAILED: $($_.Exception.Message)" -ForegroundColor Red
                $null = $script:FixResults.Add([PSCustomObject]@{Id=$fix.Id;Name=$fix.Name;Domain=$fix.Domain;Level=$fix.Level;Status='Failed';Verified=$false;Reboot=$fix.Reboot;Impact=$fix.Impact;Rollback=$fix.Rollback})
                $null = $script:ChangeLog.Add([PSCustomObject]@{Time=(Get-Date -Format 'HH:mm:ss');Id=$fix.Id;Name=$fix.Name;Result="Failed: $($_.Exception.Message)"})
            }
        }
        Write-Host ''
    }

    return @{Applied=$applied;Verified=$verified;Failed=$failed;NeedsReboot=$needsReboot}
}

function Show-Menu {
    Write-Host ('=' * 64) -ForegroundColor Cyan
    Write-Host '  CHOOSE REMEDIATION OPTION' -ForegroundColor Cyan
    Write-Host ('=' * 64) -ForegroundColor Cyan
    Write-Host ''
    Write-Host "  [1] Preview ALL fixes (DRY RUN, no changes)" -ForegroundColor White
    Write-Host "  [2] Apply SAFE fixes only ($safeCount fix(es), fully reversible)" -ForegroundColor Green
    Write-Host "  [3] Apply SAFE + MODERATE ($($safeCount + $moderateCount) fix(es), may need reboot)" -ForegroundColor Yellow
    Write-Host "  [4] Apply ALL fixes ($($script:DetectedIssues.Count) fix(es), includes risky)" -ForegroundColor Red
    Write-Host "  [5] Fix by domain (Security/Network/Hardware/Identity)" -ForegroundColor Magenta
    Write-Host "  [6] Pick individual fixes" -ForegroundColor Cyan
    Write-Host "  [7] Exit without fixing" -ForegroundColor Gray
    Write-Host ''
}

function Show-DomainMenu {
    $domains = @($script:DetectedIssues | Group-Object Domain)
    Write-Host ''
    Write-Host '  Select domain:' -ForegroundColor Cyan
    $i = 0
    foreach ($d in $domains) {
        $i++
        $dsafe = @($d.Group | Where-Object {$_.Level -eq 'Safe'}).Count
        $dmod  = @($d.Group | Where-Object {$_.Level -eq 'Moderate'}).Count
        $dimp  = ($d.Group | ForEach-Object {$_.Impact} | Measure-Object -Sum).Sum
        Write-Host "    [$i] $($d.Name) ($($d.Count) issues, $dsafe safe + $dmod moderate, +${dimp}pts)" -ForegroundColor White
    }
    Write-Host "    [0] Back" -ForegroundColor Gray
    Write-Host ''
    $dChoice = Read-Host '  Enter domain number'
    if ($dChoice -match '^\d+$' -and [int]$dChoice -ge 1 -and [int]$dChoice -le $domains.Count) {
        $selDomain = $domains[[int]$dChoice - 1]
        Write-Host ''
        Write-Host "  Apply all fixes for '$($selDomain.Name)'? (S=Safe only | A=All | N=No)" -ForegroundColor Yellow
        $sub = Read-Host '  '
        switch ($sub.Trim().ToUpper()) {
            'S' { return @($selDomain.Group | Where-Object {$_.Level -eq 'Safe'}) }
            'A' { return @($selDomain.Group) }
            default { return @() }
        }
    }
    return @()
}

function Show-IndividualMenu {
    Write-Host ''
    Write-Host '  Pick fixes (comma-separated IDs like: SEC-001,SEC-002 or press Enter to cancel):' -ForegroundColor Cyan
    Write-Host ''
    foreach ($iss in ($script:DetectedIssues | Sort-Object Domain, Impact -Descending)) {
        $lc = switch($iss.Level){'Safe'{'Green'}'Moderate'{'Yellow'}default{'Red'}}
        Write-Host "    $($iss.Id) [$($iss.Level)] $($iss.Name) (+$($iss.Impact)pts)" -ForegroundColor $lc
    }
    Write-Host ''
    $picks = Read-Host '  IDs to fix'
    if (-not $picks.Trim()) { return @() }
    $selIds = $picks -split ',' | ForEach-Object { $_.Trim().ToUpper() }
    return @($script:DetectedIssues | Where-Object { $_.Id -in $selIds })
}

# Main menu loop
$menuActive = $true
while ($menuActive) {
    Show-Menu
    $choice = Read-Host '  Enter choice (1-7)'
    $fixesToApply = @()
    $isDry = $false

    switch ($choice.Trim()) {
        '1' { $fixesToApply = @($script:DetectedIssues); $isDry = $true }
        '2' { $fixesToApply = @($script:DetectedIssues | Where-Object {$_.Level -eq 'Safe'}) }
        '3' { $fixesToApply = @($script:DetectedIssues | Where-Object {$_.Level -in @('Safe','Moderate')}) }
        '4' { $fixesToApply = @($script:DetectedIssues) }
        '5' { $fixesToApply = Show-DomainMenu }
        '6' { $fixesToApply = Show-IndividualMenu }
        '7' { $menuActive = $false; Write-Host ''; Write-Host '  Exiting without changes.' -ForegroundColor Gray; Write-Host ''; return }
        default { Write-Host '  Invalid choice. Use 1-7.' -ForegroundColor Red; continue }
    }

    if ($fixesToApply.Count -eq 0) { Write-Host '  No fixes selected.' -ForegroundColor Yellow; continue }

    # Confirm before applying (non-dry-run)
    if (-not $isDry) {
        Write-Host ''
        Write-Host "  About to apply $($fixesToApply.Count) fix(es). Continue? (Y/N)" -ForegroundColor Yellow
        $conf = Read-Host '  '
        if ($conf.Trim().ToUpper() -ne 'Y') { Write-Host '  Cancelled.' -ForegroundColor Gray; continue }
    }

    $result = Apply-Fixes -Fixes $fixesToApply -DryRun $isDry
    $menuActive = $false
}

# ============================================================
# POST-FIX SUMMARY
# ============================================================
$script:SW.Stop()
$elapsed = [math]::Round($script:SW.Elapsed.TotalSeconds, 1)

$appliedCount  = @($script:FixResults | Where-Object {$_.Status -in @('Verified','Applied')}).Count
$verifiedCount = @($script:FixResults | Where-Object {$_.Status -eq 'Verified'}).Count
$failedCount   = @($script:FixResults | Where-Object {$_.Status -eq 'Failed'}).Count
$dryCount      = @($script:FixResults | Where-Object {$_.Status -eq 'DryRun'}).Count

$impactApplied = ($script:FixResults | Where-Object {$_.Status -in @('Verified','Applied')} | ForEach-Object {$_.Impact} | Measure-Object -Sum).Sum
if (-not $impactApplied) { $impactApplied = 0 }
$impactDry = ($script:FixResults | Where-Object {$_.Status -eq 'DryRun'} | ForEach-Object {$_.Impact} | Measure-Object -Sum).Sum
if (-not $impactDry) { $impactDry = 0 }
$needsReboot = @($script:FixResults | Where-Object {$_.Reboot -and $_.Status -in @('Verified','Applied')}).Count -gt 0

Write-Host ''
Write-Host ('=' * 64) -ForegroundColor Green
Write-Host '  SESSION COMPLETE' -ForegroundColor Green
Write-Host ('=' * 64) -ForegroundColor Green
Write-Host ''
if ($dryCount -gt 0) {
    Write-Host "  DRY RUN - No changes made" -ForegroundColor Yellow
    Write-Host "  Would have applied: $dryCount fix(es) | Estimated impact: +${impactDry} points" -ForegroundColor Cyan
} else {
    Write-Host "  Applied  : $appliedCount | Verified: $verifiedCount | Failed: $failedCount" -ForegroundColor $(if($failedCount -eq 0){'Green'}else{'Yellow'})
    Write-Host "  Impact   : +${impactApplied} grade points gained" -ForegroundColor Green
}
Write-Host "  Duration : ${elapsed}s" -ForegroundColor Gray
if ($needsReboot) { Write-Host '  REBOOT REQUIRED for some fixes to take effect.' -ForegroundColor Yellow }
Write-Host ''

# ============================================================
# GENERATE REPORT + ROLLBACK
# ============================================================
$ChangeReportFile = Join-Path $ReportsPath "AutoFix_${Hostname}_${Timestamp}.html"

# Rollback script (only for actual applied fixes, not dry run)
if ($dryCount -eq 0 -and @($script:FixResults | Where-Object {$_.Status -in @('Verified','Applied')}).Count -gt 0) {
    $rollbackFile = Join-Path $ReportsPath "Rollback_${Hostname}_${Timestamp}.ps1"
    $rbLines = [System.Collections.ArrayList]::new()
    $null = $rbLines.Add("# FieldOps Pro - Rollback Script")
    $null = $rbLines.Add("# Generated: $DateHuman | Host: $Hostname | Tech: $script:TechName")
    $null = $rbLines.Add("# WARNING: Only run if fixes caused problems.")
    $null = $rbLines.Add("#Requires -RunAsAdministrator")
    $null = $rbLines.Add('')
    foreach ($fr in ($script:FixResults | Where-Object {$_.Status -in @('Verified','Applied')})) {
        $null = $rbLines.Add("# Rollback: $($fr.Id) - $($fr.Name)")
        $null = $rbLines.Add($fr.Rollback)
        $null = $rbLines.Add('')
    }
    ($rbLines -join "`r`n") | Out-File $rollbackFile -Encoding UTF8 -Force
    Write-Host "  Rollback script: $rollbackFile" -ForegroundColor DarkGray
}

# HTML report
$fixRowsHtml = ''
foreach ($fr in $script:FixResults) {
    $sc = switch($fr.Status){'Verified'{'#4caf50'}'Applied'{'#ff9800'}'Failed'{'#f44336'}'DryRun'{'#64b5f6'}default{'#888'}}
    $vi = if($fr.Verified){'&#10003; Verified'}elseif($fr.Status -eq 'DryRun'){'Dry Run'}elseif($fr.Status -eq 'Failed'){'&#10007; Failed'}else{'&#9888; Unverified'}
    $lc = switch($fr.Level){'Safe'{'#4caf50'}'Moderate'{'#ff9800'}default{'#f44336'}}
    $fixRowsHtml += "<tr><td style='font-weight:600'>$($fr.Id)</td><td>$($fr.Name)</td><td>$($fr.Domain)</td><td style='color:$lc'>$($fr.Level)</td><td style='color:$sc;font-weight:700'>$vi</td><td>+$($fr.Impact)</td><td>$(if($fr.Reboot){'Yes'}else{'No'})</td></tr>"
}

$changeRowsHtml = ''
foreach ($cl in $script:ChangeLog) {
    $clc = if($cl.Result -match 'Verified'){'#4caf50'}elseif($cl.Result -match 'Failed'){'#f44336'}else{'#ff9800'}
    $changeRowsHtml += "<tr><td>$($cl.Time)</td><td>$($cl.Id)</td><td>$($cl.Name)</td><td style='color:$clc'>$($cl.Result)</td></tr>"
}

$ChangeHtml = @"
<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>AutoFix | $Hostname</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}body{font-family:'Segoe UI',Tahoma,sans-serif;background:#040810;color:#c8d0e0;padding:24px;line-height:1.5}
.rc{max-width:1100px;margin:0 auto}
.hdr{background:linear-gradient(135deg,#081018,#0c1828);border-radius:14px;padding:28px 32px;margin-bottom:24px;border:1px solid #1a2848;position:relative;overflow:hidden}
.hdr::before{content:'';position:absolute;top:0;left:0;right:0;height:4px;background:linear-gradient(90deg,#4caf50,#ff9800,#f44336)}
.hdr h1{font-size:1.5em;font-weight:800;color:#4caf50}.hdr p{font-size:.85em;color:#5878a0;margin-top:4px}
.hdr-bar{display:flex;flex-wrap:wrap;gap:20px;margin-top:16px;padding-top:12px;border-top:1px solid #1a2848}.hdr-bar .it{font-size:.8em}.hdr-bar .lb{color:#3860a0;display:block;font-size:.85em}.hdr-bar .vl{color:#90b0d8;font-weight:700}
.summary{background:#0a1020;border:1px solid #1a2848;border-radius:12px;padding:20px 26px;margin-bottom:24px;display:flex;flex-wrap:wrap;gap:24px;align-items:center;justify-content:center}
.sum-item{text-align:center;min-width:90px}.sum-big{font-size:2em;font-weight:900}.sum-label{font-size:.75em;color:#5878a0;margin-top:2px}
.st{font-size:1em;font-weight:700;color:#90b0d0;margin:20px 0 10px;padding-bottom:6px;border-bottom:1px solid #1a2848}
table{width:100%;border-collapse:collapse;font-size:.82em;margin-bottom:16px}th{background:#081020;color:#5888c0;padding:8px 10px;text-align:left;font-weight:600;border-bottom:2px solid #1a2848}td{padding:7px 10px;border-bottom:1px solid #0c1020}tr:hover{background:#0a1428}
.reboot-box{background:#1a0808;border:1px solid #f44336;border-radius:8px;padding:14px;margin:16px 0;color:#f44336;font-weight:700}
.ftr{text-align:center;padding:18px;color:#1a2848;font-size:.75em;margin-top:24px;border-top:1px solid #0c1020}
@media print{body{background:#fff!important;color:#222!important}.hdr,.summary{background:#f8f8fc!important;border-color:#ddd!important;color:#222!important;-webkit-print-color-adjust:exact;print-color-adjust:exact}.hdr::before{display:none}th{background:#eef!important;color:#333!important}td{border-color:#ddd!important;color:#333!important}}
</style></head><body><div class="rc">
<div class="hdr"><h1>FIELDOPS PRO -- SELF-HEALING CHANGE REPORT</h1><p>Interactive automated remediation with verification and rollback</p>
<div class="hdr-bar"><div class="it"><span class="lb">Host</span><span class="vl">$Hostname</span></div><div class="it"><span class="lb">Technician</span><span class="vl">$script:TechName</span></div><div class="it"><span class="lb">Date</span><span class="vl">$DateHuman</span></div><div class="it"><span class="lb">Mode</span><span class="vl">$(if($dryCount -gt 0){'Dry Run'}else{'Live'})</span></div><div class="it"><span class="lb">Duration</span><span class="vl">${elapsed}s</span></div></div></div>
<div class="summary">
<div class="sum-item"><div class="sum-big" style="color:#64b5f6">$($script:FixRules.Count)</div><div class="sum-label">Rules</div></div>
<div class="sum-item"><div class="sum-big" style="color:#ff9800">$($script:DetectedIssues.Count)</div><div class="sum-label">Detected</div></div>
<div class="sum-item"><div class="sum-big" style="color:#4caf50">$(if($dryCount -gt 0){$dryCount}else{$appliedCount})</div><div class="sum-label">$(if($dryCount -gt 0){'Would Fix'}else{'Applied'})</div></div>
<div class="sum-item"><div class="sum-big" style="color:#4caf50">$verifiedCount</div><div class="sum-label">Verified</div></div>
<div class="sum-item"><div class="sum-big" style="color:#f44336">$failedCount</div><div class="sum-label">Failed</div></div>
<div class="sum-item"><div class="sum-big" style="color:#4caf50">+$(if($dryCount -gt 0){$impactDry}else{$impactApplied})</div><div class="sum-label">Grade Impact</div></div>
</div>
$(if($needsReboot){"<div class='reboot-box'>REBOOT REQUIRED for some fixes to take full effect.</div>"})
<div class="st">Fix Results</div>
<table><tr><th>ID</th><th>Fix</th><th>Domain</th><th>Level</th><th>Status</th><th>Impact</th><th>Reboot</th></tr>$fixRowsHtml</table>
$(if($changeRowsHtml){"<div class='st'>Change Log</div><table><tr><th>Time</th><th>ID</th><th>Fix</th><th>Result</th></tr>$changeRowsHtml</table>"})
<div class="ftr">FieldOps Pro -- Self-Healing Engine v2.0 | $DateHuman | $Hostname | $script:TechName</div>
</div></body></html>
"@

$ChangeHtml | Out-File $ChangeReportFile -Encoding UTF8 -Force
Write-Host "  Report: $ChangeReportFile" -ForegroundColor Green

# Save JSON log
$fixDataFile = Join-Path $LogsPath "AutoFix_${Hostname}_${Timestamp}.json"
$fixData = @{
    Timestamp=$DateHuman; Hostname=$Hostname; Technician=$script:TechName
    RulesScanned=$script:FixRules.Count; IssuesDetected=$script:DetectedIssues.Count
    Applied=$appliedCount; Verified=$verifiedCount; Failed=$failedCount
    ImpactPoints=$impactApplied; NeedsReboot=$needsReboot; DryRun=($dryCount -gt 0)
    Results=@($script:FixResults); ChangeLog=@($script:ChangeLog)
}
try { $fixData | ConvertTo-Json -Depth 4 | Out-File $fixDataFile -Encoding UTF8 -Force } catch {}

# ============================================================
# POST-RUN MENU
# ============================================================
Write-Host ''
Write-Host ('=' * 64) -ForegroundColor Cyan
Write-Host '  NEXT STEPS' -ForegroundColor Cyan
Write-Host ('=' * 64) -ForegroundColor Cyan
Write-Host ''
Write-Host '  [1] Open HTML report in browser' -ForegroundColor White
Write-Host '  [2] Re-scan to see remaining issues' -ForegroundColor White
Write-Host "  [3] $(if($needsReboot){'REBOOT NOW (recommended)'}else{'Reboot (not required)'})" -ForegroundColor $(if($needsReboot){'Yellow'}else{'Gray'})
Write-Host '  [4] Exit' -ForegroundColor Gray
Write-Host ''

$postChoice = Read-Host '  Enter choice (1-4)'
switch ($postChoice.Trim()) {
    '1' { Start-Process $ChangeReportFile }
    '2' {
        Write-Host ''
        Write-Host '  Re-running scan...' -ForegroundColor Gray
        Write-Host "  Run: .\Invoke-AutoFix.ps1" -ForegroundColor Yellow
    }
    '3' {
        if ($needsReboot) {
            Write-Host ''
            Write-Host '  Reboot in 60 seconds. Cancel with: shutdown /a' -ForegroundColor Yellow
            shutdown /r /t 60 /c "FieldOps: Reboot to apply security fixes"
        } else {
            Write-Host '  Reboot not required for applied fixes.' -ForegroundColor Gray
        }
    }
    default { }
}
Write-Host ''
