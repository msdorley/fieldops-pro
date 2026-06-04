# Pester 5.7.1 Offline Bundle

This directory is the offline bundle for Pester 5.7.1, used by
`tests\Install-PesterIfMissing.ps1` (D1) when PSGallery is unreachable
on locked-down enterprise endpoints (mitigates 6.6-Risk-1).

## Expected structure after provisioning

```
TOOLS\PowerShellModules\Pester\5.7.1\
    Pester.psd1          <- module manifest (checked by D1 bootstrap)
    Pester.psm1          <- root module
    bin\                 <- native binaries
    en-US\               <- help files
    Functions\           <- source tree
    ...
```

## How to populate (build machine only)

Run once on MSDORLEY from the repo root:

```powershell
.\TOOLS\PowerShellModules\Populate-PesterBundle.ps1
```

Then commit the result:

```
git add TOOLS/PowerShellModules/Pester/
git commit -m "chore(test): add Pester 5.7.1 offline bundle (D2)"
git push
```

## Version policy

The bundled version is updated only at major FieldOps Pro releases.
v0.6.0 ships with Pester **5.7.1**.  Do not auto-update the bundle between
releases -- version pinning is intentional (forty-year-stability principle,
Foundation 2.1).

## Why tracked in git?

The repo is designed to be self-contained for air-gap deployment on USB.
Binary module files are tracked deliberately so a `git clone` produces a
fully functional test environment with no network access required.

## Verification

After provisioning, confirm the manifest is readable:

```powershell
$m = Import-PowerShellDataFile .\TOOLS\PowerShellModules\Pester\5.7.1\Pester.psd1
$m.ModuleVersion   # should print: 5.7.1
```

Reference: DOCS\PHASE-6-DESIGN.md section 6.6.4.5 and 6.6.5 (D2).
