---
id: RB-WU-001
title: Repair a stalled Windows Update client
category: WU
severity: high
prerequisites:
  - Administrator rights
  - At least 2 GB free on the system volume
relatedRules:
  anssi: [R34]
estimatedDurationMinutes: 30
revertable: true
schemaVersion: "1.0"
---

# RB-WU-001 -- Repair a stalled Windows Update client

## When to use this

The update mechanism itself is broken: scans fail, the same update fails
repeatedly with the same error, or no update has installed for months while the
machine reports no pending work. The endpoint looks healthy and is quietly
falling behind on security fixes.

This playbook resets the client's local state -- the download cache and the
cryptographic catalogue store -- so the next scan rebuilds from scratch.

**Do not use this playbook** when updates are deliberately deferred or paused by
policy. A machine held on a pilot ring is behaving correctly, and resetting its
client changes nothing except your confidence. Check the deferral state first;
if that is the cause, RB-WU-002 is the right procedure and it needs the ring
owner's agreement.

Also stop if the machine is mid-installation of a feature update. Clearing
`SoftwareDistribution` during a staged feature update discards work in progress
and can leave the machine in a state that needs more than a reset to recover.

## Verify the condition first

Check the service and the last successful install:

```powershell
Get-Service wuauserv, bits, cryptsvc | Select-Object Name, Status, StartType

Get-HotFix | Sort-Object InstalledOn -Descending |
    Select-Object -First 5 HotFixID, InstalledOn
```

A most-recent install more than a couple of months old on a managed endpoint is
the signal.

Look at what is actually failing:

```powershell
Get-WinEvent -LogName 'System' -MaxEvents 200 |
    Where-Object { $_.ProviderName -like '*WindowsUpdate*' -and $_.LevelDisplayName -in 'Error','Warning' } |
    Select-Object TimeCreated, Id, LevelDisplayName, Message -First 10 |
    Format-List
```

Rule out deferral before resetting anything:

```powershell
Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' -ErrorAction SilentlyContinue |
    Select-Object PauseUpdatesExpiryTime, DeferQualityUpdatesPeriodInDays, DeferFeatureUpdatesPeriodInDays
```

If a pause or deferral is active, stop here and go to RB-WU-002.

## Procedure

### 1. Stop the update services

```powershell
Stop-Service -Name wuauserv, bits, cryptsvc -Force
```

### 2. Rename the cache directories

Renaming rather than deleting is deliberate: it makes the step reversible and
preserves evidence if the reset does not help.

```powershell
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
Rename-Item "$env:SystemRoot\SoftwareDistribution" "SoftwareDistribution.bak-$stamp"
Rename-Item "$env:SystemRoot\System32\catroot2"    "catroot2.bak-$stamp"
```

If a rename fails with a sharing violation, a service did not stop. Confirm with
`Get-Service` and retry rather than forcing it.

### 3. Restart the services

```powershell
Start-Service -Name cryptsvc, bits, wuauserv
```

### 4. Trigger a fresh detection

```powershell
Start-Process -FilePath 'UsoClient.exe' -ArgumentList 'StartScan' -Wait
```

Allow several minutes. Windows rebuilds both directories automatically.

### 5. Confirm

```powershell
Get-Service wuauserv, bits, cryptsvc | Select-Object Name, Status
Test-Path "$env:SystemRoot\SoftwareDistribution"
```

Then check for offered updates through Settings or your management console, and
confirm at least one update reaches download.

### 6. Clean up, once the machine has updated successfully

The `.bak-*` directories can be several gigabytes. Remove them only after a
successful install proves the reset worked:

```powershell
Remove-Item "$env:SystemRoot\SoftwareDistribution.bak-*" -Recurse -Force
Remove-Item "$env:SystemRoot\System32\catroot2.bak-*"    -Recurse -Force
```

## Rollback

```powershell
Stop-Service -Name wuauserv, bits, cryptsvc -Force
Remove-Item "$env:SystemRoot\SoftwareDistribution" -Recurse -Force
Rename-Item "$env:SystemRoot\SoftwareDistribution.bak-<stamp>" 'SoftwareDistribution'
Start-Service -Name cryptsvc, bits, wuauserv
```

Restoring the old cache is rarely useful -- its corruption was usually the
problem -- but the option exists for the case where the reset made a working
machine worse, and it is why step 2 renames instead of deleting.

## If it does not hold

- **Scans still fail with the same error.** The fault is upstream, not local.
  Check WSUS or Intune reachability, and any proxy that intercepts TLS to the
  update endpoints.
- **Component store corruption.** Run `DISM /Online /Cleanup-Image /RestoreHealth`
  followed by `sfc /scannow`. A reset cannot fix a damaged servicing stack.
- **Disk space.** Updates need working room well beyond the download size. A
  volume near full fails in ways that look like client corruption.
- **The machine is out of support.** An end-of-life build receives nothing.
  Confirm with `winver` before spending further time.

## Related

- ANSSI Guide d'hygiene informatique, R34 (mise a jour des composants)
