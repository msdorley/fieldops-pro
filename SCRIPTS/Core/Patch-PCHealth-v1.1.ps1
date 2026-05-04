<#
.SYNOPSIS
    FieldOps Pro - PCHealth v1.0 -> v1.1 Patch
.DESCRIPTION
    Applies two targeted fixes to Invoke-PCHealth.ps1:
    Fix 1: Battery DesignCapacity null fallback (Acer WMI returns null)
    Fix 2: Filter driver dates before 2000 (Intel epoch bug)
    Run from any directory. Targets E:\SCRIPTS\Diagnostics\Invoke-PCHealth.ps1
#>

$targetFile = Join-Path (Split-Path $PSScriptRoot -Parent) 'Diagnostics\Invoke-PCHealth.ps1'
if (-not (Test-Path $targetFile)) {
    # Try absolute path
    $targetFile = 'E:\SCRIPTS\Diagnostics\Invoke-PCHealth.ps1'
}
if (-not (Test-Path $targetFile)) {
    Write-Host "ERROR: Cannot find Invoke-PCHealth.ps1" -ForegroundColor Red
    Write-Host "Place this script in E:\SCRIPTS\Network\ or E:\SCRIPTS\Core\ and run again." -ForegroundColor Yellow
    exit 1
}

Write-Host "Patching: $targetFile" -ForegroundColor Cyan
$content = Get-Content $targetFile -Raw -Encoding UTF8

# ============================================================
# FIX 1: Battery DesignCapacity null fallback
# ============================================================
# The problem: DesignedCapacity returns null on some Acer models.
# When null, $healthPct = 0, which triggers a false "0% capacity" Critical.
# The fix: Detect null DesignCapacity and report "unavailable" instead of 0%.

$oldBattery = @'
            $healthPct = if ($designCap -and $designCap -gt 0) { [math]::Round(($fullCap / $designCap) * 100) } else { 0 }
            $cycleCount = (Get-CimInstance -Namespace 'root\wmi' -Class BatteryCycleCount -EA SilentlyContinue).CycleCount

            $hBadge = if ($healthPct -lt 40) { 'FAIL' } elseif ($healthPct -lt 65) { 'WARN' } else { 'PASS' }
            $hColor = if ($healthPct -lt 40) { 'Red' } elseif ($healthPct -lt 65) { 'Yellow' } else { 'Green' }
            Status 'Battery Health' "$healthPct% of design capacity" $hColor $hBadge
            Status 'Cycle Count' "$cycleCount cycles" 'White' 'INFO'
            Status 'Design Capacity' "${designCap} mWh" 'DarkGray' 'INFO'
'@

$newBattery = @'
            $cycleCount = (Get-CimInstance -Namespace 'root\wmi' -Class BatteryCycleCount -EA SilentlyContinue).CycleCount

            if ($designCap -and $designCap -gt 0) {
                # Normal path: design capacity available
                $healthPct = [math]::Round(($fullCap / $designCap) * 100)
                $hBadge = if ($healthPct -lt 40) { 'FAIL' } elseif ($healthPct -lt 65) { 'WARN' } else { 'PASS' }
                $hColor = if ($healthPct -lt 40) { 'Red' } elseif ($healthPct -lt 65) { 'Yellow' } else { 'Green' }
                Status 'Battery Health' "$healthPct% of design capacity" $hColor $hBadge
                Status 'Cycle Count' "$cycleCount cycles" 'White' 'INFO'
                Status 'Design Capacity' "${designCap} mWh" 'DarkGray' 'INFO'
            } else {
                # Fallback: DesignedCapacity is null (known issue on some Acer/OEM hardware)
                $healthPct = -1
                $fullCapStr = if ($fullCap -and $fullCap -gt 0) { "${fullCap} mWh" } else { 'Unknown' }
                Status 'Battery Health' "Design capacity unavailable (full charge: $fullCapStr)" 'Yellow' 'INFO'
                Status 'Cycle Count' "$cycleCount cycles" 'White' 'INFO'
                Status 'Design Capacity' 'Unavailable (WMI returned null)' 'DarkGray' 'INFO'
'@

if ($content.Contains($oldBattery)) {
    $content = $content.Replace($oldBattery, $newBattery)
    Write-Host "  [OK] Fix 1 applied: Battery DesignCapacity null fallback" -ForegroundColor Green
} else {
    Write-Host "  [SKIP] Fix 1: Battery block not found (already patched or code differs)" -ForegroundColor Yellow
}

# Also fix the health check logic below it
$oldBatCheck = @'
            if ($healthPct -lt 40) {
                Add-Check 'Battery' 'Battery Health' 'Critical' "Only $healthPct% capacity remaining ($cycleCount cycles)" 'Battery needs replacement'
            } elseif ($healthPct -lt 65) {
                Add-Check 'Battery' 'Battery Health' 'Warning' "$healthPct% capacity ($cycleCount cycles)" 'Battery degrading -- plan replacement'
            } else {
                Add-Check 'Battery' 'Battery Health' 'Pass' "$healthPct% capacity ($cycleCount cycles)"
            }
'@

$newBatCheck = @'
            if ($healthPct -eq -1) {
                # Design capacity unavailable -- report info, not failure
                Add-Check 'Battery' 'Battery Health' 'Info' "Design capacity unavailable, full charge $fullCapStr ($cycleCount cycles)" 'WMI DesignedCapacity null on this hardware'
            } elseif ($healthPct -lt 40) {
                Add-Check 'Battery' 'Battery Health' 'Critical' "Only $healthPct% capacity remaining ($cycleCount cycles)" 'Battery needs replacement'
            } elseif ($healthPct -lt 65) {
                Add-Check 'Battery' 'Battery Health' 'Warning' "$healthPct% capacity ($cycleCount cycles)" 'Battery degrading -- plan replacement'
            } else {
                Add-Check 'Battery' 'Battery Health' 'Pass' "$healthPct% capacity ($cycleCount cycles)"
            }
'@

if ($content.Contains($oldBatCheck)) {
    $content = $content.Replace($oldBatCheck, $newBatCheck)
    Write-Host "  [OK] Fix 1b applied: Battery health check logic updated" -ForegroundColor Green
} else {
    Write-Host "  [SKIP] Fix 1b: Battery check block not found" -ForegroundColor Yellow
}

# ============================================================
# FIX 2: Filter driver dates before 2000 (Intel epoch bug)
# ============================================================
# The problem: Intel chipset drivers report DriverDate of 1968-07-18
# through WMI. These are bogus epoch dates, not real timestamps.
# The fix: Filter out any DriverDate before 2000-01-01.

$oldDriverFilter = 'Where-Object { $_.DriverDate -and $_.DeviceName } |'
$newDriverFilter = 'Where-Object { $_.DriverDate -and $_.DeviceName -and $_.DriverDate -gt [datetime]''2000-01-01'' } |'

if ($content.Contains($oldDriverFilter)) {
    $content = $content.Replace($oldDriverFilter, $newDriverFilter)
    Write-Host "  [OK] Fix 2 applied: Driver date pre-2000 filter" -ForegroundColor Green
} else {
    Write-Host "  [SKIP] Fix 2: Driver filter line not found (already patched or code differs)" -ForegroundColor Yellow
}

# ============================================================
# UPDATE VERSION STRING
# ============================================================
$content = $content -replace 'PCHealth\) v1\.0', 'PCHealth) v1.1'
$content = $content -replace 'Version : 1\.0', 'Version : 1.1'
Write-Host "  [OK] Version bumped to v1.1" -ForegroundColor Green

# ============================================================
# WRITE PATCHED FILE
# ============================================================
$content | Out-File -FilePath $targetFile -Encoding UTF8 -Force -NoNewline
Write-Host ""
Write-Host "Patch complete. Run:" -ForegroundColor Cyan
Write-Host "  Set-Location 'E:\SCRIPTS\Diagnostics'" -ForegroundColor Yellow
Write-Host "  .\Invoke-PCHealth.ps1" -ForegroundColor Yellow
Write-Host ""
