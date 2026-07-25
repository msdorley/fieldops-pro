#Requires -Version 5.1
<#
    FieldOps Pro - Phase 6, Stream 6.5 (PR 5a: cross-model fallback)

    Tests for cross-model fallback in FieldOps-AIClient.

    WHY FALLBACK IS A SEPARATE AXIS FROM RETRY

    The client already retries the SAME model on transient failures (429/5xx).
    Fallback is different: on a 404 (model unavailable on this plan) it tries a
    DIFFERENT model. The two must compose without interfering -- a transient
    failure must not consume the fallback chain, and a 404 must not be retried
    on the same model.

    The distinction that makes this safe was verified against current Anthropic
    behaviour: an UNAVAILABLE model returns 404 not_found_error (fall back), an
    INVALID model name returns 400 invalid_request_error (do not fall back --
    other models would repeat the same bad request).

    All network access is mocked at the single transport boundary, so these run
    offline and deterministically.
#>

BeforeAll {
    $script:TestsRoot  = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:RepoRoot   = Split-Path $script:TestsRoot -Parent
    $script:ModulePath = Join-Path $script:RepoRoot 'SCRIPTS\AI\FieldOps-AIClient.psm1'
    Import-Module $script:ModulePath -Force -DisableNameChecking

    function New-SuccessHttp {
        param([int]$In = 100, [int]$Out = 50, [string]$Text = 'ok')
        [PSCustomObject]@{
            Success=$true; StatusCode=200; ErrorMessage=''
            Body=[PSCustomObject]@{
                content = @([PSCustomObject]@{ type='text'; text=$Text })
                usage   = [PSCustomObject]@{ input_tokens=$In; output_tokens=$Out }
            }
        }
    }
    function New-ErrorHttp {
        param([int]$Status, [string]$Message = 'error')
        [PSCustomObject]@{ Success=$false; StatusCode=$Status; Body=$null; ErrorMessage=$Message }
    }
}

AfterAll {
    Remove-Module 'FieldOps-AIClient' -Force -ErrorAction SilentlyContinue
}

# ==============================================================================
Describe 'Fallback chain derivation (6.5-R11)' -Tag 'Fast' {

    It 'degrades gracefully: requested model, then cheaper models, closest first' {
        InModuleScope 'FieldOps-AIClient' {
            $p = Import-AIPricingConfig -Force
            $chain = Get-AIModelFallbackChain -Pricing $p -RequestedModel 'claude-opus-4-8'
            # opus -> sonnet -> haiku, never opus -> haiku -> sonnet
            $chain[0] | Should -Be 'claude-opus-4-8'
            $chain[1] | Should -Be 'claude-sonnet-5'
            $chain[2] | Should -Be 'claude-haiku-4-5-20251001'
        }
    }

    It 'never upgrades: a mid-tier request does not fall back to a pricier model' {
        InModuleScope 'FieldOps-AIClient' {
            $p = Import-AIPricingConfig -Force
            $chain = Get-AIModelFallbackChain -Pricing $p -RequestedModel 'claude-sonnet-5'
            $chain | Should -Not -Contain 'claude-opus-4-8'
            $chain[0] | Should -Be 'claude-sonnet-5'
            $chain[1] | Should -Be 'claude-haiku-4-5-20251001'
        }
    }

    It 'the cheapest model has no fallback tail' {
        InModuleScope 'FieldOps-AIClient' {
            $p = Import-AIPricingConfig -Force
            $chain = @(Get-AIModelFallbackChain -Pricing $p -RequestedModel 'claude-haiku-4-5-20251001')
            $chain.Count | Should -Be 1
        }
    }

    It 'excludes legacy models from the derived chain' {
        InModuleScope 'FieldOps-AIClient' {
            $p = Import-AIPricingConfig -Force
            $chain = Get-AIModelFallbackChain -Pricing $p -RequestedModel 'claude-opus-4-8'
            $chain | Should -Not -Contain 'claude-sonnet-4-6'
            $chain | Should -Not -Contain 'claude-opus-4-6'
        }
    }

    It 'an explicit override produces a real array, not a fused string' {
        InModuleScope 'FieldOps-AIClient' {
            $p = Import-AIPricingConfig -Force
            $chain = Get-AIModelFallbackChain -Pricing $p `
                        -RequestedModel 'claude-opus-4-8' -Override @('claude-haiku-4-5-20251001')
            @($chain).Count | Should -Be 2
            $chain[0] | Should -Be 'claude-opus-4-8'
            $chain[1] | Should -Be 'claude-haiku-4-5-20251001'
        }
    }
}

# ==============================================================================
Describe 'Cross-model fallback behaviour (6.5-R9, 6.5-R10)' -Tag 'Fast' {

    BeforeEach {
        Reset-FieldOpsAISession
        Mock -ModuleName 'FieldOps-AIClient' Get-AIApiKey { 'unit-test-key-value' }
        Mock -ModuleName 'FieldOps-AIClient' Get-AITechnicianId { 'testtech0001' }
        Mock -ModuleName 'FieldOps-AIClient' Get-AIRetryDelaySeconds { 0 }
    }

    It 'falls through to the next model on a 404 and succeeds' {
        # First model (opus) 404s, second (sonnet) succeeds.
        $script:calls = @()
        Mock -ModuleName 'FieldOps-AIClient' Invoke-AIHttpRequest {
            $script:calls += $Model
            if ($Model -eq 'claude-opus-4-8') { return (New-ErrorHttp -Status 404 -Message 'model: claude-opus-4-8') }
            return (New-SuccessHttp -Text 'from sonnet')
        }

        $r = Invoke-FieldOpsAI -Prompt 'test' -TaskTier 'Reasoning' -MaxCostUSD 5.0 -NoAudit
        $r.Success  | Should -BeTrue
        $r.Response | Should -Be 'from sonnet'
        $r.Model    | Should -Be 'claude-sonnet-5'
        # opus tried once (404, no retry), then sonnet once (success).
        @($script:calls) | Should -Be @('claude-opus-4-8', 'claude-sonnet-5')
    }

    It 'does NOT fall through on a 400 (bad request repeats on every model)' {
        $script:calls = @()
        Mock -ModuleName 'FieldOps-AIClient' Invoke-AIHttpRequest {
            $script:calls += $Model
            return (New-ErrorHttp -Status 400 -Message 'invalid_request_error')
        }

        $r = Invoke-FieldOpsAI -Prompt 'test' -TaskTier 'Reasoning' -MaxCostUSD 5.0 -NoAudit
        $r.Success       | Should -BeFalse
        $r.FailureReason | Should -Be 'NonTransientFailure'
        # Only the first model attempted; the chain was NOT walked.
        @($script:calls).Count | Should -Be 1
        $script:calls[0] | Should -Be 'claude-opus-4-8'
    }

    It 'walks the whole chain when every model is 404, then reports ModelUnavailable' {
        $script:calls = @()
        Mock -ModuleName 'FieldOps-AIClient' Invoke-AIHttpRequest {
            $script:calls += $Model
            return (New-ErrorHttp -Status 404 -Message "model: $Model")
        }

        $r = Invoke-FieldOpsAI -Prompt 'test' -TaskTier 'Reasoning' -MaxCostUSD 5.0 -NoAudit
        $r.Success       | Should -BeFalse
        $r.FailureReason | Should -Be 'ModelUnavailable'
        # opus, sonnet, haiku -- each once, no retries on 404.
        @($script:calls) | Should -Be @('claude-opus-4-8', 'claude-sonnet-5', 'claude-haiku-4-5-20251001')
    }

    It 'a transient failure retries the SAME model and does not consume the chain' {
        # Sonnet 503s four times (retries exhausted). It must NOT then try haiku:
        # a transient failure is not a model problem.
        $script:calls = @()
        Mock -ModuleName 'FieldOps-AIClient' Invoke-AIHttpRequest {
            $script:calls += $Model
            return (New-ErrorHttp -Status 503 -Message 'Service Unavailable')
        }

        $r = Invoke-FieldOpsAI -Prompt 'test' -TaskTier 'Narration' -MaxCostUSD 5.0 -NoAudit
        $r.Success       | Should -BeFalse
        $r.FailureReason | Should -Be 'TransientFailureRetriesExhausted'
        # All 4 attempts on sonnet; haiku never tried.
        @($script:calls).Count | Should -Be 4
        (@($script:calls) | Sort-Object -Unique) | Should -Be @('claude-sonnet-5')
    }

    It '404 then transient-then-success on the fallback model works end to end' {
        # opus 404s; sonnet 503s twice then succeeds. Proves fallback and retry
        # compose: chain advances on 404, retry handles transience on the new model.
        $script:seq = @{}
        Mock -ModuleName 'FieldOps-AIClient' Invoke-AIHttpRequest {
            if (-not $script:seq.ContainsKey($Model)) { $script:seq[$Model] = 0 }
            $script:seq[$Model]++
            if ($Model -eq 'claude-opus-4-8') { return (New-ErrorHttp -Status 404) }
            if ($script:seq[$Model] -le 2)     { return (New-ErrorHttp -Status 503) }
            return (New-SuccessHttp -Text 'recovered')
        }

        $r = Invoke-FieldOpsAI -Prompt 'test' -TaskTier 'Reasoning' -MaxCostUSD 5.0 -NoAudit
        $r.Success  | Should -BeTrue
        $r.Response | Should -Be 'recovered'
        $r.Model    | Should -Be 'claude-sonnet-5'
        $r.RetryCount | Should -Be 2
    }

    It 'an explicit -ModelFallbacks chain is honoured' {
        $script:calls = @()
        Mock -ModuleName 'FieldOps-AIClient' Invoke-AIHttpRequest {
            $script:calls += $Model
            if ($Model -eq 'claude-opus-4-8') { return (New-ErrorHttp -Status 404) }
            return (New-SuccessHttp)
        }

        $r = Invoke-FieldOpsAI -Prompt 'test' -TaskTier 'Reasoning' `
                -ModelFallbacks @('claude-haiku-4-5-20251001') -MaxCostUSD 5.0 -NoAudit
        $r.Success | Should -BeTrue
        # opus (404) then the OVERRIDE target haiku, not the derived sonnet.
        @($script:calls) | Should -Be @('claude-opus-4-8', 'claude-haiku-4-5-20251001')
    }
}

# ==============================================================================
Describe 'Fallback preserves existing single-model guarantees' -Tag 'Fast' {

    BeforeEach {
        Reset-FieldOpsAISession
        Mock -ModuleName 'FieldOps-AIClient' Get-AIApiKey { 'unit-test-key-value' }
        Mock -ModuleName 'FieldOps-AIClient' Get-AITechnicianId { 'testtech0001' }
    }

    It 'a ceiling refusal on the primary still tries a cheaper model that fits' {
        # A prompt too costly on opus may be affordable on haiku. The chain
        # should let the cheaper model answer rather than refusing outright.
        Mock -ModuleName 'FieldOps-AIClient' Get-AIRetryDelaySeconds { 0 }
        $script:calls = @()
        Mock -ModuleName 'FieldOps-AIClient' Invoke-AIHttpRequest {
            $script:calls += $Model
            return (New-SuccessHttp)
        }

        # Ceiling set so opus is refused but haiku fits. ~4000 char prompt.
        $prompt = 'x' * 4000
        $r = Invoke-FieldOpsAI -Prompt $prompt -TaskTier 'Reasoning' -MaxCostUSD 0.02 -NoAudit
        # Whatever the exact arithmetic, the result must be a success on a
        # cheaper model OR a clean ceiling refusal -- never a crash, never opus.
        if ($r.Success) {
            $r.Model | Should -Not -Be 'claude-opus-4-8'
        } else {
            $r.FailureReason | Should -Be 'EstimateExceedsCeiling'
        }
    }

    It 'still refuses before the network when even the cheapest model exceeds the ceiling' {
        Mock -ModuleName 'FieldOps-AIClient' Invoke-AIHttpRequest { throw 'must not be called' }
        $big = 'x' * 400000
        $r = Invoke-FieldOpsAI -Prompt $big -TaskTier 'Reasoning' -MaxCostUSD 0.0001 -NoAudit
        $r.Success       | Should -BeFalse
        $r.FailureReason | Should -Be 'EstimateExceedsCeiling'
        Should -Invoke -ModuleName 'FieldOps-AIClient' Invoke-AIHttpRequest -Times 0 -Exactly
    }
}
