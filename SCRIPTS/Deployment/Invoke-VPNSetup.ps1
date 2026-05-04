#Requires -Version 5.1
<#
.SYNOPSIS
    FieldOps Pro - VPN Setup & Configuration v2.0
.DESCRIPTION
    Resilient installer discovery -- never fails due to filename/folder changes.
    Supports: GlobalProtect, Windows Built-in VPN, Always-On Device Tunnel.
    Author: Ousman Dorley | EU Deployment | FieldOps Pro v2.0
#>

Import-Module (Join-Path $PSScriptRoot '..\Core\Logger.psm1') -Force -DisableNameChecking -EA SilentlyContinue
Import-Module (Join-Path $PSScriptRoot '..\Core\Utils.psm1')  -Force -DisableNameChecking -EA SilentlyContinue

# Assert-Admin may not exist in all environments -- safe wrapper
try { Assert-Admin } catch {}
try { Initialize-Log -Module 'VPNSetup' } catch {}

# ==============================================================================
# COLOR HELPERS
# ==============================================================================
function c  ($text, $fg = 'White', $bg = 'Black') { Write-Host $text -ForegroundColor $fg -BackgroundColor $bg -NoNewline }
function cn ($text, $fg = 'White', $bg = 'Black') { Write-Host $text -ForegroundColor $fg -BackgroundColor $bg }
function nl { Write-Host '' }
function sep { cn ('  ' + ('-' * 60)) DarkGray }

# ==============================================================================
# PATH RESOLUTION -- derived, never hardcoded
# $PSScriptRoot = E:\SCRIPTS\Deployment
# ==============================================================================
$scriptsRoot = Split-Path $PSScriptRoot -Parent        # E:\SCRIPTS
$usbRoot     = Split-Path $scriptsRoot  -Parent        # E:\
$toolsPath   = Join-Path $usbRoot 'TOOLS'
$deployPath  = Join-Path $toolsPath 'Deploy'

# ==============================================================================
# RESILIENT GLOBALPROTECT INSTALLER FINDER
# Checks multiple explicit paths first, then falls back to USB-wide scan.
# Adding a new version? Just drop it in TOOLS\Deploy\GlobalProtect\ -- done.
# ==============================================================================
function Find-GPInstaller {
    # 1 -- Explicit known paths (all version variants)
    $candidates = @(
        "$deployPath\GlobalProtect\GlobalProtect64.msi",
        "$deployPath\GlobalProtect\GlobalProtect64-6.2.2.msi",
        "$deployPath\GlobalProtect\GlobalProtect64-6.2.msi",
        "$deployPath\GlobalProtect\GlobalProtect64.exe",
        "$deployPath\GlobalProtect\GlobalProtect32.msi"
    )
    foreach ($p in $candidates) {
        if (Test-Path $p) { return $p }
    }

    # 2 -- USB-wide smart scan (resilient to folder renames/moves)
    $patterns = @('GlobalProtect*.msi', 'GlobalProtect*.exe')
    foreach ($pattern in $patterns) {
        $found = Get-ChildItem $usbRoot -Recurse -Filter $pattern -EA SilentlyContinue | Select-Object -First 1
        if ($found) { return $found.FullName }
    }

    return $null
}

# ==============================================================================
# LOAD CONFIG (optional -- system works without it)
# ==============================================================================
$config     = $null
$configPath = Join-Path $scriptsRoot 'Core\Config.psd1'
if (Test-Path $configPath) {
    try { $config = Import-PowerShellDataFile $configPath -EA Stop } catch {}
}

# ==============================================================================
# ENVIRONMENT
# ==============================================================================
$isWinPE = Test-Path 'X:\Windows\System32\wpeinit.exe'

# ==============================================================================
# SAFE LOG WRAPPER (works even if Logger module not available)
# ==============================================================================
function SafeLog {
    param([string]$Event, [string]$Detail, [string]$Level = 'INFO')
    try { Write-Log -LogEvent $Event -Detail $Detail -Level $Level } catch {}
}

function SafePause {
    try { Pause-Script } catch {
        cn '  Press any key to continue...' DarkGray
        $null = $HOST.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    }
}

# ==============================================================================
# GP INSTALL FUNCTION -- separated so option 1 can call configure after
# ==============================================================================
function Install-GlobalProtect {
    $installer = Find-GPInstaller

    if ($isWinPE) {
        cn '  [WARN] Cannot install GlobalProtect in WinPE.' Yellow
        cn '         Boot into Windows first, then run this script.' DarkGray
        SafeLog 'GP_INSTALL' 'Skipped - WinPE' 'WARN'
        return $false
    }

    # Already installed?
    $gpReg = Get-ItemProperty 'HKLM:\SOFTWARE\Palo Alto Networks\GlobalProtect' -EA SilentlyContinue
    if (-not $gpReg) {
        # Also check standard uninstall key
        $gpReg = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' -EA SilentlyContinue |
                 Get-ItemProperty -EA SilentlyContinue |
                 Where-Object { $_.DisplayName -match 'GlobalProtect' } |
                 Select-Object -First 1
    }

    if ($gpReg) {
        $ver = $gpReg.DisplayVersion
        cn "  [OK] GlobalProtect already installed: v$ver" Green
        SafeLog 'GP_INSTALLED' "Already installed v$ver" 'OK'
        return $true
    }

    if (-not $installer) {
        nl
        cn '  [ERROR] GlobalProtect installer not found on USB.' Red
        cn '  Searched all of these locations:' DarkGray
        cn "    $deployPath\GlobalProtect\GlobalProtect64*.msi" DarkGray
        cn "    Entire USB scanned for GlobalProtect*.msi / *.exe" DarkGray
        nl
        cn '  Options:' Yellow
        cn '    1. Copy installer to: ' DarkGray
        cn "       $deployPath\GlobalProtect\" Yellow
        cn '    2. Download from: https://support.paloaltonetworks.com' DarkGray
        nl
        SafeLog 'GP_INSTALL_MISSING' 'No installer found on USB' 'ERROR'
        return $false
    }

    cn "  Installing from: $installer" DarkGray
    SafeLog 'GP_INSTALL_START' "Using: $installer" 'INFO'

    try {
        if ($installer -match '\.msi$') {
            # Check for optional transform file
            $mst = Join-Path (Split-Path $installer -Parent) 'GP.mst'
            $msiArgs = "/i `"$installer`" /quiet /norestart"
            if (Test-Path $mst) { $msiArgs += " TRANSFORMS=`"$mst`"" }
            $proc = Start-Process 'msiexec.exe' -ArgumentList $msiArgs -Wait -PassThru -WindowStyle Hidden -EA Stop
        } else {
            $proc = Start-Process $installer -ArgumentList '/quiet /norestart' -Wait -PassThru -WindowStyle Hidden -EA Stop
        }

        if ($proc.ExitCode -in @(0, 3010, 1641)) {
            cn '  [OK] GlobalProtect installed successfully.' Green
            SafeLog 'GP_INSTALL_OK' "Exit code: $($proc.ExitCode)" 'OK'
            if ($proc.ExitCode -in @(3010, 1641)) {
                cn '  [INFO] A reboot is required to complete installation.' Yellow
            }
            return $true
        } else {
            cn "  [WARN] Installer exited with code: $($proc.ExitCode)" Yellow
            SafeLog 'GP_INSTALL_WARN' "Exit code: $($proc.ExitCode)" 'WARN'
            return $false
        }
    } catch {
        cn "  [ERROR] Installation error: $_" Red
        SafeLog 'GP_INSTALL_FAIL' "$_" 'ERROR'
        return $false
    }
}

# ==============================================================================
# GP CONFIGURE FUNCTION
# ==============================================================================
function Configure-GlobalProtect {
    nl; cn '  GlobalProtect Configuration' Cyan; sep

    # Portal: try config file first, then ask
    $portal = ''
    if ($config -and $config.GPPortal -and -not [string]::IsNullOrWhiteSpace($config.GPPortal)) {
        $portal = $config.GPPortal
        cn "  Portal from Config.psd1: $portal" DarkGray
        c  '  Press Enter to use this, or type a new address: ' DarkGray
        $override = Read-Host
        if (-not [string]::IsNullOrWhiteSpace($override)) { $portal = $override.Trim() }
    } else {
        c '  GlobalProtect portal address (e.g. vpn.company.com): ' DarkGray
        $portal = (Read-Host).Trim()
    }

    if ([string]::IsNullOrWhiteSpace($portal)) {
        cn '  [ERROR] Portal address is required.' Red
        SafeLog 'GP_CONFIG' 'No portal provided' 'ERROR'
        return
    }

    SafeLog 'GP_PORTAL' "Portal: $portal" 'INFO'

    # Write portal to registry
    try {
        $regPath = 'HKLM:\SOFTWARE\Palo Alto Networks\GlobalProtect\PanSetup'
        if (-not (Test-Path $regPath)) { New-Item $regPath -Force | Out-Null }
        Set-ItemProperty $regPath -Name 'Portal'    -Value $portal -Type String -Force
        Set-ItemProperty $regPath -Name 'Prelogon'  -Value 0       -Type DWord  -Force
        cn "  [OK] Portal configured: $portal" Green
        SafeLog 'GP_REG_OK' "Portal: $portal" 'OK'
    } catch {
        cn "  [WARN] Registry write failed: $_" Yellow
        SafeLog 'GP_REG_FAIL' "$_" 'WARN'
    }

    # Test portal connectivity
    cn '  Testing portal connectivity on port 443...' Yellow
    try {
        $tcp  = New-Object System.Net.Sockets.TcpClient
        $conn = $tcp.BeginConnect($portal, 443, $null, $null)
        $ok   = $conn.AsyncWaitHandle.WaitOne(5000, $false)
        $tcp.Close()
        if ($ok) {
            cn "  [OK] $portal`:443 reachable." Green
            SafeLog 'GP_PORTAL_TEST' "$portal`:443 OK" 'OK'
        } else {
            cn "  [WARN] $portal`:443 unreachable. Check network/firewall." Yellow
            SafeLog 'GP_PORTAL_TEST' "$portal`:443 unreachable" 'WARN'
        }
    } catch {
        cn '  [WARN] Connectivity test failed.' Yellow
    }

    # Start PanGPS service
    cn '  Starting PanGPS service...' Yellow
    try {
        $svc = Get-Service 'PanGPS' -EA Stop
        if ($svc.Status -ne 'Running') {
            Start-Service 'PanGPS' -EA Stop
            cn '  [OK] PanGPS service started.' Green
        } else {
            cn '  [OK] PanGPS service already running.' Green
        }
        SafeLog 'GP_SERVICE' 'PanGPS running' 'OK'
    } catch {
        cn '  [WARN] PanGPS service not found -- may need reboot after install.' Yellow
        SafeLog 'GP_SERVICE' 'PanGPS not found' 'WARN'
    }

    # Launch GP UI
    $gpUI = 'C:\Program Files\Palo Alto Networks\GlobalProtect\PanGP.exe'
    if (Test-Path $gpUI) {
        cn '  Launching GlobalProtect UI...' Yellow
        Start-Process $gpUI -EA SilentlyContinue
        cn '  [OK] GlobalProtect UI launched.' Green
    }

    nl; cn "  [DONE] GlobalProtect configured for portal: $portal" Green
    SafeLog 'GP_COMPLETE' "Portal: $portal" 'OK'
}

# ==============================================================================
# MAIN MENU
# ==============================================================================
Clear-Host
nl
cn '  ================================================================' Cyan
cn '     VPN SETUP & CONFIGURATION' Cyan
cn '  ================================================================' Cyan
nl

$gpInstaller = Find-GPInstaller
c  '  GlobalProtect installer: ' DarkGray
if ($gpInstaller) { cn "[FOUND] $gpInstaller" Green }
else              { cn '[NOT FOUND on USB]' DarkGray }
nl

cn '  [1]  GlobalProtect (Palo Alto) -- Install + Configure' Green
cn '  [2]  GlobalProtect -- Configure only (already installed)' Green
cn '  [3]  Windows Built-in VPN (L2TP / IKEv2 / SSTP)' Cyan
cn '  [4]  Always-On VPN (Device tunnel)' Cyan
cn '  [5]  Check VPN status' Yellow
cn '  [6]  Remove all VPN connections' Red
cn '  [Q]  Return to main menu' Red
nl
c '  Select option: ' DarkGray

$vpnChoice = (Read-Host).Trim().ToUpper()

switch ($vpnChoice) {

    # ==========================================================================
    # 1 -- GLOBALPROTECT INSTALL + CONFIGURE
    # ==========================================================================
    '1' {
        nl; cn '  [1/2] Installing GlobalProtect...' Yellow
        $installed = Install-GlobalProtect
        if ($installed) {
            nl; cn '  [2/2] Configuring GlobalProtect...' Yellow
            Configure-GlobalProtect
        } else {
            SafePause
        }
    }

    # ==========================================================================
    # 2 -- GLOBALPROTECT CONFIGURE ONLY
    # ==========================================================================
    '2' {
        Configure-GlobalProtect
    }

    # ==========================================================================
    # 3 -- WINDOWS BUILT-IN VPN
    # ==========================================================================
    '3' {
        nl; cn '  Windows Built-in VPN Setup' Cyan

        if ($isWinPE) {
            cn '  [WARN] VPN profiles cannot be configured in WinPE.' Yellow
            SafePause; return
        }

        c '  Connection name (e.g. Company VPN): ' DarkGray
        $vpnName   = (Read-Host).Trim()
        c '  VPN server address: ' DarkGray
        $vpnServer = (Read-Host).Trim()

        cn '  VPN type: [1] IKEv2  [2] L2TP/IPsec  [3] SSTP  [4] PPTP' DarkGray
        c '  Select type: ' DarkGray
        $vpnType = switch ((Read-Host).Trim()) {
            '1' { 'IKEv2' }
            '2' { 'L2tp'  }
            '3' { 'Sstp'  }
            '4' { 'Pptp'  }
            default { 'IKEv2' }
        }

        $useL2tpPSK = $false; $psk = ''
        if ($vpnType -eq 'L2tp') {
            c '  Use pre-shared key? (Y/N): ' DarkGray
            if ((Read-Host).Trim().ToUpper() -eq 'Y') {
                c '  Pre-shared key: ' DarkGray
                $psk = (Read-Host).Trim()
                $useL2tpPSK = $true
            }
        }

        nl; cn "  Creating VPN connection '$vpnName'..." Yellow
        try {
            Get-VpnConnection -Name $vpnName -EA SilentlyContinue | Remove-VpnConnection -Force -EA SilentlyContinue

            $params = @{
                Name                 = $vpnName
                ServerAddress        = $vpnServer
                TunnelType           = $vpnType
                AuthenticationMethod = @('MSChapv2', 'Eap')
                EncryptionLevel      = 'Required'
                RememberCredential   = $true
                SplitTunneling       = $false
                PassThru             = $true
            }
            if ($useL2tpPSK -and $psk) {
                $params['L2tpPsk']            = $psk
                $params['AuthenticationMethod'] = @('MSChapv2')
            }

            Add-VpnConnection @params -EA Stop | Out-Null
            cn "  [OK] VPN '$vpnName' created." Green
            SafeLog 'VPN_CREATED' "$vpnName | $vpnServer | $vpnType" 'OK'

            c '  Add private range split-tunnel routes? (Y/N): ' DarkGray
            if ((Read-Host).Trim().ToUpper() -eq 'Y') {
                foreach ($r in @('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16')) {
                    try {
                        Add-VpnConnectionRoute -ConnectionName $vpnName -DestinationPrefix $r -EA SilentlyContinue
                        cn "  [OK] Route added: $r" Green
                    } catch {}
                }
                Set-VpnConnection -Name $vpnName -SplitTunneling $true -EA SilentlyContinue
            }
        } catch {
            cn "  [ERROR] VPN creation failed: $_" Red
            SafeLog 'VPN_FAIL' "$_" 'ERROR'
        }
    }

    # ==========================================================================
    # 4 -- ALWAYS-ON VPN (DEVICE TUNNEL)
    # ==========================================================================
    '4' {
        nl; cn '  Always-On VPN (Device Tunnel)' Cyan
        cn '  Requires: Windows 10 1709+ Enterprise, domain or AAD joined.' DarkGray

        if ($isWinPE) {
            cn '  [ERROR] Cannot configure in WinPE.' Red
            SafePause; return
        }

        c '  Device tunnel name (e.g. CorpDeviceTunnel): ' DarkGray
        $vpnName   = (Read-Host).Trim()
        c '  VPN server address: ' DarkGray
        $vpnServer = (Read-Host).Trim()

        nl; cn "  Creating Always-On device tunnel '$vpnName'..." Yellow
        try {
            Get-VpnConnection -Name $vpnName -AllUserConnection -EA SilentlyContinue |
                Remove-VpnConnection -Force -AllUserConnection -EA SilentlyContinue

            Add-VpnConnection -Name $vpnName -ServerAddress $vpnServer `
                -TunnelType 'IKEv2' -AuthenticationMethod @('MachineCertificate') `
                -EncryptionLevel 'Maximum' -AllUserConnection -SplitTunneling:$false `
                -PassThru -EA Stop | Out-Null

            Set-VpnConnection -Name $vpnName -DeviceTunnel $true -AllUserConnection $true -EA SilentlyContinue

            cn "  [OK] Device tunnel created: $vpnName" Green
            cn '  [INFO] Machine certificates must be deployed via Intune/GPO.' Cyan
            SafeLog 'AON_VPN_OK' "$vpnName | $vpnServer" 'OK'
        } catch {
            cn "  [ERROR] Always-On VPN failed: $_" Red
            SafeLog 'AON_VPN_FAIL' "$_" 'ERROR'
        }
    }

    # ==========================================================================
    # 5 -- VPN STATUS
    # ==========================================================================
    '5' {
        nl; cn '  VPN Status Check' Cyan; sep

        # Windows VPN connections
        nl; cn '  Windows VPN connections:' Yellow
        try {
            $vpns = Get-VpnConnection -EA Stop
            if ($vpns) {
                foreach ($v in $vpns) {
                    $sc = if ($v.ConnectionStatus -eq 'Connected') { 'Green' } elseif ($v.ConnectionStatus -eq 'Connecting') { 'Yellow' } else { 'Gray' }
                    c ('  ' + $v.Name.PadRight(30)) White
                    c (' ' + $v.ConnectionStatus.PadRight(15)) $sc
                    cn "| $($v.TunnelType) | $($v.ServerAddress)" DarkGray
                    SafeLog 'VPN_STATUS' "$($v.Name) | $($v.ConnectionStatus)" 'INFO'
                }
            } else {
                cn '  No Windows VPN connections configured.' DarkGray
            }
        } catch {
            cn '  Get-VpnConnection unavailable (WinPE or missing module).' DarkGray
        }

        # All-user connections
        try {
            $vpnsAll = Get-VpnConnection -AllUserConnection -EA SilentlyContinue
            if ($vpnsAll) {
                nl; cn '  All-user (device tunnel) connections:' Yellow
                foreach ($v in $vpnsAll) {
                    c ('  ' + $v.Name.PadRight(30)) Cyan; cn $v.ConnectionStatus White
                }
            }
        } catch {}

        # GlobalProtect service
        nl; cn '  GlobalProtect service:' Yellow
        try {
            $gp = Get-Service 'PanGPS' -EA Stop
            $sc = if ($gp.Status -eq 'Running') { 'Green' } else { 'Red' }
            c '  PanGPS: ' DarkGray; cn $gp.Status $sc
            SafeLog 'GP_STATUS' "PanGPS: $($gp.Status)" $(if($gp.Status -eq 'Running'){'OK'}else{'WARN'})
        } catch {
            cn '  GlobalProtect not installed.' DarkGray
        }

        # Active VPN-port connections
        nl; cn '  Active connections on VPN ports (443/500/4500/1701):' Yellow
        try {
            $vpnConns = Get-NetTCPConnection -State Established -EA Stop |
                        Where-Object { $_.RemotePort -in @(443, 1194, 500, 4500, 1701, 1723) }
            if ($vpnConns) {
                foreach ($c2 in $vpnConns) {
                    cn "  $($c2.RemoteAddress):$($c2.RemotePort)" Cyan
                }
            } else {
                cn '  No active VPN-related connections.' DarkGray
            }
        } catch {}
    }

    # ==========================================================================
    # 6 -- REMOVE ALL VPN CONNECTIONS
    # ==========================================================================
    '6' {
        nl; cn '  [WARN] This will remove ALL VPN connections!' Red
        c '  Type YES to confirm: ' Yellow
        if ((Read-Host).Trim() -eq 'YES') {
            try {
                Get-VpnConnection -EA SilentlyContinue | ForEach-Object {
                    Remove-VpnConnection -Name $_.Name -Force -EA SilentlyContinue
                    cn "  Removed: $($_.Name)" Yellow
                    SafeLog 'VPN_REMOVED' $_.Name 'INFO'
                }
                Get-VpnConnection -AllUserConnection -EA SilentlyContinue | ForEach-Object {
                    Remove-VpnConnection -Name $_.Name -Force -AllUserConnection -EA SilentlyContinue
                    cn "  Removed (all-user): $($_.Name)" Yellow
                }
                cn '  [OK] All VPN connections removed.' Green
            } catch {
                cn "  [ERROR] $_" Red
            }
        } else {
            cn '  Cancelled.' DarkGray
        }
    }

    'Q' {
        try { Close-Log -Result 'CANCELLED' } catch {}
        return
    }

    default {
        cn '  [!] Invalid option.' Red
    }
}

nl; cn '  ================================================================' Green
cn '     VPN SETUP COMPLETE' Green
cn '  ================================================================' Green

try { Close-Log -Result 'COMPLETED' } catch {}
SafePause
