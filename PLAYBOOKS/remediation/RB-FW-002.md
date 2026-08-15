---
id: RB-FW-002
title: Scope an over-permissive inbound firewall rule
category: FW
severity: high
prerequisites:
  - Administrator rights
  - Firewall profiles enabled
relatedRules:
  anssi: [R17]
estimatedDurationMinutes: 15
revertable: true
schemaVersion: "1.0"
---

# RB-FW-002 -- Scope an over-permissive inbound firewall rule

## When to use this

An enabled inbound Allow rule accepts connections from **any** remote address,
often on a remote-access or file-sharing port, and frequently for **any**
program. The firewall is on, so the machine looks compliant, while one rule
undoes the profile it sits inside.

Typical sources: an installer that opened a port the broad way to avoid support
calls, a technician who widened a rule while diagnosing and never narrowed it,
or a rule created for a temporary need years ago.

**Do not delete rules you do not understand.** Enterprise applications
legitimately need inbound rules, and an over-broad rule is not the same as an
unnecessary one. This playbook narrows scope; it does not clear the list.

**Do not modify rules whose `PolicyStoreSource` is Group Policy.** Local edits to
policy-delivered rules either fail outright or drift back at the next refresh,
and you will have logged a fix that did not hold. Those belong to whoever owns
the GPO.

## Verify the condition first

List enabled inbound Allow rules whose scope is unrestricted:

```powershell
Get-NetFirewallRule -Direction Inbound -Enabled True -Action Allow |
    Where-Object { $_.PolicyStoreSource -ne 'GroupPolicy' } |
    ForEach-Object {
        $af = $_ | Get-NetFirewallAddressFilter
        $pf = $_ | Get-NetFirewallPortFilter
        if ($af.RemoteAddress -contains 'Any') {
            [PSCustomObject]@{
                Name        = $_.DisplayName
                Profile     = $_.Profile
                Protocol    = $pf.Protocol
                LocalPort   = ($pf.LocalPort -join ',')
                Program     = ($_ | Get-NetFirewallApplicationFilter).Program
                Source      = $_.PolicyStoreSource
            }
        }
    } | Sort-Object LocalPort | Format-Table -AutoSize
```

Give particular attention to rules exposing remote administration or file
sharing -- RDP (3389), SMB (445), WinRM (5985/5986) -- and to any rule whose
`Program` is `Any`.

**Establish what the rule is for before changing it.** If nobody knows, that is
a finding to escalate, not a licence to disable it blindly on a production
machine.

## Procedure

Work one rule at a time, confirming service after each.

### 1. Record the current state

```powershell
$rule = Get-NetFirewallRule -DisplayName '<rule name>'
$rule | Format-List DisplayName, Enabled, Profile, Action, PolicyStoreSource
$rule | Get-NetFirewallAddressFilter
$rule | Get-NetFirewallPortFilter
```

Keep this output. It is what you restore from if the change breaks something.

### 2. Narrow the remote address, if the legitimate source is known

Preferred over disabling, because it keeps the application working:

```powershell
Set-NetFirewallRule -DisplayName '<rule name>' -RemoteAddress LocalSubnet
```

Or an explicit range where the consumer is a known management network:

```powershell
Set-NetFirewallRule -DisplayName '<rule name>' -RemoteAddress '10.20.30.0/24'
```

### 3. Restrict to the intended program, where the rule was port-only

```powershell
Set-NetFirewallRule -DisplayName '<rule name>' -Program 'C:\Program Files\Vendor\app.exe'
```

### 4. If no legitimate use can be established, disable rather than delete

```powershell
Disable-NetFirewallRule -DisplayName '<rule name>'
```

Disabling is reversible in one command and leaves evidence of what existed.
Deletion destroys the record, and the rule's mere existence is often the only
clue to what needed it.

### 5. Confirm

```powershell
Get-NetFirewallRule -DisplayName '<rule name>' | Get-NetFirewallAddressFilter
```

## Rollback

Re-enable, or restore the recorded scope:

```powershell
Enable-NetFirewallRule -DisplayName '<rule name>'
Set-NetFirewallRule -DisplayName '<rule name>' -RemoteAddress Any
```

Restoring `RemoteAddress Any` returns the machine to the exposed state and is
only appropriate as a short-term service restoration while the correct scope is
determined. Record why, so the next audit does not simply re-flag it.

## If it does not hold

- **The rule reappears or re-widens.** It is delivered by Group Policy or by an
  application that rewrites its own rule on start. Check `PolicyStoreSource`
  again, and watch whether the rule's timestamp changes after an app restart.
- **The application breaks after narrowing.** The real client population is
  wider than assumed. Widen deliberately to the observed set rather than
  reverting to `Any`.
- **Many machines show the same rule.** This is a deployment defect, not an
  endpoint defect. Fix it at the packaging or GPO layer; remediating endpoints
  one at a time will not converge.

## Related

- ANSSI Guide d'hygiene informatique, R17 (pare-feu local)
