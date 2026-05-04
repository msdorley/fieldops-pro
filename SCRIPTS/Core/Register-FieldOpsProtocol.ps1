#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    FieldOps Pro -- Register fieldops:// protocol handler
.DESCRIPTION
    One-time setup. Registers the fieldops:// custom URL protocol so clicks
    on Dashboard buttons launch real PowerShell scripts.

    After this runs, clicking a link like:
        fieldops://run?script=Invoke-AutoFix.ps1
    in any browser opens a new PowerShell window that executes the script.

    SECURITY: Only scripts in E:\SCRIPTS\ (and subfolders) can be executed.
    The dispatcher (Invoke-FieldOpsHandler.ps1) validates every path against
    a whitelist. Arbitrary commands from outside the USB are rejected.

.PARAMETER Unregister
    Remove the fieldops:// protocol registration.

.EXAMPLE
    # Run once per machine as Administrator
    .\Register-FieldOpsProtocol.ps1

.EXAMPLE
    # Remove
    .\Register-FieldOpsProtocol.ps1 -Unregister
#>
[CmdletBinding()]
param(
    [switch]$Unregister
)

$ErrorActionPreference = 'Stop'

# ==============================================================
# PATH RESOLUTION
# ==============================================================
$scriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$scriptsDir  = Split-Path -Parent $scriptDir
$usbRoot     = Split-Path -Parent $scriptsDir
$handlerPath = Join-Path $scriptDir 'Invoke-FieldOpsHandler.ps1'

Write-Host ''
Write-Host '  ======================================================================' -ForegroundColor Cyan
Write-Host '  FIELDOPS PRO -- PROTOCOL HANDLER SETUP' -ForegroundColor Cyan
Write-Host '  ======================================================================' -ForegroundColor Cyan
Write-Host ''
Write-Host "  USB Root     : $usbRoot"
Write-Host "  Scripts Dir  : $scriptDir"
Write-Host "  Handler      : $handlerPath"
Write-Host ''

# Verify admin
$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [System.Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host '  [ERROR] This script must run as Administrator.' -ForegroundColor Red
    Write-Host '  Right-click PowerShell and choose "Run as Administrator".' -ForegroundColor Yellow
    exit 1
}

# ==============================================================
# UNREGISTER MODE
# ==============================================================
if ($Unregister) {
    Write-Host '  Unregistering fieldops:// protocol...' -ForegroundColor Yellow
    try {
        if (Test-Path 'HKLM:\SOFTWARE\Classes\fieldops') {
            Remove-Item -Path 'HKLM:\SOFTWARE\Classes\fieldops' -Recurse -Force
            Write-Host '  [OK] Protocol unregistered from HKLM\SOFTWARE\Classes\fieldops' -ForegroundColor Green
        } else {
            Write-Host '  [INFO] Protocol was not registered.' -ForegroundColor DarkGray
        }
    } catch {
        Write-Host "  [ERROR] Failed to unregister: $_" -ForegroundColor Red
        exit 1
    }
    Write-Host ''
    exit 0
}

# ==============================================================
# VERIFY HANDLER EXISTS
# ==============================================================
if (-not (Test-Path $handlerPath)) {
    Write-Host "  [ERROR] Handler script not found: $handlerPath" -ForegroundColor Red
    Write-Host '  Make sure Invoke-FieldOpsHandler.ps1 is in the same folder as this script.' -ForegroundColor Yellow
    exit 1
}

# ==============================================================
# REGISTER PROTOCOL
# ==============================================================
# The command line that Windows invokes when fieldops:// is clicked.
# Uses powershell.exe (available on every Windows box) with -NoProfile for speed
# and -ExecutionPolicy Bypass so it works regardless of system policy.
# "%1" is the URL that Windows substitutes in.
$powershell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$cmdLine    = "`"$powershell`" -NoProfile -ExecutionPolicy Bypass -File `"$handlerPath`" -Url `"%1`""

Write-Host '  Registering fieldops:// protocol...' -ForegroundColor Cyan
Write-Host ''
Write-Host "  Command line: $cmdLine" -ForegroundColor DarkGray
Write-Host ''

try {
    # Create the protocol root key
    $root = 'HKLM:\SOFTWARE\Classes\fieldops'
    if (-not (Test-Path $root)) {
        $null = New-Item -Path $root -Force
    }

    # Required properties for a URL protocol
    Set-ItemProperty -Path $root -Name '(Default)'      -Value 'URL:FieldOps Pro Protocol'
    Set-ItemProperty -Path $root -Name 'URL Protocol'   -Value ''
    Set-ItemProperty -Path $root -Name 'FriendlyTypeName' -Value 'FieldOps Pro Command'

    # Icon (uses the PowerShell exe's icon as a sensible default)
    $iconKey = "$root\DefaultIcon"
    if (-not (Test-Path $iconKey)) { $null = New-Item -Path $iconKey -Force }
    Set-ItemProperty -Path $iconKey -Name '(Default)' -Value "$powershell,0"

    # shell\open\command -- the actual launcher
    $cmdKey = "$root\shell\open\command"
    if (-not (Test-Path $cmdKey)) { $null = New-Item -Path $cmdKey -Force }
    Set-ItemProperty -Path $cmdKey -Name '(Default)' -Value $cmdLine

    Write-Host '  [OK] Protocol registered successfully' -ForegroundColor Green
    Write-Host ''
    Write-Host '  Test it: ' -NoNewline
    Write-Host 'Start-Process "fieldops://run?script=Invoke-Dashboard.ps1"' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  ======================================================================' -ForegroundColor Cyan
    Write-Host '  SETUP COMPLETE' -ForegroundColor Green
    Write-Host '  ======================================================================' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  Next steps:' -ForegroundColor Yellow
    Write-Host '    1. Open the Dashboard: .\Invoke-Dashboard.ps1 -OpenDashboard'
    Write-Host '    2. Click any command button -- the browser will ask permission'
    Write-Host '       the first time. Check "Always allow" for seamless clicks.'
    Write-Host '    3. The script runs in a new PowerShell window.'
    Write-Host ''
    Write-Host '  To remove: .\Register-FieldOpsProtocol.ps1 -Unregister' -ForegroundColor DarkGray
    Write-Host ''

} catch {
    Write-Host "  [ERROR] Registration failed: $_" -ForegroundColor Red
    Write-Host '  You may need to disable antivirus temporarily if registry writes are blocked.' -ForegroundColor Yellow
    exit 1
}
