#Requires -Version 5.1
<#
.SYNOPSIS
    Patches FieldOps-RiskPlanner.psm1 to read the Anthropic API key from
    Windows Credential Manager (the secure, project-standard location)
    instead of looking for it in technician.json.
.DESCRIPTION
    The shipped FieldOps-RiskPlanner.psm1 v1.0 walks technician.json looking
    for the API key under fields like 'AnthropicApiKey', 'ai.apiKey' etc.
    That was a design mistake: this project's standard is to keep the key
    out of any file that gets backed up, copied to USB, or risks landing
    in git history. The key lives in Windows Credential Manager under the
    target 'FieldOpsPro:Anthropic'.

    This patch replaces the credential-lookup section of Initialize-RiskPlanner
    with a clean three-tier strategy:
        Tier 0: Windows Credential Manager (target 'FieldOpsPro:Anthropic',
                or override from technician.json ai.credentialTarget)
        Tier 1: Environment variable ANTHROPIC_API_KEY (CI/scripted use)
        Tier 2: None — the planner falls back to the local mock plan

    The model name (claude-sonnet-4-6 by default) can still be overridden
    in technician.json via ai.model — model names are not secrets.
.NOTES
    Run from the repo root (where SCRIPTS\Core\ lives).
#>

$ErrorActionPreference = 'Stop'

$plannerPath = '.\SCRIPTS\Core\FieldOps-RiskPlanner.psm1'
if (-not (Test-Path $plannerPath)) {
    Write-Host "  [X] $plannerPath not found. Run from repo root." -ForegroundColor Red
    return
}

# Backup
$bak = "$plannerPath.credprepatch.bak"
Copy-Item $plannerPath $bak -Force
Write-Host "  [OK] Backup: $bak" -ForegroundColor Green

# Read
$content = Get-Content $plannerPath -Raw

# The OLD block we are replacing — the entire JSON-key-lookup section,
# from the comment line down to the env-var fallback. We keep the env-var
# fallback but REORDER it (Cred Mgr first, env var second) and strip the
# insecure JSON paths.
$oldBlock = @'
    # Read API key from technician.json. Walk all common field names.
    $cfgPath = Join-Path $ConfigDir 'technician.json'
    if (Test-Path $cfgPath) {
        try {
            $cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($field in @('AnthropicApiKey','ApiKey','anthropic_api_key','claudeKey')) {
                $v = $cfg.$field
                if ($v -and "$v".Trim() -ne '' -and "$v".Trim() -notmatch '^(YOUR-|<.*>$)') {
                    $script:ApiKey = "$v".Trim()
                    break
                }
            }
            # Optional model override
            foreach ($field in @('AnthropicModel','ClaudeModel','Model')) {
                $v = $cfg.$field
                if ($v -and "$v".Trim() -ne '') { $script:ApiModel = "$v".Trim(); break }
            }
            # Also walk into ai/anthropic sub-objects
            foreach ($parent in @('ai','anthropic','AI','Anthropic')) {
                $sub = $cfg.$parent
                if ($sub) {
                    if ($script:ApiKey -eq '') {
                        foreach ($field in @('apiKey','key','token')) {
                            $v = $sub.$field
                            if ($v -and "$v".Trim() -ne '') { $script:ApiKey = "$v".Trim(); break }
                        }
                    }
                    foreach ($field in @('model','modelId')) {
                        $v = $sub.$field
                        if ($v -and "$v".Trim() -ne '') { $script:ApiModel = "$v".Trim(); break }
                    }
                }
            }
        } catch {
            Write-Verbose "RiskPlanner: failed to parse technician.json: $_"
        }
    }

    # Fall back to env var if config didn't yield a key
    if ($script:ApiKey -eq '' -and $env:ANTHROPIC_API_KEY) {
        $script:ApiKey = $env:ANTHROPIC_API_KEY
    }
'@

# The NEW block — Credential Manager first, env var second.
# We preserve the model-name lookup from technician.json (not a secret).
$newBlock = @'
    # ----------------------------------------------------------------
    # Read API key. SECURITY: keys are NEVER read from JSON files.
    # Lookup priority:
    #   Tier 0: Windows Credential Manager target 'FieldOpsPro:Anthropic'
    #           (or whatever target name is configured in technician.json
    #           under ai.credentialTarget — useful for orgs with naming
    #           conventions like 'MyOrg:Claude')
    #   Tier 1: Environment variable ANTHROPIC_API_KEY (CI/scripted use)
    #   Tier 2: None -- fall back to local mock plan in Get-FixRiskPlan
    # ----------------------------------------------------------------
    $credTarget = 'FieldOpsPro:Anthropic'

    # Optional: read model name and credential-target override from
    # technician.json. Model names are not secrets and are convenient
    # to keep alongside the rest of the toolkit config.
    $cfgPath = Join-Path $ConfigDir 'technician.json'
    if (Test-Path $cfgPath) {
        try {
            $cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($parent in @('ai','anthropic','AI','Anthropic')) {
                $sub = $cfg.$parent
                if (-not $sub) { continue }
                foreach ($field in @('model','modelId','Model')) {
                    $v = $sub.$field
                    if ($v -and "$v".Trim() -ne '') { $script:ApiModel = "$v".Trim(); break }
                }
                foreach ($field in @('credentialTarget','credTarget','keyTarget')) {
                    $v = $sub.$field
                    if ($v -and "$v".Trim() -ne '') { $credTarget = "$v".Trim(); break }
                }
            }
        } catch {
            Write-Verbose "RiskPlanner: technician.json parse failed (non-fatal): $_"
        }
    }

    # Tier 0: Windows Credential Manager
    if ($script:ApiKey -eq '') {
        try {
            Import-Module CredentialManager -ErrorAction SilentlyContinue
            if (Get-Command Get-StoredCredential -ErrorAction SilentlyContinue) {
                $cred = Get-StoredCredential -Target $credTarget -ErrorAction SilentlyContinue
                if ($cred) {
                    $script:ApiKey = $cred.GetNetworkCredential().Password
                    Write-Verbose "RiskPlanner: API key loaded from Credential Manager target '$credTarget'."
                } else {
                    Write-Verbose "RiskPlanner: no credential found at target '$credTarget'."
                }
            } else {
                Write-Verbose "RiskPlanner: CredentialManager module not available -- skipping Tier 0."
            }
        } catch {
            Write-Verbose "RiskPlanner: Credential Manager lookup failed (non-fatal): $_"
        }
    }

    # Tier 1: Environment variable
    if ($script:ApiKey -eq '' -and $env:ANTHROPIC_API_KEY) {
        $script:ApiKey = $env:ANTHROPIC_API_KEY
        Write-Verbose "RiskPlanner: API key loaded from `$env:ANTHROPIC_API_KEY."
    }
'@

# Verify the old block exists exactly once
$count = ([regex]::Matches($content, [regex]::Escape($oldBlock))).Count
if ($count -ne 1) {
    Write-Host "  [X] Anchor block found $count times (expected 1)." -ForegroundColor Red
    Write-Host "      The planner module may have been edited since deploy. Aborting." -ForegroundColor Red
    return
}

# Apply
$newContent = $content.Replace($oldBlock, $newBlock)
[System.IO.File]::WriteAllText((Resolve-Path $plannerPath), $newContent, [System.Text.UTF8Encoding]::new($true))

# Verify
$check = Get-Content $plannerPath -Raw
$hasNewMarker = $check.Contains("Credential Manager target 'FieldOpsPro:Anthropic'")
$hasOldMarker = $check.Contains("Walk all common field names")
$newSize = (Get-Item $plannerPath).Length
$bakSize = (Get-Item $bak).Length

Write-Host ""
Write-Host "  [OK] Patch applied." -ForegroundColor Green
Write-Host "       Size: $bakSize -> $newSize bytes" -ForegroundColor DarkGray
Write-Host "       New 'Credential Manager' lookup present: $hasNewMarker" -ForegroundColor $(if ($hasNewMarker) {'Green'} else {'Red'})
Write-Host "       Old 'Walk all common field names' removed: $(-not $hasOldMarker)" -ForegroundColor $(if (-not $hasOldMarker) {'Green'} else {'Red'})
Write-Host ""
Write-Host "  Now re-run: .\SCRIPTS\Core\Invoke-AutoFixPlan.ps1 -DryRun -FixId SEC-012" -ForegroundColor Cyan
Write-Host "  The plan source line should now read 'AI analysis (Claude claude-sonnet-4-6)'." -ForegroundColor Cyan
