#Requires -Version 5.1
<#
    FieldOps Pro - Phase 6, Stream 6.5 (D12)

    Audit: every Anthropic API call routes through FieldOps-AIClient.

    WHY THIS EXISTS

    Stream 6.5 centralises AI calls so that cost ceilings, audit logging,
    severity classification, retry, and cross-model fallback apply uniformly.
    A direct Invoke-RestMethod to the Anthropic endpoint anywhere else bypasses ALL
    of that -- an uncapped, unlogged, unclassified call. This audit is the
    standing guarantee that no such call exists in deployed code.

    WHAT COUNTS AS A VIOLATION

    A deployed SCRIPTS file (other than the client itself) that either:
      - contains the literal Anthropic endpoint host, or
      - issues an Invoke-RestMethod / Invoke-WebRequest to an Anthropic URL.

    The endpoint literal is flagged even inside a comment: dead call-code left
    in a compliance tool is itself a finding, and the reroute should remove it.

    SCOPE (matches the D14 audit convention)

    Excluded from the deployed set:
      - SCRIPTS/AI/FieldOps-AIClient.psm1  -- the client legitimately owns the
        one and only transport boundary.
      - the Archive/ tree                  -- retired code, never deployed.
      - Patch-/Debug-/Apply- one-off dev utilities.

    HISTORY

    Written red, by design: Invoke-ComplianceDiff.ps1 had two direct call sites
    (analysis + diagnostic ping), and that failing state was the definition of
    "done" for PR5b-2. The reroute landed in PR5b-2b and this audit went green.
    It is now a standing guard, not a to-do -- it must never go red again.
#>

BeforeAll {
    # This file lives at tests/audit/, i.e. two levels below the repo root:
    #   tests/audit/<file>  ->  tests/audit  ->  tests  ->  <repo>
    $script:RepoRoot   = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:ScriptsDir = Join-Path $script:RepoRoot 'SCRIPTS'

    # The single allowed home of the transport, by design.
    $script:ClientLeaf = 'FieldOps-AIClient.psm1'

    function Get-DeployedAiFiles {
        Get-ChildItem $script:ScriptsDir -Recurse -Include *.ps1, *.psm1 -File |
            Where-Object {
                $_.FullName -notmatch '\\Archive\\' -and
                $_.Name -ne $script:ClientLeaf -and
                $_.Name -notmatch '^(Patch|Debug|Apply)-'
            }
    }

    # Endpoint host, assembled from fragments so this test file does not itself
    # contain the literal it forbids (which would make it a false finding in any
    # future scan of the test tree).
    $script:EndpointHost = 'api' + '.' + 'anthropic' + '.' + 'com'

    function Find-DirectAnthropicCalls {
        param([string]$Path)

        $findings = @()
        $lines = Get-Content -LiteralPath $Path
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            $lineNo = $i + 1

            if ($line -match [regex]::Escape($script:EndpointHost)) {
                $findings += [PSCustomObject]@{ Line = $lineNo; Kind = 'endpoint-literal'; Text = $line.Trim() }
            }
            # A REST call on the same line as an anthropic reference is a direct
            # call even if the URL is held in a variable named for anthropic.
            if ($line -match '(?i)Invoke-(RestMethod|WebRequest)' -and $line -match '(?i)anthropic') {
                $findings += [PSCustomObject]@{ Line = $lineNo; Kind = 'rest-call'; Text = $line.Trim() }
            }
        }
        return $findings
    }
}

Describe 'No direct Anthropic calls outside the client (6.5-D12, 6.5-SC-1)' -Tag 'Slow' {

    It 'the AI client exists and is the designated transport owner' {
        # If the client moved or was renamed, the exclusion above is wrong and
        # every other assertion is meaningless -- so assert its presence first.
        $clientPath = Join-Path $script:ScriptsDir 'AI\FieldOps-AIClient.psm1'
        Test-Path $clientPath | Should -BeTrue
    }

    It 'no deployed script issues a direct Anthropic API call' {
        $violations = @()
        foreach ($file in (Get-DeployedAiFiles)) {
            $hits = Find-DirectAnthropicCalls -Path $file.FullName
            foreach ($h in $hits) {
                $rel = $file.FullName.Replace($script:RepoRoot + '\', '')
                $violations += ("{0}:{1} [{2}] {3}" -f $rel, $h.Line, $h.Kind, $h.Text)
            }
        }

        # Surface every offending line so a failure names exactly what to reroute,
        # not merely that something is wrong.
        if ($violations.Count -gt 0) {
            Write-Host "  Direct Anthropic calls still present (must route through the client):"
            $violations | ForEach-Object { Write-Host "    $_" }
        }

        $violations.Count | Should -Be 0
    }

    It 'the client itself is NOT excluded by accident (the exclusion is exactly one file)' {
        # Guard against the exclusion silently widening. Exactly one deployed
        # file -- the client -- is allowed to contain the transport.
        $allAi = Get-ChildItem $script:ScriptsDir -Recurse -Include *.ps1, *.psm1 -File |
                    Where-Object { $_.FullName -notmatch '\\Archive\\' -and $_.Name -notmatch '^(Patch|Debug|Apply)-' } |
                    Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match [regex]::Escape($script:EndpointHost) }

        # PR5b-2b has landed, so this is now exactly one file. Asserting the
        # COUNT, not just membership, is what makes this a real guard: it fails
        # the moment a second file acquires the transport, which is precisely
        # the regression the centralisation exists to prevent.
        $names = @($allAi | ForEach-Object { $_.Name })
        $names | Should -Contain $script:ClientLeaf
        $names.Count | Should -Be 1 -Because "only the client may own the transport; found: $($names -join ', ')"
    }
}
