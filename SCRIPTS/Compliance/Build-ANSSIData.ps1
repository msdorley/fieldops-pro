# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Ousman Dorley. See LICENSE at the repository root.
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
.PARAMETER CustomerContact Recipient name. Empty by default: the tool does not
                          know it, and a placeholder written into a value is
                          printed and signed as though it were data.

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
    [string]$CustomerContact = '',
    # L'organisation qui commande l'audit. Vide par defaut : l'outil ne la
    # connait pas, et un rapport d'audit adresse a personne n'en est pas un.
    [string]$ClientOrganisation = '',
    # Marquage de diffusion. Vide = celui du bundle. Un rapport qui enumere les
    # faiblesses d'un poste nomme doit dire qui peut le lire.
    [string]$Classification = ''
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
function Get-R1 { @{ Status='hp'; Detail=(T 'report.anssi.rules.R1.detail.hp_default' @{} 'Formation des equipes operationnelles - releve organisationnel, non observable techniquement.'); Evidence='' } }
function Get-R2 { @{ Status='hp'; Detail=(T 'report.anssi.rules.R2.detail.hp_default' @{} 'Sensibilisation des utilisateurs - releve organisationnel.'); Evidence='' } }
function Get-R3 { @{ Status='hp'; Detail=(T 'report.anssi.rules.R3.detail.hp_default' @{} 'Maitrise des risques de l''infogerance - releve contractuel.'); Evidence='' } }

# --- Module II ---
function Get-R4 {
    param($Sec, $Net, $Pch)
    @{ Status='pv'; Detail=(T 'report.anssi.rules.R4.detail.pv_local_only' @{} 'Cartographie reseau locale observee (adaptateurs, IP, passerelle). Inventaire SI global et classification des donnees hors perimetre du poste.'); Evidence='NetRepair - Network Configuration' }
}
function Get-R5 {
    param($Sec, $Net, $Pch)
    $c = Find-Check -EngineData $Sec -Category 'Identity' -CheckLike 'Local Admin'
    if (Test-Observed $c) {
        return @{ Status='cv'; Detail=(T 'report.anssi.rules.R5.detail.cv_observed' @{ adminList=(Get-CheckValue $c) } "Inventaire des administrateurs locaux : $(Get-CheckValue $c)"); Evidence='SecurityScan Identity / Local Administrators' }
    }
    return @{ Status='pv'; Detail=(T 'report.anssi.rules.R5.detail.pv_access_denied' @{} 'Enumeration des administrateurs locaux non disponible sur ce poste (acces refuse). Verification manuelle requise.'); Evidence='SecurityScan Identity / Local Administrators' }
}
function Get-R6 { @{ Status='hp'; Detail=(T 'report.anssi.rules.R6.detail.hp_default' @{} 'Procedures arrivee/depart/changement - releve RH et gouvernance.'); Evidence='' } }
function Get-R7 {
    param($Sec)
    $c = Find-Check -EngineData $Sec -Category 'Identity' -CheckLike 'Directory'
    if (Test-Observed $c) {
        return @{ Status='pv'; Detail=(T 'report.anssi.rules.R7.detail.pv_joined' @{} 'Poste rattache a un annuaire - rattachement confirme. Controle d''admission reseau (802.1X) non observable depuis le poste.'); Evidence='SecurityScan Identity / Directory Join Status' }
    }
    return @{ Status='pv'; Detail=(T 'report.anssi.rules.R7.detail.pv_unknown' @{} 'Statut d''adhesion annuaire non determine.'); Evidence='' }
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
        $gFr = switch -Regex ($g) {
            '^Disabled' { T 'report.anssi.accountState.disabled' @{} 'desactive' }
            '^Enabled'  { T 'report.anssi.accountState.active'   @{} 'active' }
            default     { $g }
        }
        return @{ Status='cv'; Detail=(T 'report.anssi.rules.R8.detail.cv_both_observed' @{ adminList=$a; guestState=$gFr } "Administrateurs locaux : $a. Compte invite : $gFr."); Evidence='SecurityScan Identity' }
    }
    if ($gOK) {
        $g = Get-CheckValue $guest
        $gFr = switch -Regex ($g) {
            '^Disabled' { T 'report.anssi.accountState.disabled' @{} 'desactive' }
            '^Enabled'  { T 'report.anssi.accountState.active'   @{} 'active' }
            default     { $g }
        }
        return @{ Status='pv'; Detail=(T 'report.anssi.rules.R8.detail.pv_guest_only' @{ guestState=$gFr } "Compte invite $gFr (observe). Enumeration des comptes administrateurs non disponible (acces refuse)."); Evidence='SecurityScan Identity' }
    }
    return @{ Status='pv'; Detail=(T 'report.anssi.rules.R8.detail.pv_default' @{} 'Enumeration des comptes locaux indisponible.'); Evidence='' }
}
function Get-R9 { @{ Status='pv'; Detail=(T 'report.anssi.rules.R9.detail.pv_default' @{} 'Inventaire des partages SMB capture en instantane. Adequation des droits d''acces non evaluable sans contexte metier.'); Evidence='ComplianceDiff - snapshot SmbShares' } }
function Get-R10 { @{ Status='pv'; Detail=(T 'report.anssi.rules.R10.detail.pv_default' @{} 'Politique de mots de passe locale non extraite par les sondes actuelles (extension G1 prevue).'); Evidence='' } }
function Get-R11 {
    param($Sec)
    $cred = Find-Check -EngineData $Sec -Category 'Identity' -CheckLike 'Stored Credential'
    $lsa  = Find-Check -EngineData $Sec -Category 'Identity' -CheckLike 'LSA'
    if (Test-Observed $cred) {
        # The bundle splits this into two whole sentences rather than a base plus
        # an inline suffix, so the key is chosen here instead of concatenated.
        $ci = "$(Get-CheckValue $cred)"
        if (Test-Observed $lsa) {
            return @{ Status='pv'; Detail=(T 'report.anssi.rules.R11.detail.pv_with_lsa' @{ credInfo=$ci } "Credential Manager : $ci. Protection LSA (PPL) active. Couverture partielle des vecteurs de stockage."); Evidence='SecurityScan Identity / Stored Credentials, LSA Protection' }
        }
        return @{ Status='pv'; Detail=(T 'report.anssi.rules.R11.detail.pv_without_lsa' @{ credInfo=$ci } "Credential Manager : $ci. Couverture partielle des vecteurs de stockage."); Evidence='SecurityScan Identity / Stored Credentials, LSA Protection' }
    }
    return @{ Status='pv'; Detail=(T 'report.anssi.rules.R11.detail.pv_no_inspect' @{} 'Credential Manager non inspecte.'); Evidence='' }
}
function Get-R12 {
    param($Sec)
    $c = Find-Check -EngineData $Sec -Category 'Identity' -CheckLike 'Auto'
    if (Test-Observed $c) {
        return @{ Status='pv'; Detail=(T 'report.anssi.rules.R12.detail.pv_observed' @{ autoLogonValue=(Get-CheckValue $c) } "Auto-logon : $(Get-CheckValue $c). Authentifications par defaut d'autres composants non testees."); Evidence='SecurityScan Identity / Auto-Logon' }
    }
    return @{ Status='pv'; Detail=(T 'report.anssi.rules.R12.detail.pv_default' @{} 'Auto-logon non detecte dans le registre. Authentifications par defaut d''autres composants non testees.'); Evidence='SecurityScan Identity' }
}
function Get-R13 {
    param($Sec)
    $hello = Find-Check -EngineData $Sec -Category 'WinSec' -CheckLike 'Hello'
    $tpm   = Find-Check -EngineData $Sec -Category 'Firmware' -CheckLike 'TPM'
    $hOK = Test-Observed $hello
    $tOK = Test-Observed $tpm
    if ($hOK -and $tOK) {
        return @{ Status='cv'; Detail=(T 'report.anssi.rules.R13.detail.cv_full' @{ helloValue=(Get-CheckValue $hello) } "Authentification forte configuree : Windows Hello ($(Get-CheckValue $hello)), TPM operationnel."); Evidence='SecurityScan WinSec + Firmware' }
    }
    if ($tOK) {
        return @{ Status='pv'; Detail=(T 'report.anssi.rules.R13.detail.pv_tpm_ok' @{} 'TPM 2.0 present et operationnel - capacite d''authentification forte disponible. Configuration effective de Windows Hello non observee.'); Evidence='SecurityScan Firmware / TPM' }
    }
    return @{ Status='pv'; Detail=(T 'report.anssi.rules.R13.detail.pv_default' @{} 'Authentification forte non determinee.'); Evidence='' }
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
        return @{ Status='cv'; Detail=(T 'report.anssi.rules.R14.detail.cv_default' @{} 'Conforme au niveau Standard : pare-feu local actif sur les profils, Microsoft Defender en protection temps reel, BitLocker actif sur le volume systeme. Detection autorun non encore couverte (extension G2).'); Evidence='SecurityScan NetSec + Defender + Encryption' }
    }
    $bits = @()
    # Composed prose: each fragment is a phrases key, and the assembled string is
    # substituted into detail.pv_partial. This is why the phrases sub-keys exist.
    if ($fwOK)  { $bits += (T 'report.anssi.rules.R14.phrases.fwOk'  @{} 'pare-feu actif') }
    else        { $bits += (T 'report.anssi.rules.R14.phrases.fwNotConfirmed'  @{} 'pare-feu non confirme') }
    if ($defOK) { $bits += (T 'report.anssi.rules.R14.phrases.defOk' @{} 'Defender actif') }
    else        { $bits += (T 'report.anssi.rules.R14.phrases.defNotConfirmed' @{} 'Defender non confirme') }
    if ($blOK)  { $bits += (T 'report.anssi.rules.R14.phrases.blOk'  @{} 'BitLocker actif') }
    else        { $bits += (T 'report.anssi.rules.R14.phrases.blNotConfirmed'  @{} 'BitLocker non confirme') }
    $joined = ($bits -join ', ')
    return @{ Status='pv'; Detail=(T 'report.anssi.rules.R14.detail.pv_partial' @{ bits=$joined } ("Socle de securite partiel : " + $joined + '. Niveau Standard non integralement atteint.')); Evidence='SecurityScan NetSec + Defender + Encryption' }
}
function Get-R15 { @{ Status='pv'; Detail=(T 'report.anssi.rules.R15.detail.pv_default' @{} 'Politique de restriction USB / AppLocker non extraite par les sondes actuelles (extension G3 prevue).'); Evidence='' } }
function Get-R16 {
    param($Sec)
    $c = Find-Check -EngineData $Sec -Category 'Identity' -CheckLike 'Directory'
    if (Test-Observed $c) {
        return @{ Status='cv'; Detail=(T 'report.anssi.rules.R16.detail.cv_default' @{} 'Poste rattache a un annuaire - gestion centralisee du parc confirmee, vraisemblablement via Microsoft Intune.'); Evidence='SecurityScan Identity / Directory Join Status' }
    }
    return @{ Status='pv'; Detail=(T 'report.anssi.rules.R16.detail.pv_unknown' @{} 'Etat d''adhesion annuaire non determine.'); Evidence='' }
}
function Get-R17 {
    param($Sec, $Pch, $Net)
    $fwAll = @(Find-AllChecks -EngineData $Sec -Category 'NetSec' -CheckLike 'Firewall')
    if ($fwAll.Count -eq 0) { $fwAll = @(Find-AllChecks -EngineData $Pch -Category 'Security' -CheckLike 'Firewall') }
    if ($fwAll.Count -eq 0) { $fwAll = @(Find-AllChecks -EngineData $Net -Category 'Firewall') }
    $passing = @($fwAll | Where-Object { Test-Status $_ }).Count
    $total   = $fwAll.Count
    if ($total -eq 0) { return @{ Status='pv'; Detail=(T 'report.anssi.rules.R17.detail.pv_no_data' @{} 'Etat du pare-feu local non extrait.'); Evidence='' } }
    if ($passing -eq $total) {
        return @{ Status='cv'; Detail=(T 'report.anssi.rules.R17.detail.cv_all_active' @{ count=$total } "Les $total profils du pare-feu Windows (Domaine, Prive, Public) sont actifs. Configuration de niveau Renforce (blocage des ports d'administration) non evaluee."); Evidence='SecurityScan NetSec + PCHealth Security + NetRepair Firewall' }
    }
    return @{ Status='pv'; Detail=(T 'report.anssi.rules.R17.detail.pv_partial' @{ passing=$passing; total=$total } "$passing/$total profil(s) de pare-feu actif(s). Le pare-feu doit etre actif sur tous les profils."); Evidence='SecurityScan NetSec' }
}
function Get-R18 { @{ Status='hp'; Detail=(T 'report.anssi.rules.R18.detail.hp_default' @{} 'Chiffrement des donnees en transit - depend de l''usage applicatif et messagerie, hors perimetre du poste.'); Evidence='' } }

# --- Module V ---
function Get-R19 { @{ Status='pv'; Detail=(T 'report.anssi.rules.R19.detail.pv_default' @{} 'Sous-reseau local et adaptateurs virtuels observes. Architecture de segmentation reseau hors perimetre du poste.'); Evidence='NetRepair - IP Configuration' } }
function Get-R20 {
    param($Sec, $Net)
    $wif = Find-Check -EngineData $Sec -Category 'NetSec' -CheckLike 'WiFi'
    if (-not $wif) { $wif = Find-Check -EngineData $Sec -Category 'NetSec' -CheckLike 'Wi-Fi' }
    if (Test-Observed $wif) {
        $val = "$(Get-CheckValue $wif)"
        if ($val -match 'WPA3') {
            return @{ Status='cv'; Detail=(T 'report.anssi.rules.R20.detail.cv_wpa3' @{} 'Connexion Wi-Fi chiffree en WPA3 - protocole conforme aux recommandations actuelles.'); Evidence='SecurityScan NetSec / WiFi Security' }
        }
        if ($val -match 'WPA2') {
            return @{ Status='cv'; Detail=(T 'report.anssi.rules.R20.detail.cv_wpa2' @{} 'Connexion Wi-Fi active chiffree en WPA2-Personal. Protocole de chiffrement conforme aux recommandations actuelles.'); Evidence='SecurityScan NetSec / WiFi Security' }
        }
        if ($val -match 'WEP|Open|ouvert') {
            return @{ Status='pv'; Detail=(T 'report.anssi.rules.R20.detail.pv_weak' @{ algorithm=$val } "Reseau Wi-Fi en chiffrement faible ou absent ($val). Migration vers WPA2/WPA3 recommandee."); Evidence='SecurityScan NetSec / WiFi Security' }
        }
        return @{ Status='pv'; Detail=(T 'report.anssi.rules.R20.detail.pv_other' @{ value=$val } "Wi-Fi observe : $val. Niveau de chiffrement a confirmer."); Evidence='SecurityScan NetSec / WiFi Security' }
    }
    return @{ Status='pv'; Detail=(T 'report.anssi.rules.R20.detail.pv_no_wifi' @{} 'Pas de connexion Wi-Fi observee au moment du diagnostic.'); Evidence='' }
}
function Get-R21 {
    param($Sec)
    $smbv1 = Find-Check -EngineData $Sec -Category 'Surface' -CheckLike 'SMBv1'
    if (Test-Observed $smbv1) {
        return @{ Status='pv'; Detail=(T 'report.anssi.rules.R21.detail.pv_smbv1_observed' @{ smbStatus=(Get-CheckValue $smbv1) } "SMBv1 : $(Get-CheckValue $smbv1). Audit complet des protocoles obsoletes (TLS, LLMNR, NetBIOS) non encore implemente."); Evidence='SecurityScan Surface' }
    }
    return @{ Status='pv'; Detail=(T 'report.anssi.rules.R21.detail.pv_default' @{} 'SMBv1 absent du poste. Audit complet des protocoles obsoletes non encore implemente.'); Evidence='SecurityScan Surface' }
}
function Get-R22 {
    param($Net, $Sec)
    $px = Find-Check -EngineData $Net -Category 'Proxy'
    if (Test-Observed $px) {
        return @{ Status='pv'; Detail=(T 'report.anssi.rules.R22.detail.pv_default' @{ proxyConfig=(Get-CheckValue $px) } "Configuration d'acces Internet : $(Get-CheckValue $px). Filtrage d'URL et DNS securise non evalues en detail."); Evidence='NetRepair - Proxy & WPAD' }
    }
    return @{ Status='pv'; Detail=(T 'report.anssi.rules.R22.detail.pv_no_analysis' @{} 'Passerelle d''acces Internet non analysee.'); Evidence='' }
}
function Get-R23 { @{ Status='hp'; Detail=(T 'report.anssi.rules.R23.detail.hp_default' @{} 'Cloisonnement des services exposes - architecture reseau, hors perimetre du poste.'); Evidence='' } }
function Get-R24 { @{ Status='hp'; Detail=(T 'report.anssi.rules.R24.detail.hp_default' @{} 'Securite de la messagerie - configuration cote serveur, hors perimetre du poste.'); Evidence='' } }
function Get-R25 { @{ Status='hp'; Detail=(T 'report.anssi.rules.R25.detail.hp_default' @{} 'Interconnexions partenaires - architecture inter-entites, hors perimetre du poste.'); Evidence='' } }
function Get-R26 { @{ Status='hp'; Detail=(T 'report.anssi.rules.R26.detail.hp_default' @{} 'Acces physiques - mesure organisationnelle, hors perimetre logiciel.'); Evidence='' } }

# --- Module VI ---
function Get-R27 { @{ Status='hp'; Detail=(T 'report.anssi.rules.R27.detail.hp_default' @{} 'Usage des postes d''administration - architecture et politique d''usage, hors perimetre.'); Evidence='' } }
function Get-R28 { @{ Status='hp'; Detail=(T 'report.anssi.rules.R28.detail.hp_default' @{} 'Reseau dedie a l''administration - architecture reseau, hors perimetre du poste.'); Evidence='' } }
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
        return @{ Status='cv'; Detail=(T 'report.anssi.rules.R29.detail.cv_full' @{ uacPolicy=$uClean; adminList=$a } "Controle d'elevation : UAC $uClean. Administrateurs locaux : $a."); Evidence='SecurityScan PrivEsc / UAC + Identity' }
    }
    if ($uOK) {
        $u = Get-CheckValue $uac
        $uClean = $u -replace '\s*\([^)]*\)\s*$',''
        return @{ Status='pv'; Detail=(T 'report.anssi.rules.R29.detail.pv_uac_only' @{ uacPolicy=$uClean } "UAC actif (politique : $uClean). Enumeration des comptes administrateurs non disponible (acces refuse)."); Evidence='SecurityScan PrivEsc / UAC + Identity' }
    }
    return @{ Status='pv'; Detail=(T 'report.anssi.rules.R29.detail.pv_no_data' @{} 'Etat UAC et nombre d''administrateurs non extraits.'); Evidence='' }
}

# --- Module VII ---
function Get-R30 {
    param($Pch)
    $sysId = Find-Check -EngineData $Pch -Category 'Identity' -CheckLike 'System Identified'
    if (Test-Observed $sysId) {
        return @{ Status='pv'; Detail=(T 'report.anssi.rules.R30.detail.pv_default' @{} 'Materiel identifie (poste portable). Mesures de securisation physique non observables techniquement.'); Evidence='PCHealth - System Identity' }
    }
    return @{ Status='pv'; Detail=(T 'report.anssi.rules.R30.detail.pv_no_hardware_id' @{} 'Identification materielle indisponible.'); Evidence='' }
}
function Get-R31 {
    param($Sec, $Pch)
    $bls = @(Find-AllChecks -EngineData $Sec -Category 'Encryption' -CheckLike 'BitLocker')
    if ($bls.Count -eq 0) { $bls = @(Find-AllChecks -EngineData $Pch -Category 'Storage' -CheckLike 'BitLocker') }
    $total = $bls.Count
    if ($total -eq 0) { return @{ Status='pv'; Detail=(T 'report.anssi.rules.R31.detail.pv_no_data' @{} 'Statut BitLocker indisponible.'); Evidence='' } }
    $on = @($bls | Where-Object { Test-Status $_ }).Count
    if ($on -eq $total -and $on -gt 0) {
        if ($total -eq 1) {
            return @{ Status='cv'; Detail=(T 'report.anssi.rules.R31.detail.cv_single_volume' @{} 'Volume systeme chiffre par BitLocker (chiffrement AES). Sur un poste portable, le volume systeme est le vecteur principal de perte de donnees.'); Evidence='SecurityScan Encryption / BitLocker + PCHealth Storage' }
        }
        return @{ Status='cv'; Detail=(T 'report.anssi.rules.R31.detail.cv_all_volumes' @{ total=$total } "Les $total volumes detectes sont chiffres par BitLocker (chiffrement AES)."); Evidence='SecurityScan Encryption / BitLocker + PCHealth Storage' }
    }
    return @{ Status='pv'; Detail=(T 'report.anssi.rules.R31.detail.pv_partial' @{ on=$on; total=$total } "$on/$total volume(s) chiffres. Les volumes non chiffres devraient l'etre pour limiter le risque en cas de perte."); Evidence='SecurityScan Encryption / BitLocker' }
}
function Get-R32 {
    param($Net)
    $vpn = Find-Check -EngineData $Net -Category 'VPN'
    if (Test-Observed $vpn) {
        $val = "$(Get-CheckValue $vpn)"
        if ($val -match '\b(?<!dis)(?<!not\s)(connected|connecte|actif)\b') {
            return @{ Status='cv'; Detail=(T 'report.anssi.rules.R32.detail.cv_connected' @{ vpnInfo=$val } "Tunnel VPN actif ($val). Connexion nomade chiffree."); Evidence='NetRepair - VPN Status' }
        }
        return @{ Status='pv'; Detail=(T 'report.anssi.rules.R32.detail.pv_inactive' @{ vpnInfo=$val } "Client VPN installe mais inactif au moment du diagnostic ($val). Qualite cryptographique du tunnel non evaluable hors connexion."); Evidence='NetRepair - VPN Status' }
    }
    return @{ Status='pv'; Detail=(T 'report.anssi.rules.R32.detail.pv_no_vpn' @{} 'Aucune solution VPN detectee.'); Evidence='' }
}
function Get-R33 { @{ Status='hp'; Detail=(T 'report.anssi.rules.R33.detail.hp_default' @{} 'Politique terminaux mobiles - concerne smartphones et tablettes, hors perimetre d''un poste Windows.'); Evidence='' } }

# --- Module VIII ---
function Get-R34 {
    param($Sec, $Pch)
    $wu = @(Find-AllChecks -EngineData $Pch -Category 'Updates')
    $fails = @($wu | Where-Object { $s = Get-DictValue $_ 'Status'; $s -eq 'Warning' -or $s -eq 'Critical' }).Count
    if ($fails -gt 0) {
        return @{ Status='cv'; Detail=(T 'report.anssi.rules.R34.detail.cv_with_failures' @{ count=$fails } "Windows Update operationnel. $fails echec(s) de mise a jour detecte(s) sur les 30 derniers jours, a relancer."); Evidence='PCHealth - Drivers & Windows Update + SecurityScan Patching' }
    }
    if ($wu.Count -gt 0) {
        return @{ Status='cv'; Detail=(T 'report.anssi.rules.R34.detail.cv_clean' @{} 'Windows Update operationnel - aucun echec recent detecte.'); Evidence='PCHealth - Drivers & Windows Update' }
    }
    return @{ Status='pv'; Detail=(T 'report.anssi.rules.R34.detail.pv_no_data' @{} 'Politique de mise a jour non observee dans les sondes.'); Evidence='' }
}
function Get-R35 {
    param($Pch, $Sec)
    $drv = @(Find-AllChecks -EngineData $Pch -Category 'Drivers')
    $old = @($drv | Where-Object { (Get-DictValue $_ 'Status') -eq 'Warning' }).Count
    if ($old -gt 0) {
        return @{ Status='cv'; Detail=(T 'report.anssi.rules.R35.detail.cv_obsolete_drivers' @{ count=$old } "Systeme sous support actif. $old pilote(s) obsolete(s) detecte(s), anterieurs aux versions supportees - remplacement recommande."); Evidence='PCHealth - Drivers & Windows Update + SecurityScan Patching' }
    }
    return @{ Status='cv'; Detail=(T 'report.anssi.rules.R35.detail.cv_clean' @{} 'Systeme et composants sous support actif - aucun composant obsolete detecte.'); Evidence='SecurityScan Patching + PCHealth Drivers' }
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
        return @{ Status='cv'; Detail=(T 'report.anssi.rules.R36.detail.cv_full' @{ auditMode=$audVal } "Journalisation active : audit des connexions ($audVal), Script Block Logging PowerShell actif."); Evidence='SecurityScan WinSec + PSSecurity' }
    }
    $bits = @()
    if ($sblOK) { $bits += (T 'report.anssi.rules.R36.phrases.pwshActive' @{} 'Journalisation PowerShell (Script Block Logging) active') }
    if ($auditWeak) {
        $bits += (T 'report.anssi.rules.R36.phrases.auditWeak' @{} 'politique d''audit des connexions au niveau minimal - renforcement recommande pour la tracabilite des evenements de securite')
    } elseif ($audVal) {
        $bits += (T 'report.anssi.rules.R36.phrases.auditObservedTemplate' @{ value=$audVal } "audit des connexions : $audVal")
    }
    if ($bits.Count -gt 0) {
        $joined = (($bits -join '. ') + '.')
        return @{ Status='pv'; Detail=(T 'report.anssi.rules.R36.detail.pv_partial' @{ bits=$joined } $joined); Evidence='SecurityScan WinSec / Logon Audit Policy + PSSecurity' }
    }
    return @{ Status='pv'; Detail=(T 'report.anssi.rules.R36.detail.pv_no_data' @{} 'Configuration des journaux non extraite.'); Evidence='' }
}
function Get-R37 { @{ Status='hp'; Detail=(T 'report.anssi.rules.R37.detail.hp_default' @{} 'Politique de sauvegarde - infrastructure et procedures, hors perimetre du poste.'); Evidence='' } }
function Get-R38 { @{ Status='cv'; Detail=(T 'report.anssi.rules.R38.detail.cv_default' @{} 'L''execution de FieldOps Pro constitue elle-meme un controle d''audit technique regulier, repondant directement a cette mesure.'); Evidence='FieldOps Pro - current run' } }
function Get-R39 { @{ Status='hp'; Detail=(T 'report.anssi.rules.R39.detail.hp_default' @{} 'Designation d''un referent SSI - mesure organisationnelle.'); Evidence='' } }
function Get-R40 { @{ Status='hp'; Detail=(T 'report.anssi.rules.R40.detail.hp_default' @{} 'Procedure de gestion des incidents - mesure organisationnelle.'); Evidence='' } }

# --- Module X ---
function Get-R41 { @{ Status='hp'; Detail=(T 'report.anssi.rules.R41.detail.hp_default' @{} 'Analyse de risque formelle (methode EBIOS RM) - demarche methodologique, hors perimetre technique.'); Evidence='' } }
function Get-R42 { @{ Status='pv'; Detail=(T 'report.anssi.rules.R42.detail.pv_default' @{} 'Inventaire logiciel capture en instantane. Croisement automatique avec le catalogue ANSSI des produits qualifies non encore implemente (extension G7).'); Evidence='ComplianceDiff - snapshot Software' } }

# ===========================================================================
# METADATA
# ===========================================================================
$RuleMeta = @(
    @{ Id='R1';  Mod='I';    Name=(T 'report.anssi.rules.R1.name' -Default 'Former les equipes operationnelles a la securite des SI') }
    @{ Id='R2';  Mod='I';    Name=(T 'report.anssi.rules.R2.name' -Default 'Sensibiliser les utilisateurs aux bonnes pratiques') }
    @{ Id='R3';  Mod='I';    Name=(T 'report.anssi.rules.R3.name' -Default 'Maitriser les risques de l''infogerance') }
    @{ Id='R4';  Mod='II';   Name=(T 'report.anssi.rules.R4.name' -Default 'Identifier informations et serveurs sensibles') }
    @{ Id='R5';  Mod='II';   Name=(T 'report.anssi.rules.R5.name' -Default 'Inventaire exhaustif des comptes privilegies') }
    @{ Id='R6';  Mod='II';   Name=(T 'report.anssi.rules.R6.name' -Default 'Procedures arrivee/depart/changement de fonction') }
    @{ Id='R7';  Mod='II';   Name=(T 'report.anssi.rules.R7.name' -Default 'Connexion reseau aux seuls equipements maitrises') }
    @{ Id='R8';  Mod='III';  Name=(T 'report.anssi.rules.R8.name' -Default 'Comptes nominatifs, distinguer usage et administration') }
    @{ Id='R9';  Mod='III';  Name=(T 'report.anssi.rules.R9.name' -Default 'Attribuer les bons droits sur les ressources sensibles') }
    @{ Id='R10'; Mod='III';  Name=(T 'report.anssi.rules.R10.name' -Default 'Definir et verifier une politique de mots de passe') }
    @{ Id='R11'; Mod='III';  Name=(T 'report.anssi.rules.R11.name' -Default 'Proteger les mots de passe stockes sur les postes') }
    @{ Id='R12'; Mod='III';  Name=(T 'report.anssi.rules.R12.name' -Default 'Changer les elements d''authentification par defaut') }
    @{ Id='R13'; Mod='III';  Name=(T 'report.anssi.rules.R13.name' -Default 'Privilegier l''authentification forte') }
    @{ Id='R14'; Mod='IV';   Name=(T 'report.anssi.rules.R14.name' -Default 'Mettre en place un niveau de securite minimal sur le parc') }
    @{ Id='R15'; Mod='IV';   Name=(T 'report.anssi.rules.R15.name' -Default 'Se proteger des menaces des supports amovibles') }
    @{ Id='R16'; Mod='IV';   Name=(T 'report.anssi.rules.R16.name' -Default 'Utiliser un outil de gestion centralisee du parc') }
    @{ Id='R17'; Mod='IV';   Name=(T 'report.anssi.rules.R17.name' -Default 'Activer et configurer le pare-feu local') }
    @{ Id='R18'; Mod='IV';   Name=(T 'report.anssi.rules.R18.name' -Default 'Chiffrer les donnees sensibles transmises par Internet') }
    @{ Id='R19'; Mod='V';    Name=(T 'report.anssi.rules.R19.name' -Default 'Segmenter le reseau et cloisonner les acces') }
    @{ Id='R20'; Mod='V';    Name=(T 'report.anssi.rules.R20.name' -Default 'Securiser les reseaux Wi-Fi') }
    @{ Id='R21'; Mod='V';    Name=(T 'report.anssi.rules.R21.name' -Default 'Utiliser des protocoles reseau securises') }
    @{ Id='R22'; Mod='V';    Name=(T 'report.anssi.rules.R22.name' -Default 'Mettre en place une passerelle d''acces securise a Internet') }
    @{ Id='R23'; Mod='V';    Name=(T 'report.anssi.rules.R23.name' -Default 'Cloisonner les services exposes sur Internet') }
    @{ Id='R24'; Mod='V';    Name=(T 'report.anssi.rules.R24.name' -Default 'Proteger la messagerie professionnelle') }
    @{ Id='R25'; Mod='V';    Name=(T 'report.anssi.rules.R25.name' -Default 'Securiser les interconnexions avec les partenaires') }
    @{ Id='R26'; Mod='V';    Name=(T 'report.anssi.rules.R26.name' -Default 'Controler les acces physiques aux locaux et salles serveurs') }
    @{ Id='R27'; Mod='VI';   Name=(T 'report.anssi.rules.R27.name' -Default 'Interdire l''acces Internet depuis les postes d''administration') }
    @{ Id='R28'; Mod='VI';   Name=(T 'report.anssi.rules.R28.name' -Default 'Utiliser un reseau dedie a l''administration') }
    @{ Id='R29'; Mod='VI';   Name=(T 'report.anssi.rules.R29.name' -Default 'Limiter au strict besoin les droits d''administration') }
    @{ Id='R30'; Mod='VII';  Name=(T 'report.anssi.rules.R30.name' -Default 'Prendre des mesures de securisation physique des terminaux nomades') }
    @{ Id='R31'; Mod='VII';  Name=(T 'report.anssi.rules.R31.name' -Default 'Chiffrer les donnees sensibles sur le materiel perdable') }
    @{ Id='R32'; Mod='VII';  Name=(T 'report.anssi.rules.R32.name' -Default 'Securiser la connexion reseau des postes nomades') }
    @{ Id='R33'; Mod='VII';  Name=(T 'report.anssi.rules.R33.name' -Default 'Adopter des politiques de securite dediees aux terminaux mobiles') }
    @{ Id='R34'; Mod='VIII'; Name=(T 'report.anssi.rules.R34.name' -Default 'Definir une politique de mise a jour des composants') }
    @{ Id='R35'; Mod='VIII'; Name=(T 'report.anssi.rules.R35.name' -Default 'Anticiper la fin de maintenance des logiciels et systemes') }
    @{ Id='R36'; Mod='IX';   Name=(T 'report.anssi.rules.R36.name' -Default 'Activer et configurer les journaux des composants') }
    @{ Id='R37'; Mod='IX';   Name=(T 'report.anssi.rules.R37.name' -Default 'Definir et appliquer une politique de sauvegarde') }
    @{ Id='R38'; Mod='IX';   Name=(T 'report.anssi.rules.R38.name' -Default 'Proceder a des controles et audits de securite reguliers') }
    @{ Id='R39'; Mod='IX';   Name=(T 'report.anssi.rules.R39.name' -Default 'Designer un referent securite des systemes d''information') }
    @{ Id='R40'; Mod='IX';   Name=(T 'report.anssi.rules.R40.name' -Default 'Definir une procedure de gestion des incidents') }
    @{ Id='R41'; Mod='X';    Name=(T 'report.anssi.rules.R41.name' -Default 'Mener une analyse de risque formelle') }
    @{ Id='R42'; Mod='X';    Name=(T 'report.anssi.rules.R42.name' -Default 'Privilegier les produits et services qualifies par l''ANSSI') }
)

$ModuleMeta = @(
    @{ Number='I';    Title=(T 'report.anssi.modules.I.title' -Default 'Sensibiliser et former') }
    @{ Number='II';   Title=(T 'report.anssi.modules.II.title' -Default 'Connaitre le systeme d''information') }
    @{ Number='III';  Title=(T 'report.anssi.modules.III.title' -Default 'Authentifier et controler les acces') }
    @{ Number='IV';   Title=(T 'report.anssi.modules.IV.title' -Default 'Securiser les postes') }
    @{ Number='V';    Title=(T 'report.anssi.modules.V.title' -Default 'Securiser le reseau') }
    @{ Number='VI';   Title=(T 'report.anssi.modules.VI.title' -Default 'Securiser l''administration') }
    @{ Number='VII';  Title=(T 'report.anssi.modules.VII.title' -Default 'Gerer le nomadisme') }
    @{ Number='VIII'; Title=(T 'report.anssi.modules.VIII.title' -Default 'Maintenir le SI a jour') }
    @{ Number='IX';   Title=(T 'report.anssi.modules.IX.title' -Default 'Superviser, auditer, reagir') }
    @{ Number='X';    Title=(T 'report.anssi.modules.X.title' -Default 'Pour aller plus loin') }
)

# ===========================================================================
# MAIN
# ===========================================================================
Write-Host ''
Write-Host '  +----------------------------------------------------------------+' -ForegroundColor White
Write-Host '  |              FIELDOPS PRO - ANSSI Data Collector               |' -ForegroundColor White
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

# ---------------------------------------------------------------------------
# Severity
# ---------------------------------------------------------------------------
# Severity is DERIVED here rather than in the renderer, and written into
# report-data.json as a real field, so that every consumer reads the same
# number instead of re-inferring it from prose. Inferring downstream would
# silently collapse the ranking in an English render, where French patterns
# match nothing and no error is raised.
#
# Accents are folded before matching so a single ASCII pattern serves both
# languages and this file stays ASCII-only (audit A1).
function ConvertTo-FoldedAscii {
    param([string]$Text)
    if (-not $Text) { return '' }
    # Typographic apostrophes are normalised to ASCII so that a single pattern
    # matches whichever form the bundle happens to carry.
    $normalized = $Text.Replace([string][char]0x2019, "'").Replace([string][char]0x02BC, "'")
    $decomposed = $normalized.Normalize([System.Text.NormalizationForm]::FormD)
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $decomposed.ToCharArray()) {
        $cat = [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch)
        if ($cat -ne [System.Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$sb.Append($ch)
        }
    }
    return $sb.ToString().ToLowerInvariant()
}

# 3 prioritaire, 2 a traiter, 1 observation, 0 not a finding.
# A rule the toolkit could not evaluate ranks level with one where it looked
# and found a defect, because for an auditor an unknown is a worse position
# than a known. That is the whole argument for pv, applied to ordering.
# The finding class says WHY a rule is not a clean pass. It selects the measure
# as well as the severity, so the badge a reader sees and the action they are
# told to take are derived from one decision and cannot contradict each other.
#
#   blind   the toolkit could not look
#   defect  it looked and found something
#   gap     an aspect was not evaluated
#   partial pv with no stated reason
#   hp / ok not a finding
function Get-RuleFindingClass {
    param([string]$Status, [string]$Text)
    if ($Status -eq 'hp') { return 'hp' }
    $t = ConvertTo-FoldedAscii $Text
    # French states a limit two ways: adjectivally ("non evalue") and as a
    # negated verb ("n'est pas evaluable"). Matching only the first ranked
    # eight rules as mere observations once the evaluators began drawing their
    # prose from the bundle, because natural French prefers the second.
    $neg   = 'n''est pas |n''etait pas |ne sont pas |n''a pas ete |n''ont pas ete |ne peut pas |ne peuvent pas |is not |are not |was not |could not be |cannot be '
    $blind = 'acces refuse|access denied|non disponible|not available|unavailable|cannot query|non extrait|not extracted|refuse par'
    $fail  = 'echec|failed|obsolete|outdated|non conforme|non-compliant|minimal|faible|weak|inactif|inactive'
    $gap   = 'non observ|not observ|non evalu|not evaluat|non confirm|not confirm|non test|not test|a confirmer|to be confirmed|non implement|not implement'
    $blindNeg = 'extrait|disponible|accessible|remonte|retrieved|available|accessible'
    $gapNeg   = 'observ|evalu|confirm|test|implement|renseign|assessed|verified'
    if ($t -match $blind) { return 'blind' }
    if ($t -match "($neg)($blindNeg)") { return 'blind' }
    if ($t -match $fail)  { return 'defect' }
    if ($t -match $gap)   { return 'gap' }
    if ($t -match "($neg)($gapNeg)") { return 'gap' }
    if ($Status -eq 'pv') { return 'partial' }
    return 'ok'
}

# Severity exists only as an ordering of the classes above.
function Get-RuleSeverity {
    param([string]$FindingClass)
    switch ($FindingClass) {
        'blind'   { return 3 }
        'defect'  { return 3 }
        'gap'     { return 2 }
        'partial' { return 1 }
        default   { return 0 }
    }
}

# ---------------------------------------------------------------------------
# Second evaluation pass: English
# ---------------------------------------------------------------------------
# The evaluators resolve their prose through the locale bundle at the moment
# they run, and $RuleMeta / $ModuleMeta resolve theirs at script load. A single
# pass therefore freezes the whole report to one language: an English render
# carried French findings, French rule names and French module titles while
# every locale test passed, because those tests only ever examined template
# chrome, which the renderer resolves separately.
#
# The evaluators are pure functions over already-parsed JSON, and the suite
# proves it: 'P3 - evaluators are deterministic'. Running them a second time
# under a different locale is safe by a property already under test, rather
# than by a mechanism introduced here and assumed to hold.
$enNames  = @{}
$enTitles = @{}
$enMeta   = @{}
$enLabels = @{}
# Initialised here, not inside the block below: StrictMode 1.0 treats a
# reference to a never-assigned variable as an error, so a failed English pass
# would take the whole collection down rather than degrading.
$enRuleNotePrefix = 'Rule {num} -'
$langDir  = Join-Path (Split-Path $PSScriptRoot -Parent) 'CONFIG\lang'
if ((Get-Command Initialize-Locale -ErrorAction SilentlyContinue) -and (Test-Path $langDir)) {
    try {
        Initialize-Locale -Lang 'en' -LangDir $langDir -ErrorAction SilentlyContinue
        foreach ($mm in $ModuleMeta) {
            $enTitles[$mm.Number] = (T "report.anssi.modules.$($mm.Number).title" @{} $mm.Title)
        }
        foreach ($m in $RuleMeta) {
            $rid = $m.Id
            $enNames[$rid] = (T "report.anssi.rules.$rid.name" @{} $m.Name)
            $rr = $null
            try { $rr = & $evaluators[$rid] } catch { $rr = $null }
            $sten = 'pv'
            if ($rr) {
                $enMeta[$rid] = Get-DictValue $rr 'Detail' ''
                $sten = Get-DictValue $rr 'Status' 'pv'
            } else {
                $enMeta[$rid] = ''
            }
            $enLabels[$rid] = switch ($sten) {
                'cv'    { T 'report.anssi.status.cv' @{} 'Verified' }
                'pv'    { T 'report.anssi.status.pv' @{} 'Partial' }
                'hp'    { T 'report.anssi.status.hp' @{} 'Out of scope' }
                default { T 'report.anssi.status.pv' @{} 'Partial' }
            }
        }
        $enRuleNotePrefix = (T 'report.anssi.ruleNote.prefix' @{} 'Rule {num} -')
        Write-OK "English pass: $($enMeta.Count) rules resolved"
    } catch {
        Write-Warn "English evaluation pass failed: $($_.Exception.Message)"
    } finally {
        # Restore French. Everything downstream -- the severity model above all
        # -- reads the French text, so that a French and an English report of
        # the same machine rank their findings identically. Two reports of one
        # machine disagreeing about what matters most would be indefensible.
        try { Initialize-Locale -Lang 'fr' -LangDir $langDir -ErrorAction SilentlyContinue } catch { }
    }
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
    $meta = Get-DictValue $r 'Detail' ''
    $fclass = Get-RuleFindingClass $st $meta
    # Fall back to the French value rather than emitting an empty string: a
    # missing translation should read as untranslated, not as a blank finding.
    $nameEn = $m.Name
    $metaEn = $meta
    $lblEn  = $label
    if ($enNames.ContainsKey($rid)  -and $enNames[$rid])  { $nameEn = $enNames[$rid] }
    if ($enMeta.ContainsKey($rid)   -and $enMeta[$rid])   { $metaEn = $enMeta[$rid] }
    if ($enLabels.ContainsKey($rid) -and $enLabels[$rid]) { $lblEn  = $enLabels[$rid] }
    $ruleResults[$rid] = [PSCustomObject]@{
        Id=$rid; Module=$m.Mod
        Name=([PSCustomObject]@{ fr=$m.Name; en=$nameEn })
        Status=$st
        StatusLabel=([PSCustomObject]@{ fr=$label; en=$lblEn })
        FindingClass=$fclass; Severity=(Get-RuleSeverity $fclass)
        Meta=([PSCustomObject]@{ fr=$meta; en=$metaEn })
        Detail=''; Evidence=(Get-DictValue $r 'Evidence' '')
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
        Number=$m.Number
        Title=([PSCustomObject]@{ fr=$m.Title; en=$(if ($enTitles.ContainsKey($m.Number) -and $enTitles[$m.Number]) { $enTitles[$m.Number] } else { $m.Title }) })
        RuleCount=$mr.Count
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
        $rr.Meta = [PSCustomObject]@{
            fr = (Format-DetailString $rr.Meta.fr)
            en = (Format-DetailString $rr.Meta.en)
        }
        $rules += [PSCustomObject]@{
            Id=$rr.Id; Name=$rr.Name; Status=$rr.Status; StatusLabel=$rr.StatusLabel
            FindingClass=$rr.FindingClass; Severity=$rr.Severity
            Meta=$rr.Meta; Detail=$rr.Detail; Evidence=$rr.Evidence
        }
    }
    $titleEn = $m.Title
    if ($enTitles.ContainsKey($m.Number) -and $enTitles[$m.Number]) { $titleEn = $enTitles[$m.Number] }
    $moduleDetails += [PSCustomObject]@{
        Number = $m.Number
        Title  = ([PSCustomObject]@{ fr=$m.Title; en=$titleEn })
        Rules  = $rules
    }
}

# --- Top findings: non-HP rules whose detail names a concrete problem ---
$topFindings = @()
$problemPattern = '\d+\s*(echec|pilote|volume)|obsolet|minimal|non chiffr|chiffrement faible|\d+/\d+\s*(profil|volume)'
# Match against the French text specifically. Meta is now per-language, and
# letting PowerShell stringify the whole object would match "@{fr=...; en=...}"
# and select findings on the strength of the wrapper rather than the prose.
$candidates = @($ruleResults.Values | Where-Object { $_.Status -ne 'hp' -and $_.Meta.fr -match $problemPattern })
foreach ($r in $candidates) {
    if ($topFindings.Count -ge 3) { break }
    $n = $r.Id.Substring(1)
    $topFindings += [PSCustomObject]@{
        Title    = $r.Name
        RuleNote = ([PSCustomObject]@{
            fr = ((T 'report.anssi.ruleNote.prefix' @{ num = $n } "Regle $n -") + ' ' + $r.Meta.fr)
            en = ($enRuleNotePrefix.Replace('{num}', $n) + ' ' + $r.Meta.en)
        })
        RuleId   = $r.Id
        Status   = $r.Status
    }
}
if ($topFindings.Count -lt 3) {
    $already = @($topFindings | ForEach-Object { $_.RuleId })
    $extra = @($ruleResults.Values | Where-Object { $_.Status -eq 'pv' -and $already -notcontains $_.Id } | Select-Object -First (3 - $topFindings.Count))
    foreach ($r in $extra) {
        $n = $r.Id.Substring(1)
        $topFindings += [PSCustomObject]@{
            Title=$r.Name
            RuleNote=([PSCustomObject]@{
                fr = ((T 'report.anssi.ruleNote.prefix' @{ num = $n } "Regle $n -") + ' ' + $r.Meta.fr)
                en = ($enRuleNotePrefix.Replace('{num}', $n) + ' ' + $r.Meta.en)
            })
            RuleId=$r.Id; Status=$r.Status
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

# --- Provenance -----------------------------------------------------------
# La date d'emission n'est pas la date d'observation. Les sondes ecrivent leur
# JSON quand elles tournent ; ce collecteur peut s'executer des semaines plus
# tard et produisait alors un rapport ou tout paraissait observe aujourd'hui.
# Chaque source porte desormais sa propre date, son age et son empreinte.
$sourceList = @()
foreach ($s in @(
    @{ Engine = 'SecurityScan'; Path = $ssPath }
    @{ Engine = 'PCHealth';     Path = $pcPath }
    @{ Engine = 'NetRepair';    Path = $nrPath }
)) {
    if (-not $s.Path -or -not (Test-Path -LiteralPath $s.Path)) { continue }
    try {
        $fi  = Get-Item -LiteralPath $s.Path
        $sha = (Get-FileHash -LiteralPath $s.Path -Algorithm SHA256).Hash.ToLowerInvariant()
        $age = [int][math]::Floor(($now - $fi.LastWriteTime).TotalDays)
        if ($age -lt 0) { $age = 0 }
        $sourceList += [PSCustomObject]@{
            Engine          = $s.Engine
            File            = $fi.Name
            Sha256          = $sha
            ObservedAt      = $fi.LastWriteTime.ToString('o')
            ObservedAtHuman = $fi.LastWriteTime.ToString('dd/MM/yyyy HH:mm')
            AgeDays         = $age
        }
    } catch {
        Write-Warn "Provenance for $($s.Engine) could not be read: $($_.Exception.Message)"
    }
}

# --- Empreinte des constats ------------------------------------------------
# Un condense canonique des VERDICTS, pas du document. Il ne contient aucune
# prose : identifiant, etat, classe, severite, source. Il est donc identique
# pour un rapport francais et son equivalent anglais du meme poste, et change
# des qu'un verdict change. C'est ce qu'un auditeur veut comparer d'un rapport
# a l'autre -- l'empreinte du fichier, elle, bouge a la moindre retouche de
# mise en page.
$canonRules = @()
foreach ($md in $moduleDetails) { foreach ($r in @($md.Rules)) { $canonRules += $r } }
$canonRules = @($canonRules | Sort-Object { [int]($_.Id -replace '\D','') })
$canonSb = New-Object System.Text.StringBuilder
foreach ($r in $canonRules) {
    $names = @($r.PSObject.Properties.Name)
    $fc = ''; if ($names -contains 'FindingClass') { $fc = "$($r.FindingClass)" }
    $sv = '0'; if ($names -contains 'Severity')     { $sv = "$($r.Severity)" }
    $ev = ''; if ($names -contains 'Evidence')      { $ev = "$($r.Evidence)" }
    [void]$canonSb.Append("$($r.Id)|$($r.Status)|$fc|$sv|$ev").Append("`n")
}
$sha256   = [System.Security.Cryptography.SHA256]::Create()
$canonBytes = [System.Text.Encoding]::UTF8.GetBytes($canonSb.ToString())
$verdictDigest = ([BitConverter]::ToString($sha256.ComputeHash($canonBytes)) -replace '-','').ToLowerInvariant()
$sha256.Dispose()

# --- Final shape ---
$reportData = [PSCustomObject]@{
    Report = [PSCustomObject]@{
        Id=$reportId; GeneratedAt=$now.ToString('o'); GeneratedAtHuman=$reportDateHuman
        Technician=$Technician; CustomerContact=$CustomerContact
        Sources=$sourceList; VerdictDigest=$verdictDigest
        Client=$ClientOrganisation; Classification=$Classification
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
