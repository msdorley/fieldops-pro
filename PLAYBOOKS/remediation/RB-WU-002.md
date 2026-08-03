---
id: RB-WU-002
title: Clear an update pause or deferral holding a machine beyond policy
category: WU
severity: medium
prerequisites:
  - Administrator rights
  - Agreement from the update ring owner
relatedRules:
  anssi: [R34]
estimatedDurationMinutes: 10
revertable: true
schemaVersion: "1.0"
---

# RB-WU-002 -- Clear an update pause or deferral holding a machine beyond policy

## When to use this

The update client is healthy but the machine is deliberately not updating: a
pause is set, or a deferral period is configured longer than the organisation's
policy allows. The machine reports "up to date" while sitting months behind on
security fixes, which is why this finding is easy to miss and easy to argue
about.

A user can pause updates for up to 35 days from Settings. A technician can set a
long deferral to stop a machine rebooting during a demonstration. Both are
frequently forgotten.

**Do not clear a deferral that is doing its job.** Staged deployment rings exist
so that a broken update does not reach the whole estate at once, and a pilot
machine holding at N-1 is behaving exactly as designed. **Confirm with whoever
owns the update rings before changing anything.** Overriding a ring locally
makes the endpoint drift from its management group, and the next policy refresh
usually undoes your change anyway -- so you get the risk of an unplanned update
without the benefit of a durable fix.

Use this playbook when the pause or deferral has **no owner** -- a user pause
nobody remembers, or a deferral left behind by a technician.

## Verify the condition first

```powershell
$ux = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
Get-ItemProperty -Path $ux -ErrorAction SilentlyContinue |
    Select-Object PauseUpdatesExpiryTime,
                  PauseFeatureUpdatesStartTime, PauseQualityUpdatesStartTime,
                  DeferFeatureUpdatesPeriodInDays, DeferQualityUpdatesPeriodInDays
```

Then determine whether the setting came from policy or from the machine:

```powershell
Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -ErrorAction SilentlyContinue
```

**This distinction decides the whole procedure.** A value under `Policies\` is
managed -- it belongs to a GPO or MDM profile, clearing it locally is temporary,
and the correct action is to talk to the ring owner. A value only under `UX\Settings`
is local, and this playbook applies.

Confirm the client is otherwise healthy; if scans are failing as well, the
deferral is not the whole story and RB-WU-001 comes first.

## Procedure

Only for a **local**, unowned pause or deferral.

### 1. Clear the pause

```powershell
$ux = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
foreach ($n in 'PauseUpdatesExpiryTime',
               'PauseFeatureUpdatesStartTime','PauseFeatureUpdatesEndTime',
               'PauseQualityUpdatesStartTime','PauseQualityUpdatesEndTime') {
    Remove-ItemProperty -Path $ux -Name $n -ErrorAction SilentlyContinue
}
```

### 2. Clear an unmanaged deferral

```powershell
Remove-ItemProperty -Path $ux -Name 'DeferQualityUpdatesPeriodInDays' -ErrorAction SilentlyContinue
Remove-ItemProperty -Path $ux -Name 'DeferFeatureUpdatesPeriodInDays' -ErrorAction SilentlyContinue
```

### 3. Trigger a scan

```powershell
Start-Process -FilePath 'UsoClient.exe' -ArgumentList 'StartScan' -Wait
```

### 4. Warn the user before anything installs

A machine held back for months will now pull a large backlog, and may want
several reboots. Tell the user before you leave, and agree when it may restart.
An unexpected reboot mid-presentation is how a correct fix becomes a complaint.

### 5. Confirm

```powershell
Get-ItemProperty -Path $ux -ErrorAction SilentlyContinue |
    Select-Object PauseUpdatesExpiryTime, DeferQualityUpdatesPeriodInDays
```

Both should be absent. Then confirm updates are being offered.

## Rollback

```powershell
$ux = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
Set-ItemProperty -Path $ux -Name 'DeferQualityUpdatesPeriodInDays' -Value <days> -Type DWord
```

Restoring a deferral is legitimate if clearing it turns out to conflict with a
deployment ring you were unaware of -- which is the argument for asking first.
Restoring a *pause* is rarely right: pauses expire on their own and exist for
short-term convenience, not as a control.

## If it does not hold

- **The pause or deferral returns.** It is policy-delivered. Confirm under
  `Policies\Microsoft\Windows\WindowsUpdate` and route it to the ring owner.
  This is the expected outcome when the finding was managed all along.
- **Updates are offered but fail to install.** The deferral was masking a broken
  client. Go to RB-WU-001.
- **Nothing is offered despite no deferral.** The machine may be pointed at a
  WSUS server with nothing approved for it. Check `WUServer` under the policy
  key before concluding the endpoint is at fault.

## Related

- ANSSI Guide d'hygiene informatique, R34 (mise a jour des composants)
