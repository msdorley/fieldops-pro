# Logger.psm1 - GDPR-compliant structured logging (WinPE compatible)
# GDPR rule: log only technical data. No usernames, passwords, or personal data.

$script:Session = @{
    Path      = ""
    StartTime = (Get-Date -Format 'o')
    TechID    = $env:USERNAME
    HostName  = $env:COMPUTERNAME
    Module    = ""
    Events    = [System.Collections.Generic.List[PSObject]]::new()
}

function Start-Log {
    param([string]$Module)
    $logDir = Join-Path $PSScriptRoot "..\..\LOGS"
    if (-not (Test-Path $logDir)) {
        try { New-Item -ItemType Directory -Path $logDir -Force | Out-Null } catch {}
    }
    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $script:Session.Module = $Module
    $script:Session.Path   = Join-Path $logDir "${stamp}_$($env:COMPUTERNAME)_${Module}.json"
    Write-Log -LogEvent "SESSION_START" -Detail "Module loaded: $Module"
}

# Alias for backward compatibility
function Initialize-Log {
    param([string]$Module)
    Start-Log -Module $Module
}

function Write-Log {
    param(
        [string]$LogEvent,
        [string]$Detail,
        [ValidateSet("INFO","OK","WARN","ERROR")][string]$Level = "INFO"
    )
    $entry = [PSCustomObject]@{
        Timestamp = (Get-Date -Format 'o')
        Level     = $Level
        LogEvent  = $LogEvent
        Detail    = $Detail
    }
    $script:Session.Events.Add($entry)
    if ($script:Session.Path -ne "") {
        try {
            $script:Session | ConvertTo-Json -Depth 5 | Set-Content -Path $script:Session.Path -Encoding UTF8 -EA SilentlyContinue
        } catch {}
    }
    $colors = @{ INFO = "Cyan"; OK = "Green"; WARN = "Yellow"; ERROR = "Red" }
    Write-Host "[$Level] $LogEvent - $Detail" -ForegroundColor $colors[$Level]
}

function Stop-Log {
    param([string]$Result = 'COMPLETED')
    Write-Log -LogEvent "SESSION_END" -Detail "Result: $Result"
    if ($script:Session.Path -ne "") {
        Write-Host "`nLog saved: $($script:Session.Path)" -ForegroundColor DarkCyan
    }
}

# Alias for backward compatibility
function Close-Log {
    param([string]$Result = 'COMPLETED')
    Stop-Log -Result $Result
}

Export-ModuleMember -Function Start-Log, Initialize-Log, Write-Log, Stop-Log, Close-Log
