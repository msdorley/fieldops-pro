#Requires -Version 5.1
<#
    FieldOps Pro - Phase 6, Stream 6.5 (PR6a: playbook reference validation)

    Tests for 6.5-R8: when -ExpectPlaybookReference is set, the client resolves
    the cited playbook and checks it conforms.

    WHAT THE CONTRACT ACTUALLY IS

    PlaybookValid is THREE-STATE, and most of these tests exist to pin that:

        $null   not checked -- the caller did not ask
        $false  checked, and the citation does not hold up
        $true   checked and sound

    A caller collapsing $null and $false treats every unvalidated call as
    clean, which is the failure this field exists to prevent. So "no reference
    when one was expected" is $false, not $null: the check ran and the answer
    is no.

    The front-matter parser is fail-closed by design (PS 5.1 has no YAML
    parser and the toolkit runs air-gapped). Tests below assert that a front
    matter outside the supported subset yields $null rather than a partial
    parse that might accidentally satisfy the required keys.
#>

BeforeAll {
    $script:TestsRoot  = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:RepoRoot   = Split-Path $script:TestsRoot -Parent
    $script:ModulePath = Join-Path $script:RepoRoot 'SCRIPTS\AI\FieldOps-AIClient.psm1'
    Import-Module $script:ModulePath -Force -DisableNameChecking

    function New-TestPlaybookDir {
        $d = Join-Path ([IO.Path]::GetTempPath()) ("fieldops-pb-" + [Guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $d -Force
        return $d
    }

    function Set-TestPlaybook {
        param([string]$Dir, [string]$Id, [string]$Body)
        $path = Join-Path $Dir "$Id.md"
        Set-Content -LiteralPath $path -Value $Body -Encoding UTF8
        return $path
    }

    $script:GoodFrontMatter = @'
---
id: RB-AV-001
title: Re-enable Microsoft Defender real-time protection
category: AV
severity: high
prerequisites:
  - Administrator rights
relatedRules:
  anssi: [R8]
estimatedDurationMinutes: 5
revertable: true
schemaVersion: "1.0"
---

# Body
'@
}

AfterAll {
    Remove-Module 'FieldOps-AIClient' -Force -ErrorAction SilentlyContinue
}

# ==============================================================================
Describe 'Reference extraction' -Tag 'Fast' {

    It 'finds a playbook id embedded in prose' {
        InModuleScope 'FieldOps-AIClient' {
            Get-AIPlaybookReference -Text 'Recommend following RB-AV-001 to restore protection.' |
                Should -Be 'RB-AV-001'
        }
    }

    It 'accepts the full 2-4 letter category range' {
        InModuleScope 'FieldOps-AIClient' {
            Get-AIPlaybookReference -Text 'see RB-BL-012'   | Should -Be 'RB-BL-012'
            Get-AIPlaybookReference -Text 'see RB-AUD-042'  | Should -Be 'RB-AUD-042'
            Get-AIPlaybookReference -Text 'see RB-CRED-003' | Should -Be 'RB-CRED-003'
        }
    }

    It 'rejects a five-letter category, which the pattern cannot express' {
        InModuleScope 'FieldOps-AIClient' {
            # Regression guard for a real contradiction in the design doc: it
            # listed RB-AUDIT-* as a category next to a 2-4 letter pattern that
            # forbids it, and schemas/ai-audit-record.json had already shipped
            # the 2-4 pattern for playbook_ref. The category was renamed to AUD.
            # If RB-AUDIT-* ever parses again, the two have drifted apart again.
            Get-AIPlaybookReference -Text 'see RB-AUDIT-042' | Should -Be ''
        }
    }

    It 'uses the same id pattern the audit record schema publishes' {
        # The two schemas describe the same identifier. They must agree, or a
        # reference the client accepts writes an audit record that fails
        # validation -- and the failure surfaces at audit time, not here.
        $auditSchema = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'schemas\ai-audit-record.json') -Raw | ConvertFrom-Json
        $pbSchema    = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'schemas\playbook-frontmatter.json') -Raw | ConvertFrom-Json
        $pbSchema.properties.id.pattern | Should -Be $auditSchema.properties.playbook_ref.pattern
    }

    It 'returns empty when nothing is cited' {
        InModuleScope 'FieldOps-AIClient' {
            Get-AIPlaybookReference -Text 'Everything looks fine.' | Should -Be ''
            Get-AIPlaybookReference -Text ''                       | Should -Be ''
        }
    }

    It 'ignores near-misses that are not valid ids' {
        InModuleScope 'FieldOps-AIClient' {
            Get-AIPlaybookReference -Text 'RB-A-001'     | Should -Be ''   # 1-letter category
            Get-AIPlaybookReference -Text 'RB-AV-01'     | Should -Be ''   # 2-digit serial
            Get-AIPlaybookReference -Text 'rb-av-001'    | Should -Be ''   # lowercase
        }
    }

    It 'takes the first citation when several appear' {
        InModuleScope 'FieldOps-AIClient' {
            # Documented behaviour: a scalar field cannot honestly represent
            # several, and picking arbitrarily would be worse than picking first.
            Get-AIPlaybookReference -Text 'RB-FW-002 then RB-AV-001' | Should -Be 'RB-FW-002'
        }
    }
}

# ==============================================================================
Describe 'Front matter parsing is fail-closed' -Tag 'Fast' {

    It 'parses the supported subset' {
        InModuleScope 'FieldOps-AIClient' -Parameters @{ T = $script:GoodFrontMatter } {
            param($T)
            $fm = ConvertFrom-AIPlaybookFrontMatter -Text $T
            $fm                             | Should -Not -BeNullOrEmpty
            $fm['id']                       | Should -Be 'RB-AV-001'
            $fm['revertable']               | Should -BeTrue
            $fm['estimatedDurationMinutes'] | Should -Be 5
            $fm['schemaVersion']            | Should -Be '1.0'
            @($fm['prerequisites']).Count   | Should -Be 1
            $fm['relatedRules']['anssi']    | Should -Be @('R8')
        }
    }

    It 'keeps a quoted version as a string, not a double' {
        InModuleScope 'FieldOps-AIClient' -Parameters @{ T = $script:GoodFrontMatter } {
            param($T)
            # "1.0" parsed as a number would render as "1" and fail the const
            # check for reasons that look nothing like the actual cause.
            $fm = ConvertFrom-AIPlaybookFrontMatter -Text $T
            $fm['schemaVersion'] | Should -BeOfType [string]
        }
    }

    It 'returns null when the front matter fence is missing' {
        InModuleScope 'FieldOps-AIClient' {
            ConvertFrom-AIPlaybookFrontMatter -Text "# Just a heading`nno front matter" |
                Should -BeNullOrEmpty
        }
    }

    It 'returns null when the fence is never closed' {
        InModuleScope 'FieldOps-AIClient' {
            ConvertFrom-AIPlaybookFrontMatter -Text "---`nid: RB-AV-001`ntitle: x" |
                Should -BeNullOrEmpty
        }
    }

    It 'returns null on tab indentation' {
        InModuleScope 'FieldOps-AIClient' {
            $t = "---`nprerequisites:`n`t- Administrator rights`n---`n"
            ConvertFrom-AIPlaybookFrontMatter -Text $t | Should -BeNullOrEmpty
        }
    }

    It 'returns null on a nested container beyond the supported depth' {
        InModuleScope 'FieldOps-AIClient' {
            $t = "---`nrelatedRules:`n  anssi:`n    deep: [R8]`n---`n"
            ConvertFrom-AIPlaybookFrontMatter -Text $t | Should -BeNullOrEmpty
        }
    }

    It 'returns null on a garbage line rather than skipping it' {
        InModuleScope 'FieldOps-AIClient' {
            # Skipping would risk a partial parse that still has every required
            # key and therefore validates -- the exact outcome to avoid.
            $t = "---`nid: RB-AV-001`nthis line is not yaml`n---`n"
            ConvertFrom-AIPlaybookFrontMatter -Text $t | Should -BeNullOrEmpty
        }
    }
}

# ==============================================================================
Describe 'Conformance checks' -Tag 'Fast' {

    It 'accepts the reference playbook shipped in the repo' {
        $dir = Join-Path $script:RepoRoot 'PLAYBOOKS'
        $r = InModuleScope 'FieldOps-AIClient' -Parameters @{ D = $dir } {
            param($D)
            Test-AIPlaybookReference -PlaybookId 'RB-AV-001' -PlaybookDir $D
        }
        $r.Valid | Should -BeTrue -Because "RB-AV-001.md ships as the canonical example: $($r.Reason)"
    }

    It 'rejects a playbook that does not exist' {
        $dir = New-TestPlaybookDir
        try {
            $r = InModuleScope 'FieldOps-AIClient' -Parameters @{ D = $dir } {
                param($D)
                Test-AIPlaybookReference -PlaybookId 'RB-AV-999' -PlaybookDir $D
            }
            $r.Valid  | Should -BeFalse
            $r.Reason | Should -Match 'not found'
        } finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'rejects a file whose front matter id disagrees with its filename' {
        $dir = New-TestPlaybookDir
        try {
            # The drift that would make a citation resolve to the wrong procedure.
            $null = Set-TestPlaybook -Dir $dir -Id 'RB-AV-002' -Body $script:GoodFrontMatter
            $r = InModuleScope 'FieldOps-AIClient' -Parameters @{ D = $dir } {
                param($D)
                Test-AIPlaybookReference -PlaybookId 'RB-AV-002' -PlaybookDir $D
            }
            $r.Valid  | Should -BeFalse
            $r.Reason | Should -Match 'does not match requested'
        } finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'rejects a category that disagrees with the id segment' {
        InModuleScope 'FieldOps-AIClient' {
            $fm = @{
                id='RB-AV-001'; title='A sufficiently long title'; category='FW'
                severity='high'; estimatedDurationMinutes=5; revertable=$true
                schemaVersion='1.0'
            }
            $r = Test-AIPlaybookConformant -FrontMatter $fm
            $r.Ok     | Should -BeFalse
            $r.Reason | Should -Match 'disagrees with id segment'
        }
    }

    It 'names the specific missing key' {
        InModuleScope 'FieldOps-AIClient' {
            $fm = @{ id='RB-AV-001'; title='A sufficiently long title'; category='AV' }
            $r = Test-AIPlaybookConformant -FrontMatter $fm
            $r.Ok     | Should -BeFalse
            $r.Reason | Should -Match "missing required key 'severity'"
        }
    }

    It 'rejects out-of-range duration and non-boolean revertable' {
        InModuleScope 'FieldOps-AIClient' {
            $base = @{
                id='RB-AV-001'; title='A sufficiently long title'; category='AV'
                severity='high'; estimatedDurationMinutes=5; revertable=$true
                schemaVersion='1.0'
            }
            $tooLong = $base.Clone(); $tooLong['estimatedDurationMinutes'] = 900
            (Test-AIPlaybookConformant -FrontMatter $tooLong).Ok | Should -BeFalse

            $notBool = $base.Clone(); $notBool['revertable'] = 'yes'
            (Test-AIPlaybookConformant -FrontMatter $notBool).Ok | Should -BeFalse
        }
    }

    It 'rejects a deprecated playbook as a citation but still resolves it' {
        InModuleScope 'FieldOps-AIClient' {
            # Resolvable on purpose so historical audit records stay readable.
            $fm = @{
                id='RB-AV-001'; title='A sufficiently long title'; category='AV'
                severity='high'; estimatedDurationMinutes=5; revertable=$true
                schemaVersion='1.0'; deprecated=$true
            }
            $r = Test-AIPlaybookConformant -FrontMatter $fm
            $r.Ok     | Should -BeFalse
            $r.Reason | Should -Match 'deprecated'
        }
    }
}

# ==============================================================================
Describe 'Schema and validator cannot drift apart' -Tag 'Fast' {

    It 'enforces exactly the required set published in the JSON Schema' {
        $schemaPath = Join-Path $script:RepoRoot 'schemas\playbook-frontmatter.json'
        Test-Path $schemaPath | Should -BeTrue

        $schema = Get-Content -LiteralPath $schemaPath -Raw | ConvertFrom-Json
        $schemaRequired = @($schema.required | Sort-Object)

        $codeRequired = InModuleScope 'FieldOps-AIClient' {
            @($script:PlaybookRequiredKeys | Sort-Object)
        }

        # The schema is the published contract; the code is what actually runs.
        # If they drift, one of them is lying to somebody.
        ($codeRequired -join ',') | Should -Be ($schemaRequired -join ',')
    }

    It 'enforces the same category and severity vocabularies as the schema' {
        $schemaPath = Join-Path $script:RepoRoot 'schemas\playbook-frontmatter.json'
        $schema = Get-Content -LiteralPath $schemaPath -Raw | ConvertFrom-Json

        $codeCats = InModuleScope 'FieldOps-AIClient' { @($script:PlaybookCategories | Sort-Object) }
        $codeSevs = InModuleScope 'FieldOps-AIClient' { @($script:PlaybookSeverities | Sort-Object) }

        ($codeCats -join ',') | Should -Be (@($schema.properties.category.enum | Sort-Object) -join ',')
        ($codeSevs -join ',') | Should -Be (@($schema.properties.severity.enum | Sort-Object) -join ',')
    }

    It 'uses the same id pattern as the schema' {
        $schemaPath = Join-Path $script:RepoRoot 'schemas\playbook-frontmatter.json'
        $schema = Get-Content -LiteralPath $schemaPath -Raw | ConvertFrom-Json
        $codePattern = InModuleScope 'FieldOps-AIClient' { $script:PlaybookIdPattern }
        $codePattern | Should -Be $schema.properties.id.pattern
    }
}

# ==============================================================================
Describe 'PlaybookValid is three-state on the result object (6.5-R8)' -Tag 'Fast' {

    BeforeAll {
        $script:PbDir = Join-Path $script:RepoRoot 'PLAYBOOKS'
    }

    It 'leaves PlaybookRef and PlaybookValid null when the caller does not ask' {
        InModuleScope 'FieldOps-AIClient' {
            Mock Get-AIApiKey { 'sk-ant-api03-testtesttesttesttesttesttesttest' }
            Mock Invoke-AIHttpRequest {
                [PSCustomObject]@{
                    Success=$true; StatusCode=200; ErrorMessage=''; ErrorDetail=''
                    Body=[PSCustomObject]@{
                        content = @([PSCustomObject]@{ type='text'; text='Follow RB-AV-001.' })
                        usage   = [PSCustomObject]@{ input_tokens=10; output_tokens=5 }
                    }
                }
            }
            $r = Invoke-FieldOpsAI -Prompt 'x' -NoAudit
            $r.PlaybookRef   | Should -BeNullOrEmpty
            # $null, NOT $false: unchecked is a different claim from checked-bad.
            $r.PlaybookValid | Should -BeNullOrEmpty
        }
    }

    It 'reports true for a citation that resolves and conforms' {
        InModuleScope 'FieldOps-AIClient' -Parameters @{ D = $script:PbDir } {
            param($D)
            Mock Get-AIApiKey { 'sk-ant-api03-testtesttesttesttesttesttesttest' }
            Mock Invoke-AIHttpRequest {
                [PSCustomObject]@{
                    Success=$true; StatusCode=200; ErrorMessage=''; ErrorDetail=''
                    Body=[PSCustomObject]@{
                        content = @([PSCustomObject]@{ type='text'; text='Recommend RB-AV-001.' })
                        usage   = [PSCustomObject]@{ input_tokens=10; output_tokens=5 }
                    }
                }
            }
            $r = Invoke-FieldOpsAI -Prompt 'x' -ExpectPlaybookReference -PlaybookDir $D -NoAudit
            $r.PlaybookRef   | Should -Be 'RB-AV-001'
            $r.PlaybookValid | Should -BeTrue
        }
    }

    It 'reports false and flags review for a citation that does not resolve' {
        InModuleScope 'FieldOps-AIClient' -Parameters @{ D = $script:PbDir } {
            param($D)
            Mock Get-AIApiKey { 'sk-ant-api03-testtesttesttesttesttesttesttest' }
            Mock Invoke-AIHttpRequest {
                [PSCustomObject]@{
                    Success=$true; StatusCode=200; ErrorMessage=''; ErrorDetail=''
                    Body=[PSCustomObject]@{
                        content = @([PSCustomObject]@{ type='text'; text='Recommend RB-AV-987.' })
                        usage   = [PSCustomObject]@{ input_tokens=10; output_tokens=5 }
                    }
                }
            }
            $r = Invoke-FieldOpsAI -Prompt 'x' -ExpectPlaybookReference -PlaybookDir $D -NoAudit
            $r.PlaybookRef      | Should -Be 'RB-AV-987'
            $r.PlaybookValid    | Should -BeFalse
            # An invented citation is exactly what a human must see.
            $r.NeedsHumanReview | Should -BeTrue
        }
    }

    It 'reports false when a citation was expected but none was given' {
        InModuleScope 'FieldOps-AIClient' -Parameters @{ D = $script:PbDir } {
            param($D)
            Mock Get-AIApiKey { 'sk-ant-api03-testtesttesttesttesttesttesttest' }
            Mock Invoke-AIHttpRequest {
                [PSCustomObject]@{
                    Success=$true; StatusCode=200; ErrorMessage=''; ErrorDetail=''
                    Body=[PSCustomObject]@{
                        content = @([PSCustomObject]@{ type='text'; text='Looks fine to me.' })
                        usage   = [PSCustomObject]@{ input_tokens=10; output_tokens=5 }
                    }
                }
            }
            $r = Invoke-FieldOpsAI -Prompt 'x' -ExpectPlaybookReference -PlaybookDir $D -NoAudit
            $r.PlaybookRef      | Should -BeNullOrEmpty
            $r.PlaybookValid    | Should -BeFalse   # the check ran; the answer is no
            $r.NeedsHumanReview | Should -BeTrue
        }
    }

    It 'does not let severity classification clear a review flag validation raised' {
        InModuleScope 'FieldOps-AIClient' -Parameters @{ D = $script:PbDir } {
            param($D)
            Mock Get-AIApiKey { 'sk-ant-api03-testtesttesttesttesttesttesttest' }
            Mock Invoke-AIHttpRequest {
                [PSCustomObject]@{
                    Success=$true; StatusCode=200; ErrorMessage=''; ErrorDetail=''
                    Body=[PSCustomObject]@{
                        # Benign wording, bad citation: the classifier would say
                        # no review needed, validation says otherwise.
                        content = @([PSCustomObject]@{ type='text'; text='All good, see RB-AV-987.' })
                        usage   = [PSCustomObject]@{ input_tokens=10; output_tokens=5 }
                    }
                }
            }
            $r = Invoke-FieldOpsAI -Prompt 'x' -ExpectPlaybookReference -PlaybookDir $D
            $r.NeedsHumanReview | Should -BeTrue
        }
    }

    It 'writes the reference into the audit record' {
        InModuleScope 'FieldOps-AIClient' -Parameters @{ D = $script:PbDir } {
            param($D)
            $r = New-AIResult -Success $true -Response 'x'
            $r.PlaybookRef   = 'RB-AV-001'
            $r.PlaybookValid = $true
            $rec = New-AIAuditRecord -Result $r -Prompt 'p' -SystemPrompt '' `
                        -CallingContext 'test' -ModelOverride $false
            $rec['playbook_ref']   | Should -Be 'RB-AV-001'
            $rec['playbook_valid'] | Should -BeTrue
        }
    }
}
