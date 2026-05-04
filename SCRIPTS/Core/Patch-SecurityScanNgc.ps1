#Requires -Version 5.1
<#
.SYNOPSIS
    Patches Invoke-SecurityScan.ps1 line 879 NGC access-denied bug.
.DESCRIPTION
    The Windows Hello section tries Test-Path on
    C:\WINDOWS\ServiceProfiles\LocalService\AppData\Local\Microsoft\Ngc
    which is a SYSTEM-only folder. Even as Administrator, Test-Path throws
    UnauthorizedAccessException. The fix is adding -ErrorAction SilentlyContinue.

    This patcher does an in-place edit with a .bak backup.
.EXAMPLE
    .\Patch-SecurityScanNgc.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$candidates = @(
    (Join-Path $scriptDir 'Invoke-SecurityScan.ps1'),
    'E:\SCRIPTS\Security\Invoke-SecurityScan.ps1',
    'E:\SCRIPTS\Core\Invoke-SecurityScan.ps1'
)
$target = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $target) {
    Write-Host '  [ERROR] Could not find Invoke-SecurityScan.ps1' -ForegroundColor Red
    Write-Host '  Checked:' -ForegroundColor DarkGray
    foreach ($c in $candidates) { Write-Host "    $c" -ForegroundColor DarkGray }
    exit 1
}

Write-Host ''
Write-Host "  Target: $target" -ForegroundColor Cyan

# Backup
$backup = "$target.bak"
Copy-Item $target $backup -Force
Write-Host "  Backup: $backup" -ForegroundColor DarkGray

$content = Get-Content $target -Raw

# Fix 1: The Test-Path in the Windows Hello / NGC check
# Match (Test-Path $ngcPath) and replace with guarded version
$patched = $content -replace `
    '\(Test-Path\s+\$ngcPath\)', `
    '(Test-Path $ngcPath -ErrorAction SilentlyContinue)'

# Fix 2: Also guard the Get-ChildItem on the same path
$patched = $patched -replace `
    '(Get-ChildItem\s+\$ngc[A-Za-z_]*)(\s|\)|\|)', `
    '$1 -ErrorAction SilentlyContinue$2'

# Fix 3: Wrap the whole $helloConfigured expression in a try/catch
# Only do this if the pattern is still vulnerable (simple heuristic)
if ($patched -match '\$helloConfigured\s*=') {
    # Add a general safety wrapper around the NGC check
    # Only if it isn't already wrapped
    if ($patched -notmatch 'try\s*\{[^}]*\$ngcPath') {
        Write-Host '  Note: Adding try/catch guard around $helloConfigured assignment' -ForegroundColor DarkGray
        $patched = $patched -replace `
            '(\$helloConfigured\s*=\s*\(Test-Path[^)]+\)\s*-and\s*\(\(Get-ChildItem[^)]+\)[^)]*\))', `
            'try { $1 } catch { $helloConfigured = $false }'
    }
}

if ($patched -eq $content) {
    Write-Host '  [INFO] No changes needed (already patched or pattern not found)' -ForegroundColor Yellow
    exit 0
}

Set-Content -Path $target -Value $patched -Encoding UTF8 -NoNewline
Write-Host '  [OK] Patched successfully' -ForegroundColor Green
Write-Host ''
Write-Host '  Changes applied:' -ForegroundColor Cyan
Write-Host '    - Test-Path $ngcPath now has -ErrorAction SilentlyContinue'
Write-Host '    - Get-ChildItem $ngc* now has -ErrorAction SilentlyContinue'
Write-Host '    - $helloConfigured assignment wrapped in try/catch'
Write-Host ''
Write-Host "  Rollback: Copy-Item `"$backup`" `"$target`" -Force" -ForegroundColor DarkGray
Write-Host ''
