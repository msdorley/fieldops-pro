---
id: RB-BL-003
title: Encrypt a fixed data volume left unprotected
category: BL
severity: medium
prerequisites:
  - Administrator rights
  - System volume already encrypted and protected
  - Volume is a fixed internal disk, not removable
relatedRules:
  anssi: [R31]
estimatedDurationMinutes: 20
revertable: true
schemaVersion: "1.0"
---

# RB-BL-003 -- Encrypt a fixed data volume left unprotected

## When to use this

The system volume is encrypted but a second fixed volume -- a `D:` data
partition, a second internal SSD -- is not. Users store working files there
precisely because it is the "data drive", so the unprotected volume frequently
holds more sensitive material than the encrypted one.

This is the normal outcome of an imaging process that encrypts only the OS
volume, so finding it on one machine usually means finding it on the whole
batch.

**Do not use this playbook** on:

- **Removable drives.** `BitLocker To Go` is governed by different policy and
  different recovery expectations. Check `DriveType` before you start.
- **Volumes that rotate between machines** -- external backup targets, swap
  disks used for data transfer. Auto-unlock binds the volume to *this* machine;
  encrypting it here can make it unreadable where it is actually needed.
- **A machine whose system volume is not itself protected.** Fix that first
  (RB-BL-001), or you are adding a second recovery burden to a machine that
  cannot protect the first one.

## Verify the condition first

```powershell
Get-BitLockerVolume | Select-Object MountPoint, VolumeType, VolumeStatus, ProtectionStatus
```

Confirm the target shows `VolumeStatus: FullyDecrypted`, and that the system
volume shows `FullyEncrypted` / `On`.

Confirm the volume is genuinely fixed:

```powershell
Get-Volume -DriveLetter D | Select-Object DriveLetter, DriveType, FileSystemType, Size, SizeRemaining
```

`DriveType` must be `Fixed`. Anything else, stop.

**Check free space.** Encryption needs room to work and the volume must not be
near full.

## Procedure

### 1. Enable encryption with a recovery password

```powershell
Enable-BitLocker -MountPoint 'D:' `
                 -EncryptionMethod XtsAes256 `
                 -UsedSpaceOnly `
                 -RecoveryPasswordProtector
```

`-UsedSpaceOnly` encrypts written space rather than the whole volume. On a
mostly-empty disk this is the difference between minutes and hours. On a volume
that previously held sensitive data now deleted, prefer full encryption: omit
the switch, and expect it to run considerably longer.

### 2. Escrow the recovery key immediately

A newly encrypted volume with an unescrowed key is RB-BL-002 all over again, on
a volume nobody thinks to check. Do it now, not later:

```powershell
$id = ((Get-BitLockerVolume -MountPoint 'D:').KeyProtector |
        Where-Object KeyProtectorType -eq 'RecoveryPassword').KeyProtectorId
BackupToAAD-BitLockerKeyProtector -MountPoint 'D:' -KeyProtectorId $id
```

### 3. Enable auto-unlock

Without this the user is prompted for a password at every boot, and the ticket
comes straight back.

```powershell
Enable-BitLockerAutoUnlock -MountPoint 'D:'
```

Auto-unlock requires the system volume to be protected -- which is why that was
a prerequisite rather than a suggestion.

### 4. Confirm, and let it finish

```powershell
Get-BitLockerVolume -MountPoint 'D:' |
    Select-Object VolumeStatus, ProtectionStatus, EncryptionPercentage
```

Encryption continues in the background. Hands-on time is roughly twenty minutes;
the volume may take hours to reach 100 percent, and the machine is usable
throughout. Do not reimage or shut down abruptly during the pass.

## Rollback

```powershell
Disable-BitLocker -MountPoint 'D:'
```

Honest about the cost: decryption takes as long as encryption did, runs in the
background, and leaves the data exposed the moment it completes. It is the right
call only if encrypting the volume is shown to break a documented business
requirement -- a disk that must be readable in another machine, typically -- and
that requirement should then be recorded so the next technician does not
"remediate" it again.

## If it does not hold

- **`Enable-BitLocker` fails with a policy error.** Group Policy or Intune is
  enforcing a specific encryption method or protector set. Match the policy
  rather than overriding it locally; a local override drifts back at the next
  policy refresh.
- **Auto-unlock refuses.** The system volume is not protected. Return to
  RB-BL-001.
- **Encryption stalls at a fixed percentage.** Usually a disk with bad sectors.
  Stop and check `Get-PhysicalDisk` health and the system event log before
  continuing -- pushing encryption through a failing disk is how a recoverable
  problem becomes data loss.

## Related

- ANSSI Guide d'hygiene informatique, R31 (chiffrement des volumes)
