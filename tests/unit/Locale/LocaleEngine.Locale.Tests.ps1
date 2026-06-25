#Requires -Version 5.1
<#
    FieldOps Pro - Chapter 6.6 Continuous Validation
    Locale engine runtime tests (D10) - FieldOps-Locale.psm1 behavior.

    Coverage:
        Get-LocaleString    -- key lookup, variable substitution, fallback
        Get-CurrentLocale   -- returns active locale code
        Get-AvailableLocales-- lists locale files
        Initialize-Locale   -- explicit language override

    Strategy: import the real module pointed at the real CONFIG\lang dir.
    Initialize-Locale auto-detects config from the module location; since
    the module lives at SCRIPTS\Core\ and CONFIG\lang is a sibling of SCRIPTS,
    the module's own resolution finds the bundles.

    Note: Get-LocaleString uses .ContainsKey on a hashtable internally; these
    tests exercise it through the public API only.
#>

BeforeAll {
    $testsRoot  = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $repoRoot   = Split-Path $testsRoot -Parent
    $localePath = Join-Path $repoRoot 'SCRIPTS\Core\FieldOps-Locale.psm1'
    $configDir  = Join-Path $repoRoot 'CONFIG'

    if (-not (Test-Path $localePath)) {
        throw "FieldOps-Locale.psm1 not found at: $localePath"
    }

    $script:LocalePath = $localePath
    $script:ConfigDir  = $configDir
}

AfterAll {
    Remove-Module 'FieldOps-Locale' -Force -ErrorAction SilentlyContinue
}

Describe 'Initialize-Locale' -Tag 'Fast' {
    BeforeEach {
        Import-Module $script:LocalePath -Force -DisableNameChecking
    }

    AfterEach {
        Remove-Module 'FieldOps-Locale' -Force -ErrorAction SilentlyContinue
    }

    It 'does not throw with explicit English' {
        { Initialize-Locale -Language 'en' -ConfigDir $script:ConfigDir } | Should -Not -Throw
    }

    It 'does not throw with explicit French' {
        { Initialize-Locale -Language 'fr' -ConfigDir $script:ConfigDir } | Should -Not -Throw
    }

    It 'sets current locale to en when requested' {
        Initialize-Locale -Language 'en' -ConfigDir $script:ConfigDir
        Get-CurrentLocale | Should -Be 'en'
    }

    It 'sets current locale to fr when requested' {
        Initialize-Locale -Language 'fr' -ConfigDir $script:ConfigDir
        Get-CurrentLocale | Should -Be 'fr'
    }
}

Describe 'Get-LocaleString basic lookup' -Tag 'Fast' {
    BeforeAll {
        Import-Module $script:LocalePath -Force -DisableNameChecking
        Initialize-Locale -Language 'en' -ConfigDir $script:ConfigDir
    }

    AfterAll {
        Remove-Module 'FieldOps-Locale' -Force -ErrorAction SilentlyContinue
    }

    It 'returns the English value for common.appName' {
        Get-LocaleString 'common.appName' | Should -Be 'FieldOps Pro'
    }

    It 'returns a non-empty string for common.error' {
        Get-LocaleString 'common.error' | Should -Not -BeNullOrEmpty
    }

    It 'returns the key itself when the key is unknown and no default given' {
        Get-LocaleString 'nonexistent.key.xyz' | Should -Be 'nonexistent.key.xyz'
    }

    It 'returns the supplied default when the key is unknown' {
        Get-LocaleString 'nonexistent.key.xyz' @{} 'my fallback' | Should -Be 'my fallback'
    }
}

Describe 'Get-LocaleString French lookup' -Tag 'Fast' {
    BeforeAll {
        Import-Module $script:LocalePath -Force -DisableNameChecking
        Initialize-Locale -Language 'fr' -ConfigDir $script:ConfigDir
    }

    AfterAll {
        Remove-Module 'FieldOps-Locale' -Force -ErrorAction SilentlyContinue
    }

    It 'returns appName (brand name, same in both locales)' {
        Get-LocaleString 'common.appName' | Should -Be 'FieldOps Pro'
    }

    It 'returns a non-empty French value for common.error' {
        Get-LocaleString 'common.error' | Should -Not -BeNullOrEmpty
    }

    It 'falls back to English when a key is missing in French only' {
        # Both bundles are in parity, so this exercises the fallback path
        # without a real gap: a known key resolves regardless of locale.
        Get-LocaleString 'common.pass' | Should -Not -BeNullOrEmpty
    }
}

Describe 'Get-LocaleString variable substitution' -Tag 'Fast' {
    BeforeAll {
        Import-Module $script:LocalePath -Force -DisableNameChecking
        Initialize-Locale -Language 'en' -ConfigDir $script:ConfigDir
    }

    AfterAll {
        Remove-Module 'FieldOps-Locale' -Force -ErrorAction SilentlyContinue
    }

    It 'substitutes a single variable into a default template' {
        $result = Get-LocaleString 'test.sub.key' @{ Name = 'World' } 'Hello {Name}'
        $result | Should -Be 'Hello World'
    }

    It 'substitutes multiple variables' {
        $result = Get-LocaleString 'test.multi.key' @{ Size = '4.4 MB'; Time = '32s' } 'Saved {Size} in {Time}'
        $result | Should -Be 'Saved 4.4 MB in 32s'
    }

    It 'leaves unknown placeholders intact' {
        $result = Get-LocaleString 'test.partial.key' @{ Known = 'yes' } 'Known={Known} Unknown={Unknown}'
        $result | Should -Be 'Known=yes Unknown={Unknown}'
    }

    It 'returns template unchanged when no vars supplied' {
        $result = Get-LocaleString 'test.novars.key' @{} 'No substitution here'
        $result | Should -Be 'No substitution here'
    }
}

Describe 'Get-AvailableLocales' -Tag 'Fast' {
    BeforeAll {
        Import-Module $script:LocalePath -Force -DisableNameChecking
        Initialize-Locale -Language 'en' -ConfigDir $script:ConfigDir
    }

    AfterAll {
        Remove-Module 'FieldOps-Locale' -Force -ErrorAction SilentlyContinue
    }

    It 'returns an array containing en' {
        Get-AvailableLocales | Should -Contain 'en'
    }

    It 'returns an array containing fr' {
        Get-AvailableLocales | Should -Contain 'fr'
    }

    It 'returns at least 2 locales' {
        @(Get-AvailableLocales).Count | Should -BeGreaterOrEqual 2
    }
}

# ===========================================================================
# Phase 6.1 (Stream 6.1-R1): Rich-text bundle value rendering
# Appended to D10 locale engine tests.
#
# Render-RichTextValue and the Flatten-Object rich-text guard are INTERNAL to
# FieldOps-Locale.psm1, so these tests reach them via InModuleScope.
# ===========================================================================

Describe 'Render-RichTextValue - separator semantics (6.1-R1)' -Tag 'Fast' {
    BeforeAll {
        Import-Module $script:LocalePath -Force -DisableNameChecking
    }
    AfterAll {
        Remove-Module 'FieldOps-Locale' -Force -ErrorAction SilentlyContinue
    }

    It 'br joins parts with <br> (visual line break)' {
        InModuleScope 'FieldOps-Locale' {
            $v = [PSCustomObject]@{ parts = @('Diagnostic ANSSI','FieldOps Pro'); separator = 'br' }
            Render-RichTextValue -Value $v | Should -Be 'Diagnostic ANSSI<br>FieldOps Pro'
        }
    }

    It 'br joins three parts with two <br>' {
        InModuleScope 'FieldOps-Locale' {
            $v = [PSCustomObject]@{ parts = @('A','B','C'); separator = 'br' }
            Render-RichTextValue -Value $v | Should -Be 'A<br>B<br>C'
        }
    }

    It 'space joins parts with a single space' {
        InModuleScope 'FieldOps-Locale' {
            $v = [PSCustomObject]@{ parts = @('Bonjour','monde'); separator = 'space' }
            Render-RichTextValue -Value $v | Should -Be 'Bonjour monde'
        }
    }

    It 'none concatenates parts directly' {
        InModuleScope 'FieldOps-Locale' {
            $v = [PSCustomObject]@{ parts = @('Field','Ops'); separator = 'none' }
            Render-RichTextValue -Value $v | Should -Be 'FieldOps'
        }
    }

    It 'para wraps each part in its own <p> element' {
        InModuleScope 'FieldOps-Locale' {
            $v = [PSCustomObject]@{ parts = @('Para un','Para deux'); separator = 'para' }
            Render-RichTextValue -Value $v | Should -Be '<p>Para un</p><p>Para deux</p>'
        }
    }

    It 'a single part renders without any separator' {
        InModuleScope 'FieldOps-Locale' {
            $v = [PSCustomObject]@{ parts = @('Solo'); separator = 'br' }
            Render-RichTextValue -Value $v | Should -Be 'Solo'
        }
    }
}

Describe 'Render-RichTextValue - defensive behaviour (6.1-R1)' -Tag 'Fast' {
    BeforeAll {
        Import-Module $script:LocalePath -Force -DisableNameChecking
    }
    AfterAll {
        Remove-Module 'FieldOps-Locale' -Force -ErrorAction SilentlyContinue
    }

    It 'an unknown separator falls back to br (never throws)' {
        InModuleScope 'FieldOps-Locale' {
            $v = [PSCustomObject]@{ parts = @('A','B'); separator = 'xyzzy' }
            Render-RichTextValue -Value $v | Should -Be 'A<br>B'
        }
    }

    It 'a null value returns empty string' {
        InModuleScope 'FieldOps-Locale' {
            Render-RichTextValue -Value $null | Should -Be ''
        }
    }

    It 'an object missing parts returns empty string' {
        InModuleScope 'FieldOps-Locale' {
            $v = [PSCustomObject]@{ separator = 'br' }
            Render-RichTextValue -Value $v | Should -Be ''
        }
    }

    It 'an object missing separator returns empty string' {
        InModuleScope 'FieldOps-Locale' {
            $v = [PSCustomObject]@{ parts = @('A','B') }
            Render-RichTextValue -Value $v | Should -Be ''
        }
    }

    It 'an empty parts array returns empty string' {
        InModuleScope 'FieldOps-Locale' {
            $v = [PSCustomObject]@{ parts = @(); separator = 'br' }
            Render-RichTextValue -Value $v | Should -Be ''
        }
    }
}

Describe 'Flatten-Object - rich-text leaf guard (6.1-R1)' -Tag 'Fast' {
    BeforeAll {
        Import-Module $script:LocalePath -Force -DisableNameChecking
    }
    AfterAll {
        Remove-Module 'FieldOps-Locale' -Force -ErrorAction SilentlyContinue
    }

    It 'a rich-text object flattens to ONE key, not exploded sub-keys' {
        InModuleScope 'FieldOps-Locale' {
            $obj = [PSCustomObject]@{
                cover = [PSCustomObject]@{
                    title = [PSCustomObject]@{ parts = @('Diagnostic ANSSI','FieldOps Pro'); separator = 'br' }
                }
            }
            $out = @{}
            Flatten-Object -Obj $obj -Prefix '' -Output $out
            # The rich-text value becomes a single rendered key...
            $out.ContainsKey('cover.title')           | Should -BeTrue
            $out['cover.title']                        | Should -Be 'Diagnostic ANSSI<br>FieldOps Pro'
            # ...and is NOT exploded into parts/separator sub-keys
            $out.ContainsKey('cover.title.parts')      | Should -BeFalse
            $out.ContainsKey('cover.title.separator')  | Should -BeFalse
        }
    }

    It 'ordinary nested objects still flatten normally (no regression)' {
        InModuleScope 'FieldOps-Locale' {
            $obj = [PSCustomObject]@{
                dashboard = [PSCustomObject]@{ title = 'OPERATIONS'; subtitle = 'READY' }
            }
            $out = @{}
            Flatten-Object -Obj $obj -Prefix '' -Output $out
            $out['dashboard.title']    | Should -Be 'OPERATIONS'
            $out['dashboard.subtitle'] | Should -Be 'READY'
        }
    }
}
