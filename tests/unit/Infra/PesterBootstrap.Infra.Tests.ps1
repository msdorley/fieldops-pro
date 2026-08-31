#Requires -Version 5.1
<#
    FieldOps Pro - continuous validation

    The Pester bootstrap resolves a satisfying Pester in four steps:

        1. a module already loaded in the session
        2. a module INSTALLED on the machine
        3. the offline bundle under TOOLS\PowerShellModules
        4. PSGallery

    Step 2 was broken from the day it was written and nobody noticed for months,
    because no machine in this project had a Pester >= 5.7.1 installed. Every
    local run fell through to Step 3, so Step 2 was dead code that looked alive.

    The first CI run took it. Hosted Windows runners ship Pester 5.9.0, so the
    runner found an installed module, tried to import it, and died in fifteen
    seconds without executing a single test:

        The specified module 'C:\Program Files\WindowsPowerShell\Modules\Pester\5.9.0'
        with version '5.9.0' was not loaded because no valid module file was
        found in any module directory.

    The cause was Import-Module -Name <ModuleBase> -RequiredVersion <version>.
    ModuleBase for a side-by-side install ALREADY ends in the version folder, so
    PS 5.1 appended the version a second time and looked for
    ...\Pester\5.9.0\5.9.0\Pester.psd1. The error names a missing module file,
    which reads like a broken install rather than a malformed path.

    WHY A CHILD PROCESS

    This test has to run the bootstrap, and the bootstrap imports Pester with
    -Force. Doing that inside the Pester session currently executing this file
    would re-import the test host's own framework mid-run. The child process
    isolates it: a fresh runspace, a PSModulePath containing only the staged
    module and the OS module directory, and a verdict carried back as an exit
    code and one line of output.

    WHAT IS ASSERTED

    That the module actually loaded came from the STAGED install path, not from
    the repository bundle. Step 2 now falls through to Step 3 when it cannot use
    what it found, which is the right behaviour but would let a future Step 2
    defect hide behind a working Step 3. Pinning the path closes that.
#>

BeforeAll {
    $script:TestsRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:RepoRoot  = Split-Path $script:TestsRoot -Parent
    $script:Bootstrap = Join-Path $script:TestsRoot 'Install-PesterIfMissing.ps1'
    $script:Bundle    = Join-Path $script:RepoRoot 'TOOLS\PowerShellModules\Pester\5.7.1'

    # A staged copy, laid out the way a real side-by-side install is:
    #   <root>\Pester\<version>\Pester.psd1
    # The versioned leaf is the whole point -- it is the shape that broke.
    $script:Stage  = Join-Path ([System.IO.Path]::GetTempPath()) ("fops-boot-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $script:Target = Join-Path $script:Stage 'Pester\5.7.1'

    $script:Staged = $false
    if ((Test-Path -LiteralPath $script:Bundle) -and (Test-Path -LiteralPath $script:Bootstrap)) {
        $null = New-Item -ItemType Directory -Path $script:Target -Force
        Copy-Item -Path (Join-Path $script:Bundle '*') -Destination $script:Target -Recurse -Force
        $script:Staged = Test-Path -LiteralPath (Join-Path $script:Target 'Pester.psd1')
    }

    # Only the staged root and the OS module directory. Excluding
    # C:\Program Files\WindowsPowerShell\Modules keeps the result the same on a
    # developer machine and on a runner that ships its own Pester.
    $script:ChildModulePath = '{0};{1}' -f $script:Stage, (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\Modules')

    $script:ChildScript = Join-Path $script:Stage 'run-bootstrap.ps1'
    if ($script:Staged) {
        $childBody = @"
`$ErrorActionPreference = 'Stop'
`$env:PSModulePath = '$($script:ChildModulePath)'
Remove-Module Pester -Force -ErrorAction SilentlyContinue
try {
    . '$($script:Bootstrap)'
} catch {
    Write-Host ("THREW " + `$_.Exception.Message)
    exit 2
}
`$m = @(Get-Module Pester | Sort-Object Version -Descending)[0]
if (`$null -eq `$m) { Write-Host 'NONE'; exit 3 }
Write-Host ("LOADED|" + `$m.Version + "|" + `$m.Path)
exit 0
"@
        Set-Content -LiteralPath $script:ChildScript -Value $childBody -Encoding ASCII
    }

    $script:Output   = ''
    $script:ExitCode = -1
    if ($script:Staged) {
        $script:Output = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:ChildScript 2>&1 | Out-String)
        $script:ExitCode = $LASTEXITCODE
    }
}

AfterAll {
    if ($script:Stage -and (Test-Path -LiteralPath $script:Stage)) {
        Remove-Item -LiteralPath $script:Stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'The bootstrap can import a Pester that is already installed' -Tag 'Slow' {

    It 'staged a satisfying install, so the branch under test is reachable' {
        $script:Staged | Should -BeTrue -Because 'without a staged install this file proves nothing at all'
    }

    It 'completes without throwing' {
        # Exit 2 is the pre-fix behaviour: Import-Module -RequiredVersion against
        # a ModuleBase that already ends in the version.
        $script:ExitCode | Should -Not -Be 2 -Because "the bootstrap threw: $($script:Output)"
    }

    It 'leaves a Pester module loaded' {
        $script:ExitCode | Should -Not -Be 3 -Because 'the bootstrap returned successfully but loaded nothing'
        $script:ExitCode | Should -Be 0 -Because "unexpected exit code. Output: $($script:Output)"
    }

    It 'loaded the version it found, not some other one' {
        $script:Output | Should -Match 'LOADED\|5\.7\.1\|'
    }

    It 'loaded it from the installed location rather than falling through to the bundle' {
        # The distinguishing assertion. Step 2 now degrades to Step 3 rather
        # than throwing, which is correct, but means a future Step 2 defect
        # would be masked by a working Step 3 unless the path is pinned.
        $script:Output | Should -BeLike "*$($script:Target)*" -Because 'a pass sourced from TOOLS\PowerShellModules means Step 2 was skipped, not exercised'
    }
}
