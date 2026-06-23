#Requires -Version 5.1
<#
    FieldOps Pro - Chapter 6.6 Continuous Validation
    Get-EvaluatorSource.ps1 (D11 support)

    Extracts ONLY the function definitions from Build-ANSSIData.ps1 and returns
    them as a single string of PowerShell source. The caller dot-sources that
    string (typically inside a Pester BeforeAll) to make the evaluators and
    their helpers available to test bodies -- WITHOUT executing the collector's
    main pipeline.

    Why:
        Build-ANSSIData.ps1 runs its collection unconditionally at the bottom
        (no dot-source guard). Dot-sourcing the whole file would read real
        LOGS\ engine JSON and overwrite REPORTS\report-data.json. We use the
        PowerShell AST to take only the function-definition extents -- T, the
        helper layer (Get-DictValue, Find-Check, Test-Status, ...), and the 42
        evaluators Get-R1..Get-R42 -- and skip every top-level statement.

    Zero changes to production code.

    Usage in a test:
        BeforeAll {
            . "$PSScriptRoot\..\..\Get-EvaluatorSource.ps1"
            $src = Get-EvaluatorSource -ScriptPath $buildAnssiPath
            . ([scriptblock]::Create($src))   # defines all functions here
        }
#>

function Get-EvaluatorSource {
    <#
    .SYNOPSIS
        Return the concatenated source text of every function defined in a
        script, with all top-level executable code removed.

    .PARAMETER ScriptPath
        Full path to Build-ANSSIData.ps1.

    .OUTPUTS
        [string] PowerShell source containing only function definitions.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath
    )

    if (-not (Test-Path -LiteralPath $ScriptPath)) {
        throw "Get-EvaluatorSource: script not found at '$ScriptPath'."
    }

    $raw = Get-Content -LiteralPath $ScriptPath -Raw -Encoding UTF8

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput(
        $raw, [ref]$tokens, [ref]$errors
    )

    if ($null -eq $ast) {
        throw "Get-EvaluatorSource: failed to parse '$ScriptPath'."
    }

    # Only top-level function definitions. The collector defines all its
    # functions at script scope, so we do not need to recurse into nested
    # scopes (and recursing would risk pulling helper-internal closures).
    $funcAsts = $ast.FindAll(
        {
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
        },
        $false
    )

    if (-not $funcAsts -or @($funcAsts).Count -eq 0) {
        # Fall back to a recursive search if the collector ever nests its
        # function definitions inside a wrapper scope.
        $funcAsts = $ast.FindAll(
            {
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
            },
            $true
        )
    }

    if (-not $funcAsts -or @($funcAsts).Count -eq 0) {
        throw "Get-EvaluatorSource: no function definitions found in '$ScriptPath'."
    }

    $parts = foreach ($fn in $funcAsts) { $fn.Extent.Text }
    return ($parts -join "`n`n")
}

function Get-EvaluatorFunctionNames {
    <#
    .SYNOPSIS
        Return just the names of the functions a script defines (for assertions
        like "all 42 evaluators are present").
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath
    )

    $raw = Get-Content -LiteralPath $ScriptPath -Raw -Encoding UTF8
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput(
        $raw, [ref]$tokens, [ref]$errors
    )

    $funcAsts = $ast.FindAll(
        {
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
        },
        $true
    )

    return @($funcAsts | ForEach-Object { $_.Name })
}
