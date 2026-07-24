#Requires -Version 5.1
<#
    FieldOps Pro - Phase 6, Stream 6.5 (D14 / SC-10)

    Audit tests for CONFIG/AIModelPricing.json.

    WHY THIS IS MORE THAN A FRESHNESS CHECK

    The design doc specifies a freshness test: warn when the pricing snapshot
    exceeds 90 days. That guards one failure mode, but not the one that
    actually occurred on this project.

    Between the design document's publication (25 May 2026) and Stream 6.5's
    execution, the model lineup moved twice: Opus 4.7 -> 4.8, Sonnet 4.6 -> 5.
    Prices did NOT change across either transition -- Opus stayed at 5.00/25.00
    and Sonnet at 3.00/15.00. A pure freshness test would therefore have
    reported healthy for the entire period during which the configured model
    identifiers went stale. Price age and model validity came apart, and the
    test guarded only the half that did not move.

    These tests therefore assert three separate things:

      1. STRUCTURE   -- the file is valid, complete, and internally consistent
      2. CONSERVATISM -- estimation defaults never under-report cost
      3. FRESHNESS   -- the snapshot is not dangerously old

    Conservatism gets its own tests because cost ceilings are a SAFETY control.
    A ceiling computed from an optimistic price fails open: it admits calls it
    was built to refuse, and the operator discovers the problem on their
    invoice. Under-reporting is the failure mode that matters, so it is the one
    under test.

    FRESHNESS POLICY
        > freshnessWarnDays  -> Write-Warning, test still passes
        > freshnessFailDays  -> test fails
    Both thresholds live in the config, so the policy is data rather than code.
    The warn tier exists so an ageing snapshot surfaces early without blocking
    unrelated work; the fail tier exists because at some point stale pricing
    stops being a nuisance and starts being wrong.
#>

BeforeAll {
    $script:TestsRoot  = Split-Path $PSScriptRoot -Parent
    $script:RepoRoot   = Split-Path $script:TestsRoot -Parent
    $script:PricingPath = Join-Path $script:RepoRoot 'CONFIG\AIModelPricing.json'

    $script:Pricing = $null
    if (Test-Path -LiteralPath $script:PricingPath) {
        try {
            $script:Pricing = Get-Content $script:PricingPath -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch {
            $script:Pricing = $null
        }
    }

    function Get-ModelNames {
        param($Pricing)
        if ($null -eq $Pricing) { return @() }
        if ($null -eq $Pricing.models) { return @() }
        return @($Pricing.models.PSObject.Properties.Name)
    }

    function Get-Model {
        param($Pricing, [string]$Name)
        return $Pricing.models.$Name
    }
}

Describe 'AI model pricing config - structure (6.5-D14)' -Tag 'Slow' {

    It 'the pricing config exists' {
        Test-Path -LiteralPath $script:PricingPath | Should -BeTrue
    }

    It 'parses as valid JSON' {
        $script:Pricing | Should -Not -BeNullOrEmpty
    }

    It 'declares a schema version, source and currency' {
        $script:Pricing._meta.schemaVersion | Should -Not -BeNullOrEmpty
        $script:Pricing._meta.source        | Should -Match '^https://'
        $script:Pricing._meta.currency      | Should -Be 'USD'
    }

    It 'defines all three task tiers required by 6.5-R2' {
        $tiers = @($script:Pricing.tiers.PSObject.Properties.Name)
        foreach ($required in @('Classification','Narration','Reasoning')) {
            $tiers | Should -Contain $required
        }
    }

    It 'every tier maps to a model present in the models table' {
        $models = Get-ModelNames -Pricing $script:Pricing
        $bad = @()
        foreach ($t in $script:Pricing.tiers.PSObject.Properties) {
            if ($models -notcontains $t.Value) { $bad += "$($t.Name) -> $($t.Value)" }
        }
        ($bad -join ', ') | Should -Be ''
    }

    It 'every model declares positive input and output prices' {
        $bad = @()
        foreach ($name in (Get-ModelNames -Pricing $script:Pricing)) {
            $m = Get-Model -Pricing $script:Pricing -Name $name
            if ($null -eq $m.inputPerMTok  -or [double]$m.inputPerMTok  -le 0) { $bad += "$name input" }
            if ($null -eq $m.outputPerMTok -or [double]$m.outputPerMTok -le 0) { $bad += "$name output" }
        }
        ($bad -join ', ') | Should -Be ''
    }

    It 'every model declares a status of current or legacy' {
        $bad = @()
        foreach ($name in (Get-ModelNames -Pricing $script:Pricing)) {
            $s = (Get-Model -Pricing $script:Pricing -Name $name).status
            if ($s -notin @('current','legacy')) { $bad += "$name=$s" }
        }
        ($bad -join ', ') | Should -Be ''
    }

    It 'every model declares a tokenizer variant' {
        # 6.5-Risk-7: the v2 tokenizer can emit up to 35% more tokens for the
        # same input. Cost estimation cannot be correct without knowing which
        # variant a model uses.
        $bad = @()
        foreach ($name in (Get-ModelNames -Pricing $script:Pricing)) {
            $v = (Get-Model -Pricing $script:Pricing -Name $name).tokenizerVariant
            if ($v -notin @('v1','v2')) { $bad += "$name=$v" }
        }
        ($bad -join ', ') | Should -Be ''
    }

    It 'output price is at least input price for every model' {
        # Anthropic's current lineup holds a 5x output-to-input ratio. This is
        # a sanity check against a transposed pair, which would make output
        # cost -- the dominant term for narration workloads -- read low.
        $bad = @()
        foreach ($name in (Get-ModelNames -Pricing $script:Pricing)) {
            $m = Get-Model -Pricing $script:Pricing -Name $name
            if ([double]$m.outputPerMTok -lt [double]$m.inputPerMTok) { $bad += $name }
        }
        ($bad -join ', ') | Should -Be ''
    }
}

Describe 'AI model pricing config - conservative estimation (6.5-R3)' -Tag 'Slow' {

    It 'chars-per-token estimate is conservative' {
        # Lower chars/token => more tokens estimated => higher estimated cost
        # => ceiling engages earlier. Real prose runs roughly 3.5-4.0 on the v1
        # tokenizer; anything at or above that would under-report.
        [double]$script:Pricing.estimation.charsPerTokenConservative |
            Should -BeLessThan 3.5
        [double]$script:Pricing.estimation.charsPerTokenConservative |
            Should -BeGreaterThan 0
    }

    It 'default output multiplier is at least 1' {
        # An output multiplier below 1 would predict responses shorter than the
        # prompt as a rule, which is not a safe default for narration tasks.
        [double]$script:Pricing.estimation.defaultOutputMultiplier |
            Should -BeGreaterOrEqual 1.0
    }

    It 'the unknown-model fallback is the most expensive current model' {
        # An unrecognised model must never be priced lower than a recognised
        # one, or a typo in configuration would silently disable the ceiling.
        $fallback = $script:Pricing.estimation.unknownModelFallback
        $fallback | Should -Not -BeNullOrEmpty

        $models = Get-ModelNames -Pricing $script:Pricing
        $models | Should -Contain $fallback

        $fallbackModel = Get-Model -Pricing $script:Pricing -Name $fallback
        $maxCurrentIn = 0.0
        foreach ($name in $models) {
            $m = Get-Model -Pricing $script:Pricing -Name $name
            if ($m.status -eq 'current' -and [double]$m.inputPerMTok -gt $maxCurrentIn) {
                $maxCurrentIn = [double]$m.inputPerMTok
            }
        }
        [double]$fallbackModel.inputPerMTok | Should -Be $maxCurrentIn
    }

    It 'recorded prices are standard rates, not promotional ones' {
        # Where a model carries an introductory rate, the standard rate must be
        # the one used for estimation. A ceiling computed from a promotional
        # price stops protecting the operator the day the promotion ends.
        $bad = @()
        foreach ($name in (Get-ModelNames -Pricing $script:Pricing)) {
            $m = Get-Model -Pricing $script:Pricing -Name $name
            if ($null -ne $m.introRateInputPerMTok) {
                if ([double]$m.inputPerMTok -le [double]$m.introRateInputPerMTok) {
                    $bad += "$name records the introductory input rate"
                }
                if ([double]$m.outputPerMTok -le [double]$m.introRateOutputPerMTok) {
                    $bad += "$name records the introductory output rate"
                }
            }
        }
        ($bad -join '; ') | Should -Be ''
    }
}

Describe 'AI model pricing config - deployed compatibility (6.5-R13)' -Tag 'Slow' {

    It 'retains every model identifier referenced by deployed code' {
        # Removing a legacy identifier from this table would cause the client
        # to reject a configuration that is currently working in the field.
        $models = Get-ModelNames -Pricing $script:Pricing
        $deployed = @()

        $sources = @(
            (Join-Path $script:RepoRoot 'SCRIPTS\Core\Invoke-ComplianceDiff.ps1'),
            (Join-Path $script:RepoRoot 'SCRIPTS\Core\FieldOps-RiskPlanner.psm1')
        )
        foreach ($src in $sources) {
            if (-not (Test-Path -LiteralPath $src)) { continue }
            $text = Get-Content $src -Raw
            foreach ($m in [regex]::Matches($text, "claude-[a-z0-9\-]+")) {
                if ($deployed -notcontains $m.Value) { $deployed += $m.Value }
            }
        }

        # Only assert on identifiers that look like real model strings
        $deployed = @($deployed | Where-Object { $_ -match '^claude-(opus|sonnet|haiku)-' })
        $deployed.Count | Should -BeGreaterThan 0

        $missing = @($deployed | Where-Object { $models -notcontains $_ })
        ($missing -join ', ') | Should -Be ''
    }

    It 'documents why legacy entries are retained' {
        $script:Pricing.legacyRetentionPolicy.reason | Should -Not -BeNullOrEmpty
    }
}

Describe 'AI model pricing config - freshness (6.5-SC-10)' -Tag 'Slow' {

    It 'declares a parseable snapshot date that is not in the future' {
        $raw = $script:Pricing._meta.snapshotDate
        $raw | Should -Not -BeNullOrEmpty

        $parsed = [datetime]::MinValue
        [datetime]::TryParseExact(
            $raw, 'yyyy-MM-dd',
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None,
            [ref]$parsed) | Should -BeTrue

        ($parsed -le (Get-Date).Date) | Should -BeTrue
    }

    It 'declares both freshness thresholds, warn before fail' {
        [int]$script:Pricing._meta.freshnessWarnDays | Should -BeGreaterThan 0
        [int]$script:Pricing._meta.freshnessFailDays |
            Should -BeGreaterThan ([int]$script:Pricing._meta.freshnessWarnDays)
    }

    It 'the pricing snapshot is not dangerously stale' {
        $parsed = [datetime]::ParseExact(
            $script:Pricing._meta.snapshotDate, 'yyyy-MM-dd',
            [System.Globalization.CultureInfo]::InvariantCulture)

        $ageDays  = [int]((Get-Date).Date - $parsed).TotalDays
        $warnDays = [int]$script:Pricing._meta.freshnessWarnDays
        $failDays = [int]$script:Pricing._meta.freshnessFailDays

        if ($ageDays -gt $warnDays -and $ageDays -le $failDays) {
            Write-Warning ("AI model pricing snapshot is {0} days old (warn threshold {1}). " -f $ageDays, $warnDays +
                           "Re-verify against $($script:Pricing._meta.source) and update _meta.snapshotDate. " +
                           "Check model identifiers as well as prices: the two can drift independently.")
        }

        if ($ageDays -gt $failDays) {
            "pricing snapshot is $ageDays days old, exceeding the $failDays day limit" | Should -Be ''
        }
        $true | Should -BeTrue
    }
}
