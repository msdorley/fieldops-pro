#Requires -Version 5.1
<#
    FieldOps Pro - Phase 6, Stream 6.5 (PR 5b-2b: ComplianceDiff reroute)

    Tests that Invoke-ComplianceDiff's AI analysis goes through the shared
    client and keeps its fallback contract.

    WHY A REROUTE NEEDS ITS OWN TESTS

    The audit (Audit-NoDirectAnthropicCalls) proves no direct API call SURVIVES
    in the script. It cannot prove the replacement behaves. The contract that
    matters to a technician in the field is narrower and stricter than "no
    direct calls": whatever happens to the AI, Invoke-AIAnalysis returns either
    a parsed result object or $null, never throws, and $null always means the
    caller falls through to local rule-based classification and still produces
    a complete report. AI is enrichment, never a dependency (6.5-R10).

    HOW THIS TESTS A SCRIPT THAT IS NOT A MODULE

    Invoke-ComplianceDiff.ps1 runs its pipeline top-to-bottom, so dot-sourcing
    it would take snapshots of the test machine and write reports. We reuse the
    D11 pattern instead: pull just the function definitions out via the AST and
    dot-source those. Zero changes to production code.
#>

BeforeAll {
    $script:TestsRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:RepoRoot  = Split-Path $script:TestsRoot -Parent
    $script:DiffPath  = Join-Path $script:RepoRoot 'SCRIPTS\Core\Invoke-ComplianceDiff.ps1'

    . (Join-Path $script:TestsRoot 'Get-EvaluatorSource.ps1')
    $src = Get-EvaluatorSource -ScriptPath $script:DiffPath
    . ([scriptblock]::Create($src))

    # --- script-scope state Invoke-AIAnalysis reads -------------------------
    $NoAI       = $false
    $apiKey     = 'sk-ant-api03-testtesttesttesttesttesttesttest'
    $HOSTNAME   = 'TESTHOST'
    $techName   = 'Test Technician'
    $IncidentId = 'INC-001'
    $script:AIClientLoaded = $true

    # --- controllable stand-in for the client -------------------------------
    # The client is not imported here: what is under test is how this script
    # CONSUMES a result object, not the client's own behaviour (covered by
    # AIFailureDetail/AIModelFallback). $script:NextAICall drives the outcome.
    $script:LastAICallArgs = $null
    function Invoke-FieldOpsAI {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory=$true)][string]$Prompt,
            [string]$SystemPrompt = '', [string]$CallingContext = '',
            [string]$TaskTier = 'Narration', [double]$MaxCostUSD = 0.0,
            [double]$OutputMultiplier = 0.0, [string]$Model = '',
            [string[]]$ModelFallbacks = @(), [double]$SessionCeilingUSD = 0.0,
            [int]$MaxTokens = 4096, [switch]$ExpectPlaybookReference,
            [switch]$CaptureFullTranscript, [string]$ConfigDir = '',
            [string]$LogsDir = '', [switch]$NoAudit
        )
        $script:LastAICallArgs = [PSCustomObject]@{
            Prompt = $Prompt; TaskTier = $TaskTier
            MaxTokens = $MaxTokens; CallingContext = $CallingContext
        }
        return $script:NextAICall
    }

    function New-AICallResult {
        param(
            [bool]$Success = $false, [string]$Response = '',
            [string]$FailureReason = '', [string]$Model = 'claude-sonnet-5',
            [int]$HttpStatus = 0, [string]$FailureDetail = '',
            [double]$CostUSD = 0.0
        )
        [PSCustomObject]@{
            Success = $Success; Response = $Response
            FailureReason = $FailureReason; Model = $Model
            HttpStatus = $HttpStatus; FailureDetail = $FailureDetail
            CostUSD = $CostUSD; AuditRecordPath = $null
        }
    }

    function New-TestChanges {
        param([int]$Count = 3)
        $list = [System.Collections.Generic.List[PSCustomObject]]::new()
        for ($i = 1; $i -le $Count; $i++) {
            $null = $list.Add([PSCustomObject]@{
                Category = 'Registry'; ChangeType = 'MODIFIED'
                Item = "Item$i"; Before = 'before value'; After = 'after value'
                Severity = 'High'; LocalClass = 'Regression'
            })
        }
        return $list
    }

    $script:GoodJson = '{"executiveSummary":"ok","overallAssessment":"IMPROVED","securityDelta":1,"changeAnalysis":[],"suspiciousFindings":[],"recommendations":[],"requiresImmediateAction":false,"complianceSummary":"fine"}'
}

# ==============================================================================
Describe 'Analysis routes through the client (6.5-R1, 6.5-D12)' -Tag 'Fast' {

    It 'calls the client once, on the Reasoning tier, tagged for audit' {
        $script:NextAICall = New-AICallResult -Success $true -Response $script:GoodJson
        $null = Invoke-AIAnalysis -Changes (New-TestChanges) -BeforeSnap $null -AfterSnap $null

        $script:LastAICallArgs                | Should -Not -BeNullOrEmpty
        $script:LastAICallArgs.TaskTier       | Should -Be 'Reasoning'
        $script:LastAICallArgs.MaxTokens      | Should -Be 4000
        # The audit log is only useful if calls are attributable to a call site.
        $script:LastAICallArgs.CallingContext | Should -Be 'ComplianceDiff/Analysis'
    }

    It 'still sends the condensed diff payload, not the raw change list' {
        $script:NextAICall = New-AICallResult -Success $true -Response $script:GoodJson
        $null = Invoke-AIAnalysis -Changes (New-TestChanges -Count 50) -BeforeSnap $null -AfterSnap $null

        # Payload trimming (top 30 by severity, 6000-char cap) is a v1.2.1 fix
        # for 400 "payload too large". Routing must not have undone it.
        $script:LastAICallArgs.Prompt.Length | Should -BeLessThan 12000
        $script:LastAICallArgs.Prompt        | Should -Match 'CHANGES'
    }

    It 'returns the parsed object and reports the model that actually answered' {
        # Not necessarily the requested model: the client may have fallen back.
        $script:NextAICall = New-AICallResult -Success $true -Response $script:GoodJson `
                                -Model 'claude-haiku-4-5-20251001' -CostUSD 0.0021
        $r = Invoke-AIAnalysis -Changes (New-TestChanges) -BeforeSnap $null -AfterSnap $null

        $r                    | Should -Not -BeNullOrEmpty
        $r.overallAssessment  | Should -Be 'IMPROVED'
        $script:AI_MODEL      | Should -Be 'claude-haiku-4-5-20251001'
    }

    It 'strips a markdown fence the model wrapped around the JSON' {
        $fenced = "``````json`n$($script:GoodJson)`n``````"
        $script:NextAICall = New-AICallResult -Success $true -Response $fenced
        $r = Invoke-AIAnalysis -Changes (New-TestChanges) -BeforeSnap $null -AfterSnap $null

        $r                   | Should -Not -BeNullOrEmpty
        $r.overallAssessment | Should -Be 'IMPROVED'
    }
}

# ==============================================================================
Describe 'Fallback contract: $null, never an exception (6.5-R10)' -Tag 'Fast' {

    It 'returns $null without calling the client when -NoAI is set' {
        $NoAI = $true
        $script:LastAICallArgs = $null
        $script:NextAICall = New-AICallResult -Success $true -Response $script:GoodJson

        Invoke-AIAnalysis -Changes (New-TestChanges) -BeforeSnap $null -AfterSnap $null |
            Should -BeNullOrEmpty
        $script:LastAICallArgs | Should -BeNullOrEmpty
    }

    It 'returns $null when the client module never loaded' {
        $script:AIClientLoaded = $false
        try {
            Invoke-AIAnalysis -Changes (New-TestChanges) -BeforeSnap $null -AfterSnap $null |
                Should -BeNullOrEmpty
        } finally { $script:AIClientLoaded = $true }
    }

    It 'returns $null for every failure reason the client can report' {
        foreach ($reason in @('NoApiKey','PricingConfigUnavailable','EstimateExceedsCeiling',
                              'SessionCeilingExceeded','TransientFailureRetriesExhausted',
                              'NonTransientFailure','MalformedResponse','UnknownTaskTier',
                              'ModelUnavailable')) {
            $script:NextAICall = New-AICallResult -Success $false -FailureReason $reason
            Invoke-AIAnalysis -Changes (New-TestChanges) -BeforeSnap $null -AfterSnap $null |
                Should -BeNullOrEmpty -Because "reason $reason must degrade to local rules"
        }
    }

    It 'returns $null rather than throwing when the model answers in prose' {
        # A model that ignores "respond ONLY with JSON" is a bad response, not
        # a failed run. Before the reroute this threw out of ConvertFrom-Json.
        $script:NextAICall = New-AICallResult -Success $true `
                                -Response 'Sure! Here is my analysis: things look fine.'
        { Invoke-AIAnalysis -Changes (New-TestChanges) -BeforeSnap $null -AfterSnap $null } |
            Should -Not -Throw

        $script:NextAICall = New-AICallResult -Success $true `
                                -Response 'Sure! Here is my analysis: things look fine.'
        Invoke-AIAnalysis -Changes (New-TestChanges) -BeforeSnap $null -AfterSnap $null |
            Should -BeNullOrEmpty
    }

    It 'returns $null on an empty response' {
        $script:NextAICall = New-AICallResult -Success $true -Response ''
        Invoke-AIAnalysis -Changes (New-TestChanges) -BeforeSnap $null -AfterSnap $null |
            Should -BeNullOrEmpty
    }

    It 'survives an empty change list' {
        $script:NextAICall = New-AICallResult -Success $true -Response $script:GoodJson
        $empty = [System.Collections.Generic.List[PSCustomObject]]::new()
        { Invoke-AIAnalysis -Changes $empty -BeforeSnap $null -AfterSnap $null } |
            Should -Not -Throw
    }
}

# ==============================================================================
Describe 'Failure guidance preserved from the pre-reroute script' -Tag 'Fast' {

    BeforeEach {
        $script:Emitted = [System.Collections.Generic.List[string]]::new()
        Mock Write-Step { $null = $script:Emitted.Add($M) }
    }

    It 'still tells the technician to add credits' {
        # The single most common field failure on the Evaluation plan. Losing
        # this hint was the main risk of routing through a coarser client.
        $call = New-AICallResult -Success $false -FailureReason 'NonTransientFailure' `
                    -HttpStatus 400 -FailureDetail 'Your credit balance is too low to access the Anthropic API.'
        Write-AIFailureGuidance -Call $call

        ($script:Emitted -join "`n") | Should -Match 'credit balance'
        ($script:Emitted -join "`n") | Should -Match 'Plans & Billing'
    }

    It 'still tells the technician to replace a rejected key' {
        $call = New-AICallResult -Success $false -FailureReason 'NonTransientFailure' `
                    -HttpStatus 401 -FailureDetail 'invalid x-api-key'
        Write-AIFailureGuidance -Call $call

        ($script:Emitted -join "`n") | Should -Match 'API Keys'
    }

    It 'names a rate limit as transient rather than a configuration fault' {
        $call = New-AICallResult -Success $false -FailureReason 'TransientFailureRetriesExhausted' `
                    -HttpStatus 429 -FailureDetail 'rate limit exceeded'
        Write-AIFailureGuidance -Call $call

        ($script:Emitted -join "`n") | Should -Match 'again shortly'
    }

    It 'explains a ceiling refusal as cost governance, not an outage' {
        $call = New-AICallResult -Success $false -FailureReason 'EstimateExceedsCeiling'
        Write-AIFailureGuidance -Call $call

        ($script:Emitted -join "`n") | Should -Match 'ceiling'
    }

    It 'says something actionable for every failure reason, and never throws' {
        foreach ($reason in @('NoApiKey','PricingConfigUnavailable','EstimateExceedsCeiling',
                              'SessionCeilingExceeded','TransientFailureRetriesExhausted',
                              'NonTransientFailure','MalformedResponse','UnknownTaskTier',
                              'ModelUnavailable','SomethingAddedLater')) {
            $script:Emitted = [System.Collections.Generic.List[string]]::new()
            $call = New-AICallResult -Success $false -FailureReason $reason
            { Write-AIFailureGuidance -Call $call } | Should -Not -Throw
            $script:Emitted.Count | Should -BeGreaterThan 0 -Because "reason $reason must produce guidance"
        }
    }

    It 'displays the provider detail verbatim, so a reworded message still informs' {
        # The credits/key keyword sniff is a shortcut, not the mechanism. If the
        # provider rewords everything, the raw line must still reach the operator.
        $call = New-AICallResult -Success $false -FailureReason 'NonTransientFailure' `
                    -HttpStatus 400 -FailureDetail 'some entirely novel provider wording'
        Write-AIFailureGuidance -Call $call

        ($script:Emitted -join "`n") | Should -Match 'some entirely novel provider wording'
    }
}
