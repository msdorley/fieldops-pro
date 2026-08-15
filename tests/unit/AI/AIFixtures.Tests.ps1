#Requires -Version 5.1
<#
    FieldOps Pro - Phase 6, Stream 6.5 (6.5-D15, 6.5-D16)

    Tests for the fixtures themselves.

    WHY FIXTURES NEED THEIR OWN TESTS

    Every AI test mocks Invoke-AIHttpRequest, so these fixtures define what the
    entire suite believes the provider returns. A fixture that drifts from the
    transport's real contract does not fail loudly -- it makes every test that
    uses it prove something slightly untrue, and keeps passing while it does so.

    The specific hazard: if New-AIHttpFixture stopped emitting ErrorDetail, the
    credits-and-key guidance tests would still pass (they would simply see an
    empty detail and assert nothing useful), while the behaviour a technician
    depends on quietly broke.
#>

BeforeAll {
    $script:TestsRoot   = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:RepoRoot    = Split-Path $script:TestsRoot -Parent
    $script:FixtureRoot = Join-Path $script:TestsRoot 'fixtures\ai'

    . (Join-Path $script:FixtureRoot 'New-AIHttpFixture.ps1')

    $script:AllKinds = @('Success','Malformed','Credits','Auth','ModelNotFound','RateLimit','Overloaded')
}

# ==============================================================================
Describe 'Transport fixtures match the contract they stand in for (6.5-D15)' -Tag 'Fast' {

    It 'every scenario returns the full transport shape' {
        foreach ($kind in $script:AllKinds) {
            $r = New-AIHttpFixture -Kind $kind
            $names = @($r.PSObject.Properties.Name)
            foreach ($f in @('Success','StatusCode','Body','ErrorMessage','ErrorDetail')) {
                $names | Should -Contain $f -Because "$kind must return the field '$f'"
            }
        }
    }

    It 'reports the real status code for each scenario' {
        (New-AIHttpFixture -Kind Success).StatusCode       | Should -Be 200
        (New-AIHttpFixture -Kind Malformed).StatusCode     | Should -Be 200
        (New-AIHttpFixture -Kind Credits).StatusCode       | Should -Be 400
        (New-AIHttpFixture -Kind Auth).StatusCode          | Should -Be 401
        (New-AIHttpFixture -Kind ModelNotFound).StatusCode | Should -Be 404
        (New-AIHttpFixture -Kind RateLimit).StatusCode     | Should -Be 429
        (New-AIHttpFixture -Kind Overloaded).StatusCode    | Should -Be 529
    }

    It 'every failure scenario carries an actionable ErrorDetail' {
        # The whole point of the error fixtures. An empty detail here would make
        # the failure-guidance tests vacuous.
        foreach ($kind in @('Credits','Auth','ModelNotFound','RateLimit','Overloaded')) {
            $r = New-AIHttpFixture -Kind $kind
            $r.Success     | Should -BeFalse
            $r.ErrorDetail | Should -Not -BeNullOrEmpty -Because "$kind must carry a provider message"
        }
    }

    It 'the credits fixture says what the guidance keys off' {
        (New-AIHttpFixture -Kind Credits).ErrorDetail | Should -Match 'credit balance'
    }

    It 'the auth fixture says what the guidance keys off' {
        (New-AIHttpFixture -Kind Auth).ErrorDetail | Should -Match 'x-api-key'
    }

    It 'the success fixture parses through the client response reader' {
        # Round-trips the fixture through the real parser rather than trusting
        # its shape by eye.
        $module = Join-Path $script:RepoRoot 'SCRIPTS\AI\FieldOps-AIClient.psm1'
        Import-Module $module -Force -DisableNameChecking
        try {
            $body = (New-AIHttpFixture -Kind Success).Body
            $parsed = InModuleScope 'FieldOps-AIClient' -Parameters @{ B = $body } {
                param($B)
                ConvertFrom-AIResponseBody -Body $B
            }
            $parsed.Ok           | Should -BeTrue
            $parsed.Text         | Should -Not -BeNullOrEmpty
            $parsed.InputTokens  | Should -BeGreaterThan 0
        } finally {
            Remove-Module 'FieldOps-AIClient' -Force -ErrorAction SilentlyContinue
        }
    }

    It 'the malformed fixture is genuinely unusable, not merely odd' {
        $module = Join-Path $script:RepoRoot 'SCRIPTS\AI\FieldOps-AIClient.psm1'
        Import-Module $module -Force -DisableNameChecking
        try {
            $body = (New-AIHttpFixture -Kind Malformed).Body
            $parsed = InModuleScope 'FieldOps-AIClient' -Parameters @{ B = $body } {
                param($B)
                ConvertFrom-AIResponseBody -Body $B
            }
            # If this ever returns Ok, the fixture stopped testing what it claims.
            $parsed.Ok | Should -BeFalse
        } finally {
            Remove-Module 'FieldOps-AIClient' -Force -ErrorAction SilentlyContinue
        }
    }

    It 'honours usage and text overrides' {
        $r = New-AIHttpFixture -Kind Success -Text 'custom text' -InputTokens 500 -OutputTokens 250
        $r.Body.content[0].text        | Should -Be 'custom text'
        $r.Body.usage.input_tokens     | Should -Be 500
        $r.Body.usage.output_tokens    | Should -Be 250
    }

    It 'rejects an unknown scenario rather than returning something plausible' {
        { New-AIHttpFixture -Kind 'NoSuchKind' } | Should -Throw
    }

    It 'names the file when a fixture is missing' {
        { Get-AIFixtureBody -Name 'definitely-not-a-fixture' } | Should -Throw -ExpectedMessage '*definitely-not-a-fixture*'
    }
}

# ==============================================================================
Describe 'Fixture files on disk are well-formed (6.5-D15, 6.5-D16)' -Tag 'Fast' {

    It 'every response fixture is valid JSON' {
        $files = @(Get-ChildItem -Path (Join-Path $script:FixtureRoot 'responses') -Filter '*.json' -File)
        $files.Count | Should -BeGreaterThan 0
        foreach ($f in $files) {
            { Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } |
                Should -Not -Throw -Because "$($f.Name) must parse"
        }
    }

    It 'every error fixture carries the provider envelope' {
        # ConvertFrom-AIErrorBody reads error.message. A flattened fixture would
        # let a regression in that parsing pass unnoticed.
        $files = @(Get-ChildItem -Path (Join-Path $script:FixtureRoot 'responses') -Filter 'error-*.json' -File)
        $files.Count | Should -BeGreaterThan 0
        foreach ($f in $files) {
            $j = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $j.type          | Should -Be 'error'
            $j.error.type    | Should -Not -BeNullOrEmpty
            $j.error.message | Should -Not -BeNullOrEmpty
        }
    }

    It 'no fixture contains anything key-shaped' {
        # Fixtures are committed and public. A real key pasted into one while
        # reproducing a live failure is exactly how a secret reaches a repo.
        $files = @(Get-ChildItem -Path $script:FixtureRoot -Recurse -File)
        foreach ($f in $files) {
            $raw = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction SilentlyContinue
            if ($raw) {
                $raw | Should -Not -Match 'sk-ant-api\d\d-[A-Za-z0-9_\-]{20,}' -Because "$($f.Name) must not contain a live-format key"
            }
        }
    }

    It 'the severity fixture directory is present and populated (6.5-D16)' {
        $sev = Join-Path $script:FixtureRoot 'severity-labeled'
        Test-Path $sev | Should -BeTrue
        @(Get-ChildItem -Path $sev -Filter '*.json' -File).Count | Should -BeGreaterThan 0
    }
}
