---
id: RB-FW-001
title: Re-enable a disabled Windows Firewall profile
category: FW
severity: critical
prerequisites:
  - Administrator rights
  - No third-party firewall registered as the active provider
relatedRules:
  anssi: [R17]
estimatedDurationMinutes: 10
revertable: true
schemaVersion: "1.0"
---

# RB-FW-001 -- Re-enable a disabled Windows Firewall profile

## When to use this

One or more firewall profiles -- Domain, Private, Public -- report `Enabled:
False` while Windows Firewall is still the registered provider. The machine is
accepting inbound connections on every open port with nothing in front of it.

Profiles get disabled by a troubleshooting step nobody reversed, by a
"performance" script, by an installer that turned it off to avoid a prompt, or
by malware. A single disabled profile is easy to miss because the other two
often stay on and the machine looks protected in a casual check.

**Do not use this playbook** when a third-party firewall is the registered
active provider. Windows disables its own profiles by design in that case and
the machine is protected. Forcing both on produces duplicate filtering,
hard-to-diagnose connectivity faults, and a support case worse than the one you
started with.

Also stop if Group Policy is enforcing the disabled state -- see below.

## Verify the condition first

```powershell
Get-NetFirewallProfile |
    Select-Object Name, Enabled, DefaultInboundAction, DefaultOutboundAction
```

Note **which** profiles are off. The Domain profile being off on a
corporate-network machine is more urgent than Public being off on a machine that
never leaves the office.

Confirm no third-party product owns the firewall:

```powershell
Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName FirewallProduct |
    Select-Object displayName, productState
```

If a third-party product is listed and current, stop.

Check whether policy is enforcing the state:

```powershell
Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsFirewall\DomainProfile' -ErrorAction SilentlyContinue
Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsFirewall\StandardProfile' -ErrorAction SilentlyContinue
```

An `EnableFirewall` value of `0` means policy is the cause. Changing the runtime
setting will not survive the next policy refresh; the GPO must be corrected at
source.

## Procedure

### 1. Enable the affected profiles

```powershell
Set-NetFirewallProfile -Profile Domain, Private, Public -Enabled True
```

### 2. Confirm the default inbound action blocks

An enabled firewall that allows inbound by default is not a firewall. Check it
in the same pass:

```powershell
Set-NetFirewallProfile -Profile Domain, Private, Public -DefaultInboundAction Block
Get-NetFirewallProfile | Select-Object Name, Enabled, DefaultInboundAction
```

All three should read `True` / `Block`.

### 3. Confirm the service is running and set to start

```powershell
Get-Service -Name mpssvc | Select-Object Name, Status, StartType
```

Expect `Running` / `Automatic`. A disabled `mpssvc` is a separate and more
serious finding -- it means something deliberately took the firewall out rather
than just switching a profile off.

### 4. Sanity-check that expected traffic still works

Re-enabling a firewall on a machine that has been running without one can break
an application that quietly depended on the open state. Confirm the user's
critical application still functions before you close the ticket.

## Rollback

```powershell
Set-NetFirewallProfile -Profile Domain, Private, Public -Enabled False
```

This returns the machine to an unprotected state and should only be used to
restore service while a legitimate blocked application is identified and given a
scoped rule. Leaving it here is the defect this playbook corrects.

## If it does not hold

Profiles reverting within minutes points to one of:

- **Group Policy re-application.** Confirm with `gpresult /h gpreport.html` and
  fix the GPO. The endpoint is the wrong place for this.
- **Active malware.** Disabling the firewall is a standard step in a compromise.
  If you did not find a benign cause, treat the machine as suspect and escalate
  rather than simply re-enabling and moving on.
- **A third-party product mid-install** that has claimed the provider role
  without finishing. Re-check the SecurityCenter2 query.

## Related

- ANSSI Guide d'hygiene informatique, R17 (pare-feu local)
