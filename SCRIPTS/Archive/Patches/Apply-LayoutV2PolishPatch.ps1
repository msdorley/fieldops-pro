#Requires -Version 5.1
<#
.SYNOPSIS
    Three small polish fixes to v2.1 layout:
      1. STATUT bar overflow on French strings ("Joint au lieu de travail"
         is 24 chars but field width was 20 -> closing | got pushed past
         the right border).
      2. Section header alignment ("DIAGNOSTIC & ANALYSE" was slightly
         left of menu item labels because menu items have [K] prefix that
         shifts the label start by 4 chars).
      3. Banner string still says v2.0 in the locale -- update to v2.1.
.NOTES
    Run from C:\Dev\fieldops-pro\.
#>

$ErrorActionPreference = 'Stop'

if (-not (Test-Path '.\SCRIPTS\FieldOps-Launcher.ps1')) {
    Write-Host "  [X] Run from the repo root." -ForegroundColor Red
    return
}

# ==============================================================================
# BACKUP
# ==============================================================================
Copy-Item .\SCRIPTS\FieldOps-Launcher.ps1 .\SCRIPTS\FieldOps-Launcher.layoutv2.bak -Force
Copy-Item .\CONFIG\lang\en.json .\CONFIG\lang\en.json.layoutv2.bak -Force
Copy-Item .\CONFIG\lang\fr.json .\CONFIG\lang\fr.json.layoutv2.bak -Force
Write-Host "  [OK] Backups created (*.layoutv2.bak)" -ForegroundColor Green

# ==============================================================================
# FIX 1: STATUT overflow -- AAD field width 20 -> 28
# ==============================================================================
$content = Get-Content .\SCRIPTS\FieldOps-Launcher.ps1 -Raw

$old1 = @'
    Write-Host $st.Aad.PadRight(20)               -ForegroundColor $aadColor -NoNewline
    $usedSoFar = 4 + 18 + 5 + 12 + 5 + 38 + 8 + 20
'@
$new1 = @'
    # AAD field: 28 chars (covers French "Joint au lieu de travail" = 24 chars + headroom)
    Write-Host $st.Aad.PadRight(28)               -ForegroundColor $aadColor -NoNewline
    $usedSoFar = 4 + 18 + 5 + 12 + 5 + 38 + 8 + 28
'@

if ($content.Contains($old1)) {
    $content = $content.Replace($old1, $new1)
    Write-Host "  [OK] Fix 1: STATUT field widened to 28 chars" -ForegroundColor Green
} else {
    Write-Host "  [!] Fix 1 anchor not found -- skipping (file may already be patched)" -ForegroundColor Yellow
}

# ==============================================================================
# FIX 2: Section header alignment -- prepend 4 spaces inside Row2 call so
# section headers align with menu item labels (which start after "[K] ")
#
# We do this NOT by padding the strings (which would change locale data),
# but by changing the Row2 call site to add the indent only for these headers.
# ==============================================================================
$old2 = @"
    Row2 (L 'launcher.col.diag'   'DIAGNOSTIC & ANALYSIS') (L 'launcher.col.deploy' 'DEPLOYMENT & REPORTING')
"@
$new2 = @"
    # Section headers indented 4 chars so they align with menu item labels (which start after `"[K] `" prefix)
    Row2 ('    ' + (L 'launcher.col.diag'   'DIAGNOSTIC & ANALYSIS')) ('    ' + (L 'launcher.col.deploy' 'DEPLOYMENT & REPORTING'))
"@

if ($content.Contains($old2)) {
    $content = $content.Replace($old2, $new2)
    Write-Host "  [OK] Fix 2: Section headers indented to align with menu labels" -ForegroundColor Green
} else {
    Write-Host "  [!] Fix 2 anchor not found -- skipping" -ForegroundColor Yellow
}

# Write launcher
[System.IO.File]::WriteAllText((Resolve-Path .\SCRIPTS\FieldOps-Launcher.ps1), $content, [System.Text.UTF8Encoding]::new($true))
Write-Host "  [OK] Launcher saved" -ForegroundColor Green

# ==============================================================================
# FIX 3: Banner string v2.0 -> v2.1 in both locale files
# ==============================================================================
function Update-BannerString {
    param([string]$LocaleFile, [string]$NewTitle)
    $loc = Get-Content $LocaleFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($loc.launcher -and $loc.launcher.banner) {
        $loc.launcher.banner.title = $NewTitle
        $json = $loc | ConvertTo-Json -Depth 20
        [System.IO.File]::WriteAllText((Resolve-Path $LocaleFile), $json, [System.Text.UTF8Encoding]::new($false))
        Write-Host "  [OK] $LocaleFile -> banner.title = $NewTitle" -ForegroundColor Green
    } else {
        Write-Host "  [!] $LocaleFile has no launcher.banner.title node -- skipping" -ForegroundColor Yellow
    }
}

Update-BannerString '.\CONFIG\lang\en.json' 'FIELDOPS PRO  v2.1    ENTERPRISE FIELD IT TOOLKIT    EU DEPLOYMENT'
Update-BannerString '.\CONFIG\lang\fr.json' 'FIELDOPS PRO  v2.1    BOITE A OUTILS IT DE TERRAIN    DEPLOIEMENT EU'

# ==============================================================================
# DONE
# ==============================================================================
Write-Host ""
Write-Host "  All polish fixes applied." -ForegroundColor Green
Write-Host "  Re-run: .\SCRIPTS\FieldOps-Launcher.ps1" -ForegroundColor Cyan
Write-Host "  Rollback: each file has a *.layoutv2.bak alongside it." -ForegroundColor DarkGray
