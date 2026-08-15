---
id: RB-CRED-001
title: Disable WDigest plaintext credential caching
category: CRED
severity: high
prerequisites:
  - Administrator rights
  - Reboot window agreed with the user
relatedRules:
  anssi: [R11]
estimatedDurationMinutes: 10
revertable: true
schemaVersion: "1.0"
---

# RB-CRED-001 -- Disable WDigest plaintext credential caching

## When to use this

`UseLogonCredential` is set to `1` under the WDigest security provider. With
that value present, Windows keeps the interactive user's password in LSASS in a
recoverable form, so anyone who obtains a memory dump obtains the password
itself -- not a hash to crack, the password.

Windows 8.1 and later default to not caching. A machine with the value set to
`1` got there deliberately: a legacy application vendor's install guide, an old
hardening baseline applied in reverse, or an attacker preparing for credential
theft.

**Do not assume it is benign.** If you cannot trace the value to a documented
application requirement, treat its presence as a possible indicator of
compromise and escalate alongside applying the fix -- an attacker who set it was
waiting for the user to log on again.

**Do not use this playbook** where a documented legacy application genuinely
requires WDigest. Those exist, mostly around old HTTP digest authentication.
Establish the requirement, record it, and route the machine to a compensating
control rather than silently breaking a business system.

## Verify the condition first

```powershell
Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest' `
                 -Name 'UseLogonCredential' -ErrorAction SilentlyContinue
```

- Value `1` -- caching is enabled. Proceed.
- Value `0` -- already correct.
- Value absent -- the OS default applies, which is not to cache. No action
  needed, though setting it explicitly to `0` makes the intent auditable.

Check whether policy is delivering it:

```powershell
gpresult /h "$env:TEMP\gpreport.html"
```

If a GPO sets the value, fixing the endpoint alone will not hold.

## Procedure

### 1. Set the value to 0

```powershell
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest' `
                 -Name 'UseLogonCredential' -Value 0 -Type DWord
```

### 2. Confirm

```powershell
(Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest' `
                  -Name 'UseLogonCredential').UseLogonCredential   # expect 0
```

### 3. Reboot

**The change does not take effect until LSASS restarts**, which in practice
means a reboot. Until then the credential is still resident in memory and the
machine is not fixed. A playbook marked complete without this step is a false
report.

```powershell
Restart-Computer
```

### 4. If the value was set maliciously, change the password

Disabling caching stops future exposure. It does not undo past exposure. If the
value's origin is unexplained, assume the credential was captured and have it
changed.

## Rollback

```powershell
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest' `
                 -Name 'UseLogonCredential' -Value 1 -Type DWord
```

Requires a reboot to take effect, and returns the machine to storing passwords
recoverably in memory. Justified only to restore a documented legacy
application while a permanent fix is arranged, and the exception should be
recorded where the next audit will find it.

## If it does not hold

- **The value returns after a policy refresh.** A GPO or an MDM configuration
  profile is setting it. Fix it there.
- **An application breaks after the reboot.** That application was relying on
  WDigest. Identify it precisely before reverting -- "something broke" is not
  grounds for restoring plaintext credential caching across the fleet.
- **The value keeps returning with no policy source.** Treat as active
  compromise and escalate. Something on the machine is re-setting it.

## Related

- ANSSI Guide d'hygiene informatique, R11 (protection des secrets d'authentification)
