#Requires -Version 5.1
<#
    FieldOps Pro - Phase 6, Stream 6.5 (PR 3: audit logging)

    Tests for the audit layer added to FieldOps-AIClient.psm1.

    WHAT AN AUDITOR ACTUALLY CHECKS

    An audit trail is a claim the product makes about itself, so these tests
    verify what a customer's compliance auditor would verify, not merely that a
    writer function ran:

      1. A record exists for EVERY call, success or failure. The failure paths
         are the ones an auditor reads, and the ones easiest to leave
         unlogged, so they are tested explicitly.
      2. Records conform to the published schema (6.5-D2), including the field
         set and the severity enum.
      3. The prompt hash is reproducible from the original text by the exact
         procedure the schema documents. A hash nobody can recompute is
         decorative -- the same failure the report integrity signature had.
      4. The API key never reaches the log (6.5-R12 / D13).

    These run offline: the transport is mocked, so a deterministic response
    lets the token, cost and hash assertions be exact.
#>

BeforeAll {
    $script:TestsRoot  = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:RepoRoot   = Split-Path $script:TestsRoot -Parent
    $script:ModulePath = Join-Path $script:RepoRoot 'SCRIPTS\AI\FieldOps-AIClient.psm1'
    $script:SchemaPath = Join-Path $script:RepoRoot 'schemas\ai-audit-record.json'

    Import-Module $script:ModulePath -Force -DisableNameChecking

    $script:Schema = $null
    if (Test-Path $script:SchemaPath) {
        $script:Schema = Get-Content $script:SchemaPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }

    function New-TempLogDir {
        $d = Join-Path $env:TEMP ('fo-audit-test-' + [guid]::NewGuid().ToString('N').Substring(0,10))
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        return $d
    }

    function Get-LastRecord {
        param([string]$LogDir)
        $path = Join-Path $LogDir 'ai-audit.jsonl'
        if (-not (Test-Path $path)) { return $null }
        $last = Get-Content $path -Tail 1
        if (-not $last) { return $null }
        return ($last | ConvertFrom-Json)
    }

    function Get-Sha256HexNoBom {
        param([string]$Text)
        $enc = New-Object System.Text.UTF8Encoding($false)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        return (([BitConverter]::ToString($sha.ComputeHash($enc.GetBytes($Text)))) -replace '-','').ToLower()
    }
}

AfterAll {
    Remove-Module 'FieldOps-AIClient' -Force -ErrorAction SilentlyContinue
}

# ==============================================================================
Describe 'Audit schema is published and well-formed (6.5-D2)' -Tag 'Fast' {

    It 'the schema file exists and parses' {
        Test-Path $script:SchemaPath | Should -BeTrue
        $script:Schema | Should -Not -BeNullOrEmpty
    }

    It 'pins schemaVersion to 1.1' {
        $script:Schema.properties.schemaVersion.const | Should -Be '1.1'
    }

    It 'forbids unspecified fields' {
        # additionalProperties:false is what makes the record a contract 6.3
        # can rely on. Without it, a stray field would validate silently.
        $script:Schema.additionalProperties | Should -Be $false
    }

    It 'includes UNCLASSIFIED so PR3 records validate before the PR4 classifier' {
        $script:Schema.properties.severity.enum | Should -Contain 'UNCLASSIFIED'
    }

    It 'specifies the hash encoding in the field description' {
        # The exact input to the hash must be documented or an auditor cannot
        # reproduce it. This asserts the specification is present, not merely
        # that a 64-hex pattern is required.
        $script:Schema.properties.prompt_sha256.description | Should -Match 'WITHOUT'
        $script:Schema.properties.prompt_sha256.description | Should -Match '(?i)utf-8'
    }
}

# ==============================================================================
Describe 'Every call writes a conformant record (6.5-R6)' -Tag 'Fast' {

    BeforeEach {
        Reset-FieldOpsAISession
        Mock -ModuleName 'FieldOps-AIClient' Get-AIApiKey { 'unit-test-key-value' }
        Mock -ModuleName 'FieldOps-AIClient' Get-AITechnicianId { 'testtech0001' }
        Mock -ModuleName 'FieldOps-AIClient' Invoke-AIHttpRequest {
            [PSCustomObject]@{
                Success=$true; StatusCode=200; ErrorMessage=''
                Body=[PSCustomObject]@{
                    content = @([PSCustomObject]@{ type='text'; text='mock analysis result' })
                    usage   = [PSCustomObject]@{ input_tokens=120; output_tokens=64 }
                }
            }
        }
        $script:LogDir = New-TempLogDir
    }

    AfterEach {
        Remove-Item $script:LogDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'writes a record for a successful call' {
        $r = Invoke-FieldOpsAI -Prompt 'analyse this' -CallingContext 'Test/Success' `
                -TaskTier 'Narration' -LogsDir $script:LogDir
        $r.AuditRecordPath | Should -Not -BeNullOrEmpty

        $rec = Get-LastRecord -LogDir $script:LogDir
        $rec              | Should -Not -BeNullOrEmpty
        $rec.success      | Should -BeTrue
        $rec.ctx          | Should -Be 'Test/Success'
        $rec.model        | Should -Be 'claude-sonnet-5'
        $rec.in_tok       | Should -Be 120
        $rec.out_tok      | Should -Be 64
    }

    It 'writes a record for a ceiling-refused call' {
        # The critical case: the call never reached the network, but the audit
        # trail must still show it was attempted and why it was refused.
        $r = Invoke-FieldOpsAI -Prompt ('x' * 400000) -CallingContext 'Test/Refused' `
                -TaskTier 'Reasoning' -MaxCostUSD 0.01 -LogsDir $script:LogDir
        $r.AuditRecordPath | Should -Not -BeNullOrEmpty

        $rec = Get-LastRecord -LogDir $script:LogDir
        $rec.success        | Should -BeFalse
        $rec.failure_reason | Should -Be 'EstimateExceedsCeiling'
        $rec.ctx            | Should -Be 'Test/Refused'
    }

    It 'writes a record for a non-transient API failure' {
        Mock -ModuleName 'FieldOps-AIClient' Invoke-AIHttpRequest {
            [PSCustomObject]@{ Success=$false; StatusCode=401; Body=$null; ErrorMessage='Unauthorized' }
        }
        $r = Invoke-FieldOpsAI -Prompt 'test' -CallingContext 'Test/401' `
                -TaskTier 'Classification' -LogsDir $script:LogDir
        $rec = Get-LastRecord -LogDir $script:LogDir
        $rec              | Should -Not -BeNullOrEmpty
        $rec.success      | Should -BeFalse
        $rec.failure_reason | Should -Be 'NonTransientFailure'
    }

    It 'the record carries every field the schema requires' {
        $null = Invoke-FieldOpsAI -Prompt 'test' -TaskTier 'Narration' -LogsDir $script:LogDir
        $rec = Get-LastRecord -LogDir $script:LogDir
        $names = @($rec.PSObject.Properties.Name)
        foreach ($req in @($script:Schema.required)) {
            $names | Should -Contain $req
        }
    }

    It 'the record contains no field the schema forbids' {
        $null = Invoke-FieldOpsAI -Prompt 'test' -TaskTier 'Narration' -LogsDir $script:LogDir
        $rec = Get-LastRecord -LogDir $script:LogDir
        $allowed = @($script:Schema.properties.PSObject.Properties.Name)
        $extra = @($rec.PSObject.Properties.Name | Where-Object { $allowed -notcontains $_ })
        ($extra -join ', ') | Should -Be ''
    }

    It 'severity is a value the schema enum permits' {
        $null = Invoke-FieldOpsAI -Prompt 'test' -TaskTier 'Narration' -LogsDir $script:LogDir
        $rec = Get-LastRecord -LogDir $script:LogDir
        @($script:Schema.properties.severity.enum) | Should -Contain $rec.severity
    }

    It 'writes exactly one line per call' {
        $null = Invoke-FieldOpsAI -Prompt 'one'   -TaskTier 'Classification' -LogsDir $script:LogDir
        $null = Invoke-FieldOpsAI -Prompt 'two'   -TaskTier 'Classification' -LogsDir $script:LogDir
        $null = Invoke-FieldOpsAI -Prompt 'three' -TaskTier 'Classification' -LogsDir $script:LogDir
        $lines = @(Get-Content (Join-Path $script:LogDir 'ai-audit.jsonl'))
        $lines.Count | Should -Be 3
        foreach ($l in $lines) { { $l | ConvertFrom-Json } | Should -Not -Throw }
    }

    It 'honours -NoAudit by writing nothing' {
        $r = Invoke-FieldOpsAI -Prompt 'test' -TaskTier 'Narration' -LogsDir $script:LogDir -NoAudit
        $r.AuditRecordPath | Should -BeNullOrEmpty
        Test-Path (Join-Path $script:LogDir 'ai-audit.jsonl') | Should -BeFalse
    }
}

# ==============================================================================
Describe 'Hashes are reproducible by an auditor (6.5-D2)' -Tag 'Fast' {

    BeforeEach {
        Reset-FieldOpsAISession
        Mock -ModuleName 'FieldOps-AIClient' Get-AIApiKey { 'unit-test-key-value' }
        Mock -ModuleName 'FieldOps-AIClient' Get-AITechnicianId { 'testtech0001' }
        Mock -ModuleName 'FieldOps-AIClient' Invoke-AIHttpRequest {
            [PSCustomObject]@{
                Success=$true; StatusCode=200; ErrorMessage=''
                Body=[PSCustomObject]@{
                    content = @([PSCustomObject]@{ type='text'; text='deterministic response text' })
                    usage   = [PSCustomObject]@{ input_tokens=50; output_tokens=25 }
                }
            }
        }
        $script:LogDir = New-TempLogDir
    }

    AfterEach { Remove-Item $script:LogDir -Recurse -Force -ErrorAction SilentlyContinue }

    It 'prompt_sha256 recomputes from the original prompt' {
        $prompt = 'Analyse the compliance posture of this workstation against ANSSI rule 12.'
        $null = Invoke-FieldOpsAI -Prompt $prompt -TaskTier 'Reasoning' `
                    -MaxCostUSD 5.0 -LogsDir $script:LogDir
        $rec = Get-LastRecord -LogDir $script:LogDir
        $rec.prompt_sha256 | Should -Be (Get-Sha256HexNoBom -Text $prompt)
    }

    It 'response_sha256 recomputes from the response text' {
        $null = Invoke-FieldOpsAI -Prompt 'test' -TaskTier 'Narration' -LogsDir $script:LogDir
        $rec = Get-LastRecord -LogDir $script:LogDir
        $rec.response_sha256 | Should -Be (Get-Sha256HexNoBom -Text 'deterministic response text')
    }

    It 'system_sha256 recomputes when a system prompt is sent' {
        $sys = 'You are a compliance analysis assistant.'
        $null = Invoke-FieldOpsAI -Prompt 'test' -SystemPrompt $sys `
                    -TaskTier 'Narration' -LogsDir $script:LogDir
        $rec = Get-LastRecord -LogDir $script:LogDir
        $rec.system_sha256 | Should -Be (Get-Sha256HexNoBom -Text $sys)
    }

    It 'system_sha256 is null when no system prompt is sent' {
        $null = Invoke-FieldOpsAI -Prompt 'test' -TaskTier 'Narration' -LogsDir $script:LogDir
        $rec = Get-LastRecord -LogDir $script:LogDir
        $rec.system_sha256 | Should -BeNullOrEmpty
    }

    It 'every hash present is lowercase 64-hex' {
        $null = Invoke-FieldOpsAI -Prompt 'test' -SystemPrompt 'sys' `
                    -TaskTier 'Narration' -LogsDir $script:LogDir
        $rec = Get-LastRecord -LogDir $script:LogDir
        foreach ($h in @($rec.prompt_sha256, $rec.system_sha256, $rec.response_sha256)) {
            if ($h) { $h | Should -Match '^[a-f0-9]{64}$' }
        }
    }
}

# ==============================================================================
Describe 'API key never reaches the audit log (6.5-R12 / D13)' -Tag 'Fast' {

    It 'no record contains the key, even when the key appears in the prompt' {
        Reset-FieldOpsAISession
        # The key value used here is a test literal, deliberately not in the
        # real key format, so the D13 audit scanner does not flag this file.
        Mock -ModuleName 'FieldOps-AIClient' Get-AIApiKey { 'secret-key-abc123' }
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
        $log = New-TempLogDir
        try {
            # Even if a careless prompt echoes the key, only its hash is stored.
            $null = Invoke-FieldOpsAI -Prompt 'my key is secret-key-abc123' `
                        -TaskTier 'Narration' -LogsDir $log
            $raw = Get-Content (Join-Path $log 'ai-audit.jsonl') -Raw
            $raw | Should -Not -Match 'secret-key-abc123'
        } finally {
            Remove-Item $log -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ==============================================================================
Describe 'Audit write failure does not fail the call (6.5-R10)' -Tag 'Fast' {

    It 'returns the response with a null audit path when the write fails' {
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
        Mock -ModuleName 'FieldOps-AIClient' Write-AIAuditRecord { $null }

        # The API call already happened and was billed. Discarding its response
        # because the log could not be written would waste what the operator
        # paid for. The response comes back; the null path signals the gap.
        # Assign OUTSIDE the -Not -Throw scriptblock: Pester runs that block in
        # its own scope, so an assignment inside it does not escape and $r
        # stays null. (Same scope trap fixed in the PR2 client tests.)
        $r = Invoke-FieldOpsAI -Prompt 'test' -TaskTier 'Narration'
        $r                 | Should -Not -BeNullOrEmpty
        $r.Success         | Should -BeTrue
        $r.Response        | Should -Be 'ok'
        $r.AuditRecordPath | Should -BeNullOrEmpty
        { Invoke-FieldOpsAI -Prompt 'test' -TaskTier 'Narration' } | Should -Not -Throw
    }
}
