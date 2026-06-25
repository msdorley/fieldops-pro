<#
================================================================================
Resolve-LocaleTokens.ps1 -- FieldOps Pro Phase 5.2
================================================================================
Post-processes a rendered HTML file, replacing {{t:locale.key}} tokens with
their resolved values from the locale bundle.

Called by Invoke-ANSSIDiagnostic-POC.ps1 after the existing token-replacement
pass completes. Operates on the file in place.

Idempotent: tokens not present in the file are no-ops. Tokens whose keys are
missing from the bundle are left unchanged (visible debug hint).
================================================================================
#>

function ConvertTo-RichTextHtml {
    # Render a {parts,separator} bundle object to HTML for injection. Each
    # part is HTML-escaped (& < >); the separator is trusted structural markup
    # from our own bundle (br/para/space/none), emitted raw. No injection
    # surface: separators are never translator-controlled free text.
    param($Value)
    if ($null -eq $Value) { return '' }
    $names = @($Value.PSObject.Properties.Name)
    if (($names -notcontains 'parts') -or ($names -notcontains 'separator')) { return '' }
    $parts = @($Value.parts | ForEach-Object {
        "$_".Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;')
    })
    if ($parts.Count -eq 0) { return '' }
    $sep = "$($Value.separator)"
    switch ($sep) {
        'br'    { return ($parts -join '<br>') }
        'space' { return ($parts -join ' ') }
        'none'  { return ($parts -join '') }
        'para'  { return (($parts | ForEach-Object { "<p>$_</p>" }) -join '') }
        default  { return ($parts -join '<br>') }
    }
}

function Resolve-LocaleTokensInFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [string]$BundleDir = $null,
        [string]$Lang      = 'fr'
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Warning "Resolve-LocaleTokensInFile: file not found: $Path"
        return
    }

    # Auto-discover BundleDir if not supplied. When this function is dot-sourced
    # into another script, $MyInvocation.MyCommand.Path may not resolve to the
    # resolver's own location. Caller should pass -BundleDir explicitly when
    # invoking from a dot-sourced context. The fallback below only works for
    # standalone invocation (e.g. testing this script directly).
    if (-not $BundleDir) {
        $candidate = $null
        try {
            if ($PSScriptRoot) { $candidate = $PSScriptRoot }
            elseif ($MyInvocation.MyCommand.Path) {
                $candidate = Split-Path -Parent $MyInvocation.MyCommand.Path
            }
        } catch { $candidate = $null }
        if ($candidate) {
            # ScriptDir is Compliance, parent is SCRIPTS, parent of that is ProjectRoot
            $projectRoot = Split-Path -Parent (Split-Path -Parent $candidate)
            $BundleDir   = Join-Path $projectRoot 'CONFIG\lang'
        } else {
            Write-Warning "Resolve-LocaleTokensInFile: cannot auto-discover BundleDir; pass -BundleDir explicitly"
            return
        }
    }

    $bundlePath = Join-Path $BundleDir ($Lang + '.json')
    if (-not (Test-Path -LiteralPath $bundlePath)) {
        Write-Warning "Resolve-LocaleTokensInFile: bundle not found: $bundlePath"
        return
    }

    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    $bundle  = [System.IO.File]::ReadAllText($bundlePath, $utf8Bom) | ConvertFrom-Json
    $content = [System.IO.File]::ReadAllText($Path, $utf8Bom)

    # Find every {{t:path.to.key}} token in the file. Replace each with the
    # resolved value from the bundle. Keys with dots traverse nested objects.
    $tokenPattern = [regex]'\{\{t:([\w.]+)\}\}'
    $matches = $tokenPattern.Matches($content)
    if ($matches.Count -eq 0) {
        return  # nothing to do
    }

    # Build a unique set of keys, resolve once per key
    $uniqueKeys = @{}
    $richKeys   = @{}
    foreach ($m in $matches) {
        $key = $m.Groups[1].Value
        if (-not $uniqueKeys.ContainsKey($key)) {
            $uniqueKeys[$key] = $null
        }
    }

    foreach ($key in @($uniqueKeys.Keys)) {
        $parts   = $key -split '\.'
        $current = $bundle
        $found   = $true
        foreach ($p in $parts) {
            if ($null -eq $current) { $found = $false; break }
            if ($current.PSObject.Properties.Name -notcontains $p) {
                $found = $false; break
            }
            $current = $current.$p
        }
        if ($found -and $null -ne $current -and $current -is [string]) {
            $uniqueKeys[$key] = $current
        } elseif ($found -and $null -ne $current -and ($current.PSObject.Properties.Name -contains 'parts') -and ($current.PSObject.Properties.Name -contains 'separator')) {
            $richKeys[$key] = ConvertTo-RichTextHtml -Value $current
        } else {
            $uniqueKeys[$key] = $null
        }
    }

    # Apply replacements
    $resolved = 0
    $unresolved = 0
    foreach ($key in @($uniqueKeys.Keys)) {
        $value = $uniqueKeys[$key]
        $token = "{{t:$key}}"
        if ($null -ne $value) {
            # HTML-encode the bundle value -- the value may contain characters
            # like apostrophes or angle brackets that need escaping in HTML.
            # For safety we only escape < > & not quotes (since the bundle
            # already uses curly quotes for French typography).
            $htmlSafe = $value.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
            $content = $content.Replace($token, $htmlSafe)
            $resolved++
        } else {
            $unresolved++
        }
    }
    foreach ($key in @($richKeys.Keys)) {
        $token = "{{t:$key}}"
        $content = $content.Replace($token, $richKeys[$key])
        $resolved++
    }

    [System.IO.File]::WriteAllText($Path, $content, $utf8Bom)

    if ($unresolved -gt 0) {
        Write-Warning ("Resolve-LocaleTokensInFile: {0} key(s) resolved, {1} unresolved" -f $resolved, $unresolved)
    }
}
