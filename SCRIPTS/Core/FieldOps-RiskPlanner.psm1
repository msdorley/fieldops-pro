#Requires -Version 5.1
<#
.SYNOPSIS
    FieldOps Pro -- AI Risk Planning Engine v1.0
.DESCRIPTION
    Generates plain-English risk analysis for AutoFix rules BEFORE they run.

    For each detected fix, produces a structured risk plan covering:
        - What the fix changes (technical detail)
        - What could go wrong (per-machine compatibility risks)
        - Reversibility analysis (what rollback actually does, residual risk)
        - Reboot requirement and downtime expectation
        - Recommendation rating for THIS specific machine

    Uses Anthropic Claude API as primary planner with three-tier fallback:
        Tier 1: Real Claude API call (Sonnet 4.6 by default)
        Tier 2: Cached previous result for same fix-id (skips API on warm runs)
        Tier 3: Local rule-based mock plan (offline-safe, always works)

    Plans are cached to LOGS\plan-cache\<fix-id>_<machine-hash>.json so
    operators can re-view a plan without re-paying API tokens. Cache TTL: 7 days.

.NOTES
    Author  : FieldOps Pro
    Version : 1.0
    Path    : SCRIPTS\Core\FieldOps-RiskPlanner.psm1
    Requires: PowerShell 5.1
#>

# Module-scope state
$script:RiskPlannerInitialized = $false
$script:ApiKey               = ''
$script:ApiModel             = 'claude-sonnet-4-6'
$script:ApiEndpoint          = 'https://api.anthropic.com/v1/messages'
$script:ApiVersion           = '2023-06-01'
$script:CacheDir             = ''
$script:CacheTTLDays         = 7
$script:Locale               = 'en'

# ==============================================================================
# INITIALIZATION
# ==============================================================================
function Initialize-RiskPlanner {
    <#
    .SYNOPSIS
        One-time setup. Reads API key from technician.json, locates cache dir.
    .PARAMETER ConfigDir
        Path to CONFIG directory. Auto-detected from module location if empty.
    .PARAMETER LogsDir
        Path to LOGS directory (where plan-cache will live). Auto-detected.
    .PARAMETER Locale
        Locale code for plan-prompt language. Defaults to 'en'.
    #>
    [CmdletBinding()]
    param(
        [string]$ConfigDir = '',
        [string]$LogsDir   = '',
        [string]$Locale    = 'en'
    )

    # Auto-detect dirs from module location: ...\SCRIPTS\Core\ â†’ ...\
    if ($ConfigDir -eq '' -or $LogsDir -eq '') {
        $modDir   = $PSScriptRoot
        $usbRoot  = Split-Path -Parent (Split-Path -Parent $modDir)
        if ($ConfigDir -eq '') { $ConfigDir = Join-Path $usbRoot 'CONFIG' }
        if ($LogsDir   -eq '') { $LogsDir   = Join-Path $usbRoot 'LOGS' }
    }

    $script:Locale   = $Locale
    $script:CacheDir = Join-Path $LogsDir 'plan-cache'
    if (-not (Test-Path $script:CacheDir)) {
        New-Item -ItemType Directory -Path $script:CacheDir -Force | Out-Null
    }

    # ----------------------------------------------------------------
    # Read API key. SECURITY: keys are NEVER read from JSON files.
    # Lookup priority:
    #   Tier 0: Windows Credential Manager target 'FieldOpsPro:Anthropic'
    #           (or whatever target name is configured in technician.json
    #           under ai.credentialTarget â€” useful for orgs with naming
    #           conventions like 'MyOrg:Claude')
    #   Tier 1: Environment variable ANTHROPIC_API_KEY (CI/scripted use)
    #   Tier 2: None -- fall back to local mock plan in Get-FixRiskPlan
    # ----------------------------------------------------------------
    $credTarget = 'FieldOpsPro:Anthropic'

    # Optional: read model name and credential-target override from
    # technician.json. Model names are not secrets and are convenient
    # to keep alongside the rest of the toolkit config.
    $cfgPath = Join-Path $ConfigDir 'technician.json'
    if (Test-Path $cfgPath) {
        try {
            $cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($parent in @('ai','anthropic','AI','Anthropic')) {
                $sub = $cfg.$parent
                if (-not $sub) { continue }
                foreach ($field in @('model','modelId','Model')) {
                    $v = $sub.$field
                    if ($v -and "$v".Trim() -ne '') { $script:ApiModel = "$v".Trim(); break }
                }
                foreach ($field in @('credentialTarget','credTarget','keyTarget')) {
                    $v = $sub.$field
                    if ($v -and "$v".Trim() -ne '') { $credTarget = "$v".Trim(); break }
                }
            }
        } catch {
            Write-Verbose "RiskPlanner: technician.json parse failed (non-fatal): $_"
        }
    }

    # Tier 0: Windows Credential Manager
    if ($script:ApiKey -eq '') {
        try {
            Import-Module CredentialManager -ErrorAction SilentlyContinue
            if (Get-Command Get-StoredCredential -ErrorAction SilentlyContinue) {
                $cred = Get-StoredCredential -Target $credTarget -ErrorAction SilentlyContinue
                if ($cred) {
                    $script:ApiKey = $cred.GetNetworkCredential().Password
                    Write-Verbose "RiskPlanner: API key loaded from Credential Manager target '$credTarget'."
                } else {
                    Write-Verbose "RiskPlanner: no credential found at target '$credTarget'."
                }
            } else {
                Write-Verbose "RiskPlanner: CredentialManager module not available -- skipping Tier 0."
            }
        } catch {
            Write-Verbose "RiskPlanner: Credential Manager lookup failed (non-fatal): $_"
        }
    }

    # Tier 1: Environment variable
    if ($script:ApiKey -eq '' -and $env:ANTHROPIC_API_KEY) {
        $script:ApiKey = $env:ANTHROPIC_API_KEY
        Write-Verbose "RiskPlanner: API key loaded from `$env:ANTHROPIC_API_KEY."
    }

    $script:RiskPlannerInitialized = $true
}

# ==============================================================================
# MACHINE FINGERPRINT -- used in cache key so plans are machine-specific
# ==============================================================================
function Get-MachineFingerprint {
    # Stable across runs on the same machine, different across machines.
    # Includes hostname + OS version. NOT a unique identifier for tracking.
    try {
        $os = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).Version
    } catch { $os = 'unknown' }
    $raw = "$env:COMPUTERNAME|$os"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($raw)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hash = $sha.ComputeHash($bytes)
    $sha.Dispose()
    return ([BitConverter]::ToString($hash) -replace '-','').Substring(0, 12).ToLower()
}

# ==============================================================================
# CACHE
# ==============================================================================
function Get-CachedPlan {
    param([string]$FixId, [string]$Fingerprint)
    if (-not $script:RiskPlannerInitialized) { return $null }
    $cachePath = Join-Path $script:CacheDir "${FixId}_${Fingerprint}.json"
    if (-not (Test-Path $cachePath)) { return $null }

    try {
        $cached = Get-Content $cachePath -Raw -Encoding UTF8 | ConvertFrom-Json
        # TTL check
        $cachedDate = [datetime]$cached.cachedAt
        if ((Get-Date) - $cachedDate -gt [timespan]::FromDays($script:CacheTTLDays)) {
            return $null  # Expired
        }
        return $cached.plan
    } catch {
        return $null
    }
}

function Save-CachedPlan {
    param([string]$FixId, [string]$Fingerprint, [object]$Plan)
    if (-not $script:RiskPlannerInitialized) { return }
    $cachePath = Join-Path $script:CacheDir "${FixId}_${Fingerprint}.json"
    $wrapper = [PSCustomObject]@{
        cachedAt = (Get-Date).ToString('o')
        fixId    = $FixId
        plan     = $Plan
    }
    try {
        $wrapper | ConvertTo-Json -Depth 10 |
            Out-File $cachePath -Encoding utf8 -Force
    } catch {
        Write-Verbose "RiskPlanner: failed to write cache: $_"
    }
}

# ==============================================================================
# TIER 1: REAL ANTHROPIC API
# ==============================================================================
function Invoke-AnthropicPlanner {
    param(
        [Parameter(Mandatory)] [hashtable]$FixRule,
        [Parameter(Mandatory)] [hashtable]$MachineContext
    )

    if ($script:ApiKey -eq '') { return $null }

    # Build prompt. Plain-English, locale-aware.
    $langName = if ($script:Locale -eq 'fr') { 'French' } else { 'English' }

    $rollbackText = if ($FixRule.Rollback) { $FixRule.Rollback } else { '(no documented rollback)' }
    $fixText      = "$($FixRule.Fix)"
    if ($fixText.Length -gt 800) { $fixText = $fixText.Substring(0, 800) + '...[truncated]' }

    $machineLines = @()
    foreach ($k in $MachineContext.Keys) { $machineLines += "  - $($k): $($MachineContext[$k])" }
    $machineSummary = $machineLines -join "`n"

    $userPrompt = @"
You are a senior Windows endpoint security engineer reviewing a proposed
remediation BEFORE it is applied to a real machine. Your job is to give
the operator (a field IT technician) a plain, operator-friendly risk
analysis they can use to decide whether to proceed.

Respond in $langName. Use simple sentences. No marketing language.

The proposed fix:
  ID:           $($FixRule.Id)
  Name:         $($FixRule.Name)
  Domain:       $($FixRule.Domain)
  Risk level:   $($FixRule.Level)
  Impact:       +$($FixRule.Impact) compliance grade points
  Reboot:       $(if ($FixRule.Reboot) { 'Required' } else { 'Not required' })
  Description:  $($FixRule.Desc)

  Fix command (PowerShell):
$fixText

  Documented rollback:
$rollbackText

The target machine:
$machineSummary

Return ONLY a single JSON object (no prose, no markdown fences) with these exact keys:
{
  "what_it_does":          "1-2 sentences. What the change actually accomplishes.",
  "what_it_changes":       "1-2 sentences. The specific registry key, service, or system setting modified.",
  "what_could_go_wrong":   "2-3 sentences. Realistic failure modes and which software/hardware on this kind of machine could be affected. Be specific. If risk is genuinely minimal, say so.",
  "reversibility":         "1-2 sentences. How well the rollback actually undoes the change. Note any residual side effects.",
  "reboot_required":       true_or_false,
  "estimated_downtime":    "Short string like 'None', '2-3 minutes (reboot)', '5+ minutes (driver re-init possible)'.",
  "recommendation":        "One of: STRONGLY_RECOMMENDED | RECOMMENDED | CAUTION | DEFER | NOT_RECOMMENDED",
  "recommendation_reason": "1-2 sentences. Why that recommendation FOR THIS SPECIFIC MACHINE."
}
"@

    $body = @{
        model      = $script:ApiModel
        max_tokens = 1200
        messages   = @(
            @{ role = 'user'; content = $userPrompt }
        )
    } | ConvertTo-Json -Depth 10 -Compress

    $headers = @{
        'x-api-key'         = $script:ApiKey
        'anthropic-version' = $script:ApiVersion
        'content-type'      = 'application/json'
    }

    try {
        $resp = Invoke-RestMethod -Uri $script:ApiEndpoint -Method Post `
                  -Headers $headers -Body $body -TimeoutSec 30 -ErrorAction Stop

        # Extract text from first content block
        $text = $resp.content[0].text
        if (-not $text) { return $null }

        # Strip ```json fences if model included them
        $text = $text -replace '```json',''  -replace '```',''
        $text = $text.Trim()

        $plan = $text | ConvertFrom-Json -ErrorAction Stop

        # Add metadata about how this plan was produced
        $plan | Add-Member -NotePropertyName 'source'    -NotePropertyValue 'anthropic_api' -Force
        $plan | Add-Member -NotePropertyName 'model'     -NotePropertyValue $script:ApiModel -Force
        $plan | Add-Member -NotePropertyName 'generated' -NotePropertyValue (Get-Date).ToString('o') -Force

        return $plan
    } catch {
        Write-Verbose "RiskPlanner: API call failed: $_"
        return $null
    }
}

# ==============================================================================
# TIER 3: LOCAL RULE-BASED MOCK
# ==============================================================================
function New-LocalMockPlan {
    param(
        [Parameter(Mandatory)] [hashtable]$FixRule,
        [Parameter(Mandatory)] [hashtable]$MachineContext
    )

    # Locale-aware static templates -- these are good-enough fallbacks when
    # no API is available. They use the rule's own metadata to compose a plan.
    $isFr = ($script:Locale -eq 'fr')

    $whatItDoes = if ($isFr) {
        "Cette correction applique l'action: $($FixRule.Desc)"
    } else {
        "This fix applies the following action: $($FixRule.Desc)"
    }

    $whatItChanges = if ($isFr) {
        "Modifie la configuration systeme. Voir la commande PowerShell pour les details exacts."
    } else {
        "Modifies system configuration. See the PowerShell command for exact details."
    }

    # Risk text scales with the rule's own classification
    $whatCouldGoWrong = switch ($FixRule.Level) {
        'Safe' {
            if ($isFr) {
                "Risque faible. Cette correction est classee SAFE et est conÃ§ue pour etre completement reversible. Aucun impact connu sur la compatibilite logicielle ou materielle."
            } else {
                "Low risk. This fix is classified SAFE and is designed to be fully reversible. No known software or hardware compatibility impact."
            }
        }
        'Moderate' {
            if ($isFr) {
                "Risque modere. Peut necessiter un redemarrage. Certains pilotes ou logiciels anciens peuvent etre affectes. Verifiez la compatibilite avant d'appliquer sur des machines critiques."
            } else {
                "Moderate risk. May require a reboot. Some older drivers or software may be affected. Verify compatibility before applying on critical machines."
            }
        }
        'Risky' {
            if ($isFr) {
                "Risque eleve. Cette modification peut affecter la compatibilite avec des logiciels tiers. Test recommande sur une machine non-critique d'abord. Une procedure de rollback documentee est disponible."
            } else {
                "High risk. This change may affect third-party software compatibility. Recommended to test on a non-critical machine first. A documented rollback is available."
            }
        }
        default {
            if ($isFr) {
                "Niveau de risque non specifie. Examinez la commande PowerShell et la procedure de rollback avant d'appliquer."
            } else {
                "Risk level not specified. Review the PowerShell command and rollback procedure before applying."
            }
        }
    }

    $reversibility = if ($FixRule.Rollback -and $FixRule.Rollback -notmatch '^#') {
        if ($isFr) { "Rollback documente: $($FixRule.Rollback). Reversible." }
        else       { "Documented rollback: $($FixRule.Rollback). Reversible." }
    } else {
        if ($isFr) { "Pas de rollback automatique. La modification peut ne pas etre completement reversible." }
        else       { "No automatic rollback. The change may not be fully reversible." }
    }

    $downtime = if ($FixRule.Reboot) {
        if ($isFr) { "2-5 minutes (redemarrage)" } else { "2-5 minutes (reboot)" }
    } else {
        if ($isFr) { "Aucun" } else { "None" }
    }

    $recommendation = switch ($FixRule.Level) {
        'Safe'     { 'RECOMMENDED' }
        'Moderate' { 'CAUTION' }
        'Risky'    { 'DEFER' }
        default    { 'CAUTION' }
    }

    $recReason = if ($isFr) {
        "Recommandation basee sur le niveau de risque '$($FixRule.Level)' classe par le moteur. Aucune analyse IA disponible (mode hors-ligne)."
    } else {
        "Recommendation based on the engine's '$($FixRule.Level)' risk classification. No AI analysis available (offline mode)."
    }

    return [PSCustomObject]@{
        what_it_does          = $whatItDoes
        what_it_changes       = $whatItChanges
        what_could_go_wrong   = $whatCouldGoWrong
        reversibility         = $reversibility
        reboot_required       = [bool]$FixRule.Reboot
        estimated_downtime    = $downtime
        recommendation        = $recommendation
        recommendation_reason = $recReason
        source                = 'local_mock'
        model                 = 'rule-based'
        generated             = (Get-Date).ToString('o')
    }
}

# ==============================================================================
# PUBLIC: Get-FixRiskPlan
# Three-tier fallback. Returns a PSCustomObject with the risk plan fields.
# ==============================================================================
function Get-FixRiskPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable]$FixRule,
        [hashtable]$MachineContext = $null,
        [switch]$NoCache,
        [switch]$NoApi
    )

    if (-not $script:RiskPlannerInitialized) {
        Initialize-RiskPlanner
    }

    if ($null -eq $MachineContext) {
        $MachineContext = Get-DefaultMachineContext
    }

    $fingerprint = Get-MachineFingerprint
    $fixId = $FixRule.Id

    # Tier 2: Cache (unless caller said no)
    if (-not $NoCache) {
        $cached = Get-CachedPlan -FixId $fixId -Fingerprint $fingerprint
        if ($null -ne $cached) {
            $cached | Add-Member -NotePropertyName 'source_note' `
                -NotePropertyValue 'cached' -Force
            return $cached
        }
    }

    # Tier 1: Real API (unless caller said no)
    if (-not $NoApi -and $script:ApiKey -ne '') {
        $apiPlan = Invoke-AnthropicPlanner -FixRule $FixRule -MachineContext $MachineContext
        if ($null -ne $apiPlan) {
            Save-CachedPlan -FixId $fixId -Fingerprint $fingerprint -Plan $apiPlan
            return $apiPlan
        }
    }

    # Tier 3: Local mock
    return (New-LocalMockPlan -FixRule $FixRule -MachineContext $MachineContext)
}

# ==============================================================================
# DEFAULT MACHINE CONTEXT
# ==============================================================================
function Get-DefaultMachineContext {
    $ctx = @{}
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $ctx['os']           = "$($os.Caption) (build $($os.BuildNumber))"
        $ctx['memory_gb']    = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
    } catch {}
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $ctx['manufacturer'] = $cs.Manufacturer
        $ctx['model']        = $cs.Model
        $ctx['domain_role']  = $cs.DomainRole
    } catch {}
    try {
        $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
        $ctx['cpu']          = ($cpu.Name -replace '\s+',' ').Trim()
    } catch {}
    try {
        # Quick check for VPN / virtualization software presence
        $vpnHints = @()
        if (Get-Service -Name 'PanGPS' -ErrorAction SilentlyContinue) { $vpnHints += 'GlobalProtect' }
        if (Get-Service -Name 'CiscoAnyConnect' -ErrorAction SilentlyContinue) { $vpnHints += 'AnyConnect' }
        if (Test-Path 'C:\Program Files\VMware') { $vpnHints += 'VMware' }
        if (Test-Path 'C:\Program Files\Oracle\VirtualBox') { $vpnHints += 'VirtualBox' }
        if ($vpnHints.Count -gt 0) {
            $ctx['vpn_or_virt_present'] = ($vpnHints -join ', ')
        }
    } catch {}
    $ctx['hostname'] = $env:COMPUTERNAME
    return $ctx
}

# ==============================================================================
# PUBLIC: Show-FixRiskPlan -- pretty-prints to console
# ==============================================================================
function Show-FixRiskPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable]$FixRule,
        [Parameter(Mandatory)] [object]$Plan
    )

    $isFr = ($script:Locale -eq 'fr')

    # Color the recommendation
    $recColor = switch ($Plan.recommendation) {
        'STRONGLY_RECOMMENDED' { 'Green' }
        'RECOMMENDED'          { 'Green' }
        'CAUTION'              { 'Yellow' }
        'DEFER'                { 'DarkYellow' }
        'NOT_RECOMMENDED'      { 'Red' }
        default                { 'Gray' }
    }

    # Source indicator
    $srcText = switch ($Plan.source) {
        'anthropic_api' { if ($isFr) { "Analyse IA (Claude $($Plan.model))" } else { "AI analysis (Claude $($Plan.model))" } }
        'local_mock'    { if ($isFr) { "Analyse locale (mode hors-ligne)" }    else { "Local rules (offline mode)" } }
        default         { if ($isFr) { "Analyse" }                              else { "Analysis" } }
    }
    if ($Plan.source_note -eq 'cached') {
        $srcText += if ($isFr) { ' [cache]' } else { ' [cached]' }
    }

    $bannerTitle = if ($isFr) { 'PLAN AVANT EXECUTION' } else { 'PLAN BEFORE EXECUTE' }
    $W = 122
    Write-Host ''
    Write-Host ('  +' + ('-' * $W) + '+') -ForegroundColor Cyan
    Write-Host ('  |  ' + $bannerTitle.PadRight($W - 2) + '|') -ForegroundColor Cyan
    Write-Host ('  +' + ('-' * $W) + '+') -ForegroundColor Cyan
    Write-Host ''

    Write-Host "  $($FixRule.Id) -- $($FixRule.Name)" -ForegroundColor Yellow
    Write-Host "  $(if ($isFr) {'Domaine'} else {'Domain'}): $($FixRule.Domain)   $(if ($isFr) {'Niveau'} else {'Level'}): $($FixRule.Level)   $(if ($isFr) {'Impact'} else {'Impact'}): +$($FixRule.Impact)pts" -ForegroundColor DarkGray
    Write-Host "  $srcText" -ForegroundColor DarkGray
    Write-Host ''

    function _Section($titleEn, $titleFr, $body) {
        $title = if ($isFr) { $titleFr } else { $titleEn }
        Write-Host "  -- $title --" -ForegroundColor Cyan
        # Wrap text at ~70 chars
        $words = $body -split ' '
        $line = '  '
        foreach ($w in $words) {
            if (($line.Length + $w.Length + 1) -gt 76) {
                Write-Host $line
                $line = '  ' + $w
            } else {
                if ($line -eq '  ') { $line += $w } else { $line += ' ' + $w }
            }
        }
        if ($line.Trim() -ne '') { Write-Host $line }
        Write-Host ''
    }

    _Section 'What it does'         "Ce que cela fait"            $Plan.what_it_does
    _Section 'What it changes'      "Ce que cela modifie"         $Plan.what_it_changes
    _Section 'What could go wrong'  "Ce qui pourrait mal tourner" $Plan.what_could_go_wrong
    _Section 'Reversibility'        "Reversibilite"               $Plan.reversibility

    $rebootText = if ($Plan.reboot_required) {
        if ($isFr) { 'OUI -- redemarrage requis' } else { 'YES -- reboot required' }
    } else {
        if ($isFr) { 'Non' } else { 'No' }
    }
    Write-Host "  -- $(if ($isFr) {'Redemarrage'} else {'Reboot'}) --" -ForegroundColor Cyan
    Write-Host "  $rebootText" -ForegroundColor $(if ($Plan.reboot_required) { 'Yellow' } else { 'White' })
    Write-Host ''

    Write-Host "  -- $(if ($isFr) {'Temps d''arret estime'} else {'Estimated downtime'}) --" -ForegroundColor Cyan
    Write-Host "  $($Plan.estimated_downtime)"
    Write-Host ''

    # Recommendation as a box
    $W = 122
    Write-Host ('  +' + ('-' * $W) + '+') -ForegroundColor $recColor
    $recLabel = if ($isFr) { 'RECOMMANDATION' } else { 'RECOMMENDATION' }
    $recLine = "  $recLabel : $($Plan.recommendation)"
    if ($recLine.Length -gt $W) { $recLine = $recLine.Substring(0, $W - 1) + '~' }
    Write-Host ('  |' + $recLine.PadRight($W) + '|') -ForegroundColor $recColor
    Write-Host ('  +' + ('-' * $W) + '+') -ForegroundColor $recColor
    Write-Host ''

    _Section 'Why' 'Pourquoi' $Plan.recommendation_reason
}

# Export public surface
Export-ModuleMember -Function Initialize-RiskPlanner, Get-FixRiskPlan, Show-FixRiskPlan, Get-DefaultMachineContext
