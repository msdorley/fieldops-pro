#Requires -Version 5.1
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Ousman Dorley. See LICENSE at the repository root.
<#
.SYNOPSIS
    FieldOps Pro -- AutoFix with Plan-Before-Execute v1.0
.DESCRIPTION
    Operator-facing orchestrator that wraps the existing AutoFix fix database
    with an AI-powered planning layer.

    For each detected fix, this engine produces (and caches) a plain-English
    risk analysis BEFORE any change is made:
        - What the fix does and what it changes
        - What could go wrong on this specific machine
        - Reversibility analysis
        - Reboot requirement and downtime estimate
        - Per-machine recommendation

    The operator approves each fix individually after reviewing its plan.
    Three-tier fallback (real Claude API > cache > local rules) means it
    works online and offline.

    This script does NOT modify the original Invoke-AutoFix.ps1. It loads
    the fix-rule database from that file at runtime so any improvements
    to the rules flow through automatically.

.PARAMETER FixId
    Optional. Run against just one fix by ID (e.g. 'SEC-012'). For testing
    or targeted operations.
.PARAMETER DryRun
    Plan everything but do not apply any fix. Equivalent to reviewing all
    plans without execution.
.PARAMETER NoApi
    Skip the Anthropic API. Use local rule-based plans only. Useful when
    offline or when API credits are unavailable.
.PARAMETER NoCache
    Force fresh API calls even if cached plans exist. Useful when the
    machine state has changed materially since the cache was written.
.PARAMETER Language
    Locale override ('en' or 'fr'). Defaults to auto-detection.

.EXAMPLE
    PS> .\Invoke-AutoFixPlan.ps1
    Run against the live machine, plan every detected fix, prompt per-fix.

.EXAMPLE
    PS> .\Invoke-AutoFixPlan.ps1 -FixId SEC-012 -DryRun
    Show the AI risk plan for HVCI without applying anything.

.NOTES
    Author  : FieldOps Pro
    Version : 1.0
    Path    : SCRIPTS\Core\Invoke-AutoFixPlan.ps1
#>
[CmdletBinding()]
param(
    [string]$FixId    = '',
    [switch]$DryRun,
    [switch]$NoApi,
    [switch]$NoCache,
    [string]$Language = ''
)

#Requires -Version 5.1
$ErrorActionPreference = 'Continue'

# ==============================================================================
# PATH SETUP
# ==============================================================================
$ScriptRoot   = $PSScriptRoot
$ProjectRoot  = Split-Path -Parent (Split-Path -Parent $ScriptRoot)
$ReportsPath  = Join-Path $ProjectRoot 'REPORTS'
$LogsPath     = Join-Path $ProjectRoot 'LOGS'
$ConfigPath   = Join-Path $ProjectRoot 'CONFIG'
$AutoFixPath  = Join-Path $ScriptRoot  'Invoke-AutoFix.ps1'
$LocaleMod    = Join-Path $ScriptRoot  'FieldOps-Locale.psm1'
$PlannerMod   = Join-Path $ScriptRoot  'FieldOps-RiskPlanner.psm1'

foreach ($d in @($ReportsPath, $LogsPath)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# ==============================================================================
# IMPORTS
# ==============================================================================
$localeOk = $false
if (Test-Path $LocaleMod) {
    try {
        Import-Module $LocaleMod -Force -DisableNameChecking -ErrorAction Stop
        Initialize-Locale -Language $Language -ConfigDir $ConfigPath
        $localeOk = $true
    } catch {
        Write-Warning "Locale module load failed: $_"
    }
}

if (-not (Test-Path $PlannerMod)) {
    Write-Host "  [X] FieldOps-RiskPlanner.psm1 not found at: $PlannerMod" -ForegroundColor Red
    Write-Host "      This file is required. Aborting." -ForegroundColor Red
    return
}
Import-Module $PlannerMod -Force -DisableNameChecking -ErrorAction Stop

# Resolve current locale (whatever Initialize-Locale ended up at)
$currentLocale = if ($localeOk) {
    try { (Get-Variable -Name 'CurrentLocale' -Scope 1 -ValueOnly -EA SilentlyContinue) } catch { 'en' }
} else { 'en' }
if (-not $currentLocale) { $currentLocale = 'en' }

Initialize-RiskPlanner -ConfigDir $ConfigPath -LogsDir $LogsPath -Locale $currentLocale

# ==============================================================================
# LOCALE HELPER
# ==============================================================================
function L {
    param([string]$Key, [string]$Default)
    if (-not $localeOk) { return $Default }
    try { return (Get-LocaleString $Key) } catch { return $Default }
}

# ==============================================================================
# LOAD THE FIX-RULE DATABASE FROM Invoke-AutoFix.ps1
# We don't dot-source the whole file (it would auto-run). Instead we extract
# just the $script:FixRules block via regex and re-evaluate it locally.
# ==============================================================================
function Get-FixRulesFromAutoFix {
    if (-not (Test-Path $AutoFixPath)) {
        throw "Invoke-AutoFix.ps1 not found at $AutoFixPath"
    }

    # Line-based extraction. Find the line where the array opens, and the
    # line where it closes. Boring, correct, robust.
    #
    # Opening signature: a line ending in '$script:FixRules = @(' (any
    # leading whitespace, optional trailing whitespace). Closing signature:
    # a line whose only non-whitespace content is ')'.
    $lines    = Get-Content $AutoFixPath
    $startLn  = -1
    $endLn    = -1

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $stripped = $lines[$i].Trim()
        if ($startLn -lt 0) {
            if ($stripped -match '^\$script:FixRules\s*=\s*@\(\s*$') {
                $startLn = $i
            }
            continue
        }
        if ($stripped -eq ')') {
            $endLn = $i
            break
        }
    }

    if ($startLn -lt 0) {
        throw "Could not find '`$script:FixRules = @(' in Invoke-AutoFix.ps1"
    }
    if ($endLn -lt 0) {
        throw "Could not find closing ')' for `$script:FixRules in Invoke-AutoFix.ps1"
    }

    # Extract the body lines between (exclusive) and re-evaluate as an array.
    $bodyLines = $lines[($startLn + 1)..($endLn - 1)]
    $rulesBody = $bodyLines -join "`n"
    $rulesArray = Invoke-Expression "@($rulesBody)"
    return @($rulesArray)
}

# ==============================================================================
# CONSOLE HELPERS
# ==============================================================================
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

function _Pause {
    param([string]$Msg)
    if (-not $Msg) { $Msg = (L 'autofixplan.common.anykey' 'Press any key to continue...') }
    Write-Host ''
    Write-Host "  $Msg" -ForegroundColor DarkGray
    $null = $HOST.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
}

# ==============================================================================
# DETECT PHASE -- run Detect on every rule
# ==============================================================================
function Find-DetectedFixes {
    param([array]$AllRules, [string]$OnlyId)

    $detected = New-Object System.Collections.ArrayList
    foreach ($rule in $AllRules) {
        if ($OnlyId -and $rule.Id -ne $OnlyId) { continue }
        try {
            $needs = & $rule.Detect
            if ($needs) {
                [void]$detected.Add($rule)
            }
        } catch {
            Write-Verbose "Detect threw for $($rule.Id): $_"
        }
    }
    return @($detected)
}

# ==============================================================================
# APPLY ONE FIX
# ==============================================================================
function Invoke-OneFix {
    param([hashtable]$Rule)

    $result = [PSCustomObject]@{
        Id          = $Rule.Id
        Name        = $Rule.Name
        AppliedAt   = (Get-Date).ToString('o')
        Outcome     = 'Skipped'
        Verified    = $false
        Error       = $null
        RebootNeeded= [bool]$Rule.Reboot
    }

    Write-Host ''
    Write-Host "  $(L 'autofixplan.apply.applying' 'Applying')..." -ForegroundColor Yellow
    try {
        & $Rule.Fix
        $result.Outcome = 'Applied'
    } catch {
        $result.Outcome = 'Failed'
        $result.Error   = "$_"
        Write-Host "  [X] $(L 'autofixplan.apply.failed' 'Fix command failed'): $_" -ForegroundColor Red
        return $result
    }

    # Verify
    try {
        $ok = & $Rule.Verify
        $result.Verified = [bool]$ok
        if ($ok) {
            Write-Host "  [OK] $(L 'autofixplan.apply.verified' 'Verified -- fix took effect')" -ForegroundColor Green
        } else {
            Write-Host "  [!] $(L 'autofixplan.apply.unverified' 'Applied but verification did not confirm') " -ForegroundColor Yellow
        }
    } catch {
        Write-Host "  [!] $(L 'autofixplan.apply.verifyerror' 'Verify check threw'): $_" -ForegroundColor Yellow
    }

    return $result
}

# ==============================================================================
# MAIN FLOW
# ==============================================================================
_Banner

# Load rules
Write-Host "  $(L 'autofixplan.loading.rules' 'Loading fix-rule database from Invoke-AutoFix.ps1')..." -ForegroundColor DarkGray
try {
    $allRules = Get-FixRulesFromAutoFix
    Write-Host "  [OK] $(L 'autofixplan.loading.rulesok' 'Loaded'): $($allRules.Count) $(L 'autofixplan.loading.rulesword' 'rules')" -ForegroundColor Green
} catch {
    Write-Host "  [X] $(L 'autofixplan.loading.rulesfail' 'Could not load fix rules'): $_" -ForegroundColor Red
    return
}

# Detect
Write-Host ''
Write-Host "  $(L 'autofixplan.scanning' 'Scanning the machine against all rules')..." -ForegroundColor DarkGray
$detected = Find-DetectedFixes -AllRules $allRules -OnlyId $FixId

if ($detected.Count -eq 0) {
    Write-Host ''
    if ($FixId) {
        Write-Host "  $(L 'autofixplan.detect.none.targeted' 'No issue detected for the specified fix ID') ($FixId)" -ForegroundColor Green
    } else {
        Write-Host "  $(L 'autofixplan.detect.none' 'No issues detected. Machine is in compliance with all rules.') " -ForegroundColor Green
    }
    Write-Host ''
    return
}

# Summary
Write-Host ''
Write-Host "  $(L 'autofixplan.detect.found' 'Detected')" -ForegroundColor Cyan -NoNewline
Write-Host " $($detected.Count) " -ForegroundColor Yellow -NoNewline
Write-Host "$(L 'autofixplan.detect.foundsuffix' 'fix(es) to review')" -ForegroundColor Cyan
foreach ($r in $detected) {
    $color = switch ($r.Level) { 'Safe' {'Green'} 'Moderate' {'Yellow'} 'Risky' {'Red'} default {'Gray'} }
    $reboot = if ($r.Reboot) { '[REBOOT]' } else { '' }
    Write-Host ("    {0,-9} +{1,-2}pts  {2,-9} {3} {4}" -f $r.Id, $r.Impact, $r.Level, $r.Name, $reboot) -ForegroundColor $color
}
Write-Host ''
Write-Host "  $(L 'autofixplan.flow.intro' 'You will see an AI-generated risk plan for each fix before any change is made.')" -ForegroundColor DarkCyan
Write-Host "  $(L 'autofixplan.flow.intro2' 'You approve or skip each fix individually.')" -ForegroundColor DarkCyan
_Pause

# Per-fix loop
$session = [PSCustomObject]@{
    Started   = (Get-Date).ToString('o')
    Host      = $env:COMPUTERNAME
    Locale    = $currentLocale
    DryRun    = [bool]$DryRun
    NoApi     = [bool]$NoApi
    Detected  = @($detected | ForEach-Object { @{ Id=$_.Id; Name=$_.Name; Level=$_.Level; Impact=$_.Impact } })
    Plans     = New-Object System.Collections.ArrayList
    Decisions = New-Object System.Collections.ArrayList
    Results   = New-Object System.Collections.ArrayList
    RebootRecommended = $false
}

$idx = 0
foreach ($rule in $detected) {
    $idx++
    Clear-Host
    _Banner
    Write-Host "  [$idx / $($detected.Count)] $(L 'autofixplan.fix.label' 'Fix')" -ForegroundColor Magenta
    Write-Host ''

    # Build a hashtable copy of the rule for the planner (the AutoFix rules
    # are defined as hashtables in the source, but Invoke-Expression yields
    # them already as hashtables, so this is effectively pass-through).
    $ruleHash = @{}
    foreach ($k in $rule.Keys) { $ruleHash[$k] = $rule[$k] }

    # Get the plan
    Write-Host "  $(L 'autofixplan.plan.generating' 'Generating risk plan')..." -ForegroundColor DarkGray
    $plan = Get-FixRiskPlan -FixRule $ruleHash -NoApi:$NoApi -NoCache:$NoCache

    # Capture for log
    [void]$session.Plans.Add(@{
        FixId          = $rule.Id
        Source         = $plan.source
        Recommendation = $plan.recommendation
        Generated      = $plan.generated
    })

    # Show
    Show-FixRiskPlan -FixRule $ruleHash -Plan $plan

    # Prompt
    if ($DryRun) {
        Write-Host "  [$(L 'autofixplan.dryrun' 'DRY RUN')] $(L 'autofixplan.dryrun.skip' 'Skipping execution')" -ForegroundColor Yellow
        [void]$session.Decisions.Add(@{ FixId=$rule.Id; Decision='dryrun_skipped' })
        if ($idx -lt $detected.Count) { _Pause (L 'autofixplan.dryrun.next' 'Press any key for next fix...') }
        continue
    }

    Write-Host '  +----------------------------------------------------------------------+' -ForegroundColor Cyan
    Write-Host "  |  [A] $(L 'autofixplan.prompt.apply' 'Apply this fix')" -ForegroundColor Green
    Write-Host "  |  [S] $(L 'autofixplan.prompt.skip' 'Skip (do not apply)') " -ForegroundColor Yellow
    Write-Host "  |  [Q] $(L 'autofixplan.prompt.quit' 'Quit AutoFixPlan (no further fixes)') " -ForegroundColor Red
    Write-Host '  +----------------------------------------------------------------------+' -ForegroundColor Cyan
    Write-Host ''
    $choice = (Read-Host ('  ' + (L 'autofixplan.prompt.choice' 'Choice'))).Trim().ToUpper()

    switch ($choice) {
        'A' {
            $result = Invoke-OneFix -Rule $ruleHash
            [void]$session.Decisions.Add(@{ FixId=$rule.Id; Decision='applied' })
            [void]$session.Results.Add($result)
            if ($result.RebootNeeded -and $result.Outcome -eq 'Applied') {
                $session.RebootRecommended = $true
            }
            _Pause
        }
        'Q' {
            [void]$session.Decisions.Add(@{ FixId=$rule.Id; Decision='aborted' })
            Write-Host ''
            Write-Host "  $(L 'autofixplan.flow.aborted' 'Aborted by operator. No further fixes will be applied.')" -ForegroundColor Yellow
            break
        }
        default {
            [void]$session.Decisions.Add(@{ FixId=$rule.Id; Decision='skipped' })
            Write-Host "  $(L 'autofixplan.flow.skipped' 'Skipped.')" -ForegroundColor DarkGray
            if ($idx -lt $detected.Count) { _Pause (L 'autofixplan.flow.next' 'Press any key for next fix...') }
        }
    }
}

# ==============================================================================
# SESSION SUMMARY + LOG
# ==============================================================================
$session.Ended = (Get-Date).ToString('o')

Clear-Host
_Banner
Write-Host "  $(L 'autofixplan.summary.title' 'SESSION SUMMARY')" -ForegroundColor Cyan
Write-Host '  ----------------------------------------------------------------------'
$applied = @($session.Results | Where-Object { $_.Outcome -eq 'Applied' })
$failed  = @($session.Results | Where-Object { $_.Outcome -eq 'Failed' })
$skipCount = ($session.Decisions | Where-Object { $_.Decision -in @('skipped','dryrun_skipped','aborted') }).Count

Write-Host "  $(L 'autofixplan.summary.detected' 'Detected'):  $($detected.Count)" -ForegroundColor White
Write-Host "  $(L 'autofixplan.summary.applied' 'Applied'):    $($applied.Count)"  -ForegroundColor Green
Write-Host "  $(L 'autofixplan.summary.failed'  'Failed'):     $($failed.Count)"   -ForegroundColor $(if ($failed.Count -gt 0) {'Red'} else {'DarkGray'})
Write-Host "  $(L 'autofixplan.summary.skipped' 'Skipped'):    $skipCount"          -ForegroundColor DarkGray

if ($session.RebootRecommended) {
    Write-Host ''
    Write-Host "  [!] $(L 'autofixplan.summary.reboot' 'A reboot is required to complete one or more applied fixes.')" -ForegroundColor Yellow
}

# Persist log
$ts = Get-Date -Format 'yyyyMMdd_HHmmss'
$logPath = Join-Path $LogsPath ("AutoFixPlan_$($env:COMPUTERNAME)_$ts.json")
try {
    $session | ConvertTo-Json -Depth 10 | Out-File $logPath -Encoding utf8 -Force
    Write-Host ''
    Write-Host "  $(L 'autofixplan.summary.logwritten' 'Session log'): $logPath" -ForegroundColor DarkGray
} catch {
    Write-Host "  [!] $(L 'autofixplan.summary.lognofail' 'Could not write session log'): $_" -ForegroundColor Yellow
}

Write-Host ''
