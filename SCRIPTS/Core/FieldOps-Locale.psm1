<#
.SYNOPSIS
    FieldOps Pro -- Localization Engine v1.0
.DESCRIPTION
    Reusable module that provides automatic language detection and string
    localization for all FieldOps Pro scripts.

    LANGUAGE DETECTION CASCADE (highest wins):
        1. Explicit -Language parameter passed to Initialize-Locale
        2. "Locale" field in technician.json
        3. Windows UI culture (Get-Culture)
        4. Fallback: English ("en")

    USAGE IN ANY SCRIPT:
        # At the top of your script:
        Import-Module (Join-Path $PSScriptRoot 'FieldOps-Locale.psm1') -Force
        Initialize-Locale

        # Then anywhere in the script:
        $msg = Get-LocaleString 'dashboard.title'
        # => "OPERATIONS DASHBOARD" (en) or "TABLEAU DE BORD" (fr)

        # With variable substitution:
        $msg = Get-LocaleString 'snapshot.saved' @{ Size='4.4 MB'; Time='32s' }
        # => "Snapshot saved: 4.4 MB in 32s" or "Instantane sauvegarde : 4.4 MB en 32s"

    ADDING A NEW LANGUAGE:
        1. Copy E:\CONFIG\lang\en.json to E:\CONFIG\lang\XX.json
        2. Translate all values (keep keys identical)
        3. Set "Locale": "XX" in technician.json (or pass -Language XX)

.NOTES
    File: FieldOps-Locale.psm1
    Path: E:\SCRIPTS\Core\FieldOps-Locale.psm1
#>

# Module-scope state
$script:CurrentLocale = 'en'
$script:Strings = @{}
$script:FallbackStrings = @{}
$script:LocaleInitialized = $false

function Initialize-Locale {
    <#
    .SYNOPSIS
        Detect language and load translation strings. Call once per script.
    .PARAMETER Language
        Explicit language code override (e.g. 'fr', 'en', 'es').
    .PARAMETER ConfigDir
        Path to E:\CONFIG (auto-detected if not specified).
    #>
    [CmdletBinding()]
    param(
        [string]$Language = '',
        [string]$ConfigDir = ''
    )

    # Auto-detect config dir from module location
    if ($ConfigDir -eq '') {
        $modDir = Split-Path -Parent $PSScriptRoot
        if (-not $modDir) { $modDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
        # Navigate: Core -> SCRIPTS -> USB root -> CONFIG
        $usbRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $ConfigDir = Join-Path $usbRoot 'CONFIG'
    }

    $langDir = Join-Path $ConfigDir 'lang'

    # === DETECTION CASCADE ===

    # Priority 1: Explicit parameter
    $detected = $Language

    # Priority 2: Config file
    if ($detected -eq '') {
        $cfgCandidates = @(
            (Join-Path $ConfigDir 'technician.json'),
            (Join-Path $ConfigDir 'FieldOps.config.json')
        )
        foreach ($cfgPath in $cfgCandidates) {
            if (Test-Path $cfgPath) {
                try {
                    $cfg = Get-Content $cfgPath -Raw -ErrorAction Stop | ConvertFrom-Json
                    foreach ($field in @('Locale','Language','Lang','Culture')) {
                        $v = $cfg.$field
                        if ($v -and "$v".Trim() -ne '') {
                            $detected = "$v".Trim().ToLower()
                            break
                        }
                    }
                } catch { }
                if ($detected -ne '') { break }
            }
        }
    }

    # Priority 3: Windows UI culture
    if ($detected -eq '') {
        try {
            $culture = (Get-Culture).TwoLetterISOLanguageName
            if ($culture) { $detected = $culture.ToLower() }
        } catch { }
    }

    # Priority 4: Fallback
    if ($detected -eq '') { $detected = 'en' }

    # Normalize: accept 'fr-FR', 'fr_FR', 'fra' -> 'fr'
    $detected = ($detected -split '[-_]')[0].ToLower()
    if ($detected.Length -gt 3) { $detected = $detected.Substring(0, 2) }

    $script:CurrentLocale = $detected

    # === LOAD STRINGS ===

    # Always load English as fallback
    $enFile = Join-Path $langDir 'en.json'
    if (Test-Path $enFile) {
        try {
            $script:FallbackStrings = Load-StringFile $enFile
        } catch {
            Write-Warning "FieldOps-Locale: Failed to load en.json: $_"
            $script:FallbackStrings = @{}
        }
    }

    # Load target language
    if ($detected -ne 'en') {
        $langFile = Join-Path $langDir "$detected.json"
        if (Test-Path $langFile) {
            try {
                $script:Strings = Load-StringFile $langFile
            } catch {
                Write-Warning "FieldOps-Locale: Failed to load $detected.json: $_"
                $script:Strings = @{}
            }
        } else {
            # Language file not found -- fall back to English
            Write-Warning "FieldOps-Locale: $detected.json not found in $langDir, falling back to English"
            $script:Strings = @{}
            $script:CurrentLocale = 'en'
        }
    } else {
        $script:Strings = $script:FallbackStrings
    }

    $script:LocaleInitialized = $true

    return $script:CurrentLocale
}

function Load-StringFile {
    <#
    .SYNOPSIS
        Load a JSON translation file and flatten nested keys with dot notation.
        { "dashboard": { "title": "Hello" } } becomes { "dashboard.title" = "Hello" }
    #>
    param([string]$Path)

    $raw = Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    $flat = @{}
    Flatten-Object -Obj $raw -Prefix '' -Output $flat
    return $flat
}

function Flatten-Object {
    param($Obj, [string]$Prefix, [hashtable]$Output)

    if ($null -eq $Obj) { return }

    $props = @()
    if ($Obj -is [System.Management.Automation.PSCustomObject]) {
        $props = @($Obj.PSObject.Properties)
    } elseif ($Obj -is [System.Collections.IDictionary]) {
        $props = @($Obj.GetEnumerator() | ForEach-Object {
            [PSCustomObject]@{ Name = $_.Key; Value = $_.Value }
        })
    }

    foreach ($p in $props) {
        $key = if ($Prefix) { "$Prefix.$($p.Name)" } else { $p.Name }
        $val = $p.Value

        if ($null -eq $val) {
            $Output[$key] = ''
        } elseif ($val -is [string] -or $val -is [int] -or $val -is [bool] -or $val -is [double]) {
            $Output[$key] = "$val"
        } elseif ($val -is [System.Management.Automation.PSCustomObject] -or $val -is [System.Collections.IDictionary]) {
            Flatten-Object -Obj $val -Prefix $key -Output $Output
        } elseif ($val -is [array]) {
            # Arrays stored as joined string (for lists of items)
            $Output[$key] = ($val -join '|')
        } else {
            $Output[$key] = "$val"
        }
    }
}

function Get-LocaleString {
    <#
    .SYNOPSIS
        Get a localized string by key, with optional variable substitution.
    .PARAMETER Key
        Dot-notation key (e.g. "dashboard.title").
    .PARAMETER Vars
        Hashtable of variables to substitute. {Name} in the string becomes
        the value of $Vars['Name'].
    .PARAMETER Default
        Fallback if key is not found in any language file.
    .EXAMPLE
        Get-LocaleString 'snap.saved' @{ Size='4.4 MB' }
        # "Snapshot saved: 4.4 MB"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Key,
        [hashtable]$Vars = @{},
        [string]$Default = ''
    )

    if (-not $script:LocaleInitialized) {
        Initialize-Locale | Out-Null
    }

    # Try current locale first, then English fallback
    $str = ''
    if ($script:Strings.ContainsKey($Key)) {
        $str = $script:Strings[$Key]
    } elseif ($script:FallbackStrings.ContainsKey($Key)) {
        $str = $script:FallbackStrings[$Key]
    }

    # If still empty, use default or key itself
    if ($str -eq '') {
        $str = if ($Default) { $Default } else { $Key }
    }

    # Variable substitution: replace {VarName} with $Vars['VarName']
    if ($Vars.Count -gt 0) {
        foreach ($vk in $Vars.Keys) {
            $str = $str -replace "\{$vk\}", "$($Vars[$vk])"
        }
    }

    return $str
}

function Get-CurrentLocale {
    <#
    .SYNOPSIS
        Returns the currently active locale code (e.g. 'en', 'fr').
    #>
    if (-not $script:LocaleInitialized) { Initialize-Locale | Out-Null }
    return $script:CurrentLocale
}

function Get-AvailableLocales {
    <#
    .SYNOPSIS
        Returns an array of available locale codes based on files in E:\CONFIG\lang\.
    #>
    $usbRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $langDir = Join-Path (Join-Path $usbRoot 'CONFIG') 'lang'
    if (-not (Test-Path $langDir)) { return @('en') }
    $files = @(Get-ChildItem -Path $langDir -Filter '*.json' -ErrorAction SilentlyContinue)
    return @($files | ForEach-Object { $_.BaseName })
}

# Export module members
Export-ModuleMember -Function Initialize-Locale, Get-LocaleString, Get-CurrentLocale, Get-AvailableLocales
