# Architecture

FieldOps Pro - Phase 6, Stream 6.4 (6.4-D7)

How the pieces fit together, and why they are shaped this way. Written for
someone evaluating whether this is credibly engineered, and for whoever
maintains it next.

---

## 1. Constraints that determined the design

Almost every decision below follows from four constraints. They are worth
stating first, because several choices look odd until you know them.

**PowerShell 5.1, nothing else.** It ships in the Windows box. Requiring
PowerShell 7, .NET, or Python would mean installing software on a machine
someone called us to fix -- which is both an imposition and a variable. The cost
is real: no `ternary`, no `??`, `Set-StrictMode -Version 1.0` only, and a JSON
parser with quirks. We pay it.

**Runs air-gapped.** Every core function, and the entire test suite, works with
no network. Field machines are frequently isolated, and a diagnostic that needs
connectivity is useless precisely when it is most needed.

**Runs from USB, on any machine.** Nothing is installed on the target. No
registry, no services, no scheduled tasks. Paths are resolved relative to the
script, never hardcoded, because the drive letter changes machine to machine.

**Any hardware, no exceptions.** No TPM, no BitLocker, a VM with no SMART data,
a WinPE preboot environment with no running Defender -- all supported. Probes
that cannot answer degrade; they do not fail and they never guess.

---

## 2. The shape of the system

```
  Diagnostic engines            Collector              Renderer
  -----------------             ---------              --------
  PCHealth      --.
  SecurityScan  --+--> LOGS\*.json --> Build-ANSSIData --> report-data.json
  NetRepair     --'                    (42 evaluators)          |
  DiskAnalysis  --'                                             v
                                                        Resolve-LocaleTokens
                                                        + locale bundle
                                                        + HTML template
                                                                |
                                                                v
                                                        REPORTS\*.html
                                                        (SHA-256 signed)
```

Three stages, deliberately separated.

**Engines observe.** Each diagnostic writes an HTML report for a human and a
JSON sidecar to `LOGS\` for machines. They know nothing about ANSSI.

**The collector judges.** `Build-ANSSIData.ps1` reads the sidecars and runs 42
evaluators, one per ANSSI rule, producing `report-data.json`. It knows nothing
about presentation.

**The renderer presents.** Locale tokens are resolved against the language
bundle, injected into the HTML template, and the result is signed.

The separation is what makes the system testable. Evaluators are pure functions
over parsed JSON, so they can be exercised against thousands of adversarial
fixtures with no machine involved -- which is exactly what the property tests do.

---

## 3. The 42 evaluators

Each ANSSI rule has a `Get-R<n>` function in `Build-ANSSIData.ps1`. Every one
returns a hashtable carrying a status of `cv`, `pv` or `hp`, plus evidence.

### The three-status contract

| Status | Meaning |
|--------|---------|
| `cv` | Control observed in place |
| `pv` | Evidence incomplete: probe unavailable, hardware absent, or human judgement needed |
| `hp` | Outside what an endpoint scan can assess |

**Two statuses would have been easier and would have made the product worthless
as evidence.** A machine with no TPM cannot demonstrate hardware-backed
authentication. Reporting that as a pass is false; reporting it as a fail
implies a defect that is not there. `pv` says what actually happened: we looked,
and the machine could not tell us.

This is why **no evaluator may report `cv` on the basis that its probe returned
nothing.** A test asserts every evaluator returns a valid status and never
throws across 200 randomised adversarial inputs each, precisely to stop a null
being read as a pass.

### Testing them without a machine

`Build-ANSSIData.ps1` runs its collection pipeline unconditionally at the bottom
-- dot-sourcing it would read real logs and overwrite real reports. So the tests
extract *only* the function definitions via the PowerShell AST
(`tests/Get-EvaluatorSource.ps1`) and dot-source those.

Zero changes to production code, full access to every evaluator. The same
pattern later let us test `Invoke-ComplianceDiff`'s AI path without running its
snapshot pipeline.

---

## 4. Snapshot and diff

A second, independent pipeline answers "what changed on this machine?"

`Invoke-ComplianceDiff.ps1` captures **16 categories** -- services, registry,
scheduled tasks, firewall, local users, software, listening ports, certificates,
startup items, SMB shares, BitLocker, Defender, WMI persistence, hosts file,
environment, drivers -- as an ordered structure, and compares two captures.

Each change is classified (Improvement, Regression, Neutral, Suspicious), mapped
to a **MITRE ATT&CK technique** where it matches a known persistence or evasion
pattern, and given a risk score weighted by classification and severity. A
rollback script is generated from the reversible subset.

**The value is the negative result.** Proving an intervention did what it
claimed is useful; proving it did *nothing else* is what an auditor wants.

---

## 5. Localisation

French and English are both first-class. The mechanism matters because a
half-translated compliance report is worse than a monolingual one.

**Bundles** (`CONFIG/lang/{fr,en}.json`) hold every user-visible string, 600+
keys. They are UTF-8 **with BOM** and contain literal accented characters.

**Templates** carry `{{t:some.key}}` tokens, never literal prose.

**Resolution** happens in memory, before the integrity hash is computed.

### Two decisions worth explaining

**Rich text lives in the bundle as data, not as markup in the template.** A
value needing a line break is `{parts: [...], separator: "br"}`, rendered at
resolution time. Putting `<br>` in the template would mean the French and
English versions could diverge structurally; putting it in the bundle as a
literal would mean escaping it correctly at every use site.

**The integrity hash covers resolved content.** The renderer previously hashed
the template before token resolution, which meant the signature did not cover
what the reader actually received. It now resolves in memory first, so the
signature covers the delivered bytes.

### Enforced by test

- Zero key drift: neither language may have a key the other lacks
- Zero unresolved `{{t:}}` tokens in a rendered report
- Zero hardcoded French strings in the template
- French renders must actually contain diacritics, proving bundle text rather
  than an ASCII fallback

---

## 6. Encoding

Two rules, both non-negotiable, both machine-enforced:

| Path | Encoding | Why |
|------|----------|-----|
| `SCRIPTS/**/*.ps1`, `*.psm1` | **ASCII, no BOM** | PowerShell 5.1 across locales and WinPE is unreliable with non-ASCII source. A BOM can break `#Requires` handling |
| `CONFIG/lang/*.json`, `SCRIPTS/Templates/*.html` | **UTF-8 with BOM** | They must carry literal accented French, and the BOM is what makes Windows read them correctly |

Audits **A1** and **A2** enforce these across the whole tree on every push.

The practical consequence: source comments say `--` where you would write an
em dash, and accented text is confined to files that are allowed to hold it.
This is why the licence-header tool verifies its own writes and reverts anything
that gains a BOM.

---

## 7. The AI boundary

Every call to the model provider goes through **one module**,
`SCRIPTS/AI/FieldOps-AIClient.psm1`. An audit test asserts that exactly one file
in the deployed tree contains the transport.

That single boundary is what makes cost ceilings, audit logging, retry and
severity classification unavoidable rather than optional. There is no path
around them because there is no second door.

**No AI feature is a hard dependency.** Every call site has a deterministic
local path and takes it on any failure -- no key, refused on cost, rate limited,
malformed response. Tested exhaustively: every failure reason the client can
report is asserted to degrade rather than throw.

**The AI never decides compliance.** The 42 evaluations are computed from
observed state by deterministic code. The model narrates, prioritises and cites
remediation procedures. It does not score.

See `DOCS/AI-INTEGRATION.md` for the full contract.

---

## 8. Testing

623 tests, roughly 50 seconds, no network, no API key.

**Two tiers, tag-driven.** Pre-commit runs the fast tier (~535, ~30s). Pre-push
runs everything including `Slow`-tagged audits. The split exists so the commit
gate stays fast enough that nobody is tempted to bypass it.

**Four kinds of test, doing different jobs:**

*Unit tests* cover behaviour. *Branch tests* cover every decision path in the
22 computed evaluators -- this is what caught a real R32 defect where the regex
`'Connected'` also matched `'Disconnected'`, silently passing VPN checks on
machines with no VPN.

*Property tests* throw 200 randomised adversarial inputs at each evaluator and
assert it never throws, always returns a valid status, and is deterministic.

*Audit tests* enforce repository invariants: ASCII source, no BOM, no hardcoded
machine paths, exactly 42 evaluators, licence headers present, no direct
provider calls, no API key in any log.

### The pattern worth copying

Several tests exist to stop a *green suite from proving nothing*. The severity
fixtures assert they actually loaded from disk, because a broken glob would make
the accuracy assertions pass vacuously on an empty set. The licence audit
asserts the file set is non-empty before checking it. The playbook validator
asserts the tree is non-empty before validating it.

A test that cannot fail is not a test, and the failure mode is invisible.

---

## 9. Configuration resolution

One resolver, one answer -- learned the hard way.

The API key is resolved by a single function searching, in order: the
`ANTHROPIC_API_KEY` environment variable, then four candidate config filenames,
each searched recursively across a fixed alias list.

Before convergence there were two resolvers: the client read one file's
top-level properties, the compliance script searched four files recursively. A
key in the wrong file produced a banner reading **AI ENABLED** and `NoApiKey` on
every call -- a silent downgrade with the interface actively contradicting it.

The lesson generalises: **two pieces of code answering the same question will
eventually disagree, and the disagreement will be silent.**

---

## 10. Extension points

| To add | Where |
|--------|-------|
| A diagnostic engine | `SCRIPTS/<Area>/`, emit JSON to `LOGS\` |
| A compliance rule mapping | An evaluator in `Build-ANSSIData.ps1` |
| A remediation playbook | `PLAYBOOKS/remediation/RB-*.md` |
| A workflow | `PLAYBOOKS/*.json` |
| A language | `CONFIG/lang/<code>.json`, at full key parity |

See `DOCS/EXTENDING.md`.

---

## 11. What is deliberately absent

**No database.** State is files: JSON snapshots, JSONL audit log. A technician
can read them, diff them, and email them.

**No service or agent.** Nothing persists on the target machine.

**No telemetry.** Nothing is transmitted anywhere unless AI is explicitly
enabled, and that path is documented and audited.

**No auto-remediation without confirmation.** Every change asks. The
plan-before-execute mode exists so a technician can explain an intervention
afterwards.

---

## Related

- `DOCS/EXTENDING.md` -- adding engines, rules, playbooks, languages
- `DOCS/AI-INTEGRATION.md` -- the AI contract in detail
- `DOCS/TESTING.md` -- test suite reference
- `DOCS/PHASE-6-DESIGN.md` -- the authoritative specification
