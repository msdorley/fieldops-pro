#Requires -Version 5.1
<#
.SYNOPSIS
    Bundle formatter test helper for FieldOps Pro locale unit tests.

.DESCRIPTION
    Loads a locale bundle file (CONFIG\lang\XX.json) and exposes its
    contents in the flat dot-notation key format that Get-LocaleString
    uses internally.  Used by locale unit tests (D10) to assert bundle
    completeness, key consistency, and value correctness without
    importing the full FieldOps-Locale.psm1 stack.

    Three functions are provided:

        Get-BundleKeys       -- returns all dot-notation keys in a bundle
        Get-BundleValue      -- returns the value for a specific key
        Compare-BundleKeys   -- returns keys present in one bundle but
                                absent in another (drift detection)

    Key flattening convention mirrors FieldOps-Locale.psm1:
        { "common": { "appName": "FieldOps Pro" } }
        => key: "common.appName", value: "FieldOps Pro"

        { "report": { "anssi": { "title": "..." } } }
        => key: "report.anssi.title", value: "..."

    The _meta block is preserved as-is under the "._meta.*" namespace
    so tests can assert language code, version, and direction.

    Usage in a locale unit test:

        . (Join-Path $PSScriptRoot '..\..\Format-Bundle.ps1')

        Describe 'EN bundle completeness' {
            It 'has all required common keys' {
                $keys = Get-BundleKeys -Locale 'en'
                $keys | Should -Contain 'common.appName'
                $keys | Should -Contain 'common.error'
            }

            It 'en and fr bundles have the same key set' {
                $diff = Compare-BundleKeys -BaseLocale 'en' -CompareLocale 'fr'
                $diff.OnlyInBase    | Should -BeNullOrEmpty
                $diff.OnlyInCompare | Should -BeNullOrEmpty
            }
        }

.NOTES
    FieldOps Pro - Chapter 6.6 Continuous Validation - D7
    PS 5.1.  ASCII source.  Set-StrictMode -Version 1.0.
    Dot-sourced by tests\unit\Locale\*.Tests.ps1 (D10).
    Bundle files live at CONFIG\lang\XX.json relative to repo root.
#>

[CmdletBinding(SupportsShouldProcess = $false)]
param()

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Internal: resolve CONFIG\lang\ directory from this script's location
# $PSScriptRoot = tests\
# Parent        = repo root
# ---------------------------------------------------------------------------
function Resolve-BundleDir {
    param([string]$Override = '')
    if ($Override -ne '') { return $Override }
    $repoRoot  = Split-Path $PSScriptRoot -Parent
    $bundleDir = Join-Path $repoRoot 'CONFIG\lang'
    if (-not (Test-Path $bundleDir)) {
        throw "Format-Bundle: CONFIG\lang\ not found at: $bundleDir"
    }
    return $bundleDir
}

# ---------------------------------------------------------------------------
# Internal: flatten nested PSCustomObject into dot-notation hashtable
# ---------------------------------------------------------------------------
function Expand-BundleObject {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Node,

        [Parameter(Mandatory = $false)]
        [string]$Prefix = '',

        [Parameter(Mandatory = $false)]
        [System.Collections.Hashtable]$Output = $null
    )

    if ($null -eq $Output) {
        $Output = @{}
    }

    $properties = $Node | Get-Member -MemberType NoteProperty -ErrorAction SilentlyContinue
    if ($null -eq $properties) {
        # Leaf node
        if ($Prefix -ne '') {
            $Output[$Prefix] = "$Node"
        }
        return $Output
    }

    foreach ($prop in $properties) {
        $key = $prop.Name
        $val = $Node.$key
        $fullKey = if ($Prefix -eq '') { $key } else { "$Prefix.$key" }

        if ($null -eq $val) {
            $Output[$fullKey] = ''
        } elseif ($val -is [System.Management.Automation.PSCustomObject]) {
            Expand-BundleObject -Node $val -Prefix $fullKey -Output $Output | Out-Null
        } elseif ($val -is [System.Object[]]) {
            # Arrays stored as pipe-joined string (mirrors FieldOps-Locale.psm1 behaviour)
            $Output[$fullKey] = ($val -join '|')
        } else {
            $Output[$fullKey] = "$val"
        }
    }

    return $Output
}

# ---------------------------------------------------------------------------
# Internal: load and parse a bundle file
# ---------------------------------------------------------------------------
function Read-BundleFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    if (-not (Test-Path $FilePath)) {
        throw "Format-Bundle: bundle file not found: $FilePath"
    }

    $raw = $null
    try {
        $raw = Get-Content -LiteralPath $FilePath -Raw -Encoding UTF8
    } catch {
        throw "Format-Bundle: failed to read bundle file '$FilePath': $_"
    }

    $parsed = $null
    try {
        $parsed = $raw | ConvertFrom-Json
    } catch {
        throw "Format-Bundle: bundle file '$FilePath' is not valid JSON: $_"
    }

    return $parsed
}

# ---------------------------------------------------------------------------
# Public: Get-BundleKeys
# ---------------------------------------------------------------------------
function Get-BundleKeys {
    <#
    .SYNOPSIS
        Returns all dot-notation keys from a locale bundle.

    .PARAMETER Locale
        Locale code, e.g. 'en' or 'fr'.
        Resolves to CONFIG\lang\XX.json relative to repo root.

    .PARAMETER BundlePath
        Full path to a bundle file.  Overrides -Locale.

    .PARAMETER BundleDir
        Override the CONFIG\lang\ directory.

    .OUTPUTS
        [string[]] sorted array of dot-notation keys.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$Locale = '',

        [Parameter(Mandatory = $false)]
        [string]$BundlePath = '',

        [Parameter(Mandatory = $false)]
        [string]$BundleDir = ''
    )

    if ($BundlePath -eq '' -and $Locale -eq '') {
        throw "Get-BundleKeys: supply either -Locale or -BundlePath."
    }

    if ($BundlePath -eq '') {
        $dir       = Resolve-BundleDir -Override $BundleDir
        $BundlePath = Join-Path $dir "$Locale.json"
    }

    $parsed = Read-BundleFile -FilePath $BundlePath
    $flat   = Expand-BundleObject -Node $parsed
    return @($flat.Keys | Sort-Object)
}

# ---------------------------------------------------------------------------
# Public: Get-BundleValue
# ---------------------------------------------------------------------------
function Get-BundleValue {
    <#
    .SYNOPSIS
        Returns the value for a specific dot-notation key in a bundle.

    .PARAMETER Key
        Dot-notation key, e.g. 'common.appName'.

    .PARAMETER Locale
        Locale code, e.g. 'en' or 'fr'.

    .PARAMETER BundlePath
        Full path override.

    .PARAMETER BundleDir
        Override the CONFIG\lang\ directory.

    .OUTPUTS
        [string] the value, or $null if the key is absent.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Key,

        [Parameter(Mandatory = $false)]
        [string]$Locale = '',

        [Parameter(Mandatory = $false)]
        [string]$BundlePath = '',

        [Parameter(Mandatory = $false)]
        [string]$BundleDir = ''
    )

    if ($BundlePath -eq '' -and $Locale -eq '') {
        throw "Get-BundleValue: supply either -Locale or -BundlePath."
    }

    if ($BundlePath -eq '') {
        $dir       = Resolve-BundleDir -Override $BundleDir
        $BundlePath = Join-Path $dir "$Locale.json"
    }

    $parsed = Read-BundleFile -FilePath $BundlePath
    $flat   = Expand-BundleObject -Node $parsed

    if ($flat.ContainsKey($Key)) {
        return $flat[$Key]
    }
    return $null
}

# ---------------------------------------------------------------------------
# Public: Compare-BundleKeys
# ---------------------------------------------------------------------------
function Compare-BundleKeys {
    <#
    .SYNOPSIS
        Compares the key sets of two locale bundles.
        Returns keys present in one but absent in the other.
        A non-empty result indicates locale drift.

    .PARAMETER BaseLocale
        The reference locale (e.g. 'en').

    .PARAMETER CompareLocale
        The locale to compare against the base (e.g. 'fr').

    .PARAMETER BasePath
        Full path override for the base bundle.

    .PARAMETER ComparePath
        Full path override for the compare bundle.

    .PARAMETER BundleDir
        Override the CONFIG\lang\ directory.

    .OUTPUTS
        [PSCustomObject] with two properties:
            OnlyInBase    [string[]] keys in base but not in compare
            OnlyInCompare [string[]] keys in compare but not in base
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$BaseLocale = '',

        [Parameter(Mandatory = $false)]
        [string]$CompareLocale = '',

        [Parameter(Mandatory = $false)]
        [string]$BasePath = '',

        [Parameter(Mandatory = $false)]
        [string]$ComparePath = '',

        [Parameter(Mandatory = $false)]
        [string]$BundleDir = ''
    )

    if ($BasePath -eq '' -and $BaseLocale -eq '') {
        throw "Compare-BundleKeys: supply either -BaseLocale or -BasePath."
    }
    if ($ComparePath -eq '' -and $CompareLocale -eq '') {
        throw "Compare-BundleKeys: supply either -CompareLocale or -ComparePath."
    }

    $baseKeys    = Get-BundleKeys -Locale $BaseLocale    -BundlePath $BasePath    -BundleDir $BundleDir
    $compareKeys = Get-BundleKeys -Locale $CompareLocale -BundlePath $ComparePath -BundleDir $BundleDir

    $baseSet    = [System.Collections.Generic.HashSet[string]]::new($baseKeys)
    $compareSet = [System.Collections.Generic.HashSet[string]]::new($compareKeys)

    $onlyInBase    = @($baseKeys    | Where-Object { -not $compareSet.Contains($_) } | Sort-Object)
    $onlyInCompare = @($compareKeys | Where-Object { -not $baseSet.Contains($_) }    | Sort-Object)

    return [PSCustomObject]@{
        OnlyInBase    = $onlyInBase
        OnlyInCompare = $onlyInCompare
    }
}
