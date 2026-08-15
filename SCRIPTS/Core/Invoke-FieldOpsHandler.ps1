#Requires -Version 5.1
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Ousman Dorley. See LICENSE at the repository root.
<#
.SYNOPSIS
    FieldOps Pro -- Protocol URL Handler / Dispatcher
.DESCRIPTION
    Receives fieldops:// URLs from Windows (registered via
    Register-FieldOpsProtocol.ps1) and safely dispatches them to the
    correct FieldOps Pro script.

    URL FORMAT:
        fieldops://run?script=<scriptname>[&args=<base64args>]
        fieldops://doc?file=<relativepath>
        fieldops://open?path=<encodedpath>
        fieldops://playbook?name=<playbookname>

    SECURITY MODEL:
        - Scripts can ONLY be launched from E:\SCRIPTS\ subtree
        - Script name is validated against actual filesystem (no path traversal)
        - Arguments are base64-encoded and length-limited
        - Every invocation is logged to E:\LOGS\protocol-handler.log
        - Unknown verbs are rejected
        - Unknown scripts are rejected
.PARAMETER Url
    The fieldops:// URL passed by Windows. Set automatically by the shell
    when the protocol is invoked.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$Url
)

$ErrorActionPreference = 'Continue'

# ==============================================================
# PATH RESOLUTION
# ==============================================================
$scriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$scriptsDir = Split-Path -Parent $scriptDir
$usbRoot    = Split-Path -Parent $scriptsDir
$logsDir    = Join-Path $usbRoot 'LOGS'
$playbooksDir = Join-Path $usbRoot 'PLAYBOOKS'
$docsDir    = Join-Path $usbRoot 'DOCS'
$logFile    = Join-Path $logsDir 'protocol-handler.log'

if (-not (Test-Path $logsDir)) {
    try { $null = New-Item -ItemType Directory -Path $logsDir -Force } catch { }
}

# ==============================================================
# LOGGING
# ==============================================================
function Write-Log {
    param([string]$Level, [string]$Message)
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line = "[$ts] [$Level] $Message"
    try { Add-Content -Path $logFile -Value $line -ErrorAction SilentlyContinue } catch { }
    $color = switch ($Level) {
        'ERROR' { 'Red' }
        'WARN'  { 'Yellow' }
        'OK'    { 'Green' }
        default { 'Gray' }
    }
    Write-Host $line -ForegroundColor $color
}

Write-Host ''
Write-Host '  ======================================================================' -ForegroundColor Cyan
Write-Host '  FIELDOPS PRO -- PROTOCOL HANDLER' -ForegroundColor Cyan
Write-Host '  ======================================================================' -ForegroundColor Cyan
Write-Host ''
Write-Log 'INFO' "Received URL: $Url"

# ==============================================================
# URL PARSING
# ==============================================================
# Expected: fieldops://verb?key=value&key=value
if ($Url -notmatch '^fieldops://') {
    Write-Log 'ERROR' "URL does not start with fieldops://"
    Write-Host ''
    Write-Host '  Press any key to close...' -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    exit 1
}

# Strip the scheme and parse manually (URI class treats custom schemes oddly)
$rest = $Url -replace '^fieldops://',''

# v1.0.1 FIX: Windows often inserts a slash between the host and query:
#   fieldops://run/?script=...   (note the /)
# The old regex '^([a-zA-Z]+)(\?(.*))?' couldn't skip that slash, so it
# matched 'run' as the verb but then found '/' instead of '?' and failed
# to capture the query string. Now we strip any trailing slashes from
# the verb before the query marker.
$rest = $rest -replace '^/+',''

# Split verb from query string, tolerating optional slash(es) between them
$verb = ''
$queryRaw = ''
if ($rest -match '^([a-zA-Z]+)/*(\?(.*))?') {
    $verb = $Matches[1].ToLower()
    $queryRaw = if ($Matches[3]) { $Matches[3] } else { '' }
}

# Strip trailing slashes that Windows sometimes adds
$queryRaw = $queryRaw.TrimEnd('/')

# Parse key=value pairs
$params = @{}
if ($queryRaw) {
    foreach ($pair in $queryRaw.Split('&')) {
        if ($pair -match '^([^=]+)=(.*)$') {
            $k = $Matches[1]
            $v = [System.Uri]::UnescapeDataString($Matches[2])
            $params[$k] = $v
        }
    }
}

Write-Log 'INFO' "Parsed verb='$verb' params=$($params.Keys -join ',')"

# ==============================================================
# VERB DISPATCH
# ==============================================================
switch ($verb) {

    'run' {
        # fieldops://run?script=<name>[&args=<base64>]
        if (-not $params.ContainsKey('script')) {
            Write-Log 'ERROR' "Missing 'script' parameter"
            break
        }

        $scriptName = $params['script']

        # SECURITY: script name must be a simple filename, no path components
        if ($scriptName -match '[\\/]|\.\.') {
            Write-Log 'ERROR' "Script name contains path characters (rejected): $scriptName"
            break
        }
        if ($scriptName -notmatch '^Invoke-[A-Za-z0-9_-]+\.ps1$') {
            Write-Log 'ERROR' "Script name doesn't match Invoke-*.ps1 pattern: $scriptName"
            break
        }

        # Find the script in SCRIPTS\ subtree (all subfolders allowed)
        $found = $null
        try {
            $found = Get-ChildItem -Path $scriptsDir -Filter $scriptName -Recurse -File -ErrorAction SilentlyContinue |
                     Select-Object -First 1
        } catch { }

        if (-not $found) {
            Write-Log 'ERROR' "Script not found anywhere in $scriptsDir : $scriptName"
            break
        }

        # SECURITY: resolved path must still be under $scriptsDir (no symlink escapes)
        $resolvedPath = $found.FullName
        if (-not $resolvedPath.StartsWith($scriptsDir, [StringComparison]::OrdinalIgnoreCase)) {
            Write-Log 'ERROR' "Resolved path escaped SCRIPTS subtree: $resolvedPath"
            break
        }

        # Decode optional arguments (base64 to handle quotes, spaces, etc)
        $argsList = @()
        if ($params.ContainsKey('args') -and $params['args']) {
            try {
                $b64 = $params['args']
                if ($b64.Length -gt 2000) {
                    Write-Log 'ERROR' "Arguments too long (max 2000 chars base64)"
                    break
                }
                $decoded = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
                # Split on spaces but respect quoted substrings
                $argsList = [regex]::Matches($decoded, '(?:[^\s"]+|"[^"]*")+') | ForEach-Object { $_.Value.Trim('"') }
            } catch {
                Write-Log 'ERROR' "Failed to decode args: $_"
                break
            }
        }

        Write-Log 'OK' "Launching: $resolvedPath $($argsList -join ' ')"
        Write-Host ''
        Write-Host "  Script: $($found.Name)" -ForegroundColor Green
        Write-Host "  Folder: $(Split-Path -Parent $resolvedPath)" -ForegroundColor DarkGray
        if ($argsList.Count -gt 0) {
            Write-Host "  Args  : $($argsList -join ' ')" -ForegroundColor DarkGray
        }
        Write-Host ''
        Write-Host '  Opening in new PowerShell window...' -ForegroundColor Cyan
        Write-Host ''

        # Launch in a new PowerShell window so user can see output
        # -NoExit keeps the window open after the script finishes
        $launchArgs = @(
            '-NoProfile'
            '-ExecutionPolicy', 'Bypass'
            '-NoExit'
            '-Command'
            "Set-Location '$(Split-Path -Parent $resolvedPath)'; & '$resolvedPath' $($argsList -join ' ')"
        )
        try {
            Start-Process powershell.exe -ArgumentList $launchArgs
            Write-Log 'OK' "Process started successfully"
            Start-Sleep -Milliseconds 800
            exit 0
        } catch {
            Write-Log 'ERROR' "Failed to launch: $_"
        }
    }

    'doc' {
        # fieldops://doc?file=<relative-path-under-DOCS>
        if (-not $params.ContainsKey('file')) { Write-Log 'ERROR' "Missing 'file' parameter"; break }
        $rel = $params['file']
        if ($rel -match '\.\.') { Write-Log 'ERROR' "Path traversal rejected"; break }
        $docPath = Join-Path $docsDir $rel
        if (-not (Test-Path $docPath)) { Write-Log 'ERROR' "Doc not found: $docPath"; break }
        Write-Log 'OK' "Opening doc: $docPath"
        Start-Process $docPath
        Start-Sleep -Milliseconds 500
        exit 0
    }

    'open' {
        # fieldops://open?path=<encoded-path-under-USB-root>
        if (-not $params.ContainsKey('path')) { Write-Log 'ERROR' "Missing 'path' parameter"; break }
        $target = $params['path']
        # SECURITY: must resolve under USB root
        try {
            $resolved = [System.IO.Path]::GetFullPath((Join-Path $usbRoot $target))
        } catch {
            Write-Log 'ERROR' "Invalid path: $target"
            break
        }
        if (-not $resolved.StartsWith($usbRoot, [StringComparison]::OrdinalIgnoreCase)) {
            Write-Log 'ERROR' "Path escaped USB root: $resolved"
            break
        }
        if (-not (Test-Path $resolved)) { Write-Log 'ERROR' "Path not found: $resolved"; break }
        Write-Log 'OK' "Opening: $resolved"
        Start-Process $resolved
        Start-Sleep -Milliseconds 500
        exit 0
    }

    'playbook' {
        # fieldops://playbook?name=<playbookname>
        if (-not $params.ContainsKey('name')) { Write-Log 'ERROR' "Missing 'name' parameter"; break }
        $pbName = $params['name']
        if ($pbName -match '[\\/]|\.\.') { Write-Log 'ERROR' "Playbook name contains path chars"; break }

        $pbPath = Join-Path $playbooksDir $pbName
        if (-not (Test-Path $pbPath)) {
            # Try with common extensions
            foreach ($ext in @('.ps1','.json','.yml','.yaml','.txt')) {
                $try = "$pbPath$ext"
                if (Test-Path $try) { $pbPath = $try; break }
            }
        }
        if (-not (Test-Path $pbPath)) { Write-Log 'ERROR' "Playbook not found: $pbName"; break }

        Write-Log 'OK' "Opening playbook: $pbPath"
        if ($pbPath -match '\.ps1$') {
            # Execute .ps1 playbooks in a new window
            Start-Process powershell.exe -ArgumentList @(
                '-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-Command',
                "& '$pbPath'"
            )
        } else {
            # Open other playbook files in default app
            Start-Process $pbPath
        }
        Start-Sleep -Milliseconds 500
        exit 0
    }

    default {
        Write-Log 'ERROR' "Unknown verb: '$verb'"
        Write-Host ''
        Write-Host '  Valid verbs:' -ForegroundColor Yellow
        Write-Host '    run      - launch a script from SCRIPTS\'
        Write-Host '    doc      - open a doc from DOCS\'
        Write-Host '    open     - open a file/folder under USB root'
        Write-Host '    playbook - run a playbook from PLAYBOOKS\'
    }
}

# Error path -- keep window open so user can read
Write-Host ''
Write-Host '  Operation failed. See log for details:' -ForegroundColor Red
Write-Host "  $logFile" -ForegroundColor DarkGray
Write-Host ''
Write-Host '  Press any key to close...' -ForegroundColor DarkGray
$null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
exit 1
