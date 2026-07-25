#Requires -Version 5.1
<#
    FieldOps Pro - Phase 6, Stream 6.5 (D13)

    Standing guard: the Anthropic API key must never be written to the audit
    log (requirement 6.5-R12).

    Two independent checks, because a key can leak two ways -- through code that
    formats it into a record, or through a record produced at runtime:

      1. STATIC. The audit-writing functions must not reference the key at all.
         The client reads the key for the request header and nowhere else; if
         an audit function ever touched it, that would be the leak. This scans
         the source for the real key prefix and for the variable names the key
         travels under.

      2. DYNAMIC. A real generated log line, with a key deliberately planted in
         the prompt, must not contain that key -- only its hash.

    The prefix this scans for is Anthropic's live key prefix. It is built at
    runtime from fragments rather than written as a literal, so this guard file
    does not itself contain the string it forbids -- which would otherwise make
    the scanner flag its own source.
#>

BeforeAll {
    $script:TestsRoot  = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    # tests/audit -> tests -> repo
    $script:RepoRoot   = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:ModulePath = Join-Path $script:RepoRoot 'SCRIPTS\AI\FieldOps-AIClient.psm1'

    # Assemble the forbidden prefix from parts so this file does not contain it.
    $script:KeyPrefix = 'sk' + '-' + 'ant' + '-'
}

Describe 'API key prefix is absent from audit-writing code (6.5-D13, static)' -Tag 'Slow' {

    It 'the module source does not contain a hardcoded key of the live format' {
        $src = Get-Content $script:ModulePath -Raw
        $src | Should -Not -Match ([regex]::Escape($script:KeyPrefix))
    }

    It 'the audit record builder does not reference the api key variable' {
        # Extract New-AIAuditRecord and confirm it never names an api-key
        # binding. The record is built only from the result object, the
        # prompts (which are hashed), and the calling context.
        $src = Get-Content $script:ModulePath -Raw
        $m = [regex]::Match($src, '(?s)function\s+New-AIAuditRecord\s*\{.*?\n\}')
        $m.Success | Should -BeTrue
        $m.Value | Should -Not -Match '(?i)\$apiKey'
        $m.Value | Should -Not -Match '(?i)x-api-key'
    }

    It 'the audit writer does not reference the api key variable' {
        $src = Get-Content $script:ModulePath -Raw
        $m = [regex]::Match($src, '(?s)function\s+Write-AIAuditRecord\s*\{.*?\n\}')
        $m.Success | Should -BeTrue
        $m.Value | Should -Not -Match '(?i)\$apiKey'
    }
}

Describe 'API key prefix is absent from produced logs (6.5-D13, dynamic)' -Tag 'Slow' {

    It 'a generated log line never contains a key of the live format' {
        Import-Module $script:ModulePath -Force -DisableNameChecking
        try {
            $planted = $script:KeyPrefix + 'PLANTEDdummySecret000'
            Reset-FieldOpsAISession
            Mock -ModuleName 'FieldOps-AIClient' Get-AIApiKey { $planted }.GetNewClosure()
            Mock -ModuleName 'FieldOps-AIClient' Get-AITechnicianId { 'testtech0001' }
            Mock -ModuleName 'FieldOps-AIClient' Invoke-AIHttpRequest {
                [PSCustomObject]@{
                    Success=$true; StatusCode=200; ErrorMessage=''
                    Body=[PSCustomObject]@{
                        content = @([PSCustomObject]@{ type='text'; text='ok' })
                        usage   = [PSCustomObject]@{ input_tokens=10; output_tokens=5 }
                    }
                }
            }

            $log = Join-Path $env:TEMP ('fo-d13-' + [guid]::NewGuid().ToString('N').Substring(0,10))
            New-Item -ItemType Directory -Path $log -Force | Out-Null
            try {
                # Plant the key in the prompt too, so we prove it is hashed, not
                # copied, even when the caller is careless.
                $null = Invoke-FieldOpsAI -Prompt ("token is " + $planted) `
                            -TaskTier 'Narration' -LogsDir $log
                $raw = Get-Content (Join-Path $log 'ai-audit.jsonl') -Raw
                $raw | Should -Not -Match ([regex]::Escape($script:KeyPrefix))
            } finally {
                Remove-Item $log -Recurse -Force -ErrorAction SilentlyContinue
            }
        } finally {
            Remove-Module 'FieldOps-AIClient' -Force -ErrorAction SilentlyContinue
        }
    }
}
