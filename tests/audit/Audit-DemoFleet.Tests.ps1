# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Ousman Dorley. See LICENSE at the repository root.
<#
    Audit-DemoFleet.Tests.ps1 -- FieldOps Pro Phase 6, Stream 6.4 (6.4-D16)

    Demo artifacts are the most widely seen output this project produces: they
    go into screenshots, documentation and sales conversations. A demo report
    carrying a real hostname or username would leak it further than any real
    report ever does, and would contradict the "nothing leaves the machine"
    claim the product is sold on.

    THE CHECK IS AGAINST THE LIVE ENVIRONMENT, NOT A BLOCKLIST

    A blocklist only catches leaks somebody already thought of. Comparing
    generated artifacts against $env:COMPUTERNAME and $env:USERNAME as they
    are AT TEST TIME catches the case this is actually written for: a future
    contributor regenerating the fleet on their own machine and committing it
    without noticing.

    That means this test protects a different person on every machine it runs
    on, which is the only version of it worth having.
#>

BeforeAll {
    # Walk up to the repository root by looking for a file only the root has.
    # A fixed number of Split-Path calls was used first and was off by one --
    # it landed on tests\ and every path below it resolved to
    # tests\SCRIPTS\..., which does not exist. Searching for a landmark
    # survives the file being moved between test subdirectories.
    $script:RepoRoot = Split-Path -Parent $PSCommandPath
    while ($script:RepoRoot -and -not (Test-Path -LiteralPath (Join-Path $script:RepoRoot 'LICENSE'))) {
        $parent = Split-Path -Parent $script:RepoRoot
        if ($parent -eq $script:RepoRoot) { break }
        $script:RepoRoot = $parent
    }

    $script:Generator = Join-Path $script:RepoRoot 'TOOLS\New-DemoFleet.ps1'
    $script:Sample    = Join-Path $script:RepoRoot 'SCRIPTS\Compliance\report-data.sample.json'

    $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ("fodemo-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $script:WorkDir -Force | Out-Null

    if (Test-Path -LiteralPath $script:Generator) {
        & $script:Generator -Count 6 -Seed 20260601 -OutputDir $script:WorkDir *>&1 | Out-Null
    }

    $script:Artifacts = @(Get-ChildItem -LiteralPath $script:WorkDir -Filter '*.json' -ErrorAction SilentlyContinue)

    # Fail the whole container rather than let the assertions below run over an
    # empty collection. When the repo-root path was wrong, generation produced
    # nothing and every leak assertion PASSED -- "no artifact contains your
    # hostname" is trivially true when there are no artifacts. Only the
    # non-empty guard exposed it. Throwing here removes the failure mode
    # instead of relying on one test to notice it.
    if ($script:Artifacts.Count -eq 0) {
        throw ("Demo fleet generation produced nothing. RepoRoot resolved to '{0}', generator '{1}' (exists: {2}). Every assertion in this file would otherwise pass vacuously." -f `
            $script:RepoRoot, $script:Generator, (Test-Path -LiteralPath $script:Generator))
    }

    # Identity values to hunt for. Short values are excluded deliberately: a
    # two-character username would match inside unrelated words and fail the
    # suite for the wrong reason. Four characters is the point where a match
    # stops being plausible coincidence.
    $script:Identity = @(
        $env:COMPUTERNAME
        $env:USERNAME
        $env:USERDOMAIN
        $env:USERDNSDOMAIN
    ) | Where-Object { $_ -and $_.Length -ge 4 } | Select-Object -Unique
}

AfterAll {
    if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir)) {
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Demo fleet generator exists and produces output (6.4-D15)' {

    It 'ships the generator' {
        Test-Path -LiteralPath $script:Generator | Should -BeTrue
    }

    It 'produced a non-empty set of artifacts' {
        # Guard against vacuous passing: every leak assertion below iterates
        # this collection, so an empty set would make all of them pass while
        # proving nothing.
        $script:Artifacts.Count | Should -BeGreaterThan 0
    }

    It 'produced exactly the requested number of machines' {
        $script:Artifacts.Count | Should -Be 6
    }
}

Describe 'No real identity reaches a demo artifact (6.4-D16)' {

    It 'has identity values to test against' {
        # If the environment reported nothing usable, the leak tests below
        # would pass trivially. Better to fail loudly here.
        $script:Identity.Count | Should -BeGreaterThan 0
    }

    It 'no artifact contains this machine''s hostname, username or domain' {
        $hits = @()
        foreach ($file in $script:Artifacts) {
            $content = Get-Content -LiteralPath $file.FullName -Raw
            foreach ($value in $script:Identity) {
                if ($content -match [regex]::Escape($value)) {
                    $hits += ('{0} contains "{1}"' -f $file.Name, $value)
                }
            }
        }
        $hits -join '; ' | Should -BeNullOrEmpty
    }

    It 'no filename contains this machine''s hostname or username' {
        $hits = @()
        foreach ($file in $script:Artifacts) {
            foreach ($value in $script:Identity) {
                if ($file.Name -match [regex]::Escape($value)) {
                    $hits += $file.Name
                }
            }
        }
        $hits -join '; ' | Should -BeNullOrEmpty
    }

    It 'every hostname carries the DEMO- prefix' {
        foreach ($file in $script:Artifacts) {
            $data = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
            $data.Machine.Hostname | Should -BeLike 'DEMO-*'
        }
    }

    It 'every serial is synthetic' {
        foreach ($file in $script:Artifacts) {
            $data = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
            $data.Machine.Serial | Should -BeLike 'DEMOSN*'
        }
    }

    It 'no artifact names a real technician' {
        foreach ($file in $script:Artifacts) {
            $data = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
            $data.Report.Technician | Should -Match 'demonstration|Demo'
        }
    }
}

Describe 'The shipped sample carries no real identity either (6.4-D16)' {

    # The generator derives from this file, so a real name here would
    # propagate into every machine in the fleet. It also ships in the deployed
    # tree, where a customer reads it.

    It 'exists and parses' {
        Test-Path -LiteralPath $script:Sample | Should -BeTrue
        { Get-Content -LiteralPath $script:Sample -Raw | ConvertFrom-Json } | Should -Not -Throw
    }

    It 'does not name a real technician' {
        $data = Get-Content -LiteralPath $script:Sample -Raw | ConvertFrom-Json
        $data.Report.Technician | Should -Match 'demonstration|Demo'
    }

    It 'does not contain this machine''s identity' {
        $content = Get-Content -LiteralPath $script:Sample -Raw
        foreach ($value in $script:Identity) {
            $content | Should -Not -Match ([regex]::Escape($value))
        }
    }
}

Describe 'The fleet is reproducible (6.4-D15)' {

    It 'produces byte-identical output for the same seed' {
        # A demo that differs between runs cannot be screenshotted for
        # documentation, and a committed artifact that churns on every
        # regeneration makes a real change invisible in a diff.
        $second = Join-Path ([System.IO.Path]::GetTempPath()) ("fodemo2-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        try {
            & $script:Generator -Count 6 -Seed 20260601 -OutputDir $second *>&1 | Out-Null

            foreach ($file in $script:Artifacts) {
                $twin = Join-Path $second $file.Name
                Test-Path -LiteralPath $twin | Should -BeTrue

                $a = [System.IO.File]::ReadAllBytes($file.FullName)
                $b = [System.IO.File]::ReadAllBytes($twin)
                [System.Convert]::ToBase64String($a) | Should -Be ([System.Convert]::ToBase64String($b))
            }
        }
        finally {
            Remove-Item -LiteralPath $second -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'produces a different fleet for a different seed' {
        # Proves the seed is actually wired to the generator rather than the
        # output being constant regardless of it.
        $other = Join-Path ([System.IO.Path]::GetTempPath()) ("fodemo3-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        try {
            & $script:Generator -Count 6 -Seed 999 -OutputDir $other *>&1 | Out-Null

            $first  = Get-Content -LiteralPath $script:Artifacts[0].FullName -Raw
            $second = Get-Content -LiteralPath (Join-Path $other $script:Artifacts[0].Name) -Raw
            $first | Should -Not -Be $second
        }
        finally {
            Remove-Item -LiteralPath $other -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Generated data conforms to the report contract (6.4-D15)' {

    It 'every machine reports exactly 42 rules' {
        foreach ($file in $script:Artifacts) {
            $data = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
            $ruleCount = ($data.ModuleDetails | ForEach-Object { $_.Rules.Count } | Measure-Object -Sum).Sum
            $ruleCount | Should -Be 42
        }
    }

    It 'every summary sums to its total' {
        foreach ($file in $script:Artifacts) {
            $data = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
            ($data.Summary.CountCV + $data.Summary.CountPV + $data.Summary.CountHP) |
                Should -Be $data.Summary.Total
            $data.Summary.Total | Should -Be 42
        }
    }

    It 'every summary count matches the rules actually assigned' {
        # The counts are recomputed by the generator rather than adjusted
        # incrementally. This asserts that they did not drift anyway.
        foreach ($file in $script:Artifacts) {
            $data  = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
            $rules = $data.ModuleDetails | ForEach-Object { $_.Rules }

            (@($rules | Where-Object { $_.Status -eq 'cv' })).Count | Should -Be $data.Summary.CountCV
            (@($rules | Where-Object { $_.Status -eq 'pv' })).Count | Should -Be $data.Summary.CountPV
            (@($rules | Where-Object { $_.Status -eq 'hp' })).Count | Should -Be $data.Summary.CountHP
        }
    }

    It 'every rule status is a permitted value' {
        foreach ($file in $script:Artifacts) {
            $data = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
            foreach ($module in $data.ModuleDetails) {
                foreach ($rule in $module.Rules) {
                    $rule.Status | Should -BeIn @('cv', 'pv', 'hp')
                }
            }
        }
    }

    It 'no machine reports all 42 rules as verified' {
        # A demo showing a perfect score would be advertising that the tool
        # cannot tell verified from unverifiable -- which is the opposite of
        # what the product is for.
        foreach ($file in $script:Artifacts) {
            $data = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
            $data.Summary.CountCV | Should -BeLessThan 42
        }
    }
}

Describe 'Verdict and evidence do not contradict each other (6.4-D15)' {

    # The first version of the generator reassigned Status while leaving the
    # skeleton's evidence prose untouched, so a rule could report cv above a
    # Meta line describing three failed Windows updates. A demo report that
    # disagrees with itself is worse than no demo.

    It 'resets the evidence of every rule whose verdict changed' {
        # Checked against the skeleton rather than by scanning for failure
        # words. A word-scan version of this test was written first and was
        # wrong: R34 and R35 are legitimately cv alongside failure prose,
        # because R34 asks whether the update MECHANISM is operational and
        # R35 is cv by design with an obsolete-driver note. A machine with
        # three failed updates still has a working update mechanism.
        #
        # The invariant that is actually true: evidence must be reset exactly
        # where the verdict moved, and left alone everywhere else.
        $skeleton = Get-Content -LiteralPath $script:Sample -Raw | ConvertFrom-Json

        $original = @{}
        foreach ($module in $skeleton.ModuleDetails) {
            foreach ($rule in $module.Rules) {
                $original[$rule.Id] = @{ Status = $rule.Status; Meta = $rule.Meta }
            }
        }

        foreach ($file in $script:Artifacts) {
            $data = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
            foreach ($module in $data.ModuleDetails) {
                foreach ($rule in $module.Rules) {
                    $was = $original[$rule.Id]
                    if (-not $was) { continue }

                    if ($rule.Status -ne $was.Status) {
                        $rule.Meta | Should -Match 'de demonstration|demonstration machine' -Because `
                            ("{0} rule {1} moved {2}->{3} but kept the skeleton's evidence" -f `
                                $file.Name, $rule.Id, $was.Status, $rule.Status)
                    }
                    else {
                        $rule.Meta | Should -Be $was.Meta -Because `
                            ("{0} rule {1} kept its verdict but lost its evidence" -f $file.Name, $rule.Id)
                    }
                }
            }
        }
    }

    It 'every rule carries some evidence text' {
        # Resetting evidence must not leave a rule blank -- an empty row in a
        # compliance report reads as a rendering defect.
        foreach ($file in $script:Artifacts) {
            $data = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
            foreach ($module in $data.ModuleDetails) {
                foreach ($rule in $module.Rules) {
                    $rule.Meta | Should -Not -BeNullOrEmpty -Because `
                        ("{0} rule {1} has no evidence text" -f $file.Name, $rule.Id)
                }
            }
        }
    }

    It 'retains original evidence where the verdict did not change' {
        # Resetting everything would produce a fleet of identical boilerplate,
        # which shows nothing about what a real report looks like. At least
        # some rules must still carry the sample's own prose.
        $data  = Get-Content -LiteralPath $script:Artifacts[0].FullName -Raw | ConvertFrom-Json
        $rules = $data.ModuleDetails | ForEach-Object { $_.Rules }

        $boilerplate = @($rules | Where-Object { $_.Meta -match 'de demonstration' })
        $original    = @($rules | Where-Object { $_.Meta -notmatch 'de demonstration' })

        $original.Count | Should -BeGreaterThan 0
        $boilerplate.Count | Should -BeGreaterThan 0
    }
}

Describe 'The fleet demonstrates the three-state vocabulary (6.4-D15)' {

    It 'includes a machine with no TPM' {
        $hosts = $script:Artifacts | ForEach-Object {
            (Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json).Machine.Hostname
        }
        ($hosts -join ' ') | Should -Match 'NOTPM'
    }

    It 'the no-TPM machine reports pv on the hardware-dependent rules' {
        # This is the specific behaviour the demo exists to show: the machine
        # is not misconfigured, it physically cannot answer. Leaving it to the
        # random draw would mean the point sometimes fails to land.
        $file = $script:Artifacts | Where-Object { $_.Name -match 'notpm' } | Select-Object -First 1
        $file | Should -Not -BeNullOrEmpty

        $data  = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
        $rules = $data.ModuleDetails | ForEach-Object { $_.Rules }

        foreach ($id in @('R13', 'R14', 'R31')) {
            $rule = $rules | Where-Object { $_.Id -eq $id } | Select-Object -First 1
            if ($rule) { $rule.Status | Should -Be 'pv' }
        }
    }

    It 'the fleet spans a range of outcomes rather than one profile repeated' {
        $cvCounts = $script:Artifacts | ForEach-Object {
            (Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json).Summary.CountCV
        }
        (($cvCounts | Measure-Object -Maximum).Maximum - ($cvCounts | Measure-Object -Minimum).Minimum) |
            Should -BeGreaterThan 5
    }

    It 'no two profiles score identically' {
        # A first version chose verdicts by probability, and on the default
        # seed 'no-tpm' and 'regressed' both landed on 12 -- two of the six
        # stories collapsed into one. Counts are now exact per profile, and
        # this asserts they stay distinguishable.
        $cvCounts = @($script:Artifacts | ForEach-Object {
            (Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json).Summary.CountCV
        })
        @($cvCounts | Select-Object -Unique).Count | Should -Be $cvCounts.Count
    }

    It 'every machine reports some pv, so the vocabulary is visible' {
        foreach ($file in $script:Artifacts) {
            $data = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
            $data.Summary.CountPV | Should -BeGreaterThan 0
        }
    }
}
