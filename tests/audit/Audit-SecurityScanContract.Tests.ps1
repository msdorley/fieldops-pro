#Requires -Version 5.1
<#
    FieldOps Pro - Phase 7, Stream 7.2

    Audit: the contract between SecurityScan and the compliance evaluators.

    WHY THIS EXISTS

    SecurityScan is 1,100 lines, supplies the evidence behind 30 of the 42 ANSSI
    rules, and until this file had no test of any kind.

    Twenty-two of those rules decide whether they have real evidence by calling
    Test-Observed, which -- before 7.2 -- inspected the free-text Value that
    SecurityScan writes and pattern-matched it for 'Cannot query'. That made the
    correctness of 22 compliance verdicts depend on one script's error prose
    continuing to be worded a particular way. Rewording a catch block from
    'Cannot query' to 'Unable to query' would have flipped those rules from
    "evidence incomplete" to "control verified" -- silently, and in the direction
    that claims more than was checked.

    Nothing was broken when this was written; every wording in the tree was
    matched. That is precisely when to nail it down.

    WHAT IS CHECKED

      - The status vocabulary is closed: every Add-Check emits a status from a
        declared set, so a typo cannot invent a fourth state.
      - A check that could not be determined says so in its STATUS, not only in
        its prose. This is the structural fix; the prose stays for old data.
      - No probe failure is reported as a security failure. The Defender catch
        block recorded Status 'Fail' with Value 'Cannot query': a machine whose
        Defender could not be queried was reported as having a Defender failure.
        Could-not-look is not the same finding as failed, and a product whose
        distinguishing claim is that it says which is which cannot ship that.
      - Undetermined checks stay out of the section score. Excluding them is
        correct -- a check that did not run should move the score neither up nor
        down -- and it was true by accident before it was true on purpose.
      - Test-Observed reads the status first and the prose second, so reports
        already written to technicians' sticks keep their meaning.

    SCOPE

    This is a source-contract audit, not a behavioural one. SecurityScan probes
    real firmware, TPM and Defender state; exercising it properly needs a Windows
    host with those present. What can be checked without one is that every call
    site obeys the contract the compliance module depends on -- which is exactly
    the class of defect found here.
#>

BeforeAll {
    $script:RepoRoot   = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:ScanPath   = Join-Path $script:RepoRoot 'SCRIPTS\Security\Invoke-SecurityScan.ps1'
    $script:BuildPath  = Join-Path $script:RepoRoot 'SCRIPTS\Compliance\Build-ANSSIData.ps1'

    $script:ScanSrc  = if (Test-Path -LiteralPath $script:ScanPath)  { Get-Content -LiteralPath $script:ScanPath  -Raw } else { '' }
    $script:BuildSrc = if (Test-Path -LiteralPath $script:BuildPath) { Get-Content -LiteralPath $script:BuildPath -Raw } else { '' }

    # The closed set. 'Undetermined' is spelled out rather than borrowing
    # 'Unknown' because the ambiguity is the thing being removed: an unknown
    # VALUE and a check that could not RUN are different statements.
    $script:AllowedStatuses = @('Pass', 'Warning', 'Fail', 'Info', 'Undetermined', 'ConstrainedLanguage')

    # Both collections are built here, into plain arrays, rather than returned
    # from helper functions.
    #
    # The first version used `, $collection` to stop PowerShell unrolling the
    # return value. That wraps: the caller received a one-element array holding
    # the collection, so Should -Contain compared the wrapper against a string
    # and -join stringified it to 'System.Collections.ArrayList'. Worse, the
    # three assertions over the other helper PASSED anyway, because $_.Status on
    # a collection triggers member enumeration and happened to give the right
    # answer -- green ticks over a broken helper.
    #
    # Assignment into $script: from BeforeAll has no return-value semantics to
    # get wrong, which matters because this file cannot be run here.

    # Every literal -Status on an Add-Check call, including the inline if/else
    # forms the script uses.
    $script:EmittedStatuses = @()
    foreach ($m in [regex]::Matches($script:ScanSrc, "-Status\s+(?:'([A-Za-z]+)'|\`$\(if\([^)]*\)\{'([A-Za-z]+)'\}else\{'([A-Za-z]+)'\}\))")) {
        foreach ($g in 1..3) {
            if ($m.Groups[$g].Success) { $script:EmittedStatuses += $m.Groups[$g].Value }
        }
    }

    # Add-Check calls whose Value says the probe could not answer, with the
    # status each one carries. One rule covers both the Info sites and the
    # Defender site that used Fail.
    $script:UndeterminedSites = @()
    $lineNo = 0
    foreach ($line in ($script:ScanSrc -split "`r?`n")) {
        $lineNo++
        if ($line -notlike '*Add-Check*') { continue }
        if ($line -match "-Value\s+'([^']*[Cc]annot query[^']*)'") {
            $value  = $Matches[1]
            $status = '(computed)'
            if ($line -match "-Status\s+'([A-Za-z]+)'") { $status = $Matches[1] }
            $script:UndeterminedSites += [PSCustomObject]@{ Line = $lineNo; Status = $status; Value = $value }
        }
    }
}

Describe 'SecurityScan emits a closed status vocabulary' -Tag 'Slow' {

    It 'ships the security engine' {
        Test-Path -LiteralPath $script:ScanPath | Should -BeTrue
    }

    It 'emits only declared statuses' {
        $script:EmittedStatuses.Count | Should -BeGreaterThan 0
        $undeclared = @($script:EmittedStatuses | Where-Object { $_ -notin $script:AllowedStatuses } | Sort-Object -Unique)
        ($undeclared -join ', ') | Should -BeNullOrEmpty -Because 'a typo must not be able to invent a fourth state'
    }

    It 'actually uses the undetermined status somewhere' {
        $script:EmittedStatuses | Should -Contain 'Undetermined' -Because 'the engine detects checks it cannot answer; it must say so structurally'
    }
}

Describe 'A probe that could not run is never reported as a failure' -Tag 'Slow' {

    It 'finds the checks that report an unanswerable probe' {
        $script:UndeterminedSites.Count | Should -BeGreaterThan 0 -Because 'the engine does encounter probes it cannot answer'
    }

    It 'gives every one of them the undetermined status' {
        $wrong  = @($script:UndeterminedSites | Where-Object { $_.Status -ne 'Undetermined' })
        $detail = ($wrong | ForEach-Object { "line $($_.Line): Status '$($_.Status)' for '$($_.Value)'" }) -join '; '
        $detail | Should -BeNullOrEmpty -Because 'could-not-look and failed are different findings'
    }

    It 'reports no unanswerable probe as Fail' {
        # The specific defect: the Defender catch block recorded a security
        # failure for a machine whose Defender simply could not be queried.
        @($script:UndeterminedSites | Where-Object { $_.Status -eq 'Fail' }).Count |
            Should -Be 0 -Because 'a machine that cannot be examined does not thereby fail'
    }
}

Describe 'Undetermined checks do not move the score' -Tag 'Slow' {

    It 'scores only checks that returned an answer' {
        # True by accident before it was true on purpose: the score filter has
        # always listed Pass/Warning/Fail. Pinning it so a later edit that adds
        # Undetermined to the filter has to argue with a test first.
        $script:ScanSrc | Should -Match "Status -in @\('Pass','Warning','Fail'\)"
    }

    It 'does not count undetermined checks as passes' {
        $script:ScanSrc | Should -Not -Match "Status -in @\([^)]*'Undetermined'[^)]*\)"
    }
}

Describe 'The compliance module reads the status, not the prose' -Tag 'Slow' {

    It 'ships the collector' {
        Test-Path -LiteralPath $script:BuildPath | Should -BeTrue
    }

    It 'treats the undetermined status as absent evidence' {
        $script:BuildSrc | Should -Match "'Undetermined'" -Because 'Test-Observed must recognise the structural signal'
    }

    It 'still recognises the old prose, for reports already on technicians sticks' {
        # Backwards compatibility is not optional here: snapshots written before
        # 7.2 carry Status 'Info' and the wording in Value. Dropping the prose
        # match would change the verdict on data already delivered to clients.
        $script:BuildSrc | Should -Match 'Cannot query\|cannot read'
    }

    It 'keeps the number of rules that depend on this above zero' {
        $uses = ([regex]::Matches($script:BuildSrc, 'Test-Observed')).Count
        $uses | Should -BeGreaterThan 1 -Because 'if nothing calls it, this contract is dead code and the audit is theatre'
    }
}
