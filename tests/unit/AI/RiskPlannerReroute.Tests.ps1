#Requires -Version 5.1
<#
    FieldOps Pro - Phase 6, Stream 6.5 (PR 5b-1)

    RiskPlanner three-tier fallback contract.

    Invoke-AnthropicPlanner (Tier 1) now routes through FieldOps-AIClient
    instead of a raw Invoke-RestMethod. The reroute must not change the
    orchestrator's contract: Get-FixRiskPlan chains Cache -> API -> Mock, and
    the API tier returns a plan-or-$null so the orchestrator can fall through.

    These tests lock the behaviour the reroute has to preserve. They matter
    because the failure they guard against is silent: a broken reroute would
    still return SOMETHING, just not the right tier, and only a test that
    inspects the plan's source would notice. Without the API reachable (no key
    in this environment), Tier 1 declines and the result must be a local mock
    -- the offline-safe guarantee the field deployment depends on.
#>

BeforeAll {
    $script:RepoRoot   = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
    $script:ModulePath = Join-Path $script:RepoRoot 'SCRIPTS\Core\FieldOps-RiskPlanner.psm1'
    Import-Module $script:ModulePath -Force -DisableNameChecking

    $script:Fix = @{
        Id='TEST-RP-001'; Name='Disable SMBv1'; Domain='Security'; Level='Medium'
        Impact=8; Reboot=$true; Desc='Removes the SMBv1 protocol'
        Fix='Disable-WindowsOptionalFeature -Online -FeatureName SMB1Protocol'
        Rollback='Enable-WindowsOptionalFeature -Online -FeatureName SMB1Protocol'
    }
    $script:Ctx = @{ OS='Windows 11 Pro'; Model='TestBox'; RAM='16GB' }
}

AfterAll {
    Remove-Module 'FieldOps-RiskPlanner' -Force -ErrorAction SilentlyContinue
}

Describe 'RiskPlanner three-tier fallback contract (6.5-R10)' -Tag 'Fast' {

    It 'exports the public surface unchanged by the reroute' {
        $exp = (Get-Module 'FieldOps-RiskPlanner').ExportedFunctions.Keys
        foreach ($f in @('Initialize-RiskPlanner','Get-FixRiskPlan','Show-FixRiskPlan','Get-DefaultMachineContext')) {
            $exp | Should -Contain $f
        }
    }

    It 'no longer contains a direct api.anthropic.com reference' {
        # The whole point of the reroute; also the D12 precondition.
        (Get-Content $script:ModulePath -Raw) | Should -Not -Match 'api\.anthropic\.com'
    }

    It 'falls through to the local mock when no API key is present' {
        # The offline-safe guarantee: Tier 1 is gated off without a key, so the
        # orchestrator must return a Tier 3 mock, not crash and not an API plan.
        InModuleScope 'FieldOps-RiskPlanner' -Parameters @{ Fix = $script:Fix; Ctx = $script:Ctx } {
            param($Fix, $Ctx)
            $script:ApiKey = ''
            $plan = Get-FixRiskPlan -FixRule $Fix -MachineContext $Ctx -NoCache
            $plan          | Should -Not -BeNullOrEmpty
            $plan.source   | Should -Be 'local_mock'
        }
    }

    It 'the mock plan carries the fields the report and display expect' {
        # A mock that is missing fields would crash Show-FixRiskPlan downstream.
        InModuleScope 'FieldOps-RiskPlanner' -Parameters @{ Fix = $script:Fix; Ctx = $script:Ctx } {
            param($Fix, $Ctx)
            $script:ApiKey = ''
            $plan = Get-FixRiskPlan -FixRule $Fix -MachineContext $Ctx -NoCache
            $plan.recommendation | Should -Not -BeNullOrEmpty
            $plan.what_it_does   | Should -Not -BeNullOrEmpty
        }
    }

    It 'Invoke-AnthropicPlanner returns null rather than throwing when the client is unavailable' {
        # Directly exercise the API tier's failure contract: no key -> $null,
        # which is what lets the orchestrator fall through.
        InModuleScope 'FieldOps-RiskPlanner' -Parameters @{ Fix = $script:Fix; Ctx = $script:Ctx } {
            param($Fix, $Ctx)
            $script:ApiKey = ''
            $result = Invoke-AnthropicPlanner -FixRule $Fix -MachineContext $Ctx
            $result | Should -BeNullOrEmpty
        }
    }

    It 'Show-FixRiskPlan renders a mock plan without error' {
        # End to end: a mock plan must survive display, since that is what the
        # field technician actually sees when offline.
        InModuleScope 'FieldOps-RiskPlanner' -Parameters @{ Fix = $script:Fix; Ctx = $script:Ctx } {
            param($Fix, $Ctx)
            $script:ApiKey = ''
            $plan = Get-FixRiskPlan -FixRule $Fix -MachineContext $Ctx -NoCache
            { Show-FixRiskPlan -Plan $plan -FixRule $Fix 6>$null } | Should -Not -Throw
        }
    }
}
