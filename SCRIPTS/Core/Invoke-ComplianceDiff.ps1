#Requires -Version 5.1
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Ousman Dorley. See LICENSE at the repository root.
<#
.SYNOPSIS
    FieldOps Pro -- AI-Powered Compliance Diff Engine v1.2.1
.DESCRIPTION
    Captures comprehensive machine state snapshots (12 categories: services,
    registry, scheduled tasks, firewall rules, users, software, ports,
    certificates, startup items, SMB shares, BitLocker, Defender), diffs
    Before vs After any field action, and submits the diff to the Anthropic
    AI API for expert-level classification of every change -- Improvement,
    Regression, Neutral, or Suspicious -- with executive summary, security
    delta score, CIS/NIST references, and a rollback script for every
    reversible change.

    Auto mode (default): if no Before snapshot exists for this host, takes
    Before. If one exists, takes After and runs full AI-powered diff.

.PARAMETER Mode
    Auto (default), Before, After, Compare.
    Auto detects which phase is needed from stored snapshots.
.PARAMETER SnapshotId
    Tag for this snapshot pair (e.g. ticket number). Used to match
    Before and After snapshots. Defaults to HOSTNAME_DATE.
.PARAMETER BeforeFile
    Full path to Before snapshot JSON (Compare mode only).
.PARAMETER AfterFile
    Full path to After snapshot JSON (Compare mode only).
.PARAMETER NoAI
    Skip Anthropic API call. Use local rule-based classification only.
.PARAMETER IncidentId
    Ticket reference attached to this diff report.
.PARAMETER OpenReport
    Open the HTML report after generation.
.EXAMPLE
    .\Invoke-ComplianceDiff.ps1                          # Auto mode
    .\Invoke-ComplianceDiff.ps1 -Mode Before             # Force Before snapshot
    .\Invoke-ComplianceDiff.ps1 -Mode After              # Force After + diff
    .\Invoke-ComplianceDiff.ps1 -IncidentId "INC-2026-04891"
    .\Invoke-ComplianceDiff.ps1 -NoAI                    # Offline / no API key
    .\Invoke-ComplianceDiff.ps1 -Mode Compare -BeforeFile "E:\..." -AfterFile "E:\..."
#>
[CmdletBinding()]
param(
    [ValidateSet('Auto','Before','After','Compare','Diagnose','QuickDiff','Cleanup','Menu','LastReport')]
    [string]$Mode = 'Menu',
    [string]$SnapshotId   = '',
    [string]$BeforeFile   = '',
    [string]$AfterFile    = '',
    [switch]$NoAI,
    [string]$IncidentId   = '',
    [switch]$OpenReport,
    [string]$Action       = '',           # v1.2: script to execute between Before/After in QuickDiff
    [int]$KeepSnapshots   = 10            # v1.2: Cleanup keeps this many recent snapshots per host
)

$ErrorActionPreference = 'Continue'

# v1.2.1: Load compression assembly for GZip snapshot support
try { Add-Type -AssemblyName System.IO.Compression 2>$null } catch { }

# ==============================================================
# PATH RESOLUTION -- Two-level Split-Path to reach USB root
# ==============================================================
$scriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Path   # E:\SCRIPTS\Core
$scriptsDir   = Split-Path -Parent $scriptDir                      # E:\SCRIPTS
$usbRoot      = Split-Path -Parent $scriptsDir                     # E:\
$reportsDir   = Join-Path $usbRoot 'REPORTS'
$snapshotDir  = Join-Path $reportsDir 'Snapshots'
$configDir    = Join-Path $usbRoot 'CONFIG'
$logsDir      = Join-Path $usbRoot 'LOGS'

# ==============================================================
# CONFIG
# ==============================================================
# Defaults (overridden by config file if present)
$techName  = if ($env:USERNAME) { $env:USERNAME } else { 'Unknown Technician' }
$orgName   = 'FieldOps Pro'
$apiKey    = ''
$cfgSource = ''  # track which file we loaded for the banner

# Recursive field finder: walks a parsed JSON object (PSCustomObject or
# hashtable, possibly nested) and returns the first non-empty string value
# whose property name matches any of the supplied aliases (case-insensitive).
# Handles both flat schemas ({"TechnicianName":"Bob"}) and nested ones
# ({"technician":{"name":"Bob"}}) so we don't have to know the exact shape
# of technician.json ahead of time.
function Find-ConfigValue {
    param($Obj, [string[]]$Aliases, [int]$Depth = 0)
    if ($null -eq $Obj -or $Depth -gt 5) { return $null }

    # Enumerate properties on PSCustomObject or keys on hashtable/ordered
    $props = @()
    if ($Obj -is [System.Collections.IDictionary]) {
        $props = @($Obj.Keys | ForEach-Object { [PSCustomObject]@{ Name=$_; Value=$Obj[$_] } })
    } elseif ($Obj.PSObject -and $Obj.PSObject.Properties) {
        $props = @($Obj.PSObject.Properties | ForEach-Object { [PSCustomObject]@{ Name=$_.Name; Value=$_.Value } })
    } else {
        return $null
    }

    # First pass: match on this level (scalars only; nested objects get
    # picked up by the second pass so a key like "technician":{"name":"Bob"}
    # doesn't match on the outer key and return "@{name=Bob}")
    foreach ($p in $props) {
        foreach ($alias in $Aliases) {
            if ($p.Name -and ($p.Name -ieq $alias)) {
                $v = $p.Value
                if ($null -eq $v) { continue }
                if ($v -is [string]) {
                    if ($v.Trim() -ne '') { return $v.Trim() }
                } elseif ($v -is [ValueType]) {
                    $s = "$v".Trim()
                    if ($s -ne '') { return $s }
                }
                # Complex object: do not stringify here; recursion below
                # will descend into it.
            }
        }
    }

    # Second pass: recurse into nested objects. Skip arrays/collections --
    # we only want to descend into dictionaries and PSCustomObjects.
    foreach ($p in $props) {
        $v = $p.Value
        if ($null -eq $v) { continue }
        if ($v -is [string] -or $v -is [ValueType]) { continue }
        if ($v -is [System.Collections.IList]) { continue }
        $sub = Find-ConfigValue -Obj $v -Aliases $Aliases -Depth ($Depth + 1)
        if ($null -ne $sub) { return $sub }
    }
    return $null
}

# Try known config filenames in order of preference. The FieldOps convention
# is technician.json; FieldOps.config.json is a legacy fallback.
$cfgCandidates = @(
    (Join-Path $configDir 'technician.json'),
    (Join-Path $configDir 'FieldOps.config.json'),
    (Join-Path $configDir 'fieldops.json'),
    (Join-Path $configDir 'config.json')
)
$cfgFile = $cfgCandidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1

if ($cfgFile) {
    try {
        $cfg = Get-Content $cfgFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $cfgSource = [IO.Path]::GetFileName($cfgFile)

        $techAliases = @(
            'TechnicianName','Technician','TechName','Tech','Name',
            'FullName','DisplayName','UserName','User','Operator','Engineer'
        )
        $orgAliases  = @(
            'OrgName','Organisation','Organization','Company',
            'Employer','Client','Tenant','Site'
        )
        $keyAliases  = @(
            'AnthropicApiKey','AnthropicKey','ApiKey','AiKey',
            'ClaudeApiKey','ClaudeKey','Key'
        )

        $v = Find-ConfigValue -Obj $cfg -Aliases $techAliases
        if ($v) { $techName = $v }

        $v = Find-ConfigValue -Obj $cfg -Aliases $orgAliases
        if ($v) { $orgName = $v }

        $v = Find-ConfigValue -Obj $cfg -Aliases $keyAliases
        if ($v) { $apiKey = $v }

        # Model override from config (optional)
        $modelAliases = @('Model','AiModel','ClaudeModel','ApiModel')
        $v = Find-ConfigValue -Obj $cfg -Aliases $modelAliases
        if ($v) { $script:cfgModel = $v }
    } catch {
        Write-Host "  [WARN] Failed to parse config file '$cfgFile': $_" -ForegroundColor Yellow
    }
}

# Environment variable fallback for API key (standard Anthropic convention)
if ($apiKey -eq '' -and $env:ANTHROPIC_API_KEY) {
    $apiKey = $env:ANTHROPIC_API_KEY
}

# ==============================================================
# CONSTANTS
# ==============================================================
$VERSION    = '1.2.1'
$NOW        = Get-Date
$HOSTNAME   = $env:COMPUTERNAME
$W          = 72

# AI Model selection: config override > env var > smart default.
# The Evaluation access (free) plan typically has access to Sonnet/Haiku
# but NOT Opus. We default to Sonnet for broadest compatibility.
# Users with paid plans can override to opus in technician.json:
#   { "Model": "claude-opus-4-6" }
$AI_MODEL = 'claude-sonnet-4-6'
if ($script:cfgModel) {
    $AI_MODEL = $script:cfgModel
} elseif ($env:ANTHROPIC_MODEL) {
    $AI_MODEL = $env:ANTHROPIC_MODEL
}

# The endpoint, API version, and model fallback chain that used to live here
# are gone: transport, model fallback, retry, cost ceilings and audit logging
# are all owned by FieldOps-AIClient now (6.5-R1, 6.5-D12). $AI_MODEL survives
# only as the label shown in the banner and report; the model actually used is
# whatever the client's fallback chain settled on, and is written back to it
# after a successful call.

if ($SnapshotId -eq '') { $SnapshotId = "$HOSTNAME`_$($NOW.ToString('yyyyMMdd'))" }

# --------------------------------------------------------------
# AI CLIENT
# --------------------------------------------------------------
# Load the shared client. Path is ..\AI from Core. A failure here is not fatal:
# AI is an optional enrichment (6.5-R10) and every call site already has a
# local-rules fallback, so the run continues exactly as it does without a key.
$script:AIClientLoaded = $false
try {
    $aiClientPath = Join-Path $PSScriptRoot '..\AI\FieldOps-AIClient.psm1'
    if (Test-Path $aiClientPath) {
        Import-Module $aiClientPath -Force -DisableNameChecking -ErrorAction Stop
        $script:AIClientLoaded = $true
    }
} catch {
    Write-Host "  [WARN] AI client load failed (non-fatal): $_" -ForegroundColor Yellow
}

# ==============================================================
# CONSOLE HELPERS
# ==============================================================
function Write-Banner {
    Write-Host ('=' * $W) -ForegroundColor Cyan
    Write-Host "  FIELDOPS PRO -- AI COMPLIANCE DIFF ENGINE v$VERSION" -ForegroundColor White
    Write-Host ('=' * $W) -ForegroundColor Cyan
    Write-Host "  Technician : $techName"
    Write-Host "  Host       : $HOSTNAME"
    Write-Host "  Date       : $($NOW.ToString('yyyy-MM-dd HH:mm:ss'))"
    Write-Host "  Config     : $(if ($cfgSource) { $cfgSource } else { '(none found -- using defaults)' })"
    $aiLine = if ($NoAI) {
        'LOCAL RULES (-NoAI specified)'
    } elseif ($apiKey -eq '') {
        'LOCAL RULES (no API key found)'
    } else {
        # Two things this line used to claim and could not know.
        #
        # It printed $AI_MODEL, which at this point is still the compiled-in
        # default -- a model marked legacy in the pricing config and one the
        # tier mapping will never select. The client resolves the model at call
        # time and $AI_MODEL is corrected afterwards from $call.Model, so the
        # report was right and only this pre-call banner misinformed.
        #
        # It also printed the first fourteen characters of the key. The prefix
        # is public rather than secret, but Test-Installation deliberately
        # prints nothing key-shaped, and one policy applied in one place and not
        # the other is how a habit erodes. Neither line prints it now.
        'ENABLED (model resolved at call time)'
    }
    Write-Host "  AI Engine  : $aiLine"
    Write-Host ('=' * $W) -ForegroundColor Cyan
}

function Write-Section { param([string]$T)
    Write-Host ''
    Write-Host "  $T" -ForegroundColor Yellow
    Write-Host ('  ' + ('-' * ($W - 2))) -ForegroundColor DarkGray
}

function Write-Step { param([string]$M, [string]$C = 'Gray')
    Write-Host "    $M" -ForegroundColor $C
}

function Write-Category { param([string]$Name, [int]$Count)
    Write-Host "    [+] $Name : $Count item(s) captured" -ForegroundColor DarkGray
}

function Write-AIFailureGuidance {
    <#
        Turn a client failure result into something a technician can act on.

        Branching is on .FailureReason, which is a closed vocabulary and the
        only field the client guarantees. .FailureDetail is the provider's own
        wording; it is DISPLAYED unconditionally, and additionally sniffed for
        the two cases worth a specific remedy (no credits, rejected key).

        That sniff is best-effort by design: if the provider rewords its
        messages the keyword match stops firing, and the operator still sees
        the raw detail line -- which is the thing that actually tells them what
        to fix. The heuristic adds a shortcut; it is never load-bearing.
    #>
    param($Call)

    $reason = [string]$Call.FailureReason
    $detail = [string]$Call.FailureDetail

    switch ($reason) {
        'NoApiKey' {
            Write-Step "[WARN] AI: no API key found in config or ANTHROPIC_API_KEY." 'Yellow'
        }
        'PricingConfigUnavailable' {
            # Fail-closed by design: with no pricing table the client cannot
            # enforce a cost ceiling, so it refuses rather than spend blind.
            Write-Step "[WARN] AI: pricing config unreadable -- cost ceiling cannot be enforced." 'Yellow'
            Write-Step "  Check CONFIG\AIModelPricing.json" 'Yellow'
        }
        'EstimateExceedsCeiling' {
            Write-Step "[WARN] AI: estimated cost exceeds the per-call ceiling. Prompt too large." 'Yellow'
        }
        'SessionCeilingExceeded' {
            Write-Step "[WARN] AI: session cost ceiling reached. Further calls refused this run." 'Yellow'
        }
        'ModelUnavailable' {
            Write-Step "[WARN] AI: no configured model is available on this plan." 'Yellow'
        }
        'TransientFailureRetriesExhausted' {
            Write-Step "[WARN] AI: provider unavailable after retries (rate limit or overload)." 'Yellow'
            Write-Step "  This usually clears on its own. Try again shortly." 'Yellow'
        }
        'MalformedResponse' {
            Write-Step "[WARN] AI: provider returned an unexpected response shape." 'Yellow'
        }
        'UnknownTaskTier' {
            Write-Step "[WARN] AI: unknown task tier requested -- configuration error." 'Yellow'
        }
        default {
            Write-Step "[WARN] AI unavailable ($reason)." 'Yellow'
        }
    }

    if ($detail) {
        Write-Step "  Provider says: $detail" 'Yellow'

        if ($detail -match 'credit balance|too low|billing|purchase credits') {
            Write-Step "  Add credits: https://console.anthropic.com -> Plans & Billing (`$5 min)" 'Yellow'
        } elseif ($detail -match 'invalid.*key|authentication|x-api-key') {
            Write-Step "  Get a fresh key: https://console.anthropic.com -> API Keys" 'Yellow'
        }
    }

    if ($Call.HttpStatus -and $Call.HttpStatus -ne 0) {
        Write-Step "  HTTP status: $($Call.HttpStatus)" 'DarkGray'
    }
}

# ==============================================================
# SNAPSHOT CAPTURE -- 12 CATEGORIES
# ==============================================================

# --- 1. SERVICES ---
# v1.1.1 FIX: batched WMI lookup. The old version called Get-WmiObject
# with a filter once per service, producing 300-400 DCOM round-trips
# that could take 2-5 minutes on busy machines. Now we fetch all
# Win32_Service rows in ONE Get-CimInstance call and look up the
# start mode via hashtable (O(1) per service).
function Get-ServicesSnapshot {
    $items = [System.Collections.Generic.List[PSCustomObject]]::new()
    try {
        $wmiMap = @{}
        try {
            Get-CimInstance -ClassName Win32_Service -ErrorAction SilentlyContinue | ForEach-Object {
                if ($_.Name) { $wmiMap[$_.Name] = "$($_.StartMode)" }
            }
        } catch { }

        Get-Service -ErrorAction SilentlyContinue | ForEach-Object {
            $startType = if ($wmiMap.ContainsKey($_.Name)) { $wmiMap[$_.Name] } else { 'Unknown' }
            $null = $items.Add([PSCustomObject]@{
                Name        = $_.Name
                DisplayName = $_.DisplayName
                Status      = $_.Status.ToString()
                StartType   = $startType
            })
        }
    } catch { }
    return @($items)
}

# --- 2. REGISTRY (security-critical keys) ---
function Get-RegistrySnapshot {
    $snap = [ordered]@{}

    $keys = [ordered]@{
        'LSA'            = @{ Path='HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'; Props=@('RunAsPPL','LmCompatibilityLevel','RestrictAnonymous','RestrictAnonymousSAM','NoLMHash','DisableDomainCreds') }
        'UAC'            = @{ Path='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'; Props=@('EnableLUA','ConsentPromptBehaviorAdmin','ConsentPromptBehaviorUser','EnableVirtualization','PromptOnSecureDesktop') }
        'Winlogon'       = @{ Path='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'; Props=@('AutoAdminLogon','DefaultUserName','DefaultPassword','DefaultDomainName','CachedLogonsCount') }
        'WDigest'        = @{ Path='HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest'; Props=@('UseLogonCredential') }
        'SMBClient'      = @{ Path='HKLM:\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters'; Props=@('SMB1','RequireSecuritySignature','EnableSecuritySignature') }
        'SMBServer'      = @{ Path='HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters'; Props=@('SMB1','EnableSecuritySignature','RequireSecuritySignature','NullSessionPipes','NullSessionShares') }
        'RDP'            = @{ Path='HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'; Props=@('fDenyTSConnections','fAllowToGetHelp') }
        'RDPEncryption'  = @{ Path='HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'; Props=@('UserAuthentication','SecurityLayer','MinEncryptionLevel') }
        'RemoteRegistry' = @{ Path='HKLM:\SYSTEM\CurrentControlSet\Services\RemoteRegistry'; Props=@('Start','ImagePath') }
        'PSLogging'      = @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging'; Props=@('EnableScriptBlockLogging','EnableScriptBlockInvocationLogging') }
        'PSTranscription'= @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\Transcription'; Props=@('EnableTranscripting','OutputDirectory') }
        'PSModuleLog'    = @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ModuleLogging'; Props=@('EnableModuleLogging') }
        'Autorun'        = @{ Path='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Props=@('NoDriveTypeAutoRun','NoAutorun','HonorAutoRunSetting') }
        'LAPS'           = @{ Path='HKLM:\SOFTWARE\Policies\Microsoft Services\AdmPwd'; Props=@('AdmPwdEnabled','PasswordLength','PasswordAgeDays') }
        'NetworkSecurity'= @{ Path='HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\MSV1_0'; Props=@('NTLMMinServerSec','NTLMMinClientSec') }
        'HibernationFile'= @{ Path='HKLM:\SYSTEM\CurrentControlSet\Control\Power'; Props=@('HibernateEnabled') }
        'GuestAccount'   = @{ Path='HKLM:\SAM\SAM\Domains\Account\Users\000001F5'; Props=@('F') }
        'StartupRun'     = @{ Path='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Props=$null }
        'StartupRunUser' = @{ Path='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Props=$null }
        'StartupRunOnce' = @{ Path='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'; Props=$null }
        'HVCI'           = @{ Path='HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard'; Props=@('EnableVirtualizationBasedSecurity','RequirePlatformSecurityFeatures','HypervisorEnforcedCodeIntegrity') }
        'SecureBoot'     = @{ Path='HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State'; Props=@('UEFISecureBootEnabled') }
        'AuditPolicy'    = @{ Path='HKLM:\SECURITY\Policy\PolAdtEv'; Props=$null }
        'CrashControl'   = @{ Path='HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl'; Props=@('CrashDumpEnabled','AutoReboot') }
    }

    foreach ($keyName in $keys.Keys) {
        $kdef  = $keys[$keyName]
        $kpath = $kdef.Path
        $kprops= $kdef.Props
        $entry = [ordered]@{}
        try {
            if (Test-Path $kpath) {
                if ($null -eq $kprops) {
                    # Capture all values under this key
                    $item = Get-Item -Path $kpath -ErrorAction SilentlyContinue
                    if ($item) {
                        foreach ($vn in $item.GetValueNames()) {
                            try { $entry[$vn] = $item.GetValue($vn) } catch { }
                        }
                    }
                } else {
                    foreach ($prop in $kprops) {
                        try {
                            $v = Get-ItemPropertyValue -Path $kpath -Name $prop -ErrorAction SilentlyContinue
                            if ($null -ne $v) { $entry[$prop] = $v }
                        } catch { }
                    }
                }
            } else {
                $entry['__exists'] = $false
            }
        } catch { }
        $snap[$keyName] = $entry
    }

    return $snap
}

# --- 3. SCHEDULED TASKS ---
# FIX v1.0.1: In PS 5.1, try/catch is a statement, not an expression, so it
# cannot appear directly as a value inside [PSCustomObject]@{ ... }. The old
# version placed three try/catch blocks inline, which caused a cascading
# parser failure ("Le litteral de hachage est incomplet" + ~10 follow-ups).
# All try/catch logic is now precomputed into local variables BEFORE the
# hashtable is built. Also added a null-guard on LastRunTime (it's $null on
# tasks that have never run, which would have thrown NullReferenceException).
function Get-ScheduledTasksSnapshot {
    $items = [System.Collections.Generic.List[PSCustomObject]]::new()
    try {
        $tasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue)
        foreach ($t in $tasks) {

            # Actions -> pipe-joined string
            $actions = @()
            try {
                $actions = @($t.Actions | ForEach-Object {
                    if ($_.CimClass.CimClassName -eq 'MSFT_TaskExecAction') {
                        "$($_.Execute) $($_.Arguments)"
                    } else { $_.ToString() }
                })
            } catch { }

            # Principal / author
            $author = ''
            try {
                if ($t.Principal -and $t.Principal.UserId) { $author = $t.Principal.UserId }
            } catch { }

            # Task info (single call, reused for both fields)
            $lastResult = $null
            $lastRun    = ''
            try {
                $info = $t | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue
                if ($info) {
                    $lastResult = $info.LastTaskResult
                    if ($info.LastRunTime) {
                        try { $lastRun = $info.LastRunTime.ToString('o') } catch { $lastRun = '' }
                    }
                }
            } catch { }

            $null = $items.Add([PSCustomObject]@{
                TaskPath   = $t.TaskPath
                TaskName   = $t.TaskName
                State      = $t.State.ToString()
                Author     = $author
                Actions    = $actions -join ' | '
                LastResult = $lastResult
                LastRun    = $lastRun
            })
        }
    } catch { }
    return @($items)
}

# --- 4. FIREWALL RULES ---
function Get-FirewallSnapshot {
    $snap = [PSCustomObject]@{
        DomainEnabled  = $false
        PrivateEnabled = $false
        PublicEnabled  = $false
        Rules          = @()
    }
    try {
        $profiles = Get-NetFirewallProfile -ErrorAction SilentlyContinue
        foreach ($p in @($profiles)) {
            switch ($p.Name) {
                'Domain'  { $snap.DomainEnabled  = $p.Enabled }
                'Private' { $snap.PrivateEnabled = $p.Enabled }
                'Public'  { $snap.PublicEnabled  = $p.Enabled }
            }
        }
    } catch { }
    try {
        $rules = @(Get-NetFirewallRule -ErrorAction SilentlyContinue |
                   Where-Object { $_.Enabled -eq 'True' })
        $snap.Rules = @($rules | ForEach-Object {
            [PSCustomObject]@{
                Name      = $_.Name
                DisplayName = $_.DisplayName
                Direction = $_.Direction.ToString()
                Action    = $_.Action.ToString()
                Profile   = $_.Profile.ToString()
                Enabled   = $_.Enabled.ToString()
            }
        })
    } catch { }
    return $snap
}

# --- 5. LOCAL USERS ---
function Get-LocalUsersSnapshot {
    $items = [System.Collections.Generic.List[PSCustomObject]]::new()
    try {
        Get-LocalUser -ErrorAction SilentlyContinue | ForEach-Object {
            $null = $items.Add([PSCustomObject]@{
                Name               = $_.Name
                Enabled            = $_.Enabled
                PasswordRequired   = $_.PasswordRequired
                PasswordNeverExpires= $_.PasswordNeverExpires
                LastLogon          = if ($_.LastLogon) { $_.LastLogon.ToString('o') } else { '' }
                AccountExpires     = if ($_.AccountExpires) { $_.AccountExpires.ToString('o') } else { 'Never' }
                Description        = $_.Description
            })
        }
    } catch { }

    # Local group memberships
    $groups = [ordered]@{}
    try {
        foreach ($grp in @(Get-LocalGroup -ErrorAction SilentlyContinue)) {
            try {
                $members = @(Get-LocalGroupMember -Group $grp.Name -ErrorAction SilentlyContinue |
                             Select-Object -ExpandProperty Name)
                $groups[$grp.Name] = $members
            } catch { $groups[$grp.Name] = @() }
        }
    } catch { }

    return [PSCustomObject]@{ Users=$items.ToArray(); Groups=$groups }
}

# --- 6. INSTALLED SOFTWARE ---
function Get-SoftwareSnapshot {
    $items = [System.Collections.Generic.List[PSCustomObject]]::new()
    $seen  = @{}
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($path in $paths) {
        try {
            if (-not (Test-Path $path)) { continue }
            Get-ChildItem -Path $path -ErrorAction SilentlyContinue | ForEach-Object {
                try {
                    $dn = $_.GetValue('DisplayName')
                    $dv = $_.GetValue('DisplayVersion')
                    if ($dn -and -not $seen.ContainsKey("$dn|$dv")) {
                        $seen["$dn|$dv"] = $true
                        $null = $items.Add([PSCustomObject]@{
                            Name        = $dn
                            Version     = if ($dv) { $dv } else { '' }
                            Publisher   = $_.GetValue('Publisher')
                            InstallDate = $_.GetValue('InstallDate')
                        })
                    }
                } catch { }
            }
        } catch { }
    }
    return @($items | Sort-Object Name)
}

# --- 7. LISTENING PORTS ---
function Get-ListeningPortsSnapshot {
    $items = [System.Collections.Generic.List[PSCustomObject]]::new()
    try {
        $conns = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue)
        foreach ($c in $conns) {
            $procName = ''
            $procPath = ''
            try {
                $proc = Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue
                if ($proc) {
                    $procName = $proc.Name
                    try { $procPath = $proc.MainModule.FileName } catch { }
                }
            } catch { }
            $null = $items.Add([PSCustomObject]@{
                Protocol  = 'TCP'
                LocalPort = $c.LocalPort
                LocalAddr = $c.LocalAddress
                PID       = $c.OwningProcess
                ProcessName= $procName
                ProcessPath= $procPath
            })
        }
    } catch { }
    try {
        $udp = @(Get-NetUDPEndpoint -ErrorAction SilentlyContinue |
                 Where-Object { $_.LocalPort -lt 49152 })
        foreach ($u in $udp) {
            $procName = ''
            try {
                $proc = Get-Process -Id $u.OwningProcess -ErrorAction SilentlyContinue
                if ($proc) { $procName = $proc.Name }
            } catch { }
            $null = $items.Add([PSCustomObject]@{
                Protocol  = 'UDP'
                LocalPort = $u.LocalPort
                LocalAddr = $u.LocalAddress
                PID       = $u.OwningProcess
                ProcessName= $procName
                ProcessPath= ''
            })
        }
    } catch { }
    return @($items | Sort-Object LocalPort)
}

# --- 8. CERTIFICATES (LocalMachine store) ---
function Get-CertificatesSnapshot {
    $items = [System.Collections.Generic.List[PSCustomObject]]::new()
    $stores = @('My','Root','CA','TrustedPeople','Disallowed')
    foreach ($store in $stores) {
        try {
            $certStore = New-Object System.Security.Cryptography.X509Certificates.X509Store($store,'LocalMachine')
            $certStore.Open('ReadOnly')
            foreach ($cert in $certStore.Certificates) {
                $now2 = Get-Date
                $null = $items.Add([PSCustomObject]@{
                    Store      = $store
                    Subject    = $cert.Subject
                    Issuer     = $cert.Issuer
                    Thumbprint = $cert.Thumbprint
                    NotBefore  = $cert.NotBefore.ToString('o')
                    NotAfter   = $cert.NotAfter.ToString('o')
                    Expired    = ($cert.NotAfter -lt $now2)
                    ExpiresSoon= ($cert.NotAfter -lt $now2.AddDays(30) -and $cert.NotAfter -ge $now2)
                    HasPrivKey = $cert.HasPrivateKey
                })
            }
            $certStore.Close()
        } catch { }
    }
    return @($items)
}

# --- 9. STARTUP ITEMS (beyond registry Run keys) ---
function Get-StartupItemsSnapshot {
    $items = [System.Collections.Generic.List[PSCustomObject]]::new()
    # Startup folders
    $folders = @(
        [System.Environment]::GetFolderPath('CommonStartup'),
        [System.Environment]::GetFolderPath('Startup')
    )
    foreach ($folder in $folders) {
        try {
            if (-not (Test-Path $folder)) { continue }
            Get-ChildItem -Path $folder -ErrorAction SilentlyContinue | ForEach-Object {
                $null = $items.Add([PSCustomObject]@{
                    Source = 'StartupFolder'
                    Name   = $_.Name
                    Path   = $_.FullName
                    Size   = $_.Length
                })
            }
        } catch { }
    }
    # HKLM Run keys
    @(
        @{ Key='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Src='HKLM_Run' },
        @{ Key='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Src='HKCU_Run' },
        @{ Key='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'; Src='HKLM_RunOnce' },
        @{ Key='HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Src='HKLM_Run_WOW' }
    ) | ForEach-Object {
        try {
            if (-not (Test-Path $_.Key)) { return }
            $item = Get-Item -Path $_.Key -ErrorAction SilentlyContinue
            if ($item) {
                foreach ($vn in $item.GetValueNames()) {
                    try {
                        $null = $items.Add([PSCustomObject]@{
                            Source = $_.Src
                            Name   = $vn
                            Path   = $item.GetValue($vn)
                            Size   = $null
                        })
                    } catch { }
                }
            }
        } catch { }
    }
    return @($items)
}

# --- 10. SMB SHARES ---
function Get-SmbSharesSnapshot {
    $items = [System.Collections.Generic.List[PSCustomObject]]::new()
    try {
        Get-SmbShare -ErrorAction SilentlyContinue | ForEach-Object {
            $null = $items.Add([PSCustomObject]@{
                Name        = $_.Name
                Path        = $_.Path
                Description = $_.Description
                ShareType   = $_.ShareType.ToString()
                IsAdmin     = $_.Name -match '\$$'
            })
        }
    } catch { }
    return @($items)
}

# --- 11. BITLOCKER STATUS ---
function Get-BitLockerSnapshot {
    $snap = [ordered]@{}
    try {
        $vols = @(Get-BitLockerVolume -ErrorAction SilentlyContinue)
        foreach ($v in $vols) {
            $snap[$v.MountPoint] = [PSCustomObject]@{
                MountPoint         = $v.MountPoint
                ProtectionStatus   = $v.ProtectionStatus.ToString()
                EncryptionMethod   = $v.EncryptionMethod.ToString()
                EncryptionPercentage = $v.EncryptionPercentage
                LockStatus         = $v.LockStatus.ToString()
                KeyProtectors      = @($v.KeyProtector | ForEach-Object { $_.KeyProtectorType.ToString() })
            }
        }
    } catch { }
    return $snap
}

# --- 12. DEFENDER STATUS ---
function Get-DefenderSnapshot {
    $snap = [ordered]@{}
    try {
        $status = Get-MpComputerStatus -ErrorAction SilentlyContinue
        if ($status) {
            $snap['RealTimeProtectionEnabled'] = $status.RealTimeProtectionEnabled
            $snap['AntivirusEnabled']          = $status.AntivirusEnabled
            $snap['AntispywareEnabled']        = $status.AntispywareEnabled
            $snap['BehaviorMonitorEnabled']    = $status.BehaviorMonitorEnabled
            $snap['IoavProtectionEnabled']     = $status.IoavProtectionEnabled
            $snap['NISEnabled']                = $status.NISEnabled
            $snap['OnAccessProtectionEnabled'] = $status.OnAccessProtectionEnabled
            $snap['AntivirusSignatureAge']     = $status.AntivirusSignatureAge
            $snap['AntispywareSignatureAge']   = $status.AntispywareSignatureAge
            $snap['FullScanAge']               = $status.FullScanAge
            $snap['AMEngineVersion']           = $status.AMEngineVersion
            $snap['AMProductVersion']          = $status.AMProductVersion
            $snap['AMServiceEnabled']          = $status.AMServiceEnabled
            $snap['AMServiceVersion']          = $status.AMServiceVersion
            $snap['QuickScanAge']              = $status.QuickScanAge
            # try/catch here is at top-level statement position, which is
            # valid in PS 5.1 (the hashtable-literal restriction doesn't apply).
            $snap['TamperProtectionSource']    = try { $status.TamperProtectionSource } catch { 'N/A' }
        }
    } catch { }
    try {
        $prefs = Get-MpPreference -ErrorAction SilentlyContinue
        if ($prefs) {
            $snap['DisableRealtimeMonitoring'] = $prefs.DisableRealtimeMonitoring
            $snap['DisableBehaviorMonitoring'] = $prefs.DisableBehaviorMonitoring
            $snap['EnableNetworkProtection']   = $prefs.EnableNetworkProtection
            $snap['EnableControlledFolderAccess'] = $prefs.EnableControlledFolderAccess
            $snap['PUAProtection']             = $prefs.PUAProtection
            $snap['ASRRules']                  = try { @($prefs.AttackSurfaceReductionRules_Ids) } catch { @() }
            $snap['ExclusionPaths']            = try { @($prefs.ExclusionPath) } catch { @() }
        }
    } catch { }
    return $snap
}

# ==============================================================
# v1.1.0 NEW CATEGORIES -- APT HUNTING SURFACE
# These categories target persistence vectors and tamper surfaces
# that no existing field tool (Hiren's/MediCat/NHV) covers.
# ==============================================================

# --- 13. WMI PERSISTENCE (MITRE T1546.003) ---
# Classic APT technique: __EventFilter + __EventConsumer +
# __FilterToConsumerBinding in root\subscription. Used by Stuxnet,
# APT29, Turla, and most fileless malware families.
function Get-WmiPersistenceSnapshot {
    $snap = [PSCustomObject]@{
        Filters   = @()
        Consumers = @()
        Bindings  = @()
    }
    try {
        $filters = @(Get-WmiObject -Namespace 'root\subscription' -Class '__EventFilter' -ErrorAction SilentlyContinue)
        $snap.Filters = @($filters | ForEach-Object {
            [PSCustomObject]@{
                Name      = $_.Name
                Query     = $_.Query
                QueryLang = $_.QueryLanguage
                EventNS   = $_.EventNamespace
            }
        })
    } catch { }
    try {
        $consumers = @(Get-WmiObject -Namespace 'root\subscription' -Class '__EventConsumer' -ErrorAction SilentlyContinue)
        $snap.Consumers = @($consumers | ForEach-Object {
            $cmdLine = ''
            try { if ($_.CommandLineTemplate) { $cmdLine = $_.CommandLineTemplate } } catch { }
            $scriptText = ''
            try { if ($_.ScriptText) { $scriptText = $_.ScriptText } } catch { }
            [PSCustomObject]@{
                Name        = $_.Name
                Class       = $_.__CLASS
                CommandLine = $cmdLine
                ScriptText  = $scriptText
            }
        })
    } catch { }
    try {
        $bindings = @(Get-WmiObject -Namespace 'root\subscription' -Class '__FilterToConsumerBinding' -ErrorAction SilentlyContinue)
        $snap.Bindings = @($bindings | ForEach-Object {
            [PSCustomObject]@{
                Filter   = "$($_.Filter)"
                Consumer = "$($_.Consumer)"
            }
        })
    } catch { }
    return $snap
}

# --- 14. HOSTS FILE (MITRE T1565.001 Stored Data Manipulation / T1205) ---
# Captures non-comment, non-empty lines plus a SHA256 of the whole file.
# Hash-based diff catches any tamper; line capture lets us show what changed.
function Get-HostsFileSnapshot {
    $snap = [PSCustomObject]@{
        Path       = ''
        Exists     = $false
        Size       = 0
        LastWrite  = ''
        SHA256     = ''
        ActiveLines= @()
        LineCount  = 0
    }
    $hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    $snap.Path = $hostsPath
    try {
        if (Test-Path $hostsPath) {
            $snap.Exists = $true
            $fi = Get-Item $hostsPath -ErrorAction SilentlyContinue
            if ($fi) {
                $snap.Size      = $fi.Length
                $snap.LastWrite = $fi.LastWriteTime.ToString('o')
            }
            $raw = Get-Content $hostsPath -Raw -ErrorAction SilentlyContinue
            if ($raw) {
                $bytes  = [System.Text.Encoding]::UTF8.GetBytes($raw)
                $sha    = [System.Security.Cryptography.SHA256]::Create()
                $hash   = $sha.ComputeHash($bytes)
                $sha.Dispose()
                $snap.SHA256 = ([BitConverter]::ToString($hash) -replace '-','').ToLower()
            }
            $lines = @(Get-Content $hostsPath -ErrorAction SilentlyContinue |
                       Where-Object { $_ -and $_.Trim() -ne '' -and $_.Trim() -notmatch '^#' })
            $snap.ActiveLines = $lines
            $snap.LineCount   = $lines.Count
        }
    } catch { }
    return $snap
}

# --- 15. ENVIRONMENT VARIABLES (MITRE T1574.007 Path Interception) ---
# Machine-scope env vars only. PATH poisoning is a top-10 persistence
# mechanism and no field tool currently audits it.
function Get-EnvironmentSnapshot {
    $snap = [ordered]@{}
    try {
        $mv = [System.Environment]::GetEnvironmentVariables('Machine')
        foreach ($k in @($mv.Keys)) {
            $snap[$k] = "$($mv[$k])"
        }
    } catch { }
    # Break PATH into its components so we can diff per-entry rather than
    # re-flagging the whole thing on every trivial change
    try {
        if ($snap.Contains('Path')) {
            $parts = @($snap['Path'] -split ';' | Where-Object { $_ -and $_.Trim() -ne '' })
            for ($i = 0; $i -lt $parts.Count; $i++) {
                $snap["__Path[$i]"] = $parts[$i]
            }
        }
    } catch { }
    return $snap
}

# --- 16. KERNEL DRIVERS (MITRE T1014 Rootkit / T1543.003) ---
# Running kernel drivers. Filter to currently-running only to keep the
# diff volume manageable; unsigned or non-Microsoft drivers are the
# most interesting targets for tamper detection.
function Get-DriversSnapshot {
    $items = [System.Collections.Generic.List[PSCustomObject]]::new()
    try {
        $drivers = @(Get-CimInstance -ClassName Win32_SystemDriver -ErrorAction SilentlyContinue |
                     Where-Object { $_.State -eq 'Running' })
        foreach ($d in $drivers) {
            $isMs = $false
            $publisher = ''
            try {
                if ($d.PathName) {
                    $driverPath = $d.PathName -replace '^\\\?\?\\',''  -replace '^System32\\','' `
                                              -replace '^\\SystemRoot\\',"$env:SystemRoot\"
                    if ($driverPath -notmatch '^[A-Z]:\\' -and $driverPath -notmatch '^\\\\') {
                        $driverPath = Join-Path $env:SystemRoot "System32\$driverPath"
                    }
                    if (Test-Path $driverPath -ErrorAction SilentlyContinue) {
                        $sig = Get-AuthenticodeSignature -FilePath $driverPath -ErrorAction SilentlyContinue
                        if ($sig -and $sig.SignerCertificate) {
                            $publisher = $sig.SignerCertificate.Subject
                            if ($publisher -match 'Microsoft') { $isMs = $true }
                        }
                    }
                }
            } catch { }
            $null = $items.Add([PSCustomObject]@{
                Name        = $d.Name
                DisplayName = $d.DisplayName
                State       = $d.State
                StartMode   = $d.StartMode
                PathName    = $d.PathName
                IsMicrosoft = $isMs
                Publisher   = $publisher
            })
        }
    } catch { }
    return @($items)
}

# ==============================================================
# MASTER SNAPSHOT CAPTURE
# ==============================================================
function New-Snapshot {
    param([string]$Type)

    Write-Section "CAPTURING $Type SNAPSHOT"
    $cap = [ordered]@{}

    Write-Step "Services..."
    $cap['Services'] = @(Get-ServicesSnapshot)
    Write-Category 'Services' $cap['Services'].Count

    Write-Step "Registry (security keys)..."
    $cap['Registry'] = Get-RegistrySnapshot
    $rc = @($cap['Registry'].Keys).Count
    Write-Category 'Registry keys' $rc

    Write-Step "Scheduled Tasks..."
    $cap['ScheduledTasks'] = @(Get-ScheduledTasksSnapshot)
    Write-Category 'Scheduled Tasks' $cap['ScheduledTasks'].Count

    Write-Step "Firewall Rules..."
    $fw = Get-FirewallSnapshot
    $cap['Firewall'] = $fw
    Write-Category 'Firewall rules (enabled)' $fw.Rules.Count

    Write-Step "Local Users and Groups..."
    $cap['LocalUsers'] = Get-LocalUsersSnapshot
    Write-Category 'Users' $cap['LocalUsers'].Users.Count

    Write-Step "Installed Software..."
    $cap['Software'] = @(Get-SoftwareSnapshot)
    Write-Category 'Software packages' $cap['Software'].Count

    Write-Step "Listening Ports..."
    $cap['Ports'] = @(Get-ListeningPortsSnapshot)
    Write-Category 'Listening ports' $cap['Ports'].Count

    Write-Step "Certificates..."
    $cap['Certificates'] = @(Get-CertificatesSnapshot)
    Write-Category 'Certificates' $cap['Certificates'].Count

    Write-Step "Startup Items..."
    $cap['StartupItems'] = @(Get-StartupItemsSnapshot)
    Write-Category 'Startup items' $cap['StartupItems'].Count

    Write-Step "SMB Shares..."
    $cap['SmbShares'] = @(Get-SmbSharesSnapshot)
    Write-Category 'SMB shares' $cap['SmbShares'].Count

    Write-Step "BitLocker..."
    $cap['BitLocker'] = Get-BitLockerSnapshot
    Write-Category 'BitLocker volumes' @($cap['BitLocker'].Keys).Count

    Write-Step "Defender..."
    $cap['Defender'] = Get-DefenderSnapshot
    Write-Category 'Defender properties' @($cap['Defender'].Keys).Count

    # ---- v1.1.0 new APT-hunting categories ----
    Write-Step "WMI Persistence (T1546.003)..."
    $cap['WmiPersistence'] = Get-WmiPersistenceSnapshot
    $wmiCount = @($cap['WmiPersistence'].Filters).Count + @($cap['WmiPersistence'].Consumers).Count + @($cap['WmiPersistence'].Bindings).Count
    Write-Category 'WMI persistence artifacts' $wmiCount

    Write-Step "Hosts File (T1565.001)..."
    $cap['HostsFile'] = Get-HostsFileSnapshot
    Write-Category 'Hosts file active lines' $cap['HostsFile'].LineCount

    Write-Step "Environment Variables (T1574.007)..."
    $cap['Environment'] = Get-EnvironmentSnapshot
    Write-Category 'Machine env vars' @($cap['Environment'].Keys).Count

    Write-Step "Kernel Drivers (T1014)..."
    $cap['Drivers'] = @(Get-DriversSnapshot)
    Write-Category 'Running kernel drivers' $cap['Drivers'].Count

    $snapshot = [PSCustomObject]@{
        SnapshotId  = $SnapshotId
        Type        = $Type
        Hostname    = $HOSTNAME
        Technician  = $techName
        Timestamp   = $NOW.ToString('o')
        IncidentId  = $IncidentId
        Data        = $cap
    }

    Write-Host ''
    Write-Step "$Type snapshot complete." 'Green'
    return $snapshot
}

# ==============================================================
# DIFF ENGINE
# ==============================================================

function Compare-Arrays {
    param($Before, $After, [string]$KeyProp, [string]$Category)
    $results = [System.Collections.Generic.List[PSCustomObject]]::new()

    $bHash = @{}; $aHash = @{}
    foreach ($i in @($Before)) { if ($i.$KeyProp) { $bHash[$i.$KeyProp] = $i } }
    foreach ($i in @($After))  { if ($i.$KeyProp) { $aHash[$i.$KeyProp] = $i } }

    # Added
    foreach ($k in @($aHash.Keys)) {
        if (-not $bHash.ContainsKey($k)) {
            $null = $results.Add([PSCustomObject]@{
                Category = $Category; ChangeType = 'ADDED'
                Item = $k; Before = 'Not present'; After = ($aHash[$k] | ConvertTo-Json -Compress -Depth 2)
                LocalClass = 'Neutral'; Severity = 'Medium'
            })
        }
    }
    # Removed
    foreach ($k in @($bHash.Keys)) {
        if (-not $aHash.ContainsKey($k)) {
            $null = $results.Add([PSCustomObject]@{
                Category = $Category; ChangeType = 'REMOVED'
                Item = $k; Before = ($bHash[$k] | ConvertTo-Json -Compress -Depth 2); After = 'Not present'
                LocalClass = 'Neutral'; Severity = 'Medium'
            })
        }
    }
    # Modified
    foreach ($k in @($bHash.Keys)) {
        if ($aHash.ContainsKey($k)) {
            $bj = $bHash[$k] | ConvertTo-Json -Compress -Depth 2
            $aj = $aHash[$k] | ConvertTo-Json -Compress -Depth 2
            if ($bj -ne $aj) {
                $null = $results.Add([PSCustomObject]@{
                    Category = $Category; ChangeType = 'MODIFIED'
                    Item = $k; Before = $bj; After = $aj
                    LocalClass = 'Neutral'; Severity = 'Low'
                })
            }
        }
    }
    return @($results)
}

# v1.1.3 FIX: Complete rewrite with universal type handling.
# The root issue: Before snapshots loaded from JSON come back as PSCustomObject
# (no .ContainsKey, no .Keys, no [] indexer). After snapshots from fresh capture
# are OrderedDictionary (has .Contains() but NOT .ContainsKey()). Hashtables
# have .ContainsKey(). The old code assumed .ContainsKey() existed on all three
# and threw 80+ errors per diff run.
#
# Fix: three universal helper functions that work on PSCustomObject,
# OrderedDictionary, and Hashtable without type-checking at every call site.

function Get-DictKeys {
    param($Obj)
    if ($null -eq $Obj) { return @() }
    if ($Obj -is [System.Collections.IDictionary]) { return @($Obj.Keys) }
    if ($Obj.PSObject -and $Obj.PSObject.Properties) { return @($Obj.PSObject.Properties.Name) }
    return @()
}

function Test-DictKey {
    param($Obj, [string]$Key)
    if ($null -eq $Obj) { return $false }
    if ($Obj -is [System.Collections.IDictionary]) { return $Obj.Contains($Key) }
    if ($Obj.PSObject -and $Obj.PSObject.Properties) { return [bool]($Obj.PSObject.Properties[$Key]) }
    return $false
}

function Get-DictValue {
    param($Obj, [string]$Key)
    if ($null -eq $Obj) { return $null }
    if ($Obj -is [System.Collections.IDictionary]) { return $Obj[$Key] }
    if ($Obj.PSObject -and $Obj.PSObject.Properties[$Key]) { return $Obj.$Key }
    return $null
}

function Compare-OrderedDicts {
    param($Before, $After, [string]$Category)
    $results = [System.Collections.Generic.List[PSCustomObject]]::new()

    $bKeys   = Get-DictKeys $Before
    $aKeys   = Get-DictKeys $After
    $allKeys = @(($bKeys + $aKeys) | Select-Object -Unique)

    foreach ($section in $allKeys) {
        $bSec = if (Test-DictKey $Before $section) { Get-DictValue $Before $section } else { $null }
        $aSec = if (Test-DictKey $After  $section) { Get-DictValue $After  $section } else { $null }

        $bSubKeys = Get-DictKeys $bSec
        $aSubKeys = Get-DictKeys $aSec
        $allSubKeys = @(($bSubKeys + $aSubKeys) | Select-Object -Unique)

        foreach ($prop in $allSubKeys) {
            $bVal = if (Test-DictKey $bSec $prop) { Get-DictValue $bSec $prop } else { $null }
            $aVal = if (Test-DictKey $aSec $prop) { Get-DictValue $aSec $prop } else { $null }

            $bStr = if ($null -ne $bVal) { "$bVal" } else { '(absent)' }
            $aStr = if ($null -ne $aVal) { "$aVal" } else { '(absent)' }

            if ($bStr -ne $aStr) {
                $null = $results.Add([PSCustomObject]@{
                    Category   = $Category
                    ChangeType = 'MODIFIED'
                    Item       = "$section \ $prop"
                    Before     = $bStr
                    After      = $aStr
                    LocalClass = 'Neutral'
                    Severity   = 'Medium'
                })
            }
        }
    }
    return @($results)
}

# ==============================================================
# LOCAL CLASSIFICATION RULES (40+ rules)
# Applied before AI, used as fallback when AI unavailable
# ==============================================================
function Invoke-LocalClassification {
    param([System.Collections.Generic.List[PSCustomObject]]$Changes)

    foreach ($c in $Changes) {
        $item  = $c.Item
        $before= $c.Before
        $after = $c.After
        $ctype = $c.ChangeType
        $cat   = $c.Category

        $class = 'Neutral'; $sev = 'Info'; $desc = ''

        # SECURITY REGISTRY IMPROVEMENTS
        if ($item -match 'RunAsPPL' -and $after -match '1') { $class='Improvement'; $sev='High'; $desc='LSA RunAsPPL enabled - protects credential data from memory scraping' }
        elseif ($item -match 'RunAsPPL' -and $after -match '0') { $class='Regression'; $sev='Critical'; $desc='LSA RunAsPPL disabled - credentials now exposed to memory scraping attacks' }
        elseif ($item -match 'UseLogonCredential' -and $after -match '0') { $class='Improvement'; $sev='High'; $desc='WDigest credential caching disabled - prevents plaintext password extraction' }
        elseif ($item -match 'UseLogonCredential' -and $after -match '1') { $class='Regression'; $sev='Critical'; $desc='WDigest enabled - plaintext passwords will be cached in LSASS memory' }
        elseif ($item -match 'SMB1' -and $after -match '0') { $class='Improvement'; $sev='High'; $desc='SMBv1 disabled - eliminates EternalBlue/WannaCry attack surface' }
        elseif ($item -match 'SMB1' -and $after -match '1') { $class='Regression'; $sev='Critical'; $desc='SMBv1 enabled - machine is vulnerable to EternalBlue and WannaCry class exploits' }
        elseif ($item -match 'EnableScriptBlockLogging' -and $after -match '1') { $class='Improvement'; $sev='Medium'; $desc='PowerShell Script Block Logging enabled - all PS commands now audited' }
        elseif ($item -match 'AutoAdminLogon' -and $after -match '0') { $class='Improvement'; $sev='High'; $desc='Auto-logon disabled - physical access no longer bypasses authentication' }
        elseif ($item -match 'AutoAdminLogon' -and $after -match '1') { $class='Regression'; $sev='Critical'; $desc='Auto-logon enabled - machine logs in automatically, bypassing authentication' }
        elseif ($item -match 'EnableVirtualizationBasedSecurity' -and $after -match '1') { $class='Improvement'; $sev='Medium'; $desc='VBS/HVCI enabled - kernel-level credential and code integrity protection active' }
        elseif ($item -match 'HypervisorEnforcedCodeIntegrity' -and $after -match '1') { $class='Improvement'; $sev='Medium'; $desc='HVCI memory integrity enabled - prevents unsigned kernel code injection' }
        elseif ($item -match 'EnableLUA' -and $after -match '0') { $class='Regression'; $sev='Critical'; $desc='UAC disabled - all processes run with full admin rights without prompting' }
        elseif ($item -match 'EnableLUA' -and $after -match '1') { $class='Improvement'; $sev='High'; $desc='UAC enabled - privilege elevation now requires explicit user approval' }
        elseif ($item -match 'fDenyTSConnections' -and $after -match '1') { $class='Improvement'; $sev='Medium'; $desc='RDP disabled - reduces attack surface against brute-force and exploit attacks' }
        elseif ($item -match 'fDenyTSConnections' -and $after -match '0') { $class='Regression'; $sev='High'; $desc='RDP enabled - exposes machine to brute-force and RDP exploit attacks' }

        # DEFENDER CHANGES
        elseif ($cat -eq 'Defender' -and $item -match 'RealTimeProtection' -and $after -match 'True') { $class='Improvement'; $sev='High'; $desc='Defender real-time protection re-enabled' }
        elseif ($cat -eq 'Defender' -and $item -match 'RealTimeProtection' -and $after -match 'False') { $class='Regression'; $sev='Critical'; $desc='Defender real-time protection disabled - machine has no active malware defense' }
        elseif ($cat -eq 'Defender' -and $item -match 'SignatureAge' -and $before -gt $after) { $class='Improvement'; $sev='Low'; $desc='Defender signatures updated - latest threat intelligence applied' }
        elseif ($cat -eq 'Defender' -and $item -match 'EnableNetworkProtection' -and $after -match '1') { $class='Improvement'; $sev='Medium'; $desc='Network Protection enabled - blocks access to malicious URLs and IPs' }
        elseif ($cat -eq 'Defender' -and $item -match 'EnableControlledFolderAccess' -and $after -match '1') { $class='Improvement'; $sev='Medium'; $desc='Controlled Folder Access enabled - ransomware protection for user files active' }
        elseif ($cat -eq 'Defender' -and $item -match 'TamperProtection' -and $after -match 'Antimalware') { $class='Improvement'; $sev='High'; $desc='Defender Tamper Protection active - settings cannot be changed by malware' }

        # BITLOCKER CHANGES
        elseif ($cat -eq 'BitLocker' -and $after -match 'FullyEncrypted') { $class='Improvement'; $sev='High'; $desc='BitLocker encryption complete - data at rest is now protected' }
        elseif ($cat -eq 'BitLocker' -and $after -match 'EncryptionInProgress') { $class='Improvement'; $sev='Low'; $desc='BitLocker encryption started' }
        elseif ($cat -eq 'BitLocker' -and $before -match 'FullyEncrypted' -and $after -match 'Off') { $class='Regression'; $sev='Critical'; $desc='BitLocker disabled on a previously encrypted volume - data at rest is no longer protected' }

        # SERVICES
        elseif ($cat -eq 'Services' -and $ctype -eq 'ADDED') { $class='Suspicious'; $sev='Medium'; $desc="New service installed: $item - verify this is authorized software" }
        elseif ($cat -eq 'Services' -and $ctype -eq 'REMOVED') { $class='Neutral'; $sev='Low'; $desc="Service removed: $item" }
        elseif ($cat -eq 'Services' -and $item -match 'RemoteRegistry' -and $after -match 'Stopped') { $class='Improvement'; $sev='Medium'; $desc='Remote Registry service stopped - registry no longer remotely accessible' }
        elseif ($cat -eq 'Services' -and $item -match 'RemoteRegistry' -and $after -match 'Running') { $class='Regression'; $sev='High'; $desc='Remote Registry service started - registry is remotely accessible' }
        elseif ($cat -eq 'Services' -and $item -match 'WinDefend' -and $after -match 'Stopped') { $class='Regression'; $sev='Critical'; $desc='Windows Defender service stopped - no antivirus protection' }

        # SCHEDULED TASKS
        elseif ($cat -eq 'ScheduledTasks' -and $ctype -eq 'ADDED') {
            if ($after -match 'base64|frombase64|-enc|-encoded|-e [A-Za-z0-9+/]{20}') {
                $class='Suspicious'; $sev='Critical'; $desc="New scheduled task with Base64-encoded PowerShell detected - potential malware persistence mechanism"
            } elseif ($after -match 'http://|https://|ftp://|\\\\[^\\]') {
                $class='Suspicious'; $sev='High'; $desc="New scheduled task downloads from network location - review task action carefully"
            } elseif ($after -match 'temp|tmp|appdata\\roaming|public\\|downloads\\') {
                $class='Suspicious'; $sev='High'; $desc="New scheduled task executes from suspicious path (Temp/AppData/Public)"
            } else {
                $class='Neutral'; $sev='Medium'; $desc="New scheduled task: $item - verify this is authorized"
            }
        }
        elseif ($cat -eq 'ScheduledTasks' -and $ctype -eq 'REMOVED') { $class='Neutral'; $sev='Low'; $desc="Scheduled task removed: $item" }

        # STARTUP ITEMS
        elseif ($cat -eq 'StartupItems' -and $ctype -eq 'ADDED') {
            if ($after -match 'base64|frombase64|-enc') { $class='Suspicious'; $sev='Critical'; $desc='New startup item with Base64-encoded payload - potential malware persistence' }
            elseif ($after -match 'temp|tmp|appdata\\roaming|public\\') { $class='Suspicious'; $sev='High'; $desc='New startup item in suspicious path' }
            else { $class='Neutral'; $sev='Medium'; $desc="New startup item: $item" }
        }

        # PORTS
        elseif ($cat -eq 'Ports' -and $ctype -eq 'ADDED') {
            $port = try { [int]($item -replace '.*:','') } catch { 0 }
            if ($port -in @(4444,5555,1234,31337,8888,9999,6666)) { $class='Suspicious'; $sev='Critical'; $desc="New listener on port $port - common backdoor/reverse shell port" }
            elseif ($port -in @(3389,5900,22,23,21)) { $class='Regression'; $sev='High'; $desc="New listener on port $port - remote access service may be newly exposed" }
            else { $class='Neutral'; $sev='Medium'; $desc="New TCP/UDP listener on port $port" }
        }
        elseif ($cat -eq 'Ports' -and $ctype -eq 'REMOVED') { $class='Improvement'; $sev='Low'; $desc="Port closed: $item - reduced attack surface" }

        # SOFTWARE
        elseif ($cat -eq 'Software' -and $ctype -eq 'ADDED') { $class='Neutral'; $sev='Low'; $desc="Software installed: $item" }
        elseif ($cat -eq 'Software' -and $ctype -eq 'REMOVED') { $class='Neutral'; $sev='Low'; $desc="Software removed: $item" }

        # USERS
        elseif ($cat -eq 'Users' -and $ctype -eq 'ADDED') { $class='Suspicious'; $sev='High'; $desc="New local user account created: $item - verify this is authorized" }
        elseif ($cat -eq 'Users' -and $ctype -eq 'REMOVED') { $class='Neutral'; $sev='Medium'; $desc="Local user account removed: $item" }
        elseif ($cat -eq 'Users' -and $item -match 'Guest' -and $after -match 'Enabled.*True') { $class='Regression'; $sev='High'; $desc='Guest account enabled - unauthenticated access possible' }
        elseif ($cat -eq 'Users' -and $item -match 'Guest' -and $after -match 'Enabled.*False') { $class='Improvement'; $sev='Medium'; $desc='Guest account disabled' }

        # SMB SHARES
        elseif ($cat -eq 'SmbShares' -and $ctype -eq 'ADDED' -and $item -notmatch '\$$') { $class='Suspicious'; $sev='High'; $desc="Non-admin SMB share created: $item - verify this is intentional and properly secured" }
        elseif ($cat -eq 'SmbShares' -and $ctype -eq 'REMOVED' -and $item -notmatch '\$$') { $class='Improvement'; $sev='Medium'; $desc="Non-admin SMB share removed: $item" }

        # FIREWALL
        elseif ($cat -eq 'Firewall' -and $item -match 'DomainEnabled|PrivateEnabled|PublicEnabled' -and $after -match 'True') { $class='Improvement'; $sev='High'; $desc="Firewall profile re-enabled" }
        elseif ($cat -eq 'Firewall' -and $item -match 'DomainEnabled|PrivateEnabled|PublicEnabled' -and $after -match 'False') { $class='Regression'; $sev='Critical'; $desc="Firewall profile disabled - machine is unprotected on this network type" }

        # CERTIFICATES
        elseif ($cat -eq 'Certificates' -and $ctype -eq 'ADDED' -and $item -match 'Root') { $class='Suspicious'; $sev='High'; $desc="New root certificate installed in LocalMachine store - could enable SSL interception/MitM" }
        elseif ($cat -eq 'Certificates' -and $ctype -eq 'ADDED' -and $item -match 'Disallowed') { $class='Improvement'; $sev='Low'; $desc="Certificate added to disallow list - revoked or untrusted cert blocked" }

        # ===== v1.1.0 NEW CATEGORIES =====
        # WMI PERSISTENCE -- any addition is high-confidence APT indicator
        elseif ($cat -eq 'WmiPersistence' -and $ctype -eq 'ADDED') {
            $class='Suspicious'; $sev='Critical'
            $desc="WMI persistence artifact created: $item - classic APT/fileless malware persistence mechanism (Stuxnet, APT29, Turla). Immediate investigation required."
        }
        elseif ($cat -eq 'WmiPersistence' -and $ctype -eq 'REMOVED') { $class='Improvement'; $sev='Medium'; $desc="WMI persistence artifact removed: $item" }
        elseif ($cat -eq 'WmiPersistence' -and $ctype -eq 'MODIFIED') { $class='Suspicious'; $sev='High'; $desc="WMI persistence artifact modified: $item - verify change was authorized" }

        # HOSTS FILE -- any change after technician visit is noteworthy
        elseif ($cat -eq 'HostsFile' -and $ctype -eq 'ADDED') {
            if ($after -match '0\.0\.0\.0|127\.0\.0\.1|::1') {
                $class='Suspicious'; $sev='Medium'; $desc="Hosts file sinkhole entry added - could block telemetry, AV updates, or legitimate services"
            } else {
                $class='Suspicious'; $sev='High'; $desc="Hosts file redirect added - potential DNS hijack or C2 redirection"
            }
        }
        elseif ($cat -eq 'HostsFile' -and $ctype -eq 'REMOVED') { $class='Neutral'; $sev='Low'; $desc="Hosts file entry removed" }
        elseif ($cat -eq 'HostsFile' -and $item -match 'SHA256') { $class='Suspicious'; $sev='Medium'; $desc='Hosts file hash changed - see line-level entries below for specifics' }

        # ENVIRONMENT VARIABLES -- PATH poisoning is a top persistence vector
        elseif ($cat -eq 'Environment' -and $item -match '__Path\[') {
            if ($ctype -eq 'ADDED') {
                if ($after -match 'temp|tmp|appdata\\roaming|public\\|downloads\\|\\users\\[^\\]+\\') {
                    $class='Suspicious'; $sev='Critical'; $desc="PATH entry added in user-writable location: $after - classic PATH hijack setup"
                } else {
                    $class='Neutral'; $sev='Medium'; $desc="New PATH entry: $after"
                }
            } elseif ($ctype -eq 'REMOVED') {
                $class='Neutral'; $sev='Low'; $desc="PATH entry removed: $before"
            }
        }
        elseif ($cat -eq 'Environment' -and $item -match 'PSModulePath' -and $after -match 'temp|appdata|users\\') {
            $class='Suspicious'; $sev='High'; $desc='PSModulePath modified to include user-writable location - PowerShell module hijack risk'
        }
        elseif ($cat -eq 'Environment' -and $ctype -eq 'ADDED') { $class='Neutral'; $sev='Low'; $desc="New machine env var: $item" }

        # KERNEL DRIVERS -- unsigned or non-MS running drivers are high risk
        elseif ($cat -eq 'Drivers' -and $ctype -eq 'ADDED') {
            if ($after -match '"IsMicrosoft":\s*false' -or $after -match '"Publisher":\s*""') {
                $class='Suspicious'; $sev='Critical'; $desc="New non-Microsoft or unsigned kernel driver running: $item - possible rootkit or unauthorized hardware agent"
            } else {
                $class='Neutral'; $sev='Medium'; $desc="New kernel driver running: $item"
            }
        }
        elseif ($cat -eq 'Drivers' -and $ctype -eq 'REMOVED') { $class='Neutral'; $sev='Low'; $desc="Kernel driver stopped: $item" }

        # ===== FINALIZATION =====
        $c.LocalClass = $class
        $c.Severity   = $sev
        if ($desc -ne '') {
            if ($c.PSObject.Properties['LocalExplanation']) {
                $c.LocalExplanation = $desc
            } else {
                $c | Add-Member -NotePropertyName LocalExplanation -NotePropertyValue $desc -Force
            }
        }

        # MITRE ATT&CK technique mapping (v1.1.0)
        $mitre = ''
        # Credential access
        if ($item -match 'RunAsPPL|WDigest|UseLogonCredential|LmCompatibilityLevel|NoLMHash') { $mitre = 'T1003 (OS Credential Dumping)' }
        # Persistence - Registry Run / Startup folder
        elseif ($cat -eq 'StartupItems' -or ($cat -eq 'Registry' -and $item -match 'StartupRun|Winlogon')) { $mitre = 'T1547.001 (Registry Run Keys / Startup Folder)' }
        # Persistence - Scheduled Task
        elseif ($cat -eq 'ScheduledTasks') { $mitre = 'T1053.005 (Scheduled Task/Job)' }
        # Persistence - WMI
        elseif ($cat -eq 'WmiPersistence') { $mitre = 'T1546.003 (Event Triggered Execution: WMI Event Subscription)' }
        # Persistence - Service
        elseif ($cat -eq 'Services' -and $ctype -eq 'ADDED') { $mitre = 'T1543.003 (Create or Modify System Process: Windows Service)' }
        # Persistence - Account
        elseif ($cat -eq 'Users' -and $ctype -eq 'ADDED') { $mitre = 'T1136.001 (Create Account: Local Account)' }
        # Persistence - Kernel driver / rootkit
        elseif ($cat -eq 'Drivers' -and $ctype -eq 'ADDED') { $mitre = 'T1014 (Rootkit) / T1543.003' }
        # Defense evasion - disable defender/firewall/UAC
        elseif ($item -match 'EnableLUA|RealTimeProtection|DisableRealtimeMonitoring|WinDefend|DomainEnabled|PrivateEnabled|PublicEnabled' -and $class -eq 'Regression') { $mitre = 'T1562.001 (Impair Defenses: Disable or Modify Tools)' }
        # Defense evasion - cert manipulation
        elseif ($cat -eq 'Certificates' -and $item -match 'Root') { $mitre = 'T1553.004 (Subvert Trust Controls: Install Root Certificate)' }
        # Defense evasion - PowerShell logging
        elseif ($item -match 'EnableScriptBlockLogging|EnableTranscripting|EnableModuleLogging' -and $class -eq 'Regression') { $mitre = 'T1562.002 (Impair Defenses: Disable Windows Event Logging)' }
        # Lateral movement / remote access
        elseif ($item -match 'fDenyTSConnections|RemoteRegistry' -and $class -eq 'Regression') { $mitre = 'T1021 (Remote Services)' }
        elseif ($cat -eq 'SmbShares' -and $ctype -eq 'ADDED') { $mitre = 'T1021.002 (Remote Services: SMB/Windows Admin Shares)' }
        # Command and control
        elseif ($cat -eq 'HostsFile') { $mitre = 'T1565.001 (Stored Data Manipulation) / T1071 (Application Layer Protocol)' }
        # Execution hijack
        elseif ($cat -eq 'Environment' -and $item -match 'Path') { $mitre = 'T1574.007 (Hijack Execution Flow: Path Interception by PATH Environment Variable)' }
        # Initial access / persistence via SMB protocol downgrade
        elseif ($item -match 'SMB1' -and $class -eq 'Regression') { $mitre = 'T1210 (Exploitation of Remote Services)' }

        if ($mitre -ne '') {
            if ($c.PSObject.Properties['Mitre']) {
                $c.Mitre = $mitre
            } else {
                $c | Add-Member -NotePropertyName Mitre -NotePropertyValue $mitre -Force
            }
        }

        # Risk score: weighted by classification and severity
        $classWeight = switch ($class) { 'Regression' { 3 } 'Suspicious' { 4 } 'Improvement' { -2 } default { 0 } }
        $sevWeight   = switch ($sev)   { 'Critical' { 10 } 'High' { 6 } 'Medium' { 3 } 'Low' { 1 } default { 0 } }
        $risk        = $classWeight * $sevWeight
        if ($c.PSObject.Properties['RiskScore']) {
            $c.RiskScore = $risk
        } else {
            $c | Add-Member -NotePropertyName RiskScore -NotePropertyValue $risk -Force
        }
    }
}

# ==============================================================
# AI ANALYSIS ENGINE
# ==============================================================
function Invoke-AIAnalysis {
    param([System.Collections.Generic.List[PSCustomObject]]$Changes, $BeforeSnap, $AfterSnap)

    if ($NoAI -or $apiKey -eq '') {
        Write-Step "AI analysis skipped (no API key or -NoAI specified)." 'DarkGray'
        return $null
    }

    $changeArr = @($Changes)
    Write-Step "Preparing diff payload for AI analysis ($($changeArr.Count) changes)..." 'Cyan'

    # v1.2.1: Aggressively trim the payload to stay within API token limits.
    # The old version sent 60 items with full Before/After JSON (200+ chars each),
    # producing prompts of 15-25K tokens that hit the 400 "payload too large" error.
    # New approach: top 30 by severity, Before/After truncated to 60 chars, total
    # diff section capped at 6000 chars.
    $condensed = @($changeArr | Sort-Object {
        switch ($_.Severity) { 'Critical' {0} 'High' {1} 'Medium' {2} 'Low' {3} default {4} }
    } | Select-Object -First 30)

    $diffLines = [System.Collections.Generic.List[string]]::new()
    $diffChars = 0
    foreach ($c in $condensed) {
        $bShort = if ($c.Before.Length -gt 60) { $c.Before.Substring(0,57) + '...' } else { $c.Before }
        $aShort = if ($c.After.Length  -gt 60) { $c.After.Substring(0,57)  + '...' } else { $c.After }
        $line   = "[$($c.Category)] $($c.ChangeType) | $($c.Item) | B: $($bShort -replace '"','') | A: $($aShort -replace '"','')"
        if (($diffChars + $line.Length) -gt 6000) { break }
        $null = $diffLines.Add($line)
        $diffChars += $line.Length + 1
    }

    $bDate = if ($BeforeSnap.Timestamp) { $BeforeSnap.Timestamp } else { 'unknown' }
    $aDate = if ($AfterSnap.Timestamp)  { $AfterSnap.Timestamp }  else { 'unknown' }

    $prompt = @"
You are a senior enterprise IT security analyst reviewing a compliance diff from a field technician visit.
Analyze the following changes detected on machine $HOSTNAME between two snapshots.

VISIT CONTEXT:
- Machine: $HOSTNAME
- Technician: $techName
- Before snapshot: $bDate
- After snapshot: $aDate
- Ticket: $(if ($IncidentId) { $IncidentId } else { 'None' })
- Total changes detected: $($changeArr.Count) (showing top $($diffLines.Count))

CHANGES (top $($diffLines.Count) by severity):
$($diffLines -join "`n")

LOCAL CLASSIFICATION SUMMARY:
- Improvements: $(@($changeArr | Where-Object { $_.LocalClass -eq 'Improvement' }).Count)
- Regressions: $(@($changeArr | Where-Object { $_.LocalClass -eq 'Regression' }).Count)
- Suspicious: $(@($changeArr | Where-Object { $_.LocalClass -eq 'Suspicious' }).Count)
- Neutral: $(@($changeArr | Where-Object { $_.LocalClass -eq 'Neutral' }).Count)

Respond ONLY with a valid JSON object -- no markdown, no explanation outside JSON:
{
  "executiveSummary": "2-3 sentence executive summary for a manager",
  "overallAssessment": "IMPROVED|DEGRADED|NEUTRAL|SUSPICIOUS",
  "securityDelta": 0,
  "changeAnalysis": [
    {
      "item": "item identifier",
      "category": "Security|Network|Identity|Hardware|Software|Configuration|Persistence",
      "classification": "Improvement|Regression|Neutral|Suspicious",
      "explanation": "plain English explanation",
      "severity": "Critical|High|Medium|Low|Info",
      "cis_reference": "CIS/NIST reference or empty string",
      "rollback": "PowerShell rollback command or empty string"
    }
  ],
  "suspiciousFindings": [],
  "recommendations": [],
  "requiresImmediateAction": false,
  "complianceSummary": "brief compliance posture note"
}
"@

    Write-Step "Prompt size: $($prompt.Length) chars, ~$([math]::Round($prompt.Length / 4)) tokens" 'DarkGray'

    # Everything that used to live here -- endpoint, headers, the model loop,
    # per-status error branching, and a private copy of the response-body
    # parser -- now belongs to FieldOps-AIClient (6.5-R1). Model fallback,
    # retry with backoff, cost ceilings and audit logging come with it, none of
    # which this call site had before. What is left is what is genuinely local:
    # the prompt, the JSON fence strip, and the fallback contract.
    if (-not $script:AIClientLoaded) {
        Write-Step "[WARN] AI client module unavailable. Falling back to local rules." 'Yellow'
        return $null
    }

    Write-Step "Calling AI (Reasoning tier, $([math]::Round($prompt.Length / 1KB, 1)) KB prompt)..." 'Cyan'

    $call = Invoke-FieldOpsAI -Prompt $prompt -TaskTier 'Reasoning' -MaxTokens 4000 `
                -CallingContext 'ComplianceDiff/Analysis'

    if (-not $call.Success) {
        Write-AIFailureGuidance -Call $call
        Write-Step "Falling back to local rule-based classification." 'DarkGray'
        return $null
    }

    $rawText = [string]$call.Response
    if (-not $rawText) {
        Write-Step "[WARN] AI returned an empty response. Falling back to local rules." 'Yellow'
        return $null
    }

    # Strip any markdown fence if the model wrapped the JSON.
    $rawText = $rawText -replace '(?s)^```json\s*',''
    $rawText = $rawText -replace '```$',''
    $rawText = $rawText.Trim()

    try {
        $aiResult = $rawText | ConvertFrom-Json -ErrorAction Stop
    } catch {
        # A model that answers in prose instead of JSON is a bad response, not
        # a bad run: local rules still produce a complete report.
        Write-Step "[WARN] AI response was not valid JSON. Falling back to local rules." 'Yellow'
        return $null
    }

    # Report the model that actually answered, which after cross-model fallback
    # is not necessarily the one requested.
    $script:AI_MODEL = $call.Model
    $costNote = "{0:N4} USD" -f [double]$call.CostUSD
    Write-Step "AI analysis complete ($($call.Model), $costNote). Assessment: $($aiResult.overallAssessment)" 'Green'
    return $aiResult
}

# ==============================================================
# ROLLBACK SCRIPT GENERATOR
# ==============================================================
function New-RollbackScript {
    param([System.Collections.Generic.List[PSCustomObject]]$Changes, $AiResult, [string]$OutPath)

    $lines = [System.Collections.Generic.List[string]]::new()
    $null = $lines.Add("# FieldOps Pro -- Compliance Diff Rollback Script")
    $null = $lines.Add("# Generated: $($NOW.ToString('yyyy-MM-dd HH:mm:ss'))")
    $null = $lines.Add("# Host: $HOSTNAME | Technician: $techName")
    $null = $lines.Add("# WARNING: Review each command before running. Test in isolated environment first.")
    $null = $lines.Add("#Requires -RunAsAdministrator")
    $null = $lines.Add("")
    $null = $lines.Add('$ErrorActionPreference = "Continue"')
    $null = $lines.Add("")

    $addedRollbacks = 0

    # AI-provided rollback commands
    if ($AiResult -and $AiResult.changeAnalysis) {
        foreach ($ca in @($AiResult.changeAnalysis)) {
            if ($ca.rollback -and $ca.rollback.Trim() -ne '') {
                $null = $lines.Add("# Rollback: $($ca.item)")
                $null = $lines.Add("# Classification: $($ca.classification) | $($ca.severity)")
                $null = $lines.Add($ca.rollback)
                $null = $lines.Add("")
                $addedRollbacks++
            }
        }
    }

    # Local rule-based rollbacks for registry changes
    foreach ($c in @($Changes)) {
        if ($c.ChangeType -ne 'MODIFIED' -or $c.Category -ne 'Registry') { continue }
        $rb = ''
        $parts = $c.Item -split ' \\ ', 2
        if ($parts.Count -eq 2) {
            $keySection = $parts[0]; $propName = $parts[1]
            # Map section to actual registry path
            $pathMap = @{
                'LSA'             = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
                'UAC'             = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
                'Winlogon'        = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
                'WDigest'         = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest'
                'PSLogging'       = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging'
                'SMBClient'       = 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters'
                'SMBServer'       = 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters'
                'HVCI'            = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard'
            }
            if ($pathMap.ContainsKey($keySection)) {
                $regPath = $pathMap[$keySection]
                $bVal    = $c.Before -replace '[^0-9]',''
                if ($bVal -match '^\d+$') {
                    $rb = "Set-ItemProperty -Path '$regPath' -Name '$propName' -Value $bVal -Type DWord -Force  # Restores $keySection\$propName to $($c.Before)"
                }
            }
        }
        if ($rb -ne '') {
            $null = $lines.Add("# Rollback: $($c.Item)")
            $null = $lines.Add($rb)
            $null = $lines.Add("")
            $addedRollbacks++
        }
    }

    if ($addedRollbacks -eq 0) {
        $null = $lines.Add("# No auto-generated rollback commands for this diff.")
        $null = $lines.Add("# Changes may require manual review or are not reversible via script.")
    }

    try {
        $lines | Set-Content -Path $OutPath -Encoding UTF8
        return $addedRollbacks
    } catch { return 0 }
}

# ==============================================================
# HTML REPORT GENERATOR
# ==============================================================
function New-DiffReport {
    param($BeforeSnap, $AfterSnap, $AllChanges, $AiResult, [string]$RollbackPath)

    $changeArr = @($AllChanges)
    $genTime   = $NOW.ToString('yyyy-MM-dd HH:mm:ss')
    $bTime     = if ($BeforeSnap.Timestamp) { [datetime]::Parse($BeforeSnap.Timestamp).ToString('yyyy-MM-dd HH:mm:ss') } else { 'Unknown' }
    $aTime     = if ($AfterSnap.Timestamp)  { [datetime]::Parse($AfterSnap.Timestamp).ToString('yyyy-MM-dd HH:mm:ss') }  else { 'Unknown' }

    $improvements= @($changeArr | Where-Object { $_.LocalClass -eq 'Improvement' -or ($AiResult -and (Get-AiClass $AiResult $_.Item) -eq 'Improvement') }).Count
    $regressions = @($changeArr | Where-Object { $_.LocalClass -eq 'Regression'  -or ($AiResult -and (Get-AiClass $AiResult $_.Item) -eq 'Regression') }).Count
    $suspicious  = @($changeArr | Where-Object { $_.LocalClass -eq 'Suspicious'  -or ($AiResult -and (Get-AiClass $AiResult $_.Item) -eq 'Suspicious') }).Count
    $neutral     = $changeArr.Count - $improvements - $regressions - $suspicious

    $overall     = if ($AiResult) { $AiResult.overallAssessment } `
                   elseif ($suspicious -gt 0) { 'SUSPICIOUS' } `
                   elseif ($regressions -gt 0) { 'DEGRADED' } `
                   elseif ($improvements -gt 0) { 'IMPROVED' } else { 'NEUTRAL' }

    $overallColor = switch ($overall) {
        'IMPROVED'   { '#22c55e' } 'NEUTRAL' { '#38bdf8' }
        'DEGRADED'   { '#ef4444' } 'SUSPICIOUS' { '#f97316' }
        default      { '#94a3b8' }
    }

    $secDelta     = if ($AiResult -and $null -ne $AiResult.securityDelta) { $AiResult.securityDelta } else { $improvements - ($regressions * 3) - ($suspicious * 5) }
    $secDeltaColor= if ($secDelta -gt 0) { '#22c55e' } elseif ($secDelta -lt 0) { '#ef4444' } else { '#94a3b8' }
    $secDeltaStr  = if ($secDelta -gt 0) { "+$secDelta" } else { "$secDelta" }

    # Build AI analysis section
    $aiHtml = ''
    if ($AiResult) {
        $execSum = if ($AiResult.executiveSummary) { $AiResult.executiveSummary } else { '' }
        $compNote= if ($AiResult.complianceSummary) { $AiResult.complianceSummary } else { '' }

        $suspHtml = ''
        if ($AiResult.suspiciousFindings) {
            foreach ($sf in @($AiResult.suspiciousFindings)) {
                $suspHtml += "<div class='alert-item'><span style='color:#f97316;margin-right:8px'>!</span>$sf</div>"
            }
        }

        $recHtml = ''
        if ($AiResult.recommendations) {
            $ri = 1
            foreach ($rec in @($AiResult.recommendations)) {
                $recHtml += "<div class='rec-item'><span style='color:#38bdf8;margin-right:8px;font-weight:bold'>$ri.</span>$rec</div>"
                $ri++
            }
        }

        $aiHtml = @"
<div class="section-title">AI ANALYSIS -- $AI_MODEL</div>
<div class="card" style="margin-bottom:16px">
  <div class="card-label">Executive Summary</div>
  <div style="color:#cbd5e1;line-height:1.7;font-size:13px">$execSum</div>
  $(if ($compNote) { "<div style='color:#64748b;font-size:11px;margin-top:10px;border-top:1px solid #334155;padding-top:10px'>$compNote</div>" })
</div>
$(if ($suspHtml) { "<div class='card' style='border-left:3px solid #f97316;margin-bottom:16px'><div class='card-label' style='color:#f97316'>Suspicious Findings</div>$suspHtml</div>" })
$(if ($recHtml) { "<div class='card' style='margin-bottom:16px'><div class='card-label'>Prioritized Recommendations</div>$recHtml</div>" })
"@
    }

    # Build change table rows
    $rowsHtml = ''
    # Merge AI per-change analysis into the change list for display
    $aiMap = @{}
    if ($AiResult -and $AiResult.changeAnalysis) {
        foreach ($ca in @($AiResult.changeAnalysis)) {
            if ($ca.item) { $aiMap[$ca.item] = $ca }
        }
    }

    $sortedChanges = @($changeArr | Sort-Object {
        switch ($_.Severity) { 'Critical' {0} 'High' {1} 'Medium' {2} 'Low' {3} default {4} }
    })

    foreach ($ch in $sortedChanges) {
        $aiEntry  = if ($aiMap.ContainsKey($ch.Item)) { $aiMap[$ch.Item] } else { $null }
        $class    = if ($aiEntry -and $aiEntry.classification) { $aiEntry.classification } else { $ch.LocalClass }
        $sev      = if ($aiEntry -and $aiEntry.severity) { $aiEntry.severity } else { $ch.Severity }
        $expl     = if ($aiEntry -and $aiEntry.explanation) { $aiEntry.explanation } `
                    elseif ($ch.PSObject.Properties['LocalExplanation'] -and $ch.LocalExplanation) { $ch.LocalExplanation } else { '' }
        $cisRef   = if ($aiEntry -and $aiEntry.cis_reference) { $aiEntry.cis_reference } else { '' }

        $cColor = switch ($class) {
            'Improvement' { '#22c55e' } 'Regression' { '#ef4444' }
            'Suspicious'  { '#f97316' } 'Neutral' { '#94a3b8' }
            default { '#64748b' }
        }
        $sColor = switch ($sev) {
            'Critical' { '#ef4444' } 'High'   { '#f97316' }
            'Medium'   { '#eab308' } 'Low'    { '#22c55e' }
            default    { '#94a3b8' }
        }
        $typeColor = switch ($ch.ChangeType) {
            'ADDED'    { '#22c55e' } 'REMOVED' { '#ef4444' }
            'MODIFIED' { '#38bdf8' } default { '#94a3b8' }
        }

        $bStrRaw = if ($null -ne $ch.Before) { [string]$ch.Before } else { '' }
        $aStrRaw = if ($null -ne $ch.After)  { [string]$ch.After }  else { '' }
        $bTrunc = if ($bStrRaw.Length -gt 80) { $bStrRaw.Substring(0,77) + '...' } else { $bStrRaw }
        $aTrunc = if ($aStrRaw.Length -gt 80) { $aStrRaw.Substring(0,77) + '...' } else { $aStrRaw }

        # v1.1.0: MITRE tag + risk score
        $mitreVal = if ($ch.PSObject.Properties['Mitre']) { $ch.Mitre } else { '' }
        $riskVal  = if ($ch.PSObject.Properties['RiskScore']) { $ch.RiskScore } else { 0 }
        $riskColor= if ($riskVal -ge 20) { '#ef4444' } elseif ($riskVal -ge 10) { '#f97316' } elseif ($riskVal -gt 0) { '#eab308' } elseif ($riskVal -lt 0) { '#22c55e' } else { '#64748b' }

        $rowsHtml += @"
<tr>
  <td><span class="badge" style="background:$(${typeColor})22;color:$typeColor;border:1px solid $typeColor">$($ch.ChangeType)</span></td>
  <td style="color:#94a3b8;font-size:11px">$($ch.Category)</td>
  <td style="color:#e2e8f0;font-size:11px;max-width:180px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title="$($ch.Item)">$($ch.Item)</td>
  <td><span class="badge" style="background:$(${cColor})22;color:$cColor;border:1px solid $cColor">$class</span></td>
  <td><span class="badge" style="background:$(${sColor})22;color:$sColor;border:1px solid $sColor">$sev</span></td>
  <td style="color:$riskColor;font-size:11px;font-weight:bold;text-align:center">$riskVal</td>
  <td style="color:#a855f7;font-size:10px;max-width:140px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title="$mitreVal">$mitreVal</td>
  <td style="color:#64748b;font-size:10px;max-width:120px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title="$bStrRaw">$bTrunc</td>
  <td style="color:#38bdf8;font-size:10px;max-width:120px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title="$aStrRaw">$aTrunc</td>
  <td style="color:#64748b;font-size:11px;max-width:200px">$expl</td>
  <td style="color:#475569;font-size:10px">$cisRef</td>
</tr>
"@
    }

    $rbName = [IO.Path]::GetFileName($RollbackPath)
    $incText= if ($IncidentId) { $IncidentId } else { 'N/A' }

    return @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Compliance Diff -- $HOSTNAME -- $($NOW.ToString('yyyy-MM-dd'))</title>
<style>
* { box-sizing:border-box; margin:0; padding:0; }
body { background:#0f172a; color:#e2e8f0; font-family:'Consolas','Courier New',monospace; padding:24px; }
.header { text-align:center; padding:32px 0 24px; border-bottom:2px solid #38bdf8; margin-bottom:32px; }
.header h1 { font-size:20px; color:#38bdf8; letter-spacing:3px; }
.header .meta { font-size:12px; color:#94a3b8; margin-top:10px; display:flex; justify-content:center; gap:14px; flex-wrap:wrap; }
.header .meta span { background:#1e293b; border:1px solid #334155; padding:3px 10px; border-radius:4px; }
.kpi-grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(130px,1fr)); gap:12px; margin-bottom:32px; }
.kpi { background:#1e293b; border:1px solid #334155; border-radius:8px; padding:14px; text-align:center; }
.kpi .v { font-size:28px; font-weight:bold; }
.kpi .l { font-size:10px; color:#94a3b8; margin-top:4px; text-transform:uppercase; letter-spacing:1px; }
.section-title { font-size:12px; color:#38bdf8; border-bottom:1px solid #334155; padding-bottom:7px; margin:28px 0 14px; letter-spacing:2px; text-transform:uppercase; }
.card { background:#1e293b; border:1px solid #334155; border-radius:8px; padding:18px; margin-bottom:12px; }
.card-label { font-size:10px; color:#64748b; text-transform:uppercase; letter-spacing:1px; margin-bottom:10px; }
.status-banner { text-align:center; padding:18px; border-radius:10px; margin-bottom:24px; font-size:20px; font-weight:bold; letter-spacing:3px; border:2px solid; }
table { width:100%; border-collapse:collapse; font-size:11px; }
th { background:#0f172a; color:#64748b; text-align:left; padding:8px 10px; font-size:10px; text-transform:uppercase; letter-spacing:1px; white-space:nowrap; }
td { padding:8px 10px; border-top:1px solid #1e293b; vertical-align:middle; }
tr:hover td { background:rgba(56,189,248,0.03); }
.badge { display:inline-block; padding:2px 7px; border-radius:4px; font-size:10px; font-weight:bold; white-space:nowrap; }
.alert-item { padding:8px 12px; margin:5px 0; background:#f9733311; border-left:3px solid #f97316; border-radius:4px; font-size:12px; color:#cbd5e1; }
.rec-item { padding:8px 12px; margin:5px 0; background:#38bdf811; border-left:3px solid #38bdf8; border-radius:4px; font-size:12px; color:#cbd5e1; }
.tl-item { display:flex; gap:16px; padding:10px 0; border-bottom:1px solid #1e293b; }
.tl-dot { width:10px; height:10px; border-radius:50%; flex-shrink:0; margin-top:4px; }
.footer { text-align:center; color:#475569; font-size:11px; margin-top:40px; padding-top:16px; border-top:1px solid #1e293b; }
</style>
</head>
<body>

<div class="header">
  <div style="font-size:11px;color:#64748b;letter-spacing:2px;margin-bottom:6px">FIELDOPS PRO -- AI COMPLIANCE DIFF ENGINE v$VERSION</div>
  <h1>COMPLIANCE DIFF REPORT</h1>
  <div style="font-size:14px;color:#94a3b8;margin-top:6px">$HOSTNAME</div>
  <div class="meta">
    <span>Technician: $techName</span>
    <span>Ticket: $incText</span>
    <span>Before: $bTime</span>
    <span>After: $aTime</span>
    <span>Total Changes: $($changeArr.Count)</span>
    <span>AI: $(if ($AiResult) { $AI_MODEL } else { 'Local Rules' })</span>
  </div>
</div>

<div class="status-banner" style="background:$($overallColor)11;color:$overallColor;border-color:$overallColor">
  $overall
</div>

<div class="kpi-grid">
  <div class="kpi"><div class="v" style="color:#38bdf8">$($changeArr.Count)</div><div class="l">Total Changes</div></div>
  <div class="kpi"><div class="v" style="color:#22c55e">$improvements</div><div class="l">Improvements</div></div>
  <div class="kpi"><div class="v" style="color:#ef4444">$regressions</div><div class="l">Regressions</div></div>
  <div class="kpi"><div class="v" style="color:#f97316">$suspicious</div><div class="l">Suspicious</div></div>
  <div class="kpi"><div class="v" style="color:#94a3b8">$neutral</div><div class="l">Neutral</div></div>
  <div class="kpi"><div class="v" style="color:$secDeltaColor">$secDeltaStr</div><div class="l">Security Delta</div></div>
</div>

$aiHtml

<div class="section-title">Full Change Log ($($changeArr.Count) changes)</div>
<div style="overflow-x:auto;margin-bottom:32px">
<table>
<thead><tr>
  <th>Type</th><th>Category</th><th>Item</th>
  <th>Classification</th><th>Severity</th><th>Risk</th><th>MITRE ATT&amp;CK</th>
  <th>Before</th><th>After</th>
  <th>Explanation</th><th>CIS/NIST</th>
</tr></thead>
<tbody>$rowsHtml</tbody>
</table>
</div>

<div class="section-title">Rollback Script</div>
<div class="card" style="margin-bottom:32px">
  <div class="card-label">Auto-generated rollback commands</div>
  <div style="color:#cbd5e1;font-size:12px">
    Rollback script saved to: <span style="color:#38bdf8">$RollbackPath</span><br>
    Run this script in an elevated PowerShell session to reverse applied changes.<br>
    <strong style="color:#f97316">IMPORTANT:</strong> Review every command before running. Test in isolated environment first.
  </div>
</div>

<div class="footer">
  FieldOps Pro AI Compliance Diff Engine v$VERSION | $genTime | $techName | $HOSTNAME |
  AI: $(if ($AiResult) { $AI_MODEL } else { 'Local Rules' })
</div>
</body>
</html>
"@
}

# Helper: look up AI classification for an item
function Get-AiClass { param($AiResult, [string]$Item)
    if (-not $AiResult -or -not $AiResult.changeAnalysis) { return '' }
    $match = @($AiResult.changeAnalysis | Where-Object { $_.item -eq $Item }) | Select-Object -First 1
    if ($match) { return $match.classification }
    return ''
}

# ==============================================================
# DIFF ORCHESTRATOR
# ==============================================================
function Invoke-FullDiff {
    param($BeforeSnap, $AfterSnap)

    Write-Section 'RUNNING COMPLIANCE DIFF ENGINE'

    $allChanges = [System.Collections.Generic.List[PSCustomObject]]::new()
    $bData = $BeforeSnap.Data
    $aData = $AfterSnap.Data

    # Services
    Write-Step "Diffing Services..."
    $svcChanges = @(Compare-Arrays $bData.Services $aData.Services 'Name' 'Services')
    foreach ($c in $svcChanges) { $null = $allChanges.Add($c) }
    Write-Step "  $($svcChanges.Count) service changes" 'DarkGray'

    # Registry
    Write-Step "Diffing Registry..."
    $regChanges = @(Compare-OrderedDicts $bData.Registry $aData.Registry 'Registry')
    foreach ($c in $regChanges) { $null = $allChanges.Add($c) }
    Write-Step "  $($regChanges.Count) registry changes" 'DarkGray'

    # Scheduled Tasks
    Write-Step "Diffing Scheduled Tasks..."
    $taskChanges = @(Compare-Arrays $bData.ScheduledTasks $aData.ScheduledTasks 'TaskName' 'ScheduledTasks')
    foreach ($c in $taskChanges) { $null = $allChanges.Add($c) }
    Write-Step "  $($taskChanges.Count) task changes" 'DarkGray'

    # Firewall profiles
    # FIX v1.0.1: flipped '-ne $null' to '$null -ne' per PS convention
    Write-Step "Diffing Firewall..."
    $fwFields = @('DomainEnabled','PrivateEnabled','PublicEnabled')
    foreach ($fld in $fwFields) {
        $bv = if ($null -ne $bData.Firewall.$fld) { "$($bData.Firewall.$fld)" } else { '(absent)' }
        $av = if ($null -ne $aData.Firewall.$fld) { "$($aData.Firewall.$fld)" } else { '(absent)' }
        if ($bv -ne $av) {
            $null = $allChanges.Add([PSCustomObject]@{
                Category='Firewall'; ChangeType='MODIFIED'; Item=$fld
                Before=$bv; After=$av; LocalClass='Neutral'; Severity='High'
            })
        }
    }
    $fwRuleChanges = @(Compare-Arrays $bData.Firewall.Rules $aData.Firewall.Rules 'Name' 'Firewall')
    foreach ($c in $fwRuleChanges) { $null = $allChanges.Add($c) }
    Write-Step "  $(@($allChanges | Where-Object { $_.Category -eq 'Firewall' }).Count) firewall changes" 'DarkGray'

    # Local Users
    Write-Step "Diffing Local Users..."
    $userChanges = @(Compare-Arrays $bData.LocalUsers.Users $aData.LocalUsers.Users 'Name' 'Users')
    foreach ($c in $userChanges) { $null = $allChanges.Add($c) }
    Write-Step "  $($userChanges.Count) user changes" 'DarkGray'

    # Software
    Write-Step "Diffing Installed Software..."
    $swChanges = @(Compare-Arrays $bData.Software $aData.Software 'Name' 'Software')
    foreach ($c in $swChanges) { $null = $allChanges.Add($c) }
    Write-Step "  $($swChanges.Count) software changes" 'DarkGray'

    # Ports
    Write-Step "Diffing Listening Ports..."
    $portChanges = @(Compare-Arrays $bData.Ports $aData.Ports 'LocalPort' 'Ports')
    foreach ($c in $portChanges) { $null = $allChanges.Add($c) }
    Write-Step "  $($portChanges.Count) port changes" 'DarkGray'

    # Certificates
    Write-Step "Diffing Certificates..."
    $certChanges = @(Compare-Arrays $bData.Certificates $aData.Certificates 'Thumbprint' 'Certificates')
    foreach ($c in $certChanges) { $null = $allChanges.Add($c) }
    Write-Step "  $($certChanges.Count) certificate changes" 'DarkGray'

    # Startup Items
    Write-Step "Diffing Startup Items..."
    $startChanges = @(Compare-Arrays $bData.StartupItems $aData.StartupItems 'Name' 'StartupItems')
    foreach ($c in $startChanges) { $null = $allChanges.Add($c) }
    Write-Step "  $($startChanges.Count) startup changes" 'DarkGray'

    # SMB Shares
    Write-Step "Diffing SMB Shares..."
    $smbChanges = @(Compare-Arrays $bData.SmbShares $aData.SmbShares 'Name' 'SmbShares')
    foreach ($c in $smbChanges) { $null = $allChanges.Add($c) }
    Write-Step "  $($smbChanges.Count) SMB share changes" 'DarkGray'

    # BitLocker
    # Note: when loaded from JSON, ordered dictionaries become PSCustomObject.
    # Compare-OrderedDicts handles both, so pass through as-is.
    Write-Step "Diffing BitLocker..."
    $blChanges = @(Compare-OrderedDicts $bData.BitLocker $aData.BitLocker 'BitLocker')
    foreach ($c in $blChanges) { $null = $allChanges.Add($c) }
    Write-Step "  $($blChanges.Count) BitLocker changes" 'DarkGray'

    # Defender
    Write-Step "Diffing Defender..."
    $defChanges = @(Compare-OrderedDicts $bData.Defender $aData.Defender 'Defender')
    foreach ($c in $defChanges) { $null = $allChanges.Add($c) }
    Write-Step "  $($defChanges.Count) Defender changes" 'DarkGray'

    # ===== v1.1.0 new categories =====
    # Helper: is this category present on the Before snapshot? JSON-round-tripped
    # snapshots come back as PSCustomObject, so we check PSObject.Properties.
    $hasBeforeCategory = {
        param($Name)
        if ($null -eq $bData) { return $false }
        if ($bData -is [System.Collections.IDictionary]) { return $bData.Contains($Name) }
        return [bool]($bData.PSObject.Properties[$Name])
    }

    # WMI Persistence
    Write-Step "Diffing WMI Persistence..."
    if (& $hasBeforeCategory 'WmiPersistence') {
        $wmiFilterChanges   = @(Compare-Arrays $bData.WmiPersistence.Filters   $aData.WmiPersistence.Filters   'Name' 'WmiPersistence')
        $wmiConsumerChanges = @(Compare-Arrays $bData.WmiPersistence.Consumers $aData.WmiPersistence.Consumers 'Name' 'WmiPersistence')
        $wmiBindingChanges  = @(Compare-Arrays $bData.WmiPersistence.Bindings  $aData.WmiPersistence.Bindings  'Filter' 'WmiPersistence')
        foreach ($c in $wmiFilterChanges)   { $null = $allChanges.Add($c) }
        foreach ($c in $wmiConsumerChanges) { $null = $allChanges.Add($c) }
        foreach ($c in $wmiBindingChanges)  { $null = $allChanges.Add($c) }
        Write-Step "  $($wmiFilterChanges.Count + $wmiConsumerChanges.Count + $wmiBindingChanges.Count) WMI persistence changes" 'DarkGray'
    } else {
        Write-Step "  (skipped -- Before snapshot predates v1.1.0 schema)" 'DarkGray'
    }

    # Hosts File
    Write-Step "Diffing Hosts File..."
    if (& $hasBeforeCategory 'HostsFile') {
        $bHash = "$($bData.HostsFile.SHA256)"
        $aHash = "$($aData.HostsFile.SHA256)"
        if ($bHash -ne $aHash) {
            $null = $allChanges.Add([PSCustomObject]@{
                Category='HostsFile'; ChangeType='MODIFIED'; Item='Hosts file SHA256'
                Before=$bHash; After=$aHash; LocalClass='Suspicious'; Severity='High'
            })
            # Line-level diff for visibility
            $bLines = @($bData.HostsFile.ActiveLines)
            $aLines = @($aData.HostsFile.ActiveLines)
            foreach ($l in $aLines) {
                if ($bLines -notcontains $l) {
                    $null = $allChanges.Add([PSCustomObject]@{
                        Category='HostsFile'; ChangeType='ADDED'; Item="Line: $l"
                        Before='(absent)'; After=$l; LocalClass='Suspicious'; Severity='High'
                    })
                }
            }
            foreach ($l in $bLines) {
                if ($aLines -notcontains $l) {
                    $null = $allChanges.Add([PSCustomObject]@{
                        Category='HostsFile'; ChangeType='REMOVED'; Item="Line: $l"
                        Before=$l; After='(absent)'; LocalClass='Neutral'; Severity='Medium'
                    })
                }
            }
            Write-Step "  Hosts file modified (hash mismatch)" 'Yellow'
        } else {
            Write-Step "  Hosts file unchanged" 'DarkGray'
        }
    } else {
        Write-Step "  (skipped -- Before snapshot predates v1.1.0 schema)" 'DarkGray'
    }

    # Environment Variables
    Write-Step "Diffing Environment Variables..."
    if (& $hasBeforeCategory 'Environment') {
        $envChanges = @(Compare-OrderedDicts $bData.Environment $aData.Environment 'Environment')
        foreach ($c in $envChanges) { $null = $allChanges.Add($c) }
        Write-Step "  $($envChanges.Count) environment changes" 'DarkGray'
    } else {
        Write-Step "  (skipped -- Before snapshot predates v1.1.0 schema)" 'DarkGray'
    }

    # Kernel Drivers
    Write-Step "Diffing Kernel Drivers..."
    if (& $hasBeforeCategory 'Drivers') {
        $drvChanges = @(Compare-Arrays $bData.Drivers $aData.Drivers 'Name' 'Drivers')
        foreach ($c in $drvChanges) { $null = $allChanges.Add($c) }
        Write-Step "  $($drvChanges.Count) driver changes" 'DarkGray'
    } else {
        Write-Step "  (skipped -- Before snapshot predates v1.1.0 schema)" 'DarkGray'
    }

    Write-Host ''
    Write-Step "Total changes detected: $($allChanges.Count)" 'Cyan'

    # Local classification pass
    Write-Step "Applying local rule classification..."
    Invoke-LocalClassification $allChanges

    $impr = @($allChanges | Where-Object { $_.LocalClass -eq 'Improvement' }).Count
    $regr = @($allChanges | Where-Object { $_.LocalClass -eq 'Regression' }).Count
    $susp = @($allChanges | Where-Object { $_.LocalClass -eq 'Suspicious' }).Count
    Write-Step "Local rules: Improvements=$impr  Regressions=$regr  Suspicious=$susp" 'DarkGray'

    return $allChanges
}

# ==============================================================
# SNAPSHOT FILE HELPERS
# ==============================================================
# FIX v1.0.1: Compare-OrderedDicts previously required the input to still be
# an OrderedDictionary. After JSON round-trip (Before snapshot is loaded from
# disk via ConvertFrom-Json), ordered dicts become PSCustomObject. The
# function already had a PSObject.Properties fallback branch, so this works
# once we stop manually reconstructing an [ordered] dict in Invoke-FullDiff.
# (See Invoke-FullDiff BitLocker/Defender sections above.)

function Save-Snapshot {
    param($Snapshot, [string]$Type)
    $ts   = $NOW.ToString('yyyyMMdd_HHmmss')
    $safe = $SnapshotId -replace '[\\/:*?"<>|]','_'
    # v1.2.1: Save as .json.gz (GZip compressed). 39 MB -> ~3-4 MB.
    $path = Join-Path $snapshotDir "$HOSTNAME`_$Type`_$safe`_$ts.json.gz"

    Write-Step "Saving $Type snapshot (chunked + gzip)..." 'DarkGray'
    $swTotal = [System.Diagnostics.Stopwatch]::StartNew()

    $sb = [System.Text.StringBuilder]::new(4 * 1024 * 1024)

    # Build wrapper metadata
    $null = $sb.AppendLine('{')
    $null = $sb.AppendLine("  ""SnapshotId"": ""$($Snapshot.SnapshotId)"",")
    $null = $sb.AppendLine("  ""Type"": ""$($Snapshot.Type)"",")
    $null = $sb.AppendLine("  ""Hostname"": ""$($Snapshot.Hostname)"",")
    $null = $sb.AppendLine("  ""Technician"": ""$($Snapshot.Technician -replace '"','\"')"",")
    $null = $sb.AppendLine("  ""Timestamp"": ""$($Snapshot.Timestamp)"",")
    $null = $sb.AppendLine("  ""IncidentId"": ""$($Snapshot.IncidentId)"",")

    $stampAt = (Get-Date).ToString('o')
    $null = $sb.AppendLine('  "Integrity": {')
    $null = $sb.AppendLine('    "Algorithm": "SHA256",')
    $null = $sb.AppendLine("    ""StampedAt"": ""$stampAt"",")
    $null = $sb.AppendLine("    ""StampedBy"": ""$($techName -replace '"','\"')"",")
    $null = $sb.AppendLine("    ""ToolVersion"": ""$VERSION""")
    $null = $sb.AppendLine('  },')

    $null = $sb.AppendLine('  "Data": {')
    $dataObj  = $Snapshot.Data
    $catNames = @()
    if ($dataObj -is [System.Collections.IDictionary]) {
        $catNames = @($dataObj.Keys)
    } elseif ($dataObj.PSObject -and $dataObj.PSObject.Properties) {
        $catNames = @($dataObj.PSObject.Properties.Name)
    }

    $catCount = $catNames.Count
    $catIndex = 0
    foreach ($catName in $catNames) {
        $catIndex++
        $catValue = $null
        if ($dataObj -is [System.Collections.IDictionary]) {
            $catValue = $dataObj[$catName]
        } else {
            $catValue = $dataObj.$catName
        }

        $swCat = [System.Diagnostics.Stopwatch]::StartNew()
        $catJson = $catValue | ConvertTo-Json -Depth 5 -Compress
        $swCat.Stop()

        $comma = if ($catIndex -lt $catCount) { ',' } else { '' }
        $null = $sb.AppendLine("    ""$catName"": $catJson$comma")

        if ($swCat.Elapsed.TotalSeconds -gt 2) {
            Write-Step "  $catName serialized ($([math]::Round($swCat.Elapsed.TotalSeconds,1))s)" 'DarkGray'
        }
    }

    $null = $sb.AppendLine('  }')
    $null = $sb.AppendLine('}')

    # GZip compress and write to disk
    $jsonBytes = [System.Text.Encoding]::UTF8.GetBytes($sb.ToString())
    $rawSize   = $jsonBytes.Length

    try {
        $fileStream = [System.IO.File]::Create($path)
        $gzStream   = [System.IO.Compression.GZipStream]::new($fileStream, [System.IO.Compression.CompressionLevel]::Optimal)
        $gzStream.Write($jsonBytes, 0, $jsonBytes.Length)
        $gzStream.Close()
        $fileStream.Close()
    } catch {
        # Fallback: write uncompressed .json if GZip fails
        $path = $path -replace '\.gz$',''
        [System.IO.File]::WriteAllText($path, $sb.ToString(), [System.Text.Encoding]::UTF8)
        Write-Step "[WARN] GZip failed, saved uncompressed: $_" 'Yellow'
    }

    $swTotal.Stop()
    $compSize = (Get-Item $path).Length
    $rawMB    = [math]::Round($rawSize / 1MB, 1)
    $compMB   = [math]::Round($compSize / 1MB, 1)
    $ratio    = if ($rawSize -gt 0) { [math]::Round((1 - $compSize / $rawSize) * 100) } else { 0 }
    Write-Step "Snapshot saved: $compMB MB (was $rawMB MB, $ratio% compressed) in $([math]::Round($swTotal.Elapsed.TotalSeconds,1))s" 'Green'

    # Sidecar SHA256
    try {
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $sha   = [System.Security.Cryptography.SHA256]::Create()
        $hash  = ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-','').ToLower()
        $sha.Dispose()
        $sidecarPath = "$path.sha256"
        $stamp = [PSCustomObject]@{
            Algorithm    = 'SHA256'
            Hash         = $hash
            File         = [IO.Path]::GetFileName($path)
            FileSize     = $bytes.Length
            RawSize      = $rawSize
            Compressed   = $path.EndsWith('.gz')
            StampedAt    = (Get-Date).ToString('o')
            StampedBy    = $techName
            ToolVersion  = $VERSION
        }
        $stamp | ConvertTo-Json | Set-Content -Path $sidecarPath -Encoding UTF8
        Write-Step "Integrity: $($hash.Substring(0,16))..." 'DarkGray'
    } catch {
        Write-Step "[WARN] Integrity sidecar creation failed: $_" 'Yellow'
    }

    return $path
}

# v1.2.1: Load a snapshot from disk. Handles both .json.gz (compressed)
# and .json (legacy uncompressed) transparently.
function Read-Snapshot {
    param([string]$Path)
    if ($Path.EndsWith('.gz')) {
        $fileStream = [System.IO.File]::OpenRead($Path)
        $gzStream   = [System.IO.Compression.GZipStream]::new($fileStream, [System.IO.Compression.CompressionMode]::Decompress)
        $reader     = [System.IO.StreamReader]::new($gzStream, [System.Text.Encoding]::UTF8)
        $json       = $reader.ReadToEnd()
        $reader.Close()
        $gzStream.Close()
        $fileStream.Close()
        return ($json | ConvertFrom-Json)
    } else {
        return (Get-Content $Path -Raw | ConvertFrom-Json)
    }
}

# v1.1.0/v1.1.1: inspect a loaded snapshot's audit-trail stamp.
# Note: we intentionally don't re-compute any hash here because
# ConvertTo-Json output is not guaranteed to be byte-identical after a
# ConvertFrom-Json round-trip (PSCustomObject vs OrderedDictionary
# enumeration, subtle array and whitespace differences). Instead,
# v1.1.1 stores the SHA256 in a sidecar .sha256 file computed over
# the raw on-disk JSON bytes. Any external hashing tool can verify it.
function Test-SnapshotIntegrity {
    param($Snapshot)
    $result = [PSCustomObject]@{
        HasStamp      = $false
        StampedBy     = ''
        StampedAt     = ''
        ToolVersion   = ''
        HashSidecar   = ''
    }
    if (-not $Snapshot) { return $result }
    if (-not $Snapshot.PSObject.Properties['Integrity']) { return $result }
    if (-not $Snapshot.Integrity) { return $result }
    $result.HasStamp    = $true
    $result.StampedBy   = "$($Snapshot.Integrity.StampedBy)"
    $result.StampedAt   = "$($Snapshot.Integrity.StampedAt)"
    $result.ToolVersion = "$($Snapshot.Integrity.ToolVersion)"
    if ($Snapshot.Integrity.PSObject.Properties['HashSidecar']) {
        $result.HashSidecar = "$($Snapshot.Integrity.HashSidecar)"
    }
    return $result
}

# v1.1.0: export the full change list to CSV for SIEM/SOAR ingestion.
function Export-DiffCsv {
    param(
        [System.Collections.Generic.List[PSCustomObject]]$Changes,
        [string]$OutPath
    )
    try {
        $rows = @($Changes | ForEach-Object {
            $mitreVal = if ($_.PSObject.Properties['Mitre']) { $_.Mitre } else { '' }
            $riskVal  = if ($_.PSObject.Properties['RiskScore']) { $_.RiskScore } else { 0 }
            $explVal  = if ($_.PSObject.Properties['LocalExplanation']) { $_.LocalExplanation } else { '' }
            [PSCustomObject]@{
                Timestamp       = $NOW.ToString('o')
                Host            = $HOSTNAME
                Technician      = $techName
                IncidentId      = $IncidentId
                Category        = $_.Category
                ChangeType      = $_.ChangeType
                Item            = $_.Item
                Classification  = $_.LocalClass
                Severity        = $_.Severity
                RiskScore       = $riskVal
                MitreTechnique  = $mitreVal
                Explanation     = $explVal
                Before          = "$($_.Before)"
                After           = "$($_.After)"
            }
        })
        $rows | Export-Csv -Path $OutPath -NoTypeInformation -Encoding UTF8
        return $true
    } catch {
        return $false
    }
}

# FIX v1.0.1: Parameter renamed from $Host to $HostName. $Host is a
# PowerShell automatic variable representing the host UI; using it as a
# parameter name is flagged by PSScriptAnalyzer (PSAvoidAssignmentToAutomaticVariable)
# and fails under Set-StrictMode -Version Latest.
# v1.2.1: Find Before snapshots. Matches both .json.gz (v1.2.1+) and
# .json (legacy). Excludes .sha256 sidecars. Prefers compressed files
# if both exist for the same timestamp.
function Find-BeforeSnapshot {
    param([string]$Dir, [string]$HostName, [string]$SID)
    $safe = $SID -replace '[\\/:*?"<>|]','_'

    # Get all Before files: .json.gz and .json, exclude .sha256
    $files = @(Get-ChildItem -Path $Dir -Filter "$HostName`_Before_*" -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -match '\.(json|json\.gz)$' -and $_.Name -notmatch '\.sha256$' } |
               Sort-Object LastWriteTime -Descending)

    # First try with snapshot ID match
    $matched = @($files | Where-Object { $_.Name -like "*_$safe`_*" })
    if ($matched.Count -gt 0) { return $matched[0].FullName }
    # Fallback: most recent Before for this host
    if ($files.Count -gt 0) { return $files[0].FullName }
    return $null
}

# ==============================================================
# MAIN EXECUTION
# ==============================================================

Write-Banner

# Ensure directories
foreach ($d in @($reportsDir, $snapshotDir, $logsDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# Determine effective mode
$effectiveMode = $Mode

# v1.2: Interactive menu when run with -Mode Menu or when user just wants guidance
if ($effectiveMode -eq 'Menu') {

    # Gather context to make the menu smart
    $existingBefore = Find-BeforeSnapshot $snapshotDir $HOSTNAME $SnapshotId
    $snapCount      = @(Get-ChildItem -Path $snapshotDir -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -match '\.(json|json\.gz)$' -and $_.Name -notmatch '\.sha256$' }).Count
    $reportCount    = @(Get-ChildItem -Path $reportsDir -Filter "ComplianceDiff_*.html" -ErrorAction SilentlyContinue).Count
    $hasBefore      = [bool]$existingBefore
    $bName          = if ($hasBefore) { [IO.Path]::GetFileName($existingBefore) } else { '' }

    # Status line
    Write-Host ''
    if ($hasBefore) {
        Write-Host '  STATUS: Before snapshot ready -- run your action, then choose [2] or [3]' -ForegroundColor Green
        Write-Host "          $bName" -ForegroundColor DarkGray
    } else {
        Write-Host '  STATUS: No Before snapshot -- start with [1] to take a baseline' -ForegroundColor Yellow
    }

    Write-Host ''
    Write-Host '  ---- FIELD WORKFLOW ----' -ForegroundColor Cyan
    Write-Host ''

    # Highlight the recommended next step
    if (-not $hasBefore) {
        Write-Host '  >> [1] Before     Take a pre-action baseline snapshot' -ForegroundColor White
    } else {
        Write-Host '     [1] Before     Take a fresh baseline (replaces current)' -ForegroundColor DarkGray
    }

    if ($hasBefore) {
        Write-Host '  >> [2] After      Capture + diff + generate report' -ForegroundColor White
    } else {
        Write-Host '     [2] After      (take Before first)' -ForegroundColor DarkGray
    }

    Write-Host '     [3] QuickDiff  Before + run script + After (all-in-one)' -ForegroundColor Gray
    Write-Host '     [4] Auto       Smart mode (detects what to do)' -ForegroundColor Gray

    Write-Host ''
    Write-Host '  ---- TOOLS ----' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '     [5] Compare    Diff two snapshot files manually' -ForegroundColor Gray
    Write-Host "     [6] Cleanup    Manage snapshots ($snapCount on disk)" -ForegroundColor Gray
    Write-Host '     [7] Diagnose   Check config, API key, filesystem' -ForegroundColor Gray

    Write-Host ''
    Write-Host '  ---- INFO ----' -ForegroundColor Cyan
    Write-Host ''
    if ($reportCount -gt 0) {
        Write-Host "     [8] Last Report  Open most recent report ($reportCount available)" -ForegroundColor Gray
    } else {
        Write-Host '     [8] Last Report  (no reports yet)' -ForegroundColor DarkGray
    }
    Write-Host '     [Q] Quit' -ForegroundColor DarkGray

    Write-Host ''
    $choice = Read-Host '  Choice'
    switch ($choice) {
        '1' { $effectiveMode = 'Before' }
        '2' {
            if (-not $hasBefore) {
                Write-Host ''
                Write-Host '  No Before snapshot found. Take one first.' -ForegroundColor Yellow
                $effectiveMode = 'Before'
            } else {
                $effectiveMode = 'After'
            }
        }
        '3' { $effectiveMode = 'QuickDiff' }
        '4' { $effectiveMode = 'Auto' }
        '5' { $effectiveMode = 'Compare' }
        '6' { $effectiveMode = 'Cleanup' }
        '7' { $effectiveMode = 'Diagnose' }
        '8' { $effectiveMode = 'LastReport' }
        'Q' { Write-Host ''; exit 0 }
        'q' { Write-Host ''; exit 0 }
        ''  {
            # Enter with no input = do the smart thing
            if ($hasBefore) { $effectiveMode = 'After' } else { $effectiveMode = 'Before' }
            Write-Host "  (auto-selected: $effectiveMode)" -ForegroundColor DarkGray
        }
        default {
            Write-Host "  Invalid choice: $choice" -ForegroundColor Red
            exit 1
        }
    }
    Write-Host ''

    # If QuickDiff and no -Action, prompt interactively
    if ($effectiveMode -eq 'QuickDiff' -and $Action -eq '') {
        Write-Host '  Available FieldOps scripts:' -ForegroundColor Cyan

        # List runnable scripts in the same directory
        $scripts = @(Get-ChildItem -Path $scriptDir -Filter "Invoke-*.ps1" -ErrorAction SilentlyContinue |
                     Where-Object { $_.Name -ne 'Invoke-ComplianceDiff.ps1' } |
                     Sort-Object Name)
        if ($scripts.Count -gt 0) {
            $si = 1
            foreach ($s in $scripts) {
                Write-Host "    [$si] $($s.Name)" -ForegroundColor Gray
                $si++
            }
            Write-Host ''
            $actionChoice = Read-Host '  Enter number or script path'

            # Try as number first
            $actionNum = 0
            if ([int]::TryParse($actionChoice, [ref]$actionNum) -and $actionNum -ge 1 -and $actionNum -le $scripts.Count) {
                $Action = $scripts[$actionNum - 1].FullName
            } elseif ($actionChoice -ne '') {
                $Action = $actionChoice
            }
        } else {
            $Action = Read-Host '  Enter script path to run between Before/After'
        }

        if ($Action -eq '') {
            Write-Host '  No action specified.' -ForegroundColor Yellow
            exit 1
        }
        Write-Host "  Action: $Action" -ForegroundColor DarkGray
        Write-Host ''
    }
}

if ($effectiveMode -eq 'Auto') {
    if ($BeforeFile -and $AfterFile) {
        $effectiveMode = 'Compare'
    } else {
        $existingBefore = Find-BeforeSnapshot $snapshotDir $HOSTNAME $SnapshotId
        $effectiveMode  = if ($existingBefore) { 'After' } else { 'Before' }
        Write-Host "  Auto mode: $(if ($effectiveMode -eq 'Before') { 'No Before snapshot found -- taking Before snapshot.' } else { 'Before snapshot found -- taking After snapshot + running diff.' })" -ForegroundColor DarkGray
    }
}

Write-Host "  Mode       : $effectiveMode"
Write-Host "  Snapshot ID: $SnapshotId"
Write-Host ''

switch ($effectiveMode) {

    'Diagnose' {
        # v1.1.4 NEW: end-to-end environment self-test. Verifies config file
        # presence, parses fields, optionally pings the Anthropic API to
        # confirm the key is valid. One command, zero ambiguity.
        Write-Section 'CONFIGURATION DIAGNOSTICS'

        # 1. Config file
        if ($cfgFile) {
            Write-Step "Config file: FOUND -> $cfgFile" 'Green'
        } else {
            Write-Step "Config file: NOT FOUND" 'Red'
            Write-Step "  Searched: $($cfgCandidates -join ', ')" 'Yellow'
        }

        # 2. Loaded values
        Write-Host ''
        Write-Step "Loaded values:" 'Cyan'
        Write-Host "    Technician  : $techName"
        Write-Host "    Organization: $orgName"
        if ($apiKey -ne '') {
            # Length is the diagnostic that matters here -- it tells a technician
            # whether the value was truncated on paste. The prefix tells them
            # nothing they cannot get from the config file they just edited, and
            # printing it in a diagnostic dump is exactly where it gets pasted
            # into a support thread.
            Write-Host ("    API Key     : present ({0} chars)" -f $apiKey.Length)
        } else {
            Write-Host "    API Key     : (not set)"
        }

        # 3. Schema sanity
        Write-Host ''
        Write-Step "API key format check:" 'Cyan'
        if ($apiKey -eq '') {
            Write-Step "  No API key loaded -- AI analysis will be disabled" 'Yellow'
        } elseif ($apiKey -match '^sk-ant-api03-[A-Za-z0-9_\-]{50,}$') {
            Write-Step "  Format: VALID (matches sk-ant-api03-... pattern)" 'Green'
        } elseif ($apiKey.StartsWith('sk-ant-')) {
            Write-Step "  Format: PARTIAL (starts with sk-ant- but length/charset suspicious)" 'Yellow'
        } else {
            Write-Step "  Format: INVALID (does not start with sk-ant-)" 'Red'
            Write-Step "  Get a fresh key at https://console.anthropic.com -> API Keys" 'Yellow'
        }

        # 4. Live API ping, through the client
        if ($apiKey -ne '') {
            Write-Host ''
            Write-Step "Live API ping..." 'Cyan'

            if (-not $script:AIClientLoaded) {
                Write-Step "  AI client module could not be loaded -- cannot ping." 'Red'
                Write-Step "  Expected: SCRIPTS\AI\FieldOps-AIClient.psm1" 'Yellow'
            } else {
                # Pre-flight first. This names a missing key or an unreadable
                # pricing config without paying a round trip to discover it.
                $avail = Test-FieldOpsAIAvailability
                if (-not $avail.HasPricing) {
                    Write-Step "  Pricing config unreadable -- all calls would be refused." 'Red'
                    Write-Step "  Check CONFIG\AIModelPricing.json" 'Yellow'
                }
                if (-not $avail.HasApiKey) {
                    # Reachable when a key is in a file the client cannot read.
                    # Before key-resolution convergence this was the silent
                    # failure mode: banner says enabled, every call says NoApiKey.
                    Write-Step "  The client cannot resolve a key, though one was loaded above." 'Red'
                }

                # Then one real minimal call. Trying each model by hand is no
                # longer this script's job -- the client walks the fallback
                # chain itself, so a single call covers what the old per-model
                # loop did. It is audited like any other call, tagged Diagnose,
                # which also proves the audit path works on this machine.
                $ping = Invoke-FieldOpsAI -Prompt 'Reply OK' -TaskTier 'Classification' `
                            -MaxTokens 5 -CallingContext 'ComplianceDiff/Diagnose'

                if ($ping.Success) {
                    $pingCost = "{0:N4} USD" -f [double]$ping.CostUSD
                    Write-Step "  SUCCESS via $($ping.Model) ($pingCost)" 'Green'
                    Write-Step "  AI analysis is fully operational." 'Green'
                    if ($ping.AuditRecordPath) {
                        Write-Step "  Audit record written: $($ping.AuditRecordPath)" 'DarkGray'
                    }
                } elseif ($ping.HttpStatus -eq 429) {
                    # Being rate limited proves the key is good, which is what a
                    # diagnostic is actually asking. Not a configuration fault.
                    Write-Step "  Rate limited (429) -- the key is VALID. Try again shortly." 'Yellow'
                } else {
                    Write-AIFailureGuidance -Call $ping
                    Write-Host ''
                    Write-Step "  No working AI model found. Local rules will be used." 'Yellow'
                    # Escaped: unescaped `$0` and `$5` interpolated as empty
                    # variables here, so this hint used to print "cause:  credit
                    # balance" and "credits ( min)".
                    Write-Step "  Most common cause: `$0 credit balance on Evaluation plan." 'Yellow'
                    Write-Step "  Fix: https://console.anthropic.com -> Plans & Billing -> Add credits (`$5 min)" 'Yellow'
                    Write-Step "  Once credits are added, AI analysis activates automatically." 'DarkGray'
                }
            }
        }

        # 5. Filesystem layout
        Write-Host ''
        Write-Step "USB filesystem layout:" 'Cyan'
        foreach ($d in @($scriptsDir, $reportsDir, $snapshotDir, $configDir, $logsDir)) {
            $exists = Test-Path $d
            $color  = if ($exists) { 'Green' } else { 'Yellow' }
            $mark   = if ($exists) { 'OK ' } else { '!! ' }
            Write-Step "  $mark$d" $color
        }

        # 6. Existing baselines
        Write-Host ''
        Write-Step "Existing snapshots for $HOSTNAME on this USB:" 'Cyan'
        $existing = @(Get-ChildItem -Path $snapshotDir -ErrorAction SilentlyContinue |
                      Where-Object { $_.Name -match "^$HOSTNAME`_.*\.(json|json\.gz)$" -and $_.Name -notmatch '\.sha256$' } |
                      Sort-Object LastWriteTime -Descending | Select-Object -First 8)
        if ($existing.Count -eq 0) {
            Write-Step "  (none)" 'DarkGray'
        } else {
            foreach ($f in $existing) {
                $sizeMB = [math]::Round($f.Length / 1MB, 1)
                Write-Step "  $($f.Name) ($sizeMB MB, $($f.LastWriteTime.ToString('yyyy-MM-dd HH:mm')))" 'DarkGray'
            }
        }

        Write-Host ''
        Write-Host ('=' * $W) -ForegroundColor Cyan
        Write-Host '  DIAGNOSTICS COMPLETE' -ForegroundColor Green
        Write-Host ('=' * $W) -ForegroundColor Cyan
        Write-Host ''
    }

    'Before' {
        $snap  = New-Snapshot 'Before'
        $saved = Save-Snapshot $snap 'Before'

        # v1.1.4: dynamic category count from the actual snapshot data
        $catCount = 0
        if ($snap.Data) {
            if ($snap.Data -is [System.Collections.IDictionary]) {
                $catCount = @($snap.Data.Keys).Count
            } elseif ($snap.Data.PSObject.Properties) {
                $catCount = @($snap.Data.PSObject.Properties.Name).Count
            }
        }

        # Try to read the integrity hash from the sidecar we just wrote
        $hashDisplay = '(not generated)'
        $sidecar = "$saved.sha256"
        if (Test-Path $sidecar) {
            try {
                $sc = Get-Content $sidecar -Raw | ConvertFrom-Json
                if ($sc.Hash) { $hashDisplay = $sc.Hash.Substring(0,16) + '...' }
            } catch { }
        }

        Write-Host ''
        Write-Host ('=' * $W) -ForegroundColor Cyan
        Write-Host '  BEFORE SNAPSHOT SAVED' -ForegroundColor Green
        Write-Host ('=' * $W) -ForegroundColor Cyan
        Write-Host "  File       : $saved"
        Write-Host "  Sidecar    : $([IO.Path]::GetFileName($sidecar))"
        Write-Host "  SHA256     : $hashDisplay"
        Write-Host "  Categories : $catCount captured"
        Write-Host "  Next step  : Run your field actions (AutoFix, AzureADJoin, etc.)"
        Write-Host "  Then run   : .\Invoke-ComplianceDiff.ps1                       (auto-detects After)"
        Write-Host "             or .\Invoke-ComplianceDiff.ps1 -Mode After -OpenReport"
        Write-Host ('=' * $W) -ForegroundColor Cyan
    }

    'After' {
        $beforePath = if ($BeforeFile) { $BeforeFile } else { Find-BeforeSnapshot $snapshotDir $HOSTNAME $SnapshotId }
        if (-not $beforePath -or -not (Test-Path $beforePath)) {
            Write-Host '  [ERROR] No Before snapshot found. Run Before mode first.' -ForegroundColor Red
            exit 1
        }
        Write-Step "Loading Before snapshot: $([IO.Path]::GetFileName($beforePath))"
        $beforeSnap = Read-Snapshot $beforePath

        # v1.1.5 FIX: validate the loaded file is actually a snapshot, not a
        # sidecar or corrupted file. The Data property must exist and contain
        # at least the core categories (Services, Registry, etc.)
        if (-not $beforeSnap.PSObject.Properties['Data']) {
            Write-Host "  [ERROR] File is not a valid snapshot (no 'Data' property)." -ForegroundColor Red
            Write-Host "          Loaded: $([IO.Path]::GetFileName($beforePath))" -ForegroundColor Red
            Write-Host "          This may be a .sha256 sidecar file. Delete it and re-run." -ForegroundColor Yellow
            exit 1
        }
        $bCatCount = (Get-DictKeys $beforeSnap.Data).Count
        if ($bCatCount -lt 5) {
            Write-Host "  [ERROR] Snapshot has only $bCatCount categories (expected 12+). File may be corrupt." -ForegroundColor Red
            exit 1
        }
        Write-Step "Before snapshot validated: $bCatCount categories" 'DarkGray'

        # v1.1.0: inspect integrity stamp for audit trail
        $bIntegrity = Test-SnapshotIntegrity $beforeSnap
        if ($bIntegrity.HasStamp) {
            Write-Step "Before snapshot stamp: $($bIntegrity.StampedBy) @ $($bIntegrity.StampedAt) (tool v$($bIntegrity.ToolVersion))" 'DarkGray'
        } else {
            Write-Step "Before snapshot has no integrity stamp (pre-v1.1.0 format)" 'DarkGray'
        }

        $afterSnap   = New-Snapshot 'After'
        $afterSaved  = Save-Snapshot $afterSnap 'After'
        Write-Step "After snapshot saved: $([IO.Path]::GetFileName($afterSaved))"

        $allChanges  = Invoke-FullDiff $beforeSnap $afterSnap
        $aiResult    = Invoke-AIAnalysis $allChanges $beforeSnap $afterSnap

        $rbName      = "Rollback_$HOSTNAME`_$($NOW.ToString('yyyyMMdd_HHmmss')).ps1"
        $rbPath      = Join-Path $reportsDir $rbName
        $rbCount     = New-RollbackScript $allChanges $aiResult $rbPath

        $rpName  = "ComplianceDiff_$HOSTNAME`_$($NOW.ToString('yyyyMMdd_HHmmss')).html"
        $rpPath  = Join-Path $reportsDir $rpName
        $html    = New-DiffReport $beforeSnap $afterSnap $allChanges $aiResult $rbPath
        $html | Set-Content -Path $rpPath -Encoding UTF8

        # v1.1.0: CSV export for SIEM/SOAR ingestion
        $csvPath = Join-Path $reportsDir "ComplianceDiff_$HOSTNAME`_$($NOW.ToString('yyyyMMdd_HHmmss')).csv"
        $null    = Export-DiffCsv $allChanges $csvPath

        # Total risk score
        $totalRisk = 0
        foreach ($ch in $allChanges) {
            if ($ch.PSObject.Properties['RiskScore']) { $totalRisk += [int]$ch.RiskScore }
        }

        Write-Host ''
        Write-Host ('=' * $W) -ForegroundColor Cyan
        Write-Host '  COMPLIANCE DIFF COMPLETE' -ForegroundColor Green
        Write-Host ('=' * $W) -ForegroundColor Cyan
        Write-Host "  Changes detected  : $(@($allChanges).Count)"
        Write-Host "  Improvements      : $(@($allChanges | Where-Object { $_.LocalClass -eq 'Improvement' }).Count)" -ForegroundColor Green
        Write-Host "  Regressions       : $(@($allChanges | Where-Object { $_.LocalClass -eq 'Regression' }).Count)"  -ForegroundColor Red
        Write-Host "  Suspicious        : $(@($allChanges | Where-Object { $_.LocalClass -eq 'Suspicious' }).Count)"  -ForegroundColor Yellow
        Write-Host "  Total Risk Score  : $totalRisk" -ForegroundColor $(if ($totalRisk -gt 50) { 'Red' } elseif ($totalRisk -gt 0) { 'Yellow' } elseif ($totalRisk -lt 0) { 'Green' } else { 'Gray' })
        Write-Host "  Rollback commands : $rbCount"
        Write-Host "  AI Analysis       : $(if ($aiResult) { 'COMPLETE (' + $AI_MODEL + ')' } else { 'LOCAL RULES' })"
        Write-Host "  HTML Report       : $rpPath"
        Write-Host "  CSV Export        : $csvPath"
        Write-Host "  Rollback Script   : $rbPath"
        Write-Host ('=' * $W) -ForegroundColor Cyan
        Write-Host "  Start-Process ""$rpPath"""

        if ($OpenReport) { Start-Process $rpPath }
    }

    'Compare' {
        if (-not (Test-Path $BeforeFile)) { Write-Host "  [ERROR] Before file not found: $BeforeFile" -ForegroundColor Red; exit 1 }
        if (-not (Test-Path $AfterFile))  { Write-Host "  [ERROR] After file not found: $AfterFile"   -ForegroundColor Red; exit 1 }

        Write-Step "Loading Before: $([IO.Path]::GetFileName($BeforeFile))"
        Write-Step "Loading After : $([IO.Path]::GetFileName($AfterFile))"
        $beforeSnap = Read-Snapshot $BeforeFile
        $afterSnap  = Read-Snapshot $AfterFile

        # Validate both are real snapshots
        foreach ($pair in @(@{Name='Before';Snap=$beforeSnap}, @{Name='After';Snap=$afterSnap})) {
            if (-not $pair.Snap.PSObject.Properties['Data']) {
                Write-Host "  [ERROR] $($pair.Name) file is not a valid snapshot (no 'Data' property)." -ForegroundColor Red
                exit 1
            }
        }

        # v1.1.0: display integrity stamp audit trail
        $bIntegrity = Test-SnapshotIntegrity $beforeSnap
        $aIntegrity = Test-SnapshotIntegrity $afterSnap
        if ($bIntegrity.HasStamp) { Write-Step "Before stamp: $($bIntegrity.StampedBy) @ $($bIntegrity.StampedAt)" 'DarkGray' }
        if ($aIntegrity.HasStamp) { Write-Step "After  stamp: $($aIntegrity.StampedBy) @ $($aIntegrity.StampedAt)" 'DarkGray' }

        $allChanges = Invoke-FullDiff $beforeSnap $afterSnap
        $aiResult   = Invoke-AIAnalysis $allChanges $beforeSnap $afterSnap

        $rbPath     = Join-Path $reportsDir "Rollback_$HOSTNAME`_$($NOW.ToString('yyyyMMdd_HHmmss')).ps1"
        $rbCount    = New-RollbackScript $allChanges $aiResult $rbPath

        $rpPath     = Join-Path $reportsDir "ComplianceDiff_$HOSTNAME`_$($NOW.ToString('yyyyMMdd_HHmmss')).html"
        $html       = New-DiffReport $beforeSnap $afterSnap $allChanges $aiResult $rbPath
        $html | Set-Content -Path $rpPath -Encoding UTF8

        $csvPath = Join-Path $reportsDir "ComplianceDiff_$HOSTNAME`_$($NOW.ToString('yyyyMMdd_HHmmss')).csv"
        $null    = Export-DiffCsv $allChanges $csvPath

        Write-Host ''
        Write-Host ('=' * $W) -ForegroundColor Cyan
        Write-Host '  COMPARE COMPLETE' -ForegroundColor Green
        Write-Host ('=' * $W) -ForegroundColor Cyan
        Write-Host "  Total changes : $(@($allChanges).Count)"
        Write-Host "  HTML Report   : $rpPath"
        Write-Host "  CSV Export    : $csvPath"
        if ($OpenReport) { Start-Process $rpPath }
    }

    # ==============================================================
    # v1.2 NEW MODES
    # ==============================================================

    'QuickDiff' {
        # All-in-one: Before -> run action script -> After -> diff -> report
        if ($Action -eq '') {
            Write-Host '  [ERROR] QuickDiff requires -Action parameter.' -ForegroundColor Red
            Write-Host '  Example: .\Invoke-ComplianceDiff.ps1 -Mode QuickDiff -Action ".\Invoke-AutoFix.ps1"' -ForegroundColor Yellow
            exit 1
        }

        # Resolve the action script path
        $actionPath = $Action
        if (-not [IO.Path]::IsPathRooted($actionPath)) {
            $actionPath = Join-Path (Get-Location).Path $actionPath
        }
        if (-not (Test-Path $actionPath)) {
            Write-Host "  [ERROR] Action script not found: $actionPath" -ForegroundColor Red
            exit 1
        }

        Write-Section 'QUICKDIFF: PHASE 1 - BEFORE SNAPSHOT'
        $beforeSnap = New-Snapshot 'Before'
        $beforeSaved = Save-Snapshot $beforeSnap 'Before'
        Write-Step "Before saved: $([IO.Path]::GetFileName($beforeSaved))" 'Green'

        Write-Section "QUICKDIFF: PHASE 2 - EXECUTING ACTION"
        Write-Step "Running: $Action" 'Cyan'
        Write-Host ''
        $actionSw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            & $actionPath
        } catch {
            Write-Host ''
            Write-Step "[WARN] Action script threw an error: $_" 'Yellow'
            Write-Step "Continuing with After snapshot anyway..." 'DarkGray'
        }
        $actionSw.Stop()
        Write-Host ''
        Write-Step "Action completed in $([math]::Round($actionSw.Elapsed.TotalSeconds,1))s" 'Green'

        Write-Section 'QUICKDIFF: PHASE 3 - AFTER SNAPSHOT + DIFF'
        $afterSnap  = New-Snapshot 'After'
        $afterSaved = Save-Snapshot $afterSnap 'After'
        Write-Step "After saved: $([IO.Path]::GetFileName($afterSaved))" 'Green'

        $allChanges = Invoke-FullDiff $beforeSnap $afterSnap
        $aiResult   = Invoke-AIAnalysis $allChanges $beforeSnap $afterSnap

        $rbPath  = Join-Path $reportsDir "Rollback_$HOSTNAME`_$($NOW.ToString('yyyyMMdd_HHmmss')).ps1"
        $rbCount = New-RollbackScript $allChanges $aiResult $rbPath

        $rpPath  = Join-Path $reportsDir "ComplianceDiff_$HOSTNAME`_$($NOW.ToString('yyyyMMdd_HHmmss')).html"
        $html    = New-DiffReport $beforeSnap $afterSnap $allChanges $aiResult $rbPath
        $html | Set-Content -Path $rpPath -Encoding UTF8

        $csvPath = Join-Path $reportsDir "ComplianceDiff_$HOSTNAME`_$($NOW.ToString('yyyyMMdd_HHmmss')).csv"
        $null    = Export-DiffCsv $allChanges $csvPath

        $totalRisk = 0
        foreach ($ch in $allChanges) {
            if ($ch.PSObject.Properties['RiskScore']) { $totalRisk += [int]$ch.RiskScore }
        }

        Write-Host ''
        Write-Host ('=' * $W) -ForegroundColor Cyan
        Write-Host '  QUICKDIFF COMPLETE' -ForegroundColor Green
        Write-Host ('=' * $W) -ForegroundColor Cyan
        Write-Host "  Action executed  : $Action"
        Write-Host "  Action duration  : $([math]::Round($actionSw.Elapsed.TotalSeconds,1))s"
        Write-Host "  Changes detected : $(@($allChanges).Count)"
        Write-Host "  Improvements     : $(@($allChanges | Where-Object { $_.LocalClass -eq 'Improvement' }).Count)" -ForegroundColor Green
        Write-Host "  Regressions      : $(@($allChanges | Where-Object { $_.LocalClass -eq 'Regression' }).Count)"  -ForegroundColor Red
        Write-Host "  Suspicious       : $(@($allChanges | Where-Object { $_.LocalClass -eq 'Suspicious' }).Count)"  -ForegroundColor Yellow
        Write-Host "  Total Risk Score : $totalRisk" -ForegroundColor $(if ($totalRisk -gt 50) { 'Red' } elseif ($totalRisk -gt 0) { 'Yellow' } elseif ($totalRisk -lt 0) { 'Green' } else { 'Gray' })
        Write-Host "  HTML Report      : $rpPath"
        Write-Host "  CSV Export       : $csvPath"
        Write-Host "  Rollback Script  : $rbPath"
        Write-Host ('=' * $W) -ForegroundColor Cyan

        if ($OpenReport) { Start-Process $rpPath }
    }

    'Cleanup' {
        Write-Section 'SNAPSHOT CLEANUP'

        $allSnaps = @(Get-ChildItem -Path $snapshotDir -ErrorAction SilentlyContinue |
                      Where-Object { $_.Name -match '\.(json|json\.gz)$' -and $_.Name -notmatch '\.sha256$' } |
                      Sort-Object LastWriteTime -Descending)

        $sidecars = @(Get-ChildItem -Path $snapshotDir -Filter "*.sha256" -ErrorAction SilentlyContinue)

        $totalSize = ($allSnaps | Measure-Object -Property Length -Sum).Sum
        $totalMB   = [math]::Round($totalSize / 1MB, 1)

        Write-Step "Snapshot directory: $snapshotDir" 'Cyan'
        Write-Step "Total snapshots: $($allSnaps.Count) ($totalMB MB)" 'Cyan'
        Write-Step "Sidecar files: $($sidecars.Count)" 'DarkGray'
        Write-Host ''

        # Group by hostname
        $byHost = @{}
        foreach ($f in $allSnaps) {
            $hname = ($f.Name -split '_')[0]
            if (-not $byHost.ContainsKey($hname)) { $byHost[$hname] = @() }
            $byHost[$hname] += $f
        }

        $toDelete   = [System.Collections.Generic.List[IO.FileInfo]]::new()
        $toDeleteSC = [System.Collections.Generic.List[IO.FileInfo]]::new()

        foreach ($hname in $byHost.Keys) {
            $hostSnaps = @($byHost[$hname] | Sort-Object LastWriteTime -Descending)
            Write-Step "$hname : $($hostSnaps.Count) snapshot(s)" 'Cyan'

            if ($hostSnaps.Count -gt $KeepSnapshots) {
                $extras = @($hostSnaps | Select-Object -Skip $KeepSnapshots)
                foreach ($e in $extras) {
                    $null = $toDelete.Add($e)
                    $sizeMB = [math]::Round($e.Length / 1MB, 1)
                    Write-Step "  DELETE: $($e.Name) ($sizeMB MB)" 'Yellow'
                    # Find matching sidecar
                    $sc = $sidecars | Where-Object { $_.Name -eq "$($e.Name).sha256" }
                    if ($sc) { $null = $toDeleteSC.Add($sc) }
                }
                $kept = @($hostSnaps | Select-Object -First $KeepSnapshots)
                foreach ($k in $kept) {
                    Write-Step "  KEEP  : $($k.Name)" 'DarkGray'
                }
            } else {
                foreach ($k in $hostSnaps) {
                    Write-Step "  KEEP  : $($k.Name)" 'DarkGray'
                }
            }
        }

        if ($toDelete.Count -eq 0) {
            Write-Host ''
            Write-Step "Nothing to clean up. All hosts have $KeepSnapshots or fewer snapshots." 'Green'
        } else {
            $delMB = [math]::Round(($toDelete | Measure-Object -Property Length -Sum).Sum / 1MB, 1)
            Write-Host ''
            Write-Step "Will delete $($toDelete.Count) snapshot(s) + $($toDeleteSC.Count) sidecar(s) = $delMB MB" 'Yellow'
            $confirm = Read-Host "  Proceed? (Y/N)"
            if ($confirm -match '^[Yy]') {
                foreach ($f in $toDelete) {
                    try { Remove-Item $f.FullName -Force } catch { }
                }
                foreach ($f in $toDeleteSC) {
                    try { Remove-Item $f.FullName -Force } catch { }
                }
                Write-Step "Deleted $($toDelete.Count) snapshot(s) and $($toDeleteSC.Count) sidecar(s)." 'Green'
            } else {
                Write-Step "Cleanup cancelled." 'DarkGray'
            }
        }

        Write-Host ''
        Write-Host ('=' * $W) -ForegroundColor Cyan
        Write-Host '  CLEANUP COMPLETE' -ForegroundColor Green
        Write-Host ('=' * $W) -ForegroundColor Cyan
    }

    'LastReport' {
        $reports = @(Get-ChildItem -Path $reportsDir -Filter "ComplianceDiff_*.html" -ErrorAction SilentlyContinue |
                     Sort-Object LastWriteTime -Descending)
        if ($reports.Count -eq 0) {
            Write-Host '  No compliance diff reports found.' -ForegroundColor Yellow
            Write-Host "  Run a Before + After cycle first to generate a report." -ForegroundColor DarkGray
        } else {
            $latest = $reports[0]
            Write-Host "  Opening latest report: $($latest.Name)" -ForegroundColor Cyan
            Write-Host "  Generated: $($latest.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor DarkGray
            Write-Host "  Size: $([math]::Round($latest.Length / 1KB, 1)) KB" -ForegroundColor DarkGray
            Start-Process $latest.FullName

            if ($reports.Count -gt 1) {
                Write-Host ''
                Write-Host '  Recent reports:' -ForegroundColor DarkGray
                foreach ($r in ($reports | Select-Object -First 5)) {
                    $sizKB = [math]::Round($r.Length / 1KB, 1)
                    Write-Host "    $($r.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))  $($r.Name)  ($sizKB KB)" -ForegroundColor DarkGray
                }
            }
        }
    }
}
