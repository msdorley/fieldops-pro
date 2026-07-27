---
id: RB-AV-001
title: Re-enable Microsoft Defender real-time protection
category: AV
severity: high
prerequisites:
  - Administrator rights
  - No third-party antivirus currently registered as primary provider
relatedRules:
  anssi: [R8]
estimatedDurationMinutes: 5
revertable: true
schemaVersion: "1.0"
---

# RB-AV-001 -- Re-enable Microsoft Defender real-time protection

## When to use this

Real-time protection is reported disabled while Microsoft Defender is still the
registered antivirus provider. This is the state left behind by a malware
dropper, an over-broad "performance tuning" script, or a Group Policy applied to
the wrong OU.

**Do not use this playbook** when a third-party antivirus is the registered
primary provider. Defender disables its own real-time protection by design in
that case, and the machine is protected. Forcing Defender back on alongside
another engine causes file-lock contention and is a regression, not a fix.

## Verify the condition first

```powershell
Get-MpComputerStatus | Select-Object AMRunningMode, RealTimeProtectionEnabled,
                                     AntivirusEnabled, IsTamperProtected
```

Proceed only when `RealTimeProtectionEnabled` is `False` and `AMRunningMode` is
`Normal`. `AMRunningMode` of `Passive` or `EDR Block Mode` means another product
owns protection.

Check whether policy is enforcing the disabled state:

```powershell
Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender' `
                 -ErrorAction SilentlyContinue
Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection' `
                 -ErrorAction SilentlyContinue
```

A `DisableAntiSpyware` or `DisableRealtimeMonitoring` value of `1` means policy
is the cause. Changing the runtime setting will not hold; the policy must be
corrected at source.

## Procedure

### If tamper protection is on

Tamper protection blocks programmatic changes by design, and that is correct
behaviour. It cannot be disabled from the command line. Turn it off in the
Windows Security app (Virus & threat protection -> Manage settings), complete
the steps below, then turn it back on.

### 1. Re-enable real-time monitoring

```powershell
Set-MpPreference -DisableRealtimeMonitoring $false
```

### 2. Confirm

```powershell
(Get-MpComputerStatus).RealTimeProtectionEnabled   # expect True
```

### 3. Update signatures

A machine that had protection off is likely behind on definitions.

```powershell
Update-MpSignature
```

### 4. Run a quick scan

```powershell
Start-MpScan -ScanType QuickScan
```

If the disabled state was caused by malware rather than misconfiguration, the
quick scan is the step that finds out.

## Rollback

```powershell
Set-MpPreference -DisableRealtimeMonitoring $true
```

Rollback is documented for completeness and to satisfy `revertable: true`. It
returns the machine to a less secure state and should only be used when
re-enabling protection is shown to have broken a business-critical application,
and only until the conflict is resolved.

## If it does not hold

Real-time protection switching itself back off within minutes points to one of:

- **Group Policy re-application.** Confirm with `gpresult /h gpreport.html` and
  correct the GPO. The endpoint is not the right place to fix this.
- **Active malware.** Boot the Microsoft Defender Offline scan
  (`Start-MpWDOScan`) and escalate.
- **A third-party product mid-install.** Re-check `AMRunningMode`.

## Related

- ANSSI Guide d'hygiene informatique, R8 (anti-malware protection)
