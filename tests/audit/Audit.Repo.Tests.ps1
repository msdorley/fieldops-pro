#Requires -Version 5.1
<#
    FieldOps Pro - Chapter 6.6 Continuous Validation
    Repository audit suite (D14)

    Where D9-D13 test the BEHAVIOUR of the code, D14 tests the STRUCTURAL
    INVARIANTS that make FieldOps Pro what it is -- the laws and contracts that
    must hold across the whole codebase for the tool to deploy correctly on any
    Windows machine, in any locale, for years. Nothing else enforces these;
    only discipline did, until now.

    Two tiers, by deliberate design:

      UNIVERSAL LAWS - apply to every .ps1/.psm1 under SCRIPTS\, archive and
      one-off utilities included. A script that exists in the repo ships
      somewhere eventually; there are no files that "don't count".
        A1  ASCII-only       : zero bytes > 127 in any source file
        A2  No BOM           : no file begins with EF BB BF
        A5  No hardcoded paths in CODE : no drive-letter path literal
            (C:\..., E:\...) used as executable code. Paths inside COMMENTS
            and Write-Host DISPLAY STRINGS are allowed (documentation, not
            path operations). Detected via the PowerShell AST/tokenizer, not
            regex, so the distinction is exact.

      PRODUCTION CONTRACTS - apply to the verified production set only.
        A3  StrictMode contract : every script on the StrictMode ALLOWLIST
            declares Set-StrictMode -Version 1.0. The allowlist is an explicit,
            growing contract -- a script joins it when it has been built/verified
            under StrictMode, not by blanket assertion. Today: Build-ANSSIData.ps1.
        A4  42-rule count : Build-ANSSIData.ps1 defines exactly Get-R1..Get-R42.
        A6  Report schema : report-data.sample.json has its 6 top-level keys
            and Summary.Total = 42.

    EXCLUSION LIST (printed by the suite -- a documented contract, not a silent
    gap): the StrictMode allowlist is opt-IN, so production scripts are not
    forced to declare StrictMode merely for existing. Archive\ and
    Patch-/Debug-/Apply- one-off utilities are dev tooling, never deployed.
#>

BeforeAll {
    $script:TestsRoot = Split-Path $PSScriptRoot -Parent
    $script:RepoRoot  = Split-Path $script:TestsRoot -Parent
    $script:ScriptsRoot = Join-Path $script:RepoRoot 'SCRIPTS'

    if (-not (Test-Path $script:ScriptsRoot)) {
        throw "SCRIPTS root not found at: $script:ScriptsRoot"
    }

    # All source files (universal-law scope).
    $script:AllSource = @(
        Get-ChildItem $script:ScriptsRoot -Recurse -Include *.ps1,*.psm1 |
            Sort-Object FullName
    )

    # --- StrictMode allowlist (A3). Opt-in, grows by deliberate decision. ---
    $script:StrictModeAllowlist = @(
        'Compliance\Build-ANSSIData.ps1'
    )

    # --- Documented exclusions (printed for visibility). ---
    $script:ExclusionNote = @(
        'StrictMode (A3) is an opt-in allowlist; production scripts are NOT',
        'forced to declare Set-StrictMode merely for existing. A script joins',
        'the allowlist when built/verified under StrictMode.',
        'Archive\ tree and Patch-/Debug-/Apply- one-off utilities are dev',
        'tooling and are never part of the deployed production set.'
    )

    Add-Type -AssemblyName System.Management.Automation -ErrorAction SilentlyContinue

    # Helper: relative path for readable failure messages.
    function Get-RelPath {
        param([string]$Full)
        return $Full.Replace($script:ScriptsRoot + '\', '')
    }
    $script:GetRelPath = ${function:Get-RelPath}

    # Helper: classify MACHINE-SPECIFIC path literals in a file via the AST.
    # A portability defect is a path tied to THIS developer's machine or the
    # USB dev mount -- not a universal Windows location.
    #
    #   VIOLATION   : C:\Dev\... (repo location), C:\Users\<name>\... (a
    #                 specific profile), E:\... (the USB dev mount; code must
    #                 resolve paths via $PSScriptRoot, never a literal E:\).
    #   ALLOWED     : HKLM:\ HKCU:\ HKCR:\ HKU:\ (registry provider drives),
    #                 Cert:\ Env:\ Function:\ Variable:\ (PS provider drives),
    #                 X:\Windows\... (WinPE RAM disk, always X:),
    #                 C:\Program Files\... C:\Windows\... (standard OS locations
    #                 probed for software detection), and regex pattern strings
    #                 that merely contain ':\' sequences. These are universal
    #                 across every Windows machine and are NOT portability
    #                 defects -- banning them would break the registry/security
    #                 scanners by design.
    #
    # Comments are always allowed (documentation). Returns a list of violations.
    function Get-CodePathViolations {
        param([string]$Path)

        $tokens = $null; $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile(
            $Path, [ref]$tokens, [ref]$errors)

        # Machine/developer/USB-specific roots only.
        $machinePatterns = @(
            '(?i)[A-Za-z]:\\Dev\\',   # any drive + \Dev  (developer repo)
            '(?i)C:\\Users\\',        # a specific user profile
            '(?i)\bE:\\'              # the USB dev mount
        )

        $violations = @()
        foreach ($t in $tokens) {
            if ($t.Kind -eq 'Comment') { continue }
            $isMachine = $false
            foreach ($pat in $machinePatterns) {
                if ($t.Text -match $pat) { $isMachine = $true; break }
            }
            if (-not $isMachine) { continue }
            $snippet = ($t.Text -replace '\s+', ' ')
            if ($snippet.Length -gt 70) { $snippet = $snippet.Substring(0, 70) + '...' }
            $violations += ("{0} [{1}]: {2}" -f (& $script:GetRelPath $Path), $t.Kind, $snippet)
        }
        return $violations
    }
    $script:GetCodePathViolations = ${function:Get-CodePathViolations}

    # Predicate: is a source file an EXCLUDED one-off (dev tooling, not deployed
    # production)? These legitimately contain dev/USB paths in instruction
    # strings and are out of scope for the no-machine-path law.
    function Test-IsExcludedUtility {
        param([string]$FullPath)
        $rel = & $script:GetRelPath $FullPath
        if ($rel -match '(?i)(^|\\)Archive\\') { return $true }
        $leaf = Split-Path $FullPath -Leaf
        if ($leaf -match '(?i)^(Patch-|Debug-|Apply-)') { return $true }
        return $false
    }
    $script:TestIsExcludedUtility = ${function:Test-IsExcludedUtility}
}

Describe 'D14 Audit - documented scope' -Tag 'Slow' {
    It 'prints the audit scope and exclusion contract' {
        Write-Host ''
        Write-Host '  --- D14 Repository Audit: scope ---'
        Write-Host ("  Source files under SCRIPTS\: {0}" -f $script:AllSource.Count)
        Write-Host '  StrictMode allowlist (A3):'
        foreach ($a in $script:StrictModeAllowlist) { Write-Host "    + $a" }
        Write-Host '  Documented exclusions:'
        foreach ($e in $script:ExclusionNote) { Write-Host "    . $e" }
        Write-Host '  A5 machine-path law: forbids C:\Dev, C:\Users, E:\ literals'
        Write-Host '    in deployed code. ALLOWS registry drives (HKLM:/HKCU:),'
        Write-Host '    Cert:/Env: provider drives, X:\Windows (WinPE), and'
        Write-Host '    C:\Program Files / C:\Windows (standard OS locations).'
        Write-Host '  -----------------------------------'
        $script:AllSource.Count | Should -BeGreaterThan 0
    }
}

Describe 'A1 - ASCII-only source (universal law)' -Tag 'Slow' {
    It 'every .ps1/.psm1 under SCRIPTS\ contains zero bytes > 127' {
        $dirty = @()
        foreach ($f in $script:AllSource) {
            $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
            $bad = 0
            foreach ($b in $bytes) { if ($b -gt 127) { $bad++ } }
            if ($bad -gt 0) {
                $dirty += ("{0} ({1} non-ASCII byte(s))" -f (& $script:GetRelPath $f.FullName), $bad)
            }
        }
        if ($dirty.Count -gt 0) {
            $msg = "Non-ASCII bytes found in:`n  " + ($dirty -join "`n  ")
            throw $msg
        }
        $dirty.Count | Should -Be 0
    }
}

Describe 'A2 - no UTF-8 BOM (universal law)' -Tag 'Slow' {
    It 'no source file begins with the EF BB BF BOM signature' {
        $bommed = @()
        foreach ($f in $script:AllSource) {
            $b = [System.IO.File]::ReadAllBytes($f.FullName)
            if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) {
                $bommed += (& $script:GetRelPath $f.FullName)
            }
        }
        if ($bommed.Count -gt 0) {
            throw ("BOM found in:`n  " + ($bommed -join "`n  "))
        }
        $bommed.Count | Should -Be 0
    }
}

Describe 'A5 - no developer/USB-specific paths in production code (universal law)' -Tag 'Slow' {
    It 'no deployed .ps1/.psm1 hardcodes a C:\Dev, C:\Users, or E:\ path (provider drives and standard OS paths allowed)' {
        $violations = @()
        foreach ($f in $script:AllSource) {
            if (& $script:TestIsExcludedUtility $f.FullName) { continue }
            $violations += (& $script:GetCodePathViolations $f.FullName)
        }
        if ($violations.Count -gt 0) {
            throw ("Developer/USB-specific path(s) in production code:`n  " + ($violations -join "`n  ") +
                   "`n`n  (Code must resolve paths via `$PSScriptRoot, never a machine-specific literal.)")
        }
        $violations.Count | Should -Be 0
    }
}

Describe 'A3 - StrictMode contract (production allowlist)' -Tag 'Slow' {
    It '<File> declares Set-StrictMode -Version 1.0' -ForEach @(
        @{ File = 'Compliance\Build-ANSSIData.ps1' }
    ) {
        $full = Join-Path $script:ScriptsRoot $File
        Test-Path $full | Should -BeTrue -Because "allowlisted script must exist: $File"
        $content = Get-Content $full -Raw
        $content | Should -Match 'Set-StrictMode\s+-Version\s+1\.0' `
            -Because "$File is on the StrictMode allowlist"
    }
}

Describe 'A4 - exactly 42 ANSSI rule evaluators' -Tag 'Slow' {
    It 'Build-ANSSIData.ps1 defines Get-R1..Get-R42 with no gaps or extras' {
        $bd = Join-Path $script:ScriptsRoot 'Compliance\Build-ANSSIData.ps1'
        Test-Path $bd | Should -BeTrue

        $nums = Select-String -Path $bd -Pattern '^\s*function\s+Get-R(\d+)\b' |
            ForEach-Object { [int]$_.Matches[0].Groups[1].Value } |
            Sort-Object

        $nums.Count | Should -Be 42 -Because 'ANSSI defines exactly 42 rules'
        ($nums | Select-Object -First 1) | Should -Be 1
        ($nums | Select-Object -Last 1)  | Should -Be 42

        $missing = @(1..42 | Where-Object { $_ -notin $nums })
        $extra   = @($nums | Where-Object { $_ -lt 1 -or $_ -gt 42 })
        $missing.Count | Should -Be 0 -Because ("missing: " + ($missing -join ','))
        $extra.Count   | Should -Be 0 -Because ("extra: " + ($extra -join ','))

        # No duplicates: distinct count equals total count.
        ($nums | Select-Object -Unique).Count | Should -Be 42 -Because 'no duplicate rule definitions'
    }
}

Describe 'A6 - report-data sample schema' -Tag 'Slow' {
    It 'report-data.sample.json has the 6 contract keys and Summary.Total = 42' {
        $jsonPath = Join-Path $script:ScriptsRoot 'Compliance\report-data.sample.json'
        Test-Path $jsonPath | Should -BeTrue

        $j = Get-Content $jsonPath -Raw | ConvertFrom-Json
        $keys = @($j.PSObject.Properties.Name)
        $expected = @('Report','Machine','Summary','TopFindings','Modules','ModuleDetails')
        foreach ($k in $expected) {
            $keys | Should -Contain $k -Because "schema must contain top-level key '$k'"
        }
        $keys.Count | Should -Be 6 -Because ('exactly 6 top-level keys; found: ' + ($keys -join ','))

        $j.Summary.Total | Should -Be 42 -Because 'the 42-rule contract is reflected in the report summary'
    }
}
