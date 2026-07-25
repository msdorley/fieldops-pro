#Requires -Version 5.1
<#
    FieldOps Pro - Phase 6, Stream 6.5 (D10 + D16)

    Severity classifier accuracy (6.5-SC-5).

    WHAT MAKES THIS TEST MEANINGFUL

    SC-5 requires <= 10% misclassification on >= 10 labeled fixtures. A fixture
    set of only easy cases would pass while proving nothing, so this corpus is
    hard on purpose:

      - CRITICAL findings phrased calmly, no alarm words
      - ADVISORY findings that contain frightening vocabulary
      - both languages, since AI narration follows the report language
      - the structural-override case and the distress-marker case

    Two assertions, not one. Aggregate accuracy is the SC-5 number, but it can
    hide the one error that endangers a customer: a CRITICAL finding scored
    lower. A second assertion checks that no CRITICAL fixture was classified
    below CRITICAL WITHOUT being flagged for review. A flagged downgrade is
    tolerable -- a human will look. A silent one is not.

    Get-AISeverityClassification is exported, so the fixtures call it directly.
    That also sidesteps the Pester 5.x InModuleScope -Parameters scoping trap.
#>

BeforeAll {
    $script:TestsRoot  = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:RepoRoot   = Split-Path $script:TestsRoot -Parent
    $script:ModulePath = Join-Path $script:RepoRoot 'SCRIPTS\AI\FieldOps-AIClient.psm1'
    Import-Module $script:ModulePath -Force -DisableNameChecking

    $script:Fixtures = @(
        # ---- CRITICAL ----
        @{ lang='en'; expect='CRITICAL'
           text='This workstation exposes an unauthenticated remote code execution path via the legacy SMBv1 service. Immediate action is required before the machine is returned to the network.'
           note='multi-signal critical' }

        @{ lang='fr'; expect='CRITICAL'
           text='Le poste presente une execution de code a distance sans authentification via SMBv1. Une action immediate est requise.'
           note='FR multi-signal critical' }

        @{ lang='en'; expect='CRITICAL'
           text='Credential theft is possible: WDigest is storing plaintext passwords in memory, and domain admin tokens are present on this shared workstation.'
           note='critical via credential theft + domain admin, no CVE' }

        @{ lang='fr'; expect='CRITICAL'
           text='Vol d''identifiant possible : les mots de passe sont stockes en clair et un administrateur de domaine est connecte sur ce poste partage.'
           note='FR credential theft critical' }

        # ---- ACTION_REQUIRED ----
        @{ lang='en'; expect='ACTION_REQUIRED'
           text='BitLocker is disabled on the system drive. This is a known misconfiguration that must be remediated to meet the baseline, though no active exploitation is indicated.'
           note='must be remediated + misconfiguration, explicitly not critical' }

        @{ lang='fr'; expect='ACTION_REQUIRED'
           text='Le chiffrement du disque est desactive. Cette mauvaise configuration doit etre corrigee pour respecter le referentiel.'
           note='FR action required' }

        @{ lang='en'; expect='ACTION_REQUIRED'
           text='The installed OpenSSL build is outdated and unpatched. It is a known vulnerability but is not currently exposed to the network.'
           note='outdated/unpatched/known vulnerability, contained' }

        # ---- ADVISORY ----
        @{ lang='en'; expect='ADVISORY'
           text='It is recommended to review the local firewall profile and consider enabling additional hardening on outbound rules as a best practice.'
           note='recommended/consider/best practice' }

        @{ lang='fr'; expect='ADVISORY'
           text='Il est recommande d''examiner le profil du pare-feu local et d''envisager un durcissement complementaire.'
           note='FR advisory' }

        @{ lang='en'; expect='ADVISORY'
           text='The audit policy could be strengthened. Consider enabling command-line process auditing to improve visibility; monitor the change over the next review cycle.'
           note='hard: security vocabulary but only advisory signal' }

        # ---- INFORMATIONAL ----
        @{ lang='en'; expect='INFORMATIONAL'
           text='The system is compliant with the checked baseline items. No action required. All controls verified successfully.'
           note='compliant + no action required + verified' }

        @{ lang='fr'; expect='INFORMATIONAL'
           text='Le systeme est conforme aux points verifies. Aucune action requise. Controle effectue.'
           note='FR informational' }

        # ---- HARD CASES ----
        @{ lang='en'; expect='CRITICAL'
           text="Severity: CRITICAL`nThe finding text is deliberately mild, but the model stated its own severity and the structural signal must win."
           note='structural override beats mild wording' }

        @{ lang='en'; expect='ACTION_REQUIRED'
           text='The remote access configuration is exposed to the internet and must be remediated. See related advisory CVE-2026-0001 for background.'
           note='action_required with a CVE present; distress marker must not downgrade' }
    )

    function Test-FixtureSet {
        param($Fixtures)
        $results = @()
        foreach ($f in $Fixtures) {
            $c = Get-AISeverityClassification -Text $f.text
            $results += [PSCustomObject]@{
                Expect  = $f.expect
                Actual  = $c.Severity
                Review  = $c.NeedsHumanReview
                Correct = ($c.Severity -eq $f.expect)
                Note    = $f.note
            }
        }
        return $results
    }
}

AfterAll {
    Remove-Module 'FieldOps-AIClient' -Force -ErrorAction SilentlyContinue
}

Describe 'Severity classifier accuracy on labeled fixtures (6.5-SC-5)' -Tag 'Fast' {

    It 'has at least 10 labeled fixtures' {
        @($script:Fixtures).Count | Should -BeGreaterOrEqual 10
    }

    It 'covers all four severity levels' {
        $levels = @($script:Fixtures | ForEach-Object { $_.expect } | Sort-Object -Unique)
        foreach ($l in @('INFORMATIONAL','ADVISORY','ACTION_REQUIRED','CRITICAL')) {
            $levels | Should -Contain $l
        }
    }

    It 'includes fixtures in both languages' {
        $langs = @($script:Fixtures | ForEach-Object { $_.lang } | Sort-Object -Unique)
        $langs | Should -Contain 'en'
        $langs | Should -Contain 'fr'
    }

    It 'misclassifies no more than 10 percent of fixtures' {
        $results = Test-FixtureSet -Fixtures $script:Fixtures
        $total = @($results).Count
        $wrong = @($results | Where-Object { -not $_.Correct })

        if ($wrong.Count -gt 0) {
            $detail = ($wrong | ForEach-Object { "[$($_.Expect)->$($_.Actual)] $($_.Note)" }) -join ' | '
            Write-Host "  misclassified: $detail"
        }

        $rate = $wrong.Count / [double]$total
        $rate | Should -BeLessOrEqual 0.10
    }

    It 'never downgrades a CRITICAL fixture below CRITICAL without flagging review' {
        $results = Test-FixtureSet -Fixtures $script:Fixtures
        $silent = @($results | Where-Object {
            $_.Expect -eq 'CRITICAL' -and $_.Actual -ne 'CRITICAL' -and -not $_.Review
        })
        ($silent | ForEach-Object { $_.Note }) -join ' | ' | Should -Be ''
    }

    It 'classifies the structural-override fixture by the structural method' {
        $c = Get-AISeverityClassification -Text "Severity: CRITICAL`nmild body text"
        $c.Severity | Should -Be 'CRITICAL'
        $c.Method   | Should -Be 'structural'
    }
}

Describe 'Severity classifier degradation (6.5-R10)' -Tag 'Fast' {

    It 'defaults to ADVISORY and flags review when the keyword config is unreadable' {
        $bogus = Join-Path $env:TEMP ('fo-nosev-' + [guid]::NewGuid().ToString('N'))
        $c = Get-AISeverityClassification -Text 'some finding text with no structural line' -ConfigDir $bogus
        $c.Severity         | Should -Be 'ADVISORY'
        $c.NeedsHumanReview | Should -BeTrue
    }

    It 'flags review on an empty response rather than asserting a severity' {
        $c = Get-AISeverityClassification -Text ''
        $c.NeedsHumanReview | Should -BeTrue
    }
}
