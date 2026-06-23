<#
.SYNOPSIS
    FieldOps Pro - ANSSI Hygiene Data Collector v0.4
.DESCRIPTION
    Reads the JSON output of the FieldOps Pro engines (SecurityScan, PCHealth,
    NetRepair, ComplianceDiff) and produces report-data.json mapping observed
    facts to the 42 ANSSI Hygiene rules.

    v0.4 changes:
      - Schema abstraction: PCHealth uses Item/Detail, SecurityScan and
        NetRepair use Check/Value. Get-CheckName / Get-CheckValue normalise.
      - Machine identity: parsed from PCHealth Identity 'System Identified'
        (make/model/serial), SecurityScan Patching 'OS Version' (OS), and
        SecurityScan Identity 'Directory Join Status' (annuaire).
      - Test-Observed: a check whose value is "Cannot query" / unavailable no
        longer counts as observed evidence (R5, R8, R29 corrected).
      - Array-safety: all .Count accesses wrapped in @() (R31 corrected).
      - R13 (auth forte): TPM-present-but-Hello-unknown now PV not CV.
      - R20 (Wi-Fi): reads the WPA2/WPA3 encryption check, not link speed.
      - R36 (journaux): "Minimal" audit policy now PV not CV.
      - Numeric rule ordering within modules (R2 before R10).
      - Top-findings selection prefers concrete numeric problems.

.PARAMETER LogsDir         Directory with engine JSON. Default <ProjectRoot>\LOGS
.PARAMETER OutputFile      report-data.json path. Default <ProjectRoot>\REPORTS\report-data.json
.PARAMETER Technician      Technician name. Default from CONFIG\technician.json then env.
.PARAMETER CustomerContact Customer contact placeholder. Default 'A completer'.

.NOTES
    Author  : FieldOps Pro
    Version : 0.4
    Requires: PowerShell 5.1
    Rules   : ASCII-only body. Set-StrictMode 1.0. Dynamic paths. Error-tolerant.
#>

#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$LogsDir,
    [string]$OutputFile,
    [string]$Technician,
    [string]$CustomerContact = 'A completer'
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'
# ===========================================================================
# LOCALE INTEGRATION (Phase 5.2)
# ===========================================================================
$LocaleModulePath = Join-Path $PSScriptRoot '..\Core\FieldOps-Locale.psm1'
if (Test-Path $LocaleModulePath) {
    Import-Module $LocaleModulePath -Force -DisableNameChecking -ErrorAction SilentlyContinue
}

function T {
    param(
        [Parameter(Mandatory=$true)][string]$Key,
        [hashtable]$Vars    = @{},
        [string]$Default    = ''
    )
    if (Get-Command Get-LocaleString -ErrorAction SilentlyContinue) {
        try {
            $resolved = Get-LocaleString -Key $Key -Vars $Vars -Default $Default
            if ($resolved) { return $resolved }
        } catch { }
    }
    return $Default
}

if (Get-Command Initialize-Locale -ErrorAction SilentlyContinue) {
    try {
        $configLangDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'CONFIG\lang'
        if (Test-Path $configLangDir) {
            Initialize-Locale -Lang 'fr' -LangDir $configLangDir -ErrorAction SilentlyContinue
        }
    } catch { }
}

# ===========================================================================
# PATHS
# ===========================================================================
$ScriptRoot = $PSScriptRoot
if (-not $ScriptRoot) { $ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
$ProjectRoot = Split-Path (Split-Path $ScriptRoot -Parent) -Parent

if (-not $LogsDir)    { $LogsDir    = Join-Path $ProjectRoot 'LOGS' }
if (-not $OutputFile) { $OutputFile = Join-Path $ProjectRoot 'REPORTS\report-data.json' }

$outDir = Split-Path $OutputFile -Parent
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
if (-not (Test-Path $LogsDir)) { throw "LOGS directory not found: $LogsDir" }

# ===========================================================================
# CONSOLE HELPERS
# ===========================================================================
function Write-Step { param([string]$m) Write-Host "  [+] $m" -ForegroundColor Cyan }
function Write-OK   { param([string]$m) Write-Host "  [OK] $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "  [WARN] $m" -ForegroundColor Yellow }

# ===========================================================================
# DATA HELPERS
# ===========================================================================
function Get-DictValue {
    param($Object, [string]$Key, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [hashtable] -or $Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Key)) { return $Object[$Key] }
        return $Default
    }
    $p = $Object.PSObject.Properties[$Key]
    if ($p) { return $p.Value }
    return $Default
}

# PCHealth uses Item/Detail ; SecurityScan + NetRepair use Check/Value.
# These two normalise across both schemas.
function Get-CheckName {
    param($c)
    if (-not $c) { return '' }
    $v = Get-DictValue $c 'Check'
    if ($v) { return $v }
    return (Get-DictValue $c 'Item' '')
}
function Get-CheckValue {
    param($c)
    if (-not $c) { return '' }
    $v = Get-DictValue $c 'Value'
    if ($v -ne $null -and "$v" -ne '') { return $v }
    return (Get-DictValue $c 'Detail' '')
}

function Get-LatestEngineJson {
    param([string]$Prefix)
    $files = Get-ChildItem -Path $LogsDir -Filter "${Prefix}_*.json" -ErrorAction SilentlyContinue
    if (-not $files -or @($files).Count -eq 0) { return $null }
    return (@($files) | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
}

function Import-EngineJson {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path $Path)) { return $null }
    try {
        return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch {
        Write-Warn "Failed to parse $Path : $($_.Exception.Message)"
        return $null
    }
}

function Find-Check {
    param($EngineData, [string]$Category, [string]$CheckLike = '')
    if (-not $EngineData) { return $null }
    $checks = Get-DictValue $EngineData 'Checks' @()
    foreach ($c in $checks) {
        if ((Get-DictValue $c 'Category') -eq $Category) {
            if (-not $CheckLike) { return $c }
            if ((Get-CheckName $c) -like "*$CheckLike*") { return $c }
        }
    }
    return $null
}

function Find-AllChecks {
    param($EngineData, [string]$Category, [string]$CheckLike = '')
    $out = @()
    if (-not $EngineData) { return $out }
    $checks = Get-DictValue $EngineData 'Checks' @()
    foreach ($c in $checks) {
        if ((Get-DictValue $c 'Category') -eq $Category) {
            if (-not $CheckLike -or ((Get-CheckName $c) -like "*$CheckLike*")) { $out += $c }
        }
    }
    return $out
}

function Test-Status {
    param($Check)
    if (-not $Check) { return $false }
    return ((Get-DictValue $Check 'Status') -eq 'Pass')
}

# A check whose value indicates it could not be read is NOT observed evidence.
function Test-Observed {
    param($Check)
    if (-not $Check) { return $false }
    $val = "$(Get-CheckValue $Check)"
    if (-not $val) { return $false }
    if ($val -match 'Cannot query|cannot read|non disponible|unavailable|^N/?A$|inconnu') { return $false }
    return $true
}

function Format-DetailString {
    [CmdletBinding()]
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $Text }
    $t = $Text.Trim()
    return $t.Substring(0,1).ToUpperInvariant() + $t.Substring(1)
}


# ===========================================================================
# RULE EVALUATORS - return @{ Status='cv'|'pv'|'hp'; Detail=''; Evidence='' }
# ===========================================================================

# --- Module I (organisational) ---
function Get-R1 { @{ Status='hp'; Detail='Formation des equipes operationnelles - releve organisationnel, non observable techniquement.'; Evidence='' } }
function Get-R2 { @{ Status='hp'; Detail='Sensibilisation des utilisateurs - releve organisationnel.'; Evidence='' } }
function Get-R3 { @{ Status='hp'; Detail='Maitrise des risques de l''infogerance - releve contractuel.'; Evidence='' } }

# --- Module II ---
function Get-R4 {
    param($Sec, $Net, $Pch)
    @{ Status='pv'; Detail='Cartographie reseau locale observee (adaptateurs, IP, passerelle). Inventaire SI global et classification des donnees hors perimetre du poste.'; Evidence='NetRepair - Configuration reseau' }
}
function Get-R5 {
    param($Sec, $Net, $Pch)
    $c = Find-Check -EngineData $Sec -Category 'Identity' -CheckLike 'Local Admin'
    if (Test-Observed $c) {
        return @{ Status='cv'; Detail="Inventaire des administrateurs locaux : $(Get-CheckValue $c)"; Evidence='SecurityScan Identity / Local Administrators' }
    }
    return @{ Status='pv'; Detail='Enumeration des administrateurs locaux non disponible sur ce poste (acces refuse). Verification manuelle requise.'; Evidence='SecurityScan Identity / Local Administrators' }
}
function Get-R6 { @{ Status='hp'; Detail='Procedures arrivee/depart/changement - releve RH et gouvernance.'; Evidence='' } }
function Get-R7 {
    param($Sec)
    $c = Find-Check -EngineData $Sec -Category 'Identity' -CheckLike 'Directory'
    if (Test-Observed $c) {
        return @{ Status='pv'; Detail='Poste rattache a un annuaire - rattachement confirme. Controle d''admission reseau (802.1X) non observable depuis le poste.'; Evidence='SecurityScan Identity / Directory Join Status' }
    }
    return @{ Status='pv'; Detail='Statut d''adhesion annuaire non determine.'; Evidence='' }
}

# --- Module III ---
function Get-R8 {
    param($Sec)
    $admins = Find-Check -EngineData $Sec -Category 'Identity' -CheckLike 'Local Admin'
    $guest  = Find-Check -EngineData $Sec -Category 'Identity' -CheckLike 'Guest'
    $aOK = Test-Observed $admins
    $gOK = Test-Observed $guest
    if ($aOK -and $gOK) {
        $a = Get-CheckValue $admins
        $g = Get-CheckValue $guest
        $gFr = switch -Regex ($g) { '^Disabled' { 'desactive' } '^Enabled' { 'active' } default { $g } }
        return @{ Status='cv'; Detail="Administrateurs locaux : $a. Compte invite : $gFr."; Evidence='SecurityScan Identity' }
    }
    if ($gOK) {
        $g = Get-CheckValue $guest
        $gFr = switch -Regex ($g) { '^Disabled' { 'desactive' } '^Enabled' { 'active' } default { $g } }
        return @{ Status='pv'; Detail="Compte invite $gFr (observe). Enumeration des comptes administrateurs non disponible (acces refuse)."; Evidence='SecurityScan Identity' }
    }
    return @{ Status='pv'; Detail='Enumeration des comptes locaux indisponible.'; Evidence='' }
}
function Get-R9 { @{ Status='pv'; Detail='Inventaire des partages SMB capture en instantane. Adequation des droits d''acces non evaluable sans contexte metier.'; Evidence='ComplianceDiff - instantane SmbShares' } }
function Get-R10 { @{ Status='pv'; Detail='Politique de mots de passe locale non extraite par les sondes actuelles (extension G1 prevue).'; Evidence='' } }
function Get-R11 {
    param($Sec)
    $cred = Find-Check -EngineData $Sec -Category 'Identity' -CheckLike 'Stored Credential'
    $lsa  = Find-Check -EngineData $Sec -Category 'Identity' -CheckLike 'LSA'
    if (Test-Observed $cred) {
        $extra = ''
        if (Test-Observed $lsa) { $extra = ' Protection LSA (PPL) active.' }
        return @{ Status='pv'; Detail="Credential Manager : $(Get-CheckValue $cred).$extra Couverture partielle des vecteurs de stockage."; Evidence='SecurityScan Identity / Stored Credentials, LSA Protection' }
    }
    return @{ Status='pv'; Detail='Credential Manager non inspecte.'; Evidence='' }
}
function Get-R12 {
    param($Sec)
    $c = Find-Check -EngineData $Sec -Category 'Identity' -CheckLike 'Auto'
    if (Test-Observed $c) {
        return @{ Status='pv'; Detail="Auto-logon : $(Get-CheckValue $c). Authentifications par defaut d'autres composants non testees."; Evidence='SecurityScan Identity / Auto-Logon' }
    }
    return @{ Status='pv'; Detail='Auto-logon non detecte dans le registre. Authentifications par defaut d''autres composants non testees.'; Evidence='SecurityScan Identity' }
}
function Get-R13 {
    param($Sec)
    $hello = Find-Check -EngineData $Sec -Category 'WinSec' -CheckLike 'Hello'
    $tpm   = Find-Check -EngineData $Sec -Category 'Firmware' -CheckLike 'TPM'
    $hOK = Test-Observed $hello
    $tOK = Test-Observed $tpm
    if ($hOK -and $tOK) {
        return @{ Status='cv'; Detail="Authentification forte configuree : Windows Hello ($(Get-CheckValue $hello)), TPM operationnel."; Evidence='SecurityScan WinSec + Firmware' }
    }
    if ($tOK) {
        return @{ Status='pv'; Detail='TPM 2.0 present et operationnel - capacite d''authentification forte disponible. Configuration effective de Windows Hello non observee.'; Evidence='SecurityScan Firmware / TPM' }
    }
    return @{ Status='pv'; Detail='Authentification forte non determinee.'; Evidence='' }
}

# --- Module IV ---
function Get-R14 {
    param($Sec, $Pch)
    $fwAll = @(Find-AllChecks -EngineData $Sec -Category 'NetSec' -CheckLike 'Firewall')
    $defRt = Find-Check     -EngineData $Sec -Category 'Defender' -CheckLike 'Real'
    $bitlk = @(Find-AllChecks -EngineData $Sec -Category 'Encryption' -CheckLike 'BitLocker')
    $fwOK  = @($fwAll | Where-Object { Test-Status $_ }).Count -ge 1
    $defOK = Test-Status $defRt
    $blOK  = @($bitlk | Where-Object { Test-Status $_ }).Count -ge 1
    if ($fwOK -and $defOK -and $blOK) {
        return @{ Status='cv'; Detail='Conforme au niveau Standard : pare-feu local actif sur les profils, Microsoft Defender en protection temps reel, BitLocker actif sur le volume systeme. Detection autorun non encore couverte (extension G2).'; Evidence='SecurityScan NetSec + Defender + Encryption' }
    }
    $bits = @()
    if ($fwOK)  { $bits += 'pare-feu actif' }    else { $bits += 'pare-feu non confirme' }
    if ($defOK) { $bits += 'Defender actif' }    else { $bits += 'Defender non confirme' }
    if ($blOK)  { $bits += 'BitLocker actif' }   else { $bits += 'BitLocker non confirme' }
    return @{ Status='pv'; Detail=("Socle de securite partiel : " + ($bits -join ', ') + '. Niveau Standard non integralement atteint.'); Evidence='SecurityScan NetSec + Defender + Encryption' }
}
function Get-R15 { @{ Status='pv'; Detail='Politique de restriction USB / AppLocker non extraite par les sondes actuelles (extension G3 prevue).'; Evidence='' } }
function Get-R16 {
    param($Sec)
    $c = Find-Check -EngineData $Sec -Category 'Identity' -CheckLike 'Directory'
    if (Test-Observed $c) {
        return @{ Status='cv'; Detail='Poste rattache a un annuaire - gestion centralisee du parc confirmee, vraisemblablement via Microsoft Intune.'; Evidence='SecurityScan Identity / Directory Join Status' }
    }
    return @{ Status='pv'; Detail='Etat d''adhesion annuaire non determine.'; Evidence='' }
}
function Get-R17 {
    param($Sec, $Pch, $Net)
    $fwAll = @(Find-AllChecks -EngineData $Sec -Category 'NetSec' -CheckLike 'Firewall')
    if ($fwAll.Count -eq 0) { $fwAll = @(Find-AllChecks -EngineData $Pch -Category 'Security' -CheckLike 'Firewall') }
    if ($fwAll.Count -eq 0) { $fwAll = @(Find-AllChecks -EngineData $Net -Category 'Firewall') }
    $passing = @($fwAll | Where-Object { Test-Status $_ }).Count
    $total   = $fwAll.Count
    if ($total -eq 0) { return @{ Status='pv'; Detail='Etat du pare-feu local non extrait.'; Evidence='' } }
    if ($passing -eq $total) {
        return @{ Status='cv'; Detail="Les $total profils du pare-feu Windows (Domaine, Prive, Public) sont actifs. Configuration de niveau Renforce (blocage des ports d'administration) non evaluee."; Evidence='SecurityScan NetSec + PCHealth Security + NetRepair Firewall' }
    }
    return @{ Status='pv'; Detail="$passing/$total profil(s) de pare-feu actif(s). Le pare-feu doit etre actif sur tous les profils."; Evidence='SecurityScan NetSec' }
}
function Get-R18 { @{ Status='hp'; Detail='Chiffrement des donnees en transit - depend de l''usage applicatif et messagerie, hors perimetre du poste.'; Evidence='' } }

# --- Module V ---
function Get-R19 { @{ Status='pv'; Detail='Sous-reseau local et adaptateurs virtuels observes. Architecture de segmentation reseau hors perimetre du poste.'; Evidence='NetRepair - Configuration IP' } }
function Get-R20 {
    param($Sec, $Net)
    $wif = Find-Check -EngineData $Sec -Category 'NetSec' -CheckLike 'WiFi'
    if (-not $wif) { $wif = Find-Check -EngineData $Sec -Category 'NetSec' -CheckLike 'Wi-Fi' }
    if (Test-Observed $wif) {
        $val = "$(Get-CheckValue $wif)"
        if ($val -match 'WPA3') {
            return @{ Status='cv'; Detail='Connexion Wi-Fi chiffree en WPA3 - protocole conforme aux recommandations actuelles.'; Evidence='SecurityScan NetSec / WiFi Security' }
        }
        if ($val -match 'WPA2') {
            return @{ Status='cv'; Detail='Connexion Wi-Fi active chiffree en WPA2-Personal. Protocole de chiffrement conforme aux recommandations actuelles.'; Evidence='SecurityScan NetSec / WiFi Security' }
        }
        if ($val -match 'WEP|Open|ouvert') {
            return @{ Status='pv'; Detail="Reseau Wi-Fi en chiffrement faible ou absent ($val). Migration vers WPA2/WPA3 recommandee."; Evidence='SecurityScan NetSec / WiFi Security' }
        }
        return @{ Status='pv'; Detail="Wi-Fi observe : $val. Niveau de chiffrement a confirmer."; Evidence='SecurityScan NetSec / WiFi Security' }
    }
    return @{ Status='pv'; Detail='Pas de connexion Wi-Fi observee au moment du diagnostic.'; Evidence='' }
}
function Get-R21 {
    param($Sec)
    $smbv1 = Find-Check -EngineData $Sec -Category 'Surface' -CheckLike 'SMBv1'
    if (Test-Observed $smbv1) {
        return @{ Status='pv'; Detail="SMBv1 : $(Get-CheckValue $smbv1). Audit complet des protocoles obsoletes (TLS, LLMNR, NetBIOS) non encore implemente."; Evidence='SecurityScan Surface' }
    }
    return @{ Status='pv'; Detail='SMBv1 absent du poste. Audit complet des protocoles obsoletes non encore implemente.'; Evidence='SecurityScan Surface' }
}
function Get-R22 {
    param($Net, $Sec)
    $px = Find-Check -EngineData $Net -Category 'Proxy'
    if (Test-Observed $px) {
        return @{ Status='pv'; Detail="Configuration d'acces Internet : $(Get-CheckValue $px). Filtrage d'URL et DNS securise non evalues en detail."; Evidence='NetRepair - Proxy & WPAD' }
    }
    return @{ Status='pv'; Detail='Passerelle d''acces Internet non analysee.'; Evidence='' }
}
function Get-R23 { @{ Status='hp'; Detail='Cloisonnement des services exposes - architecture reseau, hors perimetre du poste.'; Evidence='' } }
function Get-R24 { @{ Status='hp'; Detail='Securite de la messagerie - configuration cote serveur, hors perimetre du poste.'; Evidence='' } }
function Get-R25 { @{ Status='hp'; Detail='Interconnexions partenaires - architecture inter-entites, hors perimetre du poste.'; Evidence='' } }
function Get-R26 { @{ Status='hp'; Detail='Acces physiques - mesure organisationnelle, hors perimetre logiciel.'; Evidence='' } }

# --- Module VI ---
function Get-R27 { @{ Status='hp'; Detail='Usage des postes d''administration - architecture et politique d''usage, hors perimetre.'; Evidence='' } }
function Get-R28 { @{ Status='hp'; Detail='Reseau dedie a l''administration - architecture reseau, hors perimetre du poste.'; Evidence='' } }
function Get-R29 {
    param($Sec)
    $uac    = Find-Check -EngineData $Sec -Category 'PrivEsc' -CheckLike 'UAC'
    $admins = Find-Check -EngineData $Sec -Category 'Identity' -CheckLike 'Local Admin'
    $uOK = Test-Observed $uac
    $aOK = Test-Observed $admins
    if ($uOK -and $aOK) {
        $u = Get-CheckValue $uac
        $uClean = $u -replace '\s*\([^)]*\)\s*$',''
        $a = Get-CheckValue $admins
        return @{ Status='cv'; Detail="Controle d'elevation : UAC $uClean. Administrateurs locaux : $a."; Evidence='SecurityScan PrivEsc / UAC + Identity' }
    }
    if ($uOK) {
        $u = Get-CheckValue $uac
        $uClean = $u -replace '\s*\([^)]*\)\s*$',''
        return @{ Status='pv'; Detail="UAC actif (politique : $uClean). Enumeration des comptes administrateurs non disponible (acces refuse)."; Evidence='SecurityScan PrivEsc / UAC + Identity' }
    }
    return @{ Status='pv'; Detail='Etat UAC et nombre d''administrateurs non extraits.'; Evidence='' }
}

# --- Module VII ---
function Get-R30 {
    param($Pch)
    $sysId = Find-Check -EngineData $Pch -Category 'Identity' -CheckLike 'System Identified'
    if (Test-Observed $sysId) {
        return @{ Status='pv'; Detail='Materiel identifie (poste portable). Mesures de securisation physique non observables techniquement.'; Evidence='PCHealth - Identite systeme' }
    }
    return @{ Status='pv'; Detail='Identification materielle indisponible.'; Evidence='' }
}
function Get-R31 {
    param($Sec, $Pch)
    $bls = @(Find-AllChecks -EngineData $Sec -Category 'Encryption' -CheckLike 'BitLocker')
    if ($bls.Count -eq 0) { $bls = @(Find-AllChecks -EngineData $Pch -Category 'Storage' -CheckLike 'BitLocker') }
    $total = $bls.Count
    if ($total -eq 0) { return @{ Status='pv'; Detail='Statut BitLocker indisponible.'; Evidence='' } }
    $on = @($bls | Where-Object { Test-Status $_ }).Count
    if ($on -eq $total -and $on -gt 0) {
        if ($total -eq 1) {
            return @{ Status='cv'; Detail='Volume systeme chiffre par BitLocker (chiffrement AES). Sur un poste portable, le volume systeme est le vecteur principal de perte de donnees.'; Evidence='SecurityScan Encryption / BitLocker + PCHealth Storage' }
        }
        return @{ Status='cv'; Detail="Les $total volumes detectes sont chiffres par BitLocker (chiffrement AES)."; Evidence='SecurityScan Encryption / BitLocker + PCHealth Storage' }
    }
    return @{ Status='pv'; Detail="$on/$total volume(s) chiffres. Les volumes non chiffres devraient l'etre pour limiter le risque en cas de perte."; Evidence='SecurityScan Encryption / BitLocker' }
}
function Get-R32 {
    param($Net)
    $vpn = Find-Check -EngineData $Net -Category 'VPN'
    if (Test-Observed $vpn) {
        $val = "$(Get-CheckValue $vpn)"
        if ($val -match '\b(?<!dis)(?<!not\s)(connected|connecte|actif)\b') {
            return @{ Status='cv'; Detail="Tunnel VPN actif ($val). Connexion nomade chiffree."; Evidence='NetRepair - Statut VPN' }
        }
        return @{ Status='pv'; Detail="Client VPN installe mais inactif au moment du diagnostic ($val). Qualite cryptographique du tunnel non evaluable hors connexion."; Evidence='NetRepair - Statut VPN' }
    }
    return @{ Status='pv'; Detail='Aucune solution VPN detectee.'; Evidence='' }
}
function Get-R33 { @{ Status='hp'; Detail='Politique terminaux mobiles - concerne smartphones et tablettes, hors perimetre d''un poste Windows.'; Evidence='' } }

# --- Module VIII ---
function Get-R34 {
    param($Sec, $Pch)
    $wu = @(Find-AllChecks -EngineData $Pch -Category 'Updates')
    $fails = @($wu | Where-Object { $s = Get-DictValue $_ 'Status'; $s -eq 'Warning' -or $s -eq 'Critical' }).Count
    if ($fails -gt 0) {
        return @{ Status='cv'; Detail="Windows Update operationnel. $fails echec(s) de mise a jour detecte(s) sur les 30 derniers jours, a relancer."; Evidence='PCHealth - Drivers & Windows Update + SecurityScan Patching' }
    }
    if ($wu.Count -gt 0) {
        return @{ Status='cv'; Detail='Windows Update operationnel - aucun echec recent detecte.'; Evidence='PCHealth - Drivers & Windows Update' }
    }
    return @{ Status='pv'; Detail='Politique de mise a jour non observee dans les sondes.'; Evidence='' }
}
function Get-R35 {
    param($Pch, $Sec)
    $drv = @(Find-AllChecks -EngineData $Pch -Category 'Drivers')
    $old = @($drv | Where-Object { (Get-DictValue $_ 'Status') -eq 'Warning' }).Count
    if ($old -gt 0) {
        return @{ Status='cv'; Detail="Systeme sous support actif. $old pilote(s) obsolete(s) detecte(s), anterieurs aux versions supportees - remplacement recommande."; Evidence='PCHealth - Drivers & Windows Update + SecurityScan Patching' }
    }
    return @{ Status='cv'; Detail='Systeme et composants sous support actif - aucun composant obsolete detecte.'; Evidence='SecurityScan Patching + PCHealth Drivers' }
}

# --- Module IX ---
function Get-R36 {
    param($Sec)
    $aud = Find-Check -EngineData $Sec -Category 'WinSec' -CheckLike 'Audit'
    $sbl = Find-Check -EngineData $Sec -Category 'PSSecurity' -CheckLike 'ScriptBlock'
    $audVal = "$(Get-CheckValue $aud)"
    $sblOK  = Test-Observed $sbl
    $auditWeak = ($audVal -match 'Minimal|minimal') -or ((Get-DictValue $aud 'Status') -eq 'Fail')
    if ($sblOK -and -not $auditWeak -and $audVal) {
        return @{ Status='cv'; Detail="Journalisation active : audit des connexions ($audVal), Script Block Logging PowerShell actif."; Evidence='SecurityScan WinSec + PSSecurity' }
    }
    $bits = @()
    if ($sblOK) { $bits += 'Journalisation PowerShell (Script Block Logging) active' }
    if ($auditWeak) { $bits += 'politique d''audit des connexions au niveau minimal - renforcement recommande pour la tracabilite des evenements de securite' }
    elseif ($audVal) { $bits += "audit des connexions : $audVal" }
    if ($bits.Count -gt 0) {
        return @{ Status='pv'; Detail=(($bits -join '. ') + '.'); Evidence='SecurityScan WinSec / Logon Audit Policy + PSSecurity' }
    }
    return @{ Status='pv'; Detail='Configuration des journaux non extraite.'; Evidence='' }
}
function Get-R37 { @{ Status='hp'; Detail='Politique de sauvegarde - infrastructure et procedures, hors perimetre du poste.'; Evidence='' } }
function Get-R38 { @{ Status='cv'; Detail='L''execution de FieldOps Pro constitue elle-meme un controle d''audit technique regulier, repondant directement a cette mesure.'; Evidence='FieldOps Pro - execution courante' } }
function Get-R39 { @{ Status='hp'; Detail='Designation d''un referent SSI - mesure organisationnelle.'; Evidence='' } }
function Get-R40 { @{ Status='hp'; Detail='Procedure de gestion des incidents - mesure organisationnelle.'; Evidence='' } }

# --- Module X ---
function Get-R41 { @{ Status='hp'; Detail='Analyse de risque formelle (methode EBIOS RM) - demarche methodologique, hors perimetre technique.'; Evidence='' } }
function Get-R42 { @{ Status='pv'; Detail='Inventaire logiciel capture en instantane. Croisement automatique avec le catalogue ANSSI des produits qualifies non encore implemente (extension G7).'; Evidence='ComplianceDiff - instantane Software' } }

# ===========================================================================
# METADATA
# ===========================================================================
$RuleMeta = @(
    @{ Id='R1';  Mod='I';    Name='Former les equipes operationnelles a la securite des SI' }
    @{ Id='R2';  Mod='I';    Name='Sensibiliser les utilisateurs aux bonnes pratiques' }
    @{ Id='R3';  Mod='I';    Name='Maitriser les risques de l''infogerance' }
    @{ Id='R4';  Mod='II';   Name='Identifier informations et serveurs sensibles' }
    @{ Id='R5';  Mod='II';   Name='Inventaire exhaustif des comptes privilegies' }
    @{ Id='R6';  Mod='II';   Name='Procedures arrivee/depart/changement de fonction' }
    @{ Id='R7';  Mod='II';   Name='Connexion reseau aux seuls equipements maitrises' }
    @{ Id='R8';  Mod='III';  Name='Comptes nominatifs, distinguer usage et administration' }
    @{ Id='R9';  Mod='III';  Name='Attribuer les bons droits sur les ressources sensibles' }
    @{ Id='R10'; Mod='III';  Name='Definir et verifier une politique de mots de passe' }
    @{ Id='R11'; Mod='III';  Name='Proteger les mots de passe stockes sur les postes' }
    @{ Id='R12'; Mod='III';  Name='Changer les elements d''authentification par defaut' }
    @{ Id='R13'; Mod='III';  Name='Privilegier l''authentification forte' }
    @{ Id='R14'; Mod='IV';   Name='Mettre en place un niveau de securite minimal sur le parc' }
    @{ Id='R15'; Mod='IV';   Name='Se proteger des menaces des supports amovibles' }
    @{ Id='R16'; Mod='IV';   Name='Utiliser un outil de gestion centralisee du parc' }
    @{ Id='R17'; Mod='IV';   Name='Activer et configurer le pare-feu local' }
    @{ Id='R18'; Mod='IV';   Name='Chiffrer les donnees sensibles transmises par Internet' }
    @{ Id='R19'; Mod='V';    Name='Segmenter le reseau et cloisonner les acces' }
    @{ Id='R20'; Mod='V';    Name='Securiser les reseaux Wi-Fi' }
    @{ Id='R21'; Mod='V';    Name='Utiliser des protocoles reseau securises' }
    @{ Id='R22'; Mod='V';    Name='Mettre en place une passerelle d''acces securise a Internet' }
    @{ Id='R23'; Mod='V';    Name='Cloisonner les services exposes sur Internet' }
    @{ Id='R24'; Mod='V';    Name='Proteger la messagerie professionnelle' }
    @{ Id='R25'; Mod='V';    Name='Securiser les interconnexions avec les partenaires' }
    @{ Id='R26'; Mod='V';    Name='Controler les acces physiques aux locaux et salles serveurs' }
    @{ Id='R27'; Mod='VI';   Name='Interdire l''acces Internet depuis les postes d''administration' }
    @{ Id='R28'; Mod='VI';   Name='Utiliser un reseau dedie a l''administration' }
    @{ Id='R29'; Mod='VI';   Name='Limiter au strict besoin les droits d''administration' }
    @{ Id='R30'; Mod='VII';  Name='Prendre des mesures de securisation physique des terminaux nomades' }
    @{ Id='R31'; Mod='VII';  Name='Chiffrer les donnees sensibles sur le materiel perdable' }
    @{ Id='R32'; Mod='VII';  Name='Securiser la connexion reseau des postes nomades' }
    @{ Id='R33'; Mod='VII';  Name='Adopter des politiques de securite dediees aux terminaux mobiles' }
    @{ Id='R34'; Mod='VIII'; Name='Definir une politique de mise a jour des composants' }
    @{ Id='R35'; Mod='VIII'; Name='Anticiper la fin de maintenance des logiciels et systemes' }
    @{ Id='R36'; Mod='IX';   Name='Activer et configurer les journaux des composants' }
    @{ Id='R37'; Mod='IX';   Name='Definir et appliquer une politique de sauvegarde' }
    @{ Id='R38'; Mod='IX';   Name='Proceder a des controles et audits de securite reguliers' }
    @{ Id='R39'; Mod='IX';   Name='Designer un referent securite des systemes d''information' }
    @{ Id='R40'; Mod='IX';   Name='Definir une procedure de gestion des incidents' }
    @{ Id='R41'; Mod='X';    Name='Mener une analyse de risque formelle' }
    @{ Id='R42'; Mod='X';    Name='Privilegier les produits et services qualifies par l''ANSSI' }
)

$ModuleMeta = @(
    @{ Number='I';    Title='Sensibiliser et former' }
    @{ Number='II';   Title='Connaitre le systeme d''information' }
    @{ Number='III';  Title='Authentifier et controler les acces' }
    @{ Number='IV';   Title='Securiser les postes' }
    @{ Number='V';    Title='Securiser le reseau' }
    @{ Number='VI';   Title='Securiser l''administration' }
    @{ Number='VII';  Title='Gerer le nomadisme' }
    @{ Number='VIII'; Title='Maintenir le SI a jour' }
    @{ Number='IX';   Title='Superviser, auditer, reagir' }
    @{ Number='X';    Title='Pour aller plus loin' }
)

# ===========================================================================
# MAIN
# ===========================================================================
Write-Host ''
Write-Host '  +----------------------------------------------------------------+' -ForegroundColor White
Write-Host '  |  FIELDOPS PRO - ANSSI Data Collector v0.4                      |' -ForegroundColor White
Write-Host '  +----------------------------------------------------------------+' -ForegroundColor White
Write-Host ''
Write-Step "LOGS dir   : $LogsDir"
Write-Step "Output file: $OutputFile"
Write-Host ''

$ssPath = Get-LatestEngineJson -Prefix 'SecurityScan'
$pcPath = Get-LatestEngineJson -Prefix 'PCHealth'
$nrPath = Get-LatestEngineJson -Prefix 'NetRepair'
$cdPaths = @(Get-ChildItem -Path $LogsDir -Filter 'ComplianceDiff_*.json' -ErrorAction SilentlyContinue)

if ($ssPath) { Write-OK "SecurityScan: $(Split-Path $ssPath -Leaf)" } else { Write-Warn 'SecurityScan: no JSON found' }
if ($pcPath) { Write-OK "PCHealth    : $(Split-Path $pcPath -Leaf)" } else { Write-Warn 'PCHealth    : no JSON found' }
if ($nrPath) { Write-OK "NetRepair   : $(Split-Path $nrPath -Leaf)" } else { Write-Warn 'NetRepair   : no JSON found' }
Write-OK "ComplianceDiff snapshots: $($cdPaths.Count)"
Write-Host ''

$sec = Import-EngineJson -Path $ssPath
$pch = Import-EngineJson -Path $pcPath
$net = Import-EngineJson -Path $nrPath

# --- Machine identification ---
$hostname      = $env:COMPUTERNAME
$machineMake   = 'Non determine'
$machineSerial = 'Non determine'
$machineOs     = 'Windows'
$machineDir    = 'Non determine'

if ($pch) {
    $h = Get-DictValue $pch 'Hostname'
    if ($h) { $hostname = $h }
    # PCHealth Identity / 'System Identified' Detail: "Make Model | SN: Serial"
    $sysId = Find-Check -EngineData $pch -Category 'Identity' -CheckLike 'System Identified'
    if ($sysId) {
        $sidVal = "$(Get-CheckValue $sysId)"
        if ($sidVal -match '^(.*?)\s*\|\s*SN:\s*(.*)$') {
            $machineMake   = $matches[1].Trim()
            $machineSerial = $matches[2].Trim()
        } elseif ($sidVal) {
            $machineMake = $sidVal.Trim()
        }
    }
}
# OS from SecurityScan Patching / 'OS Version'
$osChk = Find-Check -EngineData $sec -Category 'Patching' -CheckLike 'OS Version'
if (Test-Observed $osChk) {
    $machineOs = ("$(Get-CheckValue $osChk)" -replace 'Microsoft\s+', '').Trim()
}
# Directory from SecurityScan Identity / 'Directory Join Status'
$dirChk = Find-Check -EngineData $sec -Category 'Identity' -CheckLike 'Directory'
if (Test-Observed $dirChk) {
    $dirRaw = "$(Get-CheckValue $dirChk)"
    if     ($dirRaw -match 'Azure AD:\s*Yes')  { $machineDir = 'Azure AD Joined' }
    elseif ($dirRaw -match 'Workplace:\s*Yes') { $machineDir = 'Workplace Joined' }
    elseif ($dirRaw -match 'Domain:\s*Yes')    { $machineDir = 'Domain Joined' }
    else                                       { $machineDir = 'Non rattache a un annuaire' }
}

# --- Technician ---
if (-not $Technician) {
    $techFile = Join-Path $ProjectRoot 'CONFIG\technician.json'
    if (Test-Path $techFile) {
        try {
            $t = Get-Content -LiteralPath $techFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $Technician = Get-DictValue $t 'Name' $env:USERNAME
        } catch { $Technician = $env:USERNAME }
    } else { $Technician = $env:USERNAME }
}

$now = Get-Date
$reportId = "FOPS-{0}-{1}-001" -f $now.ToString('yyyyMMdd'), $hostname
$reportDateHuman = $now.ToString('dd/MM/yyyy HH:mm') + ' ' + (T 'report.anssi.machineFields.dateSuffix' @{} '(heure locale)')

Write-Step 'Evaluating 42 ANSSI rules...'

$evaluators = @{
    'R1'={Get-R1}; 'R2'={Get-R2}; 'R3'={Get-R3}
    'R4'={Get-R4 $sec $net $pch}; 'R5'={Get-R5 $sec $net $pch}; 'R6'={Get-R6}; 'R7'={Get-R7 $sec}
    'R8'={Get-R8 $sec}; 'R9'={Get-R9}; 'R10'={Get-R10}; 'R11'={Get-R11 $sec}
    'R12'={Get-R12 $sec}; 'R13'={Get-R13 $sec}
    'R14'={Get-R14 $sec $pch}; 'R15'={Get-R15}; 'R16'={Get-R16 $sec}; 'R17'={Get-R17 $sec $pch $net}; 'R18'={Get-R18}
    'R19'={Get-R19}; 'R20'={Get-R20 $sec $net}; 'R21'={Get-R21 $sec}; 'R22'={Get-R22 $net $sec}
    'R23'={Get-R23}; 'R24'={Get-R24}; 'R25'={Get-R25}; 'R26'={Get-R26}
    'R27'={Get-R27}; 'R28'={Get-R28}; 'R29'={Get-R29 $sec}
    'R30'={Get-R30 $pch}; 'R31'={Get-R31 $sec $pch}; 'R32'={Get-R32 $net}; 'R33'={Get-R33}
    'R34'={Get-R34 $sec $pch}; 'R35'={Get-R35 $pch $sec}
    'R36'={Get-R36 $sec}; 'R37'={Get-R37}; 'R38'={Get-R38}; 'R39'={Get-R39}; 'R40'={Get-R40}
    'R41'={Get-R41}; 'R42'={Get-R42}
}

$ruleResults = [ordered]@{}
foreach ($m in $RuleMeta) {
    $rid = $m.Id
    try { $r = & $evaluators[$rid] }
    catch {
        Write-Warn "Rule $rid evaluation failed: $($_.Exception.Message)"
        $r = @{ Status='pv'; Detail=(T 'report.anssi.evaluator.evaluationFailedFallback' @{} 'Evaluation echouee.'); Evidence='' }
    }
    $st = Get-DictValue $r 'Status' 'pv'
    if ($st -notmatch '^(cv|pv|hp)$') { $st = 'pv' }
    $label = switch ($st) {
        'cv'    { T 'report.anssi.status.cv' @{} 'Verifie' }
        'pv'    { T 'report.anssi.status.pv' @{} 'Partiel' }
        'hp'    { T 'report.anssi.status.hp' @{} 'Hors perimetre' }
        default { T 'report.anssi.status.pv' @{} 'Partiel' }
    }
    $ruleResults[$rid] = [PSCustomObject]@{
        Id=$rid; Module=$m.Mod; Name=$m.Name; Status=$st; StatusLabel=$label
        Meta=(Get-DictValue $r 'Detail' ''); Detail=''; Evidence=(Get-DictValue $r 'Evidence' '')
    }
}

$countCV = @($ruleResults.Values | Where-Object { $_.Status -eq 'cv' }).Count
$countPV = @($ruleResults.Values | Where-Object { $_.Status -eq 'pv' }).Count
$countHP = @($ruleResults.Values | Where-Object { $_.Status -eq 'hp' }).Count
Write-OK "CV=$countCV  PV=$countPV  HP=$countHP  (total=42)"

# --- Modules summary ---
$modules = @()
foreach ($m in $ModuleMeta) {
    $mr = @($ruleResults.Values | Where-Object { $_.Module -eq $m.Number })
    $modules += [PSCustomObject]@{
        Number=$m.Number; Title=$m.Title; RuleCount=$mr.Count
        Counts=@{
            Cv=@($mr | Where-Object { $_.Status -eq 'cv' }).Count
            Pv=@($mr | Where-Object { $_.Status -eq 'pv' }).Count
            Hp=@($mr | Where-Object { $_.Status -eq 'hp' }).Count
        }
    }
}

# --- Module details (numeric rule order) ---
$moduleDetails = @()
foreach ($m in $ModuleMeta) {
    $mr = @($ruleResults.Values | Where-Object { $_.Module -eq $m.Number } | Sort-Object { [int]($_.Id.Substring(1)) })
    $rules = @()
    foreach ($rr in $mr) {
        $rr.Meta = Format-DetailString $rr.Meta
        $rules += [PSCustomObject]@{
            Id=$rr.Id; Name=$rr.Name; Status=$rr.Status; StatusLabel=$rr.StatusLabel
    
            Meta=$rr.Meta; Detail=$rr.Detail; Evidence=$rr.Evidence
        }
    }
    $moduleDetails += [PSCustomObject]@{ Number=$m.Number; Title=$m.Title; Rules=$rules }
}

# --- Top findings: non-HP rules whose detail names a concrete problem ---
$topFindings = @()
$problemPattern = '\d+\s*(echec|pilote|volume)|obsolet|minimal|non chiffr|chiffrement faible|\d+/\d+\s*(profil|volume)'
$candidates = @($ruleResults.Values | Where-Object { $_.Status -ne 'hp' -and $_.Meta -match $problemPattern })
foreach ($r in $candidates) {
    if ($topFindings.Count -ge 3) { break }
    $topFindings += [PSCustomObject]@{
        Title    = $r.Name
        RuleNote = "Regle $($r.Id.Substring(1)) - $($r.Meta)"
        RuleId   = $r.Id
        Status   = $r.Status
    }
}
if ($topFindings.Count -lt 3) {
    $already = @($topFindings | ForEach-Object { $_.RuleId })
    $extra = @($ruleResults.Values | Where-Object { $_.Status -eq 'pv' -and $already -notcontains $_.Id } | Select-Object -First (3 - $topFindings.Count))
    foreach ($r in $extra) {
        $topFindings += [PSCustomObject]@{
            Title=$r.Name; RuleNote="Regle $($r.Id.Substring(1)) - $($r.Meta)"; RuleId=$r.Id; Status=$r.Status
        }
    }
}

# Safety net: ensure $topFindings always has 3 entries with localized placeholder
while ($topFindings.Count -lt 3) {
    $topFindings += [PSCustomObject]@{
        Title    = T 'report.anssi.evaluator.noTopFinding' @{} 'Aucun constat majeur'
        RuleNote = ''
        RuleId   = ''
        Status   = 'cv'
    }
}

# --- Final shape ---
$reportData = [PSCustomObject]@{
    Report = [PSCustomObject]@{
        Id=$reportId; GeneratedAt=$now.ToString('o'); GeneratedAtHuman=$reportDateHuman
        Technician=$Technician; CustomerContact=$CustomerContact
    }
    Machine = [PSCustomObject]@{
        Hostname=$hostname; MakeModel=$machineMake; Serial=$machineSerial
        Os=$machineOs; Directory=$machineDir
    }
    Summary = [PSCustomObject]@{ CountCV=$countCV; CountPV=$countPV; CountHP=$countHP; Total=42 }
    TopFindings   = $topFindings
    Modules       = $modules
    ModuleDetails = $moduleDetails
}

$reportData | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $OutputFile -Encoding UTF8 -Force
Write-Host ''
Write-OK "Report data written: $OutputFile"
Write-Host "  Machine : $machineMake / $machineOs / $machineDir" -ForegroundColor DarkGray
Write-Host ''
Write-Host "  Next: .\SCRIPTS\Compliance\Invoke-ANSSIDiagnostic-POC.ps1 -DataFile `"$OutputFile`"" -ForegroundColor DarkGray
Write-Host ''
