#Requires -Version 5.1
<#
    FieldOps Pro - Phase 6, Stream 6.5 (D9 + D11)

    Tests for SCRIPTS/AI/FieldOps-AIClient.psm1.

    HOW THESE RUN OFFLINE

    Every network call in the client goes through one internal function,
    Invoke-AIHttpRequest. These tests mock that single boundary, which makes
    the entire cost, ceiling, retry and degradation surface verifiable without
    an API key or a network. That is a requirement, not a convenience: the
    suite runs air-gapped and the pre-push hook cannot depend on live
    credentials.

    THE ASSERTION THAT MATTERS MOST

    When a ceiling refuses a call, the tests assert the transport was invoked
    ZERO times. A ceiling that labels a failure after the request has already
    been sent protects nobody -- the money is spent. Checking only the returned
    FailureReason would pass in both cases, so the invocation count is what
    actually distinguishes a working control from a decorative one.

    ON THE FAKE KEY

    The mocked API key deliberately does not use Anthropic's real key prefix.
    Requirement 6.5-R12 is enforced by an audit test that scans for that
    prefix; seeding it into a test file would create a false positive in a
    guard whose value depends on being trusted. This comment avoids writing
    the prefix out for the same reason.
#>

BeforeAll {
    $script:TestsRoot  = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:RepoRoot   = Split-Path $script:TestsRoot -Parent
    $script:ModulePath = Join-Path $script:RepoRoot 'SCRIPTS\AI\FieldOps-AIClient.psm1'

    Import-Module $script:ModulePath -Force -DisableNameChecking
}

AfterAll {
    Remove-Module 'FieldOps-AIClient' -Force -ErrorAction SilentlyContinue
}

# ==============================================================================
Describe 'AI client - cost estimation arithmetic (6.5-R3)' -Tag 'Fast' {

    It 'estimates tokens by rounding UP, never down' {
        InModuleScope 'FieldOps-AIClient' {
            $p = Import-AIPricingConfig -Force
            # 7000 chars / 2.6 = 2692.3 -> 2693. A fractional token rounded
            # down is a token the ceiling did not account for.
            Measure-AIEstimatedTokens -Pricing $p -CharCount 7000 | Should -Be 2693
            Measure-AIEstimatedTokens -Pricing $p -CharCount 1     | Should -Be 1
            Measure-AIEstimatedTokens -Pricing $p -CharCount 0     | Should -Be 0
        }
    }

    It 'computes cost per the specified formula' {
        InModuleScope 'FieldOps-AIClient' {
            $p = Import-AIPricingConfig -Force
            # Opus 4.8 at 5.00 / 25.00 per MTok, 2000 input, multiplier 2.5:
            #   input  2000 / 1e6 * 5.00  = 0.010
            #   output 5000 / 1e6 * 25.00 = 0.125
            #   total                     = 0.135
            $e = Get-AICostEstimate -Pricing $p -Model 'claude-opus-4-8' `
                    -InputTokens 2000 -OutputMultiplier 2.5
            [Math]::Round($e.InputCostUSD, 6)  | Should -Be 0.01
            [Math]::Round($e.OutputCostUSD, 6) | Should -Be 0.125
            [Math]::Round($e.TotalCostUSD, 6)  | Should -Be 0.135
            $e.EstimatedOutputTokens           | Should -Be 5000
        }
    }

    It 'is monotonic: a longer prompt never estimates cheaper' {
        InModuleScope 'FieldOps-AIClient' {
            $p = Import-AIPricingConfig -Force
            $prev = -1.0
            foreach ($tokens in @(100, 500, 1000, 5000, 20000)) {
                $e = Get-AICostEstimate -Pricing $p -Model 'claude-sonnet-5' `
                        -InputTokens $tokens -OutputMultiplier 2.0
                ($e.TotalCostUSD -gt $prev) | Should -BeTrue
                $prev = $e.TotalCostUSD
            }
        }
    }

    It 'prices an unrecognised model as the most expensive current model' {
        InModuleScope 'FieldOps-AIClient' {
            $p = Import-AIPricingConfig -Force
            $unknown = Get-AICostEstimate -Pricing $p -Model 'claude-does-not-exist' `
                        -InputTokens 2000 -OutputMultiplier 2.5
            $opus = Get-AICostEstimate -Pricing $p -Model 'claude-opus-4-8' `
                        -InputTokens 2000 -OutputMultiplier 2.5

            $unknown.RateWasFallback | Should -BeTrue
            $unknown.TotalCostUSD    | Should -Be $opus.TotalCostUSD
            # A configuration typo must never estimate lower than a correct
            # value, or it would silently disable the ceiling.
            $unknown.TotalCostUSD | Should -BeGreaterOrEqual $opus.TotalCostUSD
        }
    }

    It 'reports the model actually priced, not the one requested' {
        InModuleScope 'FieldOps-AIClient' {
            $p = Import-AIPricingConfig -Force
            $e = Get-AICostEstimate -Pricing $p -Model 'claude-does-not-exist' `
                    -InputTokens 100 -OutputMultiplier 1.0
            # This value reaches the audit record in PR3. Naming the requested
            # model would make the record misstate what was priced.
            $e.PricedAsModel | Should -Be 'claude-opus-4-8'
        }
    }

    It 'a cheaper tier estimates below a more expensive one for identical input' {
        InModuleScope 'FieldOps-AIClient' {
            $p = Import-AIPricingConfig -Force
            $haiku = Get-AICostEstimate -Pricing $p -Model 'claude-haiku-4-5-20251001' -InputTokens 5000 -OutputMultiplier 2.0
            $sonnet= Get-AICostEstimate -Pricing $p -Model 'claude-sonnet-5'           -InputTokens 5000 -OutputMultiplier 2.0
            $opus  = Get-AICostEstimate -Pricing $p -Model 'claude-opus-4-8'           -InputTokens 5000 -OutputMultiplier 2.0
            ($haiku.TotalCostUSD -lt $sonnet.TotalCostUSD) | Should -BeTrue
            ($sonnet.TotalCostUSD -lt $opus.TotalCostUSD)  | Should -BeTrue
        }
    }
}

# ==============================================================================
Describe 'AI client - tier resolution (6.5-R2, 6.5-R11)' -Tag 'Fast' {

    It 'resolves each task tier to a configured model' {
        InModuleScope 'FieldOps-AIClient' {
            $p = Import-AIPricingConfig -Force
            Resolve-AIModelForTier -Pricing $p -TaskTier 'Classification' | Should -Be 'claude-haiku-4-5-20251001'
            Resolve-AIModelForTier -Pricing $p -TaskTier 'Narration'      | Should -Be 'claude-sonnet-5'
            Resolve-AIModelForTier -Pricing $p -TaskTier 'Reasoning'      | Should -Be 'claude-opus-4-8'
        }
    }

    It 'an explicit model override wins over the tier mapping' {
        InModuleScope 'FieldOps-AIClient' {
            $p = Import-AIPricingConfig -Force
            Resolve-AIModelForTier -Pricing $p -TaskTier 'Classification' -ModelOverride 'claude-opus-4-8' |
                Should -Be 'claude-opus-4-8'
        }
    }

    It 'an unknown tier resolves to empty rather than guessing' {
        InModuleScope 'FieldOps-AIClient' {
            $p = Import-AIPricingConfig -Force
            Resolve-AIModelForTier -Pricing $p -TaskTier 'NotATier' | Should -Be ''
        }
    }
}

# ==============================================================================
Describe 'AI client - ceiling enforcement (6.5-R3, 6.5-R4) [D11]' -Tag 'Fast' {

    BeforeEach {
        Reset-FieldOpsAISession
        Mock -ModuleName 'FieldOps-AIClient' Get-AIApiKey { 'unit-test-key-value' }
        Mock -ModuleName 'FieldOps-AIClient' Invoke-AIHttpRequest {
            [PSCustomObject]@{
                Success      = $true
                StatusCode   = 200
                ErrorMessage = ''
                Body         = [PSCustomObject]@{
                    content = @([PSCustomObject]@{ type = 'text'; text = 'mock response' })
                    usage   = [PSCustomObject]@{ input_tokens = 100; output_tokens = 50 }
                }
            }
        }
    }

    It 'allows a call whose estimate sits under the ceiling' {
        $r = Invoke-FieldOpsAI -Prompt 'short prompt' -TaskTier 'Classification' -MaxCostUSD 0.50
        $r.Success  | Should -BeTrue
        $r.Response | Should -Be 'mock response'
        Should -Invoke -ModuleName 'FieldOps-AIClient' Invoke-AIHttpRequest -Times 1 -Exactly
    }

    It 'refuses a call whose estimate exceeds the ceiling' {
        $big = 'x' * 400000
        $r = Invoke-FieldOpsAI -Prompt $big -TaskTier 'Reasoning' -MaxCostUSD 0.01 -OutputMultiplier 3.0
        $r.Success       | Should -BeFalse
        $r.FailureReason | Should -Be 'EstimateExceedsCeiling'
    }

    It 'a refused call never reaches the network' {
        # The assertion that separates a real control from a decorative one.
        # A ceiling checked after the request has been sent protects nothing:
        # the money is already spent.
        $big = 'x' * 400000
        $null = Invoke-FieldOpsAI -Prompt $big -TaskTier 'Reasoning' -MaxCostUSD 0.01 -OutputMultiplier 3.0
        Should -Invoke -ModuleName 'FieldOps-AIClient' Invoke-AIHttpRequest -Times 0 -Exactly
    }

    It 'reports the estimate that caused the refusal' {
        $big = 'x' * 400000
        $r = Invoke-FieldOpsAI -Prompt $big -TaskTier 'Reasoning' -MaxCostUSD 0.01 -OutputMultiplier 3.0
        # Without this the operator cannot tell whether to raise the ceiling
        # or shorten the prompt.
        ($r.EstimatedCostUSD -gt 0.01) | Should -BeTrue
    }

    It 'accumulates session cost across calls' {
        $null = Invoke-FieldOpsAI -Prompt 'one'   -TaskTier 'Classification'
        $null = Invoke-FieldOpsAI -Prompt 'two'   -TaskTier 'Classification'
        $null = Invoke-FieldOpsAI -Prompt 'three' -TaskTier 'Classification'
        $s = Get-FieldOpsAISessionCost
        $s.CallCount | Should -Be 3
        ($s.SessionCostUSD -gt 0) | Should -BeTrue
    }

    It 'refuses once the session ceiling would be exceeded' {
        # Ceiling set below the cost of a single call, so the first attempt is
        # allowed only if the session ceiling is not being consulted at all.
        $r1 = Invoke-FieldOpsAI -Prompt ('y' * 60000) -TaskTier 'Reasoning' `
                -MaxCostUSD 5.00 -SessionCeilingUSD 0.0001
        $r1.Success       | Should -BeFalse
        $r1.FailureReason | Should -Be 'SessionCeilingExceeded'
        Should -Invoke -ModuleName 'FieldOps-AIClient' Invoke-AIHttpRequest -Times 0 -Exactly
    }

    It 'resetting the session clears accumulated cost' {
        $null = Invoke-FieldOpsAI -Prompt 'spend a little' -TaskTier 'Classification'
        (Get-FieldOpsAISessionCost).CallCount | Should -Be 1
        Reset-FieldOpsAISession
        $s = Get-FieldOpsAISessionCost
        $s.CallCount      | Should -Be 0
        $s.SessionCostUSD | Should -Be 0
    }

    It 'charges actual token usage, not the estimate' {
        $r = Invoke-FieldOpsAI -Prompt 'short' -TaskTier 'Narration'
        # Mock reports 100 in / 50 out on Sonnet 5 (3.00 / 15.00 per MTok):
        #   100/1e6*3 = 0.0003, 50/1e6*15 = 0.00075, total 0.00105
        [Math]::Round($r.CostUSD, 8) | Should -Be 0.00105
        $r.InputTokens  | Should -Be 100
        $r.OutputTokens | Should -Be 50
    }
}

# ==============================================================================
Describe 'AI client - retry policy (6.5-R9)' -Tag 'Fast' {

    It 'classifies transient failures correctly' {
        InModuleScope 'FieldOps-AIClient' {
            Test-AITransientFailure -StatusCode 429 | Should -BeTrue
            Test-AITransientFailure -StatusCode 500 | Should -BeTrue
            Test-AITransientFailure -StatusCode 503 | Should -BeTrue
            Test-AITransientFailure -StatusCode 0 -Message 'The operation timed out' | Should -BeTrue
        }
    }

    It 'classifies non-transient failures correctly' {
        InModuleScope 'FieldOps-AIClient' {
            # Retrying an unauthorized or malformed request wastes the
            # operator's time and cannot succeed.
            Test-AITransientFailure -StatusCode 400 | Should -BeFalse
            Test-AITransientFailure -StatusCode 401 | Should -BeFalse
            Test-AITransientFailure -StatusCode 403 | Should -BeFalse
            Test-AITransientFailure -StatusCode 404 | Should -BeFalse
        }
    }

    It 'uses the specified backoff schedule' {
        InModuleScope 'FieldOps-AIClient' {
            # Attempt 1 immediate, then 1s, 2s, 4s: 7s worst case over 4 attempts.
            Get-AIRetryDelaySeconds -AttemptNumber 1 | Should -Be 0
            Get-AIRetryDelaySeconds -AttemptNumber 2 | Should -Be 1
            Get-AIRetryDelaySeconds -AttemptNumber 3 | Should -Be 2
            Get-AIRetryDelaySeconds -AttemptNumber 4 | Should -Be 4
        }
    }

    It 'fails fast on a non-transient error without retrying' {
        Reset-FieldOpsAISession
        Mock -ModuleName 'FieldOps-AIClient' Get-AIApiKey { 'unit-test-key-value' }
        Mock -ModuleName 'FieldOps-AIClient' Get-AIRetryDelaySeconds { 0 }
        Mock -ModuleName 'FieldOps-AIClient' Invoke-AIHttpRequest {
            [PSCustomObject]@{ Success=$false; StatusCode=401; Body=$null; ErrorMessage='Unauthorized' }
        }

        $r = Invoke-FieldOpsAI -Prompt 'test' -TaskTier 'Classification'
        $r.Success       | Should -BeFalse
        $r.FailureReason | Should -Be 'NonTransientFailure'
        $r.RetryCount    | Should -Be 0
        Should -Invoke -ModuleName 'FieldOps-AIClient' Invoke-AIHttpRequest -Times 1 -Exactly
    }

    It 'retries a transient failure up to four attempts then gives up' {
        Reset-FieldOpsAISession
        Mock -ModuleName 'FieldOps-AIClient' Get-AIApiKey { 'unit-test-key-value' }
        Mock -ModuleName 'FieldOps-AIClient' Get-AIRetryDelaySeconds { 0 }
        Mock -ModuleName 'FieldOps-AIClient' Invoke-AIHttpRequest {
            [PSCustomObject]@{ Success=$false; StatusCode=503; Body=$null; ErrorMessage='Service Unavailable' }
        }

        $r = Invoke-FieldOpsAI -Prompt 'test' -TaskTier 'Classification'
        $r.Success       | Should -BeFalse
        $r.FailureReason | Should -Be 'TransientFailureRetriesExhausted'
        Should -Invoke -ModuleName 'FieldOps-AIClient' Invoke-AIHttpRequest -Times 4 -Exactly
    }

    It 'treats a malformed success response as non-retryable' {
        Reset-FieldOpsAISession
        Mock -ModuleName 'FieldOps-AIClient' Get-AIApiKey { 'unit-test-key-value' }
        Mock -ModuleName 'FieldOps-AIClient' Get-AIRetryDelaySeconds { 0 }
        Mock -ModuleName 'FieldOps-AIClient' Invoke-AIHttpRequest {
            [PSCustomObject]@{
                Success=$true; StatusCode=200; ErrorMessage=''
                Body=[PSCustomObject]@{ unexpected = 'shape' }
            }
        }

        $r = Invoke-FieldOpsAI -Prompt 'test' -TaskTier 'Classification'
        $r.Success       | Should -BeFalse
        $r.FailureReason | Should -Be 'MalformedResponse'
        Should -Invoke -ModuleName 'FieldOps-AIClient' Invoke-AIHttpRequest -Times 1 -Exactly
    }
}

# ==============================================================================
Describe 'AI client - graceful degradation (6.5-R10)' -Tag 'Fast' {

    It 'returns a failure result rather than throwing when no key is present' {
        Reset-FieldOpsAISession
        Mock -ModuleName 'FieldOps-AIClient' Get-AIApiKey { '' }

        # Assign outside the Should -Not -Throw scriptblock: Pester runs that
        # block in its own scope, so an assignment inside it does not escape.
        # A $null result would then pass -BeFalse vacuously ($null is falsy),
        # giving a green assertion against an object that was never created.
        $r = Invoke-FieldOpsAI -Prompt 'test' -TaskTier 'Classification'
        $r               | Should -Not -BeNullOrEmpty
        $r.Success       | Should -BeFalse
        $r.FailureReason | Should -Be 'NoApiKey'
        { Invoke-FieldOpsAI -Prompt 'test' -TaskTier 'Classification' } | Should -Not -Throw
    }

    It 'fails closed when the pricing config cannot be read' {
        Reset-FieldOpsAISession
        Mock -ModuleName 'FieldOps-AIClient' Get-AIApiKey { 'unit-test-key-value' }
        Mock -ModuleName 'FieldOps-AIClient' Invoke-AIHttpRequest { throw 'transport must not be reached' }

        # No pricing means no estimate means no ceiling. Refusing is the safe
        # outcome; proceeding unmetered is not. The caller's fallback path
        # handles it, so R10 is satisfied by the refusal.
        $r = Invoke-FieldOpsAI -Prompt 'test' -TaskTier 'Classification' `
                -ConfigDir (Join-Path $env:TEMP ('fo-no-config-' + [guid]::NewGuid().ToString('N')))
        $r.Success       | Should -BeFalse
        $r.FailureReason | Should -Be 'PricingConfigUnavailable'
        Should -Invoke -ModuleName 'FieldOps-AIClient' Invoke-AIHttpRequest -Times 0 -Exactly
    }

    It 'does not throw when the transport itself fails' {
        Reset-FieldOpsAISession
        Mock -ModuleName 'FieldOps-AIClient' Get-AIApiKey { 'unit-test-key-value' }
        Mock -ModuleName 'FieldOps-AIClient' Get-AIRetryDelaySeconds { 0 }
        Mock -ModuleName 'FieldOps-AIClient' Invoke-AIHttpRequest {
            [PSCustomObject]@{ Success=$false; StatusCode=0; Body=$null; ErrorMessage='network unreachable' }
        }

        { Invoke-FieldOpsAI -Prompt 'test' -TaskTier 'Narration' } | Should -Not -Throw
    }

    It 'reports availability without making a call' {
        Mock -ModuleName 'FieldOps-AIClient' Invoke-AIHttpRequest { throw 'must not be called' }
        $a = Test-FieldOpsAIAvailability
        $a.PSObject.Properties.Name | Should -Contain 'Available'
        $a.PSObject.Properties.Name | Should -Contain 'HasApiKey'
        Should -Invoke -ModuleName 'FieldOps-AIClient' Invoke-AIHttpRequest -Times 0 -Exactly
    }
}

# ==============================================================================
Describe 'AI client - contract stability and key safety (6.5-R12)' -Tag 'Fast' {

    BeforeEach {
        Reset-FieldOpsAISession
        Mock -ModuleName 'FieldOps-AIClient' Get-AIApiKey { 'unit-test-key-value' }
        Mock -ModuleName 'FieldOps-AIClient' Invoke-AIHttpRequest {
            [PSCustomObject]@{
                Success=$true; StatusCode=200; ErrorMessage=''
                Body=[PSCustomObject]@{
                    content = @([PSCustomObject]@{ type='text'; text='ok' })
                    usage   = [PSCustomObject]@{ input_tokens=10; output_tokens=5 }
                }
            }
        }
    }

    It 'returns the full result shape on success and on failure alike' {
        # Later PRs populate Severity, PlaybookRef and the audit fields. They
        # are present and null from PR2 so call sites written against this
        # contract do not change when those PRs land.
        $expected = @(
            'Success','Response','FailureReason','Model','TaskTier',
            'CostUSD','EstimatedCostUSD','InputTokens','OutputTokens',
            'DurationMs','RetryCount','SessionCostUSD',
            'Severity','NeedsHumanReview','PlaybookRef','PlaybookValid',
            'AuditRecordPath','AuditRecordSha256'
        )

        $ok = Invoke-FieldOpsAI -Prompt 'test' -TaskTier 'Classification'
        foreach ($f in $expected) { $ok.PSObject.Properties.Name | Should -Contain $f }

        $fail = Invoke-FieldOpsAI -Prompt ('z' * 400000) -TaskTier 'Reasoning' -MaxCostUSD 0.001
        foreach ($f in $expected) { $fail.PSObject.Properties.Name | Should -Contain $f }
    }

    It 'never places the API key in the result object' {
        $r = Invoke-FieldOpsAI -Prompt 'test' -TaskTier 'Classification'
        $serialized = ($r | ConvertTo-Json -Depth 5)
        $serialized | Should -Not -Match 'unit-test-key-value'
    }

    It 'availability reports a boolean for the key, never the key itself' {
        $a = Test-FieldOpsAIAvailability
        $a.HasApiKey | Should -BeOfType [bool]
        ($a | ConvertTo-Json -Depth 5) | Should -Not -Match 'unit-test-key-value'
    }

    It 'records which model was used' {
        $r = Invoke-FieldOpsAI -Prompt 'test' -TaskTier 'Narration'
        $r.Model    | Should -Be 'claude-sonnet-5'
        $r.TaskTier | Should -Be 'Narration'
    }
}
