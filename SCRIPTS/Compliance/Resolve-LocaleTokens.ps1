<#
================================================================================
Resolve-LocaleTokens.ps1 -- FieldOps Pro Phase 5.2, refactored in Phase 6.1-R4b
================================================================================
Replaces {{t:locale.key}} tokens with their resolved values from the locale
bundle.

TWO ENTRY POINTS

    Resolve-LocaleTokensInString   Takes HTML content, returns resolved content.
                                   Used by the report renderer, which resolves
                                   IN MEMORY before hashing and writing.

    Resolve-LocaleTokensInFile     Thin wrapper: read, resolve, write in place.
                                   Retained for standalone use and for the
                                   existing token-resolution tests.

WHY THE STRING FORM EXISTS (6.1-R4b)

    The renderer previously computed the report's SHA-256 integrity hash, wrote
    the file, and only then invoked the file-based resolver, which rewrote that
    same file in place. The embedded hash therefore covered content that no
    longer existed on disk -- while the report itself states that any
    modification after generation invalidates the signature.

    Resolving in memory before the hash is computed makes the signature cover
    exactly the delivered bytes. It also lets bundle placeholders such as
    {cvCount} flow through the renderer's normal replacement pass, so no
    separate variable-substitution mechanism is needed here.

IDEMPOTENT
    Tokens not present are a no-op. Keys missing from the bundle are left
    unchanged so they are visible in the output rather than silently blanked.
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

function Resolve-LocaleBundleDir {
    # Auto-discover the bundle directory when the caller did not supply one.
    # When this file is dot-sourced, $MyInvocation.MyCommand.Path may not point
    # at the resolver, so callers should pass -BundleDir explicitly from a
    # dot-sourced context. This fallback covers standalone invocation.
    param([string]$BundleDir)
    if ($BundleDir) { return $BundleDir }
    $candidate = $null
    try {
        if ($PSScriptRoot) { $candidate = $PSScriptRoot }
        elseif ($MyInvocation.MyCommand.Path) {
            $candidate = Split-Path -Parent $MyInvocation.MyCommand.Path
        }
    } catch { $candidate = $null }
    if (-not $candidate) { return $null }
    # ScriptDir is Compliance, parent is SCRIPTS, parent of that is ProjectRoot
    $projectRoot = Split-Path -Parent (Split-Path -Parent $candidate)
    return (Join-Path $projectRoot 'CONFIG\lang')
}

function Resolve-LocaleTokensInString {
    <#
    .SYNOPSIS
        Resolve {{t:locale.key}} tokens in a string against a locale bundle.
    .OUTPUTS
        The resolved content. On any failure the input is returned unchanged,
        so a bundle problem degrades the report to visible tokens rather than
        aborting generation in the field.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Content,
        [string]$BundleDir = $null,
        [string]$Lang      = 'fr'
    )

    $dir = Resolve-LocaleBundleDir -BundleDir $BundleDir
    if (-not $dir) {
        Write-Warning 'Resolve-LocaleTokens: cannot determine bundle directory; pass -BundleDir explicitly'
        return $Content
    }

    $bundlePath = Join-Path $dir ($Lang + '.json')
    if (-not (Test-Path -LiteralPath $bundlePath)) {
        Write-Warning "Resolve-LocaleTokens: bundle not found: $bundlePath"
        return $Content
    }

    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    $bundle  = [System.IO.File]::ReadAllText($bundlePath, $utf8Bom) | ConvertFrom-Json

    $tokenPattern = [regex]'\{\{t:([\w.]+)\}\}'
    $found = $tokenPattern.Matches($Content)
    if ($found.Count -eq 0) { return $Content }

    # One resolution per distinct key
    $plainKeys = @{}
    $richKeys  = @{}
    foreach ($m in $found) {
        $key = $m.Groups[1].Value
        if (-not $plainKeys.ContainsKey($key)) { $plainKeys[$key] = $null }
    }

    foreach ($key in @($plainKeys.Keys)) {
        $segments = $key -split '\.'
        $current  = $bundle
        $ok       = $true
        foreach ($s in $segments) {
            if ($null -eq $current) { $ok = $false; break }
            if ($current.PSObject.Properties.Name -notcontains $s) { $ok = $false; break }
            $current = $current.$s
        }
        if ($ok -and $null -ne $current -and $current -is [string]) {
            $plainKeys[$key] = $current
        } elseif ($ok -and $null -ne $current -and
                  ($current.PSObject.Properties.Name -contains 'parts') -and
                  ($current.PSObject.Properties.Name -contains 'separator')) {
            # Rich-text values resolve through $richKeys and are injected raw
            # (their parts are escaped individually by ConvertTo-RichTextHtml).
            # The placeholder must be removed from $plainKeys or the reporting
            # loop below would count a resolved key as unresolved.
            $richKeys[$key] = ConvertTo-RichTextHtml -Value $current
            [void]$plainKeys.Remove($key)
        } else {
            $plainKeys[$key] = $null
        }
    }

    $resolved   = 0
    $unresolved = 0

    foreach ($key in @($plainKeys.Keys)) {
        $value = $plainKeys[$key]
        $token = "{{t:$key}}"
        if ($null -ne $value) {
            # Escape only & < > . Quotes are left alone: the bundle uses
            # typographic quotation marks for French, which need no escaping.
            $htmlSafe = $value.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
            $Content = $Content.Replace($token, $htmlSafe)
            $resolved++
        } else {
            $unresolved++
        }
    }

    foreach ($key in @($richKeys.Keys)) {
        $Content = $Content.Replace("{{t:$key}}", $richKeys[$key])
        $resolved++
    }

    if ($unresolved -gt 0) {
        Write-Warning ("Resolve-LocaleTokens: {0} key(s) resolved, {1} unresolved" -f $resolved, $unresolved)
    }

    return $Content
}

function Resolve-LocaleTokensInFile {
    <#
    .SYNOPSIS
        Resolve {{t:locale.key}} tokens in an HTML file, in place.
    .DESCRIPTION
        Thin wrapper over Resolve-LocaleTokensInString. Preserved so existing
        callers and tests continue to work unchanged. New code in the render
        pipeline should use the string form and resolve before hashing.
    #>
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

    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    $content = [System.IO.File]::ReadAllText($Path, $utf8Bom)

    $resolvedContent = Resolve-LocaleTokensInString -Content $content -BundleDir $BundleDir -Lang $Lang

    if ($resolvedContent -ne $content) {
        [System.IO.File]::WriteAllText($Path, $resolvedContent, $utf8Bom)
    }
}
