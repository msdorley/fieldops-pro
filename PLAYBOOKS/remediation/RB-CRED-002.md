---
id: RB-CRED-002
title: Remove a plaintext auto-logon password from the registry
category: CRED
severity: critical
prerequisites:
  - Administrator rights
  - Confirmation of whether unattended logon is genuinely required
relatedRules:
  anssi: [R12]
estimatedDurationMinutes: 15
revertable: true
schemaVersion: "1.0"
---

# RB-CRED-002 -- Remove a plaintext auto-logon password from the registry

## When to use this

`AutoAdminLogon` is enabled and `DefaultPassword` holds an account password **in
clear text** under the Winlogon key. That value is readable by any local
account -- no administrator rights, no memory dumping, no tooling. A standard
user can read it with one command.

It is frequently a domain or privileged account, because auto-logon was
configured for a kiosk, a shop-floor terminal, a digital sign, or a test rig and
the nearest available credential was used.

**Do not simply delete auto-logon** without establishing whether the machine
needs it. A kiosk that stops logging in at boot is an outage, and the ticket
comes back with the plaintext password restored. Determine the requirement
first, then choose the path below.

## Verify the condition first

```powershell
$wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Get-ItemProperty -Path $wl |
    Select-Object AutoAdminLogon, DefaultUserName, DefaultDomainName,
                  @{n='DefaultPasswordPresent';e={ $null -ne $_.DefaultPassword }}
```

Note the deliberate projection: it reports **whether** a password is present
without printing it. Do not query `DefaultPassword` directly into a console,
transcript, or ticket. A logged remediation that contains the password is worse
than the finding.

Confirm the finding when `AutoAdminLogon` is `1` **and** a `DefaultPassword`
value exists.

Establish the business need before changing anything: is this an unattended
kiosk or appliance, or a normal user workstation where auto-logon was a
convenience?

## Procedure

### Path A -- auto-logon is not required (normal workstation)

#### 1. Remove the password and disable auto-logon

```powershell
$wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Remove-ItemProperty -Path $wl -Name 'DefaultPassword' -ErrorAction SilentlyContinue
Set-ItemProperty   -Path $wl -Name 'AutoAdminLogon' -Value '0' -Type String
```

#### 2. Clear the residual identity hints

Not sensitive, but leaving them invites the next technician to "restore" the
configuration:

```powershell
Remove-ItemProperty -Path $wl -Name 'DefaultUserName'   -ErrorAction SilentlyContinue
Remove-ItemProperty -Path $wl -Name 'DefaultDomainName' -ErrorAction SilentlyContinue
```

#### 3. Confirm

```powershell
Get-ItemProperty -Path $wl |
    Select-Object AutoAdminLogon,
                  @{n='DefaultPasswordPresent';e={ $null -ne $_.DefaultPassword }}
```

Expect `0` and `False`.

### Path B -- unattended logon is genuinely required

Do **not** re-add a plaintext value. Configure auto-logon so the credential is
stored as an LSA secret instead, which is not readable by a standard user. The
Sysinternals `Autologon` utility does this, and is the supported route.

Then reduce the blast radius, which matters more than the storage method:

- The auto-logon account must be a **local, non-privileged** account created for
  this purpose -- never a domain account, never an administrator.
- It should have no network resource access it does not need.
- Record the exception where the next audit will find it.

### 4. Change the exposed password -- in both paths

The password was readable by every local user for as long as the value existed.
Removing it stops further exposure; it does not undo what has already happened.
Have the account's password changed, and if it was a domain or privileged
account, treat that as an incident rather than a maintenance task.

## Rollback

Auto-logon can be restored via Path B at any time. **Restoring the plaintext
`DefaultPassword` value is not a rollback and must not be performed** -- it
recreates the exact defect this playbook exists to remove.

The front matter marks this playbook revertable because the *behaviour*
(unattended logon) can be restored safely. The insecure *implementation* cannot.

## If it does not hold

- **`AutoAdminLogon` returns to 1 with a plaintext password.** A deployment
  script or task sequence is rewriting it. Fix the image or the sequence; the
  endpoint will keep losing.
- **The kiosk stops working after Path A.** It needed auto-logon. Move to Path B
  rather than reverting.
- **The account is a domain administrator.** Stop treating this as a workstation
  ticket and escalate. A domain admin password readable by any local user on a
  shared machine is an incident.

## Related

- ANSSI Guide d'hygiene informatique, R12 (comptes et ouverture de session automatique)
