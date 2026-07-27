#Requires -Version 5.1
<#
    FieldOps Pro - Phase 6, Stream 6.5 (PR 5b-2a: failure detail)

    Tests for HttpStatus and FailureDetail on the AI client result object.

    WHY THESE FIELDS EXIST

    PowerShell 5.1's Invoke-RestMethod throws a WebException on non-2xx, and
    its .Message is generic: "The remote server returned an error: (400) Bad
    Request." The reason an operator can act on -- "your credit balance is too
    low" -- is in the response body, which is discarded unless it is read off
    the exception stream.

    Before the 6.5 reroute, Invoke-ComplianceDiff carried its own body parser
    (Get-ApiErrorDetail) to recover that reason and turn it into console
    guidance: add credits, check your key, you are rate limited. Routing every
    call through the client without these fields would have deleted that
    guidance from a field-deployed diagnostic tool -- a regression dressed up
    as a refactor. These tests are what stops that.

    THE CONTRACT UNDER TEST

    FailureReason stays a closed vocabulary and remains the only field callers
    branch on. FailureDetail and HttpStatus are advisory: display-only, and
    always safe to show, because redaction is applied unconditionally on the
    way into the result object rather than at each call site.

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
            Success=$true; StatusCode=200; ErrorMessage=''; ErrorDetail=''
            Body=[PSCustomObject]@{
                content = @([PSCustomObject]@{ type='text'; text=$Text })
                usage   = [PSCustomObject]@{ input_tokens=$In; output_tokens=$Out }
            }
        }
    }
    function New-ErrorHttp {
        param([int]$Status, [string]$Message = 'error', [string]$Detail = '')
        [PSCustomObject]@{
            Success=$false; StatusCode=$Status; Body=$null
            ErrorMessage=$Message; ErrorDetail=$Detail
        }
    }
}

AfterAll {
    Remove-Module 'FieldOps-AIClient' -Force -ErrorAction SilentlyContinue
}

# ==============================================================================
Describe 'Error body parsing (6.5-R12)' -Tag 'Fast' {

    It 'extracts the message from the Anthropic error envelope' {
        InModuleScope 'FieldOps-AIClient' {
            $body = '{"type":"error","error":{"type":"invalid_request_error","message":"Your credit balance is too low to access the Anthropic API."}}'
            ConvertFrom-AIErrorBody -Body $body |
                Should -Be 'Your credit balance is too low to access the Anthropic API.'
        }
    }

    It 'returns a bounded slice when the body is not JSON' {
        InModuleScope 'FieldOps-AIClient' {
            # A proxy or gateway between the technician and the API returns HTML,
            # not JSON. Something is better than nothing here: the operator needs
            # to see that a captive portal is in the way.
            $body = '<html><body>502 Bad Gateway</body></html>'
            $out = ConvertFrom-AIErrorBody -Body $body
            $out | Should -Match '502 Bad Gateway'
        }
    }

    It 'caps a huge body rather than carrying it into the result object' {
        InModuleScope 'FieldOps-AIClient' {
            $body = 'x' * 5000
            $out = ConvertFrom-AIErrorBody -Body $body
            $out.Length | Should -BeLessOrEqual 300
        }
    }

    It 'returns empty for an empty body' {
        InModuleScope 'FieldOps-AIClient' {
            ConvertFrom-AIErrorBody -Body ''   | Should -Be ''
            ConvertFrom-AIErrorBody -Body $null | Should -Be ''
        }
    }

    It 'returns empty for JSON that is not an error envelope' {
        InModuleScope 'FieldOps-AIClient' {
            # Valid JSON, no error.message: fall through to the slice path, which
            # still yields the raw text rather than a misleading empty string.
            $out = ConvertFrom-AIErrorBody -Body '{"ok":true}'
            $out | Should -Match 'ok'
        }
    }
}

# ==============================================================================
Describe 'Key redaction is unconditional (6.5-R12)' -Tag 'Fast' {

    It 'redacts an Anthropic key echoed back inside an error message' {
        InModuleScope 'FieldOps-AIClient' {
            $leak = '{"error":{"message":"invalid x-api-key: sk-ant-api03-AAAABBBBCCCCDDDDEEEEFFFFGGGGHHHHIIIIJJJJKKKKLLLLMMMM"}}'
            $out = ConvertFrom-AIErrorBody -Body $leak
            $out | Should -Not -Match 'sk-ant-api03-AAAA'
            $out | Should -Match 'REDACTED'
        }
    }

    It 'redacts a key in a non-JSON body too' {
        InModuleScope 'FieldOps-AIClient' {
            $out = ConvertFrom-AIErrorBody -Body 'auth failed for sk-ant-api03-ZZZZYYYYXXXXWWWWVVVVUUUUTTTT'
            $out | Should -Not -Match 'ZZZZYYYY'
            $out | Should -Match 'REDACTED'
        }
    }

    It 'redacts at the result boundary even if a detail slips through unredacted' {
        InModuleScope 'FieldOps-AIClient' {
            # Belt-and-braces: New-AIResult redacts on the way in, so no future
            # caller can construct a result carrying a key by passing one here.
            $r = New-AIResult -FailureDetail 'token sk-ant-api03-QQQQWWWWEEEERRRRTTTTYYYYUUUU rejected'
            $r.FailureDetail | Should -Not -Match 'QQQQWWWW'
            $r.FailureDetail | Should -Match 'REDACTED'
        }
    }

    It 'leaves ordinary text untouched' {
        InModuleScope 'FieldOps-AIClient' {
            Get-AIRedactedText -Text 'rate limited, retry in 60s' |
                Should -Be 'rate limited, retry in 60s'
        }
    }
}

# ==============================================================================
Describe 'Detail propagates to the result object' -Tag 'Fast' {

    It 'carries status and detail on a non-transient failure' {
        InModuleScope 'FieldOps-AIClient' {
            Mock Invoke-AIHttpRequest {
                [PSCustomObject]@{
                    Success=$false; StatusCode=400; Body=$null
                    ErrorMessage='The remote server returned an error: (400) Bad Request.'
                    ErrorDetail='Your credit balance is too low to access the Anthropic API.'
                }
            }
            Mock Get-AIApiKey { 'sk-ant-api03-testtesttesttesttesttesttesttest' }

            $r = Invoke-FieldOpsAICall -Prompt 'hello' -TaskTier 'Narration'

            $r.Success       | Should -BeFalse
            $r.FailureReason | Should -Be 'NonTransientFailure'
            $r.HttpStatus    | Should -Be 400
            $r.FailureDetail | Should -Match 'credit balance'
        }
    }

    It 'carries detail from the final attempt when transient retries are exhausted' {
        InModuleScope 'FieldOps-AIClient' {
            Mock Invoke-AIHttpRequest {
                [PSCustomObject]@{
                    Success=$false; StatusCode=429; Body=$null
                    ErrorMessage='429'
                    ErrorDetail='Number of request tokens has exceeded your per-minute rate limit.'
                }
            }
            Mock Get-AIApiKey { 'sk-ant-api03-testtesttesttesttesttesttesttest' }
            Mock Get-AIRetryDelaySeconds { 0 }   # keep the suite fast

            $r = Invoke-FieldOpsAICall -Prompt 'hello' -TaskTier 'Narration'

            $r.FailureReason | Should -Be 'TransientFailureRetriesExhausted'
            $r.HttpStatus    | Should -Be 429
            $r.FailureDetail | Should -Match 'rate limit'
        }
    }

    It 'carries detail from the last candidate when the whole chain 404s' {
        InModuleScope 'FieldOps-AIClient' {
            Mock Invoke-AIHttpRequest {
                [PSCustomObject]@{
                    Success=$false; StatusCode=404; Body=$null
                    ErrorMessage='404'
                    ErrorDetail='model: claude-opus-4-8'
                }
            }
            Mock Get-AIApiKey { 'sk-ant-api03-testtesttesttesttesttesttesttest' }

            $r = Invoke-FieldOpsAICall -Prompt 'hello' -TaskTier 'Narration'

            $r.FailureReason | Should -Be 'ModelUnavailable'
            $r.HttpStatus    | Should -Be 404
            $r.FailureDetail | Should -Match 'model'
        }
    }

    It 'reports HttpStatus 200 and no detail on success' {
        InModuleScope 'FieldOps-AIClient' {
            Mock Invoke-AIHttpRequest {
                [PSCustomObject]@{
                    Success=$true; StatusCode=200; ErrorMessage=''; ErrorDetail=''
                    Body=[PSCustomObject]@{
                        content = @([PSCustomObject]@{ type='text'; text='fine' })
                        usage   = [PSCustomObject]@{ input_tokens=10; output_tokens=5 }
                    }
                }
            }
            Mock Get-AIApiKey { 'sk-ant-api03-testtesttesttesttesttesttesttest' }

            $r = Invoke-FieldOpsAICall -Prompt 'hello' -TaskTier 'Narration'

            $r.Success       | Should -BeTrue
            $r.HttpStatus    | Should -Be 200
            $r.FailureDetail | Should -Be ''
        }
    }
}

# ==============================================================================
Describe 'Failures that never reached the network report status 0' -Tag 'Fast' {

    It 'reports 0 when no API key is configured' {
        InModuleScope 'FieldOps-AIClient' {
            Mock Get-AIApiKey { '' }
            $r = Invoke-FieldOpsAICall -Prompt 'hello' -TaskTier 'Narration'

            $r.FailureReason | Should -Be 'NoApiKey'
            # 0 is the signal "we never asked" -- distinct from any real status,
            # so a call site can tell a config problem from a provider problem.
            $r.HttpStatus    | Should -Be 0
            $r.FailureDetail | Should -Be ''
        }
    }

    It 'reports 0 when the cost ceiling refuses the call' {
        InModuleScope 'FieldOps-AIClient' {
            Mock Get-AIApiKey { 'sk-ant-api03-testtesttesttesttesttesttesttest' }
            Mock Invoke-AIHttpRequest { throw 'the transport must not be reached' }

            $r = Invoke-FieldOpsAICall -Prompt ('x' * 20000) -TaskTier 'Reasoning' -MaxCostUSD 0.0001

            $r.Success    | Should -BeFalse
            $r.HttpStatus | Should -Be 0
        }
    }
}

# ==============================================================================
Describe 'Existing result contract is unchanged (additive only)' -Tag 'Fast' {

    It 'still exposes every field call sites already depend on' {
        InModuleScope 'FieldOps-AIClient' {
            $r = New-AIResult
            $names = @($r.PSObject.Properties.Name)
            foreach ($f in @('Success','Response','FailureReason','Model','TaskTier',
                             'CostUSD','EstimatedCostUSD','InputTokens','OutputTokens',
                             'DurationMs','RetryCount','SessionCostUSD','Severity',
                             'NeedsHumanReview','PlaybookRef','PlaybookValid',
                             'AuditRecordPath','AuditRecordSha256')) {
                $names | Should -Contain $f
            }
        }
    }

    It 'defaults the new fields so callers built before this PR still work' {
        InModuleScope 'FieldOps-AIClient' {
            $r = New-AIResult
            $r.HttpStatus    | Should -Be 0
            $r.FailureDetail | Should -Be ''
        }
    }

    It 'tolerates a transport mock that predates ErrorDetail' {
        InModuleScope 'FieldOps-AIClient' {
            # Every 6.5 test written before this PR returns a transport object
            # with no ErrorDetail property. Those must keep passing untouched.
            Mock Invoke-AIHttpRequest {
                [PSCustomObject]@{ Success=$false; StatusCode=400; Body=$null; ErrorMessage='Bad Request' }
            }
            Mock Get-AIApiKey { 'sk-ant-api03-testtesttesttesttesttesttesttest' }

            $r = Invoke-FieldOpsAICall -Prompt 'hello' -TaskTier 'Narration'

            $r.FailureReason | Should -Be 'NonTransientFailure'
            $r.FailureDetail | Should -Be ''
        }
    }
}
