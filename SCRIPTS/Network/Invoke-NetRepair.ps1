<#
.SYNOPSIS
    FieldOps Pro - Network Diagnostic & Repair Engine v2.0
.DESCRIPTION
    12-section network analysis with context-aware scoring, interactive remediation,
    and professional visual HTML report. Detects network profile, firewall status,
    GlobalProtect from registry, MTU issues, and active connections.
.NOTES
    Author  : FieldOps Pro
    Version : 2.0
    Requires: PowerShell 5.1, Administrator recommended
    Location: E:\SCRIPTS\Network\Invoke-NetRepair.ps1
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
# CONFIGURATION
# ============================================================
$Config = @{
    PingCount         = 4;  PingTimeoutMs = 2000
    LatencyWarnMs     = 50; LatencyFailMs = 200
    LossWarnPct       = 5;  LossFailPct   = 20
    WiFiWarnPct       = 40; WiFiFailPct   = 20
    DnsTimeoutSec     = 5
    NetTestUrl        = 'http://www.msftconnecttest.com/connecttest.txt'
    NetTestExpect     = 'Microsoft Connect Test'
    VirtualPatterns   = @('Bluetooth','VMware','Hyper-V','vEthernet','VirtualBox','PANGP','GlobalProtect','Loopback','Teredo','isatap','6to4','Docker','WSL')
    PortTimeoutMs     = 3000
    MtuTestTarget     = '8.8.8.8'
    MtuTestSizes      = @(1472, 1400, 1300, 1200)  # bytes, descending
}

# ============================================================
# RESULTS ENGINE
# ============================================================
$script:Results  = [System.Collections.ArrayList]::new()
$script:Findings = [System.Collections.ArrayList]::new()
$script:CheckCount = 0
$script:Stopwatch  = [System.Diagnostics.Stopwatch]::StartNew()

function Convert-StatusToLogLevel { param([string]$S); switch ($S) { 'Pass' {'OK'} 'Warning' {'WARN'} 'Fail' {'ERROR'} default {'INFO'} } }

function Add-Check {
    param([string]$Category,[string]$Check,[string]$Status,[string]$Value,[string]$Detail)
    $script:CheckCount++
    $null = $script:Results.Add([PSCustomObject]@{ Number=$script:CheckCount; Category=$Category; Check=$Check; Status=$Status; Value=$Value; Detail=$Detail })
    $icon = switch ($Status) { 'Pass' {'[PASS]'} 'Warning' {'[WARN]'} 'Fail' {'[FAIL]'} default {'[INFO]'} }
    Write-Host "  $icon $Check : $Value" -ForegroundColor $(switch ($Status) { 'Pass' {'Green'} 'Warning' {'Yellow'} 'Fail' {'Red'} default {'Cyan'} })
    Write-Log -Message "$icon $Check = $Value | $Detail" -Level (Convert-StatusToLogLevel $Status)
}

function Add-Finding {
    param([string]$Severity,[string]$Title,[string]$Detail,[string]$Action,[array]$FixCommands,[int]$FixMinutes=5)
    $null = $script:Findings.Add([PSCustomObject]@{ Severity=$Severity; Title=$Title; Detail=$Detail; Action=$Action; FixCommands=$FixCommands; FixMinutes=$FixMinutes })
}

# ============================================================
# HELPERS
# ============================================================
function Test-TcpPort {
    param([string]$H,[int]$P,[int]$T=3000)
    try { $c=New-Object System.Net.Sockets.TcpClient; $r=$c.BeginConnect($H,$P,$null,$null); $w=$r.AsyncWaitHandle.WaitOne($T,$false); if($w -and $c.Connected){$c.Close();$true}else{$c.Close();$false} } catch { $false }
}

function Measure-Latency {
    param([string]$Target,[int]$Count=4,[int]$Timeout=2000)
    $r=@(); for($i=0;$i -lt $Count;$i++){ try { $p=New-Object System.Net.NetworkInformation.Ping; $reply=$p.Send($Target,$Timeout); if($reply.Status -eq 'Success'){$r+=$reply.RoundtripTime}; $p.Dispose() } catch {} }
    if($r.Count -eq 0){ return [PSCustomObject]@{AvgMs=-1;MinMs=-1;MaxMs=-1;LossPct=100;Sent=$Count;Received=0} }
    [PSCustomObject]@{ AvgMs=[math]::Round(($r|Measure-Object -Average).Average,1); MinMs=($r|Measure-Object -Minimum).Minimum; MaxMs=($r|Measure-Object -Maximum).Maximum; LossPct=[math]::Round((($Count-$r.Count)/$Count)*100,1); Sent=$Count; Received=$r.Count }
}

function Test-IsVirtual {
    param([string]$Name,[string]$Desc)
    foreach ($p in $Config.VirtualPatterns) { if ($Name -match $p -or $Desc -match $p) { return $true } }
    return $false
}

# ============================================================
# HEADER
# ============================================================
$Hostname  = $env:COMPUTERNAME
$Timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$DateHuman = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host '  FieldOps Pro - Network Diagnostic & Repair Engine v2.0' -ForegroundColor Cyan
Write-Host "  Host: $Hostname | $DateHuman" -ForegroundColor Gray
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ''

# ============================================================
# DETECT: Is WiFi providing primary connectivity?
# Used for context-aware scoring throughout.
# ============================================================
$script:PrimaryAdapterName = $null
$script:PrimaryIsWiFi      = $false
try {
    $primaryRoute = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop | Sort-Object RouteMetric | Select-Object -First 1
    if ($primaryRoute) {
        $primaryAdapter = Get-NetAdapter -InterfaceIndex $primaryRoute.InterfaceIndex -ErrorAction Stop
        $script:PrimaryAdapterName = $primaryAdapter.Name
        $script:PrimaryIsWiFi = ($primaryAdapter.InterfaceDescription -match 'Wi-Fi|WiFi|Wireless|WLAN|802\.11')
    }
} catch { }

# ============================================================
# SECTION 1: NETWORK PROFILE & IDENTITY
# ============================================================
Write-Host '[Section 1/12] Network Profile' -ForegroundColor White
$script:ProfileData = [System.Collections.ArrayList]::new()
try {
    $profiles = @(Get-NetConnectionProfile -ErrorAction Stop)
    foreach ($np in $profiles) {
        try {
            $profileType = $np.NetworkCategory.ToString()
            $null = $script:ProfileData.Add([PSCustomObject]@{
                Name = $np.Name; Interface = $np.InterfaceAlias
                Category = $profileType; IPv4 = $np.IPv4Connectivity.ToString()
                IPv6 = $np.IPv6Connectivity.ToString()
            })
            $catSt = switch ($profileType) { 'DomainAuthenticated' {'Pass'} 'Private' {'Pass'} 'Public' {'Warning'} default {'Info'} }
            Add-Check -Category 'Profile' -Check "Network: $($np.Name)" `
                -Status $catSt -Value "$profileType | IPv4: $($np.IPv4Connectivity)" `
                -Detail "Adapter: $($np.InterfaceAlias) | IPv6: $($np.IPv6Connectivity)"

            if ($profileType -eq 'Public') {
                Add-Finding -Severity 'Warning' -Title "Network '$($np.Name)' set to Public" `
                    -Detail "Public profile restricts network discovery and file sharing." `
                    -Action 'Set to Private if this is a trusted network.' `
                    -FixCommands @(
                        @{ Desc = 'Set network to Private'; Cmd = "Set-NetConnectionProfile -InterfaceAlias '$($np.InterfaceAlias)' -NetworkCategory Private; Write-Host 'Set to Private'" }
                        @{ Desc = 'View all profiles'; Cmd = 'Get-NetConnectionProfile | Format-Table Name, InterfaceAlias, NetworkCategory, IPv4Connectivity -AutoSize' }
                    ) -FixMinutes 1
            }
        } catch {}
    }
} catch {
    Add-Check -Category 'Profile' -Check 'Network Profile' -Status 'Info' -Value 'Could not query' -Detail $_.Exception.Message
}

# ============================================================
# SECTION 2: WINDOWS FIREWALL STATUS
# ============================================================
Write-Host ''
Write-Host '[Section 2/12] Windows Firewall' -ForegroundColor White
$script:FirewallData = [System.Collections.ArrayList]::new()
try {
    $fwProfiles = @(Get-NetFirewallProfile -ErrorAction Stop)
    foreach ($fw in $fwProfiles) {
        $enabled = $fw.Enabled
        $st = if ($enabled) { 'Pass' } else { 'Fail' }
        $null = $script:FirewallData.Add([PSCustomObject]@{
            Profile = $fw.Name; Enabled = $enabled
            DefaultIn = $fw.DefaultInboundAction.ToString()
            DefaultOut = $fw.DefaultOutboundAction.ToString()
        })
        Add-Check -Category 'Firewall' -Check "Firewall ($($fw.Name))" `
            -Status $st -Value "$(if ($enabled) {'Enabled'} else {'DISABLED'})" `
            -Detail "Inbound: $($fw.DefaultInboundAction) | Outbound: $($fw.DefaultOutboundAction)"

        if (-not $enabled) {
            Add-Finding -Severity 'Critical' -Title "$($fw.Name) firewall DISABLED" `
                -Detail 'Windows Firewall is off for this profile. System is exposed.' `
                -Action 'Enable the firewall immediately.' `
                -FixCommands @(
                    @{ Desc = "Enable $($fw.Name) firewall"; Cmd = "Set-NetFirewallProfile -Profile $($fw.Name) -Enabled True; Write-Host '$($fw.Name) firewall enabled'" }
                ) -FixMinutes 1
        }
    }
} catch {
    Add-Check -Category 'Firewall' -Check 'Firewall Status' -Status 'Info' -Value 'Could not query' -Detail $_.Exception.Message
}

# ============================================================
# SECTION 3: ADAPTER INVENTORY (context-aware)
# ============================================================
Write-Host ''
Write-Host '[Section 3/12] Adapter Inventory' -ForegroundColor White
$script:AdapterData = [System.Collections.ArrayList]::new()
try {
    $adapters = @(Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Virtual -eq $false -or $_.InterfaceDescription -match 'VPN|Pangp|GlobalProtect' } | Sort-Object Status)
    foreach ($a in $adapters) {
        try {
            $speedStr = if ($a.LinkSpeed) { $a.LinkSpeed } else { 'N/A' }
            $isUp = ($a.Status -eq 'Up')
            $null = $script:AdapterData.Add([PSCustomObject]@{
                Name=$a.Name; Desc=$a.InterfaceDescription; Status=$a.Status
                MAC=$a.MacAddress; Speed=$speedStr; Index=$a.ifIndex; MediaType=$a.MediaType
            })

            # Context-aware: disconnected Ethernet is Info when WiFi is primary
            $st = if ($isUp) { 'Pass' }
                  elseif ($a.Status -eq 'Disconnected' -and $script:PrimaryIsWiFi) { 'Info' }
                  elseif ($a.Status -eq 'Disabled' -and $a.InterfaceDescription -match 'PANGP|GlobalProtect') { 'Info' }
                  else { 'Info' }

            Add-Check -Category 'Adapters' -Check "$($a.Name) ($($a.InterfaceDescription))" `
                -Status $st -Value "$($a.Status) | $speedStr" `
                -Detail "MAC: $($a.MacAddress) | Primary: $(if ($a.Name -eq $script:PrimaryAdapterName) {'Yes'} else {'No'})"

            # Only warn about disconnected Ethernet if WiFi is NOT providing connectivity
            if ($a.Status -eq 'Disconnected' -and $a.MediaType -eq '802.3' -and -not $script:PrimaryIsWiFi) {
                Add-Finding -Severity 'Warning' -Title "Ethernet '$($a.Name)' disconnected (no WiFi backup)" `
                    -Detail 'No wired connection and WiFi is not the primary adapter.' `
                    -Action 'Check cable or enable WiFi.' `
                    -FixCommands @(
                        @{ Desc = 'Restart adapter'; Cmd = "Restart-NetAdapter -Name '$($a.Name)' -Confirm:`$false" }
                        @{ Desc = 'Check cable'; Cmd = "Write-Host 'Verify: cable seated, switch port active, link LEDs on'" }
                    ) -FixMinutes 2
            }
        } catch {}
    }
} catch {
    Add-Check -Category 'Adapters' -Check 'Adapter Enumeration' -Status 'Info' -Value 'Could not enumerate' -Detail $_.Exception.Message
}

# ============================================================
# SECTION 4: IP CONFIGURATION (context-aware)
# ============================================================
Write-Host ''
Write-Host '[Section 4/12] IP Configuration' -ForegroundColor White
$script:IPConfigData = [System.Collections.ArrayList]::new()
try {
    $activeAdapters = @(Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' })
    foreach ($aa in $activeAdapters) {
        try {
            $isVirtual = Test-IsVirtual -Name $aa.Name -Desc $aa.InterfaceDescription
            $ipv4Addrs = @(Get-NetIPAddress -InterfaceIndex $aa.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notmatch '^169\.254\.' })
            $ipv4 = $ipv4Addrs | Select-Object -First 1
            $ipStr = if ($ipv4) { "$($ipv4.IPAddress)/$($ipv4.PrefixLength)" } else { 'None' }
            $gwRoute = Get-NetRoute -InterfaceIndex $aa.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Select-Object -First 1
            $gwStr = if ($gwRoute) { $gwRoute.NextHop } else { 'None' }
            $dnsServers = @(Get-DnsClientServerAddress -InterfaceIndex $aa.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object { $_.ServerAddresses } | Select-Object -First 2)
            $dnsStr = if ($dnsServers.Count -gt 0) { $dnsServers -join ', ' } else { 'None' }
            $dhcpEnabled = ($ipv4 -and $ipv4.PrefixOrigin -eq 'Dhcp')

            $null = $script:IPConfigData.Add([PSCustomObject]@{ Adapter=$aa.Name; IP=$ipStr; Gateway=$gwStr; DNS=$dnsStr; DHCP=$dhcpEnabled; Index=$aa.ifIndex; IsVirtual=$isVirtual })

            $hasIP = ($ipv4 -ne $null); $hasGW = ($gwStr -ne 'None'); $hasDNS = ($dnsStr -ne 'None')
            # Virtual adapters without GW = Info (they're host-only by design)
            $st = if ($isVirtual) { 'Info' }
                  elseif ($hasIP -and $hasGW -and $hasDNS) { 'Pass' }
                  elseif ($hasIP -and $hasDNS) { 'Pass' }
                  elseif ($hasIP) { 'Info' }
                  else { 'Info' }

            $dhcpLabel = if ($dhcpEnabled) { 'DHCP' } else { 'Static' }
            $virtLabel = if ($isVirtual) { ' [Virtual]' } else { '' }
            Add-Check -Category 'IP Config' -Check "$($aa.Name)$virtLabel" `
                -Status $st -Value "$ipStr | GW: $gwStr | $dhcpLabel" -Detail "DNS: $dnsStr"
        } catch {
            Add-Check -Category 'IP Config' -Check "$($aa.Name)" -Status 'Info' -Value 'Could not read' -Detail $_.Exception.Message
        }
    }
} catch {
    Add-Check -Category 'IP Config' -Check 'IP Configuration' -Status 'Info' -Value 'Could not enumerate' -Detail $_.Exception.Message
}

# ============================================================
# SECTION 5: CONNECTIVITY CHAIN
# ============================================================
Write-Host ''
Write-Host '[Section 5/12] Connectivity Chain' -ForegroundColor White
$script:ConnChain = [System.Collections.ArrayList]::new()

$defaultGW = $null
try { $gwr = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop | Select-Object -First 1; $defaultGW = $gwr.NextHop } catch {}

if ($defaultGW) {
    $gwR = Measure-Latency -Target $defaultGW
    $gwOk = ($gwR.LossPct -lt 100)
    $st = if ($gwOk -and $gwR.AvgMs -lt $Config.LatencyWarnMs) {'Pass'} elseif ($gwOk) {'Warning'} else {'Fail'}
    Add-Check -Category 'Connectivity' -Check "Gateway ($defaultGW)" -Status $st `
        -Value "$(if ($gwOk){"$($gwR.AvgMs)ms"}else{'Unreachable'}) | Loss: $($gwR.LossPct)%" `
        -Detail "Min: $($gwR.MinMs)ms Max: $($gwR.MaxMs)ms"
    $null = $script:ConnChain.Add([PSCustomObject]@{Target="Gateway ($defaultGW)";AvgMs=$gwR.AvgMs;LossPct=$gwR.LossPct;Ok=$gwOk})
    if (-not $gwOk) {
        Add-Finding -Severity 'Critical' -Title 'Gateway unreachable' -Detail "$defaultGW not responding" `
            -Action 'Check connection.' -FixCommands @(
                @{Desc='Restart network adapters';Cmd="Get-NetAdapter | Where-Object {`$_.Status -eq 'Up' -and `$_.Virtual -eq `$false} | ForEach-Object { Restart-NetAdapter -Name `$_.Name -Confirm:`$false; Write-Host `"Restarted `$(`$_.Name)`" }"}
                @{Desc='Flush ARP + renew DHCP';Cmd='netsh interface ip delete arpcache; ipconfig /release; Start-Sleep 3; ipconfig /renew'}
                @{Desc='Full stack reset (reboot needed)';Cmd='netsh winsock reset; netsh int ip reset; Write-Host "REBOOT REQUIRED"'}
            ) -FixMinutes 5
    }
} else {
    Add-Check -Category 'Connectivity' -Check 'Default Gateway' -Status 'Fail' -Value 'None configured' -Detail 'No 0.0.0.0/0 route'
    $null = $script:ConnChain.Add([PSCustomObject]@{Target='Gateway';AvgMs=-1;LossPct=100;Ok=$false})
}

$dnsR = Measure-Latency -Target '8.8.8.8'
$dnsOk = ($dnsR.LossPct -lt 100)
$st = if ($dnsOk -and $dnsR.AvgMs -lt $Config.LatencyWarnMs) {'Pass'} elseif ($dnsOk) {'Warning'} else {'Fail'}
Add-Check -Category 'Connectivity' -Check 'DNS (8.8.8.8)' -Status $st `
    -Value "$(if ($dnsOk){"$($dnsR.AvgMs)ms"}else{'Unreachable'}) | Loss: $($dnsR.LossPct)%" -Detail "$($dnsR.Received)/$($dnsR.Sent) pkts"
$null = $script:ConnChain.Add([PSCustomObject]@{Target='DNS (8.8.8.8)';AvgMs=$dnsR.AvgMs;LossPct=$dnsR.LossPct;Ok=$dnsOk})

$internetOk = $false; $iDetail = 'Not tested'
try {
    $wr = [System.Net.WebRequest]::Create($Config.NetTestUrl); $wr.Timeout = 5000
    $resp = $wr.GetResponse(); $rd = New-Object System.IO.StreamReader($resp.GetResponseStream())
    $body = $rd.ReadToEnd(); $rd.Close(); $resp.Close()
    $internetOk = ($body -match $Config.NetTestExpect)
    $iDetail = if ($internetOk) {'MS connect test passed'} else {'Unexpected response'}
} catch { $iDetail = $_.Exception.Message }
Add-Check -Category 'Connectivity' -Check 'Internet (HTTP)' -Status $(if ($internetOk){'Pass'}else{'Fail'}) `
    -Value $(if ($internetOk){'Connected'}else{'Failed'}) -Detail $iDetail
$null = $script:ConnChain.Add([PSCustomObject]@{Target='Internet';AvgMs=0;LossPct=$(if($internetOk){0}else{100});Ok=$internetOk})

if (-not $internetOk) {
    Add-Finding -Severity 'Critical' -Title 'No internet (HTTP)' -Detail $iDetail `
        -Action 'Check proxy/firewall.' -FixCommands @(
            @{Desc='Check proxy';Cmd='netsh winhttp show proxy'}
            @{Desc='Reset proxy';Cmd='netsh winhttp reset proxy; Write-Host "Reset"'}
        ) -FixMinutes 3
}

# ============================================================
# SECTION 6: DNS HEALTH
# ============================================================
Write-Host ''
Write-Host '[Section 6/12] DNS Health' -ForegroundColor White
$script:DnsData = [System.Collections.ArrayList]::new()

$dnsTests = @(
    @{Name='External (microsoft.com)';Query='www.microsoft.com'}
    @{Name='Azure AD';Query='login.microsoftonline.com'}
    @{Name='Intune';Query='manage.microsoft.com'}
    @{Name='Windows Update';Query='windowsupdate.microsoft.com'}
)

foreach ($dt in $dnsTests) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew(); $dOk=$false; $rStr='FAILED'
    try {
        $res = @(Resolve-DnsName -Name $dt.Query -Type A -DnsOnly -ErrorAction Stop | Select-Object -First 3)
        $sw.Stop(); $ms = $sw.ElapsedMilliseconds
        if ($res.Count -gt 0) {
            $ips = @($res | Where-Object {$_.QueryType -eq 'A' -or $_.QueryType -eq 'AAAA'} | ForEach-Object {$_.IPAddress})
            $rStr = if ($ips.Count -gt 0) {($ips|Select-Object -First 2) -join ', '} else {($res|Select-Object -First 1|ForEach-Object {if($_.NameHost){$_.NameHost}else{$_.Name}})}
            $dOk = $true
        }
    } catch {
        $sw.Stop(); $ms = $sw.ElapsedMilliseconds
        try { # Fallback via 8.8.8.8
            $fb = @(Resolve-DnsName -Name $dt.Query -Type A -Server '8.8.8.8' -DnsOnly -ErrorAction Stop | Select-Object -First 3)
            if ($fb.Count -gt 0) {
                $fbIps = @($fb|Where-Object{$_.QueryType -eq 'A'}|ForEach-Object{$_.IPAddress})
                $rStr = if ($fbIps.Count -gt 0) {($fbIps -join ', ') + ' (via 8.8.8.8)'} else {'Resolved via 8.8.8.8'}
                $dOk = $true
            }
        } catch {}
    }
    if (-not $sw.IsRunning) {} else { $sw.Stop(); $ms = $sw.ElapsedMilliseconds }
    $st = if ($dOk -and $ms -lt 500){'Pass'} elseif ($dOk -and $ms -lt 2000){'Pass'} elseif ($dOk){'Warning'} else {'Fail'}
    Add-Check -Category 'DNS' -Check "DNS - $($dt.Name)" -Status $st -Value "$rStr (${ms}ms)" -Detail $dt.Query
    $null = $script:DnsData.Add([PSCustomObject]@{Name=$dt.Name;Query=$dt.Query;Result=$rStr;TimeMs=$ms;Ok=$dOk})
    if (-not $dOk -and $dt.Query -eq 'www.microsoft.com') {
        Add-Finding -Severity 'Critical' -Title 'DNS resolution failing' -Detail "Cannot resolve $($dt.Query)" `
            -Action 'Fix DNS configuration.' -FixCommands @(
                @{Desc='Flush DNS';Cmd='Clear-DnsClientCache; Write-Host "Flushed"'}
                @{Desc='Register DNS';Cmd='ipconfig /registerdns; Write-Host "Registered"'}
                @{Desc='Set DNS to Google';Cmd="`$idx=(Get-NetAdapter|Where-Object Status -eq 'Up'|Where-Object Virtual -eq `$false|Select-Object -First 1).ifIndex;Set-DnsClientServerAddress -InterfaceIndex `$idx -ServerAddresses '8.8.8.8','8.8.4.4';Write-Host 'DNS set'"}
            ) -FixMinutes 2
    }
}

# Reverse lookup
try {
    $sw3=[System.Diagnostics.Stopwatch]::StartNew()
    $rv=@(Resolve-DnsName -Name '8.8.8.8' -Type PTR -DnsOnly -ErrorAction Stop|Select-Object -First 1); $sw3.Stop()
    $rvN=if($rv -and $rv.NameHost){$rv.NameHost}else{'Unknown'}
    Add-Check -Category 'DNS' -Check 'Reverse (8.8.8.8)' -Status $(if($sw3.ElapsedMilliseconds -lt 1000){'Pass'}else{'Warning'}) `
        -Value "$rvN ($($sw3.ElapsedMilliseconds)ms)" -Detail 'PTR 8.8.8.8'
} catch { Add-Check -Category 'DNS' -Check 'Reverse (8.8.8.8)' -Status 'Info' -Value 'N/A' -Detail $_.Exception.Message }

# ============================================================
# SECTION 7: DHCP (filtered)
# ============================================================
Write-Host ''
Write-Host '[Section 7/12] DHCP Lease' -ForegroundColor White
try {
    $dhcpAddrs = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object {$_.PrefixOrigin -eq 'Dhcp' -and $_.IPAddress -notmatch '^169\.254\.'})
    foreach ($da in $dhcpAddrs) {
        try {
            $aObj = Get-NetAdapter -InterfaceIndex $da.InterfaceIndex -ErrorAction Stop
            if (Test-IsVirtual -Name $aObj.Name -Desc $aObj.InterfaceDescription) { continue }
            $wmi = Get-CimInstance Win32_NetworkAdapterConfiguration -ErrorAction Stop | Where-Object {$_.InterfaceIndex -eq $da.InterfaceIndex -and $_.DHCPEnabled}
            $srv = if ($wmi) {$wmi.DHCPServer} else {'Unknown'}
            $exp = if ($wmi -and $wmi.DHCPLeaseExpires) {$wmi.DHCPLeaseExpires} else {$null}
            $info = "Server: $srv"
            if ($exp) { $h=[math]::Round(($exp-(Get-Date)).TotalHours,1); $info+=" | ${h}h left"; $st=if($h -gt 2){'Pass'}elseif($h -gt 0){'Warning'}else{'Fail'} } else { $st='Pass' }
            Add-Check -Category 'DHCP' -Check "DHCP - $($aObj.Name)" -Status $st -Value "$($da.IPAddress) | $info" -Detail "Expires: $exp"
        } catch {}
    }
    # APIPA on physical UP adapters only
    $apipaAddrs = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object {$_.IPAddress -match '^169\.254\.'})
    foreach ($ap in $apipaAddrs) {
        $skip = $true
        try { $aO=Get-NetAdapter -InterfaceIndex $ap.InterfaceIndex -ErrorAction Stop; if ($aO.Status -eq 'Up' -and -not (Test-IsVirtual -Name $aO.Name -Desc $aO.InterfaceDescription)) { $skip=$false; $apName=$aO.Name } } catch {}
        if ($skip) { continue }
        Add-Check -Category 'DHCP' -Check "APIPA - $apName" -Status 'Fail' -Value "$($ap.IPAddress)" -Detail 'DHCP failed'
        Add-Finding -Severity 'Critical' -Title "APIPA on '$apName'" -Detail "$($ap.IPAddress) - no DHCP" `
            -Action 'Renew DHCP.' -FixCommands @(
                @{Desc='Renew DHCP';Cmd="ipconfig /release `"$apName`"; Start-Sleep 3; ipconfig /renew `"$apName`""}
                @{Desc='Restart adapter';Cmd="Restart-NetAdapter -Name '$apName' -Confirm:`$false; Start-Sleep 5; ipconfig /renew `"$apName`""}
            ) -FixMinutes 2
    }
} catch { Add-Check -Category 'DHCP' -Check 'DHCP' -Status 'Info' -Value 'Could not query' -Detail $_.Exception.Message }

# ============================================================
# SECTION 8: WIFI (French+English)
# ============================================================
Write-Host ''
Write-Host '[Section 8/12] WiFi Diagnostics' -ForegroundColor White
$script:WiFiData = $null
try {
    $wifiAd = Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -match 'Wi-Fi|WiFi|Wireless|WLAN|802\.11' } | Select-Object -First 1
    if ($wifiAd) {
        $wl = netsh wlan show interfaces 2>$null; $wt = $wl -join "`n"
        $ssid='Unknown'; foreach ($ln in $wl) { if ($ln -match '^\s+SSID\s*:\s*(.+)' -and $ln -notmatch 'BSSID') { $ssid=$Matches[1].Trim(); break } }
        $sigPct=0; if ($wt -match 'Signal\s*:\s*(\d+)\s*%') {$sigPct=[int]$Matches[1]} elseif ($wt -match 'Signal\s*:\s*(\d+)') {$sigPct=[int]$Matches[1]}
        $ch=0; if ($wt -match '(?:Channel|Canal)\s*:\s*(\d+)') {$ch=[int]$Matches[1]}
        $radio='Unknown'; if ($wt -match '(?:Radio type|Type de radio)\s*:\s*(.+)') {$radio=$Matches[1].Trim()}
        $auth='Unknown'; if ($wt -match '(?:Authentication|Authentification)\s*:\s*(.+)') {$auth=$Matches[1].Trim()}
        $rx='N/A'; if ($wt -match '(?:Receive rate|[Dd].bit.*?[Rr].ception)\s*(?:\(Mbps\))?\s*:\s*([\d.,]+)') {$rx=$Matches[1].Trim()-replace',','.'}
        $tx='N/A'; if ($wt -match '(?:Transmit rate|[Dd].bit.*?mission)\s*(?:\(Mbps\))?\s*:\s*([\d.,]+)') {$tx=$Matches[1].Trim()-replace',','.'}
        $band = if ($ch -gt 14){'5 GHz'} elseif ($ch -gt 0){'2.4 GHz'} else {'Unknown'}
        $dbm = if ($sigPct -gt 0){[math]::Round(($sigPct/2)-100,0)} else {-100}
        # Fallback: if signal=0 but adapter is up with good speed, mark as connected
        if ($sigPct -eq 0 -and $wifiAd.LinkSpeed -match '(\d+)' -and [int]$Matches[1] -ge 50) { $sigPct = -1 }

        $script:WiFiData = [PSCustomObject]@{Adapter=$wifiAd.Name;SSID=$ssid;SignalPct=$sigPct;ApproxDbm=$dbm;Channel=$ch;Band=$band;RadioType=$radio;Auth=$auth;RxMbps=$rx;TxMbps=$tx;LinkSpeed=$wifiAd.LinkSpeed}
        if ($sigPct -eq -1) {
            Add-Check -Category 'WiFi' -Check "WiFi - $ssid" -Status 'Pass' -Value "Connected | $($wifiAd.LinkSpeed) | Ch $ch" `
                -Detail "Auth: $auth | Radio: $radio (signal % unavailable in locale)"
        } else {
            $st = if ($sigPct -ge $Config.WiFiWarnPct){'Pass'} elseif ($sigPct -ge $Config.WiFiFailPct){'Warning'} else {'Fail'}
            Add-Check -Category 'WiFi' -Check "WiFi - $ssid ($band)" -Status $st `
                -Value "Signal: $sigPct% (~${dbm}dBm) | Ch $ch" -Detail "Auth: $auth | Radio: $radio | Rx: $rx Mbps"
            if ($st -ne 'Pass') {
                Add-Finding -Severity 'Warning' -Title "WiFi signal $(if ($st -eq 'Fail'){'weak'}else{'marginal'}) on '$ssid' (${dbm}dBm)" `
                    -Detail "Signal $sigPct%." -Action 'Move closer to AP or switch bands.' `
                    -FixCommands @(
                        @{Desc='Show networks';Cmd='netsh wlan show networks mode=bssid'}
                        @{Desc='Reconnect';Cmd="netsh wlan disconnect;Start-Sleep 3;netsh wlan connect name='$ssid'"}
                    ) -FixMinutes 2
            }
        }
    } else { Add-Check -Category 'WiFi' -Check 'WiFi' -Status 'Info' -Value 'Not connected' -Detail 'No active WiFi' }
} catch { Add-Check -Category 'WiFi' -Check 'WiFi' -Status 'Info' -Value 'Error' -Detail $_.Exception.Message }

# ============================================================
# SECTION 9: VPN STATUS (GP from registry)
# ============================================================
Write-Host ''
Write-Host '[Section 9/12] VPN Status' -ForegroundColor White
$script:VpnData = [System.Collections.ArrayList]::new()
$gpPortal = $null

# Try to find actual GP portal from registry
try {
    $gpRegPaths = @(
        'HKLM:\SOFTWARE\Palo Alto Networks\GlobalProtect\PanSetup',
        'HKLM:\SOFTWARE\Palo Alto Networks\GlobalProtect\Settings',
        'HKLM:\SOFTWARE\Palo Alto Networks\GlobalProtect\PanGPS'
    )
    foreach ($gp in $gpRegPaths) {
        if (Test-Path $gp) {
            $gpReg = Get-ItemProperty -Path $gp -ErrorAction SilentlyContinue
            # Check Portal and other possible property names
            foreach ($propName in @('Portal','portal','PortalAddress','LastPortal')) {
                if ($gpReg.PSObject.Properties.Name -contains $propName) {
                    $val = [string]$gpReg.$propName
                    # Validate: must contain a dot (real hostname), not just a number or empty
                    if ($val -match '\.') { $gpPortal = $val; break }
                }
            }
            if ($gpPortal) { break }
        }
    }
} catch {}

try {
    $vpnAds = @(Get-NetAdapter -ErrorAction Stop | Where-Object { $_.InterfaceDescription -match 'PANGP|GlobalProtect|Palo Alto' -or $_.Name -match 'GlobalProtect' })
    if ($vpnAds.Count -gt 0) {
        foreach ($va in $vpnAds) {
            $vUp = ($va.Status -eq 'Up')
            $vIP = 'None'
            if ($vUp) { try { $vIP = (Get-NetIPAddress -InterfaceIndex $va.ifIndex -AddressFamily IPv4 -ErrorAction Stop | Select-Object -First 1).IPAddress } catch {} }
            $null = $script:VpnData.Add([PSCustomObject]@{Name=$va.Name;Desc=$va.InterfaceDescription;Status=$va.Status;IP=$vIP})

            # Context: VPN disabled is Info (informational), not Warning, since user may be at home
            $st = if ($vUp) {'Pass'} else {'Info'}
            $portalInfo = if ($gpPortal) {" | Portal: $gpPortal"} else {''}
            Add-Check -Category 'VPN' -Check "GlobalProtect ($($va.Name))" -Status $st `
                -Value "$($va.Status) | IP: $vIP$portalInfo" -Detail $va.InterfaceDescription

            if (-not $vUp) {
                Add-Finding -Severity 'Info' -Title 'GlobalProtect VPN not connected' `
                    -Detail "Adapter '$($va.Name)' is $($va.Status). $(if ($gpPortal){"Portal: $gpPortal"}else{'Portal unknown.'})" `
                    -Action 'Connect if on corporate/remote network.' `
                    -FixCommands @(
                        @{Desc='Check GP processes';Cmd='Get-Process PanGP* -ErrorAction SilentlyContinue | Format-Table Name,Id,CPU -AutoSize'}
                        @{Desc='Restart GP service';Cmd='Get-Service PanGPS -ErrorAction SilentlyContinue | Restart-Service -Force; Write-Host "Restarted"'}
                        @{Desc='Launch GP UI';Cmd='Start-Process "C:\Program Files\Palo Alto Networks\GlobalProtect\PanGPA.exe" -ErrorAction SilentlyContinue'}
                    ) -FixMinutes 2
            }
        }
    } else { Add-Check -Category 'VPN' -Check 'GlobalProtect' -Status 'Info' -Value 'Not installed' -Detail 'No GP adapter' }
    # Windows VPN
    try { $wvpn = @(Get-VpnConnection -ErrorAction Stop); foreach ($wv in $wvpn) {
        Add-Check -Category 'VPN' -Check "VPN - $($wv.Name)" -Status $(if($wv.ConnectionStatus -eq 'Connected'){'Pass'}else{'Info'}) `
            -Value "$($wv.ConnectionStatus) | $($wv.ServerAddress)" -Detail "Type: $($wv.TunnelType)"
    }} catch {}
} catch { Add-Check -Category 'VPN' -Check 'VPN' -Status 'Info' -Value 'Error' -Detail $_.Exception.Message }

# ============================================================
# SECTION 10: PROXY
# ============================================================
Write-Host ''
Write-Host '[Section 10/12] Proxy & WPAD' -ForegroundColor White
$proxyEnabled=$false;$proxySrv='None';$pac='None'
try {
    $rp='HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    if (Test-Path $rp) {
        $pr=Get-ItemProperty -Path $rp -ErrorAction Stop
        $proxyEnabled=if($pr.PSObject.Properties.Name -contains 'ProxyEnable'){[bool]$pr.ProxyEnable}else{$false}
        $proxySrv=if($pr.PSObject.Properties.Name -contains 'ProxyServer' -and $pr.ProxyServer){$pr.ProxyServer}else{'None'}
        $pac=if($pr.PSObject.Properties.Name -contains 'AutoConfigURL' -and $pr.AutoConfigURL){$pr.AutoConfigURL}else{'None'}
    }
} catch {}
$pd2="Proxy: $(if($proxyEnabled){$proxySrv}else{'Direct'}) | PAC: $pac"
Add-Check -Category 'Proxy' -Check 'WinINET Proxy' -Status $(if(-not $proxyEnabled -and $pac -eq 'None'){'Pass'}else{'Info'}) -Value $pd2 -Detail "Enabled: $proxyEnabled"

try {
    $wh=netsh winhttp show proxy 2>$null; $whS=($wh|Out-String).Trim(); $whD=($whS -match '(?:Direct access|Acc.s direct)')
    Add-Check -Category 'Proxy' -Check 'WinHTTP' -Status $(if($whD){'Pass'}else{'Info'}) -Value $(if($whD){'Direct'}else{'Proxy set'}) -Detail ($whS -replace '[\r\n]+',' | ')
} catch { Add-Check -Category 'Proxy' -Check 'WinHTTP' -Status 'Info' -Value 'Error' -Detail $_.Exception.Message }

# ============================================================
# SECTION 11: PORT REACHABILITY
# ============================================================
Write-Host ''
Write-Host '[Section 11/12] Port Reachability' -ForegroundColor White
$script:PortData = [System.Collections.ArrayList]::new()

# Build port list dynamically: add actual GP portal if found
$portTests = @(
    @{Name='HTTPS';Host='www.microsoft.com';Port=443}
    @{Name='HTTP';Host='www.microsoft.com';Port=80}
    @{Name='DNS';Host='8.8.8.8';Port=53}
    @{Name='Intune';Host='manage.microsoft.com';Port=443}
    @{Name='Azure AD';Host='login.microsoftonline.com';Port=443}
    @{Name='Entra Join';Host='enterpriseregistration.windows.net';Port=443}
)
if ($gpPortal) { $portTests += @{Name='GlobalProtect Portal';Host=$gpPortal;Port=443} }
else { $portTests += @{Name='GlobalProtect (generic)';Host='portal.paloaltonetworks.com';Port=443} }

foreach ($pt in $portTests) {
    try {
        $ok = Test-TcpPort -H $pt.Host -P $pt.Port -T $Config.PortTimeoutMs
        $st = if ($ok){'Pass'} else {'Fail'}
        # GP generic portal blocked is expected and informational
        if (-not $ok -and $pt.Name -match 'generic') { $st = 'Info' }
        Add-Check -Category 'Ports' -Check "$($pt.Name) ($($pt.Host):$($pt.Port))" -Status $st `
            -Value $(if($ok){'Open'}else{'Blocked'}) -Detail "TCP $($pt.Host):$($pt.Port)"
        $null = $script:PortData.Add([PSCustomObject]@{Name=$pt.Name;Host=$pt.Host;Port=$pt.Port;Open=$ok})
        if (-not $ok -and $pt.Name -match 'Intune|Azure|Entra') {
            Add-Finding -Severity 'Warning' -Title "$($pt.Name) blocked ($($pt.Host):$($pt.Port))" `
                -Detail 'Enterprise endpoint unreachable.' -Action 'Check firewall/proxy.' `
                -FixCommands @(
                    @{Desc='Detailed test';Cmd="Test-NetConnection -ComputerName '$($pt.Host)' -Port $($pt.Port) -InformationLevel Detailed"}
                    @{Desc='Trace route';Cmd="tracert -d -w 1000 $($pt.Host)"}
                ) -FixMinutes 5
        }
    } catch { Add-Check -Category 'Ports' -Check $pt.Name -Status 'Info' -Value 'Error' -Detail $_.Exception.Message }
}

# ============================================================
# SECTION 12: PERFORMANCE + MTU
# ============================================================
Write-Host ''
Write-Host '[Section 12/12] Performance & MTU' -ForegroundColor White
$script:PerfData = [System.Collections.ArrayList]::new()

$perfTargets = @(@{Name='Gateway';Target=$defaultGW},@{Name='Google DNS';Target='8.8.8.8'},@{Name='Microsoft';Target='www.microsoft.com'})
foreach ($pf in $perfTargets) {
    if (-not $pf.Target) {continue}
    try {
        $perf = Measure-Latency -Target $pf.Target
        $jitter = if ($perf.MaxMs -gt 0 -and $perf.MinMs -ge 0){$perf.MaxMs-$perf.MinMs}else{0}
        $latSt = if ($perf.AvgMs -lt 0){'Fail'} elseif ($perf.AvgMs -ge $Config.LatencyFailMs){'Fail'} elseif ($perf.AvgMs -ge $Config.LatencyWarnMs){'Warning'} else{'Pass'}
        $losSt = if ($perf.LossPct -ge $Config.LossFailPct){'Fail'} elseif ($perf.LossPct -ge $Config.LossWarnPct){'Warning'} else{'Pass'}
        $st = if ($latSt -eq 'Fail' -or $losSt -eq 'Fail'){'Fail'} elseif ($latSt -eq 'Warning' -or $losSt -eq 'Warning'){'Warning'} else{'Pass'}
        Add-Check -Category 'Performance' -Check "Latency - $($pf.Name)" -Status $st `
            -Value "Avg: $($perf.AvgMs)ms | Loss: $($perf.LossPct)% | Jitter: ${jitter}ms" -Detail "Min: $($perf.MinMs)ms Max: $($perf.MaxMs)ms"
        $null = $script:PerfData.Add([PSCustomObject]@{Name=$pf.Name;Target=$pf.Target;AvgMs=$perf.AvgMs;MinMs=$perf.MinMs;MaxMs=$perf.MaxMs;LossPct=$perf.LossPct;Jitter=$jitter})
    } catch {}
}

# MTU Path Discovery
Write-Host '  Testing MTU...' -ForegroundColor Gray
$mtuOk = $false; $effectiveMtu = 0
foreach ($size in $Config.MtuTestSizes) {
    try {
        $p = New-Object System.Net.NetworkInformation.Ping
        $opts = New-Object System.Net.NetworkInformation.PingOptions(128, $true)  # DontFragment=true
        $buf = New-Byte[] $size
        $reply = $p.Send($Config.MtuTestTarget, 2000, $buf, $opts)
        $p.Dispose()
        if ($reply.Status -eq 'Success') { $effectiveMtu = $size + 28; $mtuOk = $true; break }  # +28 for IP+ICMP headers
    } catch { }
}
if ($mtuOk) {
    $st = if ($effectiveMtu -ge 1500){'Pass'} elseif ($effectiveMtu -ge 1400){'Pass'} else {'Warning'}
    Add-Check -Category 'Performance' -Check 'MTU Path Discovery' -Status $st -Value "Effective MTU: $effectiveMtu bytes" `
        -Detail "Largest unfragmented payload: $($effectiveMtu - 28) bytes to $($Config.MtuTestTarget)"
} else {
    Add-Check -Category 'Performance' -Check 'MTU Path Discovery' -Status 'Warning' -Value 'Could not determine' `
        -Detail 'All test sizes failed. Possible ICMP blocking or MTU issue.'
}

# ============================================================
# ACTIVE CONNECTIONS SUMMARY
# ============================================================
$script:TopConnections = [System.Collections.ArrayList]::new()
try {
    $conns = Get-NetTCPConnection -State Established -ErrorAction Stop |
        Group-Object RemoteAddress | Sort-Object Count -Descending | Select-Object -First 8
    foreach ($c in $conns) {
        $remoteHost = $c.Name
        try { $resolved = [System.Net.Dns]::GetHostEntry($c.Name).HostName } catch { $resolved = $c.Name }
        $null = $script:TopConnections.Add([PSCustomObject]@{Remote=$c.Name;Host=$resolved;Count=$c.Count})
    }
} catch {}

# ============================================================
# SCORING
# ============================================================
$script:Stopwatch.Stop()
$ElapsedSec = [math]::Round($script:Stopwatch.Elapsed.TotalSeconds, 1)
$scoredChecks = @($script:Results | Where-Object {$_.Status -in @('Pass','Warning','Fail')})
$passCount = @($scoredChecks | Where-Object {$_.Status -eq 'Pass'}).Count
$warnCount = @($scoredChecks | Where-Object {$_.Status -eq 'Warning'}).Count
$failCount = @($scoredChecks | Where-Object {$_.Status -eq 'Fail'}).Count
$infoCount = @($script:Results | Where-Object {$_.Status -eq 'Info'}).Count
$totalScored = $scoredChecks.Count
$scorePct = if ($totalScored -gt 0){[math]::Round((($passCount+($warnCount*0.5))/$totalScored)*100,0)}else{0}
$grade = if ($scorePct -ge 95){'A+'} elseif ($scorePct -ge 90){'A'} elseif ($scorePct -ge 85){'A-'} elseif ($scorePct -ge 80){'B+'} elseif ($scorePct -ge 75){'B'} elseif ($scorePct -ge 70){'C+'} elseif ($scorePct -ge 65){'C'} elseif ($scorePct -ge 60){'D'} else {'F'}
$gradeColor = if ($scorePct -ge 80){'#4caf50'} elseif ($scorePct -ge 60){'#ff9800'} else {'#f44336'}

# Category scores for breakdown
$categories = @($script:Results | Select-Object -ExpandProperty Category -Unique)
$script:CatScores = [System.Collections.ArrayList]::new()
foreach ($cat in $categories) {
    $catChecks = @($script:Results | Where-Object {$_.Category -eq $cat -and $_.Status -in @('Pass','Warning','Fail')})
    if ($catChecks.Count -eq 0) { continue }
    $cp = @($catChecks|Where-Object{$_.Status -eq 'Pass'}).Count
    $cw = @($catChecks|Where-Object{$_.Status -eq 'Warning'}).Count
    $cs = [math]::Round((($cp+($cw*0.5))/$catChecks.Count)*100,0)
    $null = $script:CatScores.Add([PSCustomObject]@{Category=$cat;Score=$cs;Checks=$catChecks.Count})
}

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host "  NETWORK ANALYSIS COMPLETE" -ForegroundColor Cyan
Write-Host "  Grade: $grade ($scorePct%) | $($script:CheckCount) checks in $ElapsedSec sec" -ForegroundColor $(if ($scorePct -ge 80){'Green'}elseif($scorePct -ge 60){'Yellow'}else{'Red'})
Write-Host "  Pass: $passCount | Warn: $warnCount | Fail: $failCount | Info: $infoCount" -ForegroundColor Gray
Write-Host '============================================================' -ForegroundColor Cyan

# Executive Summary
$actCnt = @($script:AdapterData|Where-Object{$_.Status -eq 'Up'}).Count
$wPh = if ($script:WiFiData) { $sigS=if($script:WiFiData.SignalPct -gt 0){"$($script:WiFiData.SignalPct)%"}elseif($script:WiFiData.SignalPct -eq -1){"connected"}else{"unknown"}; "WiFi '$($script:WiFiData.SSID)' ($sigS)." } else {'No WiFi.'}
$vPh = if ($script:VpnData.Count -gt 0){$vu=@($script:VpnData|Where-Object{$_.Status -eq 'Up'});if($vu.Count -gt 0){'GP VPN connected.'}else{'GP installed, not connected.'}}else{'No VPN.'}
$cPh = if ($internetOk){'Internet OK.'}else{'Internet FAILED.'}
$profPh = if ($script:ProfileData.Count -gt 0) {$pp=($script:ProfileData|Select-Object -First 1);$pp.Category}else{'Unknown'}
$ExecSummary = "$actCnt adapter(s) active. Network profile: $profPh. $wPh $vPh $cPh " +
    "$(if($script:Findings.Count -eq 0){'All clear.'}else{"$($script:Findings.Count) finding(s)."})"

# ============================================================
# INTERACTIVE REMEDIATION MENU
# ============================================================
$actionableFindings = @($script:Findings | Where-Object {$_.FixCommands -and $_.FixCommands.Count -gt 0})

if ($actionableFindings.Count -gt 0) {
    # Sort by severity (Critical first) then by fix time (quick wins first)
    $sortedFindings = @($actionableFindings | Sort-Object @{Expression={switch($_.Severity){'Critical'{0}'Warning'{1}default{2}}}}, FixMinutes)

    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Yellow
    Write-Host '  INTERACTIVE REMEDIATION MENU' -ForegroundColor Yellow
    Write-Host "  $($sortedFindings.Count) finding(s) | Sorted: critical first, quick wins first" -ForegroundColor Gray
    Write-Host '============================================================' -ForegroundColor Yellow
    Write-Host ''

    $fixIndex = 0
    foreach ($af in $sortedFindings) {
        $fixIndex++
        $sevColor = switch ($af.Severity) {'Critical'{'Red'}'Warning'{'Yellow'}default{'Cyan'}}
        $timeTag = if ($af.FixMinutes -le 2) {' [QUICK FIX]'} else {''}
        Write-Host "  [$fixIndex] $($af.Severity.ToUpper()): $($af.Title)$timeTag" -ForegroundColor $sevColor
        Write-Host "      $($af.Detail)" -ForegroundColor Gray
        $ci = 0; foreach ($fc in $af.FixCommands) { $ci++; Write-Host "      ${fixIndex}.${ci} - $($fc.Desc)" -ForegroundColor DarkCyan }
        Write-Host ''
    }

    Write-Host '  fix# (e.g. 1.2) | ALL (generate script) | SKIP' -ForegroundColor Gray
    Write-Host ''

    $keepAsking = $true
    while ($keepAsking) {
        $choice = Read-Host '  Enter choice'
        $ct = $choice.Trim().ToUpper()
        if ($ct -eq 'SKIP' -or $ct -eq '') { $keepAsking = $false }
        elseif ($ct -eq 'ALL') {
            $rp2 = Join-Path $ReportsPath "NetRemediation_${Hostname}_${Timestamp}.ps1"
            $lns = [System.Collections.ArrayList]::new()
            $null = $lns.Add("# FieldOps Pro - Network Remediation | $DateHuman | $Hostname")
            $null = $lns.Add("#Requires -RunAsAdministrator`n")
            $fi2 = 0; foreach ($af in $sortedFindings) { $fi2++; $null = $lns.Add("# === [$fi2] $($af.Severity.ToUpper()): $($af.Title) ===")
                foreach ($fc in $af.FixCommands) { $null = $lns.Add("`n# $($fc.Desc)"); $null = $lns.Add($fc.Cmd) }; $null = $lns.Add("") }
            ($lns -join "`r`n") | Out-File -FilePath $rp2 -Encoding UTF8 -Force
            Write-Host "  Saved: $rp2" -ForegroundColor Green; $keepAsking = $false
        }
        elseif ($ct -match '^(\d+)\.(\d+)$') {
            $fN=[int]$Matches[1]; $cN=[int]$Matches[2]
            if ($fN -ge 1 -and $fN -le $sortedFindings.Count) {
                $tf2=$sortedFindings[$fN-1]
                if ($cN -ge 1 -and $cN -le $tf2.FixCommands.Count) {
                    $tc2=$tf2.FixCommands[$cN-1]; Write-Host "  Running: $($tc2.Desc)" -ForegroundColor Yellow
                    $cf=Read-Host '  Execute? (Y/N)'; if($cf.Trim().ToUpper() -eq 'Y'){try{Invoke-Expression $tc2.Cmd;Write-Host '  Done.' -ForegroundColor Green}catch{Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red}}; Write-Host ''
                } else {Write-Host '  Invalid cmd#' -ForegroundColor Red}
            } else {Write-Host '  Invalid fix#' -ForegroundColor Red}
        } else {Write-Host '  Use: 1.2, ALL, or SKIP' -ForegroundColor Red}
    }
}

# ============================================================
# HTML REPORT v2.0
# ============================================================
Write-Host ''; Write-Host 'Generating HTML report...' -ForegroundColor Gray
$ReportFile = Join-Path $ReportsPath "NetRepair_${Hostname}_${Timestamp}.html"

# --- Connectivity Chain SVG ---
$cSteps=@(); $cSteps+=[PSCustomObject]@{Label='This PC';Ok=$true}
foreach($cc in $script:ConnChain){$cSteps+=[PSCustomObject]@{Label=$cc.Target;Ok=$cc.Ok}}
$cSvg=''; $cx2=30
foreach($cs in $cSteps){
    $fc2=if($cs.Ok){'#1b5e20'}else{'#b71c1c'}; $sc2=if($cs.Ok){'#4caf50'}else{'#f44336'}
    $lb2=if($cs.Label.Length -gt 18){$cs.Label.Substring(0,16)+'..'}else{$cs.Label}
    $cSvg+="<rect x='$cx2' y='15' width='130' height='40' rx='8' fill='$fc2' stroke='$sc2' stroke-width='2'/><text x='$($cx2+65)' y='40' text-anchor='middle' fill='#e0e0e0' font-size='11' font-weight='600'>$lb2</text>"
    $cx2+=130; if($cs -ne $cSteps[-1]){$ac2=if($cs.Ok){'#4caf50'}else{'#f44336'};$cSvg+="<line x1='$cx2' y1='35' x2='$($cx2+30)' y2='35' stroke='$ac2' stroke-width='2' marker-end='url(#ah)'/>";$cx2+=40}
}
$cW=$cx2+30; $chainHtml="<svg viewBox='0 0 $cW 70' xmlns='http://www.w3.org/2000/svg' style='width:100%;max-width:${cW}px;height:70px'><defs><marker id='ah' markerWidth='8' markerHeight='6' refX='8' refY='3' orient='auto'><polygon points='0 0,8 3,0 6' fill='#4caf50'/></marker></defs>$cSvg</svg>"

# --- Category Score Bars ---
$catBarsHtml = ''
foreach ($cs in $script:CatScores) {
    $bc3 = if ($cs.Score -ge 80){'#4caf50'} elseif ($cs.Score -ge 60){'#ff9800'} else {'#f44336'}
    $catBarsHtml += "<div class='cb-row'><div class='cb-label'>$($cs.Category)</div><div class='cb-track'><div class='cb-fill' style='width:$($cs.Score)%;background:$bc3'></div></div><div class='cb-val' style='color:$bc3'>$($cs.Score)%</div></div>"
}

# --- WiFi Gauge ---
$wGauge = ''
if ($script:WiFiData) {
    $wd2=$script:WiFiData; $sd=if($wd2.SignalPct -gt 0){$wd2.SignalPct}elseif($wd2.SignalPct -eq -1){75}else{0}
    $r3=50;$al2=[math]::Round([math]::PI*$r3,2);$fl2=[math]::Round(($sd/100)*$al2,2)
    $gc2=if($sd -ge 70){'#4caf50'}elseif($sd -ge 40){'#ff9800'}else{'#f44336'}
    $sl2=if($wd2.SignalPct -eq -1){'OK'}else{"$sd%"}
    $wGauge="<div class='gauge-card'><svg viewBox='0 0 120 75' style='width:120px;height:75px'><path d='M 10 65 A 50 50 0 0 1 110 65' fill='none' stroke='#1a1a3a' stroke-width='10' stroke-linecap='round'/><path d='M 10 65 A 50 50 0 0 1 110 65' fill='none' stroke='$gc2' stroke-width='10' stroke-linecap='round' stroke-dasharray='$fl2 $al2'/><text x='60' y='55' text-anchor='middle' fill='#e0e0e0' font-size='16' font-weight='800'>$sl2</text></svg><div class='gauge-label'>$($wd2.SSID)$(if($wd2.Band -ne 'Unknown'){" ($($wd2.Band))"})</div><div class='gauge-sub'>$($wd2.LinkSpeed) | Ch $($wd2.Channel) | $($wd2.Auth)</div></div>"
}

# --- Latency Bars ---
$lBars = ''
if ($script:PerfData.Count -gt 0) {
    $mxL=[math]::Max(($script:PerfData|Where-Object{$_.AvgMs -gt 0}|Measure-Object AvgMs -Maximum).Maximum,1)
    foreach($pd in $script:PerfData){
        $bp2=if($pd.AvgMs -gt 0){[math]::Min([math]::Round(($pd.AvgMs/($mxL*1.2))*100,0),100)}else{100}
        $bc4=if($pd.AvgMs -lt 0){'#f44336'}elseif($pd.AvgMs -lt $Config.LatencyWarnMs){'#4caf50'}elseif($pd.AvgMs -lt $Config.LatencyFailMs){'#ff9800'}else{'#f44336'}
        $vs2=if($pd.AvgMs -lt 0){'Timeout'}else{"$($pd.AvgMs)ms"}
        $lBars+="<div class='lat-row'><div class='lat-label'>$($pd.Name)</div><div class='lat-track'><div class='lat-fill' style='width:${bp2}%;background:$bc4'></div></div><div class='lat-val' style='color:$bc4'>$vs2</div><div class='lat-loss'>$($pd.LossPct)% loss</div></div>"
    }
}

# --- DNS Bar Chart ---
$dnsBars = ''
if ($script:DnsData.Count -gt 0) {
    $mxD=[math]::Max(($script:DnsData|Where-Object{$_.TimeMs -gt 0}|Measure-Object TimeMs -Maximum).Maximum,1)
    foreach($dd in $script:DnsData){
        $bp3=if($dd.TimeMs -gt 0){[math]::Min([math]::Round(($dd.TimeMs/($mxD*1.2))*100,0),100)}else{100}
        $bc5=if(-not $dd.Ok){'#f44336'}elseif($dd.TimeMs -lt 100){'#4caf50'}elseif($dd.TimeMs -lt 500){'#ff9800'}else{'#f44336'}
        $vs3=if($dd.Ok){"$($dd.TimeMs)ms"}else{'FAIL'}
        $dnsBars+="<div class='lat-row'><div class='lat-label'>$($dd.Name)</div><div class='lat-track'><div class='lat-fill' style='width:${bp3}%;background:$bc5'></div></div><div class='lat-val' style='color:$bc5'>$vs3</div></div>"
    }
}

# --- Port Grid ---
$pGrid = ''
foreach($pd in $script:PortData){
    $pc2=if($pd.Open){'#4caf50'}else{'#f44336'}; $pi2=if($pd.Open){'&#10003;'}else{'&#10007;'}
    $pGrid+="<div class='port-chip' style='border-color:$pc2'><span style='color:$pc2'>$pi2</span> $($pd.Name)<br><span class='port-detail'>$($pd.Host):$($pd.Port)</span></div>"
}

# --- Firewall badges ---
$fwBadges = ''
foreach ($fw in $script:FirewallData) {
    $fc3=if($fw.Enabled){'#4caf50'}else{'#f44336'}; $fi3=if($fw.Enabled){'&#128274;'}else{'&#128275;'}
    $fwBadges+="<div class='fw-badge' style='border-color:$fc3'><span style='color:$fc3'>$fi3</span> $($fw.Profile)<div class='fw-detail'>$(if($fw.Enabled){'Enabled'}else{'OFF'}) | In: $($fw.DefaultIn) | Out: $($fw.DefaultOut)</div></div>"
}

# --- Findings ---
$fHtml=''; $fi4=0
if ($script:Findings.Count -gt 0) {
    foreach($f in $script:Findings){
        $fi4++; $svc2=switch($f.Severity){'Critical'{'finding-critical'}'Warning'{'finding-warning'}default{'finding-info'}}
        $svi2=switch($f.Severity){'Critical'{'&#10007;'}'Warning'{'&#9888;'}default{'&#8505;'}}
        $fxB=''; if($f.FixCommands -and $f.FixCommands.Count -gt 0){
            $ci2='';$cx3=0; foreach($fc in $f.FixCommands){$cx3++;$cid2="fix-${fi4}-${cx3}"
                $esc2=$fc.Cmd -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;'
                $ci2+="<div class='fix-item'><div class='fix-desc'>$($fc.Desc)</div><div class='fix-cmd-wrap'><pre class='fix-cmd' id='$cid2'>$esc2</pre><button class='copy-btn' onclick=`"copyCmd('$cid2')`">Copy</button></div></div>"}
            $fxB="<div class='fix-block'><div class='fix-header' onclick='toggleFix(this)'><span class='fix-arrow'>&#9654;</span> $($f.FixCommands.Count) Fix(es)$(if($f.FixMinutes -le 2){' <span style=''color:#4caf50''>[QUICK]</span>'})</div><div class='fix-body' style='display:none'>$ci2</div></div>"
        }
        $fHtml+="<div class='finding-card $svc2'><div class='finding-title'>$svi2 $($f.Severity.ToUpper()): $($f.Title)</div><div class='finding-detail'>$($f.Detail)</div><div class='finding-action'><strong>Action:</strong> $($f.Action)</div>$fxB</div>"
    }
} else { $fHtml='<div class="finding-card finding-info"><div class="finding-title">&#10003; All clear - no issues</div></div>' }

# --- Active Connections ---
$connHtml = ''
foreach ($tc in $script:TopConnections) {
    $connHtml += "<tr><td>$($tc.Remote)</td><td>$($tc.Host)</td><td>$($tc.Count)</td></tr>"
}

# --- Check Rows ---
$crHtml = foreach($r in $script:Results){
    $sc3=switch($r.Status){'Pass'{'status-pass'}'Warning'{'status-warn'}'Fail'{'status-fail'}default{'status-info'}}
    $si3=switch($r.Status){'Pass'{'&#10003;'}'Warning'{'&#9888;'}'Fail'{'&#10007;'}default{'&#8505;'}}
    "<tr><td>$($r.Number)</td><td>$($r.Category)</td><td>$($r.Check)</td><td class='$sc3'>$si3 $($r.Status)</td><td>$($r.Value)</td><td class='detail-cell'>$($r.Detail)</td></tr>"
}

$HtmlContent = @"
<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>FieldOps Pro - Network | $Hostname</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}body{font-family:'Segoe UI',Tahoma,sans-serif;background:#08081a;color:#d8dce6;padding:24px;line-height:1.5}.rc{max-width:1200px;margin:0 auto}
.hdr{background:linear-gradient(135deg,#0c1638,#162450);border-radius:14px;padding:28px 32px;margin-bottom:24px;border:1px solid #253068}.hdr-title{font-size:1.6em;font-weight:800;color:#82b1ff}.hdr-sub{font-size:0.88em;color:#7888aa;margin-top:2px}.hdr-bar{display:flex;flex-wrap:wrap;gap:20px;margin-top:16px;padding-top:14px;border-top:1px solid #253068}.hdr-item{font-size:0.8em}.hdr-lbl{color:#5a7090}.hdr-val{color:#b8c8e0;font-weight:600}
.grade{background:linear-gradient(135deg,#0e1030,#141840);border-radius:14px;padding:24px 32px;margin-bottom:24px;border:1px solid #1e2858;display:flex;align-items:center;gap:32px}.grade-circle{width:92px;height:92px;border-radius:50%;display:flex;align-items:center;justify-content:center;font-size:2.1em;font-weight:900;flex-shrink:0;border:5px solid}.grade-det{flex:1}.grade-score{font-size:1.1em;font-weight:700}.grade-track{width:100%;height:14px;background:#141430;border-radius:7px;overflow:hidden;margin:8px 0}.grade-fill{height:100%;border-radius:7px}.grade-stats{display:flex;gap:20px;font-size:0.82em;margin-top:4px}.st-p{color:#4caf50}.st-w{color:#ff9800}.st-f{color:#f44336}.st-i{color:#64b5f6}
.exec{background:#0c0c26;border:1px solid #1c1c48;border-radius:12px;padding:18px 24px;margin-bottom:24px;font-size:0.9em;color:#a0b0c8;line-height:1.65}.exec-title{font-weight:700;color:#82b1ff;margin-bottom:6px}
.stitle{font-size:1.05em;font-weight:700;color:#82b1ff;margin:24px 0 12px;padding-bottom:6px;border-bottom:1px solid #1e1e48;display:flex;align-items:center;gap:8px}.stitle .badge{background:#1e2858;color:#7888aa;font-size:0.68em;padding:2px 7px;border-radius:10px}
.two-col{display:flex;gap:20px;flex-wrap:wrap;margin-bottom:20px}.two-col>div{flex:1;min-width:280px}
.chain-wrap{overflow-x:auto;margin-bottom:20px;padding:8px 0}
.cb-row{display:flex;align-items:center;gap:10px;margin-bottom:6px}.cb-label{width:100px;font-size:0.78em;color:#a0b0c8;font-weight:600;flex-shrink:0}.cb-track{flex:1;height:14px;background:#141430;border-radius:4px;overflow:hidden}.cb-fill{height:100%;border-radius:4px}.cb-val{width:45px;font-size:0.78em;font-weight:700;text-align:right}
.gauge-card{background:#0e0e28;border:1px solid #1e1e48;border-radius:12px;padding:14px;text-align:center;min-width:180px;display:inline-block;margin-bottom:16px}.gauge-label{font-size:0.82em;color:#b0c0d8;font-weight:600;margin-top:4px}.gauge-sub{font-size:0.7em;color:#5a7090;margin-top:2px}
.lat-row{display:flex;align-items:center;gap:10px;margin-bottom:6px}.lat-label{width:100px;font-size:0.78em;color:#a0b0c8;font-weight:600;flex-shrink:0}.lat-track{flex:1;height:16px;background:#141430;border-radius:4px;overflow:hidden}.lat-fill{height:100%;border-radius:4px}.lat-val{width:65px;font-size:0.78em;font-weight:700;text-align:right;flex-shrink:0}.lat-loss{width:60px;font-size:0.7em;color:#7888aa;flex-shrink:0}
.port-grid{display:flex;flex-wrap:wrap;gap:8px;margin-bottom:20px}.port-chip{background:#0e0e28;border:1px solid;border-radius:8px;padding:8px 12px;font-size:0.78em;font-weight:600;min-width:130px}.port-detail{font-size:0.7em;color:#5a7090;font-weight:400}
.fw-grid{display:flex;flex-wrap:wrap;gap:8px;margin-bottom:20px}.fw-badge{background:#0e0e28;border:1px solid;border-radius:8px;padding:8px 12px;font-size:0.82em;font-weight:600;min-width:130px}.fw-detail{font-size:0.7em;color:#5a7090;font-weight:400;margin-top:2px}
.finding-card{border-radius:10px;padding:12px 16px;margin-bottom:10px;border-left:5px solid}.finding-critical{background:#18080c;border-color:#f44336}.finding-warning{background:#18140a;border-color:#ff9800}.finding-info{background:#081018;border-color:#64b5f6}.finding-title{font-weight:700;margin-bottom:3px;font-size:0.92em}.finding-detail{font-size:0.82em;color:#8898aa}.finding-action{font-size:0.8em;color:#a0b0c0;margin-top:4px}
.fix-block{margin-top:8px;border:1px solid #1e2848;border-radius:8px;overflow:hidden}.fix-header{background:#0c1430;padding:8px 12px;cursor:pointer;font-size:0.82em;font-weight:600;color:#64b5f6;display:flex;align-items:center;gap:6px;user-select:none}.fix-header:hover{background:#101838}.fix-arrow{font-size:0.65em;transition:transform 0.2s;display:inline-block}.fix-arrow.open{transform:rotate(90deg)}.fix-body{padding:10px 12px;background:#080c20}.fix-item{margin-bottom:10px}.fix-desc{font-size:0.78em;color:#90a4c4;font-weight:600;margin-bottom:3px}.fix-cmd-wrap{position:relative}.fix-cmd{background:#060a18;border:1px solid #1a2040;border-radius:6px;padding:8px 10px;font-family:'Cascadia Code','Consolas',monospace;font-size:0.75em;color:#a8d0a8;white-space:pre-wrap;word-break:break-all;margin:0}.copy-btn{position:absolute;top:4px;right:4px;background:#1e2858;color:#82b1ff;border:1px solid #2a3a6e;border-radius:4px;padding:2px 8px;font-size:0.68em;cursor:pointer}.copy-btn:hover{background:#2a3a6e}
table{width:100%;border-collapse:collapse;margin-bottom:14px;font-size:0.78em}th{background:#101030;color:#7eb8ff;padding:8px 10px;text-align:left;font-weight:600;border-bottom:2px solid #252560;position:sticky;top:0}td{padding:7px 10px;border-bottom:1px solid #151538;vertical-align:top}tr:hover{background:#0e0e2a}.detail-cell{max-width:300px;word-break:break-all;color:#6878a0;font-size:0.88em}.status-pass{color:#4caf50;font-weight:600}.status-warn{color:#ff9800;font-weight:600}.status-fail{color:#f44336;font-weight:600}.status-info{color:#64b5f6;font-weight:600}
details{background:#0c0c24;border:1px solid #1a1a44;border-radius:10px;margin-bottom:16px;overflow:hidden}summary{cursor:pointer;padding:12px 18px;font-weight:600;color:#90a4c4;font-size:0.92em;user-select:none;list-style:none;display:flex;align-items:center;gap:6px}summary:hover{background:#101038}summary::-webkit-details-marker{display:none}summary::before{content:'\\25B6';font-size:0.65em;transition:transform 0.2s;display:inline-block;color:#5070a0}details[open] summary::before{transform:rotate(90deg)}details .sect-body{padding:14px 18px;overflow-x:auto}
.ftr{text-align:center;padding:18px;color:#2a3a5a;font-size:0.75em;border-top:1px solid #151538;margin-top:24px}
@media print{body{background:#fff!important;color:#222!important;padding:8px}.hdr,.grade,.exec,details,.finding-card,.gauge-card,.port-chip,.fw-badge{background:#f8f8fc!important;border-color:#ddd!important;color:#222!important;-webkit-print-color-adjust:exact;print-color-adjust:exact}.fix-cmd{background:#f0f0f0!important;color:#1a3a1a!important}.fix-header{background:#eef!important;color:#1a3a6a!important}.copy-btn{display:none!important}th{background:#eef!important;color:#1a3a6a!important}td{border-color:#ddd!important;color:#333!important}.status-pass{color:#1b7a1b!important}.status-warn{color:#b36b00!important}.status-fail{color:#c62828!important}.status-info{color:#1565c0!important}}
</style></head><body><div class="rc">
<div class="hdr"><div class="hdr-title">FieldOps Pro -- Network Diagnostic Report</div><div class="hdr-sub">12-section analysis with context-aware scoring, remediation &amp; visual diagnostics</div><div class="hdr-bar"><div class="hdr-item"><span class="hdr-lbl">Host</span> <span class="hdr-val">$Hostname</span></div><div class="hdr-item"><span class="hdr-lbl">Date</span> <span class="hdr-val">$DateHuman</span></div><div class="hdr-item"><span class="hdr-lbl">Checks</span> <span class="hdr-val">$($script:CheckCount)</span></div><div class="hdr-item"><span class="hdr-lbl">Duration</span> <span class="hdr-val">${ElapsedSec}s</span></div><div class="hdr-item"><span class="hdr-lbl">Engine</span> <span class="hdr-val">NetRepair v2.0</span></div><div class="hdr-item"><span class="hdr-lbl">Profile</span> <span class="hdr-val">$profPh</span></div></div></div>
<div class="grade"><div class="grade-circle" style="background:${gradeColor}18;border-color:$gradeColor;color:$gradeColor">$grade</div><div class="grade-det"><div class="grade-score">Network Health: $scorePct%</div><div class="grade-track"><div class="grade-fill" style="width:${scorePct}%;background:linear-gradient(90deg,$gradeColor,${gradeColor}66)"></div></div><div class="grade-stats"><span class="st-p">$passCount Pass</span><span class="st-w">$warnCount Warn</span><span class="st-f">$failCount Fail</span><span class="st-i">$infoCount Info</span></div></div></div>
<div class="exec"><div class="exec-title">Executive Summary</div>$ExecSummary</div>
<div class="stitle">Connectivity Chain</div><div class="chain-wrap">$chainHtml</div>
<div class="two-col"><div><div class="stitle">Category Breakdown</div>$catBarsHtml</div><div>$(if($wGauge){"<div class='stitle'>WiFi Signal</div>$wGauge"})</div></div>
<div class="stitle">Findings &amp; Remediation <span class="badge">$($script:Findings.Count)</span></div>$fHtml
<div class="stitle">Firewall Status</div><div class="fw-grid">$fwBadges</div>
<div class="two-col"><div><div class="stitle">Latency</div>$lBars</div><div><div class="stitle">DNS Resolution</div>$dnsBars</div></div>
<div class="stitle">Port Reachability <span class="badge">$($script:PortData.Count)</span></div><div class="port-grid">$pGrid</div>
$(if($script:TopConnections.Count -gt 0){"<details><summary>Active Connections (top $($script:TopConnections.Count))</summary><div class='sect-body'><table><tr><th>Remote IP</th><th>Hostname</th><th>Connections</th></tr>$connHtml</table></div></details>"})
<details><summary>All Checks ($($script:CheckCount))</summary><div class="sect-body"><table><tr><th>#</th><th>Category</th><th>Check</th><th>Status</th><th>Value</th><th>Detail</th></tr>$($crHtml -join '')</table></div></details>
<div class="ftr">FieldOps Pro -- NetRepair v2.0 | $DateHuman | $($script:CheckCount) checks in ${ElapsedSec}s | $Hostname</div>
</div><script>
function copyCmd(id){var el=document.getElementById(id);if(navigator.clipboard)navigator.clipboard.writeText(el.textContent).then(function(){var b=event.target;b.textContent='Copied!';setTimeout(function(){b.textContent='Copy'},2000)})}
function toggleFix(h){var b=h.nextElementSibling,a=h.querySelector('.fix-arrow');if(b.style.display==='none'){b.style.display='block';a.classList.add('open')}else{b.style.display='none';a.classList.remove('open')}}
</script></body></html>
"@

$HtmlContent | Out-File -FilePath $ReportFile -Encoding UTF8 -Force

# FieldOps-ANSSI-JSON-Sidecar-Marker - DO NOT REMOVE (idempotency check anchor)
try {
    $jsonFile = Join-Path $LogsPath ("NetRepair_${Hostname}_${Timestamp}.json")
    $allChecks = @()
    if (Get-Variable -Name 'Results' -Scope Script -EA SilentlyContinue) { $allChecks = @($script:Results) }
    $allFindings = @()
    if (Get-Variable -Name 'Findings' -Scope Script -EA SilentlyContinue) { $allFindings = @($script:Findings) }

    $reportData = [PSCustomObject]@{
        Engine     = 'NetRepair'
        Version    = '2.0'
        Hostname   = $Hostname
        Timestamp  = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Summary    = @{
            Total   = ($allChecks | Measure-Object).Count
            Pass    = ($allChecks | Where-Object { $_.Status -eq 'Pass' }    | Measure-Object).Count
            Warning = ($allChecks | Where-Object { $_.Status -eq 'Warning' } | Measure-Object).Count
            Fail    = ($allChecks | Where-Object { $_.Status -eq 'Fail' }    | Measure-Object).Count
            Info    = ($allChecks | Where-Object { $_.Status -eq 'Info' }    | Measure-Object).Count
        }
        Checks     = $allChecks
        Findings   = $allFindings
    }
    $reportData | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $jsonFile -Encoding UTF8 -Force
    Write-Host "  JSON  : $jsonFile" -ForegroundColor DarkGray
} catch {
    Write-Host "  [WARN] JSON sidecar failed: $($_.Exception.Message)" -ForegroundColor Yellow
}
Write-Host "  Report: $ReportFile" -ForegroundColor Green
Write-Host "  Start-Process `"$ReportFile`"" -ForegroundColor Yellow
Write-Host ''
