# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Ousman Dorley. See LICENSE at the repository root.
# Utils.psm1 - Shared utility functions (WinPE compatible)
# All function names use PowerShell approved verbs to suppress warnings

function Test-AdminPrivilege {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = [Security.Principal.WindowsPrincipal]$id
    return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Keep old name as alias for backward compatibility
function Assert-Admin {
    if (-not (Test-AdminPrivilege)) {
        Write-Host "ERROR: This script must run as Administrator." -ForegroundColor Red
        exit 1
    }
}

function Get-SystemSummary {
    $os  = Get-CimInstance Win32_OperatingSystem
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $ram = (Get-CimInstance Win32_PhysicalMemory | Measure-Object Capacity -Sum).Sum / 1GB
    return [PSCustomObject]@{
        OS      = $os.Caption
        Build   = $os.BuildNumber
        CPU     = $cpu.Name
        RAM_GB  = [math]::Round($ram,1)
        Uptime  = (Get-Date) - $os.LastBootUpTime
    }
}

function Wait-UserInput {
    param([string]$Message = 'Press any key to continue...')
    Write-Host $Message -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
}

# Keep old name as alias
function Pause-Script {
    param([string]$Message = 'Press any key to continue...')
    Wait-UserInput -Message $Message
}

function Get-RecentEvents {
    # WinPE-compatible replacement for Get-WinEvent
    $events = @()
    try {
        $events = Get-WinEvent -FilterHashtable @{ LogName='System'; Level=1,2 } -MaxEvents 10 -ErrorAction Stop
    } catch {
        $events = @()
    }
    return $events
}

function Test-WinPE {
    return (Test-Path 'X:\Windows\System32\wpeinit.exe')
}

function Get-USBBase {
    param([string]$ScriptRoot)
    return Split-Path (Split-Path $ScriptRoot -Parent) -Parent
}

function Invoke-WithRetry {
    param(
        [scriptblock]$ScriptBlock,
        [int]$MaxRetries = 3,
        [int]$DelaySeconds = 2
    )
    $attempt = 0
    do {
        $attempt++
        try {
            & $ScriptBlock
            return $true
        } catch {
            if ($attempt -lt $MaxRetries) {
                Write-Host "  Retry $attempt/$MaxRetries in ${DelaySeconds}s..." -ForegroundColor Yellow
                Start-Sleep -Seconds $DelaySeconds
            } else {
                throw $_
            }
        }
    } while ($attempt -lt $MaxRetries)
    return $false
}

function Get-FieldOpsVersion {
    <#
    .SYNOPSIS
        The product version, from CONFIG\version.json. Never throws.

    .DESCRIPTION
        One number for the whole product. Reports name the build that produced
        them -- an auditor holding a compliance report needs to know which
        version's rules were applied -- so the value belongs in the HTML, but
        it must never come from a literal typed into eight separate templates.
        That is what produced fifteen disagreeing numbers in v0.6.0.

        Walks up from the calling script to find CONFIG\version.json, so it
        works from any depth under the deployment root and from a copy of the
        tree in a temp directory.

        Returns '' when the file is missing or malformed. Every caller renders
        a version-less banner rather than failing, matching the contract every
        other optional dependency in this tree follows.

    .PARAMETER From
        Directory to start walking up from. Defaults to this module's location.

    .EXAMPLE
        $VERSION = Get-FieldOpsVersion -From $PSScriptRoot
    #>
    param([string]$From = $PSScriptRoot)

    try {
        $dir = $From
        for ($i = 0; $i -lt 6 -and $dir; $i++) {
            $candidate = Join-Path $dir 'CONFIG\version.json'
            if (Test-Path -LiteralPath $candidate) {
                $v = (Get-Content -LiteralPath $candidate -Raw -ErrorAction Stop | ConvertFrom-Json).product
                if ($v -and "$v".Trim() -ne '') { return "$v".Trim() }
                return ''
            }
            $parent = Split-Path -Parent $dir
            if ($parent -eq $dir) { break }
            $dir = $parent
        }
    } catch { }
    return ''
}

Export-ModuleMember -Function Test-AdminPrivilege, Assert-Admin, Get-SystemSummary, Wait-UserInput, Pause-Script, Get-RecentEvents, Test-WinPE, Get-USBBase, Invoke-WithRetry, Get-FieldOpsVersion
