#Requires -Version 5.1
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Ousman Dorley. See LICENSE at the repository root.
<#
.SYNOPSIS
    FieldOps Pro - Session Manager
.DESCRIPTION
    Creates and manages JSON session files that track every action taken
    during a machine visit. Enables session continuity: when you revisit
    a machine, FieldOps detects previous sessions and offers to resume.

    Sessions stored at: E:\LOGS\sessions\HOSTNAME_YYYYMMDD_HHMMSS.json
    Author: Ousman Dorley | EU Deployment | FieldOps Pro
#>

$script:_currentSession = $null
$script:_sessionPath    = $null

function New-FieldOpsSession {
    <#
    .SYNOPSIS
        Creates a new session for the current machine visit.
    #>
    param(
        [string]$LogRoot,
        [PSCustomObject]$MachineProfile = $null,
        [PSCustomObject]$Technician = $null
    )

    $sessDir = Join-Path $LogRoot 'sessions'
    if (-not (Test-Path $sessDir)) { New-Item $sessDir -ItemType Directory -Force | Out-Null }

    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $hostname  = $env:COMPUTERNAME
    $filename  = "${hostname}_${timestamp}.json"

    $session = [PSCustomObject]@{
        SessionID    = [guid]::NewGuid().ToString('N').Substring(0,12)
        Hostname     = $hostname
        StartTime    = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        EndTime      = $null
        Technician   = if ($Technician) { $Technician.Name } else { $env:USERNAME }
        TechID       = if ($Technician) { $Technician.EmployeeID } else { '' }
        Region       = if ($Technician) { $Technician.Region } else { '' }
        Machine      = if ($MachineProfile) {
            [PSCustomObject]@{
                Manufacturer = $MachineProfile.Manufacturer
                Model        = $MachineProfile.Model
                Serial       = $MachineProfile.SerialNumber
                OS           = "$($MachineProfile.OSName) $($MachineProfile.OSBuild)"
                AAD          = $MachineProfile.AADState
                Intune       = $MachineProfile.IntuneState
                IP           = $MachineProfile.PrimaryIP
            }
        } else { $null }
        Actions      = @()
        Findings     = @()
        Warnings     = @()
        ScriptsRun   = @()
        Status       = 'Active'
    }

    $script:_sessionPath = Join-Path $sessDir $filename
    $script:_currentSession = $session

    # Write initial session file
    Save-CurrentSession

    return $session
}

function Add-SessionAction {
    <#
    .SYNOPSIS
        Records an action taken during this session.
    #>
    param(
        [string]$Category,     # e.g. 'Diagnostic', 'Deployment', 'Security', 'Tool'
        [string]$Action,       # e.g. 'Ran PCHealth diagnostic'
        [string]$Result = '',  # e.g. 'Pass', 'Fail', 'Warning'
        [string]$Detail = ''   # Any extra detail
    )

    if (-not $script:_currentSession) { return }

    $entry = [PSCustomObject]@{
        Timestamp = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Category  = $Category
        Action    = $Action
        Result    = $Result
        Detail    = $Detail
    }

    $script:_currentSession.Actions += $entry
    Save-CurrentSession
}

function Add-SessionFinding {
    <#
    .SYNOPSIS
        Records a diagnostic finding (issue discovered).
    #>
    param(
        [string]$Severity,  # 'Critical', 'Warning', 'Info'
        [string]$Component, # 'Disk', 'RAM', 'Network', 'Security', etc.
        [string]$Finding,
        [string]$Recommendation = ''
    )

    if (-not $script:_currentSession) { return }

    $entry = [PSCustomObject]@{
        Timestamp      = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Severity       = $Severity
        Component      = $Component
        Finding        = $Finding
        Recommendation = $Recommendation
    }

    $script:_currentSession.Findings += $entry
    if ($Severity -eq 'Critical' -or $Severity -eq 'Warning') {
        $script:_currentSession.Warnings += "$Severity [$Component] $Finding"
    }
    Save-CurrentSession
}

function Add-SessionScript {
    <#
    .SYNOPSIS
        Records that a script was executed.
    #>
    param(
        [string]$ScriptName,
        [string]$Duration = '',
        [string]$Result = ''
    )

    if (-not $script:_currentSession) { return }

    $entry = [PSCustomObject]@{
        Timestamp  = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Script     = $ScriptName
        Duration   = $Duration
        Result     = $Result
    }

    $script:_currentSession.ScriptsRun += $entry
    Save-CurrentSession
}

function Close-FieldOpsSession {
    <#
    .SYNOPSIS
        Closes the current session and writes final state.
    #>
    if (-not $script:_currentSession) { return }

    $script:_currentSession.EndTime = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    $script:_currentSession.Status  = 'Completed'
    Save-CurrentSession

    return $script:_sessionPath
}

function Get-PreviousSessions {
    <#
    .SYNOPSIS
        Finds previous sessions for the current machine.
    #>
    param([string]$LogRoot)

    $sessDir = Join-Path $LogRoot 'sessions'
    if (-not (Test-Path $sessDir)) { return @() }

    $hostname = $env:COMPUTERNAME
    $sessions = @()

    Get-ChildItem $sessDir -Filter "${hostname}_*.json" -EA SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 5 |
    ForEach-Object {
        try {
            $data = Get-Content $_.FullName -Raw -EA SilentlyContinue | ConvertFrom-Json
            $sessions += [PSCustomObject]@{
                File        = $_.FullName
                Date        = $data.StartTime
                Technician  = $data.Technician
                Actions     = $data.Actions.Count
                Findings    = $data.Findings.Count
                Warnings    = $data.Warnings.Count
                Status      = $data.Status
                ScriptsRun  = ($data.ScriptsRun | ForEach-Object { $_.Script }) -join ', '
            }
        } catch {}
    }

    return $sessions
}

function Get-CurrentSession {
    return $script:_currentSession
}

function Save-CurrentSession {
    if (-not $script:_currentSession -or -not $script:_sessionPath) { return }
    try {
        $script:_currentSession | ConvertTo-Json -Depth 10 | Set-Content $script:_sessionPath -Encoding UTF8 -Force
    } catch {}
}

Export-ModuleMember -Function New-FieldOpsSession, Add-SessionAction, Add-SessionFinding,
                              Add-SessionScript, Close-FieldOpsSession, Get-PreviousSessions,
                              Get-CurrentSession
