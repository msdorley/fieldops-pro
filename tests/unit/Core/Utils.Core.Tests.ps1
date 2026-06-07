#Requires -Version 5.1
<#
    FieldOps Pro - Chapter 6.6 Continuous Validation
    Unit tests for SCRIPTS\Core\Utils.psm1

    Coverage:
        Test-WinPE       -- path-based detection, mockable
        Get-USBBase      -- pure path arithmetic, no mocking needed
        Invoke-WithRetry -- retry logic, scriptblock execution
        Test-AdminPrivilege -- returns bool (light smoke test only;
                              full mock requires .NET reflection shim)

    Excluded (not unit-testable without integration harness):
        Assert-Admin      -- calls exit 1
        Get-SystemSummary -- CIM dependency
        Get-RecentEvents  -- WinEvent dependency
        Wait-UserInput    -- interactive
        Pause-Script      -- interactive alias
#>

BeforeAll {
    # Resolve paths relative to this test file
    # This file lives at tests\unit\Core\Utils.Core.Tests.ps1
    $testsRoot  = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $repoRoot   = Split-Path $testsRoot -Parent
    $utilsPath  = Join-Path $repoRoot 'SCRIPTS\Core\Utils.psm1'

    if (-not (Test-Path $utilsPath)) {
        throw "Utils.psm1 not found at: $utilsPath"
    }

    Import-Module $utilsPath -Force -DisableNameChecking
}

AfterAll {
    Remove-Module 'Utils' -Force -ErrorAction SilentlyContinue
}

Describe 'Test-WinPE' -Tag 'Fast' {
    Context 'when wpeinit.exe exists at X:\' {
        BeforeEach {
            Mock Test-Path {
                param($Path)
                return ($Path -eq 'X:\Windows\System32\wpeinit.exe')
            } -ModuleName Utils
        }

        It 'returns $true when running in WinPE' {
            Test-WinPE | Should -BeTrue
        }
    }

    Context 'when wpeinit.exe does not exist' {
        BeforeEach {
            Mock Test-Path { return $false } -ModuleName Utils
        }

        It 'returns $false when not in WinPE' {
            Test-WinPE | Should -BeFalse
        }
    }
}

Describe 'Get-USBBase' -Tag 'Fast' {
    It 'returns two levels up from a given script root' {
        # Given: script at E:\SCRIPTS\Core\MyScript.ps1
        # $PSScriptRoot = E:\SCRIPTS\Core
        # Get-USBBase should return E:\
        $scriptRoot = 'E:\SCRIPTS\Core'
        $result = Get-USBBase -ScriptRoot $scriptRoot
        $result | Should -Be 'E:\'
    }

    It 'works with a deep nested path' {
        $scriptRoot = 'C:\Dev\fieldops-pro\SCRIPTS\Compliance'
        $result = Get-USBBase -ScriptRoot $scriptRoot
        $result | Should -Be 'C:\Dev\fieldops-pro'
    }

    It 'returns a non-empty string' {
        $result = Get-USBBase -ScriptRoot 'D:\SCRIPTS\Core'
        $result | Should -Not -BeNullOrEmpty
    }
}

Describe 'Invoke-WithRetry' -Tag 'Fast' {
    It 'returns $true when scriptblock succeeds on first attempt' {
        $result = Invoke-WithRetry -ScriptBlock { 'ok' } -MaxRetries 3 -DelaySeconds 0
        $result | Should -BeTrue
    }

    It 'retries and succeeds when scriptblock fails then succeeds' {
        $state = @{ Count = 0 }
        $result = Invoke-WithRetry -ScriptBlock {
            $state.Count++
            if ($state.Count -lt 2) { throw 'transient error' }
        } -MaxRetries 3 -DelaySeconds 0
        $result | Should -BeTrue
        $state.Count | Should -Be 2
    }

    It 'throws after exhausting all retries' {
        $state = @{ Count = 0 }
        {
            Invoke-WithRetry -ScriptBlock {
                $state.Count++
                throw 'always fails'
            } -MaxRetries 2 -DelaySeconds 0
        } | Should -Throw
        $state.Count | Should -Be 2
    }

    It 'calls scriptblock exactly MaxRetries times on consistent failure' {
        $state = @{ Count = 0 }
        try {
            Invoke-WithRetry -ScriptBlock { $state.Count++; throw 'fail' } -MaxRetries 3 -DelaySeconds 0
        } catch { }
        $state.Count | Should -Be 3
    }

    It 'accepts a scriptblock that returns a value' {
        $result = Invoke-WithRetry -ScriptBlock { 42 } -MaxRetries 1 -DelaySeconds 0
        $result | Should -BeTrue  # Invoke-WithRetry returns $true on success
    }
}

Describe 'Test-AdminPrivilege' -Tag 'Fast' {
    It 'returns a boolean' {
        $result = Test-AdminPrivilege
        $result | Should -BeOfType [bool]
    }

    It 'does not throw' {
        { Test-AdminPrivilege } | Should -Not -Throw
    }
}
