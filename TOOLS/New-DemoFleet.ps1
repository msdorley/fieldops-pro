# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Ousman Dorley. See LICENSE at the repository root.
<#
================================================================================
New-DemoFleet.ps1 -- FieldOps Pro Phase 6, Stream 6.4 (6.4-D15)
================================================================================
Generates a synthetic fleet of compliance report data for demonstration,
documentation screenshots, and fleet-report development.

WHY THIS EXISTS

    Showing the product requires data. Showing it with real customer data is
    not an option, and showing it with the developer's own machine leaks a
    hostname, a username and a disk serial into every screenshot and every
    committed artifact.

WHY IT DERIVES FROM THE SHIPPED SAMPLE

    The 42-rule / 10-module structure is a contract enforced by audits A4 and
    A6. Hand-rolling that mapping here would create a second source of truth
    that drifts the first time a module title changes. Instead this script
    loads SCRIPTS\Compliance\report-data.sample.json as a structural skeleton
    and varies only what a demo needs to vary: identity and verdicts.

    Schema conformance therefore holds by construction, not by vigilance.

WHY THE SEED IS FIXED BY DEFAULT

    A demo that differs on every run cannot be screenshotted for
    documentation, and a fleet report that changes underneath you cannot be
    used to develop against. Same seed, same fleet, always.

IDENTITY IS SYNTHETIC BY CONSTRUCTION

    Every hostname, serial and technician name is generated from a fixed
    vocabulary with a DEMO- prefix. Nothing is read from the environment --
    not $env:COMPUTERNAME, not $env:USERNAME, not the real disk serial.

    Audit-DemoFleet.Tests.ps1 asserts this against the LIVE environment values
    at test time rather than against a blocklist, because a blocklist only
    catches the leaks somebody already thought of.

USAGE

    .\TOOLS\New-DemoFleet.ps1
    .\TOOLS\New-DemoFleet.ps1 -Count 10 -Seed 42
    .\TOOLS\New-DemoFleet.ps1 -OutputDir C:\Temp\fleet -Render

Changes nothing outside -OutputDir. Needs no elevation and no network.
================================================================================
#>

[CmdletBinding()]
param(
    # Number of machines to generate. The six profiles cycle if Count exceeds
    # six, so a larger fleet stays representative rather than repetitive.
    [ValidateRange(1, 200)]
    [int]$Count = 6,

    # Fixed by default so demos and screenshots are reproducible.
    [int]$Seed = 20260601,

    [string]$OutputDir,

    # Also render each machine to HTML. Slower; needs the renderer.
    [switch]$Render,

    # Emit the fleet objects for scripting. Off by default: an interactive run
    # already prints a summary, and dumping six objects underneath it buries
    # the summary rather than adding to it.
    [switch]$PassThru,

    [ValidateSet('fr', 'en')]
    [string]$Language = 'fr'
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutputDir) { $OutputDir = Join-Path $RepoRoot 'REPORTS\demo-fleet' }

$SamplePath = Join-Path $RepoRoot 'SCRIPTS\Compliance\report-data.sample.json'
$Renderer   = Join-Path $RepoRoot 'SCRIPTS\Compliance\Invoke-ANSSIDiagnostic-POC.ps1'

# ------------------------------------------------------------------ vocabulary
# Fixed, synthetic, and deliberately obvious. A reader glancing at a demo
# report should be able to tell at once that it is not a real machine.

$DemoTechnician = @{ fr = 'Technicien de demonstration'; en = 'Demo Technician' }
$DemoCustomer   = @{ fr = 'Client de demonstration';     en = 'Demo Customer'   }

# Invented models. Deliberately not real product names, to avoid implying that
# any vendor's hardware was tested and produced these results.
$DemoModels = @(
    'DemoCorp Workstation W-100',
    'DemoCorp Notebook N-220',
    'DemoCorp Compact C-40',
    'DemoCorp Tower T-800',
    'DemoCorp Convertible X-15',
    'Generic Virtual Machine'
)

$DemoOs = @(
    'Windows 11 Professionnel (build 26100, 24H2)',
    'Windows 11 Entreprise (build 26100, 24H2)',
    'Windows 10 Professionnel (build 19045, 22H2)'
)

# --------------------------------------------------------------------- profiles
# Each profile is a story a buyer needs to see. The middle two matter most:
# they are what makes the three-state vocabulary legible.

# TargetCv is an exact count, not a probability. A first version used a bias
# and let the draw decide; on the default seed it gave 'no-tpm' and
# 'regressed' identical scores, which collapsed two of the six stories the
# fleet exists to tell. The demo's central point is not something to leave to
# chance -- the same reasoning that forces pv on the hardware-dependent rules.
#
# 42 rules, 16 of which are hp on every machine, leaves 26 to allocate.

$Profiles = @(
    @{
        Key      = 'healthy'
        Label    = 'Well-managed domain workstation'
        # Deliberately not 26. A machine reporting every rule verified would
        # advertise that the tool cannot tell verified from unverifiable.
        TargetCv = 22
        NoTpm    = $false
        ModelIdx = 0
    },
    @{
        Key      = 'no-tpm'
        Label    = 'Older machine with no TPM'
        # The profile that demonstrates why pv exists. This machine is not
        # misconfigured; it physically cannot answer the question.
        TargetCv = 15
        NoTpm    = $true
        ModelIdx = 2
    },
    @{
        Key      = 'regressed'
        Label    = 'Machine with genuine findings'
        TargetCv = 8
        NoTpm    = $false
        ModelIdx = 1
    },
    @{
        Key      = 'vm'
        Label    = 'Virtual machine, no SMART or firmware data'
        TargetCv = 11
        NoTpm    = $true
        ModelIdx = 5
    },
    @{
        Key      = 'laptop'
        Label    = 'Mobile user, Wi-Fi and VPN in scope'
        TargetCv = 18
        NoTpm    = $false
        ModelIdx = 4
    },
    @{
        Key      = 'fresh'
        Label    = 'Newly imaged, not yet hardened'
        TargetCv = 5
        NoTpm    = $false
        ModelIdx = 3
    }
)

# ---------------------------------------------------------------------- helpers

function Get-DemoHostname {
    param([int]$Index, [string]$ProfileKey)
    # DEMO- prefix is load-bearing: it makes a leaked real hostname visible on
    # sight, not merely detectable by test.
    return ('DEMO-{0}-{1:D3}' -f $ProfileKey.ToUpper().Replace('-', ''), $Index)
}

function Get-DemoSerial {
    param([int]$Index)
    return ('DEMOSN{0:D10}' -f $Index)
}

function Copy-JsonObject {
    param($Object)
    # PowerShell 5.1 has no deep-clone for PSCustomObject. Round-tripping
    # through JSON is slower but correct, and this runs once per machine.
    return ($Object | ConvertTo-Json -Depth 12 | ConvertFrom-Json)
}

function Set-DemoEvidence {
    param($Rule, [string]$NewStatus, [string]$OriginalStatus, [string]$Language)

    # A rule whose verdict changed can no longer carry the sample's evidence.
    # The sample's R34 Meta describes three specific failed updates; leaving
    # that text under a cv verdict produces a report that contradicts itself,
    # which is precisely what an evaluator reads a demo looking for.
    #
    # Rules whose verdict did NOT change keep their original prose, so the
    # fleet still shows what real evidence text looks like.
    if ($NewStatus -eq $OriginalStatus) { return }

    $en = switch ($NewStatus) {
        'cv' { 'Control observed in place on this demonstration machine.' }
        'pv' { 'Evidence incomplete on this demonstration machine: the probe could not confirm the control, or the hardware required to demonstrate it is absent.' }
        default { '' }
    }
    $fr = switch ($NewStatus) {
        'cv' { 'Controle observe en place sur cette machine de demonstration.' }
        'pv' { 'Preuve incomplete sur cette machine de demonstration : le releve n''a pas pu confirmer le controle, ou le materiel necessaire est absent.' }
        default { '' }
    }
    $text = $fr
    if ($Language -eq 'en') { $text = $en }

    $names = @($Rule.PSObject.Properties.Name)
    # Meta is per-language since 7.1. Writing a single string here would put
    # French into an English demo render -- the same defect the 7.1 guard
    # exists to catch, reintroduced through the demo path. Older skeletons
    # still carry a plain string, so both shapes are handled.
    if ($names -contains 'Meta') {
        if ($Rule.Meta -is [string]) { $Rule.Meta = $text }
        else { $Rule.Meta = [PSCustomObject]@{ fr = $fr; en = $en } }
    }
    if ($names -contains 'Detail')   { $Rule.Detail   = '' }
    if ($names -contains 'Evidence') { $Rule.Evidence = '' }
}

# Rules whose verdict depends on hardware the machine does not have. On a
# no-TPM profile these can only ever be pv -- the machine is not
# misconfigured, it physically cannot answer.
$script:TpmDependentRules = @('R13', 'R14', 'R31')

function Get-DemoCvSelection {
    param(
        [System.Random]$Rng,
        $Skeleton,
        [int]$TargetCv,
        [bool]$NoTpm
    )

    # Build the pool of rules eligible to be cv, then choose exactly TargetCv
    # of them. Selecting an exact set rather than rolling per rule is what
    # makes each profile's score a property of the profile instead of an
    # accident of the seed.
    $eligible = @()
    foreach ($module in $Skeleton.ModuleDetails) {
        foreach ($rule in $module.Rules) {
            # hp is a property of the rule, not of the machine. R1 is out of
            # scope on every machine ever built.
            if ($rule.Status -eq 'hp') { continue }
            if ($NoTpm -and ($script:TpmDependentRules -contains $rule.Id)) { continue }
            $eligible += $rule.Id
        }
    }

    # Deterministic Fisher-Yates. Sort-Object {Get-Random} would ignore the
    # seeded generator and make the fleet irreproducible.
    for ($i = $eligible.Count - 1; $i -gt 0; $i--) {
        $j = $Rng.Next(0, $i + 1)
        $tmp = $eligible[$i]; $eligible[$i] = $eligible[$j]; $eligible[$j] = $tmp
    }

    $take = [Math]::Min($TargetCv, $eligible.Count)
    return @{ Cv = @($eligible | Select-Object -First $take) }
}

function Get-DemoStatus {
    param(
        [string]$OriginalStatus,
        [string[]]$CvSet,
        [string]$RuleId
    )

    if ($OriginalStatus -eq 'hp') { return 'hp' }
    if ($CvSet -contains $RuleId) { return 'cv' }
    return 'pv'
}

# ------------------------------------------------------------------------- main

if (-not (Test-Path -LiteralPath $SamplePath)) {
    throw "Structural sample not found: $SamplePath"
}

Write-Host ''
Write-Host '=========================================================================='
Write-Host '  FIELDOPS PRO -- DEMO FLEET GENERATOR'
Write-Host '=========================================================================='
Write-Host ("  Count    : {0}" -f $Count)
Write-Host ("  Seed     : {0}" -f $Seed)
Write-Host ("  Output   : {0}" -f $OutputDir)
Write-Host ''

$sampleRaw = Get-Content -LiteralPath $SamplePath -Raw -Encoding UTF8
$skeleton  = $sampleRaw | ConvertFrom-Json

if (-not (Test-Path -LiteralPath $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

$rng       = New-Object System.Random($Seed)
$generated = @()

# A fixed base date, not Get-Date. A regenerated fleet must be byte-identical
# to the committed one, or the leak test cannot tell a real change from a
# timestamp.
$baseDate = [datetime]'2026-06-01T09:00:00'

for ($i = 1; $i -le $Count; $i++) {

    $prof     = $Profiles[($i - 1) % $Profiles.Count]
    $machine  = Copy-JsonObject $skeleton
    $hostname = Get-DemoHostname -Index $i -ProfileKey $prof.Key
    $stamp    = $baseDate.AddHours($i * 3)

    # --- identity: entirely synthetic, nothing read from the environment ---
    $machine.Report.Id               = ('FOPS-DEMO-{0:D3}-{1}' -f $i, $prof.Key.ToUpper())
    $machine.Report.GeneratedAt      = $stamp.ToString('yyyy-MM-ddTHH:mm:ss+02:00')
    $machine.Report.GeneratedAtHuman = $stamp.ToString('dd/MM/yyyy HH:mm')
    $machine.Report.Technician       = $DemoTechnician[$Language]
    $machine.Report.CustomerContact  = $DemoCustomer[$Language]

    $machine.Machine.Hostname  = $hostname
    $machine.Machine.MakeModel = $DemoModels[$prof.ModelIdx]
    $machine.Machine.Serial    = Get-DemoSerial -Index $i
    $machine.Machine.Os        = $DemoOs[$rng.Next(0, $DemoOs.Count)]
    $machine.Machine.Directory = if ($prof.Key -eq 'fresh') { 'Not joined' } else { 'Workplace Joined' }

    # --- verdicts: exact per profile, recount from what was actually set ---
    $selection = Get-DemoCvSelection -Rng $rng -Skeleton $skeleton `
        -TargetCv $prof.TargetCv -NoTpm $prof.NoTpm
    $cvSet = $selection.Cv

    $cv = 0; $pv = 0; $hp = 0

    foreach ($module in $machine.ModuleDetails) {
        $mCv = 0; $mPv = 0; $mHp = 0

        foreach ($rule in $module.Rules) {
            $originalStatus = $rule.Status

            $rule.Status = Get-DemoStatus -OriginalStatus $originalStatus `
                -CvSet $cvSet -RuleId $rule.Id

            Set-DemoEvidence -Rule $rule -NewStatus $rule.Status `
                -OriginalStatus $originalStatus -Language $Language

            switch ($rule.Status) {
                'cv' { $cv++; $mCv++ }
                'pv' { $pv++; $mPv++ }
                'hp' { $hp++; $mHp++ }
            }
        }

        # Per-module counts are recomputed from the rules just assigned rather
        # than adjusted incrementally, so they cannot drift from the detail.
        $summaryModule = $machine.Modules | Where-Object { $_.Number -eq $module.Number }
        if ($summaryModule) {
            $summaryModule.Counts.Cv = $mCv
            $summaryModule.Counts.Pv = $mPv
            $summaryModule.Counts.Hp = $mHp
        }
    }

    $machine.Summary.CountCV = $cv
    $machine.Summary.CountPV = $pv
    $machine.Summary.CountHP = $hp
    $machine.Summary.Total   = $cv + $pv + $hp

    $outFile = Join-Path $OutputDir ('report-data.{0}.json' -f $hostname.ToLower())
    $json    = $machine | ConvertTo-Json -Depth 12

    # ASCII-safe write. The sample carries accented French, so this file is
    # UTF-8; it is data, not source, and A1 does not apply to it.
    [System.IO.File]::WriteAllText($outFile, $json, (New-Object System.Text.UTF8Encoding($false)))

    $generated += [PSCustomObject]@{
        Hostname = $hostname
        Profile  = $prof.Label
        Cv       = $cv
        Pv       = $pv
        Hp       = $hp
        Path     = $outFile
    }

    Write-Host ("  [OK  ] {0,-22} {1,-38} cv:{2,2} pv:{3,2} hp:{4,2}" -f `
        $hostname, $prof.Label, $cv, $pv, $hp)
}

# ------------------------------------------------------------------- rendering

if ($Render) {
    Write-Host ''
    Write-Host '  Rendering reports...'

    if (-not (Test-Path -LiteralPath $Renderer)) {
        Write-Warning "  Renderer not found: $Renderer -- data written, nothing rendered."
    }
    else {
        foreach ($m in $generated) {
            try {
                & $Renderer -DataFile $m.Path -OutputDir $OutputDir `
                    -Language $Language -NoPdf -NoOpen *>&1 | Out-Null
                Write-Host ("  [OK  ] rendered {0}" -f $m.Hostname)
            }
            catch {
                # One bad render must not abandon the rest of the fleet.
                Write-Warning ("  render failed for {0}: {1}" -f $m.Hostname, $_.Exception.Message)
            }
        }
    }
}

Write-Host ''
Write-Host '--------------------------------------------------------------------------'
Write-Host ("  {0} machine(s) written to {1}" -f $generated.Count, $OutputDir)
Write-Host '--------------------------------------------------------------------------'
Write-Host ''

if ($PassThru) { return $generated }
