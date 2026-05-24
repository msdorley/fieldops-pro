# FieldOps Pro - ANSSI Pipeline v0.2 (Phase 1+2+3)

**Date** : 13 mai 2026
**Status** : End-to-end pipeline drafted, Python-tested, awaiting Windows deployment.

---

## What's new vs v0.1

The POC could render a PDF from hand-curated JSON. This version adds the two
pieces that produce that JSON automatically:

1. **`Apply-JsonSidecarPatch.ps1`** - patches SecurityScan and NetRepair so they
   emit JSON to `LOGS\` alongside their HTML reports (PCHealth already does).
2. **`Build-ANSSIData.ps1`** - reads the four engine JSONs from `LOGS\` and
   produces `report-data.json` mapping observed facts to all 42 ANSSI rules.

Plus the original POC renderer (`Invoke-ANSSIDiagnostic-POC.ps1`) is unchanged
and reads the production-shaped JSON without modification.

## Deployment - 5 steps on your Windows machine

```powershell
# 1. Unzip into your dev tree
Expand-Archive -Path C:\Users\<you>\Desktop\fieldops-anssi-v02.zip `
               -DestinationPath C:\Dev\fieldops-pro -Force

# 2. Patch the two engines (idempotent - safe to re-run)
cd C:\Dev\fieldops-pro
.\Apply-JsonSidecarPatch.ps1

# 3. Run each engine once to generate fresh JSON in LOGS\
.\SCRIPTS\Security\Invoke-SecurityScan.ps1
.\SCRIPTS\Health\Invoke-PCHealth.ps1
.\SCRIPTS\Network\Invoke-NetRepair.ps1

# 4. Collect engine data into ANSSI-shaped JSON
.\SCRIPTS\Compliance\Build-ANSSIData.ps1

# 5. Render the PDF
.\SCRIPTS\Compliance\Invoke-ANSSIDiagnostic-POC.ps1 -OpenAfter `
   -DataFile C:\Dev\fieldops-pro\REPORTS\report-data.json
```

## Files in this package

```
Apply-JsonSidecarPatch.ps1              <- run once to patch engines
SCRIPTS\Compliance\
  Build-ANSSIData.ps1                   <- the collector (42 rule evaluators)
  Invoke-ANSSIDiagnostic-POC.ps1        <- the renderer (unchanged from POC)
  report-data.sample.json               <- hand-curated sample (fallback)
SCRIPTS\Templates\
  anssi-diagnostic.html                 <- the HTML template
README.md                               <- this file
```

The patches create `.jsonpatch.bak` files alongside the engines for rollback.

## What the collector decides (mapping philosophy)

Pragmatic philosophy: **CV requires full Standard-level evidence**, PV means
partial coverage with caveats, HP means literally not observable from this
position. The collector reports actual machine state, not max-possible coverage.

Expected counts on a typical machine: **CV=12-13, PV=13-14, HP=16**.

The actual number floats with machine state - if BitLocker is partial, R31
correctly drops from CV to PV. This is desirable behaviour, not a bug. The
verdict on the cover page reflects the truth, not a target.

## Validated in sandbox before shipping

Python equivalent of the entire pipeline was run against synthetic engine
JSONs simulating a sample workstation:

- Engine JSON read: OK
- All 42 rules evaluated: OK
- Output shape matches sample JSON: OK
- Final counts: CV=12 PV=14 HP=16 (1 less CV than max because the test machine
  has 2 unencrypted volumes - R31 conservative drop)
- Top findings: R31 (1/3 volumes), R34 (3 update failures), R35 (2 obsolete
  drivers) - all concrete numeric problems, no generic PV fallbacks needed

## What's still expected to surface on first Windows run

Realistic expectations - the first end-to-end on your real machine will
probably trip on 3-5 small issues. Most likely candidates:

1. **PCHealth category names** - the collector assumes 'System', 'Security',
   'Storage', 'Drivers', 'Updates'. If PCHealth uses different category
   strings, some rules will return PV when they should be CV.
2. **SecurityScan category names** - I assumed 'Identity', 'NetSec',
   'Defender', 'Encryption', 'WinSec', 'PSSecurity', 'Surface', 'PrivEsc',
   'Firmware'.
3. **NetRepair category names** - 'Firewall', 'WiFi', 'VPN', 'Proxy'.
4. **Edge headless path** - the renderer auto-detects but if Edge is in an
   unusual location it falls back to wkhtmltopdf (also auto-detected).

Send any error output and we patch quickly. The collector is error-tolerant -
missing data shows up as PV with explanatory text, not a crash.

## What's intentionally NOT done yet

- **No launcher menu entry** - production wiring (the `[A] Diagnostic ANSSI`
  menu item, post-op prompt flow) comes after the first successful real-data run.
- **No EN locale** - FR only.
- **No customer branding parameters** - logo, MSP name, contact info still
  hardcoded placeholders.
- **No real PDF signing** - SHA-256 hash only.
- **7 known gaps still open** (G1-G7) - closing G1 (local password policy) and
  G2 (autorun detection) would push R10 and R14 from PV/limited-CV to full CV.
  ~6h of work, parked until after the first real PDF prints correctly.

## Rollback

```powershell
# To undo the engine patches:
Copy-Item C:\Dev\fieldops-pro\SCRIPTS\Security\Invoke-SecurityScan.ps1.jsonpatch.bak `
          C:\Dev\fieldops-pro\SCRIPTS\Security\Invoke-SecurityScan.ps1 -Force
Copy-Item C:\Dev\fieldops-pro\SCRIPTS\Network\Invoke-NetRepair.ps1.jsonpatch.bak `
          C:\Dev\fieldops-pro\SCRIPTS\Network\Invoke-NetRepair.ps1 -Force
```
