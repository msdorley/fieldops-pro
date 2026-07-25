#Requires -Version 5.1
<#
================================================================================
FieldOps-AIClient.psm1 -- FieldOps Pro Phase 6, Stream 6.5 (D1)
================================================================================
Centralized client for all Anthropic API calls (requirement 6.5-R1).

WHAT THIS MODULE IS FOR

    Before this module, AI calls were made directly from call sites with no
    cost ceiling. A customer running the toolkit against their own API key had
    no defense against a runaway prompt, and fleet mode (Stream 6.3) multiplies
    every call by the number of machines scanned. This module is the single
    place where a call can be refused before it costs anything.

DESIGN POSTURE: ESTIMATION MUST NEVER UNDER-REPORT

    A cost ceiling is a safety control. If the estimate comes in low, the
    ceiling admits a call it exists to refuse, and the operator finds out on
    their invoice. Every rounding decision here therefore errs high:

      - token counts round UP (Math.Ceiling)
      - the chars-per-token ratio is deliberately low (see AIModelPricing.json)
      - an unrecognised model is priced as the most expensive current model
      - promotional prices are never used; standard list rates only

    The inverse error -- refusing a call that would have been affordable --
    costs the operator a fallback path, not money. That asymmetry drives the
    design.

FAIL-CLOSED ON MISSING PRICING

    If the pricing config cannot be read, the client cannot estimate cost, so
    it cannot enforce the ceiling. It refuses the call rather than proceeding
    unmetered. This is not in tension with graceful degradation (6.5-R10): a
    refusal is a clean, signalled failure that the caller handles with its
    fallback path. Proceeding without a ceiling would be the unsafe option.

NEVER THROWS

    Invoke-FieldOpsAI always returns a result object. Callers branch on
    .Success and use .FailureReason. No AI feature is a hard dependency
    (6.5-R10); an exception escaping this module would break that contract and
    take down a diagnostic run over an optional narration.

TESTABILITY

    All network access goes through the single internal function
    Invoke-AIHttpRequest. Tests mock that one boundary, so the entire cost,
    ceiling, retry and degradation surface is verifiable offline. This matters
    beyond convenience: the suite runs air-gapped and the pre-push hook cannot
    depend on a live API key.

NOTE ON -CaptureFullTranscript

    Design doc 6.5.4.1 names this switch -Verbose. That collides with the
    PowerShell common parameter of the same name, which every CmdletBinding
    function already exposes and which operators reasonably expect to control
    diagnostic output only. Binding prompt-and-response persistence to it
    would mean anyone adding -Verbose while debugging silently starts writing
    potentially sensitive content to disk. Renamed for that reason.

SCOPE OF THIS PR (Stream 6.5, PR 2 of 7)

    Implemented here: model resolution, cost estimation, per-invocation and
    per-session ceilings, retry with backoff, graceful degradation.

    Arriving later, with the result-object fields already present and null so
    the contract does not change under call sites:
      PR3  audit logging      -> AuditRecordPath, AuditRecordSha256
      PR4  severity classifier -> Severity, NeedsHumanReview
      PR6  playbook validation -> PlaybookRef, PlaybookValid
================================================================================
#>

# ------------------------------------------------------------------------------
# Module state
# ------------------------------------------------------------------------------
$script:SessionCostUSD   = 0.0
$script:SessionCallCount = 0
$script:PricingConfig    = $null
$script:PricingConfigPath = ''

$script:DefaultSessionCeilingUSD = 5.00
$script:DefaultInvocationCeilingUSD = 0.50
$script:ApiEndpoint = 'https://api.anthropic.com/v1/messages'
$script:ApiVersion  = '2023-06-01'
$script:MaxAttempts = 4

# Failure reasons. Callers may branch on these, so they are a contract.
$script:FailureReasons = @{
    NoApiKey              = 'NoApiKey'
    PricingUnavailable    = 'PricingConfigUnavailable'
    InvocationCeiling     = 'EstimateExceedsCeiling'
    SessionCeiling        = 'SessionCeilingExceeded'
    RetriesExhausted      = 'TransientFailureRetriesExhausted'
    NonTransient          = 'NonTransientFailure'
    MalformedResponse     = 'MalformedResponse'
    UnknownTier           = 'UnknownTaskTier'
}

# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------

function Resolve-AIConfigRoot {
    <#
    .SYNOPSIS
        Locate the repository CONFIG directory from this module's location.
    #>
    param([string]$ConfigDir = '')
    if ($ConfigDir) { return $ConfigDir }
    if (-not $PSScriptRoot) { return '' }
    # SCRIPTS\AI -> SCRIPTS -> repo root
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    return (Join-Path $repoRoot 'CONFIG')
}

function Import-AIPricingConfig {
    <#
    .SYNOPSIS
        Load and cache CONFIG/AIModelPricing.json.
    .DESCRIPTION
        Returns $null on any failure. Callers treat $null as fail-closed: no
        pricing means no cost estimate means no ceiling enforcement means the
        call must be refused.
    #>
    [CmdletBinding()]
    param([string]$ConfigDir = '', [switch]$Force)

    $dir = Resolve-AIConfigRoot -ConfigDir $ConfigDir
    if (-not $dir) { return $null }
    $path = Join-Path $dir 'AIModelPricing.json'

    # Cache is keyed on the resolved path. A global cache would return the
    # first config loaded regardless of which ConfigDir a later caller asked
    # for, which silently ignores the argument and makes fail-closed
    # behaviour impossible to exercise.
    if ($script:PricingConfig -and -not $Force -and $script:PricingConfigPath -eq $path) {
        return $script:PricingConfig
    }
    if ($script:PricingConfigPath -ne $path) { $script:PricingConfig = $null }

    if (-not (Test-Path -LiteralPath $path)) {
        $script:PricingConfigPath = $path
        return $null
    }

    try {
        $cfg = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        return $null
    }

    $script:PricingConfig     = $cfg
    $script:PricingConfigPath = $path
    return $cfg
}

function Resolve-AIModelForTier {
    <#
    .SYNOPSIS
        Map a task tier to a model identifier (6.5-R2, 6.5-R11).
    .DESCRIPTION
        An explicit -Model override always wins. Returns empty string for an
        unknown tier so the caller can refuse rather than guess.
    #>
    param($Pricing, [string]$TaskTier, [string]$ModelOverride = '')

    if ($ModelOverride) { return $ModelOverride }
    if ($null -eq $Pricing -or $null -eq $Pricing.tiers) { return '' }

    $names = @($Pricing.tiers.PSObject.Properties.Name)
    if ($names -notcontains $TaskTier) { return '' }
    return [string]$Pricing.tiers.$TaskTier
}

function Get-AIModelRate {
    <#
    .SYNOPSIS
        Return input/output price per MTok for a model.
    .DESCRIPTION
        An unrecognised model is priced using estimation.unknownModelFallback,
        which the pricing config's own audit test requires to be the most
        expensive current model. A typo in configuration must never estimate
        lower than a correct value, or it would silently disable the ceiling.
    #>
    param($Pricing, [string]$Model)

    $result = [PSCustomObject]@{
        Model          = $Model
        InputPerMTok   = 0.0
        OutputPerMTok  = 0.0
        WasFallback    = $false
        Found          = $false
    }
    if ($null -eq $Pricing -or $null -eq $Pricing.models) { return $result }

    $known = @($Pricing.models.PSObject.Properties.Name)
    $lookup = $Model

    if ($known -notcontains $lookup) {
        $fallback = ''
        if ($Pricing.estimation) { $fallback = [string]$Pricing.estimation.unknownModelFallback }
        if ($fallback -and $known -contains $fallback) {
            $lookup = $fallback
            $result.WasFallback = $true
            # Report the model whose rates were actually applied. This value
            # reaches the audit record in PR3; naming the requested model here
            # would make the record misstate what was priced.
            $result.Model = $fallback
        } else {
            return $result
        }
    }

    $m = $Pricing.models.$lookup
    $result.InputPerMTok  = [double]$m.inputPerMTok
    $result.OutputPerMTok = [double]$m.outputPerMTok
    $result.Found = $true
    return $result
}

# ------------------------------------------------------------------------------
# Cost estimation (6.5-R3, design 6.5.4.4)
# ------------------------------------------------------------------------------

function Measure-AIEstimatedTokens {
    <#
    .SYNOPSIS
        Estimate token count from character count, rounding UP.
    .DESCRIPTION
        charsPerTokenConservative is deliberately below real-prose ratios so
        this over-estimates. Ceiling rounding compounds that deliberately: a
        fractional token that rounds down is a token the ceiling did not
        account for.
    #>
    param($Pricing, [int]$CharCount)

    if ($CharCount -le 0) { return 0 }
    $ratio = 3.5
    if ($Pricing -and $Pricing.estimation -and $Pricing.estimation.charsPerTokenConservative) {
        $ratio = [double]$Pricing.estimation.charsPerTokenConservative
    }
    if ($ratio -le 0) { $ratio = 3.5 }
    return [int][Math]::Ceiling($CharCount / $ratio)
}

function Get-AICostEstimate {
    <#
    .SYNOPSIS
        Estimate the USD cost of a call before making it.
    .DESCRIPTION
        Implements design 6.5.4.4:
            input_cost  = (input_tokens  / 1e6) * inputPerMTok
            output_est  = input_tokens * OutputMultiplier
            output_cost = (output_est   / 1e6) * outputPerMTok
            total       = input_cost + output_cost
    #>
    param(
        $Pricing,
        [string]$Model,
        [int]$InputTokens,
        [double]$OutputMultiplier
    )

    $rate = Get-AIModelRate -Pricing $Pricing -Model $Model
    $estimatedOutputTokens = [int][Math]::Ceiling($InputTokens * $OutputMultiplier)

    $inputCost  = ($InputTokens / 1000000.0) * $rate.InputPerMTok
    $outputCost = ($estimatedOutputTokens / 1000000.0) * $rate.OutputPerMTok

    return [PSCustomObject]@{
        InputTokens           = $InputTokens
        EstimatedOutputTokens = $estimatedOutputTokens
        InputCostUSD          = $inputCost
        OutputCostUSD         = $outputCost
        TotalCostUSD          = $inputCost + $outputCost
        RateFound             = $rate.Found
        RateWasFallback       = $rate.WasFallback
        PricedAsModel         = $rate.Model
    }
}

function Get-AIActualCost {
    <#
    .SYNOPSIS
        Compute actual USD cost from the usage block the API returns.
    #>
    param($Pricing, [string]$Model, [int]$InputTokens, [int]$OutputTokens)

    $rate = Get-AIModelRate -Pricing $Pricing -Model $Model
    $inputCost  = ($InputTokens  / 1000000.0) * $rate.InputPerMTok
    $outputCost = ($OutputTokens / 1000000.0) * $rate.OutputPerMTok
    return $inputCost + $outputCost
}

# ------------------------------------------------------------------------------
# Retry policy (6.5-R9, design 6.5.4.8)
# ------------------------------------------------------------------------------

function Test-AITransientFailure {
    <#
    .SYNOPSIS
        Decide whether a failure is worth retrying.
    .DESCRIPTION
        Transient: network error, timeout, 429, any 5xx.
        Non-transient: 400, 401, 403, 404 and malformed responses -- retrying
        an unauthorized or malformed request wastes the operator's time and,
        for 429-adjacent quota errors, can make matters worse.
    #>
    param([int]$StatusCode = 0, [string]$Message = '')

    if ($StatusCode -eq 429) { return $true }
    if ($StatusCode -ge 500 -and $StatusCode -le 599) { return $true }
    if ($StatusCode -ge 400 -and $StatusCode -le 499) { return $false }

    # No status code: network-level failure. Treat recognised transport
    # symptoms as transient, anything else as non-transient.
    if ($StatusCode -eq 0 -and $Message) {
        if ($Message -match '(?i)timed?\s*out|timeout|temporarily|unreachable|connection|network|socket|dns') {
            return $true
        }
    }
    return $false
}

function Get-AIRetryDelaySeconds {
    <#
    .SYNOPSIS
        Backoff delay before the given attempt number (1-based).
    .DESCRIPTION
        Attempt 1 immediate, then 1s, 2s, 4s. Worst case 7s of waiting across
        4 attempts, per design 6.5.4.8.
    #>
    param([int]$AttemptNumber)
    if ($AttemptNumber -le 1) { return 0 }
    return [int][Math]::Pow(2, $AttemptNumber - 2)
}

# ------------------------------------------------------------------------------
# API key discovery (6.5-R12: never returned, never logged)
# ------------------------------------------------------------------------------

function Get-AIApiKey {
    <#
    .SYNOPSIS
        Locate the Anthropic API key. Environment first, then technician.json.
    .DESCRIPTION
        Alias list matches the discovery already implemented in
        Invoke-ComplianceDiff.ps1 so a working field configuration keeps
        working. The key is never placed in a result object or log record.
    #>
    param([string]$ConfigDir = '')

    if ($env:ANTHROPIC_API_KEY) { return $env:ANTHROPIC_API_KEY }

    $dir = Resolve-AIConfigRoot -ConfigDir $ConfigDir
    if (-not $dir) { return '' }
    $path = Join-Path $dir 'technician.json'
    if (-not (Test-Path -LiteralPath $path)) { return '' }

    try {
        $cfg = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        return ''
    }

    $aliases = @('AnthropicApiKey','AnthropicKey','ApiKey','AiKey','ClaudeApiKey','ClaudeKey','Key')
    $names = @($cfg.PSObject.Properties.Name)
    foreach ($a in $aliases) {
        if ($names -contains $a) {
            $v = [string]$cfg.$a
            if ($v) { return $v }
        }
    }
    return ''
}

# ------------------------------------------------------------------------------
# Transport boundary -- the single place this module touches the network.
# Tests mock this function; everything above and below it is verifiable offline.
# ------------------------------------------------------------------------------

function Invoke-AIHttpRequest {
    <#
    .SYNOPSIS
        Issue one POST to the Anthropic messages endpoint.
    .OUTPUTS
        PSCustomObject with Success, StatusCode, Body (parsed), ErrorMessage.
        Never throws: transport failures are reported, not raised.
    #>
    [CmdletBinding()]
    param(
        [string]$ApiKey,
        [string]$Model,
        [string]$SystemPrompt,
        [string]$Prompt,
        [int]$MaxTokens = 4096,
        [int]$TimeoutSec = 100
    )

    $headers = @{
        'x-api-key'         = $ApiKey
        'anthropic-version' = $script:ApiVersion
        'content-type'      = 'application/json'
    }

    $payload = @{
        model      = $Model
        max_tokens = $MaxTokens
        messages   = @(@{ role = 'user'; content = $Prompt })
    }
    if ($SystemPrompt) { $payload['system'] = $SystemPrompt }

    try {
        $json = $payload | ConvertTo-Json -Depth 6
        $resp = Invoke-RestMethod -Uri $script:ApiEndpoint -Method POST `
                    -Headers $headers -Body $json -TimeoutSec $TimeoutSec `
                    -ErrorAction Stop
        return [PSCustomObject]@{
            Success      = $true
            StatusCode   = 200
            Body         = $resp
            ErrorMessage = ''
        }
    } catch {
        $status = 0
        try {
            if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
                $status = [int]$_.Exception.Response.StatusCode
            }
        } catch { $status = 0 }

        return [PSCustomObject]@{
            Success      = $false
            StatusCode   = $status
            Body         = $null
            # Deliberately does not include request headers: the API key must
            # never reach an error string (6.5-R12).
            ErrorMessage = $_.Exception.Message
        }
    }
}

function ConvertFrom-AIResponseBody {
    <#
    .SYNOPSIS
        Extract text and token usage from an Anthropic messages response.
    .OUTPUTS
        PSCustomObject with Text, InputTokens, OutputTokens, Ok.
    #>
    param($Body)

    $out = [PSCustomObject]@{
        Text         = ''
        InputTokens  = 0
        OutputTokens = 0
        Ok           = $false
    }
    if ($null -eq $Body) { return $out }

    try {
        $names = @($Body.PSObject.Properties.Name)
        if ($names -contains 'content' -and $Body.content) {
            $parts = @($Body.content | Where-Object { $_.type -eq 'text' } | ForEach-Object { [string]$_.text })
            $out.Text = ($parts -join "`n")
        }
        if ($names -contains 'usage' -and $Body.usage) {
            $u = @($Body.usage.PSObject.Properties.Name)
            if ($u -contains 'input_tokens')  { $out.InputTokens  = [int]$Body.usage.input_tokens }
            if ($u -contains 'output_tokens') { $out.OutputTokens = [int]$Body.usage.output_tokens }
        }
        $out.Ok = [bool]$out.Text
    } catch {
        $out.Ok = $false
    }
    return $out
}

# ------------------------------------------------------------------------------
# Result construction
# ------------------------------------------------------------------------------

function New-AIResult {
    <#
    .SYNOPSIS
        Build the result object. Shape is fixed from PR2 so later PRs populate
        fields rather than changing the contract under call sites.
    #>
    param(
        [bool]$Success = $false,
        [string]$Response = '',
        [string]$FailureReason = '',
        [string]$Model = '',
        [string]$TaskTier = '',
        [double]$CostUSD = 0.0,
        [double]$EstimatedCostUSD = 0.0,
        [int]$InputTokens = 0,
        [int]$OutputTokens = 0,
        [int]$DurationMs = 0,
        [int]$RetryCount = 0
    )
    return [PSCustomObject]@{
        Success           = $Success
        Response          = $Response
        FailureReason     = $FailureReason
        Model             = $Model
        TaskTier          = $TaskTier
        CostUSD           = $CostUSD
        EstimatedCostUSD  = $EstimatedCostUSD
        InputTokens       = $InputTokens
        OutputTokens      = $OutputTokens
        DurationMs        = $DurationMs
        RetryCount        = $RetryCount
        SessionCostUSD    = $script:SessionCostUSD
        # Populated by later PRs; present now so the contract is stable.
        Severity          = $null
        NeedsHumanReview  = $null
        PlaybookRef       = $null
        PlaybookValid     = $null
        AuditRecordPath   = $null
        AuditRecordSha256 = $null
    }
}

# ==============================================================================
# PUBLIC API
# ==============================================================================

function Invoke-FieldOpsAICall {
    <#
    .SYNOPSIS
        Make a cost-governed Anthropic API call.
    .DESCRIPTION
        Never throws. Always returns a result object; branch on .Success and
        read .FailureReason. See module header for the failure-reason contract.
    .PARAMETER CaptureFullTranscript
        Opt in to retaining full prompt and response text in the result.
        Named in place of the design document's -Verbose to avoid colliding
        with the PowerShell common parameter; see module header.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Prompt,
        [string]$SystemPrompt = '',
        [string]$CallingContext = '',
        [ValidateSet('Classification','Narration','Reasoning')]
        [string]$TaskTier = 'Narration',
        [double]$MaxCostUSD = 0.0,
        [double]$OutputMultiplier = 0.0,
        [string]$Model = '',
        [double]$SessionCeilingUSD = 0.0,
        [int]$MaxTokens = 4096,
        [switch]$ExpectPlaybookReference,
        [switch]$CaptureFullTranscript,
        [string]$ConfigDir = ''
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    if ($MaxCostUSD -le 0)        { $MaxCostUSD        = $script:DefaultInvocationCeilingUSD }
    if ($SessionCeilingUSD -le 0) { $SessionCeilingUSD = $script:DefaultSessionCeilingUSD }

    # --- pricing: fail closed if unavailable -------------------------------
    $pricing = Import-AIPricingConfig -ConfigDir $ConfigDir
    if ($null -eq $pricing) {
        return New-AIResult -FailureReason $script:FailureReasons.PricingUnavailable `
                            -TaskTier $TaskTier -DurationMs $sw.ElapsedMilliseconds
    }

    if ($OutputMultiplier -le 0) {
        $OutputMultiplier = 2.0
        if ($pricing.estimation -and $pricing.estimation.defaultOutputMultiplier) {
            $OutputMultiplier = [double]$pricing.estimation.defaultOutputMultiplier
        }
    }

    # --- model resolution ---------------------------------------------------
    $resolvedModel = Resolve-AIModelForTier -Pricing $pricing -TaskTier $TaskTier -ModelOverride $Model
    if (-not $resolvedModel) {
        return New-AIResult -FailureReason $script:FailureReasons.UnknownTier `
                            -TaskTier $TaskTier -DurationMs $sw.ElapsedMilliseconds
    }

    # --- estimate BEFORE spending anything ----------------------------------
    $charCount = $Prompt.Length + $SystemPrompt.Length
    $inputTokens = Measure-AIEstimatedTokens -Pricing $pricing -CharCount $charCount
    $estimate = Get-AICostEstimate -Pricing $pricing -Model $resolvedModel `
                    -InputTokens $inputTokens -OutputMultiplier $OutputMultiplier

    if ($estimate.TotalCostUSD -gt $MaxCostUSD) {
        return New-AIResult -FailureReason $script:FailureReasons.InvocationCeiling `
                    -Model $resolvedModel -TaskTier $TaskTier `
                    -EstimatedCostUSD $estimate.TotalCostUSD `
                    -InputTokens $inputTokens -DurationMs $sw.ElapsedMilliseconds
    }

    if (($script:SessionCostUSD + $estimate.TotalCostUSD) -gt $SessionCeilingUSD) {
        return New-AIResult -FailureReason $script:FailureReasons.SessionCeiling `
                    -Model $resolvedModel -TaskTier $TaskTier `
                    -EstimatedCostUSD $estimate.TotalCostUSD `
                    -InputTokens $inputTokens -DurationMs $sw.ElapsedMilliseconds
    }

    # --- key ----------------------------------------------------------------
    $apiKey = Get-AIApiKey -ConfigDir $ConfigDir
    if (-not $apiKey) {
        return New-AIResult -FailureReason $script:FailureReasons.NoApiKey `
                    -Model $resolvedModel -TaskTier $TaskTier `
                    -EstimatedCostUSD $estimate.TotalCostUSD `
                    -InputTokens $inputTokens -DurationMs $sw.ElapsedMilliseconds
    }

    # --- call, with retry ----------------------------------------------------
    $attempt = 0
    $retryCount = 0
    $lastReason = $script:FailureReasons.NonTransient

    while ($attempt -lt $script:MaxAttempts) {
        $attempt++
        if ($attempt -gt 1) {
            $delay = Get-AIRetryDelaySeconds -AttemptNumber $attempt
            if ($delay -gt 0) { Start-Sleep -Seconds $delay }
            $retryCount++
        }

        $http = Invoke-AIHttpRequest -ApiKey $apiKey -Model $resolvedModel `
                    -SystemPrompt $SystemPrompt -Prompt $Prompt -MaxTokens $MaxTokens

        if ($http.Success) {
            $parsed = ConvertFrom-AIResponseBody -Body $http.Body
            if (-not $parsed.Ok) {
                # Malformed success response is not worth retrying.
                return New-AIResult -FailureReason $script:FailureReasons.MalformedResponse `
                            -Model $resolvedModel -TaskTier $TaskTier `
                            -EstimatedCostUSD $estimate.TotalCostUSD `
                            -InputTokens $inputTokens -RetryCount $retryCount `
                            -DurationMs $sw.ElapsedMilliseconds
            }

            $actualCost = Get-AIActualCost -Pricing $pricing -Model $resolvedModel `
                            -InputTokens $parsed.InputTokens -OutputTokens $parsed.OutputTokens
            $script:SessionCostUSD   = $script:SessionCostUSD + $actualCost
            $script:SessionCallCount = $script:SessionCallCount + 1

            $responseText = $parsed.Text
            if (-not $CaptureFullTranscript -and $responseText.Length -gt 100000) {
                $responseText = $responseText.Substring(0, 100000)
            }

            return New-AIResult -Success $true -Response $responseText `
                        -Model $resolvedModel -TaskTier $TaskTier `
                        -CostUSD $actualCost -EstimatedCostUSD $estimate.TotalCostUSD `
                        -InputTokens $parsed.InputTokens -OutputTokens $parsed.OutputTokens `
                        -RetryCount $retryCount -DurationMs $sw.ElapsedMilliseconds
        }

        $transient = Test-AITransientFailure -StatusCode $http.StatusCode -Message $http.ErrorMessage
        if (-not $transient) {
            return New-AIResult -FailureReason $script:FailureReasons.NonTransient `
                        -Model $resolvedModel -TaskTier $TaskTier `
                        -EstimatedCostUSD $estimate.TotalCostUSD `
                        -InputTokens $inputTokens -RetryCount $retryCount `
                        -DurationMs $sw.ElapsedMilliseconds
        }
        $lastReason = $script:FailureReasons.RetriesExhausted
    }

    return New-AIResult -FailureReason $lastReason `
                -Model $resolvedModel -TaskTier $TaskTier `
                -EstimatedCostUSD $estimate.TotalCostUSD `
                -InputTokens $inputTokens -RetryCount $retryCount `
                -DurationMs $sw.ElapsedMilliseconds
}

function Get-FieldOpsAISessionCost {
    <#
    .SYNOPSIS
        Total actual USD spent by this session, and the call count.
    #>
    [CmdletBinding()]
    param()
    return [PSCustomObject]@{
        SessionCostUSD = $script:SessionCostUSD
        CallCount      = $script:SessionCallCount
    }
}

function Reset-FieldOpsAISession {
    <#
    .SYNOPSIS
        Zero the session cost accumulator.
    #>
    [CmdletBinding()]
    param()
    $script:SessionCostUSD   = 0.0
    $script:SessionCallCount = 0
}

function Test-FieldOpsAIAvailability {
    <#
    .SYNOPSIS
        Report whether an AI call could be attempted, without making one.
    .DESCRIPTION
        Used by call sites to choose the fallback path up front rather than
        paying a failed round trip to discover it.
    #>
    [CmdletBinding()]
    param([string]$ConfigDir = '')

    $pricing = Import-AIPricingConfig -ConfigDir $ConfigDir
    $key     = Get-AIApiKey -ConfigDir $ConfigDir

    $reasons = @()
    if ($null -eq $pricing) { $reasons += $script:FailureReasons.PricingUnavailable }
    if (-not $key)          { $reasons += $script:FailureReasons.NoApiKey }

    return [PSCustomObject]@{
        Available     = ($reasons.Count -eq 0)
        # Boolean only. The key itself is never surfaced (6.5-R12).
        HasApiKey     = [bool]$key
        HasPricing    = ($null -ne $pricing)
        Reasons       = $reasons
    }
}


# ==============================================================================
# ==============================================================================
# SEVERITY CLASSIFIER (6.5-R7, D3, design 6.5.4.6)
# ==============================================================================

$script:SeverityConfig = $null
$script:SeverityConfigPath = ''

function Import-AISeverityConfig {
    <#
    .SYNOPSIS
        Load and cache CONFIG/AISeverityKeywords.json. $null on failure.
    #>
    param([string]$ConfigDir = '', [switch]$Force)

    $dir = Resolve-AIConfigRoot -ConfigDir $ConfigDir
    if (-not $dir) { return $null }
    $path = Join-Path $dir 'AISeverityKeywords.json'

    if ($script:SeverityConfig -and -not $Force -and $script:SeverityConfigPath -eq $path) {
        return $script:SeverityConfig
    }
    if ($script:SeverityConfigPath -ne $path) { $script:SeverityConfig = $null }

    if (-not (Test-Path -LiteralPath $path)) { $script:SeverityConfigPath = $path; return $null }
    try {
        $cfg = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch { return $null }

    $script:SeverityConfig = $cfg
    $script:SeverityConfigPath = $path
    return $cfg
}

function Get-AIStructuralSeverity {
    <#
    .SYNOPSIS
        Tier 2. Return the level from an explicit "Severity: <LEVEL>" line, or ''.
    .DESCRIPTION
        The model naming its own severity is the strongest signal, so it
        overrides keyword matching. Only the enum values are accepted; a free
        text severity line is ignored rather than guessed at.
    #>
    param([string]$Text)
    if (-not $Text) { return '' }
    $m = [regex]::Match($Text, '(?im)^\s*severity\s*[:=]\s*(INFORMATIONAL|ADVISORY|ACTION_REQUIRED|CRITICAL)\b')
    if ($m.Success) { return $m.Groups[1].Value.ToUpper() }
    return ''
}

function Get-AISeverityClassification {
    <#
    .SYNOPSIS
        Classify AI response text into the audit severity enum.
    .OUTPUTS
        PSCustomObject: Severity, Method (structural|keyword|default),
        NeedsHumanReview, MatchedPatternCount.
    .DESCRIPTION
        Tier 2 structural override, then Tier 1 keyword (highest matched level
        wins), then ADVISORY default. needs_human_review is set for a
        low-confidence single match, and by the structural distress guard when
        a distress marker is present but the classified level is below
        ACTION_REQUIRED.
    #>
    param([string]$Text, [string]$ConfigDir = '')

    $result = [PSCustomObject]@{
        Severity            = 'ADVISORY'
        Method              = 'default'
        NeedsHumanReview    = $false
        MatchedPatternCount = 0
    }
    if ([string]::IsNullOrWhiteSpace($Text)) {
        # Nothing to classify: default, and flag for a human since we cannot
        # actually assess an empty response.
        $result.NeedsHumanReview = $true
        return $result
    }

    # Tier 2: structural override.
    $structural = Get-AIStructuralSeverity -Text $Text
    if ($structural) {
        $result.Severity = $structural
        $result.Method   = 'structural'
        return $result
    }

    $cfg = Import-AISeverityConfig -ConfigDir $ConfigDir
    if ($null -eq $cfg) {
        # No keyword config: cannot classify, so default and flag. Never guess.
        $result.NeedsHumanReview = $true
        return $result
    }

    # Tier 1: keyword. Highest-ranked matching level wins.
    $rank = @{}
    foreach ($p in $cfg.levelRank.PSObject.Properties) { $rank[$p.Name] = [int]$p.Value }

    $bestLevel = ''
    $bestRank  = -1
    $totalMatches = 0

    foreach ($levelProp in $cfg.keywords.PSObject.Properties) {
        $level = $levelProp.Name
        $patterns = @($levelProp.Value)
        $levelMatches = 0
        foreach ($pat in $patterns) {
            if ([string]::IsNullOrEmpty($pat)) { continue }
            if ([regex]::IsMatch($Text, [regex]::Escape($pat), 'IgnoreCase')) {
                $levelMatches++
            }
        }
        if ($levelMatches -gt 0) {
            $totalMatches += $levelMatches
            if ($rank[$level] -gt $bestRank) {
                $bestRank  = $rank[$level]
                $bestLevel = $level
            }
        }
    }

    if ($bestLevel) {
        $result.Severity = $bestLevel
        $result.Method   = 'keyword'
        $result.MatchedPatternCount = $totalMatches
        # Low-confidence: a single pattern matched, nothing else corroborates.
        if ($totalMatches -le 1) { $result.NeedsHumanReview = $true }
    } else {
        # No keyword matched anywhere: safe middle, and flag, because "no
        # vocabulary we recognise" is not the same as "benign".
        $result.Severity = $cfg.default
        $result.Method   = 'default'
        $result.NeedsHumanReview = $true
    }

    # Structural distress guard: a marker of severity is present, but we did
    # not classify at ACTION_REQUIRED or above. Do not trust the lower label.
    $distress = $false
    if ($cfg.structuralDistressMarkers -and $cfg.structuralDistressMarkers.patterns) {
        foreach ($dp in @($cfg.structuralDistressMarkers.patterns)) {
            if ([string]::IsNullOrEmpty($dp)) { continue }
            if ([regex]::IsMatch($Text, $dp, 'IgnoreCase')) { $distress = $true; break }
        }
    }
    if ($distress -and $rank[$result.Severity] -lt $rank['ACTION_REQUIRED']) {
        $result.NeedsHumanReview = $true
    }

    return $result
}
# AUDIT LOGGING (6.5-R6, D2, schema 1.1)
# ==============================================================================
#
# HASHING IS SPECIFIED PRECISELY, ON PURPOSE
#
#   Every hash below is SHA-256 over the UTF-8 bytes of the string, WITHOUT a
#   byte order mark, rendered lowercase hex. That is stated in the schema and
#   reproducible by anyone holding the original text. A hash whose input is
#   not pinned down cannot be checked by an auditor, and an integrity claim
#   nobody can verify is worse than none. This project has already shipped one
#   such hash.
#
# AUDIT FAILURE DOES NOT FAIL THE CALL
#
#   The record is written after the API responds, because it carries token
#   counts and actual cost. By then the call has happened and been billed.
#   A write failure warns and sets AuditRecordPath to null so the caller can
#   detect the gap; it never throws and never discards a paid-for response.

function Get-AISha256Hex {
    <#
    .SYNOPSIS
        SHA-256 of a string, UTF-8 without BOM, lowercase hex. $null for empty.
    #>
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $null }
    $enc = New-Object System.Text.UTF8Encoding($false)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash($enc.GetBytes($Text))
        return (([BitConverter]::ToString($bytes)) -replace '-','').ToLower()
    } finally {
        $sha.Dispose()
    }
}

function Get-AITechnicianId {
    <#
    .SYNOPSIS
        Pseudonymous technician id: truncated SHA-256 of the technician name.
    .DESCRIPTION
        Pseudonymity, not anonymity. A short name space is brute-forceable by
        anyone holding a candidate list; this keeps names out of a shared log
        but must not be described to customers as anonymisation.
    #>
    param([string]$ConfigDir = '')
    $name = ''
    $dir = Resolve-AIConfigRoot -ConfigDir $ConfigDir
    if ($dir) {
        $p = Join-Path $dir 'technician.json'
        if (Test-Path -LiteralPath $p) {
            try {
                $cfg = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
                foreach ($a in @('TechnicianName','Technician','TechName','Name','FullName')) {
                    if (@($cfg.PSObject.Properties.Name) -contains $a -and $cfg.$a) {
                        $name = [string]$cfg.$a; break
                    }
                }
            } catch { $name = '' }
        }
    }
    if (-not $name) { $name = $env:USERNAME }
    if (-not $name) { return 'unknown' }
    $full = Get-AISha256Hex -Text $name
    if (-not $full) { return 'unknown' }
    return $full.Substring(0, 12)
}

function Resolve-AIAuditLogPath {
    <#
    .SYNOPSIS
        Absolute path to LOGS/ai-audit.jsonl, creating LOGS if needed.
    #>
    param([string]$LogsDir = '')
    $dir = $LogsDir
    if (-not $dir) {
        if (-not $PSScriptRoot) { return '' }
        $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $dir = Join-Path $repoRoot 'LOGS'
    }
    if (-not (Test-Path -LiteralPath $dir)) {
        try { New-Item -ItemType Directory -Path $dir -Force | Out-Null } catch { return '' }
    }
    return (Join-Path $dir 'ai-audit.jsonl')
}

function New-AIAuditRecord {
    <#
    .SYNOPSIS
        Build a schema-1.1-conformant record from a call result.
    #>
    param(
        $Result, [string]$Prompt, [string]$SystemPrompt,
        [string]$CallingContext, [bool]$ModelOverride, [string]$ConfigDir = ''
    )

    $variance = 0.0
    if ($null -ne $Result.CostUSD -and $null -ne $Result.EstimatedCostUSD) {
        # Positive means the estimate came in low: the ceiling was consulted
        # against a smaller figure than reality. That is the direction to watch.
        $variance = [double]$Result.CostUSD - [double]$Result.EstimatedCostUSD
    }

    $severity = 'UNCLASSIFIED'
    $severityMethod = 'unclassified'
    if ($Result.Severity) { $severity = [string]$Result.Severity; $severityMethod = 'keyword' }

    $failureReason = $null
    if ($Result.FailureReason) { $failureReason = [string]$Result.FailureReason }

    $needsReview = $false
    if ($null -ne $Result.NeedsHumanReview) { $needsReview = [bool]$Result.NeedsHumanReview }

    return [ordered]@{
        schemaVersion      = '1.1'
        ts                 = (Get-Date).ToString('o')
        ctx                = $CallingContext
        tier               = [string]$Result.TaskTier
        model              = [string]$Result.Model
        model_override     = $ModelOverride
        in_tok             = [int]$Result.InputTokens
        out_tok            = [int]$Result.OutputTokens
        est_cost_usd       = [double]$Result.EstimatedCostUSD
        cost_usd           = [double]$Result.CostUSD
        cost_variance      = $variance
        severity           = $severity
        severity_method    = $severityMethod
        playbook_ref       = $Result.PlaybookRef
        playbook_valid     = $Result.PlaybookValid
        prompt_sha256      = (Get-AISha256Hex -Text $Prompt)
        system_sha256      = (Get-AISha256Hex -Text $SystemPrompt)
        response_sha256    = (Get-AISha256Hex -Text $Result.Response)
        tech               = (Get-AITechnicianId -ConfigDir $ConfigDir)
        duration_ms        = [int]$Result.DurationMs
        retries            = [int]$Result.RetryCount
        success            = [bool]$Result.Success
        failure_reason     = $failureReason
        needs_human_review = $needsReview
    }
}

function Write-AIAuditRecord {
    <#
    .SYNOPSIS
        Append one JSON Lines record. Never throws. Returns path or $null.
    #>
    param($Record, [string]$LogsDir = '')
    try {
        $path = Resolve-AIAuditLogPath -LogsDir $LogsDir
        if (-not $path) { return $null }
        # JSON Lines requires exactly one record per physical line.
        $json = ($Record | ConvertTo-Json -Depth 5 -Compress)
        if ($json -match "[`r`n]") { $json = ($json -replace "[`r`n]", ' ') }
        $enc = New-Object System.Text.UTF8Encoding($false)
        $sw = New-Object System.IO.StreamWriter($path, $true, $enc)
        try { $sw.WriteLine($json) } finally { $sw.Dispose() }
        return $path
    } catch {
        Write-Warning "AI audit record could not be written: $($_.Exception.Message)"
        return $null
    }
}

function Get-FieldOpsAIAuditLogPath {
    <#
    .SYNOPSIS
        Path of the audit log, for operators and for 6.3 fleet aggregation.
    #>
    [CmdletBinding()]
    param([string]$LogsDir = '')
    return Resolve-AIAuditLogPath -LogsDir $LogsDir
}

# ==============================================================================
# PUBLIC ENTRY POINT
# ==============================================================================

function Invoke-FieldOpsAI {
    <#
    .SYNOPSIS
        Make a cost-governed Anthropic API call and record it (6.5-R1, R6).
    .DESCRIPTION
        Thin wrapper over Invoke-FieldOpsAICall. Every outcome passes through
        this single exit, so no return path can skip the audit record. Never
        throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Prompt,
        [string]$SystemPrompt = '',
        [string]$CallingContext = '',
        [ValidateSet('Classification','Narration','Reasoning')]
        [string]$TaskTier = 'Narration',
        [double]$MaxCostUSD = 0.0,
        [double]$OutputMultiplier = 0.0,
        [string]$Model = '',
        [double]$SessionCeilingUSD = 0.0,
        [int]$MaxTokens = 4096,
        [switch]$ExpectPlaybookReference,
        [switch]$CaptureFullTranscript,
        [string]$ConfigDir = '',
        [string]$LogsDir = '',
        [switch]$NoAudit
    )

    $result = Invoke-FieldOpsAICall `
                -Prompt $Prompt -SystemPrompt $SystemPrompt `
                -CallingContext $CallingContext -TaskTier $TaskTier `
                -MaxCostUSD $MaxCostUSD -OutputMultiplier $OutputMultiplier `
                -Model $Model -SessionCeilingUSD $SessionCeilingUSD `
                -MaxTokens $MaxTokens `
                -ExpectPlaybookReference:$ExpectPlaybookReference `
                -CaptureFullTranscript:$CaptureFullTranscript `
                -ConfigDir $ConfigDir

    if (-not $NoAudit) {
        # Classify the response severity before building the audit record so
        # the severity, severity_method and needs_human_review fields reflect
        # what the model actually returned (6.5-R7).
        if ($result.Success -and $result.Response) {
            $sev = Get-AISeverityClassification -Text $result.Response -ConfigDir $ConfigDir
            $result.Severity         = $sev.Severity
            $result.NeedsHumanReview = $sev.NeedsHumanReview
        }
        $record = New-AIAuditRecord -Result $result -Prompt $Prompt `
                    -SystemPrompt $SystemPrompt -CallingContext $CallingContext `
                    -ModelOverride ([bool]$Model) -ConfigDir $ConfigDir
        $written = Write-AIAuditRecord -Record $record -LogsDir $LogsDir

        $result.AuditRecordPath = $written
        if ($written) {
            $result.AuditRecordSha256 = Get-AISha256Hex -Text ($record | ConvertTo-Json -Depth 5 -Compress)
        }
    }

    return $result
}
Export-ModuleMember -Function Invoke-FieldOpsAI, Get-FieldOpsAISessionCost,
                              Reset-FieldOpsAISession, Test-FieldOpsAIAvailability,
                              Get-FieldOpsAIAuditLogPath, Get-AISeverityClassification
