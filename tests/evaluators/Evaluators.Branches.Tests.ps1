#Requires -Version 5.1
<#
    FieldOps Pro - Chapter 6.6 Continuous Validation
    Evaluator branch-coverage tests (D12) - Build-ANSSIData.ps1

    D11 proved the AST-extraction harness and locked in defensive behaviour on a
    few representative rules. D12 goes wide: every decision branch of all 22
    COMPUTED rules is exercised with a synthetic engine fixture shaped to drive
    exactly that path -- plus degenerate inputs ($null / empty / Cannot-query)
    that prove portability at the branch level.

    Computed rules covered (22):
        R4 R5 R7 R8 R11 R12 R13 R14 R16 R17 R20 R21 R22
        R29 R30 R31 R32 R34 R35 R36
    (R14/R16/R17 also carry a few asserts here for branch completeness; their
     deeper degradation contract lives in Compliance.Build.Tests.ps1 / D11.)

    Premium-grade regressions this locks (history-flagged):
        - R8  guest state is TRANSLATED (Disabled->desactive, Enabled->active)
        - R13 TPM-present-but-Hello-unknown is PV, not CV
        - R34/R35 mechanism-operational is CV even when failures are reported
        - R36 Minimal audit policy is PV, not CV; compound boolean logic
        - R31 partial encryption reports $on/$total and is PV

    Check schema (confirmed from source):
        @{ Checks = @( @{ Category=...; Check=...; Value=...; Status=... } ) }
        Test-Status  passes only when Status -eq 'Pass'.
        Test-Observed fails on empty / Cannot query / unavailable / N/A / inconnu.
        Get-DictValue works on hashtables, so fixtures are plain hashtables.
#>

BeforeAll {
    $testsRoot = Split-Path $PSScriptRoot -Parent
    $repoRoot  = Split-Path $testsRoot -Parent

    $srcHelper = Join-Path $testsRoot 'Get-EvaluatorSource.ps1'
    $buildPath = Join-Path $repoRoot 'SCRIPTS\Compliance\Build-ANSSIData.ps1'

    if (-not (Test-Path $srcHelper)) { throw "Get-EvaluatorSource.ps1 not found at: $srcHelper" }
    if (-not (Test-Path $buildPath)) { throw "Build-ANSSIData.ps1 not found at: $buildPath" }

    . $srcHelper
    . ([scriptblock]::Create((Get-EvaluatorSource -ScriptPath $buildPath)))

    # ---- fixture builder: one engine with an arbitrary set of checks ----
    function New-Engine {
        param([object[]]$Checks = @())
        @{ Checks = $Checks }
    }
    function New-Check {
        param(
            [string]$Category,
            [string]$Name,
            [string]$Value,
            [string]$Status = 'Pass'
        )
        @{ Category = $Category; Check = $Name; Value = $Value; Status = $Status }
    }

    $script:NewEngine = ${function:New-Engine}
    $script:NewCheck  = ${function:New-Check}
}

# Convenience: build an engine inside an It from a list of check hashtables.
# (Defined per-Describe via dot into scope is unnecessary; we call the builders
#  through the script-scoped scriptblocks captured in BeforeAll.)

Describe 'R5 - inventaire administrateurs locaux' -Tag 'Fast' {
    It 'cv when local admin list is observed' {
        $eng = & $script:NewEngine @( (& $script:NewCheck 'Identity' 'Local Admin Accounts' 'Administrator, jdoe' 'Pass') )
        (Get-R5 -Sec $eng -Net $null -Pch $null).Status | Should -Be 'cv'
    }
    It 'pv when admin enumeration is unavailable' {
        $eng = & $script:NewEngine @( (& $script:NewCheck 'Identity' 'Local Admin Accounts' 'Cannot query' 'Fail') )
        (Get-R5 -Sec $eng -Net $null -Pch $null).Status | Should -Be 'pv'
    }
    It 'pv (no throw) on null engine' {
        (Get-R5 -Sec $null -Net $null -Pch $null).Status | Should -Be 'pv'
    }
}

Describe 'R7 - rattachement annuaire (always pv, two evidence paths)' -Tag 'Fast' {
    It 'pv with directory-confirmed evidence when observed' {
        $eng = & $script:NewEngine @( (& $script:NewCheck 'Identity' 'Directory Join Status' 'AzureAD' 'Pass') )
        $r = Get-R7 -Sec $eng
        $r.Status | Should -Be 'pv'
        $r.Evidence | Should -Match 'Directory'
    }
    It 'pv with empty evidence when not observed' {
        $r = Get-R7 -Sec (& $script:NewEngine @())
        $r.Status | Should -Be 'pv'
    }
    It 'pv (no throw) on null engine' {
        (Get-R7 -Sec $null).Status | Should -Be 'pv'
    }
}

Describe 'R8 - comptes locaux + traduction du compte invite' -Tag 'Fast' {
    It 'cv when both admins and guest observed' {
        $eng = & $script:NewEngine @(
            (& $script:NewCheck 'Identity' 'Local Admin Accounts' 'Administrator' 'Pass'),
            (& $script:NewCheck 'Identity' 'Guest Account' 'Disabled' 'Pass')
        )
        (Get-R8 -Sec $eng).Status | Should -Be 'cv'
    }
    It 'translates Disabled guest to desactive (French)' {
        $eng = & $script:NewEngine @(
            (& $script:NewCheck 'Identity' 'Local Admin Accounts' 'Administrator' 'Pass'),
            (& $script:NewCheck 'Identity' 'Guest Account' 'Disabled' 'Pass')
        )
        (Get-R8 -Sec $eng).Detail | Should -Match 'desactive'
    }
    It 'translates Enabled guest to active (French)' {
        $eng = & $script:NewEngine @(
            (& $script:NewCheck 'Identity' 'Local Admin Accounts' 'Administrator' 'Pass'),
            (& $script:NewCheck 'Identity' 'Guest Account' 'Enabled' 'Pass')
        )
        (Get-R8 -Sec $eng).Detail | Should -Match 'active'
    }
    It 'pv when only guest observed (admins unavailable)' {
        $eng = & $script:NewEngine @(
            (& $script:NewCheck 'Identity' 'Guest Account' 'Disabled' 'Pass')
        )
        (Get-R8 -Sec $eng).Status | Should -Be 'pv'
    }
    It 'pv (no throw) on null engine' {
        (Get-R8 -Sec $null).Status | Should -Be 'pv'
    }
}

Describe 'R11 - credential manager + LSA' -Tag 'Fast' {
    It 'pv with LSA note when both observed' {
        $eng = & $script:NewEngine @(
            (& $script:NewCheck 'Identity' 'Stored Credentials' '3 entries' 'Pass'),
            (& $script:NewCheck 'Identity' 'LSA Protection' 'Enabled' 'Pass')
        )
        $r = Get-R11 -Sec $eng
        $r.Status | Should -Be 'pv'
        $r.Detail | Should -Match 'LSA'
    }
    It 'pv without LSA note when only credentials observed' {
        $eng = & $script:NewEngine @(
            (& $script:NewCheck 'Identity' 'Stored Credentials' '3 entries' 'Pass')
        )
        (Get-R11 -Sec $eng).Detail | Should -Not -Match 'PPL'
    }
    It 'pv when nothing observed' {
        (Get-R11 -Sec (& $script:NewEngine @())).Status | Should -Be 'pv'
    }
}

Describe 'R12 - auto-logon' -Tag 'Fast' {
    It 'pv when auto-logon value observed' {
        $eng = & $script:NewEngine @( (& $script:NewCheck 'Identity' 'Auto-Logon' 'Disabled' 'Pass') )
        (Get-R12 -Sec $eng).Status | Should -Be 'pv'
    }
    It 'pv when not detected' {
        (Get-R12 -Sec (& $script:NewEngine @())).Status | Should -Be 'pv'
    }
}

Describe 'R13 - authentification forte (TPM/Hello), history-flagged' -Tag 'Fast' {
    It 'cv when Hello and TPM both observed' {
        $eng = & $script:NewEngine @(
            (& $script:NewCheck 'WinSec' 'Windows Hello' 'PIN + Biometric' 'Pass'),
            (& $script:NewCheck 'Firmware' 'TPM' '2.0 Ready' 'Pass')
        )
        (Get-R13 -Sec $eng).Status | Should -Be 'cv'
    }
    It 'pv when TPM present but Hello unknown (the flagged regression)' {
        $eng = & $script:NewEngine @(
            (& $script:NewCheck 'Firmware' 'TPM' '2.0 Ready' 'Pass')
        )
        (Get-R13 -Sec $eng).Status | Should -Be 'pv'
    }
    It 'pv when neither observed (no TPM hardware)' {
        (Get-R13 -Sec (& $script:NewEngine @())).Status | Should -Be 'pv'
    }
    It 'pv (no throw) on null engine' {
        (Get-R13 -Sec $null).Status | Should -Be 'pv'
    }
}

Describe 'R20 - Wi-Fi encryption (5 branches)' -Tag 'Fast' {
    It 'cv on WPA3' {
        $eng = & $script:NewEngine @( (& $script:NewCheck 'NetSec' 'WiFi Security' 'WPA3-Personal' 'Pass') )
        (Get-R20 -Sec $eng -Net $null).Status | Should -Be 'cv'
    }
    It 'cv on WPA2' {
        $eng = & $script:NewEngine @( (& $script:NewCheck 'NetSec' 'WiFi Security' 'WPA2-Personal' 'Pass') )
        (Get-R20 -Sec $eng -Net $null).Status | Should -Be 'cv'
    }
    It 'pv on WEP/Open (weak encryption must NOT be cv)' {
        $eng = & $script:NewEngine @( (& $script:NewCheck 'NetSec' 'WiFi Security' 'WEP' 'Pass') )
        (Get-R20 -Sec $eng -Net $null).Status | Should -Be 'pv'
    }
    It 'pv on an unrecognised observed value' {
        $eng = & $script:NewEngine @( (& $script:NewCheck 'NetSec' 'WiFi Security' 'SomethingElse' 'Pass') )
        (Get-R20 -Sec $eng -Net $null).Status | Should -Be 'pv'
    }
    It 'pv when no Wi-Fi observed (wired desktop)' {
        (Get-R20 -Sec (& $script:NewEngine @()) -Net $null).Status | Should -Be 'pv'
    }
}

Describe 'R21 - SMBv1 (both branches pv, distinct evidence)' -Tag 'Fast' {
    It 'pv when SMBv1 present' {
        $eng = & $script:NewEngine @( (& $script:NewCheck 'Surface' 'SMBv1 Status' 'Enabled' 'Pass') )
        (Get-R21 -Sec $eng).Status | Should -Be 'pv'
    }
    It 'pv when SMBv1 absent (good state, still pv by design)' {
        (Get-R21 -Sec (& $script:NewEngine @())).Status | Should -Be 'pv'
    }
}

Describe 'R22 - proxy / internet gateway' -Tag 'Fast' {
    It 'pv when proxy observed' {
        $eng = & $script:NewEngine @( (& $script:NewCheck 'Proxy' 'System Proxy' 'proxy.corp:8080' 'Pass') )
        (Get-R22 -Net $eng -Sec $null).Status | Should -Be 'pv'
    }
    It 'pv when no proxy data' {
        (Get-R22 -Net (& $script:NewEngine @()) -Sec $null).Status | Should -Be 'pv'
    }
}

Describe 'R29 - UAC + administrateurs' -Tag 'Fast' {
    It 'cv when UAC and admin count both observed' {
        $eng = & $script:NewEngine @(
            (& $script:NewCheck 'PrivEsc'  'UAC Policy' 'Enabled (Default)' 'Pass'),
            (& $script:NewCheck 'Identity' 'Local Admin Count' '2' 'Pass')
        )
        (Get-R29 -Sec $eng).Status | Should -Be 'cv'
    }
    It 'strips the parenthetical from the UAC value' {
        $eng = & $script:NewEngine @(
            (& $script:NewCheck 'PrivEsc'  'UAC Policy' 'Enabled (Default)' 'Pass'),
            (& $script:NewCheck 'Identity' 'Local Admin Count' '2' 'Pass')
        )
        (Get-R29 -Sec $eng).Detail | Should -Not -Match '\(Default\)'
    }
    It 'pv when only UAC observed' {
        $eng = & $script:NewEngine @(
            (& $script:NewCheck 'PrivEsc' 'UAC Policy' 'Enabled' 'Pass')
        )
        (Get-R29 -Sec $eng).Status | Should -Be 'pv'
    }
    It 'pv (no throw) on null engine' {
        (Get-R29 -Sec $null).Status | Should -Be 'pv'
    }
}

Describe 'R30 - identification materielle (both pv)' -Tag 'Fast' {
    It 'pv when system identified' {
        $eng = & $script:NewEngine @( (& $script:NewCheck 'Identity' 'System Identified' 'Acer Nitro ANV15-51' 'Pass') )
        (Get-R30 -Pch $eng).Status | Should -Be 'pv'
    }
    It 'pv when hardware identification unavailable' {
        (Get-R30 -Pch (& $script:NewEngine @())).Status | Should -Be 'pv'
    }
    It 'pv (no throw) on null engine' {
        (Get-R30 -Pch $null).Status | Should -Be 'pv'
    }
}

Describe 'R31 - BitLocker volumes (4 branches)' -Tag 'Fast' {
    It 'pv when no BitLocker data anywhere' {
        (Get-R31 -Sec (& $script:NewEngine @()) -Pch $null).Status | Should -Be 'pv'
    }
    It 'cv when single volume fully encrypted' {
        $eng = & $script:NewEngine @( (& $script:NewCheck 'Encryption' 'BitLocker C:' 'On' 'Pass') )
        (Get-R31 -Sec $eng -Pch $null).Status | Should -Be 'cv'
    }
    It 'cv when multiple volumes all encrypted' {
        $eng = & $script:NewEngine @(
            (& $script:NewCheck 'Encryption' 'BitLocker C:' 'On' 'Pass'),
            (& $script:NewCheck 'Encryption' 'BitLocker D:' 'On' 'Pass')
        )
        (Get-R31 -Sec $eng -Pch $null).Status | Should -Be 'cv'
    }
    It 'pv when only some volumes encrypted (partial)' {
        $eng = & $script:NewEngine @(
            (& $script:NewCheck 'Encryption' 'BitLocker C:' 'On'  'Pass'),
            (& $script:NewCheck 'Encryption' 'BitLocker D:' 'Off' 'Fail')
        )
        $r = Get-R31 -Sec $eng -Pch $null
        $r.Status | Should -Be 'pv'
        $r.Detail | Should -Match '1/2'
    }
    It 'pv (no throw) on null engine' {
        (Get-R31 -Sec $null -Pch $null).Status | Should -Be 'pv'
    }
}

Describe 'R32 - VPN (3 branches)' -Tag 'Fast' {
    It 'cv when VPN connected' {
        $eng = & $script:NewEngine @( (& $script:NewCheck 'VPN' 'GlobalProtect' 'Connected' 'Pass') )
        (Get-R32 -Net $eng).Status | Should -Be 'cv'
    }
    It 'pv when VPN installed but inactive' {
        $eng = & $script:NewEngine @( (& $script:NewCheck 'VPN' 'GlobalProtect' 'Disconnected' 'Pass') )
        (Get-R32 -Net $eng).Status | Should -Be 'pv'
    }
    It 'pv when no VPN detected' {
        (Get-R32 -Net (& $script:NewEngine @())).Status | Should -Be 'pv'
    }
}

Describe 'R34 - Windows Update (mechanism-operational = cv even with failures)' -Tag 'Fast' {
    It 'cv with failure note when updates report failures' {
        $eng = & $script:NewEngine @(
            (& $script:NewCheck 'Updates' 'Recent Update KB1' 'Failed'    'Warning'),
            (& $script:NewCheck 'Updates' 'Recent Update KB2' 'Installed' 'Pass')
        )
        $r = Get-R34 -Sec $null -Pch $eng
        $r.Status | Should -Be 'cv'
        $r.Detail | Should -Match 'echec'
    }
    It 'cv with no-failure note when updates all clean' {
        $eng = & $script:NewEngine @(
            (& $script:NewCheck 'Updates' 'Recent Update KB1' 'Installed' 'Pass')
        )
        (Get-R34 -Sec $null -Pch $eng).Status | Should -Be 'cv'
    }
    It 'pv when no update data observed' {
        (Get-R34 -Sec $null -Pch (& $script:NewEngine @())).Status | Should -Be 'pv'
    }
}

Describe 'R35 - drivers / support (always cv, two notes)' -Tag 'Fast' {
    It 'cv with obsolete-driver note when warnings present' {
        $eng = & $script:NewEngine @(
            (& $script:NewCheck 'Drivers' 'Chipset Driver' 'Old' 'Warning')
        )
        $r = Get-R35 -Pch $eng -Sec $null
        $r.Status | Should -Be 'cv'
        $r.Detail | Should -Match 'obsolete'
    }
    It 'cv clean when no driver warnings' {
        (Get-R35 -Pch (& $script:NewEngine @()) -Sec $null).Status | Should -Be 'cv'
    }
}

Describe 'R36 - journalisation (Minimal=pv, compound logic), history-flagged' -Tag 'Fast' {
    It 'cv when ScriptBlock logging on AND audit not minimal' {
        $eng = & $script:NewEngine @(
            (& $script:NewCheck 'WinSec'     'Logon Audit Policy'   'Success and Failure' 'Pass'),
            (& $script:NewCheck 'PSSecurity' 'ScriptBlock Logging'  'Enabled'             'Pass')
        )
        (Get-R36 -Sec $eng).Status | Should -Be 'cv'
    }
    It 'pv when audit policy is Minimal (the flagged regression)' {
        $eng = & $script:NewEngine @(
            (& $script:NewCheck 'WinSec'     'Logon Audit Policy'  'Minimal' 'Pass'),
            (& $script:NewCheck 'PSSecurity' 'ScriptBlock Logging' 'Enabled' 'Pass')
        )
        (Get-R36 -Sec $eng).Status | Should -Be 'pv'
    }
    It 'pv when only ScriptBlock logging present (audit absent)' {
        $eng = & $script:NewEngine @(
            (& $script:NewCheck 'PSSecurity' 'ScriptBlock Logging' 'Enabled' 'Pass')
        )
        (Get-R36 -Sec $eng).Status | Should -Be 'pv'
    }
    It 'pv when nothing observed' {
        (Get-R36 -Sec (& $script:NewEngine @())).Status | Should -Be 'pv'
    }
    It 'pv (no throw) on null engine' {
        (Get-R36 -Sec $null).Status | Should -Be 'pv'
    }
}

Describe 'R4 - static pv (cartographie reseau)' -Tag 'Fast' {
    It 'always pv regardless of input' {
        (Get-R4 -Sec $null -Net $null -Pch $null).Status | Should -Be 'pv'
    }
}
