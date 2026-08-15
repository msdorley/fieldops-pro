#Requires -Version 5.1
<#
    FieldOps Pro - Phase 6, Stream 6.5 (6.5-D15)

    Builds transport-shaped objects for mocking Invoke-AIHttpRequest.

    WHY A HELPER AND NOT JUST THE JSON

    Tests mock Invoke-AIHttpRequest, which returns a wrapper around the response
    body -- Success, StatusCode, Body, ErrorMessage, ErrorDetail -- not the body
    itself. Handing a test the raw JSON would make every call site re-derive
    that wrapper, which is the duplication D15 exists to remove.

    So the JSON files hold what the provider sends, and this builds what the
    transport returns. Keeping those separate means a change to the provider's
    body shape is a data edit, while a change to the transport contract is a
    change here -- and neither pretends to be the other.

    ON ErrorDetail

    Real non-2xx responses carry the reason in the body, which
    Invoke-AIHttpRequest recovers via ConvertFrom-AIErrorBody. The error kinds
    below populate ErrorDetail from their fixture's error.message for exactly
    that reason: a mock that omitted it would let a regression in the
    credits-and-key guidance pass unnoticed.

    Usage:
        . "$PSScriptRoot\..\..\fixtures\ai\New-AIHttpFixture.ps1"
        New-AIHttpFixture -Kind Success
        New-AIHttpFixture -Kind Credits
        New-AIHttpFixture -Kind Success -InputTokens 500 -Text 'custom'
#>

function Get-AIFixtureBody {
    <#
    .SYNOPSIS
        Load and parse a response fixture by filename stem.
    #>
    param([Parameter(Mandatory = $true)][string]$Name)

    $path = Join-Path $PSScriptRoot "responses\$Name.json"
    if (-not (Test-Path -LiteralPath $path)) {
        throw "AI fixture '$Name' not found at $path"
    }
    return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function New-AIHttpFixture {
    <#
    .SYNOPSIS
        A transport-shaped response object for mocking Invoke-AIHttpRequest.
    .PARAMETER Kind
        Which scenario to build. Success and Malformed return 200; the rest
        return their real status codes.
    .PARAMETER Text
        Override the response text. Success and Malformed only.
    .PARAMETER InputTokens / OutputTokens
        Override reported usage, for cost-arithmetic tests.
    .OUTPUTS
        PSCustomObject matching Invoke-AIHttpRequest's contract exactly.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Success','Malformed','Credits','Auth','ModelNotFound','RateLimit','Overloaded')]
        [string]$Kind,

        [string]$Text,
        [int]$InputTokens = -1,
        [int]$OutputTokens = -1
    )

    # Scenario -> fixture file and status. Kept as one table so a new scenario
    # is one row rather than a new branch.
    $map = @{
        Success       = @{ File = 'success';               Status = 200; Ok = $true  }
        Malformed     = @{ File = 'malformed';             Status = 200; Ok = $true  }
        Credits       = @{ File = 'error-credits';         Status = 400; Ok = $false }
        Auth          = @{ File = 'error-auth';            Status = 401; Ok = $false }
        ModelNotFound = @{ File = 'error-model-not-found'; Status = 404; Ok = $false }
        RateLimit     = @{ File = 'error-rate-limit';      Status = 429; Ok = $false }
        Overloaded    = @{ File = 'error-overloaded';      Status = 529; Ok = $false }
    }

    $spec = $map[$Kind]
    $body = Get-AIFixtureBody -Name $spec.File

    if ($spec.Ok) {
        # Apply overrides to a copy of the fixture, never to the fixture itself.
        if ($PSBoundParameters.ContainsKey('Text') -and $body.content -and @($body.content).Count -gt 0) {
            $body.content[0].text = $Text
        }
        if ($InputTokens  -ge 0) { $body.usage.input_tokens  = $InputTokens }
        if ($OutputTokens -ge 0) { $body.usage.output_tokens = $OutputTokens }

        return [PSCustomObject]@{
            Success      = $true
            StatusCode   = $spec.Status
            Body         = $body
            ErrorMessage = ''
            ErrorDetail  = ''
        }
    }

    # Failure: mirror what the real transport produces. ErrorMessage is the
    # generic WebException text PowerShell 5.1 surfaces; ErrorDetail is the
    # actionable reason recovered from the body.
    $detail = ''
    if ($body.error -and $body.error.message) { $detail = [string]$body.error.message }

    return [PSCustomObject]@{
        Success      = $false
        StatusCode   = $spec.Status
        Body         = $null
        ErrorMessage = "The remote server returned an error: ($($spec.Status))."
        ErrorDetail  = $detail
    }
}
