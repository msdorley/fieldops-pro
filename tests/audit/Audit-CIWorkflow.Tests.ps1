#Requires -Version 5.1
<#
    FieldOps Pro - continuous validation

    Audit: the CI workflow says what we think it says.

    WHY THIS EXISTS

    Two pull requests reached main showing "Checks 0". They were merged on an
    assertion that the suite passed -- a screenshot of a terminal on one
    developer's machine -- rather than on evidence anyone else could check.
    The workflow added alongside this file moves that evidence off the author's
    machine.

    A workflow is easy to neuter without noticing. The three edits that would
    do it, in descending order of how reasonable each looks at the time:

      - Switch `shell: powershell` to `shell: pwsh`, because PowerShell 7 is
        newer and the YAML looks more modern. The product is PS 5.1 ONLY. A
        suite green under 7 says nothing about the runtime every customer
        actually has, and 7 accepts syntax 5.1 rejects.
      - Add `continue-on-error: true` to get a red X off a branch. The job then
        reports success while the tests fail, which is worse than having no CI,
        because it manufactures the evidence rather than merely lacking it.
      - Reimplement the run inline with a bare Invoke-Pester call, to "simplify".
        Discovery order, the Pester bootstrap, and the four distinct exit codes
        then live in two places and drift apart. Run-AllTests.ps1 is the single
        entry point the hooks use too; CI must call it, not paraphrase it.

    SCOPE

    This is a text audit. PS 5.1 ships no YAML parser and the repo takes no
    dependency on one, so these are string and regex assertions over the file,
    in the same style as the other audits here. They cannot prove the workflow
    RUNS -- only GitHub can do that, and the run itself is the evidence. What
    they can prove is that nobody has quietly changed what it would run.
#>

BeforeAll {
    $script:RepoRoot     = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:WorkflowPath = Join-Path $script:RepoRoot '.github\workflows\tests.yml'
    $script:Workflow     = if (Test-Path -LiteralPath $script:WorkflowPath) {
        Get-Content -LiteralPath $script:WorkflowPath -Raw
    } else { '' }

    # Comment lines are stripped before the behavioural assertions below.
    # Without this, the long rationale comment at the top of the workflow --
    # which names `pwsh` and `continue-on-error` in order to explain why they
    # are wrong -- would trip the very checks that forbid them. A guard that
    # fires on its own explanation is a guard nobody keeps.
    $script:Directives = (
        ($script:Workflow -split "`r?`n") |
            Where-Object { $_ -notmatch '^\s*#' }
    ) -join "`n"
}

Describe 'The repository has continuous validation at all' -Tag 'Slow' {

    It 'ships a workflow' {
        Test-Path -LiteralPath $script:WorkflowPath | Should -BeTrue -Because 'without this file every merge rests on the author''s word'
    }

    It 'runs on pull requests, where a review decision is actually made' {
        $script:Directives | Should -Match 'pull_request'
    }

    It 'runs on pushes to main, so the trunk keeps its own verdict' {
        $script:Directives | Should -Match 'push:'
    }
}

Describe 'CI runs the same suite a developer runs' -Tag 'Slow' {

    It 'invokes the repository test runner' {
        $script:Directives | Should -Match 'Run-AllTests\.ps1' -Because 'CI and the hooks must share one entry point or they will disagree for uninteresting reasons'
    }

    It 'does not reimplement discovery with a bare Pester call' {
        $script:Directives | Should -Not -Match 'Invoke-Pester' -Because 'discovery order, bootstrap and exit codes belong to Run-AllTests.ps1 alone'
    }

    It 'does not skip the audit tier' {
        $script:Directives | Should -Not -Match '-SkipAudit' -Because 'the audit tests are the ones that catch repo-wide regressions, and they only run here'
    }
}

Describe 'CI runs the runtime the product actually targets' -Tag 'Slow' {

    It 'uses Windows PowerShell, not PowerShell 7' {
        $script:Directives | Should -Match 'shell:\s*powershell'
    }

    It 'never selects pwsh for any step' {
        $script:Directives | Should -Not -Match 'shell:\s*pwsh' -Because 'the product is PS 5.1 only; a pass under 7 would be evidence about a runtime no customer has'
    }

    It 'asserts the major version at run time rather than trusting the label' {
        $script:Directives | Should -Match 'PSVersion' -Because 'if GitHub ever redefines what `shell: powershell` means, this must fail loudly rather than silently test the wrong thing'
    }
}

Describe 'CI cannot report success over a failure' -Tag 'Slow' {

    It 'does not mark any step or job continue-on-error' {
        $script:Directives | Should -Not -Match 'continue-on-error' -Because 'a green job over red tests manufactures evidence instead of gathering it'
    }

    It 'propagates the runner exit code instead of discarding it' {
        $script:Directives | Should -Match '\$LASTEXITCODE' -Because 'Run-AllTests exits 2 on a bootstrap failure and 3 when it discovers no tests; neither is a pass'
    }

    It 'preserves the results file as an artifact' {
        $script:Directives | Should -Match 'upload-artifact'
        $script:Directives | Should -Match 'FieldOps-AllTests\.xml'
    }
}
