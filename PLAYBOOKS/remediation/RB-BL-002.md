---
id: RB-BL-002
title: Escrow a BitLocker recovery key that was never backed up
category: BL
severity: high
prerequisites:
  - Administrator rights
  - Device joined or registered to Entra ID (Azure AD)
  - Network connectivity to the tenant
relatedRules:
  anssi: [R31]
estimatedDurationMinutes: 10
revertable: false
schemaVersion: "1.0"
---

# RB-BL-002 -- Escrow a BitLocker recovery key that was never backed up

## When to use this

A volume is encrypted and protected, but its recovery password has never been
backed up anywhere the organisation can reach. The machine is secure and
entirely unrecoverable: a TPM failure, a motherboard swap, or a firmware change
that alters the boot measurement leaves the data gone.

This is the single most expensive BitLocker misconfiguration, because nothing
reveals it until the day recovery is needed.

**Do not use this playbook** on a device that is not joined or registered to
Entra ID -- the escrow call will fail and you will have logged a fix that never
happened. Check first. In an on-premises Active Directory environment the
equivalent is `Backup-BitLockerKeyProtector` against AD DS, which is a different
procedure and a different policy.

Also do not use it as a substitute for MDM policy. Escrowing by hand fixes one
machine; if the fleet is unescrowed, the Intune or GPO setting is the actual
defect.

## Verify the condition first

Confirm the device can escrow at all:

```powershell
dsregcmd /status
```

Look for `AzureAdJoined : YES` or `WorkplaceJoined : YES`. If both are NO, stop.

Then list the protectors and find the recovery password:

```powershell
(Get-BitLockerVolume -MountPoint 'C:').KeyProtector |
    Where-Object KeyProtectorType -eq 'RecoveryPassword' |
    Select-Object KeyProtectorId, RecoveryPassword
```

If there is no recovery password protector at all, create one before escrowing:

```powershell
Add-BitLockerKeyProtector -MountPoint 'C:' -RecoveryPasswordProtector
```

**Treat the recovery password itself as sensitive.** Do not paste it into a
ticket, a chat message, or a report. The point of this playbook is to place it
somewhere controlled, not to spread copies of it.

## Procedure

### 1. Capture the protector ID

```powershell
$id = ((Get-BitLockerVolume -MountPoint 'C:').KeyProtector |
        Where-Object KeyProtectorType -eq 'RecoveryPassword').KeyProtectorId
$id
```

If more than one is returned, escrow each of them -- an unescrowed spare
protector is the same problem you came to fix.

### 2. Escrow to Entra ID

```powershell
BackupToAAD-BitLockerKeyProtector -MountPoint 'C:' -KeyProtectorId $id
```

The cmdlet is silent on success.

### 3. Verify the escrow actually landed

Silence is not confirmation. Check the operational log:

```powershell
Get-WinEvent -LogName 'Microsoft-Windows-BitLocker/BitLocker Management' -MaxEvents 20 |
    Where-Object Id -in 845, 846 |
    Select-Object TimeCreated, Id, Message
```

Event 845 records a successful backup to Entra ID; 846 records the failure. If
you see neither, the call did not reach the tenant -- treat that as unresolved,
not as done.

The authoritative confirmation is the key appearing under the device in the
Entra admin centre. Where the environment allows it, check there before closing
the ticket.

## Rollback

**None, deliberately.** A recovery key cannot be un-escrowed, and there is no
circumstance in which you would want to. This is why the front matter declares
`revertable: false`: this procedure must never be offered as an automated fix
that something else can undo.

If a key must be invalidated -- suspected disclosure, for instance -- the
correct response is to remove the protector and add a fresh one, which is a
different procedure with different approvals.

## If it does not hold

- **Event 846 with an authentication error.** The device's Entra registration is
  stale. `dsregcmd /leave` then re-register, or re-enrol via MDM.
- **No event at all.** The Entra endpoint is unreachable -- proxy, captive
  portal, or a firewall rule. Confirm with a plain HTTPS test before blaming
  BitLocker.
- **Escrow succeeds, key absent in the portal.** Directory replication delay, or
  you are looking at a different device object. Confirm the device ID from
  `dsregcmd /status` rather than matching on hostname.

## Related

- ANSSI Guide d'hygiene informatique, R31 (chiffrement des volumes)
