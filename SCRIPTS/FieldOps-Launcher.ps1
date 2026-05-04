# ============================================================
# FieldOps Pro - Main Launcher
# Enterprise IT Toolkit | EU Deployment
# ============================================================

$USB = "C:"  # USB drive letter in WinPE
$ScriptsPath = "$USB\SCRIPTS"
$ToolsPath   = "$USB\TOOLS"
$ReportsPath = "$USB\REPORTS"
$LogsPath    = "$USB\LOGS"

# Ensure output dirs exist
foreach ($dir in @($ReportsPath, $LogsPath)) {
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
}

function Show-Banner {
    Clear-Host
    Write-Host ""
    Write-Host "  =============================================" -ForegroundColor Cyan
    Write-Host "        FIELDOPS PRO - Enterprise Toolkit      " -ForegroundColor White
    Write-Host "        Field IT Operations System v1.0        " -ForegroundColor Gray
    Write-Host "  =============================================" -ForegroundColor Cyan
    Write-Host "  Machine  : $($env:COMPUTERNAME)" -ForegroundColor Yellow
    Write-Host "  Date     : $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -ForegroundColor Yellow
    Write-Host "  =============================================" -ForegroundColor Cyan
    Write-Host ""
}

function Show-Menu {
    Write-Host "  MAIN MENU" -ForegroundColor White
    Write-Host "  ---------" -ForegroundColor DarkGray
    Write-Host "  [1]  PC Health Diagnostic" -ForegroundColor Green
    Write-Host "  [2]  Network Troubleshooting" -ForegroundColor Green
    Write-Host "  [3]  Security Scan" -ForegroundColor Green
    Write-Host "  [4]  Disk Analysis" -ForegroundColor Green
    Write-Host "  [5]  Open HWiNFO (Full Hardware Info)" -ForegroundColor Green
    Write-Host "  [6]  Open CrystalDiskInfo" -ForegroundColor Green
    Write-Host "  [7]  View Reports" -ForegroundColor Cyan
    Write-Host "  [8]  Open Tools Folder" -ForegroundColor Cyan
    Write-Host "  [Q]  Quit" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Select option: " -ForegroundColor White -NoNewline
}

function Invoke-PCDiagnostic {
    Write-Host "`n  Running PC Health Diagnostic..." -ForegroundColor Cyan
    $script = "$ToolsPath\Diagnostics\Invoke-PCHealth.ps1"
    if (Test-Path $script) {
        powershell -ExecutionPolicy Bypass -File $script -OutputPath $ReportsPath
    } else {
        Write-Host "  ERROR: Script not found at $script" -ForegroundColor Red
    }
    Write-Host "`n  Press any key to return..." -ForegroundColor Gray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

function Invoke-NetworkFix {
    Write-Host "`n  Running Network Diagnostics..." -ForegroundColor Cyan
    $script = "$ScriptsPath\Invoke-NetworkFix.ps1"
    if (Test-Path $script) {
        powershell -ExecutionPolicy Bypass -File $script
    } else {
        # Inline basic network check
        Write-Host "`n  Network Adapter Status:" -ForegroundColor White
        Get-WmiObject Win32_NetworkAdapterConfiguration | Where-Object { $_.IPEnabled } | ForEach-Object {
            Write-Host "  Adapter : $($_.Description)" -ForegroundColor Yellow
            Write-Host "  IP      : $($_.IPAddress -join ', ')" -ForegroundColor Green
            Write-Host "  Gateway : $($_.DefaultIPGateway -join ', ')" -ForegroundColor Green
        }
        Write-Host "`n  Testing internet (8.8.8.8)..." -ForegroundColor White
        if (Test-Connection -ComputerName "8.8.8.8" -Count 2 -Quiet) {
            Write-Host "  Internet: OK" -ForegroundColor Green
        } else {
            Write-Host "  Internet: FAILED" -ForegroundColor Red
        }
    }
    Write-Host "`n  Press any key to return..." -ForegroundColor Gray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

function Open-Tool {
    param([string]$Path, [string]$Name)
    if (Test-Path $Path) {
        Write-Host "`n  Launching $Name..." -ForegroundColor Cyan
        Start-Process $Path
    } else {
        Write-Host "`n  ERROR: $Name not found at $Path" -ForegroundColor Red
        Write-Host "  Press any key to return..." -ForegroundColor Gray
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    }
}

function View-Reports {
    Write-Host "`n  Reports in $ReportsPath :" -ForegroundColor Cyan
    if (Test-Path $ReportsPath) {
        Get-ChildItem $ReportsPath | ForEach-Object {
            Write-Host "  - $($_.Name)" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  No reports found yet." -ForegroundColor Gray
    }
    Write-Host "`n  Press any key to return..." -ForegroundColor Gray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

# ---- MAIN LOOP ----
do {
    Show-Banner
    Show-Menu
    $choice = Read-Host

    switch ($choice.ToUpper()) {
        "1" { Invoke-PCDiagnostic }
        "2" { Invoke-NetworkFix }
        "3" { Open-Tool "$ToolsPath\Security\MalwareBytes.exe" "Security Scan" }
        "4" { Open-Tool "$ToolsPath\Diagnostics\DiskInfo64S.exe" "CrystalDiskInfo" }
        "5" { Open-Tool "$ToolsPath\Diagnostics\HWiNFO64.exe" "HWiNFO64" }
        "6" { Open-Tool "$ToolsPath\Diagnostics\DiskInfo64S.exe" "CrystalDiskInfo" }
        "7" { View-Reports }
        "8" { Start-Process "explorer.exe" $ToolsPath }
        "Q" { Write-Host "`n  Exiting FieldOps Pro. Goodbye.`n" -ForegroundColor Cyan; exit }
        default { Write-Host "`n  Invalid option. Try again." -ForegroundColor Red; Start-Sleep 1 }
    }
} while ($true)
