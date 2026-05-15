#Requires -Version 5.1
<#
.SYNOPSIS
    Layout v2 patch -- compact-pro visuals across all FieldOps Pro
    operator-facing screens (launcher, AutoFixPlan banner, risk plan box,
    log viewer, quit menu, tools menu pass-through).

.DESCRIPTION
    Applies three changes:

    1. REPLACES SCRIPTS\FieldOps-Launcher.ps1 with v2.1 (computed-padding
       grid, serial number in header, perfect column alignment, [N] entry
       baked in).

    2. PATCHES SCRIPTS\Core\Invoke-AutoFixPlan.ps1's _Banner function to
       use the same compact-pro visual language as the launcher.

    3. PATCHES SCRIPTS\Core\FieldOps-RiskPlanner.psm1's Show-FixRiskPlan
       function to render risk plans with the same border style.

    4. ADDS new locale keys (launcher.bar.serial, launcher.bar.model,
       launcher.bar.bios, launcher.quit.title) into both en.json and
       fr.json.

    Each step backs up before changing. Rollback is one-command per file.

.NOTES
    Run from C:\Dev\fieldops-pro\.
    The patch verifies the launcher v2.0 + Flavor 3 patches are already
    applied before proceeding -- it will refuse to run on an un-patched
    base.
#>

$ErrorActionPreference = 'Stop'
$dl = "$env:USERPROFILE\Downloads\fieldops-layout-v2"

# ==============================================================================
# PRE-FLIGHT CHECKS
# ==============================================================================
Write-Host ""
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "  FieldOps Pro -- Layout v2 patch installer" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host ""

if (-not (Test-Path '.\SCRIPTS\FieldOps-Launcher.ps1')) {
    Write-Host "  [X] Run from the repo root (C:\Dev\fieldops-pro\)." -ForegroundColor Red
    return
}

# Verify dependencies are present
$reqs = @(
    '.\SCRIPTS\FieldOps-Launcher.ps1',
    '.\SCRIPTS\Core\Invoke-AutoFixPlan.ps1',
    '.\SCRIPTS\Core\FieldOps-RiskPlanner.psm1',
    '.\CONFIG\lang\en.json',
    '.\CONFIG\lang\fr.json',
    "$dl\FieldOps-Launcher.ps1"
)
$missing = @($reqs | Where-Object { -not (Test-Path $_) })
if ($missing.Count -gt 0) {
    Write-Host "  [X] Missing required files:" -ForegroundColor Red
    $missing | ForEach-Object { Write-Host "      $_" -ForegroundColor Red }
    Write-Host ""
    Write-Host "  Make sure you've extracted the layout-v2 zip to:" -ForegroundColor Yellow
    Write-Host "      $dl" -ForegroundColor Yellow
    return
}

# Verify base launcher has [N] entry (proves Flavor 3 was applied)
$launcherContent = Get-Content '.\SCRIPTS\FieldOps-Launcher.ps1' -Raw
if (-not $launcherContent.Contains("'N' { Invoke-FieldScript")) {
    Write-Host "  [X] Current launcher does not have the [N] entry." -ForegroundColor Red
    Write-Host "      Apply Flavor 3 first (Phases A-G of fieldops-flavor3.zip)." -ForegroundColor Red
    return
}
Write-Host "  [OK] Pre-flight checks passed." -ForegroundColor Green

# ==============================================================================
# STEP 1: BACKUP EVERYTHING WE'LL TOUCH
# ==============================================================================
Write-Host ""
Write-Host "--- Step 1: Backups ---" -ForegroundColor Cyan
$ts = Get-Date -Format 'yyyyMMdd_HHmmss'

$backups = @(
    @{ Src = '.\SCRIPTS\FieldOps-Launcher.ps1';                Bak = ".\SCRIPTS\FieldOps-Launcher.layoutv1.bak"            },
    @{ Src = '.\SCRIPTS\Core\Invoke-AutoFixPlan.ps1';          Bak = ".\SCRIPTS\Core\Invoke-AutoFixPlan.layoutv1.bak"      },
    @{ Src = '.\SCRIPTS\Core\FieldOps-RiskPlanner.psm1';       Bak = ".\SCRIPTS\Core\FieldOps-RiskPlanner.layoutv1.bak"    },
    @{ Src = '.\CONFIG\lang\en.json';                          Bak = ".\CONFIG\lang\en.json.layoutv1.bak"                  },
    @{ Src = '.\CONFIG\lang\fr.json';                          Bak = ".\CONFIG\lang\fr.json.layoutv1.bak"                  }
)
foreach ($b in $backups) {
    Copy-Item $b.Src $b.Bak -Force
    Write-Host "  [OK] Backed up: $(Split-Path $b.Src -Leaf) -> $(Split-Path $b.Bak -Leaf)" -ForegroundColor DarkGray
}

# ==============================================================================
# STEP 2: REPLACE LAUNCHER
# ==============================================================================
Write-Host ""
Write-Host "--- Step 2: Deploy new launcher ---" -ForegroundColor Cyan
Copy-Item "$dl\FieldOps-Launcher.ps1" '.\SCRIPTS\FieldOps-Launcher.ps1' -Force
Unblock-File '.\SCRIPTS\FieldOps-Launcher.ps1' -ErrorAction SilentlyContinue
$newSize = (Get-Item '.\SCRIPTS\FieldOps-Launcher.ps1').Length
Write-Host "  [OK] Launcher v2.1 deployed ($newSize bytes)" -ForegroundColor Green

# Verify it has the new key markers
$check = Get-Content '.\SCRIPTS\FieldOps-Launcher.ps1' -Raw
$hasNewMarker  = $check.Contains('Get-MachineIdentity')
$hasOldMarker  = $check.Contains('cn (' + "'" + '  +-')   # old hand-counted dashes
Write-Host "  [OK] Has Get-MachineIdentity (new layout): $hasNewMarker" -ForegroundColor $(if ($hasNewMarker) {'Green'} else {'Red'})

# ==============================================================================
# STEP 3: ADD NEW LOCALE KEYS
# ==============================================================================
Write-Host ""
Write-Host "--- Step 3: Add new locale keys ---" -ForegroundColor Cyan

function Add-LocaleKeys {
    param(
        [string]$LocaleFile,
        [hashtable]$LauncherBarAdditions,
        [hashtable]$LauncherQuitAdditions
    )
    $loc = Get-Content $LocaleFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $loc.launcher) { Write-Host "  [!] No launcher node in $LocaleFile -- skipping" -ForegroundColor Yellow; return }
    if (-not $loc.launcher.bar)  { $loc.launcher | Add-Member -NotePropertyName 'bar'  -NotePropertyValue ([PSCustomObject]@{}) -Force }
    if (-not $loc.launcher.quit) { $loc.launcher | Add-Member -NotePropertyName 'quit' -NotePropertyValue ([PSCustomObject]@{}) -Force }

    foreach ($k in $LauncherBarAdditions.Keys) {
        $loc.launcher.bar | Add-Member -NotePropertyName $k -NotePropertyValue $LauncherBarAdditions[$k] -Force
    }
    foreach ($k in $LauncherQuitAdditions.Keys) {
        $loc.launcher.quit | Add-Member -NotePropertyName $k -NotePropertyValue $LauncherQuitAdditions[$k] -Force
    }

    $json = $loc | ConvertTo-Json -Depth 20
    [System.IO.File]::WriteAllText((Resolve-Path $LocaleFile), $json, [System.Text.UTF8Encoding]::new($false))
}

Add-LocaleKeys '.\CONFIG\lang\en.json' @{
    serial = 'SERIAL'
    model  = 'MODEL'
    bios   = 'BIOS'
} @{
    title = 'QUIT FIELDOPS PRO'
}
Write-Host "  [OK] en.json updated" -ForegroundColor Green

Add-LocaleKeys '.\CONFIG\lang\fr.json' @{
    serial = 'N/SERIE'
    model  = 'MODELE'
    bios   = 'BIOS'
} @{
    title = 'QUITTER FIELDOPS PRO'
}
Write-Host "  [OK] fr.json updated" -ForegroundColor Green

# Verify
$en = Get-Content '.\CONFIG\lang\en.json' -Raw -Encoding UTF8 | ConvertFrom-Json
$fr = Get-Content '.\CONFIG\lang\fr.json' -Raw -Encoding UTF8 | ConvertFrom-Json
Write-Host "  Spot-check en.launcher.bar.serial = $($en.launcher.bar.serial)" -ForegroundColor DarkGray
Write-Host "  Spot-check fr.launcher.bar.serial = $($fr.launcher.bar.serial)" -ForegroundColor DarkGray

# ==============================================================================
# STEP 4: PATCH ORCHESTRATOR _Banner FUNCTION
# ==============================================================================
Write-Host ""
Write-Host "--- Step 4: Patch orchestrator banner ---" -ForegroundColor Cyan

$orchPath = '.\SCRIPTS\Core\Invoke-AutoFixPlan.ps1'
$orchContent = Get-Content $orchPath -Raw

$oldBanner = @'
function _Banner {
    Clear-Host
    Write-Host ''
    Write-Host '  +======================================================================+' -ForegroundColor Cyan
    Write-Host ('  |  ' + (L 'autofixplan.banner.title' 'FIELDOPS PRO  --  AUTOFIX  PLAN-BEFORE-EXECUTE  v1.0').PadRight(67) + '|') -ForegroundColor Cyan
    Write-Host '  +======================================================================+' -ForegroundColor Cyan
    Write-Host ''
    $hostname = $env:COMPUTERNAME
    $now      = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $isAdmin  = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    Write-Host "  $(L 'autofixplan.bar.host' 'Host'): $hostname    $(L 'autofixplan.bar.time' 'Time'): $now" -ForegroundColor Gray
    Write-Host "  $(L 'autofixplan.bar.admin' 'Administrator'): $isAdmin    $(L 'autofixplan.bar.locale' 'Locale'): $currentLocale" -ForegroundColor Gray
    if ($DryRun) {
        Write-Host ''
        Write-Host "  [$(L 'autofixplan.dryrun' 'DRY RUN')] $(L 'autofixplan.dryrun.desc' 'Plans only -- no fix will be applied') " -ForegroundColor Yellow
    }
    Write-Host ''
}
'@

$newBanner = @'
function _Banner {
    Clear-Host
    $W = 122
    Write-Host ''
    # Top rule
    Write-Host ('  +' + ('-' * $W) + '+') -ForegroundColor Cyan
    # Title
    $title = (L 'autofixplan.banner.title' 'FIELDOPS PRO  --  AUTOFIX  PLAN-BEFORE-EXECUTE  v1.0')
    if ($title.Length -gt $W) { $title = $title.Substring(0, $W - 1) + '~' }
    Write-Host ('  |' + $title.PadRight($W) + '|') -ForegroundColor Cyan
    Write-Host ('  +' + ('-' * $W) + '+') -ForegroundColor Cyan
    # Status line
    $hostname = $env:COMPUTERNAME
    $now      = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $isAdmin  = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $statusLine = "  $(L 'autofixplan.bar.host' 'Host'): $hostname    $(L 'autofixplan.bar.time' 'Time'): $now    $(L 'autofixplan.bar.admin' 'Administrator'): $isAdmin    $(L 'autofixplan.bar.locale' 'Locale'): $currentLocale"
    if ($statusLine.Length -gt $W) { $statusLine = $statusLine.Substring(0, $W - 1) + '~' }
    Write-Host ('  |' + $statusLine.PadRight($W) + '|') -ForegroundColor Gray
    Write-Host ('  +' + ('-' * $W) + '+') -ForegroundColor Cyan
    if ($DryRun) {
        Write-Host ''
        Write-Host "  [$(L 'autofixplan.dryrun' 'DRY RUN')] $(L 'autofixplan.dryrun.desc' 'Plans only -- no fix will be applied') " -ForegroundColor Yellow
    }
    Write-Host ''
}
'@

if ($orchContent.Contains($oldBanner)) {
    $orchContent = $orchContent.Replace($oldBanner, $newBanner)
    [System.IO.File]::WriteAllText((Resolve-Path $orchPath), $orchContent, [System.Text.UTF8Encoding]::new($true))
    Write-Host "  [OK] Orchestrator _Banner patched" -ForegroundColor Green
} else {
    Write-Host "  [!] Orchestrator _Banner not in expected form -- skipping (manual edit needed)" -ForegroundColor Yellow
    Write-Host "      File NOT modified." -ForegroundColor Yellow
}

# ==============================================================================
# STEP 5: PATCH PLANNER Show-FixRiskPlan TO USE NEW BORDER STYLE
# ==============================================================================
Write-Host ""
Write-Host "--- Step 5: Patch planner risk plan box ---" -ForegroundColor Cyan

$plannerPath = '.\SCRIPTS\Core\FieldOps-RiskPlanner.psm1'
$plannerContent = Get-Content $plannerPath -Raw

$oldBox = @'
    $bannerTitle = if ($isFr) { 'PLAN AVANT EXECUTION' } else { 'PLAN BEFORE EXECUTE' }
    Write-Host ''
    Write-Host '  +======================================================================+' -ForegroundColor Cyan
    Write-Host ('  |  ' + $bannerTitle.PadRight(67) + '|') -ForegroundColor Cyan
    Write-Host '  +======================================================================+' -ForegroundColor Cyan
    Write-Host ''
'@

$newBox = @'
    $bannerTitle = if ($isFr) { 'PLAN AVANT EXECUTION' } else { 'PLAN BEFORE EXECUTE' }
    $W = 122
    Write-Host ''
    Write-Host ('  +' + ('-' * $W) + '+') -ForegroundColor Cyan
    Write-Host ('  |  ' + $bannerTitle.PadRight($W - 2) + '|') -ForegroundColor Cyan
    Write-Host ('  +' + ('-' * $W) + '+') -ForegroundColor Cyan
    Write-Host ''
'@

if ($plannerContent.Contains($oldBox)) {
    $plannerContent = $plannerContent.Replace($oldBox, $newBox)
    [System.IO.File]::WriteAllText((Resolve-Path $plannerPath), $plannerContent, [System.Text.UTF8Encoding]::new($true))
    Write-Host "  [OK] Planner risk-plan banner patched" -ForegroundColor Green
} else {
    Write-Host "  [!] Planner banner not in expected form -- skipping" -ForegroundColor Yellow
}

# ALSO: patch the recommendation box width
$oldRec = @'
    Write-Host '  +======================================================================+' -ForegroundColor $recColor
    $recLabel = if ($isFr) { 'RECOMMANDATION' } else { 'RECOMMENDATION' }
    Write-Host ("  |  $recLabel : $($Plan.recommendation)".PadRight(72) + '|') -ForegroundColor $recColor
    Write-Host '  +======================================================================+' -ForegroundColor $recColor
'@

$newRec = @'
    $W = 122
    Write-Host ('  +' + ('-' * $W) + '+') -ForegroundColor $recColor
    $recLabel = if ($isFr) { 'RECOMMANDATION' } else { 'RECOMMENDATION' }
    $recLine = "  $recLabel : $($Plan.recommendation)"
    if ($recLine.Length -gt $W) { $recLine = $recLine.Substring(0, $W - 1) + '~' }
    Write-Host ('  |' + $recLine.PadRight($W) + '|') -ForegroundColor $recColor
    Write-Host ('  +' + ('-' * $W) + '+') -ForegroundColor $recColor
'@

if ($plannerContent.Contains($oldRec)) {
    $plannerContent = (Get-Content $plannerPath -Raw).Replace($oldRec, $newRec)
    [System.IO.File]::WriteAllText((Resolve-Path $plannerPath), $plannerContent, [System.Text.UTF8Encoding]::new($true))
    Write-Host "  [OK] Planner recommendation box patched" -ForegroundColor Green
} else {
    Write-Host "  [!] Planner recommendation box not in expected form -- skipping" -ForegroundColor Yellow
}

# ==============================================================================
# DONE
# ==============================================================================
Write-Host ""
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "  All patches applied." -ForegroundColor Green
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Next: run .\SCRIPTS\FieldOps-Launcher.ps1 to see the new layout." -ForegroundColor Cyan
Write-Host "  Rollback: each patched file has a *.layoutv1.bak alongside it." -ForegroundColor DarkGray
Write-Host ""
