#Requires -Version 5.1
<#
.SYNOPSIS
    Adds a post-operation prompt to FieldOps-Launcher.ps1.
.DESCRIPTION
    After every script run, the launcher detects what was produced
    (HTML reports, JSON logs, GZip snapshots) and offers contextual
    actions:
        [O] Open the report (if HTML produced)
        [E] Open the REPORTS folder in Explorer
        [C] Copy the report path to clipboard
        [N] Run AutoFix Plan-Before-Execute (only if a snapshot was produced)
        [Enter] Return to main menu

    The prompt only appears when at least one new file was detected.
    If nothing new was produced, the launcher falls through to the normal
    "Press any key to return" behaviour.

    All strings flow through Get-LocaleString so the prompt is bilingual.

    Architecture: this patch modifies ONLY the launcher's Invoke-FieldScript
    wrapper. No engine is touched. Old engines, new engines, and future
    engines all get the prompt automatically.

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
Copy-Item .\SCRIPTS\FieldOps-Launcher.ps1 .\SCRIPTS\FieldOps-Launcher.postop.bak -Force
Copy-Item .\CONFIG\lang\en.json            .\CONFIG\lang\en.json.postop.bak      -Force
Copy-Item .\CONFIG\lang\fr.json            .\CONFIG\lang\fr.json.postop.bak      -Force
Write-Host "  [OK] Backups created (*.postop.bak)" -ForegroundColor Green

# ==============================================================================
# PATCH 1: Replace Invoke-FieldScript with the post-op-aware version
# ==============================================================================
$content = Get-Content .\SCRIPTS\FieldOps-Launcher.ps1 -Raw

$oldFunc = @'
function Invoke-FieldScript {
    param(
        [Parameter(Mandatory)] [string]$RelativePath,
        [Parameter(Mandatory)] [string]$DisplayName,
        [hashtable]$Arguments = @{}
    )
    $scriptPath = Join-Path $scriptsRoot $RelativePath

    Clear-Host
    Nl
    Hr
    Row ("  " + (L 'launcher.run.running' 'Running') + ":  $DisplayName") 'Yellow'
    Row ("  " + (L 'launcher.run.path'    'Path'   ) + ":     $scriptPath") 'DarkGray'
    Hr
    Nl

    if (-not (Test-Path $scriptPath)) {
        Write-Host ('  [X] ' + (L 'launcher.run.notfound' 'Script not found') + ": $scriptPath") -ForegroundColor Red
        Write-Host ('      ' + (L 'launcher.run.notfound.hint' 'Verify this file exists on the USB.')) -ForegroundColor DarkGray
    } else {
        try {
            if ($Arguments -and $Arguments.Count -gt 0) {
                & $scriptPath @Arguments
            } else {
                & $scriptPath
            }
        } catch {
            Write-Host ('  [X] ' + (L 'launcher.run.error' 'Runtime error') + ": $_") -ForegroundColor Red
            Write-Host ('  ' + $_.ScriptStackTrace) -ForegroundColor DarkGray
        }
    }

    Nl
    Write-Host ('  ' + (L 'launcher.run.completed' 'Completed. Press any key to return to the menu...')) -ForegroundColor DarkGray
    $null = $HOST.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
}
'@

$newFunc = @'
function Invoke-FieldScript {
    param(
        [Parameter(Mandatory)] [string]$RelativePath,
        [Parameter(Mandatory)] [string]$DisplayName,
        [hashtable]$Arguments = @{}
    )
    $scriptPath = Join-Path $scriptsRoot $RelativePath

    Clear-Host
    Nl
    Hr
    Row ("  " + (L 'launcher.run.running' 'Running') + ":  $DisplayName") 'Yellow'
    Row ("  " + (L 'launcher.run.path'    'Path'   ) + ":     $scriptPath") 'DarkGray'
    Hr
    Nl

    # Capture start time for "what's new" detection.
    # Subtract 2 seconds to be tolerant of clock skew / fast scripts.
    $runStart = (Get-Date).AddSeconds(-2)
    $hadError = $false

    if (-not (Test-Path $scriptPath)) {
        Write-Host ('  [X] ' + (L 'launcher.run.notfound' 'Script not found') + ": $scriptPath") -ForegroundColor Red
        Write-Host ('      ' + (L 'launcher.run.notfound.hint' 'Verify this file exists on the USB.')) -ForegroundColor DarkGray
        $hadError = $true
    } else {
        try {
            if ($Arguments -and $Arguments.Count -gt 0) {
                & $scriptPath @Arguments
            } else {
                & $scriptPath
            }
        } catch {
            Write-Host ('  [X] ' + (L 'launcher.run.error' 'Runtime error') + ": $_") -ForegroundColor Red
            Write-Host ('  ' + $_.ScriptStackTrace) -ForegroundColor DarkGray
            $hadError = $true
        }
    }

    # ----------------------------------------------------------------
    # POST-OPERATION PROMPT
    # Detect new files produced during this run, offer contextual actions.
    # ----------------------------------------------------------------
    if (-not $hadError) {
        Show-PostOpPrompt -RunStart $runStart
    } else {
        Nl
        Write-Host ('  ' + (L 'launcher.run.completed' 'Completed. Press any key to return to the menu...')) -ForegroundColor DarkGray
        $null = $HOST.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    }
}

function Show-PostOpPrompt {
    param([Parameter(Mandatory)] [datetime]$RunStart)

    # Find new files in REPORTS\ and LOGS\ since RunStart
    $newReports = @()
    $newLogs    = @()
    if (Test-Path $reportsDir) {
        $newReports = @(Get-ChildItem $reportsDir -File -Recurse -EA SilentlyContinue |
            Where-Object { $_.LastWriteTime -ge $RunStart })
    }
    if (Test-Path $logsDir) {
        $newLogs = @(Get-ChildItem $logsDir -File -Recurse -EA SilentlyContinue |
            Where-Object { $_.LastWriteTime -ge $RunStart })
    }

    $allNew = @($newReports) + @($newLogs)
    if ($allNew.Count -eq 0) {
        # No artifacts produced. Fall through to standard prompt.
        Nl
        Write-Host ('  ' + (L 'launcher.run.completed' 'Completed. Press any key to return to the menu...')) -ForegroundColor DarkGray
        $null = $HOST.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        return
    }

    # Pick the "primary" artifact: prefer .html, then most recent
    $primaryHtml = @($newReports | Where-Object { $_.Extension -eq '.html' } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1)
    $primary = if ($primaryHtml.Count -gt 0) { $primaryHtml[0] }
               else { @($allNew | Sort-Object LastWriteTime -Descending | Select-Object -First 1)[0] }

    # Detect snapshot files (Compliance produces .json.gz under REPORTS\Snapshots)
    $newSnapshot = @($newReports | Where-Object { $_.Name -like '*.json.gz' -or $_.Name -like 'snapshot_*.json' } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1)
    $hasSnapshot = ($newSnapshot.Count -gt 0)

    # ---- Render the prompt ----
    Nl
    Hr
    Row ('  ' + (L 'launcher.postop.title' 'Operation complete')) 'Green'
    Hr
    Nl

    # File summary
    foreach ($f in ($allNew | Sort-Object LastWriteTime -Descending | Select-Object -First 5)) {
        $kb = [math]::Round($f.Length / 1KB, 1)
        $rel = $f.FullName
        if ($rel.Length -gt 90) { $rel = '...' + $rel.Substring($rel.Length - 87) }
        Write-Host ('    ' + $rel) -ForegroundColor White -NoNewline
        Write-Host ('  (' + $kb + ' KB)') -ForegroundColor DarkGray
    }
    if ($allNew.Count -gt 5) {
        Write-Host ('    ... and ' + ($allNew.Count - 5) + ' more') -ForegroundColor DarkGray
    }

    Nl
    Hr
    Row ('  ' + (L 'launcher.postop.what' 'What next?')) 'Cyan'
    Hr

    # ---- Build the option menu dynamically based on what was produced ----
    $opts = New-Object System.Collections.ArrayList

    if ($primary.Extension -eq '.html') {
        [void]$opts.Add(@{ Key='O'; Color='Cyan';
            Label = (L 'launcher.postop.opt.open'   'Open the report in your browser') })
    }
    [void]$opts.Add(@{ Key='E'; Color='Cyan';
        Label = (L 'launcher.postop.opt.folder' 'Open the REPORTS folder in Explorer') })
    [void]$opts.Add(@{ Key='C'; Color='Cyan';
        Label = (L 'launcher.postop.opt.copy'   'Copy the file path to clipboard') })
    if ($hasSnapshot) {
        [void]$opts.Add(@{ Key='N'; Color='Magenta';
            Label = (L 'launcher.postop.opt.autofixplan' 'Run AutoFix Plan-Before-Execute on this snapshot') })
    }
    [void]$opts.Add(@{ Key='Enter'; Color='DarkGray';
        Label = (L 'launcher.postop.opt.menu' 'Return to main menu') })

    Nl
    foreach ($o in $opts) {
        Write-Host ('  [' + $o.Key + ']') -ForegroundColor $o.Color -NoNewline
        Write-Host ('  ' + $o.Label) -ForegroundColor White
    }
    Nl
    Write-Host ('  ' + (L 'launcher.postop.choice' 'Choice') + ': ') -ForegroundColor DarkGray -NoNewline

    $choice = (Read-Host).Trim().ToUpper()

    switch ($choice) {
        'O' {
            if ($primary.Extension -eq '.html') {
                try {
                    Start-Process $primary.FullName -ErrorAction Stop
                    Write-Host ('  [OK] ' + (L 'launcher.postop.opened' 'Opened') + ': ' + $primary.Name) -ForegroundColor Green
                } catch {
                    Write-Host ('  [X] ' + (L 'launcher.postop.openerr' 'Could not open file') + ': ' + $_) -ForegroundColor Red
                }
            } else {
                Write-Host ('  [!] ' + (L 'launcher.postop.nohtml' 'No HTML report to open from this run.')) -ForegroundColor Yellow
            }
        }
        'E' {
            try {
                Start-Process explorer.exe -ArgumentList $reportsDir -ErrorAction Stop
                Write-Host ('  [OK] ' + (L 'launcher.postop.foldopen' 'Opened folder') + ': ' + $reportsDir) -ForegroundColor Green
            } catch {
                Write-Host ('  [X] ' + (L 'launcher.postop.folderr' 'Could not open folder') + ': ' + $_) -ForegroundColor Red
            }
        }
        'C' {
            try {
                Set-Clipboard -Value $primary.FullName -ErrorAction Stop
                Write-Host ('  [OK] ' + (L 'launcher.postop.copied' 'Copied to clipboard') + ': ' + $primary.FullName) -ForegroundColor Green
            } catch {
                Write-Host ('  [X] ' + (L 'launcher.postop.copyerr' 'Could not copy to clipboard') + ': ' + $_) -ForegroundColor Red
            }
        }
        'N' {
            if ($hasSnapshot) {
                Write-Host ('  ' + (L 'launcher.postop.launchplan' 'Launching AutoFix Plan-Before-Execute...')) -ForegroundColor Magenta
                Start-Sleep -Milliseconds 600
                # Recurse into ourselves -- this will produce its own post-op prompt at the end
                Invoke-FieldScript 'Core\Invoke-AutoFixPlan.ps1' (L 'launcher.menu.autofixplan' 'AutoFix Plan-Before-Execute')
                return
            }
        }
        default {
            # Enter or anything else -> just return
            return
        }
    }

    # After action (except N which already returned), pause briefly then return
    Nl
    Write-Host ('  ' + (L 'launcher.run.completed' 'Press any key to return to the menu...')) -ForegroundColor DarkGray
    $null = $HOST.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
}
'@

if ($content.Contains($oldFunc)) {
    $content = $content.Replace($oldFunc, $newFunc)
    [System.IO.File]::WriteAllText((Resolve-Path .\SCRIPTS\FieldOps-Launcher.ps1), $content, [System.Text.UTF8Encoding]::new($true))
    Write-Host "  [OK] Invoke-FieldScript replaced + Show-PostOpPrompt added" -ForegroundColor Green
    $newSize = (Get-Item .\SCRIPTS\FieldOps-Launcher.ps1).Length
    Write-Host "       Launcher size now: $newSize bytes" -ForegroundColor DarkGray
} else {
    Write-Host "  [X] Anchor not found -- launcher may have been edited since v2.1 polish patch." -ForegroundColor Red
    Write-Host "      File NOT modified. Restore from .postop.bak if needed." -ForegroundColor Red
    return
}

# ==============================================================================
# PATCH 2: Add new locale keys
# ==============================================================================
function Add-PostOpKeys {
    param([string]$LocaleFile, [hashtable]$Strings)
    $loc = Get-Content $LocaleFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $loc.launcher) {
        Write-Host "  [!] $LocaleFile -- no launcher node, skipping" -ForegroundColor Yellow
        return
    }
    if (-not $loc.launcher.postop) {
        $loc.launcher | Add-Member -NotePropertyName 'postop' -NotePropertyValue ([PSCustomObject]@{}) -Force
    }
    if (-not $loc.launcher.postop.opt) {
        $loc.launcher.postop | Add-Member -NotePropertyName 'opt' -NotePropertyValue ([PSCustomObject]@{}) -Force
    }
    foreach ($k in $Strings.Keys) {
        if ($k.StartsWith('opt.')) {
            $sub = $k.Substring(4)
            $loc.launcher.postop.opt | Add-Member -NotePropertyName $sub -NotePropertyValue $Strings[$k] -Force
        } else {
            $loc.launcher.postop | Add-Member -NotePropertyName $k -NotePropertyValue $Strings[$k] -Force
        }
    }
    $json = $loc | ConvertTo-Json -Depth 20
    [System.IO.File]::WriteAllText((Resolve-Path $LocaleFile), $json, [System.Text.UTF8Encoding]::new($false))
}

Add-PostOpKeys '.\CONFIG\lang\en.json' @{
    'title'           = 'Operation complete'
    'what'            = 'What next?'
    'choice'          = 'Choice'
    'opened'          = 'Opened'
    'openerr'         = 'Could not open file'
    'nohtml'          = 'No HTML report to open from this run.'
    'foldopen'        = 'Opened folder'
    'folderr'         = 'Could not open folder'
    'copied'          = 'Copied to clipboard'
    'copyerr'         = 'Could not copy to clipboard'
    'launchplan'      = 'Launching AutoFix Plan-Before-Execute...'
    'opt.open'        = 'Open the report in your browser'
    'opt.folder'      = 'Open the REPORTS folder in Explorer'
    'opt.copy'        = 'Copy the file path to clipboard'
    'opt.autofixplan' = 'Run AutoFix Plan-Before-Execute on this snapshot'
    'opt.menu'        = 'Return to main menu'
}
Write-Host "  [OK] en.json updated with launcher.postop.* keys" -ForegroundColor Green

Add-PostOpKeys '.\CONFIG\lang\fr.json' @{
    'title'           = 'Operation terminee'
    'what'            = 'Et ensuite ?'
    'choice'          = 'Choix'
    'opened'          = 'Ouvert'
    'openerr'         = 'Impossible d''ouvrir le fichier'
    'nohtml'          = 'Aucun rapport HTML a ouvrir.'
    'foldopen'        = 'Dossier ouvert'
    'folderr'         = 'Impossible d''ouvrir le dossier'
    'copied'          = 'Copie dans le presse-papiers'
    'copyerr'         = 'Impossible de copier dans le presse-papiers'
    'launchplan'      = 'Lancement de AutoFix avec Plan...'
    'opt.open'        = 'Ouvrir le rapport dans le navigateur'
    'opt.folder'      = 'Ouvrir le dossier RAPPORTS dans l''Explorateur'
    'opt.copy'        = 'Copier le chemin du fichier dans le presse-papiers'
    'opt.autofixplan' = 'Lancer AutoFix avec Plan sur ce snapshot'
    'opt.menu'        = 'Retour au menu principal'
}
Write-Host "  [OK] fr.json updated with launcher.postop.* keys" -ForegroundColor Green

# Verify
$en = Get-Content .\CONFIG\lang\en.json -Raw -Encoding UTF8 | ConvertFrom-Json
$fr = Get-Content .\CONFIG\lang\fr.json -Raw -Encoding UTF8 | ConvertFrom-Json
Write-Host ""
Write-Host "  Spot-check en.launcher.postop.opt.open = $($en.launcher.postop.opt.open)" -ForegroundColor DarkGray
Write-Host "  Spot-check fr.launcher.postop.opt.open = $($fr.launcher.postop.opt.open)" -ForegroundColor DarkGray
Write-Host "  Spot-check fr.launcher.postop.what     = $($fr.launcher.postop.what)" -ForegroundColor DarkGray

Write-Host ""
Write-Host "  Post-operation prompt patch applied." -ForegroundColor Green
Write-Host "  Re-run a report-generating engine (e.g. PCHealth, Compliance, Dashboard) to see it." -ForegroundColor Cyan
Write-Host "  Rollback: each file has a *.postop.bak alongside it." -ForegroundColor DarkGray
