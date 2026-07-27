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

FAILURE REASON vs FAILURE DETAIL

    .FailureReason is a closed vocabulary (see $script:FailureReasons) and is
    the ONLY field a caller may branch on. It is deliberately coarse.

    .FailureDetail is the provider's own explanation, read off the non-2xx
    response body and redacted -- "your credit balance is too low", "invalid
    x-api-key". .HttpStatus is the status code, or 0 when the failure never
    reached the network (ceiling refusal, missing key, unknown tier).

    Both exist so a call site can tell an operator what to actually DO. Before
    they existed, PowerShell 5.1's generic WebException message ("The remote
    server returned an error: (400) Bad Request.") was all that survived the
    transport, and Invoke-ComplianceDiff kept its own body parser to recover
    the reason -- which is precisely the duplication the 6.5 reroute removes.
    Neither field is a contract for branching: the provider may reword them at
    any time. Display them; do not match on them.

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
    ModelUnavailable      = 'ModelUnavailable'
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

# Config filenames tried in order of preference. This list, its order, and the
# recursive alias search below deliberately mirror Invoke-ComplianceDiff.ps1:
# before the 6.5 reroute the two resolved keys independently, and a key that
# lived anywhere but a top-level property of technician.json was found by the
# script and missed by this module. The banner would then report AI as enabled
# while every call returned NoApiKey -- a silent downgrade to local rules.
# One resolver, one answer.
function Get-AIConfigCandidatePath {
    param([string]$ConfigDir = '')
    $dir = Resolve-AIConfigRoot -ConfigDir $ConfigDir
    if (-not $dir) { return @() }
    return @(
        (Join-Path $dir 'technician.json'),
        (Join-Path $dir 'FieldOps.config.json'),
        (Join-Path $dir 'fieldops.json'),
        (Join-Path $dir 'config.json')
    )
}

function Find-AIConfigValue {
    <#
    .SYNOPSIS
        First non-empty scalar whose property name matches an alias, searched
        recursively. Handles flat ({"ApiKey":"..."}) and nested
        ({"anthropic":{"ApiKey":"..."}}) schemas alike.
    #>
    param($Obj, [string[]]$Aliases, [int]$Depth = 0)
    if ($null -eq $Obj -or $Depth -gt 5) { return $null }

    $props = @()
    if ($Obj -is [System.Collections.IDictionary]) {
        $props = @($Obj.Keys | ForEach-Object { [PSCustomObject]@{ Name = $_; Value = $Obj[$_] } })
    } elseif ($Obj.PSObject -and $Obj.PSObject.Properties) {
        $props = @($Obj.PSObject.Properties | ForEach-Object { [PSCustomObject]@{ Name = $_.Name; Value = $_.Value } })
    } else {
        return $null
    }

    # Scalars at this level first, so {"technician":{"name":"Bob"}} does not
    # match the outer key and return a stringified object.
    foreach ($p in $props) {
        foreach ($alias in $Aliases) {
            if ($p.Name -and ($p.Name -ieq $alias)) {
                $v = $p.Value
                if ($null -eq $v) { continue }
                if ($v -is [string]) {
                    if ($v.Trim() -ne '') { return $v.Trim() }
                } elseif ($v -is [ValueType]) {
                    $s = "$v".Trim()
                    if ($s -ne '') { return $s }
                }
            }
        }
    }

    foreach ($p in $props) {
        $v = $p.Value
        if ($null -eq $v) { continue }
        if ($v -is [string] -or $v -is [ValueType]) { continue }
        if ($v -is [System.Collections.IList]) { continue }
        $sub = Find-AIConfigValue -Obj $v -Aliases $Aliases -Depth ($Depth + 1)
        if ($null -ne $sub) { return $sub }
    }
    return $null
}

function Get-AIApiKey {
    <#
    .SYNOPSIS
        Locate the Anthropic API key. Environment first, then the config
        candidate files in preference order.
    .DESCRIPTION
        PRECEDENCE. ANTHROPIC_API_KEY wins over any config file. This is the
        standard Anthropic convention and lets a technician override a stale
        provisioned key without editing files on the USB. It is also a change
        from Invoke-ComplianceDiff's former config-first order, which only
        differs when both are set to DIFFERENT keys -- in that case the
        environment now wins.

        SEARCH. Each candidate file is tried in order; the first file that
        parses AND yields a key wins. A file that exists but has no key does
        not stop the search: a stub technician.json must not mask a real key
        in FieldOps.config.json.

        The key is never placed in a result object or log record (6.5-R12).
    #>
    param([string]$ConfigDir = '')

    if ($env:ANTHROPIC_API_KEY) { return $env:ANTHROPIC_API_KEY }

    $aliases = @('AnthropicApiKey','AnthropicKey','ApiKey','AiKey','ClaudeApiKey','ClaudeKey','Key')

    foreach ($path in (Get-AIConfigCandidatePath -ConfigDir $ConfigDir)) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        try {
            $cfg = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch {
            # Malformed file: skip it and keep looking rather than failing the
            # whole resolution on one bad JSON blob.
            continue
        }
        $v = Find-AIConfigValue -Obj $cfg -Aliases $aliases
        if ($v) { return [string]$v }
    }
    return ''
}

# ------------------------------------------------------------------------------
# Transport boundary -- the single place this module touches the network.
# Tests mock this function; everything above and below it is verifiable offline.
# ------------------------------------------------------------------------------

function Get-AIRedactedText {
    <#
    .SYNOPSIS
        Strip anything key-shaped from a string before it can be surfaced or
        logged (6.5-R12).
    .DESCRIPTION
        The API never echoes the key, so in practice this is belt-and-braces.
        It exists because FailureDetail is the first field on the result object
        sourced from an external response body rather than from our own code,
        and a redaction applied unconditionally cannot be forgotten at a call
        site later.
    #>
    param([string]$Text)
    if (-not $Text) { return '' }
    # Anthropic keys, and any sk-* bearer-style token, whatever the suffix.
    $out = $Text -replace 'sk-[A-Za-z0-9_\-]{8,}', 'sk-***REDACTED***'
    return $out
}

function ConvertFrom-AIErrorBody {
    <#
    .SYNOPSIS
        Turn a raw non-2xx response body into a redacted, bounded reason string.
    .DESCRIPTION
        Pure: string in, string out, no I/O. All the judgement lives here --
        which JSON shape carries the message, what to do when the body is not
        JSON, how much to keep, what to redact -- so it is fully unit-testable
        offline, in keeping with this module's transport-boundary posture. The
        stream plumbing in Read-AIErrorDetail stays deliberately trivial.

        Returns '' when nothing useful can be recovered.
    #>
    param([string]$Body)

    if (-not $Body) { return '' }

    try {
        $errObj = $Body | ConvertFrom-Json -ErrorAction Stop
        if ($errObj -and $errObj.error -and $errObj.error.message) {
            return (Get-AIRedactedText -Text ([string]$errObj.error.message))
        }
    } catch { }

    # Not JSON, or not the shape we expect: a bounded slice of the raw body
    # beats discarding the only evidence there is.
    $slice = $Body.Substring(0, [math]::Min($Body.Length, 300))
    return (Get-AIRedactedText -Text $slice.Trim())
}

function Read-AIErrorDetail {
    <#
    .SYNOPSIS
        Extract the human-readable reason from a non-2xx Anthropic response.
    .DESCRIPTION
        PowerShell 5.1's Invoke-RestMethod throws a WebException on non-2xx and
        its .Message is generic ("The remote server returned an error: (400)
        Bad Request."). The reason an operator can act on -- "your credit
        balance is too low", "invalid x-api-key" -- is in the response body,
        which is discarded unless it is read off the exception stream here.

        Stream plumbing only; the parsing rules are in ConvertFrom-AIErrorBody.
        Returns '' when no detail can be recovered; callers treat that as
        "status code only" rather than as an error.
    #>
    param($ErrorRecord)
    try {
        $webEx = $ErrorRecord.Exception
        while ($webEx -and -not ($webEx -is [System.Net.WebException])) {
            $webEx = $webEx.InnerException
        }
        if (-not ($webEx -and $webEx.Response)) { return '' }

        $stream = $webEx.Response.GetResponseStream()
        $reader = [System.IO.StreamReader]::new($stream)
        $body   = $reader.ReadToEnd()
        $reader.Close()
        $stream.Close()

        return (ConvertFrom-AIErrorBody -Body $body)
    } catch {
        return ''
    }
}

function Invoke-AIHttpRequest {
    <#
    .SYNOPSIS
        Issue one POST to the Anthropic messages endpoint.
    .OUTPUTS
        PSCustomObject with Success, StatusCode, Body (parsed), ErrorMessage,
        ErrorDetail. Never throws: transport failures are reported, not raised.
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
            ErrorDetail  = ''
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
            # The actionable reason, read off the response body. Redacted.
            ErrorDetail  = (Read-AIErrorDetail -ErrorRecord $_)
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
        [int]$RetryCount = 0,
        [int]$HttpStatus = 0,
        [string]$FailureDetail = ''
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
        # HttpStatus is 0 for failures that never reached the network (ceiling
        # refusal, no key, unknown tier). FailureDetail is the provider's own
        # words, redacted, and is '' whenever none could be recovered. Callers
        # must treat both as advisory: branch on FailureReason, display these.
        HttpStatus        = $HttpStatus
        FailureDetail     = (Get-AIRedactedText -Text $FailureDetail)
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

function Get-AIModelFallbackChain {
    <#
    .SYNOPSIS
        Ordered list of models to try: the requested model, then progressively
        cheaper current models (graceful capability degradation).
    .DESCRIPTION
        Fallback preserves capability as far as possible rather than minimising
        cost. The chain is the requested model, then the current models that are
        CHEAPER than it, in descending price order -- closest capability first.
        Price is the proxy for capability, and this matches the existing
        sonnet -> haiku fallback intent in Invoke-ComplianceDiff.

        A model is never upgraded on fallback: asking for Sonnet does not opt
        the operator into Opus pricing. Only status=current models are eligible,
        so a fallback never lands on a legacy model that is itself likely 404.
        Requested model always first, deduplicated.

        An explicit -Override replaces the derived tail entirely (requested
        model still first).
    #>
    param($Pricing, [string]$RequestedModel, [string[]]$Override = @())

    # Build the chain as an explicit array to avoid scalar+array fusion.
    $chain = New-Object System.Collections.Generic.List[string]
    if ($RequestedModel) { [void]$chain.Add($RequestedModel) }

    if ($Override -and $Override.Count -gt 0) {
        foreach ($m in $Override) {
            if ($m -and (-not $chain.Contains($m))) { [void]$chain.Add($m) }
        }
        return $chain.ToArray()
    }

    if ($Pricing -and $Pricing.models) {
        # Price of the requested model, so we only fall to CHEAPER ones.
        $requestedPrice = [double]::MaxValue
        if ($RequestedModel -and (@($Pricing.models.PSObject.Properties.Name) -contains $RequestedModel)) {
            $requestedPrice = [double]$Pricing.models.$RequestedModel.inputPerMTok
        }

        $candidates = @()
        foreach ($name in $Pricing.models.PSObject.Properties.Name) {
            $mdl = $Pricing.models.$name
            if ($mdl.status -ne 'current') { continue }
            $price = [double]$mdl.inputPerMTok
            # Strictly cheaper than the requested model: graceful degradation,
            # never an upgrade.
            if ($price -lt $requestedPrice) {
                $candidates += [PSCustomObject]@{ Name = $name; Price = $price }
            }
        }
        # Descending price = closest capability first.
        foreach ($c in ($candidates | Sort-Object Price -Descending)) {
            if (-not $chain.Contains($c.Name)) { [void]$chain.Add($c.Name) }
        }
    }

    return $chain.ToArray()
}
function Invoke-FieldOpsAICall {
    <#
    .SYNOPSIS
        Make a cost-governed Anthropic API call, with cross-model fallback.
    .DESCRIPTION
        Never throws. Always returns a result object; branch on .Success and
        read .FailureReason. See module header for the failure-reason contract.

        Tries the resolved model first. On a 404 (model unavailable on this
        plan) it advances to the next model in the fallback chain. On success,
        or on any non-404 failure, it returns immediately. Cost estimate and
        both ceilings are re-evaluated for each candidate, since candidates
        differ in price.
    .PARAMETER ModelFallbacks
        Optional explicit fallback chain, overriding the price-ordered default
        derived from the pricing config.
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
        [string[]]$ModelFallbacks = @(),
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

    # --- key (once; shared across all candidates) --------------------------
    $apiKey = Get-AIApiKey -ConfigDir $ConfigDir
    if (-not $apiKey) {
        return New-AIResult -FailureReason $script:FailureReasons.NoApiKey `
                    -Model $resolvedModel -TaskTier $TaskTier `
                    -DurationMs $sw.ElapsedMilliseconds
    }

    # --- fallback chain -----------------------------------------------------
    $chain = Get-AIModelFallbackChain -Pricing $pricing -RequestedModel $resolvedModel -Override $ModelFallbacks

    $charCount   = $Prompt.Length + $SystemPrompt.Length
    $inputTokens = Measure-AIEstimatedTokens -Pricing $pricing -CharCount $charCount

    # Remember the last "soft" refusal (ceiling) so that if EVERY model is
    # refused by its ceiling we report that rather than a model error.
    $lastResult = $null

    foreach ($candidate in $chain) {

        # --- estimate BEFORE spending anything, per candidate --------------
        $estimate = Get-AICostEstimate -Pricing $pricing -Model $candidate `
                        -InputTokens $inputTokens -OutputMultiplier $OutputMultiplier

        if ($estimate.TotalCostUSD -gt $MaxCostUSD) {
            # Too expensive on this model. A cheaper candidate may still pass,
            # so record and continue rather than returning.
            $lastResult = New-AIResult -FailureReason $script:FailureReasons.InvocationCeiling `
                        -Model $candidate -TaskTier $TaskTier `
                        -EstimatedCostUSD $estimate.TotalCostUSD `
                        -InputTokens $inputTokens -DurationMs $sw.ElapsedMilliseconds
            continue
        }

        if (($script:SessionCostUSD + $estimate.TotalCostUSD) -gt $SessionCeilingUSD) {
            $lastResult = New-AIResult -FailureReason $script:FailureReasons.SessionCeiling `
                        -Model $candidate -TaskTier $TaskTier `
                        -EstimatedCostUSD $estimate.TotalCostUSD `
                        -InputTokens $inputTokens -DurationMs $sw.ElapsedMilliseconds
            continue
        }

        # --- call, with retry, on THIS candidate ---------------------------
        $attempt = 0
        $retryCount = 0
        $lastReason = $script:FailureReasons.NonTransient
        $modelUnavailable = $false
        # Carried out of the retry loop so a retries-exhausted return can still
        # report what the provider actually said on the final attempt.
        $lastStatus = 0
        $lastDetail = ''

        while ($attempt -lt $script:MaxAttempts) {
            $attempt++
            if ($attempt -gt 1) {
                $delay = Get-AIRetryDelaySeconds -AttemptNumber $attempt
                if ($delay -gt 0) { Start-Sleep -Seconds $delay }
                $retryCount++
            }

            $http = Invoke-AIHttpRequest -ApiKey $apiKey -Model $candidate `
                        -SystemPrompt $SystemPrompt -Prompt $Prompt -MaxTokens $MaxTokens

            $lastStatus = $http.StatusCode
            $lastDetail = $http.ErrorDetail

            if ($http.Success) {
                $parsed = ConvertFrom-AIResponseBody -Body $http.Body
                if (-not $parsed.Ok) {
                    return New-AIResult -FailureReason $script:FailureReasons.MalformedResponse `
                                -Model $candidate -TaskTier $TaskTier `
                                -EstimatedCostUSD $estimate.TotalCostUSD `
                                -InputTokens $inputTokens -RetryCount $retryCount `
                                -DurationMs $sw.ElapsedMilliseconds `
                                -HttpStatus $http.StatusCode
                }

                $actualCost = Get-AIActualCost -Pricing $pricing -Model $candidate `
                                -InputTokens $parsed.InputTokens -OutputTokens $parsed.OutputTokens
                $script:SessionCostUSD   = $script:SessionCostUSD + $actualCost
                $script:SessionCallCount = $script:SessionCallCount + 1

                $responseText = $parsed.Text
                if (-not $CaptureFullTranscript -and $responseText.Length -gt 100000) {
                    $responseText = $responseText.Substring(0, 100000)
                }

                return New-AIResult -Success $true -Response $responseText `
                            -Model $candidate -TaskTier $TaskTier `
                            -CostUSD $actualCost -EstimatedCostUSD $estimate.TotalCostUSD `
                            -InputTokens $parsed.InputTokens -OutputTokens $parsed.OutputTokens `
                            -RetryCount $retryCount -DurationMs $sw.ElapsedMilliseconds `
                            -HttpStatus 200
            }

            # 404 = model unavailable on this plan: stop retrying this model and
            # let the outer loop try the next candidate.
            if ($http.StatusCode -eq 404) {
                $modelUnavailable = $true
                break
            }

            $transient = Test-AITransientFailure -StatusCode $http.StatusCode -Message $http.ErrorMessage
            if (-not $transient) {
                # A real error with this request (400/401/403, malformed). Trying
                # other models would repeat it, so return now.
                return New-AIResult -FailureReason $script:FailureReasons.NonTransient `
                            -Model $candidate -TaskTier $TaskTier `
                            -EstimatedCostUSD $estimate.TotalCostUSD `
                            -InputTokens $inputTokens -RetryCount $retryCount `
                            -DurationMs $sw.ElapsedMilliseconds `
                            -HttpStatus $http.StatusCode -FailureDetail $http.ErrorDetail
            }
            $lastReason = $script:FailureReasons.RetriesExhausted
        }

        if ($modelUnavailable) {
            # Record and advance to the next candidate.
            $lastResult = New-AIResult -FailureReason $script:FailureReasons.ModelUnavailable `
                        -Model $candidate -TaskTier $TaskTier `
                        -EstimatedCostUSD $estimate.TotalCostUSD `
                        -InputTokens $inputTokens -RetryCount $retryCount `
                        -DurationMs $sw.ElapsedMilliseconds `
                        -HttpStatus $lastStatus -FailureDetail $lastDetail
            continue
        }

        # Transient retries exhausted on this candidate. This is not a model
        # problem, so do not burn the rest of the chain on it: return.
        return New-AIResult -FailureReason $lastReason `
                    -Model $candidate -TaskTier $TaskTier `
                    -EstimatedCostUSD $estimate.TotalCostUSD `
                    -InputTokens $inputTokens -RetryCount $retryCount `
                    -DurationMs $sw.ElapsedMilliseconds `
                    -HttpStatus $lastStatus -FailureDetail $lastDetail
    }

    # Chain exhausted. Return the last recorded failure (ceiling or the final
    # ModelUnavailable), or a bare ModelUnavailable if somehow nothing was set.
    if ($null -ne $lastResult) { return $lastResult }
    return New-AIResult -FailureReason $script:FailureReasons.ModelUnavailable `
                -Model $resolvedModel -TaskTier $TaskTier `
                -InputTokens $inputTokens -DurationMs $sw.ElapsedMilliseconds
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
        [string[]]$ModelFallbacks = @(),
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
                -Model $Model -ModelFallbacks $ModelFallbacks -SessionCeilingUSD $SessionCeilingUSD `
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
