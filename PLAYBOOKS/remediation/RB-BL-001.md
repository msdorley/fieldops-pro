---
id: RB-BL-001
title: Resume BitLocker protection left suspended after servicing
category: BL
severity: high
prerequisites:
  - Administrator rights
  - Volume already fully encrypted
relatedRules:
  anssi: [R31]
estimatedDurationMinutes: 5
revertable: true
schemaVersion: "1.0"
---

# RB-BL-001 -- Resume BitLocker protection left suspended after servicing

## When to use this

The system volume is fully encrypted but protection is **off**. BitLocker is
still holding the volume key in the clear so the machine can boot without a
challenge, which means the encryption is providing no protection at all against
someone who takes the disk.

This is the state left behind by a BIOS or firmware update, a Windows feature
update, or a technician who suspended protection for servicing and never
resumed it. It is common and it is quiet: the machine works perfectly and
nothing warns the user.

**Do not use this playbook** when the volume is not already encrypted --
`VolumeStatus` of `FullyDecrypted` means there is nothing to resume, and you
want RB-BL-003 instead. Also stop if a firmware update is deliberately staged
and pending reboot: resuming now only means it suspends itself again at the next
boot, and you will have logged a fix that did not hold.

## Verify the condition first

```powershell
Get-BitLockerVolume -MountPoint 'C:' |
    Select-Object MountPoint, VolumeStatus, ProtectionStatus, EncryptionPercentage
```

Proceed only when `VolumeStatus` is `FullyEncrypted` **and** `ProtectionStatus`
is `Off`. That specific combination is what "suspended" looks like.

Check whether a reboot-count suspension is armed, which tells you the suspension
was deliberate and time-boxed rather than forgotten:

```powershell
manage-bde -status C:
```

Look for `Protection Status: Protection Off (Suspended)` and any reboot count.

## Procedure

### 1. Resume protection

```powershell
Resume-BitLocker -MountPoint 'C:'
```

### 2. Confirm

```powershell
(Get-BitLockerVolume -MountPoint 'C:').ProtectionStatus   # expect On
```

### 3. Confirm a usable key protector exists

Resuming protection is worthless if nobody can recover the volume. Verify at
least one recovery password protector is present:

```powershell
(Get-BitLockerVolume -MountPoint 'C:').KeyProtector |
    Select-Object KeyProtectorType, KeyProtectorId
```

If there is no `RecoveryPassword` entry, or it has never been escrowed, follow
RB-BL-002 before considering this machine finished.

## Rollback

```powershell
Suspend-BitLocker -MountPoint 'C:' -RebootCount 1
```

This returns the machine to the suspended state, surviving exactly one reboot.
Use it only if resuming protection is shown to block a pending firmware update
that must complete first -- and resume again immediately afterwards. Leaving a
machine suspended is the defect this playbook exists to correct.

## If it does not hold

Protection switching itself back off points to one of:

- **A pending firmware or TPM update.** Windows suspends BitLocker deliberately
  across such updates. Let the update complete, reboot, then resume.
- **A deployment task sequence** re-suspending on every run. Fix the sequence;
  the endpoint is not the right place to correct this.
- **TPM not owned or in a bad state.** Check `Get-Tpm` for `TpmReady` and
  `TpmOwned`. A TPM that is present but not ready cannot seal the key, and
  BitLocker falls back to suspension rather than failing loudly.

## Related

- ANSSI Guide d'hygiene informatique, R31 (chiffrement des volumes)
