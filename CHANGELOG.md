# Changelog

All notable changes to FieldOps Pro are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
as qualified in `VERSIONING.md`.

Entries are reconstructed from merged pull requests. Where a change corrects an
earlier defect, the defect is described rather than elided -- a changelog that
only lists additions is a marketing document.

---

## [Unreleased]

Nothing yet.

---

## [0.6.0] - 2026-08-16

Phase 6. Four streams: test infrastructure, localisation completion, AI
integration, and licensing and documentation. The release turns a working
toolkit into a product that can be handed to someone else.

650 tests, no network, no API key.

### Added

**AI integration (stream 6.5)**

- Single AI transport module, `SCRIPTS/AI/FieldOps-AIClient.psm1`. Every provider
  call routes through it, enforced by an audit test asserting exactly one file in
  the deployed tree contains the transport (#23)
- Per-call and per-session cost ceilings, evaluated before the network is touched.
  A call whose estimate exceeds the ceiling is refused, not truncated (#22, #23)
- Pricing configuration as data (`CONFIG/AIModelPricing.json`) with a declared
  snapshot date and staleness thresholds, so prices going out of date is a test
  failure rather than a silent overcharge (#22)
- Audit log at `LOGS/ai-audit.jsonl`: one record per call, published JSON Schema,
  SHA-256 of prompt and response, pseudonymous technician id. Never the API key
  (#24)
- Severity classification of AI findings, validated against labeled fixtures in
  both languages (#25)
- Cross-model fallback that degrades on availability but **never upgrades** to a
  pricier model than the caller asked for (#26)
- Remediation playbook validation. A cited procedure that does not resolve or
  does not conform is reported as invalid rather than passed through (#30)
- Ten remediation playbooks with a published front-matter schema and authoring
  guide (#31)
- Transport and severity fixtures so the AI paths are testable with no network
  and no key (#33)
- `DOCS/AI-INTEGRATION.md`: what is transmitted, what is not, cost controls, and
  how an auditor verifies the audit log hashes (#34)

**Localisation (stream 6.1)**

- Rich-text bundle values (`{parts, separator}`) so structured strings live in
  the bundle as data rather than as markup in the template (#15)
- All 42 ANSSI rule names and 10 module titles routed through the locale bundle;
  a test asserts no evaluator carries a bare hardcoded name (#16)
- Hardcoded-string audit tool with accent folding and CSS masking, plus a
  flattener-parity test proving the audit tool and the locale engine agree on
  what a key is (#17)
- Complete template token routing, French and English at full parity (#18-#20)
- Render-parity suite: both languages render, differ, and leave zero unresolved
  tokens (#21)

**Test infrastructure (stream 6.6)**

- Pester 5.7.1 bundled offline; the suite runs air-gapped (#3, #4)
- Two-tier gate: fast tier on commit, full suite including `Slow` audits on push
  (#13)
- 42-evaluator branch coverage (#10) and property tests running 200 randomised
  adversarial inputs per evaluator (#11)
- Repository audit suite -- ASCII source, no BOM, StrictMode allowlist, exactly
  42 evaluators, no hardcoded machine paths, report schema (#12)
- `DOCS/TESTING.md` (#14)

**Licensing and documentation (stream 6.4)**

- Apache License 2.0, replacing MIT, with SPDX headers on every deployed script
  and a `NOTICE` file carrying an explicit ANSSI non-endorsement (#35)
- `DOCS/INSTALL.md` and `DOCS/USING.md` (#36)
- `SCRIPTS/Core/Test-Installation.ps1` -- verifies a deployed stick before it is
  trusted in the field (#36)
- `DOCS/ARCHITECTURE.md` and `DOCS/EXTENDING.md` (#37)
- `CHANGELOG.md`, `VERSIONING.md`, `RELEASE.md` and `BRAND.md` (#38)
- `TOOLS/New-DemoFleet.ps1` -- six synthetic machines for demos and screenshots,
  reproducible from a fixed seed, with an audit asserting no real hostname,
  username or serial reaches an artifact (#39)
- `README.md`, rewritten from scratch. The previous one predated Phase 6 and
  documented a workflow that no longer existed (#40)
- `COMMERCIAL-LICENSING.md` -- a brief for counsel and the open-core boundary,
  deliberately not a licence (#41)

### Changed

- **Licence changed from MIT to Apache 2.0.** Apache carries an express patent
  grant and a trademark reservation; MIT carries neither. For a French
  enterprise buyer, the difference is a procurement question with a real answer
  (#35)
- Report integrity hash now covers **resolved** content. It previously hashed the
  template before token resolution, which meant the signature did not cover what
  the reader actually received (#20)
- API key resolution converged on a single function. Two resolvers previously
  disagreed, producing a banner reading `AI ENABLED` alongside `NoApiKey` on
  every call (#29)
- `Invoke-ComplianceDiff.ps1` and the risk planner now call the AI client rather
  than the provider directly (#27, #29)
- Design document reconciled with implemented reality, including the playbook
  category rename `AUDIT` to `AUD` -- the published id pattern admits 2-4
  letters, and `AUDIT` is five (#32)

### Fixed

- **R32 reported VPN as connected on machines with no VPN.** The regex
  `'Connected'` also matches `'Disconnected'`, so the check passed silently
  wherever it should have degraded. Found by branch coverage, not in the field
  (#10)
- **Pester bootstrap could not install the module**, leaving the entire suite
  unrunnable. It probed a Documents path that does not exist under a redirected
  profile and treated a partial copy as success (#28)
- Locale flattener exploded rich-text objects into phantom sub-keys, inflating
  the key count and producing false drift reports (#15)
- Pre-commit hook wrote its own file with a BOM, tripping the audit it was meant
  to enforce (#7)
- Test scoping leaked state between files (#6)
- **The shipped report sample named a real person as the technician** who ran a
  compliance scan, in a file that deploys to the stick and that a customer
  reads. A deliberate anonymisation pass in May had missed it; the audit added
  alongside the demo fleet caught it (#39)

### Security

- API key never appears in the audit log, in any result object, or in any error
  detail. Enforced by both static and dynamic tests, including one that plants a
  key inside a prompt and asserts it does not survive into the record (#24)
- Provider error bodies are redacted and length-capped before being carried into
  a result object (#29)

### Deliberately not done

- **No commercial licence text.** `LICENSE-COMMERCIAL` will ship only after
  qualified legal review. A plausible-looking licence drafted by a non-lawyer is
  worse than none
- **No auto-remediation without confirmation.** Every change still asks

---

## [0.5.2] - 2026-05-25

### Added

- French-perfect ANSSI diagnostic output: all 42 rule evaluations, module
  groupings and report prose reviewed against the ANSSI *Guide d'hygiene
  informatique* wording

### Changed

- Report language handling reworked ahead of the full bilingual pipeline in 0.6.0

---

## [0.4.1] - 2026-05-15

### Added

- `Format-DetailString` helper for consistent evidence formatting

### Fixed

- R8 French translation
- R29 now flattens the parenthetical from the UAC value rather than printing it raw
- R36 capitalisation routed through the Meta field

---

## [0.4] - 2026-05-15

### Added

- ANSSI report renderer, HTML template, and sample report data

---

## [0.1] - 2026-05-04

Initial release.

---

[Unreleased]: https://github.com/msdorley/fieldops-pro/compare/v0.6.0...HEAD
[0.6.0]: https://github.com/msdorley/fieldops-pro/compare/v0.5.2...v0.6.0
[0.5.2]: https://github.com/msdorley/fieldops-pro/releases/tag/v0.5.2
[0.4.1]: https://github.com/msdorley/fieldops-pro/releases/tag/v0.4.1
