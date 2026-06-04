#Requires -Version 5.1
<#
    FieldOps Pro - Chapter 6.6 Continuous Validation
    Unit tests for SCRIPTS\Core\Logger.psm1

    Coverage:
        Write-Log  -- event recording, level validation, output
        Start-Log  -- module name stored, SESSION_START event written
        Stop-Log   -- SESSION_END event written
        Close-Log  -- alias for Stop-Log

    Strategy: import module in each Context, use InModuleScope to inspect
    $script:Session state without exposing internal variables publicly.
    File I/O is suppressed by directing Path to $env:TEMP.
#>

BeforeAll {
    $testsRoot  = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $repoRoot   = Split-Path $testsRoot -Parent
    $loggerPath = Join-Path $repoRoot 'SCRIPTS\Core\Logger.psm1'

    if (-not (Test-Path $loggerPath)) {
        throw "Logger.psm1 not found at: $loggerPath"
    }

    $script:LoggerPath = $loggerPath
}

AfterAll {
    Remove-Module 'Logger' -Force -ErrorAction SilentlyContinue
}

Describe 'Write-Log' -Tag 'Fast' {
    BeforeEach {
        Import-Module $script:LoggerPath -Force -DisableNameChecking
    }

    AfterEach {
        Remove-Module 'Logger' -Force -ErrorAction SilentlyContinue
    }

    It 'does not throw on valid INFO entry' {
        { Write-Log -LogEvent 'TEST_EVENT' -Detail 'test detail' -Level 'INFO' } |
            Should -Not -Throw
    }

    It 'does not throw on valid OK entry' {
        { Write-Log -LogEvent 'TEST_OK' -Detail 'success' -Level 'OK' } |
            Should -Not -Throw
    }

    It 'does not throw on valid WARN entry' {
        { Write-Log -LogEvent 'TEST_WARN' -Detail 'warning text' -Level 'WARN' } |
            Should -Not -Throw
    }

    It 'does not throw on valid ERROR entry' {
        { Write-Log -LogEvent 'TEST_ERROR' -Detail 'error text' -Level 'ERROR' } |
            Should -Not -Throw
    }

    It 'records the event in the session events list' {
        Write-Log -LogEvent 'UNIT_TEST' -Detail 'recorded' -Level 'INFO'
        InModuleScope Logger {
            $script:Session.Events | Where-Object { $_.LogEvent -eq 'UNIT_TEST' } |
                Should -Not -BeNullOrEmpty
        }
    }

    It 'records the correct level' {
        Write-Log -LogEvent 'LEVEL_CHECK' -Detail 'checking level' -Level 'WARN'
        InModuleScope Logger {
            $entry = $script:Session.Events | Where-Object { $_.LogEvent -eq 'LEVEL_CHECK' }
            $entry.Level | Should -Be 'WARN'
        }
    }

    It 'records the correct detail' {
        Write-Log -LogEvent 'DETAIL_CHECK' -Detail 'my detail string' -Level 'INFO'
        InModuleScope Logger {
            $entry = $script:Session.Events | Where-Object { $_.LogEvent -eq 'DETAIL_CHECK' }
            $entry.Detail | Should -Be 'my detail string'
        }
    }

    It 'defaults to INFO level when Level is not specified' {
        Write-Log -LogEvent 'DEFAULT_LEVEL' -Detail 'no level param'
        InModuleScope Logger {
            $entry = $script:Session.Events | Where-Object { $_.LogEvent -eq 'DEFAULT_LEVEL' }
            $entry.Level | Should -Be 'INFO'
        }
    }

    It 'records a Timestamp on every entry' {
        Write-Log -LogEvent 'TIMESTAMP_CHECK' -Detail 'ts'
        InModuleScope Logger {
            $entry = $script:Session.Events | Where-Object { $_.LogEvent -eq 'TIMESTAMP_CHECK' }
            $entry.Timestamp | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'Start-Log' -Tag 'Fast' {
    BeforeEach {
        Import-Module $script:LoggerPath -Force -DisableNameChecking
    }

    AfterEach {
        Remove-Module 'Logger' -Force -ErrorAction SilentlyContinue
    }

    It 'does not throw' {
        { Start-Log -Module 'UnitTest' } | Should -Not -Throw
    }

    It 'stores the module name in the session' {
        Start-Log -Module 'TestModule'
        InModuleScope Logger {
            $script:Session.Module | Should -Be 'TestModule'
        }
    }

    It 'writes a SESSION_START event' {
        Start-Log -Module 'StartTest'
        InModuleScope Logger {
            $start = $script:Session.Events | Where-Object { $_.LogEvent -eq 'SESSION_START' }
            $start | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'Initialize-Log (alias)' -Tag 'Fast' {
    BeforeEach {
        Import-Module $script:LoggerPath -Force -DisableNameChecking
    }

    AfterEach {
        Remove-Module 'Logger' -Force -ErrorAction SilentlyContinue
    }

    It 'does not throw' {
        { Initialize-Log -Module 'AliasTest' } | Should -Not -Throw
    }

    It 'stores module name (same as Start-Log)' {
        Initialize-Log -Module 'AliasModule'
        InModuleScope Logger {
            $script:Session.Module | Should -Be 'AliasModule'
        }
    }
}

Describe 'Stop-Log' -Tag 'Fast' {
    BeforeEach {
        Import-Module $script:LoggerPath -Force -DisableNameChecking
    }

    AfterEach {
        Remove-Module 'Logger' -Force -ErrorAction SilentlyContinue
    }

    It 'does not throw' {
        { Stop-Log } | Should -Not -Throw
    }

    It 'writes a SESSION_END event' {
        Stop-Log -Result 'COMPLETED'
        InModuleScope Logger {
            $end = $script:Session.Events | Where-Object { $_.LogEvent -eq 'SESSION_END' }
            $end | Should -Not -BeNullOrEmpty
        }
    }

    It 'includes the result in the SESSION_END detail' {
        Stop-Log -Result 'FAILED'
        InModuleScope Logger {
            $end = $script:Session.Events | Where-Object { $_.LogEvent -eq 'SESSION_END' }
            $end.Detail | Should -Match 'FAILED'
        }
    }
}

Describe 'Close-Log (alias)' -Tag 'Fast' {
    BeforeEach {
        Import-Module $script:LoggerPath -Force -DisableNameChecking
    }

    AfterEach {
        Remove-Module 'Logger' -Force -ErrorAction SilentlyContinue
    }

    It 'does not throw' {
        { Close-Log } | Should -Not -Throw
    }

    It 'writes a SESSION_END event (same as Stop-Log)' {
        Close-Log -Result 'COMPLETED'
        InModuleScope Logger {
            $end = $script:Session.Events | Where-Object { $_.LogEvent -eq 'SESSION_END' }
            $end | Should -Not -BeNullOrEmpty
        }
    }
}
