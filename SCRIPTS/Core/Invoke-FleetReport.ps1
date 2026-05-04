#Requires -Version 5.1
<#
.SYNOPSIS
    FieldOps Pro -- Fleet Intelligence Dashboard v2.0
.DESCRIPTION
    Reads all machine history from E:\REPORTS\History\, parses linked Master
    HTML reports for hardware identity (manufacturer, model, serial, OS, CPU,
    RAM), generates per-machine and fleet-wide recommendations, builds a
    compliance baseline, and produces a comprehensive HTML dashboard.
.PARAMETER Since
    Include scans from this date onward. Default: 90 days ago.
.PARAMETER OpenReport
    Open the HTML report automatically after generation.
.EXAMPLE
    .\Invoke-FleetReport.ps1
    .\Invoke-FleetReport.ps1 -Since (Get-Date).AddDays(-30)
    .\Invoke-FleetReport.ps1 -OpenReport
#>
[CmdletBinding()]
param(
    [datetime]$Since     = (Get-Date).AddDays(-90),
    [switch]$OpenReport
)

$ErrorActionPreference = 'Continue'

# ==============================================================
# PATH RESOLUTION -- Two-level Split-Path to reach USB root
# ==============================================================
$scriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path   # E:\SCRIPTS\Core
$scriptsDir = Split-Path -Parent $scriptDir                      # E:\SCRIPTS
$usbRoot    = Split-Path -Parent $scriptsDir                     # E:\
$reportsDir = Join-Path $usbRoot 'REPORTS'
$historyDir = Join-Path $reportsDir 'History'
$configDir  = Join-Path $usbRoot 'CONFIG'

# ==============================================================
# CONFIG
# ==============================================================
$techName = 'Unknown Technician'
$orgName  = 'FieldOps Pro'
$cfgFile  = Join-Path $configDir 'FieldOps.config.json'
if (Test-Path $cfgFile) {
    try {
        $cfg = Get-Content $cfgFile -Raw | ConvertFrom-Json
        foreach ($f in @('TechnicianName','Technician','TechName','Tech','Name','Engineer','User')) {
            $v = $cfg.$f
            if ($v -and $v.ToString().Trim() -ne '') { $techName = $v.ToString().Trim(); break }
        }
        foreach ($f in @('OrgName','Organisation','Organization','Company','Title','Org')) {
            $v = $cfg.$f
            if ($v -and $v.ToString().Trim() -ne '') { $orgName = $v.ToString().Trim(); break }
        }
    } catch { }
}
# Fallback: peek at the most recent history JSON for technician name
if ($techName -eq 'Unknown Technician' -and (Test-Path $historyDir)) {
    $latestJ = @(Get-ChildItem -Path $historyDir -Filter '*.json' -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime -Descending | Select-Object -First 1)
    if ($latestJ.Count -gt 0) {
        try {
            $peek = Get-Content $latestJ[0].FullName -Raw | ConvertFrom-Json
            foreach ($f in @('Technician','TechnicianName','TechName','Tech','Engineer','RunBy','User')) {
                $v = $peek.$f
                if ($v -and $v.ToString().Trim() -ne '' -and $v.ToString() -ne 'Unknown') {
                    $techName = $v.ToString().Trim(); break
                }
            }
        } catch { }
    }
}

# ==============================================================
# CONSTANTS
# ==============================================================
$VERSION     = '2.1'
$NOW         = Get-Date
$W           = 72
$REPORT_NAME = "FleetReport_$($NOW.ToString('yyyyMMdd_HHmmss')).html"
$REPORT_PATH = Join-Path $reportsDir $REPORT_NAME

# ==============================================================
# CONSOLE HELPERS
# ==============================================================
function Write-Banner {
    Write-Host ('=' * $W) -ForegroundColor Cyan
    Write-Host "  FIELDOPS PRO -- FLEET INTELLIGENCE DASHBOARD v$VERSION" -ForegroundColor White
    Write-Host ('=' * $W) -ForegroundColor Cyan
    Write-Host "  Technician : $techName"
    Write-Host "  Since      : $($Since.ToString('yyyy-MM-dd'))"
    Write-Host "  Date       : $($NOW.ToString('yyyy-MM-dd HH:mm:ss'))"
    Write-Host ('-' * $W) -ForegroundColor DarkGray
}

function Write-Section { param([string]$T)
    Write-Host ''
    Write-Host "  $T" -ForegroundColor Yellow
    Write-Host ('  ' + ('-' * ($W - 2))) -ForegroundColor DarkGray
}

function Write-Step { param([string]$M, [string]$C = 'Gray')
    Write-Host "    $M" -ForegroundColor $C
}

# ==============================================================
# GRADE / RISK HELPERS
# ==============================================================
function Get-GradeFromScore {
    param([int]$S)
    if ($S -ge 97) { return 'A+' }
    if ($S -ge 93) { return 'A'  }
    if ($S -ge 90) { return 'A-' }
    if ($S -ge 87) { return 'B+' }
    if ($S -ge 83) { return 'B'  }
    if ($S -ge 80) { return 'B-' }
    if ($S -ge 77) { return 'C+' }
    if ($S -ge 73) { return 'C'  }
    if ($S -ge 70) { return 'C-' }
    if ($S -ge 67) { return 'D+' }
    if ($S -ge 63) { return 'D'  }
    if ($S -ge 60) { return 'D-' }
    return 'F'
}

function Get-RiskFromScore {
    param([int]$S)
    if ($S -ge 90) { return 'MINIMAL'  }
    if ($S -ge 80) { return 'LOW'      }
    if ($S -ge 70) { return 'MEDIUM'   }
    if ($S -ge 60) { return 'HIGH'     }
    return 'CRITICAL'
}

function Get-GradeHex {
    param([string]$G)
    switch -Wildcard ($G) {
        'A*' { return '#22c55e' }
        'B*' { return '#84cc16' }
        'C*' { return '#eab308' }
        'D*' { return '#f97316' }
        'F'  { return '#ef4444' }
        default { return '#94a3b8' }
    }
}

function Get-RiskHex {
    param([string]$R)
    switch ($R) {
        'CRITICAL' { return '#ef4444' }
        'HIGH'     { return '#f97316' }
        'MEDIUM'   { return '#eab308' }
        'LOW'      { return '#84cc16' }
        'MINIMAL'  { return '#22c55e' }
        default    { return '#94a3b8' }
    }
}

function Get-PriorityHex {
    param([string]$P)
    switch ($P) {
        'CRITICAL' { return '#ef4444' }
        'HIGH'     { return '#f97316' }
        'MEDIUM'   { return '#eab308' }
        'LOW'      { return '#84cc16' }
        'INFO'     { return '#38bdf8' }
        'OK'       { return '#22c55e' }
        default    { return '#94a3b8' }
    }
}

function Get-EngineHex {
    param([int]$S)
    if ($S -ge 88) { return '#22c55e' }
    if ($S -ge 75) { return '#84cc16' }
    if ($S -ge 65) { return '#eab308' }
    if ($S -ge 55) { return '#f97316' }
    return '#ef4444'
}

# ==============================================================
# GRADE <-> SCORE CONVERSION (both directions)
# ==============================================================
function Get-ScoreFromGrade {
    param([string]$G)
    switch ($G) {
        'A+' { return 98 } 'A'  { return 94 } 'A-' { return 91 }
        'B+' { return 88 } 'B'  { return 84 } 'B-' { return 81 }
        'C+' { return 78 } 'C'  { return 74 } 'C-' { return 71 }
        'D+' { return 68 } 'D'  { return 64 } 'D-' { return 61 }
        'F'  { return 45 }
        default { return 0 }
    }
}

# ==============================================================
# SCAN RECORD NORMALIZATION
# Resilient multi-strategy parser -- logs structure on failure
# ==============================================================
function ConvertTo-ScanRecord {
    param($Raw, [string]$FilePath)
    try {
        $fname = [IO.Path]::GetFileName($FilePath)

        # ---- HOSTNAME ----
        $hostname = $null
        foreach ($f in @('Hostname','HostName','ComputerName','Computer','Host','MachineName','Device')) {
            if ($Raw.$f -and ($Raw.$f).ToString().Trim() -ne '') { $hostname = ($Raw.$f).ToString().Trim(); break }
        }
        if (-not $hostname) {
            $hostname = [IO.Path]::GetFileNameWithoutExtension($FilePath) -replace '_\d{8}_\d{6}$','' -replace '^\w+_',''
            # If filename is HOSTNAME_20260405_125219 the above strips the date
            $hostname = [IO.Path]::GetFileNameWithoutExtension($FilePath) -replace '_\d{8}_\d{6}$',''
        }

        # ---- SCAN DATE ----
        $scanDate = $NOW
        foreach ($f in @('ScanDate','Timestamp','Date','ScanTime','ReportDate','DateTime','Created')) {
            $v = $Raw.$f
            if ($v) { try { $scanDate = [datetime]::Parse($v.ToString()); break } catch { } }
        }

        # ---- SCORE (numeric 0-100) ----
        $score = 0
        $scoreFields = @('OverallScore','Score','TotalScore','FinalScore','HealthScore',
                         'Percentage','GradeScore','Total','HealthPct','Pct','Points',
                         'OverallPct','AggregateScore','CompositeScore','HealthIndex')
        foreach ($f in $scoreFields) {
            $v = $Raw.$f
            if ($null -ne $v) {
                try {
                    $n = [double]$v
                    if ($n -ge 1 -and $n -le 100) { $score = [int][math]::Round($n); break }
                } catch { }
            }
        }

        # ---- GRADE (letter: A+, A, A-, B+, ..., F) ----
        $grade = ''
        $gradeFields = @('OverallGrade','Grade','LetterGrade','GradeLetter','Rating',
                         'HealthGrade','GradeResult','Mark','OverallRating')
        foreach ($f in $gradeFields) {
            $v = $Raw.$f
            if ($v -and $v.ToString() -match '^[A-Fa-f][+\-]?$') { $grade = $v.ToString().ToUpper(); break }
        }

        # ---- RISK ----
        $risk = ''
        $riskFields = @('RiskLevel','Risk','RiskRating','RiskCategory','RiskStatus',
                        'Severity','ThreatLevel','RiskScore','RiskGrade')
        foreach ($f in $riskFields) {
            $v = $Raw.$f
            if ($v -and $v.ToString().Trim() -ne '') {
                $rv = $v.ToString().ToUpper().Trim()
                if ($rv -in @('CRITICAL','HIGH','MEDIUM','LOW','MINIMAL')) { $risk = $rv; break }
            }
        }

        # ---- CROSS-DERIVE: fill in whatever is still missing ----
        if ($grade -and $score -eq 0)  { $score = Get-ScoreFromGrade $grade }
        if ($score -gt 0 -and -not $grade) { $grade = Get-GradeFromScore $score }
        if ($score -gt 0 -and -not $risk)  { $risk  = Get-RiskFromScore $score }
        if ($grade -and -not $risk)        { $risk  = Get-RiskFromScore (Get-ScoreFromGrade $grade) }

        # ---- LAST RESORT: scan ALL properties for score / grade signals ----
        if ($score -eq 0 -and -not $grade) {
            $Raw.PSObject.Properties | ForEach-Object {
                $pv = $_.Value
                if ($null -eq $pv) { return }
                # Numeric in plausible score range
                if ($pv -is [int] -or $pv -is [double] -or $pv -is [long]) {
                    $n = [int]$pv
                    if ($n -ge 50 -and $n -le 100 -and $score -eq 0) { $score = $n }
                }
                # String that looks like a grade letter
                if ($pv -is [string] -and $pv -match '^[A-Fa-f][+\-]?$' -and -not $grade) {
                    $grade = $pv.ToUpper()
                }
                # String that contains a numeric percent  e.g. "85%" or "85.3%"
                if ($pv -is [string] -and $pv -match '^(\d{1,3}(\.\d+)?)%?$' -and $score -eq 0) {
                    $n = [int][double]$matches[1]
                    if ($n -ge 50 -and $n -le 100) { $score = $n }
                }
            }
            if ($grade -and $score -eq 0)  { $score = Get-ScoreFromGrade $grade }
            if ($score -gt 0 -and -not $grade) { $grade = Get-GradeFromScore $score }
            if ($score -gt 0 -and -not $risk)  { $risk  = Get-RiskFromScore $score }
        }

        # ---- FINAL DEFAULTS ----
        if (-not $grade) { $grade = 'F' }
        if (-not $risk)  { $risk  = if ($score -gt 0) { Get-RiskFromScore $score } else { 'CRITICAL' } }

        # ---- DEBUG: dump JSON structure when score still 0 ----
        if ($score -eq 0) {
            $propDump = ($Raw.PSObject.Properties | ForEach-Object {
                $t = if ($null -ne $_.Value) { $_.Value.GetType().Name } else { 'null' }
                "$($_.Name)[$t]"
            }) -join ', '
            Write-Host "    [JSON-DBG] $fname -> $propDump" -ForegroundColor DarkYellow
        }

        # ---- TECHNICIAN ----
        $tech = 'Unknown'
        foreach ($f in @('Technician','TechnicianName','Tech','TechName','Engineer',
                          'FieldTech','User','Operator','RunBy','ExecutedBy')) {
            $v = $Raw.$f
            if ($v -and $v.ToString().Trim() -ne '' -and $v.ToString() -ne 'Unknown') {
                $tech = $v.ToString().Trim(); break
            }
        }

        # ---- ENGINE SCORES ----
        $engines  = @{}
        $engNames = @('PCHealth','SecurityScan','AzureADJoin','NetworkRepair',
                      'DiskAnalysis','VPNSetup','SoftwareDeploy')

        # Strategy 1: EngineResults sub-object
        if ($Raw.EngineResults) {
            foreach ($en in $engNames) {
                $er = $Raw.EngineResults.$en
                if ($null -eq $er) { continue }
                $es = $null
                if ($er -is [int] -or $er -is [double])   { $es = [int]$er }
                elseif ($null -ne $er.Score)               { $es = [int]$er.Score }
                elseif ($null -ne $er.Percentage)          { $es = [int]$er.Percentage }
                elseif ($null -ne $er.Pct)                 { $es = [int]$er.Pct }
                elseif ($null -ne $er.Result)              { try { $es = [int]$er.Result } catch { } }
                if ($null -ne $es) { $engines[$en] = $es }
            }
        }

        # Strategy 2: Engines sub-object
        if ($Raw.Engines -and $engines.Count -eq 0) {
            foreach ($en in $engNames) {
                $v = $Raw.Engines.$en
                if ($null -ne $v) { try { $engines[$en] = [int]$v } catch { } }
            }
        }

        # Strategy 3: Flat properties on root object
        if ($engines.Count -eq 0) {
            foreach ($en in $engNames) {
                $v = $Raw.$en
                if ($null -ne $v) {
                    try {
                        $n = [int]$v
                        if ($n -ge 0 -and $n -le 100) { $engines[$en] = $n }
                    } catch { }
                }
            }
        }

        # Strategy 4: Scan ALL sub-objects for engine-name properties
        if ($engines.Count -eq 0) {
            $Raw.PSObject.Properties | Where-Object { $_.Value -and $_.Value -is [PSCustomObject] } | ForEach-Object {
                $sub = $_.Value
                foreach ($en in $engNames) {
                    $v = $sub.$en
                    if ($null -ne $v -and -not $engines.ContainsKey($en)) {
                        try { $n = [int]$v; if ($n -ge 0 -and $n -le 100) { $engines[$en] = $n } } catch { }
                    }
                }
            }
        }

        # ---- RISK CHAINS ----
        $chains = @()
        foreach ($f in @('RiskChains','Chains','Issues','Findings','Problems',
                          'FailedChecks','Alerts','Warnings','Errors')) {
            $v = $Raw.$f
            if ($v) { $chains = @($v); break }
        }

        # ---- REPORT PATH ----
        $rpath = $null
        foreach ($f in @('MasterReportPath','ReportPath','HtmlReport','Report',
                          'OutputPath','FilePath','HtmlFile','MasterReport')) {
            $v = $Raw.$f
            if ($v -and $v.ToString().Trim() -ne '') { $rpath = $v.ToString().Trim(); break }
        }

        return [PSCustomObject]@{
            Hostname   = $hostname
            ScanDate   = $scanDate
            Score      = $score
            Grade      = $grade
            Risk       = $risk
            Technician = $tech
            Engines    = $engines
            Chains     = $chains
            ReportPath = $rpath
            SourceFile = $FilePath
        }
    }
    catch {
        Write-Host "    [ERROR] Failed parsing $([IO.Path]::GetFileName($FilePath)): $_" -ForegroundColor Red
        return $null
    }
}

# ==============================================================
# MACHINE IDENTITY -- Parse Master HTML for hardware details
# ==============================================================
function Get-MachineIdentity {
    param([string]$Hostname, [string]$ReportsDir, [string]$ReportPath)

    $id = [PSCustomObject]@{
        Manufacturer = 'N/A'
        Model        = 'N/A'
        Serial       = 'N/A'
        OS           = 'N/A'
        CPU          = 'N/A'
        RAM          = 'N/A'
        IPAddress    = 'N/A'
    }

    # Priority 1: explicit path from JSON record
    $htmlFile = $null
    if ($ReportPath -and (Test-Path $ReportPath)) { $htmlFile = $ReportPath }

    # Priority 2: FieldOps_Master_HOSTNAME_*.html in reports dir
    if (-not $htmlFile) {
        $hits = @(Get-ChildItem -Path $ReportsDir `
                    -Filter "FieldOps_Master_$Hostname`_*.html" `
                    -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime -Descending)
        if ($hits.Count -gt 0) { $htmlFile = $hits[0].FullName }
    }

    # Priority 3: any HTML in reports dir containing hostname in filename
    if (-not $htmlFile) {
        $hits = @(Get-ChildItem -Path $ReportsDir `
                    -Filter "*$Hostname*.html" `
                    -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime -Descending)
        if ($hits.Count -gt 0) { $htmlFile = $hits[0].FullName }
    }

    if (-not $htmlFile) { return $id }

    try {
        $html = Get-Content $htmlFile -Raw -ErrorAction SilentlyContinue
        if (-not $html) { return $id }

        # Label->value map: each array entry is a possible label text in the HTML
        $labelMap = [ordered]@{
            Manufacturer = @('Manufacturer','Make','Fabricant','Constructeur')
            Model        = @('Model','Modele','Product Name','Modele Produit')
            Serial       = @('Serial Number','Serial','S/N','No. Serie','Service Tag','ServiceTag')
            OS           = @('Operating System','OS','Systeme','OS Version','Windows Version')
            CPU          = @('Processor','CPU','Processeur','Processor Name')
            RAM          = @('RAM','Memory','Memoire','Total RAM','Physical Memory')
            IPAddress    = @('IP Address','IP','IPv4','Adresse IP','IP Addr')
        }

        foreach ($field in $labelMap.Keys) {
            foreach ($lbl in $labelMap[$field]) {
                # Match: <td...>LABEL</td> <td...>VALUE</td>
                $pat = "(?i)<td[^>]*>\s*$([regex]::Escape($lbl))\s*</td>\s*<td[^>]*>\s*([^<]{2,120}?)\s*</td>"
                if ($html -match $pat) {
                    $v = ($matches[1]).Trim()
                    if ($v -and $v -ne '' -and $v -ne 'N/A' -and
                        $v -ne 'Unknown' -and $v -ne '-') {
                        $id.$field = $v
                        break
                    }
                }
            }
        }
    }
    catch { }

    return $id
}

# ==============================================================
# PER-MACHINE RECOMMENDATION ENGINE
# ==============================================================
function Get-MachineRecommendations {
    param($Machine)

    $recs = [System.Collections.Generic.List[PSCustomObject]]::new()

    $score = $Machine.LatestScore
    $risk  = $Machine.Risk
    $trend = $Machine.Trend
    $delta = $Machine.TrendDelta
    $eng   = $Machine.LatestEngines  # hashtable

    # --- Trend deterioration ---
    if ($trend -eq 'Degrading') {
        $null = $recs.Add([PSCustomObject]@{
            Priority = 'HIGH'
            Category = 'Trend'
            Action   = "Health degraded $([math]::Abs($delta))% since last visit. Investigate: recent Windows Update side effects, driver regression, hardware wear, or GPO/Intune policy drift."
        })
    }

    # --- Overall risk escalation ---
    if ($risk -eq 'CRITICAL') {
        $null = $recs.Add([PSCustomObject]@{
            Priority = 'CRITICAL'
            Category = 'Escalation'
            Action   = "CRITICAL machine at $score%. Schedule emergency maintenance within 24 hours. Notify team lead. Do not wait for next field cycle."
        })
    } elseif ($risk -eq 'HIGH') {
        $null = $recs.Add([PSCustomObject]@{
            Priority = 'HIGH'
            Category = 'Escalation'
            Action   = "HIGH risk at $score%. Schedule maintenance this week. Prioritize over routine visits."
        })
    } elseif ($risk -eq 'MEDIUM') {
        $null = $recs.Add([PSCustomObject]@{
            Priority = 'MEDIUM'
            Category = 'Escalation'
            Action   = "MEDIUM risk at $score%. Schedule maintenance within 2 weeks."
        })
    }

    # --- PCHealth ---
    $phS = $eng['PCHealth']
    if ($null -ne $phS) {
        if ($phS -lt 60) {
            $null = $recs.Add([PSCustomObject]@{
                Priority = 'CRITICAL'; Category = 'Hardware'
                Action   = "PCHealth $phS%: Critical hardware state. Boot Memtest86+ from USB for RAM diagnostics. Check all SMART attributes via CrystalDiskInfo. Inspect thermals -- use HWiNFO for temp logs. Review Windows Event Log for hardware errors (Kernel-PnP, disk, memory)."
            })
        } elseif ($phS -lt 75) {
            $null = $recs.Add([PSCustomObject]@{
                Priority = 'HIGH'; Category = 'Hardware'
                Action   = "PCHealth $phS%: Hardware issues present. Review failing PCHealth checks specifically. Update chipset/firmware drivers. Run SMART short self-test. Check RAM seating if access available."
            })
        } elseif ($phS -lt 88) {
            $null = $recs.Add([PSCustomObject]@{
                Priority = 'MEDIUM'; Category = 'Hardware'
                Action   = "PCHealth $phS%: Minor hardware anomalies. Monitor on next visit. Run extended SMART test proactively."
            })
        }
    }

    # --- SecurityScan ---
    $ssS = $eng['SecurityScan']
    if ($null -ne $ssS) {
        if ($ssS -lt 65) {
            $null = $recs.Add([PSCustomObject]@{
                Priority = 'CRITICAL'; Category = 'Security'
                Action   = "SecurityScan $ssS%: Critical security posture. Immediately verify: (1) BitLocker encryption status, (2) Windows Defender service state and definition age, (3) Windows Firewall profile states, (4) CIS Level 1 benchmark gaps. Consider isolating from corporate network until remediated."
            })
        } elseif ($ssS -lt 75) {
            $null = $recs.Add([PSCustomObject]@{
                Priority = 'HIGH'; Category = 'Security'
                Action   = "SecurityScan $ssS%: Significant CIS baseline gaps. Address in priority order: BitLocker status, Defender definitions, account lockout policy (max 5 attempts), audit log configuration, and UAC settings."
            })
        } elseif ($ssS -lt 85) {
            $null = $recs.Add([PSCustomObject]@{
                Priority = 'MEDIUM'; Category = 'Security'
                Action   = "SecurityScan $ssS%: Several CIS controls unmet. Review: software restriction policies, screensaver lock timeout (<=15 min), NTP configuration, and local admin account state."
            })
        } elseif ($ssS -lt 92) {
            $null = $recs.Add([PSCustomObject]@{
                Priority = 'LOW'; Category = 'Security'
                Action   = "SecurityScan $ssS%: Minor CIS gaps remain. Fine-tune remaining controls on next scheduled visit."
            })
        }
    }

    # --- AzureADJoin ---
    $aadS = $eng['AzureADJoin']
    if ($null -ne $aadS) {
        if ($aadS -lt 65) {
            $null = $recs.Add([PSCustomObject]@{
                Priority = 'HIGH'; Category = 'Identity'
                Action   = "AzureADJoin $aadS%: Significant Azure AD / Intune issues. Check: dsregcmd /status for join state, Intune enrollment in Settings > Access work, certificate chain validity, GlobalProtect VPN connectivity. Re-join if dsregcmd shows AzureAdJoined: NO."
            })
        } elseif ($aadS -lt 80) {
            $null = $recs.Add([PSCustomObject]@{
                Priority = 'MEDIUM'; Category = 'Identity'
                Action   = "AzureADJoin $aadS%: Identity/MDM gaps. Sync Intune policies (Settings > Accounts > Access work > Sync). Check device compliance status in Azure AD portal. Verify co-management workloads."
            })
        }
    }

    # --- NetworkRepair ---
    $netS = $eng['NetworkRepair']
    if ($null -ne $netS) {
        if ($netS -lt 65) {
            $null = $recs.Add([PSCustomObject]@{
                Priority = 'HIGH'; Category = 'Network'
                Action   = "NetworkRepair $netS%: Serious network issues. Run: netsh int ip reset, netsh winsock reset, ipconfig /flushdns. Check GlobalProtect VPN gateway. Update NIC drivers. Review DNS suffix search list and WINS configuration."
            })
        } elseif ($netS -lt 80) {
            $null = $recs.Add([PSCustomObject]@{
                Priority = 'MEDIUM'; Category = 'Network'
                Action   = "NetworkRepair $netS%: Network instability. Review: DNS server config (must resolve internal corp domains), proxy settings, VPN split-tunnel rules, NIC adapter power management (disable 'Allow the computer to turn off this device to save power')."
            })
        }
    }

    # --- DiskAnalysis ---
    $dskS = $eng['DiskAnalysis']
    if ($null -ne $dskS) {
        if ($dskS -lt 70) {
            $null = $recs.Add([PSCustomObject]@{
                Priority = 'HIGH'; Category = 'Storage'
                Action   = "DiskAnalysis $dskS%: Disk health concern. Check SMART reallocated sector count and pending sectors. Run chkdsk /scan. For SSD: check wear level percentage. Consider proactive drive replacement if wear level <20% or reallocated sectors >50."
            })
        } elseif ($dskS -lt 85) {
            $null = $recs.Add([PSCustomObject]@{
                Priority = 'MEDIUM'; Category = 'Storage'
                Action   = "DiskAnalysis $dskS%: Storage suboptimal. Review free space (minimum 15% recommended), clean temp files, check fragmentation (HDD only). Verify SMART attributes for early wear indicators."
            })
        }
    }

    # --- VPNSetup ---
    $vpnS = $eng['VPNSetup']
    if ($null -ne $vpnS) {
        if ($vpnS -lt 70) {
            $null = $recs.Add([PSCustomObject]@{
                Priority = 'MEDIUM'; Category = 'VPN'
                Action   = "VPNSetup $vpnS%: GlobalProtect VPN configuration issues. Verify gateway URL, re-run VPN installer from USB, check certificate trust chain, confirm user is licensed for GlobalProtect in Prisma Access."
            })
        }
    }

    # --- First scan baseline ---
    if ($Machine.ScanCount -eq 1) {
        $null = $recs.Add([PSCustomObject]@{
            Priority = 'INFO'; Category = 'Baseline'
            Action   = "First scan recorded. Run follow-up scan within 30 days to establish trend data. No trend analysis possible until 2+ scans exist."
        })
    }

    # --- Specific findings from risk chains ---
    $chainArr = @($Machine.LatestChains)
    if ($chainArr.Count -gt 0) {
        $summary = ($chainArr | Select-Object -First 3) -join ' | '
        $null = $recs.Add([PSCustomObject]@{
            Priority = 'MEDIUM'; Category = 'Findings'
            Action   = "Engine findings from last scan: $summary$(if ($chainArr.Count -gt 3) { " (+ $($chainArr.Count - 3) more)" } else { '' })"
        })
    }

    # --- All clear ---
    if ($recs.Count -eq 0) {
        $null = $recs.Add([PSCustomObject]@{
            Priority = 'OK'; Category = 'Overall'
            Action   = "All engines within acceptable thresholds. Machine is healthy. Maintain current scan schedule."
        })
    }

    return $recs.ToArray()
}

# ==============================================================
# FLEET-WIDE RECOMMENDATION ENGINE
# ==============================================================
function Get-FleetRecommendations {
    param($Stats, $Machines)

    $recs     = [System.Collections.Generic.List[PSCustomObject]]::new()
    $machArr  = @($Machines)
    $total    = $Stats.TotalMachines

    # Critical machines
    if ($Stats.CriticalCount -gt 0) {
        $cNames = (@($machArr | Where-Object { $_.Risk -eq 'CRITICAL' } |
                     Select-Object -First 3 -ExpandProperty Hostname)) -join ', '
        $null = $recs.Add([PSCustomObject]@{
            Priority = 'CRITICAL'
            Action   = "$($Stats.CriticalCount) CRITICAL machine(s) require immediate field visit: $cNames. Escalate to team lead. Do not wait for next scheduled cycle."
        })
    }

    # High risk count
    if ($Stats.HighRiskCount -gt 0) {
        $hNames = (@($machArr | Where-Object { $_.Risk -eq 'HIGH' } |
                     Select-Object -First 3 -ExpandProperty Hostname)) -join ', '
        $null = $recs.Add([PSCustomObject]@{
            Priority = 'HIGH'
            Action   = "$($Stats.HighRiskCount) HIGH-risk machine(s) need maintenance this week: $hNames. Add to priority field schedule."
        })
    }

    # Degrading trend -- systemic if 2+ or >25% of fleet
    $degPct = 0
    if ($total -gt 0) { $degPct = [math]::Round(($Stats.DegradingCount / $total) * 100) }
    if ($Stats.DegradingCount -ge 2 -or $degPct -ge 25) {
        $null = $recs.Add([PSCustomObject]@{
            Priority = 'HIGH'
            Action   = "$($Stats.DegradingCount) machines ($degPct% of fleet) are degrading health-over-time. Investigate systemic cause: recent Windows Update batch, Intune policy change, or hardware aging cohort. Pull update history from WSUS or Intune."
        })
    }

    # Compliance rate
    if ($Stats.ComplianceRate -lt 70) {
        $null = $recs.Add([PSCustomObject]@{
            Priority = 'HIGH'
            Action   = "Only $($Stats.ComplianceRate)% of fleet meets the B-grade compliance threshold. Escalate fleet health report to management. Request emergency maintenance budget and accelerated field cycle."
        })
    } elseif ($Stats.ComplianceRate -lt 85) {
        $null = $recs.Add([PSCustomObject]@{
            Priority = 'MEDIUM'
            Action   = "$($Stats.ComplianceRate)% fleet compliance (B-grade threshold). Review and remediate at-risk machines before next audit cycle. Target: >90%."
        })
    }

    # Systemic engine weaknesses (fleet averages)
    $avgEng = $Stats.AvgEngineScores
    if ($avgEng.ContainsKey('SecurityScan')) {
        $s = $avgEng['SecurityScan']
        if ($s -lt 75) {
            $null = $recs.Add([PSCustomObject]@{
                Priority = 'HIGH'
                Action   = "Fleet SecurityScan average $s% -- this is a policy-level problem, not per-machine. Review: Intune security baseline profile deployment, Azure AD Conditional Access enforcement, Defender for Endpoint onboarding status, and BitLocker policy scope."
            })
        } elseif ($s -lt 85) {
            $null = $recs.Add([PSCustomObject]@{
                Priority = 'MEDIUM'
                Action   = "Fleet SecurityScan average $s%. Tighten CIS baseline via Intune configuration profiles. Focus on account lockout policies, audit settings, and screensaver lock enforcement."
            })
        }
    }

    if ($avgEng.ContainsKey('PCHealth')) {
        $s = $avgEng['PCHealth']
        if ($s -lt 75) {
            $null = $recs.Add([PSCustomObject]@{
                Priority = 'HIGH'
                Action   = "Fleet PCHealth average $s% -- systemic hardware concern. Audit device age and warranty status across fleet. Identify if degradation correlates with specific device model or purchase cohort. Consider hardware refresh proposal."
            })
        }
    }

    if ($avgEng.ContainsKey('AzureADJoin')) {
        $s = $avgEng['AzureADJoin']
        if ($s -lt 80) {
            $null = $recs.Add([PSCustomObject]@{
                Priority = 'MEDIUM'
                Action   = "Fleet AzureADJoin average $s%. MDM enrollment health issue across multiple machines. Check Intune Device Enrollment > Enrollment failures report in Azure portal. Verify certificate authority chain is trusted on all machines."
            })
        }
    }

    if ($avgEng.ContainsKey('NetworkRepair')) {
        $s = $avgEng['NetworkRepair']
        if ($s -lt 78) {
            $null = $recs.Add([PSCustomObject]@{
                Priority = 'MEDIUM'
                Action   = "Fleet NetworkRepair average $s%. Network instability across multiple machines. Review GlobalProtect gateway configuration, DNS suffix search list in DHCP, and NIC driver version consistency across device models."
            })
        }
    }

    # Scan frequency
    if ($Stats.AvgScansPerHost -lt 2) {
        $null = $recs.Add([PSCustomObject]@{
            Priority = 'INFO'
            Action   = "Average scan frequency: $($Stats.AvgScansPerHost) scans/machine. Insufficient data for reliable trend analysis. Target minimum 2 scans/machine/month to detect degradation patterns early."
        })
    }

    # Stale fleet data
    $daysSince = [math]::Round(($NOW - $Stats.LastScanDate).TotalDays)
    if ($daysSince -gt 30) {
        $null = $recs.Add([PSCustomObject]@{
            Priority = 'MEDIUM'
            Action   = "Last fleet scan was $daysSince days ago. Schedule comprehensive field sweep to refresh machine baselines. Machines may have drifted from last known state."
        })
    }

    if ($recs.Count -eq 0) {
        $null = $recs.Add([PSCustomObject]@{
            Priority = 'OK'
            Action   = "Fleet is in good health across all dimensions. Maintain current field schedule and scan frequency. Run weekly fleet reports to catch early degradation trends."
        })
    }

    return $recs.ToArray()
}

# ==============================================================
# FLEET STATISTICS AGGREGATION
# ==============================================================
function Build-FleetStats {
    param($Machines)

    $machArr     = @($Machines)
    $totalScans  = 0
    $scores      = [System.Collections.Generic.List[int]]::new()
    $risk        = @{ CRITICAL=0; HIGH=0; MEDIUM=0; LOW=0; MINIMAL=0 }
    $trends      = @{ Improving=0; Stable=0; Degrading=0 }
    $engTotals   = @{}
    $engCounts   = @{}
    $compliance  = 0          # machines >= 80% (B-)
    $secCompliant = 0         # SecurityScan >= 80%
    $aadCompliant = 0         # AzureADJoin >= 80%
    $hwCompliant  = 0         # PCHealth >= 80%
    $lastScan    = [datetime]::MinValue

    foreach ($m in $machArr) {
        $totalScans += $m.ScanCount
        if ($m.LatestScore -gt 0) { $null = $scores.Add($m.LatestScore) }
        if ($risk.ContainsKey($m.Risk))   { $risk[$m.Risk]++ }
        if ($trends.ContainsKey($m.Trend)){ $trends[$m.Trend]++ }
        if ($m.LatestScore -ge 80)        { $compliance++ }
        if ($m.LastSeen -gt $lastScan)    { $lastScan = $m.LastSeen }

        $e = $m.LatestEngines
        if ($e['SecurityScan'] -and $e['SecurityScan'] -ge 80) { $secCompliant++ }
        if ($e['AzureADJoin']  -and $e['AzureADJoin']  -ge 80) { $aadCompliant++ }
        if ($e['PCHealth']     -and $e['PCHealth']     -ge 80) { $hwCompliant++ }

        foreach ($en in @($e.Keys)) {
            if (-not $engTotals.ContainsKey($en)) { $engTotals[$en] = 0; $engCounts[$en] = 0 }
            $engTotals[$en] += $e[$en]
            $engCounts[$en]++
        }
    }

    $scoreArr = @($scores)
    $avgScore = 0
    $avgGrade = 'N/A'
    if ($scoreArr.Count -gt 0) {
        $avgScore = [math]::Round(($scoreArr | Measure-Object -Sum).Sum / $scoreArr.Count)
        $avgGrade = Get-GradeFromScore $avgScore
    }

    $avgEngScores = @{}
    foreach ($en in @($engTotals.Keys)) {
        $avgEngScores[$en] = [math]::Round($engTotals[$en] / $engCounts[$en])
    }

    $machCount = $machArr.Count
    $compRate   = if ($machCount -gt 0) { [math]::Round(($compliance   / $machCount) * 100) } else { 0 }
    $secRate    = if ($machCount -gt 0) { [math]::Round(($secCompliant / $machCount) * 100) } else { 0 }
    $aadRate    = if ($machCount -gt 0) { [math]::Round(($aadCompliant / $machCount) * 100) } else { 0 }
    $hwRate     = if ($machCount -gt 0) { [math]::Round(($hwCompliant  / $machCount) * 100) } else { 0 }

    $avgSPH = if ($machCount -gt 0) { [math]::Round($totalScans / $machCount, 1) } else { 0 }

    return [PSCustomObject]@{
        TotalMachines    = $machCount
        TotalScans       = $totalScans
        AvgScore         = $avgScore
        AvgGrade         = $avgGrade
        RiskBuckets      = $risk
        CriticalCount    = $risk['CRITICAL']
        HighRiskCount    = $risk['HIGH']
        MediumCount      = $risk['MEDIUM']
        LowCount         = $risk['LOW']
        MinimalCount     = $risk['MINIMAL']
        ImprovingCount   = $trends['Improving']
        StableCount      = $trends['Stable']
        DegradingCount   = $trends['Degrading']
        AvgEngineScores  = $avgEngScores
        ComplianceRate   = $compRate
        SecCompliance    = $secRate
        AadCompliance    = $aadRate
        HwCompliance     = $hwRate
        AvgScansPerHost  = $avgSPH
        LastScanDate     = if ($lastScan -eq [datetime]::MinValue) { $NOW } else { $lastScan }
    }
}

# ==============================================================
# GRADE DISTRIBUTION
# ==============================================================
function Get-GradeDistribution {
    param($Machines)
    $order = @('A+','A','A-','B+','B','B-','C+','C','C-','D+','D','D-','F')
    $dist  = [ordered]@{}
    foreach ($g in $order) { $dist[$g] = 0 }
    foreach ($m in @($Machines)) {
        if ($dist.Contains($m.Grade)) { $dist[$m.Grade]++ }
        else { $dist['F']++ }
    }
    return $dist
}

# ==============================================================
# SVG DONUT CHART
# ==============================================================
function New-DonutSvg {
    param($Segments)   # array of [PSCustomObject]@{Label;Value;Color}

    $total = 0
    foreach ($s in @($Segments)) { $total += $s.Value }
    if ($total -eq 0) { return '<p style="color:#64748b;padding:20px">No data for this period.</p>' }

    $cx = 100; $cy = 100; $r = 80; $ir = 50
    $sb = [System.Text.StringBuilder]::new()
    $null = $sb.Append('<svg width="200" height="200" viewBox="0 0 200 200">')

    $startDeg = -90.0
    foreach ($seg in @($Segments)) {
        if ($seg.Value -eq 0) { continue }
        $sweep  = ($seg.Value / $total) * 360.0
        $endDeg = $startDeg + $sweep
        $large  = if ($sweep -gt 180) { 1 } else { 0 }

        $x1  = [math]::Round($cx + $r  * [math]::Cos($startDeg * [math]::PI / 180), 2)
        $y1  = [math]::Round($cy + $r  * [math]::Sin($startDeg * [math]::PI / 180), 2)
        $x2  = [math]::Round($cx + $r  * [math]::Cos($endDeg   * [math]::PI / 180), 2)
        $y2  = [math]::Round($cy + $r  * [math]::Sin($endDeg   * [math]::PI / 180), 2)
        $xi1 = [math]::Round($cx + $ir * [math]::Cos($startDeg * [math]::PI / 180), 2)
        $yi1 = [math]::Round($cy + $ir * [math]::Sin($startDeg * [math]::PI / 180), 2)
        $xi2 = [math]::Round($cx + $ir * [math]::Cos($endDeg   * [math]::PI / 180), 2)
        $yi2 = [math]::Round($cy + $ir * [math]::Sin($endDeg   * [math]::PI / 180), 2)

        $d = "M $x1 $y1 A $r $r 0 $large 1 $x2 $y2 L $xi2 $yi2 A $ir $ir 0 $large 0 $xi1 $yi1 Z"
        $null = $sb.Append("<path d=""$d"" fill=""$($seg.Color)""/>")
        $startDeg = $endDeg
    }

    # Center hole + labels
    $null = $sb.Append("<circle cx=""$cx"" cy=""$cy"" r=""$ir"" fill=""#1e293b""/>")
    $null = $sb.Append("<text x=""$cx"" y=""$($cy - 8)"" text-anchor=""middle"" fill=""#e2e8f0"" font-size=""20"" font-weight=""bold"" font-family=""Consolas,monospace"">$total</text>")
    $null = $sb.Append("<text x=""$cx"" y=""$($cy + 10)"" text-anchor=""middle"" fill=""#94a3b8"" font-size=""10"" font-family=""Consolas,monospace"">machines</text>")
    $null = $sb.Append('</svg>')
    return $sb.ToString()
}

# ==============================================================
# HTML ENGINE BAR ROW
# ==============================================================
function New-EngineBarHtml {
    param([string]$Name, [int]$Score)
    $color = Get-EngineHex $Score
    $pct   = [math]::Min($Score, 100)
    return @"
<div class="engine-row">
  <div class="engine-name">$Name</div>
  <div class="engine-bar-wrap"><div class="engine-bar-fill" style="width:$(${pct})%;background:$color;"></div></div>
  <div class="engine-pct" style="color:$color">$Score%</div>
</div>
"@
}

# ==============================================================
# HTML REPORT GENERATOR
# ==============================================================
function New-HtmlReport {
    param($Machines, $Stats, $FleetRecs, $GradeDist)

    $machArr = @($Machines | Sort-Object LatestScore)
    $genTime = $NOW.ToString('yyyy-MM-dd HH:mm:ss')
    $avgColor= Get-GradeHex $Stats.AvgGrade

    # ---- KPI Cards ----
    $kpiHtml = ''
    $kpiDefs = @(
        @{ V = "$($Stats.AvgGrade)"; Sub="$($Stats.AvgScore)%"; L="Fleet Avg Grade"; C=$avgColor },
        @{ V = "$($Stats.TotalMachines)"; Sub="unique hosts"; L="Machines"; C='#38bdf8' },
        @{ V = "$($Stats.TotalScans)"; Sub="scan records"; L="Total Scans"; C='#818cf8' },
        @{ V = "$($Stats.CriticalCount + $Stats.HighRiskCount)"; Sub="CRIT + HIGH"; L="High Risk"; C='#ef4444' },
        @{ V = "$($Stats.DegradingCount)"; Sub="vs prior scan"; L="Degrading"; C='#f97316' },
        @{ V = "$($Stats.ImprovingCount)"; Sub="vs prior scan"; L="Improving"; C='#22c55e' },
        @{ V = "$($Stats.ComplianceRate)%"; Sub="B-grade (80%+)"; L="Compliant"; C= if ($Stats.ComplianceRate -ge 85) { '#22c55e' } elseif ($Stats.ComplianceRate -ge 70) { '#eab308' } else { '#ef4444' } },
        @{ V = "$($Stats.AvgScansPerHost)"; Sub="per machine"; L="Avg Scans"; C='#94a3b8' }
    )
    foreach ($k in $kpiDefs) {
        $kpiHtml += @"
<div class="kpi-card">
  <div class="kpi-value" style="color:$($k.C)">$($k.V)</div>
  <div class="kpi-sub">$($k.Sub)</div>
  <div class="kpi-label">$($k.L)</div>
</div>
"@
    }

    # ---- Risk Donut ----
    $donutSegs = @(
        [PSCustomObject]@{ Label='CRITICAL'; Value=$Stats.CriticalCount; Color='#ef4444' },
        [PSCustomObject]@{ Label='HIGH';     Value=$Stats.HighRiskCount;  Color='#f97316' },
        [PSCustomObject]@{ Label='MEDIUM';   Value=$Stats.MediumCount;    Color='#eab308' },
        [PSCustomObject]@{ Label='LOW';      Value=$Stats.LowCount;       Color='#84cc16' },
        [PSCustomObject]@{ Label='MINIMAL';  Value=$Stats.MinimalCount;   Color='#22c55e' }
    )
    $donutSvg   = New-DonutSvg $donutSegs
    $donutLegend = ''
    foreach ($seg in $donutSegs) {
        $pct = if ($Stats.TotalMachines -gt 0) { [math]::Round(($seg.Value / $Stats.TotalMachines) * 100) } else { 0 }
        $donutLegend += "<div class='legend-row'><span class='legend-dot' style='background:$($seg.Color)'></span><span class='legend-lbl'>$($seg.Label)</span><span class='legend-val'>$($seg.Value) ($pct%)</span></div>"
    }

    # ---- Engine Averages ----
    $engHtml = ''
    $engOrder = @('PCHealth','SecurityScan','AzureADJoin','NetworkRepair','DiskAnalysis','VPNSetup','SoftwareDeploy')
    foreach ($en in $engOrder) {
        if ($Stats.AvgEngineScores.ContainsKey($en)) {
            $engHtml += New-EngineBarHtml $en $Stats.AvgEngineScores[$en]
        }
    }
    if ($engHtml -eq '') { $engHtml = '<p style="color:#64748b">No engine score data available.</p>' }

    # ---- Grade Distribution ----
    $maxGradeCount = 0
    foreach ($g in @($GradeDist.Values)) { if ($g -gt $maxGradeCount) { $maxGradeCount = $g } }
    $gradeHtml = ''
    foreach ($g in @($GradeDist.Keys)) {
        $cnt   = $GradeDist[$g]
        $color = Get-GradeHex $g
        $wpct  = if ($maxGradeCount -gt 0) { [math]::Round(($cnt / $maxGradeCount) * 100) } else { 0 }
        $gradeHtml += @"
<div class="grade-row">
  <div class="grade-label" style="color:$color">$g</div>
  <div class="grade-bar-wrap"><div class="grade-bar-fill" style="width:$(${wpct})%;background:$color;"></div></div>
  <div class="grade-count">$cnt</div>
</div>
"@
    }

    # ---- Compliance Baseline ----
    $compItems = @(
        @{ Rate=$Stats.ComplianceRate;   Label="Overall (B-grade)";  Sub="Score >= 80%" },
        @{ Rate=$Stats.HwCompliance;     Label="Hardware (PCHealth)"; Sub="Score >= 80%" },
        @{ Rate=$Stats.SecCompliance;    Label="Security";            Sub="SecurityScan >= 80%" },
        @{ Rate=$Stats.AadCompliance;    Label="Identity";            Sub="AzureADJoin >= 80%" }
    )
    $compHtml = ''
    foreach ($ci in $compItems) {
        $col = if ($ci.Rate -ge 85) { '#22c55e' } elseif ($ci.Rate -ge 70) { '#eab308' } else { '#ef4444' }
        $barW = $ci.Rate
        $compHtml += @"
<div class="comp-item">
  <div class="comp-pct" style="color:$col">$($ci.Rate)%</div>
  <div class="bar-wrap" style="margin:8px 0"><div class="bar-fill" style="width:$(${barW})%;background:$col;height:6px;border-radius:3px;"></div></div>
  <div class="comp-label">$($ci.Label)</div>
  <div style="font-size:10px;color:#475569;margin-top:2px">$($ci.Sub)</div>
</div>
"@
    }

    # ---- Machine Inventory Table ----
    $invHtml = ''
    $rowNum  = 0
    $invSorted = @($machArr | Sort-Object LatestScore)
    foreach ($m in $invSorted) {
        $rowNum++
        $gColor = Get-GradeHex $m.Grade
        $rColor = Get-RiskHex $m.Risk
        $tArrow = switch ($m.Trend) {
            'Improving' { '<span style="color:#22c55e">&#8599; +' + $m.TrendDelta + '%</span>' }
            'Degrading' { '<span style="color:#ef4444">&#8600; ' + $m.TrendDelta + '%</span>' }
            default     { '<span style="color:#64748b">&#8594; 0%</span>' }
        }
        $rLink = if ($m.ReportPath -and (Test-Path $m.ReportPath)) {
            "<a href=""file:///$($m.ReportPath.Replace('\','/'))$"" style=""color:#38bdf8;text-decoration:none"" title=""Open Master Report"">$($m.Hostname)</a>"
        } else { $m.Hostname }

        $topRec  = @($m.Recommendations | Where-Object { $_.Priority -ne 'OK' } | Select-Object -First 1)
        $recBadge = if ($topRec.Count -gt 0) {
            $c = Get-PriorityHex $topRec[0].Priority
            "<span class='badge' style='background:$(${c})22;color:$c;border:1px solid $c'>$($topRec[0].Priority)</span>"
        } else {
            "<span class='badge' style='background:#22c55e22;color:#22c55e;border:1px solid #22c55e'>HEALTHY</span>"
        }

        $invHtml += @"
<tr>
  <td style="color:#475569;width:30px">$rowNum</td>
  <td><strong>$rLink</strong></td>
  <td style="color:#94a3b8">$($m.Manufacturer)</td>
  <td style="color:#cbd5e1">$($m.Model)</td>
  <td style="color:#64748b;font-size:11px">$($m.Serial)</td>
  <td style="color:#64748b;font-size:11px;max-width:140px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title="$($m.OS)">$($m.OS)</td>
  <td><span class="badge" style="background:$(${gColor})22;color:$gColor;border:1px solid $gColor">$($m.Grade)</span></td>
  <td style="color:$gColor;font-weight:bold">$($m.LatestScore)%</td>
  <td><span class="badge" style="background:$(${rColor})22;color:$rColor;border:1px solid $rColor">$($m.Risk)</span></td>
  <td>$tArrow</td>
  <td style="color:#94a3b8">$($m.ScanCount)</td>
  <td style="color:#64748b;font-size:11px">$($m.LastSeen.ToString('yyyy-MM-dd'))</td>
  <td>$recBadge</td>
</tr>
"@
    }

    # ---- Per-Machine Recommendation Cards ----
    $recCardsHtml = ''
    $recMachines  = @($machArr | Sort-Object LatestScore | Select-Object -First 20)
    foreach ($m in $recMachines) {
        $rColor    = Get-RiskHex $m.Risk
        $gColor    = Get-GradeHex $m.Grade
        $recCount  = @($m.Recommendations).Count
        $hasIssues = @($m.Recommendations | Where-Object { $_.Priority -notin @('OK','INFO') }).Count -gt 0
        $openAttr  = if ($m.Risk -in @('CRITICAL','HIGH')) { ' open' } else { '' }

        $recItemsHtml = ''
        foreach ($rec in @($m.Recommendations)) {
            $pColor = Get-PriorityHex $rec.Priority
            $recItemsHtml += @"
<div class="rec-item" style="background:$(${pColor})11;border-left-color:$pColor;color:#cbd5e1">
  <span class="badge" style="background:$(${pColor})33;color:$pColor;margin-right:8px;font-size:10px">$($rec.Priority)</span>
  <span style="color:#64748b;font-size:11px;margin-right:6px">[$($rec.Category)]</span>
  $($rec.Action)
</div>
"@
        }

        $engBarsHtml = ''
        foreach ($en in $engOrder) {
            if ($m.LatestEngines.ContainsKey($en)) {
                $es    = $m.LatestEngines[$en]
                $ec    = Get-EngineHex $es
                $epct  = [math]::Min($es, 100)
                $engBarsHtml += @"
<div style="display:flex;align-items:center;gap:8px;margin-bottom:5px">
  <span style="width:110px;font-size:11px;color:#64748b">$en</span>
  <div style="flex:1;background:#0f172a;border-radius:3px;height:8px"><div style="width:$(${epct})%;height:8px;border-radius:3px;background:$ec"></div></div>
  <span style="width:36px;text-align:right;font-size:12px;color:$ec;font-weight:bold">$es%</span>
</div>
"@
            }
        }

        $techs = (@($m.Technicians) -join ', ')

        $recCardsHtml += @"
<details$openAttr style="margin-bottom:10px;background:#1e293b;border:1px solid #334155;border-left:3px solid $rColor;border-radius:8px">
  <summary style="padding:14px 16px;cursor:pointer;list-style:none;display:flex;align-items:center;gap:12px">
    <span style="font-weight:bold;color:#e2e8f0;min-width:140px">$($m.Hostname)</span>
    <span class="badge" style="background:$(${gColor})22;color:$gColor;border:1px solid $gColor">$($m.Grade) $($m.LatestScore)%</span>
    <span class="badge" style="background:$(${rColor})22;color:$rColor;border:1px solid $rColor">$($m.Risk)</span>
    <span style="color:#64748b;font-size:12px">$($m.Manufacturer) $($m.Model)</span>
    <span style="margin-left:auto;color:#475569;font-size:12px">$recCount action(s)</span>
  </summary>
  <div style="padding:0 16px 16px">
    <div style="display:grid;grid-template-columns:1fr 1fr;gap:16px;margin-bottom:12px;padding:12px;background:#0f172a;border-radius:6px;font-size:12px;color:#64748b">
      <div><strong style="color:#94a3b8">Serial:</strong> $($m.Serial)</div>
      <div><strong style="color:#94a3b8">OS:</strong> $($m.OS)</div>
      <div><strong style="color:#94a3b8">CPU:</strong> $($m.CPU)</div>
      <div><strong style="color:#94a3b8">RAM:</strong> $($m.RAM)</div>
      <div><strong style="color:#94a3b8">IP:</strong> $($m.IPAddress)</div>
      <div><strong style="color:#94a3b8">Technician(s):</strong> $techs</div>
      <div><strong style="color:#94a3b8">Scans:</strong> $($m.ScanCount) | Last: $($m.LastSeen.ToString('yyyy-MM-dd'))</div>
      <div><strong style="color:#94a3b8">Trend:</strong> $(if ($m.Trend -eq 'Improving') { '<span style="color:#22c55e">&#8599; Improving</span>' } elseif ($m.Trend -eq 'Degrading') { '<span style="color:#ef4444">&#8600; Degrading</span>' } else { '<span style="color:#64748b">&#8594; Stable</span>' })</div>
    </div>
    $(if ($engBarsHtml) { "<div style='margin-bottom:12px;padding:12px;background:#0f172a;border-radius:6px'><div style='font-size:11px;color:#475569;margin-bottom:8px;text-transform:uppercase;letter-spacing:1px'>Engine Scores</div>$engBarsHtml</div>" })
    <div style="font-size:11px;color:#475569;margin-bottom:8px;text-transform:uppercase;letter-spacing:1px">Recommended Actions</div>
    $recItemsHtml
  </div>
</details>
"@
    }

    # ---- Fleet Recommendations ----
    $fleetRecHtml = ''
    foreach ($fr in @($FleetRecs)) {
        $fc = Get-PriorityHex $fr.Priority
        $fleetRecHtml += @"
<div class="fleet-rec" style="background:$(${fc})11;border-left-color:$fc;color:#cbd5e1">
  <span class="badge" style="background:$(${fc})33;color:$fc;margin-right:10px">$($fr.Priority)</span>
  $($fr.Action)
</div>
"@
    }

    # ---- Technician Breakdown ----
    $techTable = @{}
    foreach ($m in @($Machines)) {
        foreach ($t in @($m.Technicians)) {
            if (-not $techTable.ContainsKey($t)) { $techTable[$t] = @{ Scans=0; Machines=0 } }
            $techTable[$t].Scans    += $m.ScanCount
            $techTable[$t].Machines += 1
        }
    }
    $techHtml = ''
    foreach ($t in ($techTable.Keys | Sort-Object)) {
        $td = $techTable[$t]
        $techHtml += "<tr><td>$t</td><td style='color:#38bdf8'>$($td.Machines)</td><td style='color:#94a3b8'>$($td.Scans)</td><td style='color:#64748b'>$(if ($td.Machines -gt 0) { [math]::Round($td.Scans / $td.Machines, 1) } else { 0 })</td></tr>"
    }

    # ---- Full HTML Assembly ----
    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>FieldOps Pro Fleet Report -- $($NOW.ToString('yyyy-MM-dd'))</title>
<style>
:root {
  --bg:#0f172a; --card:#1e293b; --border:#334155;
  --text:#e2e8f0; --muted:#94a3b8; --accent:#38bdf8;
}
* { box-sizing:border-box; margin:0; padding:0; }
body { background:var(--bg); color:var(--text); font-family:'Consolas','Courier New',monospace; padding:24px; }
.header { text-align:center; padding:32px 0 24px; border-bottom:2px solid var(--accent); margin-bottom:32px; }
.header h1 { font-size:22px; color:var(--accent); letter-spacing:3px; }
.header .org { font-size:14px; color:#64748b; margin-top:4px; }
.header .meta { font-size:12px; color:var(--muted); margin-top:8px; display:flex; justify-content:center; gap:24px; flex-wrap:wrap; }
.header .meta span { background:#1e293b; border:1px solid #334155; padding:4px 12px; border-radius:4px; }
.kpi-grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(150px,1fr)); gap:12px; margin-bottom:32px; }
.kpi-card { background:var(--card); border:1px solid var(--border); border-radius:8px; padding:16px; text-align:center; }
.kpi-value { font-size:26px; font-weight:bold; }
.kpi-sub { font-size:10px; color:#64748b; margin-top:2px; }
.kpi-label { font-size:10px; color:var(--muted); margin-top:6px; text-transform:uppercase; letter-spacing:1px; }
.section-title { font-size:13px; color:var(--accent); border-bottom:1px solid var(--border); padding-bottom:8px; margin:32px 0 16px; letter-spacing:2px; text-transform:uppercase; }
.two-col { display:grid; grid-template-columns:auto 1fr; gap:24px; margin-bottom:24px; }
.card { background:var(--card); border:1px solid var(--border); border-radius:8px; padding:20px; }
.card-title { font-size:11px; color:var(--muted); text-transform:uppercase; letter-spacing:1px; margin-bottom:14px; }
.donut-wrap { display:flex; align-items:center; gap:24px; flex-wrap:wrap; }
.legend-row { display:flex; align-items:center; gap:8px; margin-bottom:7px; font-size:12px; }
.legend-dot { width:12px; height:12px; border-radius:50%; flex-shrink:0; }
.legend-lbl { color:var(--muted); width:70px; }
.legend-val { color:var(--text); }
.engine-row { display:flex; align-items:center; gap:10px; margin-bottom:10px; }
.engine-name { width:120px; font-size:11px; color:var(--muted); flex-shrink:0; }
.engine-bar-wrap { flex:1; background:#0f172a; border-radius:4px; height:14px; overflow:hidden; }
.engine-bar-fill { height:100%; border-radius:4px; }
.engine-pct { width:40px; text-align:right; font-size:12px; font-weight:bold; }
.grade-dist-wrap { }
.grade-row { display:flex; align-items:center; gap:8px; margin-bottom:5px; }
.grade-label { width:26px; font-size:11px; text-align:right; flex-shrink:0; }
.grade-bar-wrap { flex:1; background:#0f172a; border-radius:3px; height:16px; overflow:hidden; }
.grade-bar-fill { height:100%; border-radius:3px; }
.grade-count { width:24px; font-size:11px; color:var(--muted); text-align:right; }
.table-wrap { overflow-x:auto; margin-bottom:24px; }
table { width:100%; border-collapse:collapse; font-size:12px; }
th { background:#0f172a; color:var(--muted); text-align:left; padding:9px 10px; font-size:10px; text-transform:uppercase; letter-spacing:1px; cursor:pointer; white-space:nowrap; }
th:hover { color:var(--accent); }
td { padding:9px 10px; border-top:1px solid #1e293b; vertical-align:middle; white-space:nowrap; }
tr:hover td { background:rgba(56,189,248,0.04); }
.badge { display:inline-block; padding:2px 7px; border-radius:4px; font-size:10px; font-weight:bold; white-space:nowrap; }
.bar-wrap { background:#0f172a; border-radius:4px; height:8px; overflow:hidden; }
.bar-fill { height:100%; border-radius:4px; }
.comp-grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(180px,1fr)); gap:16px; }
.comp-item { background:var(--card); border:1px solid var(--border); border-radius:8px; padding:16px; }
.comp-pct { font-size:30px; font-weight:bold; }
.comp-label { font-size:12px; color:var(--muted); margin-top:6px; }
.rec-item { padding:10px 12px; margin:5px 0; border-radius:5px; border-left:3px solid; font-size:12px; line-height:1.5; }
.fleet-rec { padding:12px 16px; border-radius:7px; margin-bottom:8px; border-left:4px solid; font-size:12px; line-height:1.5; }
.footer { text-align:center; color:#475569; font-size:11px; margin-top:48px; padding-top:20px; border-top:1px solid #1e293b; }
details summary::-webkit-details-marker { display:none; }
@media (max-width:700px) { .two-col { grid-template-columns:1fr; } }
</style>
</head>
<body>

<div class="header">
  <div class="org">$orgName</div>
  <h1>FLEET INTELLIGENCE DASHBOARD</h1>
  <div class="meta">
    <span>Technician: $techName</span>
    <span>Period: $($Since.ToString('yyyy-MM-dd')) - $($NOW.ToString('yyyy-MM-dd'))</span>
    <span>Generated: $genTime</span>
    <span>v$VERSION</span>
  </div>
</div>

<!-- KPI CARDS -->
<div class="kpi-grid">$kpiHtml</div>

<!-- FLEET OVERVIEW -->
<div class="section-title">Fleet Overview</div>
<div style="display:grid;grid-template-columns:auto 1fr 1fr;gap:24px;margin-bottom:24px;flex-wrap:wrap">

  <div class="card">
    <div class="card-title">Risk Distribution</div>
    <div class="donut-wrap">
      $donutSvg
      <div>$donutLegend</div>
    </div>
  </div>

  <div class="card">
    <div class="card-title">Engine Performance (Fleet Avg)</div>
    $engHtml
  </div>

  <div class="card">
    <div class="card-title">Grade Distribution</div>
    <div class="grade-dist-wrap">$gradeHtml</div>
  </div>

</div>

<!-- COMPLIANCE BASELINE -->
<div class="section-title">Compliance Baseline</div>
<div class="comp-grid" style="margin-bottom:32px">$compHtml</div>

<!-- FLEET-WIDE ACTION PLAN -->
<div class="section-title">Fleet-Wide Action Plan</div>
<div style="margin-bottom:32px">$fleetRecHtml</div>

<!-- MACHINE INVENTORY -->
<div class="section-title">Machine Inventory</div>
<div class="table-wrap">
<table id="inv-table">
<thead>
<tr>
  <th onclick="sortTable('inv-table',0)">#</th>
  <th onclick="sortTable('inv-table',1)">Hostname</th>
  <th onclick="sortTable('inv-table',2)">Manufacturer</th>
  <th onclick="sortTable('inv-table',3)">Model</th>
  <th onclick="sortTable('inv-table',4)">Serial</th>
  <th onclick="sortTable('inv-table',5)">OS</th>
  <th onclick="sortTable('inv-table',6)">Grade</th>
  <th onclick="sortTable('inv-table',7)">Score</th>
  <th onclick="sortTable('inv-table',8)">Risk</th>
  <th onclick="sortTable('inv-table',9)">Trend</th>
  <th onclick="sortTable('inv-table',10)">Scans</th>
  <th onclick="sortTable('inv-table',11)">Last Seen</th>
  <th>Action</th>
</tr>
</thead>
<tbody>$invHtml</tbody>
</table>
</div>

<!-- PER-MACHINE RECOMMENDATIONS -->
<div class="section-title">Per-Machine Recommendations</div>
<div style="margin-bottom:32px">
  <p style="font-size:11px;color:#475569;margin-bottom:12px">CRITICAL and HIGH machines are expanded by default. Click any machine to see full details and action items.</p>
  $recCardsHtml
</div>

<!-- TECHNICIAN ACTIVITY -->
<div class="section-title">Technician Activity</div>
<div class="table-wrap" style="margin-bottom:32px">
<table>
<thead><tr>
  <th>Technician</th>
  <th>Machines Visited</th>
  <th>Total Scans</th>
  <th>Avg Scans/Machine</th>
</tr></thead>
<tbody>$techHtml</tbody>
</table>
</div>

<div class="footer">
  FieldOps Pro Fleet Intelligence Dashboard v$VERSION &nbsp;|&nbsp;
  Generated $genTime by $techName &nbsp;|&nbsp;
  $($Stats.TotalMachines) machines / $($Stats.TotalScans) scans analyzed
</div>

<script>
function sortTable(tableId, col) {
  var tbl = document.getElementById(tableId);
  var rows = Array.from(tbl.tBodies[0].rows);
  var asc = tbl.getAttribute('data-sort-col') != col || tbl.getAttribute('data-sort-dir') == 'desc';
  rows.sort(function(a, b) {
    var av = a.cells[col] ? a.cells[col].innerText.trim() : '';
    var bv = b.cells[col] ? b.cells[col].innerText.trim() : '';
    var an = parseFloat(av); var bn = parseFloat(bv);
    if (!isNaN(an) && !isNaN(bn)) return asc ? an - bn : bn - an;
    return asc ? av.localeCompare(bv) : bv.localeCompare(av);
  });
  rows.forEach(function(r) { tbl.tBodies[0].appendChild(r); });
  tbl.setAttribute('data-sort-col', col);
  tbl.setAttribute('data-sort-dir', asc ? 'asc' : 'desc');
}
</script>
</body>
</html>
"@

    return $html
}

# ==============================================================
# MAIN EXECUTION
# ==============================================================

Write-Banner

# Validate history directory
if (-not (Test-Path $historyDir)) {
    Write-Host "  [ERROR] History directory not found: $historyDir" -ForegroundColor Red
    Write-Host "  Run Invoke-FieldOps.ps1 on at least one machine first." -ForegroundColor Yellow
    exit 1
}

Write-Section 'LOADING FLEET HISTORY'
Write-Step "History path : $historyDir"
Write-Step "Date range   : $($Since.ToString('yyyy-MM-dd')) to $($NOW.ToString('yyyy-MM-dd'))"

$jsonFiles = @(Get-ChildItem -Path $historyDir -Filter '*.json' -ErrorAction SilentlyContinue)
Write-Step "Found $($jsonFiles.Count) history file(s) on USB"

if ($jsonFiles.Count -eq 0) {
    Write-Host ''
    Write-Host "  [WARN] No history files found. Run FieldOps engines and re-try." -ForegroundColor Yellow
    exit 0
}

# Parse all records
$allScans = [System.Collections.Generic.List[PSCustomObject]]::new()
$skipped  = 0
foreach ($f in $jsonFiles) {
    try {
        $raw = Get-Content $f.FullName -Raw -ErrorAction Stop | ConvertFrom-Json
        $rec = ConvertTo-ScanRecord $raw $f.FullName
        if ($rec) {
            if ($rec.ScanDate -ge $Since) {
                $null = $allScans.Add($rec)
                Write-Step "  OK  $($f.Name) -> $($rec.Hostname) | Score=$($rec.Score) Grade=$($rec.Grade) Risk=$($rec.Risk) Tech=$($rec.Technician)" 'DarkGray'
            }
        } else { $skipped++ }
    }
    catch {
        Write-Step "  FAIL $($f.Name): $_" 'Red'
        $skipped++
    }
}

$scanArr = @($allScans)
Write-Step "Loaded $($scanArr.Count) scan record(s) in range ($skipped skipped)" `
           $(if ($skipped -gt 0) { 'Yellow' } else { 'Gray' })

if ($scanArr.Count -eq 0) {
    Write-Host "  No records in specified date range. Try -Since (Get-Date).AddDays(-180)" -ForegroundColor Yellow
    exit 0
}

# Group by hostname -> build machine profiles
Write-Section 'BUILDING MACHINE PROFILES'
$machineTable = @{}
foreach ($scan in $scanArr) {
    if (-not $machineTable.ContainsKey($scan.Hostname)) {
        $machineTable[$scan.Hostname] = [System.Collections.Generic.List[PSCustomObject]]::new()
    }
    $null = $machineTable[$scan.Hostname].Add($scan)
}

$machines = [System.Collections.Generic.List[PSCustomObject]]::new()
foreach ($hostname in ($machineTable.Keys | Sort-Object)) {
    $scans  = @($machineTable[$hostname] | Sort-Object ScanDate)
    $latest = $scans[-1]
    $cnt    = $scans.Count

    # Trend: compare latest vs previous (need 2+ scans)
    $trend  = 'Stable'
    $delta  = 0
    if ($cnt -ge 2) {
        $prev  = $scans[-2]
        $delta = $latest.Score - $prev.Score
        if      ($delta -ge 5)  { $trend = 'Improving' }
        elseif  ($delta -le -5) { $trend = 'Degrading' }
        else                    { $trend = 'Stable' }
    }

    # Distinct technicians across all scans
    $techs = @($scans | Select-Object -ExpandProperty Technician -Unique)

    # Hardware identity from HTML
    $id = Get-MachineIdentity $hostname $reportsDir $latest.ReportPath

    $mobj = [PSCustomObject]@{
        Hostname      = $hostname
        Manufacturer  = $id.Manufacturer
        Model         = $id.Model
        Serial        = $id.Serial
        OS            = $id.OS
        CPU           = $id.CPU
        RAM           = $id.RAM
        IPAddress     = $id.IPAddress
        ScanCount     = $cnt
        LastSeen      = $latest.ScanDate
        LatestScore   = $latest.Score
        Grade         = $latest.Grade
        Risk          = $latest.Risk
        Trend         = $trend
        TrendDelta    = $delta
        LatestEngines = $latest.Engines
        LatestChains  = $latest.Chains
        AllScores     = @($scans | Select-Object -ExpandProperty Score)
        Technicians   = $techs
        ReportPath    = $latest.ReportPath
    }

    $recs = @(Get-MachineRecommendations $mobj)
    $mobj | Add-Member -NotePropertyName Recommendations -NotePropertyValue $recs

    $null = $machines.Add($mobj)
    $tStr = switch ($trend) { 'Improving' { '+' + $delta + '%' } 'Degrading' { $delta.ToString() + '%' } default { 'stable' } }
    Write-Step "$hostname : $($mobj.Grade) ($($mobj.LatestScore)%) | $($mobj.Risk) | $trend $tStr | $cnt scan(s) | $($id.Manufacturer) $($id.Model)"
}

Write-Step "Profiled $($machines.Count) unique machine(s)" 'Green'

# Aggregate fleet statistics
Write-Section 'COMPUTING FLEET INTELLIGENCE'
$machArr    = @($machines)
$stats      = Build-FleetStats $machArr
$fleetRecs  = Get-FleetRecommendations $stats $machArr
$gradeDist  = Get-GradeDistribution $machArr

Write-Step "Fleet size     : $($stats.TotalMachines) machines | $($stats.TotalScans) total scans"
Write-Step "Avg grade      : $($stats.AvgGrade) ($($stats.AvgScore)%)"
Write-Step "Compliance     : $($stats.ComplianceRate)% (B-grade threshold)"
Write-Step "Risk           : CRIT=$($stats.CriticalCount) HIGH=$($stats.HighRiskCount) MED=$($stats.MediumCount) LOW=$($stats.LowCount) MIN=$($stats.MinimalCount)"
Write-Step "Trends         : Improving=$($stats.ImprovingCount) Stable=$($stats.StableCount) Degrading=$($stats.DegradingCount)"
if ($stats.AvgEngineScores.Count -gt 0) {
    $engSummary = ($stats.AvgEngineScores.Keys | Sort-Object | ForEach-Object { "$_=$($stats.AvgEngineScores[$_])%" }) -join '  '
    Write-Step "Engine avgs    : $engSummary"
}

# Generate report
Write-Section 'GENERATING FLEET DASHBOARD'
if (-not (Test-Path $reportsDir)) {
    New-Item -ItemType Directory -Path $reportsDir -Force | Out-Null
}

$html = New-HtmlReport $machArr $stats $fleetRecs $gradeDist
$html | Set-Content -Path $REPORT_PATH -Encoding UTF8

Write-Host ''
Write-Host ('=' * $W) -ForegroundColor Cyan
Write-Host '  FLEET INTELLIGENCE COMPLETE' -ForegroundColor Green
Write-Host ('=' * $W) -ForegroundColor Cyan
Write-Host "  Machines analyzed : $($stats.TotalMachines)"
Write-Host "  Scans processed   : $($stats.TotalScans)"
Write-Host "  Fleet avg grade   : $($stats.AvgGrade) ($($stats.AvgScore)%)"
Write-Host "  Compliance rate   : $($stats.ComplianceRate)% (B-grade threshold)"
Write-Host "  Security rate     : $($stats.SecCompliance)% (SecurityScan >= 80%)"
Write-Host "  High-risk count   : $($stats.CriticalCount + $stats.HighRiskCount)"
Write-Host "  Fleet recs        : $(@($fleetRecs).Count) action item(s)"
Write-Host "  Report            : $REPORT_PATH"
Write-Host ('=' * $W) -ForegroundColor Cyan
Write-Host "  Start-Process ""$REPORT_PATH"""

if ($OpenReport) {
    Start-Process $REPORT_PATH
}
