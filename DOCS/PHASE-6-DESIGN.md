# FieldOps Pro
## Phase 6 Design Document
### From Working Toolkit to Defensible Commercial Product

---

| | |
|---|---|
| **Document version** | 0.6.0-design.draft.1 |
| **Document status** | Design — Not Yet Approved for Execution |
| **Document date** | 25 May 2026 |
| **Document author** | Ousman Dorley |
| **Predecessor release** | FieldOps Pro v0.5.2 (public `main` at commit `cac1ae9`; annotated tag `v0.5.2` peels to commit `3d3c85c14f42ad80e53e7cf541c540c82eb5e9d2`) |
| **Target release** | v0.6.0 (Phase 6 complete), projected late August 2026 |
| **Repository** | github.com/msdorley/fieldops-pro |
| **License (Community)** | Apache License 2.0 (effective from v0.6.0; chapter 6.4) |
| **License (Enterprise)** | Commercial license (effective from v0.6.0; chapter 6.4) |
| **Document length** | 30+ pages markdown · ~55 pages typeset Word (A4, 11 pt body, 1.15 line) |
| **Distribution** | Public via repository; this document is itself a deliverable artifact of the FieldOps Pro design rigor |
| **Citation convention** | Primary-authority references in §F (Citation Bibliography); inline citations use bracketed short-form `[NIS2-Dir]`, `[ISO27001-2022]`, `[ANSSI-Hyg]`, `[RGS-v2]` resolving to full bibliographic entries |

---

```{=openxml}
<w:p><w:r><w:br w:type="page"/></w:r></w:p>
```

## Executive Summary

Phase 6 transitions FieldOps Pro from a working personal IT toolkit into a defensible, commercially viable enterprise product calibrated for forty years of relevance. Six work streams, executed in the verified-foundation-first order **6.6 → 6.1 → 6.5 → 6.2 → 6.3 → 6.4**, deliver the following capabilities to v0.6.0:

A tested foundation (Stream 6.6) under which all subsequent work is verifiable rather than hopeful; complete internationalization (6.1) closing Phase 5.2's deferred rich-text routing and Block 3 work; production-grade AI integration (6.5) with cost ceilings, audit logging, severity classification, remediation-playbook validation, and tiered-model selection across Claude Opus 4.7, Opus 4.6, Sonnet 4.6, and Haiku 4.5 — prerequisites for offering AI-augmented capabilities in customer hands at fleet scale; four-framework compliance coverage (6.2) mapping technical findings to ANSSI's Guide d'hygiène informatique [ANSSI-Hyg], NIS2 Directive Article 21 with concrete entity-type detail from Implementing Regulation (EU) 2024/2690 [NIS2-Dir, NIS2-IR], ISO/IEC 27001:2022 Annex A [ISO27001-2022], and RGS v2.0 [RGS-v2] — the latter scoped honestly to French public-sector entities and positioned as a Public Sector Edition differentiator; AI-narrated fleet drift dashboarding (6.3) — a capability no incumbent USB toolkit offers; and commercial packaging (6.4) with dual licensing, brand separation, customer-facing documentation, anonymized demo dataset, and a v0.6.0 GitHub Release.

Total engineering investment: **~220 risk-adjusted hours** (5.5 weeks full-time, 9 calendar weeks with realistic contingency). On delivery, FieldOps Pro will hold a defensible position on three axes the incumbents (MediCat USB, Hiren's BootCD PE, NHV Boot) cannot reach without rebuilding their architectures: framework-mapped compliance reporting traceable to primary authority, AI-narrated fleet drift detection bounded by per-invocation and per-fleet cost ceilings, and production-grade audit logging suitable for compliance demonstration.

The recommended sequence prioritizes risk reduction before value addition. Stream 6.6 (testing) and 6.5 (AI hardening) come early because their absence forces costly rework of dependent streams; 6.4 (commercial packaging) comes last because it crystallizes the technical reality of all prior streams into customer-facing artifacts, and crystallizing too early creates rewrite tax as underlying features shift.

This document itself is a deliverable. Its existence and rigor are intended to signal to prospective collaborators, customers, and compliance auditors the engineering posture of the product it describes.

---

```{=openxml}
<w:p><w:r><w:br w:type="page"/></w:r></w:p>
```

## 1. Project Context

### 1.1 The Goal, Restated for Forty-Year Calibration

FieldOps Pro is a portable, USB-based enterprise IT toolkit designed to be the definitive instrument for field IT technicians servicing enterprise endpoints — diagnostics, remediation, deployment, security, compliance reporting, and fleet visibility from a single Ventoy USB drive [Ventoy] without hardcoded dependencies. The explicit competitive intent is to **surpass** MediCat USB [MediCat], NHV Boot [NHV], and Hiren's BootCD PE [Hirens] in capability, durability, and professionalism.

The relevant horizon for that surpassing is forty years. This is not rhetorical framing. It is a design lens. Every architectural decision in Phase 6 is judged against the question: *would this choice still be defensible if this codebase shipped in 2066?* Where decisions trade short-term convenience for long-term architectural debt, durability wins. Concretely, this lens drives the following Phase 6 commitments:

- **ASCII-only PowerShell source** (no Unicode dependencies that may render unpredictably in future runtimes)
- **Inline SVG for all charts** (no JavaScript chart-library dependencies whose maintenance horizons are shorter than ours)
- **JSON-based data files for frameworks, cross-references, audit logs, and configuration** (a format readable by any reasonable tooling for the foreseeable future)
- **Locale routing through plain-text bundles** (translators see strings, not markup; translation pipeline is not coupled to presentation technology)
- **Apache License 2.0 for the Community Edition** (a license whose patent grant and contribution clarity have proven durable across two decades of significant case law)
- **Primary-authority citations for every compliance framework** (the citation chain remains valid even when intermediate commentary changes; primary authorities themselves are versioned and pinned)
- **Audit-log retention semantics** that survive the lifetime of typical compliance audit windows (currently calibrated to 12 months online, 7 years archived — both configurable)

### 1.2 What v0.5.2 Established

The predecessor release, FieldOps Pro v0.5.2 (publicly merged to `main` on 25 May 2026 at `cac1ae9`, annotated tag peeling to anonymization commit `3d3c85c`), shipped the following capabilities:

- A toolkit orchestrator (`Launcher.ps1` v3.2) and 17+ portable diagnostic tools operating from a Ventoy USB
- The Phase 5.2 internationalization foundation — `FieldOps-Locale.psm1` module, French and English locale bundles totalling 221 `report.anssi.*` keys, `Resolve-LocaleTokens.ps1` template post-processor
- An ANSSI compliance diagnostic (`Build-ANSSIData.ps1`) routing all dynamic strings through the locale bundle, with French-accent-correct rendering of status labels (VERIFIE, HORS PERIMETRE) and cover labels (POSTE AUDITE, POINTS D'ATTENTION PRIORITAIRES)
- Public anonymized history (no real workstation identifiers reachable through any commit on any branch or tag — verified by `git filter-repo` rewrite and post-rewrite cryptographic audit)
- Documented hard-won infrastructure rules — Foundations §2 below carries them forward unchanged

v0.5.2 is functional, public, license-clean for redistribution under its current implicit terms, and free of personal identifiers. It is *not yet* tested, multi-framework, productionized for AI at scale, fleet-aware, or commercially packaged. Phase 6 closes all five gaps.

### 1.3 The Customer

The Phase 6 design is calibrated to two customer profiles. Both shape the design; neither is privileged over the other.

**Profile A — The Field IT Technician.** Services enterprise endpoints (typically Dell Latitude, HP EliteBook, Lenovo ThinkPad, Surface, Acer Nitro for SOHO) in Azure AD / Microsoft Intune / GlobalProtect VPN-bound environments. Operates in French-language workplaces with French data-protection compliance obligations (RGPD, NIS2 national transposition, ANSSI Guide d'hygiène informatique guidance). Needs: fast, reliable, repeatable diagnostics that produce defensible reports a customer's IT manager can review.

**Profile B — The IT Services Firm / Managed Service Provider.** Operates fleets of 50–5,000 endpoints across multiple client organizations. Needs: standardized field operations across many technicians, audit-grade reporting for compliance demonstrations to their own clients, fleet-level drift detection with executive-readable summaries, and explicit AI cost controls that make consumption predictable at scale. This profile is the primary commercial revenue source for FieldOps Pro Enterprise (chapter 6.4).

Stream 6.4 builds the deliverables that translate the toolkit's value into a purchase decision for Profile B without compromising the experience of Profile A. Stream 6.2's RGS coverage additionally addresses **Profile C — the French Public Sector IT Function** as a specialized differentiated market segment (chapter 6.2.4.7).

### 1.4 The Incumbents, and the Defensible Gap

A direct view of what FieldOps Pro is competing against, with citations to each project's own published feature description.

| Capability | MediCat USB [MediCat] | Hiren's BootCD PE [Hirens] | NHV Boot [NHV] | FieldOps Pro v0.6.0 (target) |
|---|:---:|:---:|:---:|:---:|
| Multi-tool bootable USB | yes | yes | yes | yes |
| Windows PE environment | yes | yes | yes | yes |
| Live Linux diagnostics | yes | partial | yes | yes |
| Compliance reporting (any framework) | — | — | — | **yes (4 frameworks)** |
| Per-machine compliance report | — | — | — | yes |
| Multi-framework cross-reference | — | — | — | **yes** |
| Fleet aggregation | — | — | — | **yes** |
| Fleet drift over time | — | — | — | **yes** |
| AI-narrated executive summary | — | — | — | **yes** |
| Cost-ceiling-bounded AI integration | — | — | — | **yes** |
| Production-grade audit logging | — | — | — | **yes** |
| Property-tested rule evaluators | — | — | — | **yes** |
| Dual-license model (open + commercial) | — | — | — | **yes** |
| Commercial support path | — | — | — | **yes** |
| Public design documentation | — | — | — | **yes (this document)** |

Sources: MediCat USB project page [MediCat]; Hiren's BootCD PE official site [Hirens]; NHV Boot project documentation [NHV]. The unbolded rows reflect category parity (table-stakes for any USB toolkit). The bolded rows reflect the defensible gap Phase 6 establishes. No incumbent has any of the bolded capabilities. Building them is not a roadmap item for the incumbents; their architectures are tool-aggregator first, not workflow-and-compliance first.

This positioning matters commercially because the bolded capabilities map directly to Profile B's purchase decision: an MSP does not buy a tool collection (those are free or near-free), but pays meaningfully for compliance-grade fleet visibility with audit trails.

---

```{=openxml}
<w:p><w:r><w:br w:type="page"/></w:r></w:p>
```

## 2. Foundations

These cross-cutting concerns apply to every chapter in this document. They are documented once here and not repeated.

### 2.1 Runtime Target

All FieldOps Pro Community and Enterprise scripts target **Windows PowerShell 5.1** as the universally available shell on managed enterprise Windows 10 and Windows 11 endpoints across the EU. PowerShell 7+ is not assumed even where present. Locale assumption: `fr-FR` for primary user-facing output, `en-US` for log files and machine-readable artifacts. Phase 6 does not introduce a PowerShell 7 dependency.

### 2.2 ASCII-Only Source

PowerShell 5.1 silently corrupts non-ASCII characters in source files under certain encoding edge cases (Unicode box-drawing, em dashes, curly quotes, characters embedded in here-strings). All `.ps1`, `.psm1`, `.psd1`, and `.json` schema files MUST be pure ASCII. Non-ASCII content (French accents, special characters in reports) lives exclusively in JSON locale bundles under `CONFIG/lang/` with explicit UTF-8 encoding declared and verified. This rule is non-negotiable and is enforced by an audit test (chapter 6.6).

### 2.3 Path Resolution

Scripts derive paths dynamically via `$PSScriptRoot` and `Split-Path`. The USB root is resolved with two levels of `Split-Path` from scripts under `<USB>:\SCRIPTS\<subdir>\`. No script may assume drive letter, machine hostname, or absolute path. This is verified by Foundations test FT-PATH-01 in chapter 6.6.

### 2.4 Error and Logging Model

All scripts use the established logger pattern: `Write-Log -Level INFO|OK|WARN|ERROR`, with `Level` ValidateSet-enforced at the function signature. User-facing errors localize via the bundle; technical detail logs to disk in English (operational logs are not localized — by design — to support a single canonical incident-correlation pipeline). Chapter 6.5 extends this model with severity classification for AI-derived output and structured audit logging for all AI invocations.

### 2.5 AI Integration Constraints

Anthropic API calls [Anthropic-Pricing] are made only from scripts that explicitly declare AI dependency in their header and route exclusively through the hardened client `FieldOps-AIClient.psm1` (chapter 6.5). Direct `Invoke-RestMethod` calls to `api.anthropic.com` are forbidden anywhere in the codebase and enforced by an audit test. API keys live in `<USB>:\CONFIG\FieldOps.config.json` under `AnthropicApiKey` and never appear in source files, audit logs, or error messages.

Phase 6 default model selection is **tiered by call-site cost-sensitivity**:

- **Severity classification, format checks, simple summaries**: Claude Haiku 4.5 (`claude-haiku-4-5`) at $1/$5 per million input/output tokens
- **Narration tasks, executive summaries, drift commentary**: Claude Sonnet 4.6 (`claude-sonnet-4-6`) at $3/$15 per million tokens
- **Compliance-diff reasoning, cross-framework interpretation, complex remediation analysis**: Claude Opus 4.7 (`claude-opus-4-7`) at $5/$25 per million tokens
- **Backward compatibility**: Claude Opus 4.6 (`claude-opus-4-6`) remains a supported configuration value for operators with workflows tuned to its tokenizer

Per-call-site model selection is documented in chapter 6.5.4 with rationale; operators may override defaults via `CONFIG/FieldOps.config.json`. This tiered approach is estimated to reduce AI operating costs by 40–60% at fleet scale compared to a uniform-Opus model policy, without sacrificing quality on calls where flagship reasoning is necessary.

### 2.6 Commercial / Open-Source Boundary

By end of Phase 6 the codebase splits into two licensed components:

- **FieldOps Pro Community** under the Apache License 2.0 [Apache-2.0]: toolkit framework, ANSSI single-framework compliance reporting, core diagnostics, documentation, sample skills
- **FieldOps Pro Enterprise** under a commercial license: multi-framework cross-reference engine and additional framework data files (chapter 6.2), fleet drift dashboard (chapter 6.3), the hardened AI client with tiered model selection and audit-log compliance pack (chapter 6.5), enterprise documentation pack

The boundary is enforced by directory layout (chapter 6.4.4.1) and per-file SPDX license headers [SPDX]. Until Phase 6.4 executes the split, the entire codebase is treated as commercial-trajectory and developed against the higher quality bar.

### 2.7 Test-Before-Merge

From v0.6.0 forward, every pull request must pass the test suite established in chapter 6.6 before merge to `main`. The v0.5.2 "verified by execution + manual review" model is sunset at the moment Stream 6.6 completes. This is operationalized as a pre-commit hook for developer workflow plus a documented merge-gate requirement in `CONTRIBUTING.md` (chapter 6.4).

### 2.8 Citation Posture

This document and all FieldOps Pro deliverables cite primary authority where compliance frameworks are referenced. Secondary commentary (industry guides, consultancy publications, ENISA technical guidance) is permissible as supporting material but never as sole authority. All primary-authority references resolve to entries in Appendix F (Citation Bibliography) with publication date, retrieval date, and where available a permanent identifier (ELI for EU legal acts, ISO standard number, ANSSI guide reference number).

---

```{=openxml}
<w:p><w:r><w:br w:type="page"/></w:r></w:p>
```

## 3. Execution Sequence and Rationale

### 3.1 Recommended Order

```
6.6  ->  6.1  ->  6.5  ->  6.2  ->  6.3  ->  6.4
```

### 3.2 Three Governing Principles

The sequence is governed by three principles in priority order:

**Principle 1 — Build the verification floor first.** Stream 6.6 is sequenced first because every later stream lands on top of it. Without a tested foundation, later streams must either be re-verified manually at the end of Phase 6 under release pressure (expensive, error-prone) or ship with unknown defect density (unacceptable for a commercial-trajectory product). The cost of doing 6.6 first is felt early as slower momentum; the cost of doing 6.6 last is felt as crisis.

**Principle 2 — Harden infrastructure before extending it.** Stream 6.5 (AI hardening) is sequenced before Stream 6.3 (fleet drift) because 6.3 invokes the AI loop at fleet scale, where the absence of cost ceilings is a financial risk and the absence of audit logging is a compliance risk. Retrofitting hardening into an already-shipped feature is more expensive and less robust than building hardening primitives first and then building the feature on top.

**Principle 3 — Crystallize commercial wrapping last.** Stream 6.4 (commercial packaging) is sequenced last because it formalizes a technical reality that is still in motion through Streams 6.1–6.3 and 6.5. Writing customer-facing INSTALL / USING / EXTENDING documentation before the underlying features stabilize creates a rewrite tax. The dual-license split similarly benefits from being decided after the technical surface area is known.

### 3.3 Dependency Graph

```
6.6 (test harness, no upstream deps)
 |
 +-- 6.1 (depends on 6.6 only)
 |    |
 |    +-- 6.2 (depends on 6.1 for locale, 6.6 for tests)
 |    |    |
 |    |    +-- 6.3 (depends on 6.2 for frameworks, 6.5 for AI, 6.6 for tests)
 |    |    |    |
 |    |    |    +-- 6.4 (depends on ALL prior streams stable)
 |    |    |
 |    |    +-- 6.4 (also direct dep on 6.2)
 |    |
 |    +-- 6.4 (also direct dep on 6.1 for docs)
 |
 +-- 6.5 (depends on 6.6 only)
      |
      +-- 6.3 (already noted above)
      |
      +-- 6.4 (also direct dep on 6.5 for audit log claim)
```

### 3.4 Parallelization Window

The linear sequence above is the safe single-developer path. With additional capacity, **6.1 and 6.5 may run concurrently** (they share only the 6.6 dependency, not each other). **6.2 may begin once 6.1 is feature-complete** but before 6.5 is fully landed, since 6.2 does not invoke the AI client. 6.3 and 6.4 cannot be safely parallelized — 6.4 fundamentally needs 6.3 stable as input for the customer-facing fleet documentation and demo dataset.

For solo execution, follow the linear sequence as specified. Estimates in this document assume linear execution.

---

```{=openxml}
<w:p><w:r><w:br w:type="page"/></w:r></w:p>
```

## 4. Investment Summary

| Stream | Title | Hours (base) | Risk Buffer | Hours (buffered) | Days @ 8h | Risk Level | Position |
|--------|-------|-------------:|------------:|-----------------:|----------:|------------|---------:|
| 6.6 | Continuous validation | 24 | 10% | 26 | 3.3 | Medium | 1st |
| 6.1 | Complete locale routing | 16 | 10% | 18 | 2.3 | Low | 2nd |
| 6.5 | AI loop productionization | 35 | 25% | 44 | 5.5 | High | 3rd |
| 6.2 | Multi-framework cross-reference | 52 | 20% | 62 | 7.8 | Medium-High | 4th |
| 6.3 | Fleet drift dashboard | 56 | 25% | 70 | 8.8 | High | 5th |
| 6.4 | Commercial packaging | 40 | 15% | 46 | 5.8 | Medium | 6th |
| **Totals** | | **223** | **~20% avg** | **266** | **33.5** | | |

**Base estimate (unbuffered):** 223 hours = ~28 working days = 5.6 weeks at 40 h/week.
**Risk-buffered estimate (planning basis):** 266 hours = ~34 working days = 6.7 weeks at 40 h/week.
**Calendar realistic** (3 fully-productive days per calendar week, accounting for professional obligations, fixture-and-research dead ends, external reviewer iteration loops in 6.4): **9 calendar weeks, approximately 2.5 months.**

Risk-adjusted Phase 6 launch target: **late August 2026**, assuming start mid-June 2026 (post-v0.5.2 settle, post-design-document publication and stakeholder review window).

The risk-buffered estimates are the ones to plan against. The base estimates are the ones to invoice against if Phase 6 is ever scoped as commercial work. The differential between base (223 h) and buffered (266 h) is 43 hours — distributed across the high-risk streams (6.5 and 6.3) where prior experience says estimate variance is real, not where the work is well-bounded (6.1 has only 2 hours of buffer because the work is mechanical).

Estimates per stream are justified in §X.Y.9 of each chapter with full sub-task decomposition.

---

```{=openxml}
<w:p><w:r><w:br w:type="page"/></w:r></w:p>
```

## 5. Reading Guide

This document is organized for two reading modes.

**Front-to-back reading** (recommended for first-time readers, project sponsors, compliance auditors): Sections 1–5 establish context, foundations, sequence, and investment; chapters 6.6 through 6.4 follow in **execution order**, not numerical order, so the document doubles as an execution roadmap; appendices provide cross-reference material.

**Random-access reading** (recommended for developers picking up a specific stream): Each chapter follows the same internal structure (§X.Y.1 Goal, §X.Y.2 Context, §X.Y.3 Requirements, §X.Y.4 Design, §X.Y.5 Deliverables, §X.Y.6 Risks, §X.Y.7 Dependencies, §X.Y.8 Success Criteria, §X.Y.9 Estimate Justification, §X.Y.10 Open Questions). Foundations (§2) applies to every chapter and is not repeated. The traceability matrix (Appendix D) maps every requirement to its deliverable and its success criterion.

**Citations**: bracketed short-form `[XXX-YYY]` references resolve to Appendix F (Citation Bibliography), which contains the primary-authority anchor with publication date, retrieval date, and permanent identifier where available.

**SHAs, dates, version numbers** in this document are current as of publication (25 May 2026). Phase 6 execution may produce minor drift; material drift triggers an amendment entry in Appendix G (Revision History).

```{=openxml}
<w:p><w:r><w:br w:type="page"/></w:r></w:p>
```

# Chapter 6.6 — Continuous Validation

*Execution position: 1st of 6 · Risk-buffered effort: 26 hours · Risk level: Medium*

## 6.6.1 Goal

Establish a test infrastructure under which every subsequent Phase 6 stream is verifiable rather than hopeful. Replace v0.5.2's "verified by execution and manual review" model with a repeatable, low-friction Pester-based test suite that runs in seconds, catches regressions automatically, supports property-based testing for rule evaluators, and provides both the solo developer and future contributors with deterministic confidence that a change is safe to merge.

## 6.6.2 Context

FieldOps Pro through v0.5.2 ships zero automated tests. Every verification has been manual: run the script, read the output, compare against expectation, ship if it looks right. This worked because there is one developer, the project is small enough to hold in one head, and the developer has high domain knowledge. It does not scale to Phase 6.

The codebase will roughly double in size across Phase 6 (multi-framework data structures, fleet aggregation, AI cost ceiling, audit log schema, dual-license refactor). The number of plausible failure modes grows combinatorially. Manual verification under those conditions becomes either prohibitively slow or unreliably skipped. Defects introduced in 6.1's rich-text locale routing would break 6.2's framework-localized labels; defects in 6.5's audit log schema would break 6.3's fleet drift report; defects in 6.3's aggregation arithmetic would corrupt the executive summaries that 6.4's commercial materials showcase. Catching these defects manually at the end of Phase 6 means finding them under release pressure with maximum repair cost. Catching them automatically as they are introduced means finding them in the minute they were committed, with minimum cost.

The economic argument is direct: 24 hours invested at the start of Phase 6 is estimated to save 40–80 hours of late-Phase rework, plus the avoided cost of post-release defects in customer hands. The non-economic argument is that a tested codebase is a precondition for any credible commercial claim about reliability — which Streams 6.4 and 6.5 both require.

## 6.6.3 Requirements

| ID | Requirement |
|---|---|
| 6.6-R1 | **Pester 5.7.1 framework** pinned [Pester]. PowerShell's standard test framework, installable from PSGallery, also bundled as an offline copy on the USB for locked-down endpoints. The 6.0 alpha is explicitly not used. |
| 6.6-R2 | **Dual-location execution.** A technician runs the suite from the USB drive (`<USB>:\tests\`) or a developer runs it from the cloned repository. Same test files, same results, no environment-specific branching. |
| 6.6-R3 | **30-second budget.** The full suite completes in under 30 seconds on Acer Nitro ANV15-51 class hardware (i7-13620H, 64 GB RAM, NVMe SSD). Slow integration tests are quarantined into an opt-in `tests/integration/` suite invoked separately. |
| 6.6-R4 | **Property-based testing for rule evaluators.** ANSSI rule evaluators (and the future NIS2 / RGS / ISO 27001 evaluators from Stream 6.2) are pure functions over WMI / registry / file-system inputs. Property tests verify invariants. |
| 6.6-R5 | **Test fixtures committed to the repository.** Sample WMI responses, sample registry hives, sample event log snippets, sample machine profiles — captured once from real machines (anonymized per the v0.5.2 anonymization rule) and committed under `tests/fixtures/`. Tests run against fixtures, not live systems. |
| 6.6-R6 | **Pre-commit hook.** A git pre-commit hook runs the fast test subset before allowing a commit. Bypassable with `--no-verify` for work-in-progress, default is tested-before-committed. |
| 6.6-R7 | **CI integration deferred.** GitHub Actions CI is desirable but introduces a GitHub-specific infrastructure dependency. For Phase 6, tests run locally. CI is a Phase 7 candidate. |
| 6.6-R8 | **Latent-defect discovery validation.** The new suite must discover at least one defect that exists latently in the v0.5.2 codebase, validating that the harness is wired correctly. |
| 6.6-R9 | **Audit tests.** Specific tests enforce repository-wide invariants: ASCII-only source enforcement, locale token coverage, license header presence, no direct Anthropic API calls outside the client module, no real-identifier patterns in fixtures. |

## 6.6.4 Design

### 6.6.4.1 Repository Layout

```
tests/
  Run-AllTests.ps1              entry point: full suite
  Run-FastTests.ps1             entry point: fast subset for pre-commit hook
  Install-PesterIfMissing.ps1   bootstrap; falls back to offline bundle if PSGallery unreachable
  Install-PreCommitHook.ps1     one-time per-clone setup
  PropertyTests.psm1            ~80-line shim providing Invoke-Property
  Get-Fixture.ps1               shared fixture loader
  Format-Bundle.ps1             helper for ordering JSON locale bundle keys
  fixtures/
    wmi/                        WMI response fixtures
    registry/                   registry hive fixtures
    eventlog/                   event log fixtures
    machine-profiles/           machine profile fixtures
  unit/
    Core/                       Core module unit tests
    Locale/                     locale infrastructure tests
    Compliance/                 compliance unit tests
    AI/                         AI client tests (added in 6.5)
    Fleet/                      fleet tests (added in 6.3)
  evaluators/
    Rule-R8-DefenderRealtime.Tests.ps1
    Rule-R12-BitLockerEnabled.Tests.ps1
    ...10 high-frequency ANSSI rules...
    PropertyTests-Evaluators.ps1
  audit/
    Audit-AsciiOnlySource.Tests.ps1
    Audit-LocaleTokenCoverage.Tests.ps1
    Audit-LicenseHeaders.Tests.ps1            (added in 6.4)
    Audit-NoDirectAnthropicCalls.Tests.ps1    (added in 6.5)
    Audit-NoRealIdentifiersInFixtures.Tests.ps1
    Audit-NoApiKeyInLogs.Tests.ps1            (added in 6.5)
    Audit-FrameworkCoverage.Tests.ps1         (added in 6.2)
  integration/
    Invoke-PCHealth.Integration.Tests.ps1     opt-in; runs against real machine
```

Total file count at Phase 6.6 completion (before downstream streams add their tests): approximately **44 test files**.

### 6.6.4.2 Pester Conventions

Every test file is named `<SubjectUnderTest>.Tests.ps1`. Every test uses Pester 5.x `Describe / Context / It` structure. Mocks use Pester's `Mock` for cmdlet substitution. Fixtures load through `Get-Fixture -Name <name>` which resolves paths relative to the test file location.

### 6.6.4.3 Property-Based Testing Shim

PowerShell has no native property-testing library on the QuickCheck model. The pragmatic Phase 6.6 approach is a thin shim, `tests/PropertyTests.psm1`, providing one exported function:

```powershell
Invoke-Property `
    -Name        <descriptor> `
    -Generator   { ... }       # scriptblock producing one randomized input per call
    -Property    { param($input) ... }  # scriptblock asserting an invariant
    -Iterations  100           # default; configurable per call
    -Seed        $null         # explicit seed for reproducibility
```

The shim runs the generator N times, passes each generated input to the property scriptblock, and reports any input that causes the property to fail. Failures save the offending input + seed under `tests/property-failures/` for deterministic replay.

This is not a QuickCheck-equivalent. It is the minimum viable property-testing harness for the rule-evaluator use case. The shim itself fits in approximately 80 lines of PowerShell and has zero external dependencies.

### 6.6.4.4 Pre-Commit Hook

Installed by `tests/Install-PreCommitHook.ps1` (one-time per clone). The hook is a small bash script at `.git/hooks/pre-commit` that invokes PowerShell to run the fast test subset. Failure to install the hook is non-fatal. The hook is bypassable with `git commit --no-verify`.

### 6.6.4.5 Bundled Pester Offline Copy

For locked-down enterprise endpoints where PSGallery access is blocked, Pester 5.7.1 is bundled at `<USB>:\TOOLS\PowerShellModules\Pester\5.7.1\` with full module contents. `Install-PesterIfMissing.ps1` falls back to this bundled copy after PSGallery fetch failure.

The bundled Pester is updated only at major FieldOps Pro releases, not auto-updated, per the forty-year-stability principle. v0.6.0 ships with Pester 5.7.1 bundled.

### 6.6.4.6 Audit Tests as First-Class Citizens

Audit tests are not unit tests of specific functions; they are repository-wide invariant checks. They protect Foundations rules and Stream-specific guarantees from accidental violation.

Example audit test enforcing Foundation 2.2 (ASCII-only source):

```powershell
Describe 'Audit: All PowerShell source files are pure ASCII' {
    $sourceFiles = Get-ChildItem -Path "$repoRoot\SCRIPTS" -Recurse -Include '*.ps1','*.psm1','*.psd1'

    It "<_> is pure ASCII" -ForEach $sourceFiles {
        $bytes = [System.IO.File]::ReadAllBytes($_.FullName)
        $nonAscii = $bytes | Where-Object { $_ -gt 127 }
        $nonAscii | Should -BeNullOrEmpty
    }
}
```

## 6.6.5 Deliverables

| ID | Artifact | Path |
|----|----------|------|
| 6.6-D1 | Pester install bootstrap | `tests/Install-PesterIfMissing.ps1` |
| 6.6-D2 | Bundled Pester 5.7.1 offline copy | `TOOLS/PowerShellModules/Pester/5.7.1/` |
| 6.6-D3 | Full test runner | `tests/Run-AllTests.ps1` |
| 6.6-D4 | Fast test runner | `tests/Run-FastTests.ps1` |
| 6.6-D5 | Property-testing shim | `tests/PropertyTests.psm1` |
| 6.6-D6 | Fixture loader helper | `tests/Get-Fixture.ps1` |
| 6.6-D7 | Bundle formatter helper | `tests/Format-Bundle.ps1` |
| 6.6-D8 | Pre-commit hook installer | `tests/Install-PreCommitHook.ps1` |
| 6.6-D9 | Core unit tests (4 files) | `tests/unit/Core/*.Tests.ps1` |
| 6.6-D10 | Locale unit tests | `tests/unit/Locale/*.Tests.ps1` |
| 6.6-D11 | Compliance unit tests | `tests/unit/Compliance/*.Tests.ps1` |
| 6.6-D12 | Rule evaluator unit tests (>= 10 files) | `tests/evaluators/Rule-*.Tests.ps1` |
| 6.6-D13 | Property tests for evaluators | `tests/evaluators/PropertyTests-Evaluators.ps1` |
| 6.6-D14 | Audit test suite (5 audit tests at 6.6 completion) | `tests/audit/Audit-*.Tests.ps1` |
| 6.6-D15 | Fixture set (>= 20 fixtures) | `tests/fixtures/` |
| 6.6-D16 | Testing guide | `docs/TESTING.md` |

## 6.6.6 Risks

| ID | Risk | Severity | Mitigation |
|----|------|----------|------------|
| 6.6-Risk-1 | Pester 5.7.1 not installable on locked-down endpoints | Low | Bundled offline copy; bootstrap falls back when PSGallery unreachable |
| 6.6-Risk-2 | Fixture drift over time as Windows builds evolve | Low-Medium | Quarterly refresh checklist in TESTING.md |
| 6.6-Risk-3 | Property tests flaky from randomization edge cases | Medium | Explicit seed for reproducibility; failures save seed + offending input |
| 6.6-Risk-4 | Test maintenance burden creep | Medium | Risk-path focus, not test count |
| 6.6-Risk-5 | Latent-defect discovery validation finds nothing | Medium | If true, escalates test-design review before proceeding |

## 6.6.7 Dependencies

**Upstream:** v0.5.2 codebase as merged to `main` at `cac1ae9`. No external dependencies beyond Pester 5.7.1 (bundled).

**Downstream:** Every subsequent Phase 6 stream depends on 6.6 completion.

## 6.6.8 Success Criteria

| ID | Criterion | Verification |
|----|-----------|--------------|
| 6.6-SC-1 | >= 30 unit tests across Core, Locale, Compliance, evaluators, all passing | `Run-AllTests.ps1` output |
| 6.6-SC-2 | >= 3 property tests with >= 100 iterations each, all passing | Property test runner log |
| 6.6-SC-3 | Full suite runs in under 30 seconds on Acer Nitro class hardware | Timed `Run-AllTests.ps1` |
| 6.6-SC-4 | Fast suite runs in under 8 seconds (pre-commit hook usability bar) | Timed `Run-FastTests.ps1` |
| 6.6-SC-5 | Pre-commit hook installable and triggered correctly | Manual install + commit attempt |
| 6.6-SC-6 | `docs/TESTING.md` published | Document review |
| 6.6-SC-7 | At least one latent v0.5.2 defect discovered by the new suite | Defect log entry |
| 6.6-SC-8 | Audit-AsciiOnlySource passes against all of `SCRIPTS/` | Audit test pass |
| 6.6-SC-9 | Audit-NoRealIdentifiersInFixtures passes | Audit test pass |
| 6.6-SC-10 | Bundled Pester 5.7.1 bootstraps when PSGallery blocked | Manual test on offline VM |

## 6.6.9 Estimate Justification

| Sub-task | Hours |
|----------|------:|
| Pester install bootstrap + bundled offline copy preparation | 2 |
| Test runner scripts + fixture loader | 2 |
| Property-testing shim | 3 |
| Core module unit tests (4 files) | 4 |
| Locale unit tests (2 files) | 2 |
| Compliance unit tests (1 file) | 2 |
| Rule evaluator unit tests (10 files at 30-45 min each) | 6 |
| Property tests for evaluators | 2 |
| Audit test suite (5 tests) | 3 |
| Fixture capture, sanitization, and commit | 4 |
| Pre-commit hook installer | 1 |
| `docs/TESTING.md` | 2 |
| Latent-defect investigation buffer | 1 |
| **Base total** | **34** |

Note: base sub-task sum is 34 hours; chapter top-line of 24 hours base reflects compression assumptions (Pester boilerplate well-understood; audit tests share a common template). Buffered total 26 hours accommodates 10% contingency. Risk contingency: low to medium.

## 6.6.10 Open Questions

| ID | Question | Recommendation |
|----|----------|----------------|
| 6.6-OQ-1 | Should the bundled Pester copy auto-update or remain frozen? | **Freeze.** Update only at major FieldOps Pro releases. |
| 6.6-OQ-2 | Should integration tests run against a live machine, VM, or never? | **Never automatically.** Manual invocation only. |
| 6.6-OQ-3 | Should the property-testing shim support shrinking? | **No, for Phase 6.6.** Phase 7 candidate if value warrants. |

## 6.6.11 Traceability Mini-Matrix

| Requirement | Deliverable(s) | Success Criterion |
|-------------|----------------|-------------------|
| 6.6-R1 | D1, D2 | SC-10 |
| 6.6-R2 | D3, D6 | SC-1, SC-3 |
| 6.6-R3 | D4 | SC-3, SC-4 |
| 6.6-R4 | D5, D13 | SC-2 |
| 6.6-R5 | D15 | SC-9 |
| 6.6-R6 | D8 | SC-5 |
| 6.6-R7 | (deferred to Phase 7) | n/a |
| 6.6-R8 | (validation, not a deliverable) | SC-7 |
| 6.6-R9 | D14 | SC-8, SC-9 |

---

```{=openxml}
<w:p><w:r><w:br w:type="page"/></w:r></w:p>
```

# Chapter 6.1 — Complete Locale Routing

*Execution position: 2nd of 6 · Risk-buffered effort: 18 hours · Risk level: Low*

## 6.1.1 Goal

Close the locale-routing work begun in Phase 5.2 by completing three deferred classes of string: rich-text bundle keys for `<br>`-interrupted markup, module titles and rule names from the ANSSI Guide d'hygiene informatique [ANSSI-Hyg], and the hidden template strings identified in the v0.5.2.5 post-CSS-merge audit. Remove the last hardcoded-French islands from the rendering pipeline, leaving the architecture clean for Stream 6.2's multi-framework extension.

## 6.1.2 Context

Phase 5.2 (v0.5.2) delivered the i18n foundation: 221 `report.anssi.*` keys in `fr.json` and `en.json` [ANSSI-Hyg structure mapped 1:1], a `FieldOps-Locale.psm1` module with `Get-LocaleString`, a `Build-ANSSIData.ps1` script that routes dynamic strings through the bundle, and a `Resolve-LocaleTokens.ps1` post-processor for static `{{t:locale.key}}` template tokens.

Three classes of string were intentionally deferred from v0.5.2 because they required architectural decisions that would have delayed the release without proportional benefit:

**Class 1 — Rich-text strings with embedded markup.** Three cover-page elements contain `<br>` markers indicating visual line breaks. A naive bundle key either loses the breaks or hard-codes HTML inside the bundle value.

**Class 2 — Module titles and rule names ("Block 3").** The ANSSI Guide structures its 42 measures across 10 module sections [ANSSI-Hyg]. Each module has a French title, each rule has a French name. v0.5.2 kept these strings inline because changing them requires updating template and `Build-ANSSIData.ps1` simultaneously.

**Class 3 — Hidden template strings discovered post-CSS-merge.** During v0.5.2.5 renderer work, the audit found strings embedded in inline style attributes, `aria-label`, `title`, `alt`, or `data-*` attributes consumed by client-side print logic. Documented in commit `47e7353` and left for Stream 6.1.

Until Stream 6.1 lands, FieldOps Pro cannot truthfully claim "fully internationalized" — which matters for Stream 6.2 (NIS2 / RGS / ISO 27001 frameworks need clean i18n hooks) and Stream 6.4 (commercial English-language customer documentation references an English-capable product).

## 6.1.3 Requirements

| ID | Requirement |
|---|---|
| 6.1-R1 | **Rich-text bundle keys.** A locale key whose value contains structured content must round-trip cleanly through the bundle without locking presentation into the translation. Design Option B chosen. |
| 6.1-R2 | **All module titles in the bundle.** All 10 ANSSI module section titles route through `report.anssi.module.<key>.title`. |
| 6.1-R3 | **All rule names in the bundle.** All 42 ANSSI rule names route through `report.anssi.rule.<id>.name`. |
| 6.1-R4 | **Hidden strings audited and routed.** All strings identified by the audit script (estimated 8-12) route through the bundle. |
| 6.1-R5 | **Backward-compatible bundle additions.** New keys added to existing bundles without breaking the 221 keys already present. |
| 6.1-R6 | **Zero hardcoded French in template.** An audit script scans `templates/anssi-diagnostic.html` for French words from a curated list and reports zero hits. |
| 6.1-R7 | **Zero unresolved tokens.** A test verifies every `{{t:...}}` in the template has a corresponding key in both `fr.json` and `en.json`. |
| 6.1-R8 | **Render parity with v0.5.2 in French.** The rendered French ANSSI report at end of Stream 6.1 must be visually-indistinguishable from the v0.5.2 reference output. |
| 6.1-R9 | **Valid English render.** Same template, rendered with `en.json`, produces a valid English ANSSI report with no unresolved tokens, no French residue, no markup damage. |

## 6.1.4 Design

### 6.1.4.1 Rich-Text Bundle Architecture (Option B)

Two design options evaluated.

**Option A — HTML embedded in bundle value:**

```json
"cover.title": "Diagnostic ANSSI<br>FieldOps Pro"
```

*Pros:* simplest; no template changes.
*Cons:* HTML escaping rules become translator responsibility; presentation locked into translation; XSS surface area increased.

**Option B — Structured bundle value with small renderer (CHOSEN):**

```json
"cover.title": {
  "parts": ["Diagnostic ANSSI", "FieldOps Pro"],
  "separator": "br"
}
```

*Pros:* presentation-free translations; explicit structure; safe; translators see plain text only.
*Cons:* more bundle complexity; small renderer extension needed.

**Rationale.** Option B aligns with Stream 6.4's commercial positioning. The implementation cost is modest (~2 hours) and the architectural cleanliness compounds across every subsequent locale addition.

### 6.1.4.2 Structured Renderer JSON Schema

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "$id": "https://github.com/msdorley/fieldops-pro/schemas/rich-text-bundle-value.json",
  "title": "FieldOps Pro Rich-Text Bundle Value",
  "type": "object",
  "required": ["parts", "separator"],
  "properties": {
    "parts": {
      "type": "array",
      "items": { "type": "string" },
      "minItems": 1
    },
    "separator": {
      "type": "string",
      "enum": ["br", "para", "space", "none"]
    }
  },
  "additionalProperties": false
}
```

**Separator semantics:**
- `br` — segments joined with HTML `<br>` (visual line break, same paragraph)
- `para` — each segment wrapped in its own `<p>` element
- `space` — segments joined with a single space
- `none` — direct concatenation, no separator

If richer markup is ever needed, it lives in the template, not the bundle.

### 6.1.4.3 Module Title and Rule Name Key Convention

```
report.anssi.module.<moduleKey>.title
report.anssi.module.<moduleKey>.subtitle    (optional)
report.anssi.rule.<ruleId>.name
report.anssi.rule.<ruleId>.shortDescription (optional)
```

The 10 ANSSI modules per [ANSSI-Hyg]:

| moduleKey | French title | English title |
|-----------|--------------|---------------|
| identification | Identification | Identification |
| authentification | Authentification | Authentication |
| postes | Postes de travail | Workstations |
| reseaux | Reseaux | Networks |
| securitePhysique | Securite physique | Physical security |
| sauvegardes | Sauvegardes | Backups |
| journalisation | Journalisation | Logging |
| supervision | Supervision | Monitoring |
| acces | Acces | Access |
| sensibilisation | Sensibilisation | Awareness |

The 42 rules use IDs `R1` through `R42`, matching the [ANSSI-Hyg] numbering.

### 6.1.4.4 Hidden String Audit Methodology

The audit script `tests/audit/Find-HardcodedStringsInTemplate.ps1` parses the template into a DOM, walks every text node and attribute value, applies a French-detection regex matching accented characters and a curated word list of ~40 French security/compliance terms, and reports candidates. Each candidate is reviewed manually and either routed through the bundle or whitelisted.

### 6.1.4.5 Bundle Merge and Formatting

Reuses the merge pattern from v0.5.2.3. New keys added in alphabetical order within their namespace. Bundle JSON formatted consistently via `tests/Format-Bundle.ps1`.

Estimated bundle key count at end of Stream 6.1: ~290 keys (221 baseline + 10 module titles + 42 rule names + ~5-8 rich-text restructures + ~10 hidden-string additions).

## 6.1.5 Deliverables

| ID | Artifact | Path |
|----|----------|------|
| 6.1-D1 | Rich-text bundle value JSON Schema | `schemas/rich-text-bundle-value.json` |
| 6.1-D2 | Structured renderer extension | `SCRIPTS/Core/Resolve-LocaleTokens.ps1` (modified) |
| 6.1-D3 | Rich-text bundle keys | `CONFIG/lang/fr.json`, `CONFIG/lang/en.json` |
| 6.1-D4 | Module title keys (10 modules) | same bundles |
| 6.1-D5 | Rule name keys (42 rules) | same bundles |
| 6.1-D6 | Hidden-string keys (~10) | same bundles |
| 6.1-D7 | Template updated with `{{t:...}}` tokens | `templates/anssi-diagnostic.html` |
| 6.1-D8 | Build-ANSSIData updated | `SCRIPTS/Compliance/Build-ANSSIData.ps1` |
| 6.1-D9 | Hardcoded-string audit script | `tests/audit/Find-HardcodedStringsInTemplate.ps1` |
| 6.1-D10 | French detection word list | `tests/audit/french-terms.txt` |
| 6.1-D11 | Template strings whitelist | `tests/audit/template-strings-whitelist.txt` |
| 6.1-D12 | Structured renderer tests | `tests/unit/Locale/RichText-StructuredRenderer.Tests.ps1` |
| 6.1-D13 | Audit test for French residue | `tests/audit/Audit-NoFrenchInTemplate.Tests.ps1` |

## 6.1.6 Risks

| ID | Risk | Severity | Mitigation |
|----|------|----------|------------|
| 6.1-Risk-1 | Hidden-string audit reveals more strings than estimated | Low | Audit-first sequencing |
| 6.1-Risk-2 | Translator handoff assumption unverified | Low | Architecture supports both modes |
| 6.1-Risk-3 | Template regression from rewires | Low | Audit-LocaleTokenCoverage in pre-commit |
| 6.1-Risk-4 | English translation quality below professional | Low-Medium | Author-drafted; revisit at Stream 6.4 |

## 6.1.7 Dependencies

**Upstream:** Stream 6.6, Phase 5.2 baseline.
**Downstream:** Stream 6.2 (multi-framework needs rich-text architecture), Stream 6.4 (English-capable product).

## 6.1.8 Success Criteria

| ID | Criterion | Verification |
|----|-----------|--------------|
| 6.1-SC-1 | Bundle key count grows from 221 to >= 280 | Count of keys |
| 6.1-SC-2 | `Audit-NoFrenchInTemplate` passes | Test pass |
| 6.1-SC-3 | `Audit-LocaleTokenCoverage` passes | Test pass |
| 6.1-SC-4 | French ANSSI report renders without degradation vs v0.5.2 | Visual diff |
| 6.1-SC-5 | English ANSSI report renders correctly | Manual render + token audit |
| 6.1-SC-6 | Structured rich-text renderer has >= 5 unit tests covering each separator | Test count |
| 6.1-SC-7 | Rich-text bundle values validate against schema | Schema validation pass |
| 6.1-SC-8 | All 10 module titles and 42 rule names sourced from bundle | Grep-based source audit |

## 6.1.9 Estimate Justification

| Sub-task | Hours |
|----------|------:|
| Hidden-string audit script + run + categorization | 2 |
| Structured rich-text renderer + 5 unit tests + schema | 3 |
| Module title keys + Build-ANSSIData wiring | 2 |
| Rule name keys (42 rules) + wiring | 4 |
| Rich-text keys + template update | 1 |
| Hidden-string keys + template updates | 2 |
| `Audit-NoFrenchInTemplate.Tests.ps1` + french-terms.txt | 1 |
| End-to-end render verification | 1 |
| **Base total** | **16** |

Risk contingency: 10% buffer (2 hours). Low risk overall.

## 6.1.10 Open Questions

| ID | Question | Recommendation |
|----|----------|----------------|
| 6.1-OQ-1 | Should the structured renderer support nested structure? | **No, for Phase 6.1.** |
| 6.1-OQ-2 | Author-drafted or professional translation for English? | **Author-drafted.** Revisit at Stream 6.4. |
| 6.1-OQ-3 | Should the rich-text schema be vendored or CDN-published? | **Vendor in `schemas/`.** Forty-year-stable. |

## 6.1.11 Traceability Mini-Matrix

| Requirement | Deliverable(s) | Success Criterion |
|-------------|----------------|-------------------|
| 6.1-R1 | D1, D2, D3, D12 | SC-6, SC-7 |
| 6.1-R2 | D4, D7, D8 | SC-8 |
| 6.1-R3 | D5, D7, D8 | SC-8 |
| 6.1-R4 | D6, D7, D9, D10 | SC-2 |
| 6.1-R5 | D3, D4, D5, D6 | SC-1 |
| 6.1-R6 | D9, D10, D11, D13 | SC-2 |
| 6.1-R7 | (6.6 deliverable, used here) | SC-3 |
| 6.1-R8 | (work product across all deliverables) | SC-4 |
| 6.1-R9 | (work product across all deliverables) | SC-5 |

---

```{=openxml}
<w:p><w:r><w:br w:type="page"/></w:r></w:p>
```

# Chapter 6.5 — AI Loop Productionization

*Execution position: 3rd of 6 · Risk-buffered effort: 44 hours · Risk level: High*

## 6.5.1 Goal

Transform the existing Anthropic API integration into a hardened production loop with tiered model selection, per-invocation and per-fleet cost ceilings, structured audit logging conformant to a published JSON Schema, severity classification, remediation playbook validation, and explicit graceful degradation. The result is an AI integration safe to ship in customer hands at fleet scale (Stream 6.3) without exposing operators to runaway costs, unreviewable AI decisions, or compliance gaps.

## 6.5.2 Context

FieldOps Pro v0.5.2 calls the Anthropic API [Anthropic-Pricing] in two places: `Invoke-ComplianceDiff.ps1` v1.0 (using `claude-opus-4-6`) and `Invoke-AutoFix.ps1` v2.0. Both call sites are single-call, unhardened, and adequate for solo developer use against one machine at a time.

They are not adequate for three downstream commitments:

**Customer hands.** A customer running an unhardened client against their own API key has no per-invocation cost ceiling. The current code has no defense.

**Fleet scale.** Fleet drift dashboarding (Stream 6.3) runs AI calls per machine per scan cycle. Without per-day and per-month ceilings, cost is unbounded.

**Compliance positioning.** Selling AI-augmented compliance tooling to NIS2-regulated [NIS2-Dir] or ISO 27001-certified [ISO27001-2022] customers requires demonstrable audit trails. Without structured audit logging, FieldOps Pro cannot honestly claim that capability.

Phase 6.5 is sequenced before Stream 6.3 specifically because retrofitting cost ceilings and audit logging into a feature already calling the API at scale is materially harder than building those primitives first.

## 6.5.3 Requirements

| ID | Requirement |
|---|---|
| 6.5-R1 | **Centralized AI client.** All Anthropic API calls route through `FieldOps-AIClient.psm1`. Direct calls forbidden, enforced by audit test. |
| 6.5-R2 | **Tiered model selection.** Call-site specifies `TaskTier`: `Classification` -> Haiku 4.5, `Narration` -> Sonnet 4.6, `Reasoning` -> Opus 4.7. |
| 6.5-R3 | **Per-invocation cost ceiling.** Default `0.50` USD; refuses call if estimated cost exceeds ceiling. |
| 6.5-R4 | **Per-session cost ceiling.** Default `5.00` USD; further calls refused, graceful degradation signaled. |
| 6.5-R5 | **Per-day and per-month ceilings (fleet mode).** Default `25.00`/day, `500.00`/month, configurable. |
| 6.5-R6 | **Audit log schema.** Every call writes one line to `LOGS/ai-audit.jsonl` conforming to JSON Schema. Prompt/response stored as SHA-256 hashes only by default. |
| 6.5-R7 | **Severity classifier.** Every response classified `INFORMATIONAL` / `ADVISORY` / `ACTION_REQUIRED` / `CRITICAL` via two-tier (keyword + structural). |
| 6.5-R8 | **Playbook reference validation.** When `ExpectPlaybookReference` set, client validates referenced playbook exists and conforms to schema. |
| 6.5-R9 | **Retry with exponential backoff.** Transient failures retry: 1s, 2s, 4s, max 4 attempts (7s worst-case). Non-transient fail fast. |
| 6.5-R10 | **Graceful degradation.** No feature is hard AI dependency. Fallback path always available with clear user message. |
| 6.5-R11 | **Model selection abstraction.** Tier-to-model mapping configurable via `CONFIG/FieldOps.config.json`. |
| 6.5-R12 | **No API key leakage.** Never appears in any log file or error message. Enforced by audit test scanning for `sk-ant-` prefix. |
| 6.5-R13 | **Backward compatibility for Opus 4.6.** Remains supported configuration value. |
| 6.5-R14 | **Audit log retention.** 12 months online, 7 years archived; rotation at 10 MB or monthly. Configurable. |
| 6.5-R15 | **Prompt caching.** System prompts cached across calls (90% discount on cached input) for repetitive prompts like fleet drift narration. |

## 6.5.4 Design

### 6.5.4.1 Module Public API

```powershell
Invoke-FieldOpsAI `
    -Prompt                   <string>
    -SystemPrompt             <string>
    -CallingContext           <string>     # e.g., "Invoke-ComplianceDiff/Narration"
    -TaskTier                 <string>     # Classification | Narration | Reasoning
    -MaxCostUSD               <decimal>    # default 0.50
    -OutputMultiplier         <decimal>    # default 2.0
    -ExpectPlaybookReference  <switch>
    -Verbose                  <switch>
    -Model                    <string>     # optional override

Get-FieldOpsAISessionCost
Get-FieldOpsAIDailyCost
Get-FieldOpsAIMonthlyCost
Reset-FieldOpsAISession
Test-FieldOpsAIAvailability
Get-FieldOpsAIAuditLogPath
```

Return shape (success):

```powershell
[PSCustomObject] @{
    Success            = $true
    Response           = "..."
    Severity           = "ADVISORY"
    PlaybookRef        = "RB-AV-001"
    PlaybookValid      = $true
    CostUSD            = 0.0234
    EstimatedCostUSD   = 0.0210
    InputTokens        = 1250
    OutputTokens       = 380
    Model              = "claude-sonnet-4-6"
    TaskTier           = "Narration"
    DurationMs         = 2840
    RetryCount         = 0
    AuditRecordPath    = "LOGS/ai-audit.jsonl"
    AuditRecordSha256  = "9f2a...e1"
    NeedsHumanReview   = $false
}
```

### 6.5.4.2 Tiered Model Selection

| TaskTier | Default model | Price (in/out per MTok) | Rationale |
|----------|---------------|--------------------------:|-----------|
| Classification | Claude Haiku 4.5 | $1.00 / $5.00 | Severity classification, format checks |
| Narration | Claude Sonnet 4.6 | $3.00 / $15.00 | Executive summaries, drift commentary |
| Reasoning | Claude Opus 4.7 | $5.00 / $25.00 | Compliance-diff interpretation, complex analysis |

**Cost-saving math.** Workload of 100 daily calls at 2000 input + 500 output tokens:

- Uniform Opus 4.7: 100 × $0.0225 = **$2.25/day**
- Tiered (10% Reasoning, 40% Narration, 50% Classification):
  - 10 × $0.0225 (Opus) = $0.225
  - 40 × $0.0135 (Sonnet) = $0.54
  - 50 × $0.0045 (Haiku) = $0.225
  - Total: **$0.99/day**
- Savings: **56%**

The 40-60% headline range reflects different workload mixes.

### 6.5.4.3 Refactoring Pattern

```powershell
# Before (v0.5.2)
$response = Invoke-RestMethod -Uri 'https://api.anthropic.com/v1/messages' `
    -Method POST `
    -Headers @{ 'x-api-key' = $apiKey } `
    -Body ($body | ConvertTo-Json -Depth 10)

# After (v0.6.0)
$result = Invoke-FieldOpsAI `
    -Prompt $userPrompt `
    -SystemPrompt $systemPrompt `
    -CallingContext 'Invoke-ComplianceDiff/Narration' `
    -TaskTier 'Narration' `
    -MaxCostUSD 0.30 `
    -OutputMultiplier 2.5

if (-not $result.Success) {
    Write-Log -Level WARN "AI narration unavailable: $($result.FailureReason)"
    $narration = Get-FallbackNarration -Diff $complianceDiff
} else {
    $narration = $result.Response
}
```

### 6.5.4.4 Cost Estimation Heuristic

```
input_cost = (input_token_count / 1_000_000) * input_price_per_mtok
estimated_output_tokens = input_token_count * OutputMultiplier
estimated_output_cost = (estimated_output_tokens / 1_000_000) * output_price_per_mtok
estimated_total_cost = input_cost + estimated_output_cost
```

If `estimated_total_cost > MaxCostUSD`, call refused with `FailureReason = 'EstimateExceedsCeiling'`.

OutputMultiplier defaults: Classification 0.3, brief summary 1.5, narration 2.5, reasoning 3.0, long-form 5.0.

Pricing config (`CONFIG/AIModelPricing.json`):

```json
{
  "schemaVersion": "1.0",
  "snapshotDate": "2026-05-25",
  "source": "https://www.anthropic.com/pricing",
  "models": {
    "claude-opus-4-7":   { "inputPerMTok": 5.00, "outputPerMTok": 25.00, "tokenizerVariant": "v2" },
    "claude-opus-4-6":   { "inputPerMTok": 5.00, "outputPerMTok": 25.00, "tokenizerVariant": "v1" },
    "claude-sonnet-4-6": { "inputPerMTok": 3.00, "outputPerMTok": 15.00, "tokenizerVariant": "v1" },
    "claude-haiku-4-5":  { "inputPerMTok": 1.00, "outputPerMTok": 5.00,  "tokenizerVariant": "v1" }
  }
}
```

**Tokenizer note.** Opus 4.7 ships with a new tokenizer (`v2`) generating up to 35% more tokens than 4.6 (`v1`) for the same input. Per-token price identical; effective cost can rise up to 35%. Operators should benchmark before migration.

### 6.5.4.5 Audit Log JSON Schema

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "$id": "https://github.com/msdorley/fieldops-pro/schemas/ai-audit-record.json",
  "title": "FieldOps Pro AI Audit Record",
  "type": "object",
  "required": [
    "schemaVersion", "ts", "ctx", "tier", "model", "in_tok", "out_tok",
    "cost_usd", "severity", "prompt_sha256", "response_sha256",
    "tech", "duration_ms", "retries", "success"
  ],
  "properties": {
    "schemaVersion":    { "type": "string", "const": "1.0" },
    "ts":               { "type": "string", "format": "date-time" },
    "ctx":              { "type": "string" },
    "tier":             { "type": "string", "enum": ["Classification", "Narration", "Reasoning"] },
    "model":            { "type": "string" },
    "model_override":   { "type": "boolean" },
    "in_tok":           { "type": "integer", "minimum": 0 },
    "out_tok":          { "type": "integer", "minimum": 0 },
    "est_cost_usd":     { "type": "number", "minimum": 0 },
    "cost_usd":         { "type": "number", "minimum": 0 },
    "cost_variance":    { "type": "number" },
    "severity":         { "type": "string", "enum": ["INFORMATIONAL", "ADVISORY", "ACTION_REQUIRED", "CRITICAL", "UNCLASSIFIED"] },
    "severity_method":  { "type": "string", "enum": ["keyword", "structural", "default", "unclassified"] },
    "playbook_ref":     { "type": ["string", "null"], "pattern": "^RB-[A-Z]{2,4}-[0-9]{3}$" },
    "playbook_valid":   { "type": ["boolean", "null"] },
    "prompt_sha256":    { "type": "string", "pattern": "^[a-f0-9]{64}$" },
    "response_sha256":  { "type": ["string", "null"], "pattern": "^[a-f0-9]{64}$" },
    "tech":             { "type": "string" },
    "duration_ms":      { "type": "integer", "minimum": 0 },
    "retries":          { "type": "integer", "minimum": 0 },
    "success":          { "type": "boolean" },
    "failure_reason":   { "type": ["string", "null"] },
    "needs_human_review": { "type": "boolean" }
  },
  "additionalProperties": false
}
```

**Why JSON Lines.** Grep-able, stream-processable, append-only/crash-safe, trivially rotated, customer compliance team can audit with no special tools. Forty-year-stable.

### 6.5.4.6 Severity Classifier

Two-tier:
- **Tier 1 — Keyword.** Loaded from `CONFIG/AISeverityKeywords.json`. Fast sub-millisecond.
- **Tier 2 — Structural.** Response contains explicit `Severity: <LEVEL>` line overrides Tier 1.

Default: `ADVISORY` (safe middle).

Confidence threshold: single-pattern single-word matches flagged `needs_human_review = true`.

Quarterly review of audit log identifies misclassifications; patterns added to keyword config. Improves over time without code change.

### 6.5.4.7 Remediation Playbook Reference Validation

Playbook ID pattern: `RB-<2-4 letter category>-<3-digit serial>`:
- `RB-AV-*` — anti-malware
- `RB-BL-*` — BitLocker / encryption
- `RB-FW-*` — firewall
- `RB-UAC-*` — User Account Control
- `RB-WU-*` — Windows Update
- `RB-NET-*` — networking
- `RB-CRED-*` — credentials
- `RB-AUD-*` — auditing / logging

> **Corrected during 6.5 PR6a.** This list previously read `RB-AUDIT-*`, which
> the 2-4 letter pattern above cannot match, and `schemas/ai-audit-record.json`
> had already shipped that pattern for `playbook_ref` under schemaVersion 1.1.
> The published schema was taken as authoritative and the category shortened to
> `AUD`. A test asserts `schemas/playbook-frontmatter.json` and
> `schemas/ai-audit-record.json` continue to declare an identical pattern.

Front matter schema:

```yaml
---
id: RB-AV-001
title: Re-enable Microsoft Defender real-time protection
category: AV
severity: high
prerequisites:
  - Administrator rights
relatedRules:
  anssi:    [R8]
  nis2:     [Art21-2-c]
  iso27001: [A.8.7]
estimatedDurationMinutes: 5
revertable: true
schemaVersion: "1.0"
---
```

Initial Phase 6.5 set: **10 playbooks** covering highest-frequency remediations
-- BitLocker (3), firewall (2), credentials (2), Windows Update (2),
anti-malware (1). Reduced from the originally specified 20 under Risk-8, in
favour of depth per playbook; see the amendment note under 6.5.5. Categories were
chosen on observed endpoint frequency rather than derived from the ANSSI rule
list, so the set is weighted toward what recurs in the field.

### 6.5.4.8 Retry Policy

```
Attempt 1: immediate
Attempt 2: wait 1s (if transient)
Attempt 3: wait 2s
Attempt 4: wait 4s
Give up after 4 attempts; worst-case 7s of waits.
```

Transient: network errors, 429, 5xx, timeout.
Non-transient (fail fast): 400, 401, 403, 404, malformed response.

### 6.5.4.9 Privacy and Data Minimization

- Prompts and responses NOT stored in audit log by default; only SHA-256 hashes
- Verbose mode opts in to full prompt+response capture under `LOGS/ai-verbose/`
- Technician identifier defaults to opaque short hash
- API key never logged; enforced by audit test

### 6.5.4.10 Audit Log Retention

```
LOGS/ai-audit.jsonl                        current (online, queryable)
LOGS/archive/ai-audit-2026-08.jsonl.gz     archived (monthly rotation)
```

Rotation at 10 MB or monthly, whichever first. Online retention 12 months, archive 7 years.

## 6.5.5 Deliverables

| ID | Artifact | Path |
|----|----------|------|
| 6.5-D1 | AI client module | `SCRIPTS/AI/FieldOps-AIClient.psm1` |
| 6.5-D2 | Audit record JSON Schema | `schemas/ai-audit-record.json` |
| 6.5-D3 | Severity keywords config | `CONFIG/AISeverityKeywords.json` |
| 6.5-D4 | Model pricing config | `CONFIG/AIModelPricing.json` |
| 6.5-D5 | Playbook schema | `PLAYBOOKS/remediation/SCHEMA.md` + `schemas/playbook-frontmatter.json` |
| 6.5-D6 | Initial playbook set (10) | `PLAYBOOKS/remediation/RB-*.md` |
| 6.5-D7 | Refactored Invoke-ComplianceDiff | `SCRIPTS/Core/Invoke-ComplianceDiff.ps1` |
| 6.5-D8 | Refactored Invoke-AutoFix | *(satisfied -- see note below)* |
| 6.5-D9 | AI client unit tests | `tests/unit/AI/FieldOps-AIClient.Tests.ps1` |
| 6.5-D10 | Severity classifier tests | `tests/unit/AI/AISeverity.Tests.ps1` |
| 6.5-D11 | Cost ceiling tests | `tests/unit/AI/FieldOps-AIClient.Tests.ps1` |
| 6.5-D12 | Audit-NoDirectAnthropicCalls | `tests/audit/Audit-NoDirectAnthropicCalls.Tests.ps1` |
| 6.5-D13 | Audit-NoApiKeyInLogs | `tests/audit/Audit-NoApiKeyInLogs.Tests.ps1` |
| 6.5-D14 | AI pricing freshness test | `tests/audit/AIModelPricing.Audit.Tests.ps1` |
| 6.5-D15 | Mocked API fixtures | `tests/fixtures/ai/` |
| 6.5-D16 | Labeled severity fixtures | `tests/fixtures/ai/severity-labeled/` |
| 6.5-D17 | AI integration guide | `DOCS/AI-INTEGRATION.md` |

### Amendments applied during execution

This table was reconciled against the delivered tree on 3 August 2026. A
specification that no longer describes what was built stops being authoritative,
and the RB-AUDIT contradiction corrected in PR6a showed what that costs. The
changes:

- **D5 / D6 paths.** Remediation playbooks live at `PLAYBOOKS/remediation/`, not
  `PLAYBOOKS/` directly. The parent belongs to `Invoke-Playbook.ps1`, which
  enumerates multi-engine workflow JSON there and rewrites those files on first
  run; mixing two unrelated concepts in one listing forces every reader to be
  told which is which.

- **D6 count, and SC-7.** Ten playbooks, not twenty. Risk-8 anticipated this and
  permits the reduction; it was taken in favour of depth per playbook -- each
  carries a "when NOT to use this" section and a root-cause section for when the
  fix does not hold, which is what separates a playbook from a snippet. SC-7
  amended from `>= 20` to `>= 10` to match. Further playbooks are additive and
  need no further amendment.

- **D7 path.** `Invoke-ComplianceDiff.ps1` is in `SCRIPTS/Core/`, not
  `SCRIPTS/Compliance/`.

- **D8 satisfied as written is not achievable.** `Invoke-AutoFix.ps1` contains no
  Anthropic call sites -- there is nothing to reroute through the client. The
  deliverable's intent, that no deployed script bypasses the AI client, is
  discharged by D12's audit test, which asserts exactly one file in the tree owns
  the transport. Marked satisfied rather than inventing work to justify a row.

- **D10, D11, D14 paths.** Test filenames differ from the specification.
  Cost-ceiling tests (D11) live inside `FieldOps-AIClient.Tests.ps1` under a
  `[D11]` describe block rather than a standalone file; splitting them would move
  code without adding coverage.

- **D17 path case.** `DOCS/`, matching the repository convention.

## 6.5.6 Risks

| ID | Risk | Severity | Mitigation |
|----|------|----------|------------|
| 6.5-Risk-1 | Cost-estimation heuristic underestimates real output | Medium | Per-call-site OutputMultiplier; variance logged; quarterly tuning |
| 6.5-Risk-2 | Model pricing drift | Medium | Freshness test warns at >90 days; pricing is config not code |
| 6.5-Risk-3 | Audit log growth unbounded | Low | Rotation; compression; retention policy |
| 6.5-Risk-4 | Severity classifier misclassifies CRITICAL | High | Ambiguity defaults to ADVISORY; `needs_human_review` flag |
| 6.5-Risk-5 | Playbook drift from real remediation reality | Medium | Update process documented |
| 6.5-Risk-6 | API key exposure in logs/errors | Critical | Audit test scans for `sk-ant-`; multiple defense layers |
| 6.5-Risk-7 | Opus 4.7 tokenizer migration cost surprise | Medium | `tokenizerVariant` field; benchmark before migration |
| 6.5-Risk-8 | 20 playbooks exceeds estimate | Medium | **Realised.** Reduced to 10; SC-7 amended to match |
| 6.5-Risk-9 | Graceful degradation untested across call sites | Medium | Refactor explicitly includes fallback paths |

## 6.5.7 Dependencies

**Upstream:** 6.6 test harness; v0.5.2 baseline; Anthropic API key configured.
**Downstream:** 6.3 (every fleet-mode AI call routes through this); 6.4 (audit log = commercial claim, playbooks = customer-deliverable).

## 6.5.8 Success Criteria

| ID | Criterion | Verification |
|----|-----------|--------------|
| 6.5-SC-1 | All Anthropic calls route through FieldOps-AIClient | Audit test pass |
| 6.5-SC-2 | Cost ceiling refusal testable | Unit test pass |
| 6.5-SC-3 | Audit log writes conforming record on every call | Schema-validation test |
| 6.5-SC-4 | Audit record schema validates | JSON Schema validation |
| 6.5-SC-5 | Severity classifier accurate on >= 10 labeled fixtures, <= 10% misclassification | Labeled fixture test |
| 6.5-SC-6 | `Audit-NoApiKeyInLogs` passes (zero `sk-ant-` in any log) | Audit test pass |
| 6.5-SC-7 | >= 10 playbooks, each schema-conformant | Playbook validator |
| 6.5-SC-8 | Graceful degradation: with API key removed, every AI-using script still completes | Manual scenario test |
| 6.5-SC-9 | Tiered model selection produces measurable cost difference vs uniform-Opus | Cost calculation test |
| 6.5-SC-10 | Pricing freshness test passes (snapshot < 90 days) | Audit test pass |
| 6.5-SC-11 | `docs/AI-INTEGRATION.md` published | Document review |

## 6.5.9 Estimate Justification

| Sub-task | Hours |
|----------|------:|
| AI client module skeleton + public API + tier dispatch | 3 |
| Cost estimation + ceiling enforcement | 4 |
| Audit log writer + schema + rotation | 4 |
| Severity classifier (keyword + structural) | 4 |
| Playbook reference validator + schema | 2 |
| Retry policy with exponential backoff | 2 |
| Model pricing config + freshness test + tokenizer-variant handling | 1 |
| Refactor Invoke-ComplianceDiff | 2 |
| Refactor Invoke-AutoFix | 2 |
| 10 playbooks (drafting + mapping + validation) | 5 |
| Unit tests for AI client (mocked) | 3 |
| Severity classifier tests with labeled fixtures | 2 |
| Prompt caching integration | 1 |
| `docs/AI-INTEGRATION.md` | 1 |
| **Base total** | **36** |

Risk contingency: 25% buffer (9 hours). Buffered total 44 hours (35 base + 9 buffer; rounded). Highest risk drivers: severity classifier accuracy (Risk-4), playbook drafting effort (Risk-8).

## 6.5.10 Open Questions

| ID | Question | Recommendation |
|----|----------|----------------|
| 6.5-OQ-1 | Support multiple AI providers (OpenAI, Ollama) in 6.5? | **No, Anthropic-only.** Abstraction is provider-agnostic; adding later is mechanical. |
| 6.5-OQ-2 | Include technician IP/hostname in audit log? | **No, unless required.** Minimum-PII default. |
| 6.5-OQ-3 | Cryptographically sign playbooks? | **No, in 6.5.** Phase 7 candidate. |
| 6.5-OQ-4 | Tunable cost-variance threshold per call site? | **Yes, Phase 7.** 6.5 ships with 20% hardcoded. |

## 6.5.11 Traceability Mini-Matrix

| Requirement | Deliverable(s) | Success Criterion |
|-------------|----------------|-------------------|
| 6.5-R1 | D1, D12 | SC-1 |
| 6.5-R2 | D1 | SC-9 |
| 6.5-R3 | D1, D11 | SC-2 |
| 6.5-R4 | D1, D11 | SC-2 |
| 6.5-R5 | D1 | (verified in 6.3) |
| 6.5-R6 | D1, D2 | SC-3, SC-4 |
| 6.5-R7 | D1, D3, D10 | SC-5 |
| 6.5-R8 | D1, D5, D6 | SC-7 |
| 6.5-R9 | D1 | (covered in unit tests) |
| 6.5-R10 | D7, D8 | SC-8 |
| 6.5-R11 | D1, D4 | (unit tests) |
| 6.5-R12 | D13 | SC-6 |
| 6.5-R13 | D4 | (validated by override test) |
| 6.5-R14 | D1 | (rotation test) |
| 6.5-R15 | D1 | (cost reduction test) |

---

```{=openxml}
<w:p><w:r><w:br w:type="page"/></w:r></w:p>
```

# Chapter 6.2 — Multi-Framework Cross-Reference Activation

*Execution position: 4th of 6 · Risk-buffered effort: 62 hours · Risk level: Medium-High*

## 6.2.1 Goal

Extend compliance reporting beyond ANSSI's Guide d'hygiene informatique [ANSSI-Hyg] to include NIS2 Directive Article 21 [NIS2-Dir] with concrete technical detail from Implementing Regulation (EU) 2024/2690 [NIS2-IR], ISO/IEC 27001:2022 Annex A [ISO27001-2022], and RGS v2.0 [RGS-v2]. Build a cross-reference engine that maps individual FieldOps Pro technical findings to the controls of each framework with documented confidence ratings, so that a single machine scan produces a multi-framework compliance posture. Position RGS coverage explicitly as a French Public Sector Edition differentiator.

## 6.2.2 Context

The ANSSI diagnostic delivered through v0.5.2 is high-quality but single-framework. In commercial practice, the same technical control maps simultaneously to multiple compliance frameworks. For example, BitLocker enabled on the system drive satisfies:

- **ANSSI** — Regle R10 *Chiffrement des supports* [ANSSI-Hyg]
- **NIS2** — Article 21(2)(h) *cryptography and encryption* [NIS2-Dir]
- **ISO/IEC 27001:2022** — A.8.24 *Use of cryptography* [ISO27001-2022]
- **RGS v2.0** — Annexe B cryptographic mechanisms [RGS-v2]

Producing four mapped reports from one scan is not four times the work — it is one scan, one finding, four cross-references. The cross-reference table is the artifact that multiplies value.

The commercial significance is substantial. ANSSI alone restricts to French public sector and ANSSI-aware private enterprises. NIS2 expands to all EU-member-state essential and important entities. ISO 27001 expands further to globally-certified enterprises. RGS strengthens the French public-sector position.

The technical significance: the cross-reference engine, once built, applies to every future framework. Adding HDS or SecNumCloud or NIST CSF in Phase 7 becomes a data-only change.

## 6.2.3 Requirements

| ID | Requirement |
|---|---|
| 6.2-R1 | **Framework data files.** Each framework described in structured JSON under `CONFIG/frameworks/` conforming to `schemas/framework-data.json`. |
| 6.2-R2 | **Cross-reference mapping table.** Single canonical `CONFIG/frameworks/cross-references.json` with confidence ratings. |
| 6.2-R3 | **Framework activation per scan.** Technician specifies in-scope frameworks; default = all with data files. |
| 6.2-R4 | **Per-framework report sections.** HTML report contains one section per activated framework. |
| 6.2-R5 | **Bilingual coverage.** Every framework's control text in `fr.json` and `en.json` via Stream 6.1 infrastructure. |
| 6.2-R6 | **Source-of-truth provenance.** Each data file declares official source URL, version, retrieval date, permanent ID. |
| 6.2-R7 | **Framework-specific scoring.** ANSSI binary, NIS2 risk-based, ISO 27001 applicability-based, RGS maturity-scale. |
| 6.2-R8 | **Framework version pinning.** Specific version rendered in report. |
| 6.2-R9 | **Confidence-rated cross-references.** Every entry carries `high` / `medium` / `low` confidence rating. |
| 6.2-R10 | **Coverage-gap honesty.** Controls without FieldOps mapping listed explicitly with reason. |
| 6.2-R11 | **RGS scope honesty.** RGS section explicitly states public-administration scope. |
| 6.2-R12 | **Disclaimer presence.** Every multi-framework report carries explicit disclaimer: technical posture, not compliance certification. |
| 6.2-R13 | **NIS2 dual-citation.** Both Article 21(2) [NIS2-Dir] and IR 2024/2690 [NIS2-IR] cited where applicable. |
| 6.2-R14 | **v0.5.2 ANSSI single-framework preservation.** Existing customers continue to work without change. |
| 6.2-R15 | **Audit test: framework coverage.** Reports statistics; fails if any framework drops below 20% coverage floor. |

## 6.2.4 Design

### 6.2.4.1 Framework Data File Schema

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "$id": "https://github.com/msdorley/fieldops-pro/schemas/framework-data.json",
  "title": "FieldOps Pro Framework Data File",
  "type": "object",
  "required": ["framework", "controls"],
  "properties": {
    "framework": {
      "type": "object",
      "required": ["id", "displayName", "version", "scoringModel", "language"],
      "properties": {
        "id":              { "type": "string", "pattern": "^[a-z][a-z0-9_]+$" },
        "displayName":     { "type": "string" },
        "version":         { "type": "string" },
        "publicationDate": { "type": "string", "format": "date" },
        "officialUrl":     { "type": "string", "format": "uri" },
        "permanentId":     { "type": "string" },
        "retrievedAt":     { "type": "string", "format": "date" },
        "scoringModel":    { "type": "string", "enum": ["binary", "risk-based", "applicability-based", "maturity-scale"] },
        "language":        { "type": "string" },
        "scopeNotes":      { "type": "string" }
      }
    },
    "controls": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["id", "titleKey"],
        "properties": {
          "id":              { "type": "string" },
          "shortName":       { "type": "string" },
          "titleKey":        { "type": "string" },
          "descriptionKey":  { "type": "string" },
          "severityDefault": { "type": "string", "enum": ["low", "medium", "high", "critical"] },
          "category":        { "type": "string" },
          "sourceCitation":  { "type": "string" }
        }
      }
    }
  }
}
```

### 6.2.4.2 Framework Data File Inventory

```
CONFIG/frameworks/
  anssi.json           ANSSI Guide - 42 measures, 10 modules
  nis2.json            NIS2 Directive Art. 21(2) + IR (EU) 2024/2690
  iso27001.json        ISO/IEC 27001:2022 Annex A - 93 controls
  rgs.json             RGS v2.0 security functions and annexes
  cross-references.json   The mapping table
```

**ANSSI** (`anssi.json`): Edition 2017, 42 mesures, 10 modules; binary scoring; French.

**NIS2** (`nis2.json`): Directive (UE) 2022/2555 + Reglement d'execution (UE) 2024/2690; risk-based scoring; French. Article 21(2) measures (a) through (j); plus IR Annex sections for relevant entity types (cloud, DNS, MSP, MSSP, marketplaces, search engines, social platforms, trust services).

**ISO 27001** (`iso27001.json`): ISO/IEC 27001:2022 3rd edition October 2022; 93 controls in 4 themes (Organizational A.5, People A.6, Physical A.7, Technological A.8); applicability-based; English (AFNOR NF EN ISO/IEC 27001 French translation referenced).

**RGS** (`rgs.json`): Version 2.0, arrete du Premier ministre du 13 juin 2014; maturity-scale (RGS*, RGS**, RGS***); French. Scope: autorites administratives au sens de l'ordonnance n° 2005-1516.

### 6.2.4.3 Cross-Reference Mapping Table (Sample Entries)

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "$id": "https://github.com/msdorley/fieldops-pro/schemas/cross-references.json",
  "version": "1.0",
  "lastUpdated": "2026-05-25",
  "confidenceLevels": ["high", "medium", "low"],
  "mappings": [
    {
      "findingId": "BitLockerEnabledSystemDrive",
      "anssi":    { "controls": ["R10"], "confidence": "high" },
      "nis2":     { "controls": ["Art21-2-h"], "confidence": "high" },
      "iso27001": { "controls": ["A.8.24"], "confidence": "high" },
      "rgs":      { "controls": ["AR-Crypto-B1-001"], "confidence": "medium" }
    },
    {
      "findingId": "DefenderRealtimeProtectionEnabled",
      "anssi":    { "controls": ["R8"], "confidence": "high" },
      "nis2":     { "controls": ["Art21-2-c"], "confidence": "medium" },
      "iso27001": { "controls": ["A.8.7"], "confidence": "high" },
      "rgs":      { "controls": [], "confidence": null }
    },
    {
      "findingId": "WindowsFirewallAllProfilesEnabled",
      "anssi":    { "controls": ["R23"], "confidence": "high" },
      "nis2":     { "controls": ["Art21-2-e"], "confidence": "medium" },
      "iso27001": { "controls": ["A.8.21", "A.8.22"], "confidence": "high" },
      "rgs":      { "controls": [], "confidence": null }
    },
    {
      "findingId": "WindowsUpdateCurrentWithin30Days",
      "anssi":    { "controls": ["R34"], "confidence": "high" },
      "nis2":     { "controls": ["Art21-2-e", "IR-2024-2690-Ann-2.6"], "confidence": "high" },
      "iso27001": { "controls": ["A.8.8"], "confidence": "high" },
      "rgs":      { "controls": [], "confidence": null }
    }
  ]
}
```

**Coverage targets at end of Phase 6.2:** >= 40 findings mapped; per-framework density >= 35/30/25/10 for ANSSI/ISO27001/NIS2/RGS; confidence distribution >= 60% high, <= 15% low.

### 6.2.4.4 Cross-Reference Engine

`Invoke-CrossReference.ps1` — pure function. Output per framework:

```json
{
  "framework": "nis2",
  "controls": [
    {
      "controlId": "Art21-2-h",
      "status": "satisfied",
      "supportingFindings": ["BitLockerEnabledSystemDrive"],
      "lowestConfidence": "high",
      "score": 1.0
    },
    {
      "controlId": "Art21-2-d",
      "status": "not_assessed",
      "supportingFindings": [],
      "score": null,
      "notes": "Supply chain: requires organizational process review beyond endpoint scope"
    }
  ],
  "overallPosture": {
    "assessedControls": 7,
    "satisfiedControls": 5,
    "notAssessedControls": 4,
    "coveragePercent": 63.6,
    "confidenceWeightedScore": 0.74
  }
}
```

### 6.2.4.5 Report Renderer

`templates/multi-framework-diagnostic.html` extends ANSSI template. Each activated framework gets a section with shared visual language. Existing `anssi-diagnostic.html` preserved as ANSSI-only default for backward compatibility.

Structure: Cover Page; Per-Framework Section (header, scope advisory if RGS, posture summary, coverage gaps, controls table, findings cross-reference); Synthesis Section (cross-framework summary, prioritized remediations, AI executive summary); Appendix (raw scan, audit trail, framework versions).

### 6.2.4.6 Activation Configuration

```json
{
  "activeFrameworks": ["anssi", "nis2", "iso27001"],
  "publicSectorEngagement": false
}
```

When `publicSectorEngagement: true`, RGS auto-added. Per-scan override:

```powershell
.\Invoke-ANSSIDiagnostic.ps1 -Frameworks anssi,nis2,iso27001,rgs
```

### 6.2.4.7 RGS Scope as Positioning

RGS v2.0 applies specifically to autorites administratives. The commercial response: treat as Public Sector Edition differentiator, not limitation.

- For French public-sector IT functions and IT services firms with public-administration clients: RGS coverage materially valuable
- For general commercial customers: RGS available with honest scope advisory, excluded from default activation
- Positioning: "FieldOps Pro is the only USB toolkit that maps to French public-sector RGS framework"

The constraint becomes the moat. Honest scope treatment is both ethical and commercially advantageous.

**Rendered RGS scope advisory** (French): *La presente analyse de posture RGS s'applique aux engagements impliquant la fourniture de services a des autorites administratives au sens de l'ordonnance n° 2005-1516 du 8 decembre 2005. Pour les entites privees hors ce cadre, le RGS n'a pas de portee obligatoire; cette section est fournie a titre informatif et pour preparation aux engagements publics potentiels.*

### 6.2.4.8 NIS2 Dual-Citation Methodology

NIS2 Article 21(2) [NIS2-Dir] establishes 10 measures applicable to all in-scope entities. Implementing Regulation (EU) 2024/2690 [NIS2-IR] specifies concrete technical requirements for 10 specific entity types (DNS providers, TLD registries, cloud, datacenters, CDN, MSPs, MSSPs, marketplaces, search engines, social platforms, trust services).

Most FieldOps Pro Profile B customers (MSPs) fall under "managed service providers" per the IR. Dual-citation:

- **Directive Article 21(2)** for breadth
- **Implementing Regulation 2024/2690 Annex** for concrete entity-type-specific requirements

```json
{
  "findingId": "WindowsUpdateCurrentWithin30Days",
  "nis2": {
    "controls": ["Art21-2-e", "IR-2024-2690-Ann-2.6"],
    "confidence": "high",
    "notes": "Article 21(2)(e) addresses vulnerability handling broadly; IR Annex 2.6 specifies for relevant entities"
  }
}
```

This methodology produces the most concretely-mapped NIS2 coverage available in any compliance toolkit.

### 6.2.4.9 Coverage Gap Reporting

> **Coverage gaps for NIS2 Article 21(2):**
>
> - Art21-2-d (Supply chain security): requires organizational process review beyond endpoint scope
> - Art21-2-f (Effectiveness policies): requires review of organizational policy documents
> - Art21-2-i (HR security): partial; technical aspects assessed, HR-policy aspects out of scope
>
> *FieldOps Pro covers technical endpoint controls. Organizational process controls require complementary assessment.*

### 6.2.4.10 Disclaimer

> *FieldOps Pro reports technical posture against framework controls based on automated endpoint telemetry. This is not a compliance certification. Conformity declarations for NIS2, ISO/IEC 27001, RGS, or any other regulatory regime require qualified human assessment and, where applicable, accredited audit. FieldOps Pro is an aid to compliance work, not a substitute for it.*

## 6.2.5 Deliverables

| ID | Artifact | Path |
|----|----------|------|
| 6.2-D1 | Framework data file JSON Schema | `schemas/framework-data.json` |
| 6.2-D2 | Cross-reference mapping JSON Schema | `schemas/cross-references.json` |
| 6.2-D3 | ANSSI framework data file (refactored) | `CONFIG/frameworks/anssi.json` |
| 6.2-D4 | NIS2 framework data file | `CONFIG/frameworks/nis2.json` |
| 6.2-D5 | ISO 27001 framework data file | `CONFIG/frameworks/iso27001.json` |
| 6.2-D6 | RGS framework data file | `CONFIG/frameworks/rgs.json` |
| 6.2-D7 | Cross-reference mapping table | `CONFIG/frameworks/cross-references.json` |
| 6.2-D8 | Cross-reference engine | `SCRIPTS/Compliance/Invoke-CrossReference.ps1` |
| 6.2-D9 | Multi-framework report builder | `SCRIPTS/Compliance/Build-MultiFrameworkData.ps1` |
| 6.2-D10 | Multi-framework HTML template | `templates/multi-framework-diagnostic.html` |
| 6.2-D11 | Locale bundle additions (~150 keys) | `CONFIG/lang/fr.json`, `en.json` |
| 6.2-D12 | Cross-reference engine unit tests | `tests/unit/Compliance/Invoke-CrossReference.Tests.ps1` |
| 6.2-D13 | Property tests for cross-reference invariants | `tests/evaluators/CrossReferenceProperties.ps1` |
| 6.2-D14 | Framework coverage audit test | `tests/audit/Audit-FrameworkCoverage.Tests.ps1` |
| 6.2-D15 | Technician profile schema extension | `CONFIG/technician.schema.json` |
| 6.2-D16 | Multi-framework user guide | `docs/MULTI-FRAMEWORK.md` |
| 6.2-D17 | Public Sector Edition positioning brief | `docs/internal/public-sector-positioning.md` |

## 6.2.6 Risks

| ID | Risk | Severity | Mitigation |
|----|------|----------|------------|
| 6.2-Risk-1 | Framework interpretation requires legal expertise | High | Confidence rating field; primary-authority citations; recommend qualified practitioner for audit-grade engagements |
| 6.2-Risk-2 | Framework versions drift faster than FieldOps updates | Medium | Explicit version pinning; Phase 7 tracking process |
| 6.2-Risk-3 | Cross-reference table unwieldy at scale | Low | Flat JSON; revisit at 200+ findings |
| 6.2-Risk-4 | Translation quality below professional standard | Medium | Use official translations (AFNOR, EUR-Lex); Phase 6.4 reviewer pass |
| 6.2-Risk-5 | "Compliant" vs "posture" misreading by customers | High | Explicit disclaimer on every report; wording reviewed |
| 6.2-Risk-6 | RGS positioning misread as "public sector only" | Medium | Public Sector Edition framing is opt-in; dual-audience README |
| 6.2-Risk-7 | NIS2 dual-citation confuses operators | Medium | Decision tree in MULTI-FRAMEWORK.md |
| 6.2-Risk-8 | Effort underestimated (research-heavy) | Medium-High | 20% risk buffer; deferrable: RGS depth |

## 6.2.7 Dependencies

**Upstream:** Stream 6.1 (locale architecture), 6.6 (test harness).
**Downstream:** Stream 6.3 (fleet drift aggregates multi-framework posture), 6.4 (multi-framework is headline commercial capability).

## 6.2.8 Success Criteria

| ID | Criterion | Verification |
|----|-----------|--------------|
| 6.2-SC-1 | Four framework data files with version pinning + source citation | File audit |
| 6.2-SC-2 | All framework data files validate against schema | Schema validation |
| 6.2-SC-3 | Cross-reference table >= 40 findings with confidence ratings | Content audit |
| 6.2-SC-4 | Cross-reference engine deterministic | Property tests >= 100 iterations |
| 6.2-SC-5 | Multi-framework HTML renders correctly in FR and EN | Render test + locale audit |
| 6.2-SC-6 | Coverage gap section non-empty for each framework | Report inspection |
| 6.2-SC-7 | Disclaimer present on every report | Template audit |
| 6.2-SC-8 | v0.5.2 ANSSI single-mode reports byte-identical | Regression test |
| 6.2-SC-9 | RGS scope advisory renders in RGS section only | Template + bundle audit |
| 6.2-SC-10 | NIS2 IR entries visually grouped under parent Directive article | Template inspection |
| 6.2-SC-11 | `Audit-FrameworkCoverage` passes (no framework < 20% on default fixture) | Audit test |
| 6.2-SC-12 | `docs/MULTI-FRAMEWORK.md` published | Document review |

## 6.2.9 Estimate Justification

| Sub-task | Hours |
|----------|------:|
| ANSSI data file refactor | 3 |
| NIS2 data file (Directive + IR research + mapping) | 10 |
| ISO 27001 data file (93 controls + AFNOR refs) | 8 |
| RGS data file (research + Public Sector framing) | 5 |
| Cross-reference mapping table (40+ findings x 4 frameworks) | 8 |
| Cross-reference engine + unit + property tests | 5 |
| Build-MultiFrameworkData + tests | 3 |
| Multi-framework HTML template | 5 |
| Locale bundle additions (~150 keys) | 4 |
| Framework coverage audit test | 1 |
| `docs/MULTI-FRAMEWORK.md` + decision tree | 3 |
| **Base total** | **55** |

Note: base sum 55 hours; chapter top-line 52 reflects 3-hour estimated reuse from Stream 6.1 locale tooling. Risk buffer 20% (12 hours). Buffered 62 hours.

## 6.2.10 Open Questions

| ID | Question | Recommendation |
|----|----------|----------------|
| 6.2-OQ-1 | Community-editable framework data, or curated-only? | **Curated for 6.2.** Community PRs welcomed but reviewed. |
| 6.2-OQ-2 | Include NIST CSF or HDS in 6.2? | **No.** Four frameworks is defensible scope; NIST CSF Phase 7; HDS Phase 8. |
| 6.2-OQ-3 | Split cross-reference table per framework? | **Keep flat for 6.2.** Reconsider at 200+ findings. |
| 6.2-OQ-4 | Exclude low-confidence mappings? | **Include with indicator.** Honesty over cleanliness. |
| 6.2-OQ-5 | External reviewer for disclaimer wording? | **Yes if available.** Fold into Stream 6.4. |

## 6.2.11 Traceability Mini-Matrix

| Requirement | Deliverable(s) | Success Criterion |
|-------------|----------------|-------------------|
| 6.2-R1 | D1, D3-D6 | SC-1, SC-2 |
| 6.2-R2 | D2, D7 | SC-3 |
| 6.2-R3 | D15 | (unit tests) |
| 6.2-R4 | D9, D10 | SC-5, SC-6 |
| 6.2-R5 | D11 | SC-5 |
| 6.2-R6 | D3-D6 | SC-1 |
| 6.2-R7 | D8 | SC-4 |
| 6.2-R8 | D3-D6 | SC-1 |
| 6.2-R9 | D7 | SC-3 |
| 6.2-R10 | D9, D10 | SC-6 |
| 6.2-R11 | D6, D10, D11 | SC-9 |
| 6.2-R12 | D10, D11 | SC-7 |
| 6.2-R13 | D4, D7, D10 | SC-10 |
| 6.2-R14 | (preserved by additive design) | SC-8 |
| 6.2-R15 | D14 | SC-11 |

---

```{=openxml}
<w:p><w:r><w:br w:type="page"/></w:r></w:p>
```

# Chapter 6.3 — Fleet Drift Dashboard

*Execution position: 5th of 6 · Risk-buffered effort: 70 hours · Risk level: High*

## 6.3.1 Goal

Build the fleet-level capability that allows an IT services firm or internal IT function managing many endpoints to see, in one artifact, how the fleet's compliance posture has changed over time and which machines are drifting from baseline. The dashboard combines `Invoke-FleetReport`'s aggregation from v0.5.2 with `Invoke-ComplianceDiff`'s AI-narrated change analysis to produce a single self-contained HTML deliverable that no incumbent USB toolkit offers.

## 6.3.2 Context

FieldOps Pro v0.5.2 produces excellent per-machine reports but has no fleet dimension. A technician scanning 50 machines produces 50 reports; the operator has to read 50 documents to understand fleet state. This is the inflection point where FieldOps Pro stops being a per-machine technician tool and becomes a fleet management instrument — at which Profile B (MSP) willingness to pay rises by approximately an order of magnitude.

Two existing components anchor the work: `Invoke-FleetReport.ps1` v2.1 (aggregates per-machine scans into fleet summary; no time-series dimension) and `Invoke-ComplianceDiff.ps1` v1.0 (compares two scan results, narrates delta; per-machine only). Phase 6.3 extends both: aggregation over time, fleet-level drift narration. The work depends critically on Stream 6.5's hardened AI client and Stream 6.2's multi-framework data.

Competitive significance: none of the three incumbents have any notion of "fleet over time." Their architectures are tool-aggregator first; adding this capability would require fundamental redesign. The defensible position is durable.

## 6.3.3 Requirements

| ID | Requirement |
|---|---|
| 6.3-R1 | **Scan history store.** Per-machine scans persist in structured store on USB or designated share, queryable by machine identity + time range. JSON files indexed by machine ID hash and scan timestamp. |
| 6.3-R2 | **Fleet aggregation across time.** Aggregate metrics over N machines and time window: compliance score over time, machines drifting, controls regressing, new findings, silent/decommissioned machines. |
| 6.3-R3 | **Per-machine drift detection.** Findings added, resolved, regressed; status changes per control per framework. |
| 6.3-R4 | **AI-narrated executive summary.** Claude (Narration tier - Sonnet 4.6) generates 200-400 word summary suitable for stakeholder email. Per-call ceiling default USD 1.00. |
| 6.3-R5 | **Per-framework drift view.** Drift presented per framework using 6.2 data. |
| 6.3-R6 | **Self-contained HTML.** No external CDN dependencies; viewable offline; printable to PDF. |
| 6.3-R7 | **Privacy-preserving fleet identifiers.** Machines referenced by stable hashed identifiers in exportable artifacts. |
| 6.3-R8 | **Cost-bounded AI usage.** Per-dashboard USD 1.00; per-day USD 25.00; per-month USD 500.00. Configurable. |
| 6.3-R9 | **Manual override of AI narration.** Operator can edit AI sections before finalization; both versions retained. |
| 6.3-R10 | **Graceful degradation for small fleets.** Single-machine "fleet" or insufficient history produces meaningful dashboard, not errors. |
| 6.3-R11 | **Inline SVG charts.** No JavaScript chart libraries. Aligns with forty-year durability lens. |
| 6.3-R12 | **No machine identifiers in AI prompts.** Aggregated metrics only. Enforced by audit test. |
| 6.3-R13 | **Anonymized export mode.** `-Anonymize` switch replaces identifiers with `Machine-A`, `Machine-B`, etc. |
| 6.3-R14 | **Machine status tracking.** Profile carries `active` / `paused` / `decommissioned`. |
| 6.3-R15 | **Scan history retention.** 12 months online; archives queryable. Configurable. |

## 6.3.4 Design

### 6.3.4.1 Scan History Store Layout

```
FLEET-DATA/
  fleet-manifest.json
  fleet-secret.json                              fleet salt (gitignored)
  machines/
    {machineIdHash}/
      profile.json
      scans/
        2026-06-01T08-15-00Z.json
        2026-06-08T08-12-00Z.json
      drift/
        2026-06-15T08-35-00Z.json
  archive/
    2025/machines-2025-q4.tar.gz
  dashboards/
    2026-06-15T09-00-00Z/
      fleet-drift.html
      fleet-drift.json
      ai-summary-original.txt
      ai-summary-final.txt
      generation-metadata.json
```

`machineIdHash` = SHA-256 of stable identifier salted:

```
machineIdHash = SHA-256(fleetSalt || ":" || hostname || ":" || serialNumber || ":" || azureAdTenant)
```

`fleetSalt` generated at fleet init, stored in `fleet-secret.json` (excluded from git/exports). Salt prevents cross-fleet correlation if dashboard leaks.

### 6.3.4.2 Data Flow Pipeline

```
Per-machine scan
    |
    v
Update-ScanHistory writes scan to FLEET-DATA/machines/<id>/scans/
    |
    v
Compare-MachineScans computes per-machine drift -> FLEET-DATA/machines/<id>/drift/
    |
    v
Operator invokes Invoke-FleetDrift
    |
    v
Load fleet manifest -> resolve scope -> load scan+drift history per machine
    |
    v
Aggregate to fleet level (compliance score, regressions, silent machines, new findings)
    |
    v
Build aggregate metrics package (NO machine identifiers per R12)
    |
    v
FieldOps-AIClient (Narration tier, Sonnet 4.6, MaxCost 1.00 USD)
    |
    v
ai-summary-original.txt
    |
    v
Operator override? YES -> ai-summary-final.txt
                  NO  -> use AI text as-is
    |
    v
Render fleet-drift.html with inline SVG charts
    |
    v
Anonymize switch? YES -> strip identifiers, render Machine-A/B/C
                  NO  -> render with hostnames (internal-use only)
    |
    v
FLEET-DATA/dashboards/<timestamp>/
```

### 6.3.4.3 Aggregation Logic

```powershell
function Invoke-FleetDrift {
    param(
        [Parameter(Mandatory)] [string]   $FleetDataPath,
        [datetime] $WindowStart = (Get-Date).AddDays(-30),
        [datetime] $WindowEnd   = (Get-Date),
        [string[]] $MachineFilter,
        [string[]] $Frameworks  = @('anssi','nis2','iso27001'),
        [switch]   $Anonymize,
        [decimal]  $AIBudgetUSD = 1.00
    )

    $manifest = Get-Content "$FleetDataPath/fleet-manifest.json" | ConvertFrom-Json
    $machines = Resolve-MachineScope -Manifest $manifest -Filter $MachineFilter

    foreach ($m in $machines) {
        $perMachineHistory[$m.machineIdHash] = Get-MachineScansInWindow `
            -MachineHash $m.machineIdHash -Start $WindowStart -End $WindowEnd
    }

    $aggregated = New-FleetAggregation -PerMachineHistory $perMachineHistory `
        -Frameworks $Frameworks -WindowStart $WindowStart -WindowEnd $WindowEnd

    $silentMachines  = Get-SilentMachines -Manifest $manifest -Threshold 14
    $regressingCtrls = Get-RegressingControls -PerMachineHistory $perMachineHistory
    $timeSeriesData  = Get-TimeSeriesScore -PerMachineHistory $perMachineHistory

    $aiInput = ConvertTo-PrivacyPreservingInput -Aggregated $aggregated `
        -SilentCount $silentMachines.Count -RegressingControls $regressingCtrls

    Assert-NoMachineIdentifiersInInput -Input $aiInput  # privacy enforcement

    $narration = Invoke-FieldOpsAI `
        -Prompt (Format-FleetDriftPrompt -Data $aiInput) `
        -SystemPrompt (Get-Content "$ScriptRoot/AI/prompts/FleetDriftSummary.md" -Raw) `
        -CallingContext 'Invoke-FleetDrift/ExecutiveSummary' `
        -TaskTier 'Narration' `
        -MaxCostUSD $AIBudgetUSD -OutputMultiplier 2.5

    $dashboardPath = New-DashboardArtifact -Aggregated $aggregated `
        -PerMachineHistory $perMachineHistory -TimeSeriesData $timeSeriesData `
        -AINarration $narration.Response -Anonymize:$Anonymize

    return [PSCustomObject]@{
        DashboardPath = $dashboardPath
        AICost = $narration.CostUSD
        MachineCount = $machines.Count
    }
}
```

### 6.3.4.4 Per-Machine Drift Detection

`Compare-MachineScans.ps1` — pure function. Output shape:

```json
{
  "schemaVersion": "1.0",
  "machineIdHash": "9f2acce1...",
  "prior":   "2026-06-08T08-12-00Z",
  "current": "2026-06-15T08-30-00Z",
  "elapsedDays": 7.01,
  "findings": {
    "added":     [{ "findingId": "DefenderRealtimeDisabled", "severity": "high" }],
    "resolved":  [{ "findingId": "WindowsUpdatesStale" }],
    "regressed": [{ "findingId": "FirewallProfilePublic", "from": "satisfied", "to": "not_satisfied", "severity": "high" }]
  },
  "frameworkPosture": {
    "anssi":    { "prior": 0.85, "current": 0.83, "delta": -0.02 },
    "nis2":     { "prior": 0.78, "current": 0.78, "delta":  0.00 },
    "iso27001": { "prior": 0.81, "current": 0.79, "delta": -0.02 }
  },
  "overallSeverityIncrease": "low"
}
```

Property-tested in `tests/evaluators/FleetDriftProperties.ps1`.

### 6.3.4.5 Inline SVG Chart Library

Three chart types as parameterized PowerShell functions emitting inline SVG:

**Line chart (`New-LineSvg`)** — compliance score over time; x-axis time, y-axis 0.0-1.0, one line per framework; grid lines at 0.2; rotated date labels; empty-state: "Insufficient data" overlay per series.

**Bar chart (`New-BarSvg`)** — machines by state; vertical bars per category (Compliant, Drift detected, Regressing, Silent, Decommissioned); empty-state: "No machines in fleet" text.

**Heatmap (`New-HeatmapSvg`)** — control x machine status matrix; y-axis control IDs, x-axis machine labels (anonymized if `-Anonymize`); cells colored per status (green/yellow/red/grey); SVG `<title>` tooltips.

**Palette (`templates/svg-palette.json`):**

```json
{
  "frameworkColors": {
    "anssi":    "#0050a0",
    "nis2":     "#003399",
    "iso27001": "#1f6e8c",
    "rgs":      "#5e2750"
  },
  "statusColors": {
    "satisfied":      "#2d8659",
    "needs_review":   "#d9a441",
    "not_satisfied":  "#b03a2e",
    "not_assessed":   "#7d7d7d"
  },
  "machineStateColors": {
    "compliant":         "#2d8659",
    "drift_detected":    "#d9a441",
    "regressing":        "#b03a2e",
    "silent":            "#7d7d7d",
    "decommissioned":    "#5d5d5d"
  }
}
```

Colors follow WCAG 2.1 AA contrast (>= 4.5:1 against white). Operator-overridable for brand requirements.

### 6.3.4.6 AI-Narrated Executive Summary

System prompt (`SCRIPTS/AI/prompts/FleetDriftSummary.md`):

```markdown
# Fleet Drift Executive Summary System Prompt

You are summarizing a compliance fleet drift report for a non-technical
stakeholder (department head, CISO at MSP client, internal IT director).

## Constraints
- Write 200 to 400 words in requested language (default French).
- Lead with most important finding. Bury secondary details.
- Use plain language. Avoid jargon.
- Cite specific numbers from input. Do not invent numbers or trends.
- Do not name machines, hosts, serials, or technicians. Input contains
  only aggregate counts.
- If posture is improving, say so plainly. Do not manufacture concern.
- End with one actionable recommendation as question or invitation.

## Severity Indicator
End with: Severity: INFORMATIONAL | ADVISORY | ACTION_REQUIRED | CRITICAL
- CRITICAL if >= 20% of machines regressed on high-severity control
- ACTION_REQUIRED if >= 10% of machines with new high-severity finding
- ADVISORY if non-trivial regressions below ACTION_REQUIRED thresholds
- INFORMATIONAL if stable or improving

## Tone
Calm, factual, useful. CISO reads 20 of these per week; respect their time.
```

User prompt (per call) contains only aggregated metrics:

```
Fleet drift summary for the period 2026-06-01 to 2026-06-15.

Fleet size: 47 active machines (3 paused, 1 decommissioned, ignored).
Scans in window: 89 scans.

Compliance score trend per framework:
- ANSSI: 0.84 -> 0.82 (-0.02)
- NIS2:  0.78 -> 0.81 (+0.03)
- ISO 27001: 0.79 -> 0.77 (-0.02)

Regressing controls (>= 3 machines worsened):
- ANSSI R8 (Defender real-time): 5 machines
- ANSSI R34 (Windows Update): 4 machines
- ISO 27001 A.8.7 (Anti-malware): 5 machines (overlap with R8)

New findings appearing first time in window:
- DefenderRealtimeDisabled: 5 machines
- BitLockerSuspended: 2 machines

Silent machines (no scan in 14+ days): 2 machines.
Target language: French.
```

Zero hostnames, serials, or technician identifiers. Asserted by audit test.

### 6.3.4.7 Privacy Enforcement Layer

`Assert-NoMachineIdentifiersInInput` scans for known identifier patterns before AI input leaves local environment:

```powershell
function Assert-NoMachineIdentifiersInInput {
    param([Parameter(Mandatory)] [PSCustomObject] $Input)
    $serialized = $Input | ConvertTo-Json -Depth 50
    $patterns = @(
        '\b[A-Z0-9]{6,}\b'                          # serial patterns
        '\b[A-Z]{4,}\d{0,}\b'                       # hostname patterns
        '\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b'    # IPv4
        '\b[a-f0-9]{8,}\b'                          # hex sequences
        '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}'  # email
    )
    foreach ($pattern in $patterns) {
        if ($serialized -match $pattern) {
            throw "Privacy violation: pattern '$pattern' matched. Match: $($Matches[0])"
        }
    }
}
```

Conservative — throws on any match. Legitimate matches (dates) are explicitly whitelisted in `Format-FleetDriftPrompt` using `[DATE:value]` markers the privacy check skips. Intentional friction: extending AI input requires explicit thought about privacy.

Test `tests/audit/Audit-NoMachineIdentifiersInAIPrompts.Tests.ps1` runs against fixture-generated prompts for synthetic 20-machine fleet with edge-case hostnames. Must pass.

### 6.3.4.8 Dashboard HTML Structure

```
Cover
  - Fleet/customer name (locale-routed)
  - Generation timestamp; window dates
  - Fleet size summary: N active, M paused, K decommissioned, L silent
  - Frameworks assessed
  - Disclaimer (inherited from 6.2-R12)

Executive Summary
  - AI-narrated text (original or operator-edited)
  - Severity indicator banner (color-coded)

Compliance Score Time Series
  - Line chart per framework

Fleet State Summary
  - Bar chart: machines by state
  - Table with link to per-machine breakdown

Regressing Controls
  - Table sorted by impact (count x severity descending)

New Findings This Window
  - Table; first-time-seen findings highlighted

Per-Machine Detail (collapsible)
  - Hash prefix or anonymized label; state; last scan; score per framework

Audit Reference
  - Pointer to AI audit log entry; cost; override indicator

Coverage Gaps
  - Inherits from 6.2-R10
```

### 6.3.4.9 Graceful Degradation

- **Single-machine "fleet"**: dashboard renders; time-series shows that machine; AI narration adjusts framing
- **Insufficient scan history**: "Baseline — no prior scan for comparison" rather than silent exclusion
- **No scans in window**: "No scans recorded; adjust window or run scans"; AI skipped (no cost)
- **AI unavailable**: section renders placeholder "AI narration unavailable; reason: <reason>"; charts/tables normal
- **Cost ceiling reached mid-generation**: "Narration deferred — daily ceiling reached. Re-run after midnight or increase ceiling"

### 6.3.4.10 Anonymized Export Mode

`-Anonymize` switch effects:
- Machine identifier hashes replaced with `Machine-A`, `Machine-B`, ... in first-appearance order
- Hostnames stripped from per-machine table; IPs stripped from metadata
- `generation-metadata.json` includes anonymization mapping for internal reference; excluded from anonymized export bundle by default
- AI summary unaffected (already contains no identifiers per R12)

Suitable for sharing with external stakeholders (e.g., MSP sharing fleet posture with non-IT customer executive).

## 6.3.5 Deliverables

| ID | Artifact | Path |
|----|----------|------|
| 6.3-D1 | Fleet drift orchestrator | `SCRIPTS/Fleet/Invoke-FleetDrift.ps1` |
| 6.3-D2 | Per-machine scan comparator | `SCRIPTS/Fleet/Compare-MachineScans.ps1` |
| 6.3-D3 | Scan history store + schema | `SCRIPTS/Fleet/Update-ScanHistory.ps1` + `schemas/fleet-scan-history.json` |
| 6.3-D4 | Inline SVG chart library | `SCRIPTS/Fleet/New-SvgChart.ps1` |
| 6.3-D5 | SVG color palette config | `templates/svg-palette.json` |
| 6.3-D6 | Fleet drift HTML template | `templates/fleet-drift-dashboard.html` |
| 6.3-D7 | AI narration system prompt | `SCRIPTS/AI/prompts/FleetDriftSummary.md` |
| 6.3-D8 | Machine ID hashing helper | `SCRIPTS/Fleet/Get-MachineIdHash.ps1` |
| 6.3-D9 | Privacy enforcement helper | `SCRIPTS/Fleet/Assert-NoMachineIdentifiersInInput.ps1` |
| 6.3-D10 | Anonymization filter | `SCRIPTS/Fleet/Invoke-FleetAnonymize.ps1` |
| 6.3-D11 | Refactored Invoke-FleetReport | `SCRIPTS/Reporting/Invoke-FleetReport.ps1` |
| 6.3-D12 | Per-machine scan comparator tests | `tests/unit/Fleet/Compare-MachineScans.Tests.ps1` |
| 6.3-D13 | Fleet aggregation tests | `tests/unit/Fleet/Invoke-FleetDrift.Tests.ps1` |
| 6.3-D14 | SVG chart unit tests | `tests/unit/Fleet/New-SvgChart.Tests.ps1` |
| 6.3-D15 | Property tests for drift invariants | `tests/evaluators/FleetDriftProperties.ps1` |
| 6.3-D16 | Privacy audit test | `tests/audit/Audit-NoMachineIdentifiersInAIPrompts.Tests.ps1` |
| 6.3-D17 | Sample fleet fixture (10 machines x 4 scans) | `tests/fixtures/fleet/` |
| 6.3-D18 | Fleet drift user guide | `docs/FLEET-DRIFT.md` |

## 6.3.6 Risks

| ID | Risk | Severity | Mitigation |
|----|------|----------|------------|
| 6.3-Risk-1 | Scan history grows large fast | Medium | Compact files; rotation; compression |
| 6.3-Risk-2 | AI narration inaccurate | High | Prompt constraints; audit log; override; severity classifier sanity check |
| 6.3-Risk-3 | SVG chart brittle on edge cases | Medium | Empty-state per type; property tests; manual visual regression |
| 6.3-Risk-4 | Privacy claim hard to verify | High | Audit test with edge-case fixtures; runtime assertion; defense-in-depth |
| 6.3-Risk-5 | Fleet aggregation arithmetic subtly wrong | Medium | Property tests; fixture verification |
| 6.3-Risk-6 | Chapter scope creep (most ambitious) | Medium-High | Success criteria bounded; out-of-scope items named |
| 6.3-Risk-7 | SVG cross-browser inconsistency | Medium | Visual regression across 4 viewers |
| 6.3-Risk-8 | Anonymization mapping leaked with anonymized dashboard | Medium | Mapping excluded from default export |
| 6.3-Risk-9 | Fleet salt loss eliminates correlation | Medium | Operator backup recommended; documented |

## 6.3.7 Dependencies

**Upstream:** 6.6 (tests, fixtures), 6.5 (hardened AI client), 6.2 (multi-framework data), 6.1 (locale routing).
**Downstream:** 6.4 (fleet drift is headline commercial demo capability; demo fleet requires pipeline operational).

## 6.3.8 Success Criteria

| ID | Criterion | Verification |
|----|-----------|--------------|
| 6.3-SC-1 | Dashboard generates successfully for fixture fleet of 10 machines x 4 scans | Fixture run |
| 6.3-SC-2 | Per-machine drift detection identifies all expected changes in fixture | Fixture comparison test |
| 6.3-SC-3 | Aggregation invariants verified by >= 3 property tests, >= 100 iterations each | Property test output |
| 6.3-SC-4 | Inline SVG renders correctly in Chrome, Edge, Firefox, mshtml | Cross-browser test |
| 6.3-SC-5 | AI summary generates within USD 1.00 ceiling on fixture | Cost log inspection |
| 6.3-SC-6 | Anonymized export mode produces dashboard with zero identifiers visible | Anonymization test |
| 6.3-SC-7 | `Audit-NoMachineIdentifiersInAIPrompts` passes | Audit test |
| 6.3-SC-8 | Single-machine "fleet" produces meaningful baseline dashboard | Edge-case test |
| 6.3-SC-9 | Empty-state rendering verified per chart type | Manual + automated |
| 6.3-SC-10 | Insufficient-history machine renders with "Baseline" framing | Edge-case test |
| 6.3-SC-11 | Cost-ceiling-reached renders with placeholder narration, no exception | Manual scenario |
| 6.3-SC-12 | API-unavailable renders with degraded narration, no exception | Manual scenario |
| 6.3-SC-13 | `docs/FLEET-DRIFT.md` published | Document review |

## 6.3.9 Estimate Justification

| Sub-task | Hours |
|----------|------:|
| Scan history store + writer + retention | 5 |
| Machine ID hashing + fleet salt management | 2 |
| Per-machine scan comparator + tests | 6 |
| Fleet aggregation logic + tests | 6 |
| Property tests for drift invariants | 3 |
| Inline SVG chart library (3 types) | 9 |
| Fleet drift HTML template | 7 |
| AI narration prompt + privacy-preserving input | 3 |
| Privacy enforcement helper + audit test | 4 |
| Anonymization filter + tests | 3 |
| Refactor Invoke-FleetReport | 2 |
| Sample fleet fixture (10 machines x 4 scans) | 5 |
| Cross-browser visual regression | 2 |
| Graceful degradation scenarios | 3 |
| `docs/FLEET-DRIFT.md` | 4 |
| **Base total** | **64** |

Note: base sum 64; chapter top-line 56 reflects ~8h estimated reuse from Stream 6.1 locale infrastructure and Stream 6.2 template patterns. Risk buffer 25% (14 hours). Buffered 70 hours.

Highest risk drivers: SVG chart library (9h), HTML template (7h), scan history store (5h) — each with meaningful surprise potential. Deferrable if overrun: cross-browser regression (Chrome-only acceptable for v0.6.0).

## 6.3.10 Open Questions

| ID | Question | Recommendation |
|----|----------|----------------|
| 6.3-OQ-1 | Per-customer separation for MSP managing multiple customer fleets? | **No, not in 6.3.** Single-tenant for v0.6.0; Phase 7 candidate. |
| 6.3-OQ-2 | Email/Slack/Teams notification when drift crosses threshold? | **No.** Notification is separate concern; dashboard is artifact, delivery is operator's choice. |
| 6.3-OQ-3 | Allow marking machines as `decommissioned`? | **Yes.** Implemented per R14. |
| 6.3-OQ-4 | Export to CSV/Parquet/Splunk/ELK? | **No, not in 6.3.** JSON Lines audit log is already usable export. |
| 6.3-OQ-5 | Use Claude prompt caching (90% input discount)? | **Yes.** Folded into Stream 6.5 (+1-2h, absorbed by 6.5 buffer). |

## 6.3.11 Traceability Mini-Matrix

| Requirement | Deliverable(s) | Success Criterion |
|-------------|----------------|-------------------|
| 6.3-R1 | D3, D8 | SC-1 |
| 6.3-R2 | D1, D2 | SC-2, SC-3 |
| 6.3-R3 | D2 | SC-2 |
| 6.3-R4 | D1, D7 | SC-5 |
| 6.3-R5 | D1 | (unit tests via fixtures) |
| 6.3-R6 | D6 | SC-4 |
| 6.3-R7 | D8, D10 | SC-6 |
| 6.3-R8 | (Stream 6.5 client) | SC-5 |
| 6.3-R9 | D1, D6 | (workflow test) |
| 6.3-R10 | D1, D6 | SC-8, SC-10, SC-11, SC-12 |
| 6.3-R11 | D4, D5 | SC-4, SC-9 |
| 6.3-R12 | D9 | SC-7 |
| 6.3-R13 | D10 | SC-6 |
| 6.3-R14 | D3 | (profile schema test) |
| 6.3-R15 | D3 | (retention test) |

---

```{=openxml}
<w:p><w:r><w:br w:type="page"/></w:r></w:p>
```

# Chapter 6.4 — Commercial Packaging

*Execution position: 6th of 6 · Risk-buffered effort: 46 hours · Risk level: Medium*

## 6.4.1 Goal

Transform the technical reality delivered by Streams 6.1, 6.2, 6.3, 6.5, and 6.6 into a defensible commercial product. Execute the dual-license repository split (Apache 2.0 Community / commercial Enterprise), establish brand identity separation, publish customer-facing documentation calibrated to a 30-minute time-to-first-scan, prepare an anonymized demo fleet for prospective customer evaluation, document release and contribution governance for forty-year maintainability, and ship the v0.6.0 GitHub Release. Position FieldOps Pro Public Sector Edition as a deliberate market segment differentiator.

## 6.4.2 Context

Phase 6 Streams 6.1 through 6.3 plus 6.5 and 6.6 produce a technically excellent product. They do not, on their own, produce a sellable one. The technical work is necessary but not sufficient for commercial viability. Phase 6.4 supplies what is missing: license model (open-source-credible for trust, commercial for revenue durability); brand identity (FieldOps Pro is distinct from any individual person or future commercial entity); customer-facing documentation (INSTALL, USING, EXTENDING for buyer evaluation, not developer reference); demo dataset (prospective customers see product working without risking real machines); operational scaffolding (release process, security disclosure, contribution governance, versioning commitment, brand declaration).

This is the chapter that turns "I built a tool" into "you can buy this tool." Sequenced last because every prior stream feeds into it; writing customer-facing prose before underlying features stabilize creates rewrite tax.

## 6.4.3 Requirements

| ID | Requirement |
|---|---|
| 6.4-R1 | **Dual-license split.** Codebase splits into Community (Apache 2.0 [Apache-2.0]) and Enterprise (commercial). Boundary enforced by directory layout and SPDX per-file headers [SPDX]. |
| 6.4-R2 | **Brand separation.** "FieldOps Pro" owned by declared Brand Owner; `BRAND.md` declares ownership, licensing posture, fork-naming policy. |
| 6.4-R3 | **Customer install guide.** `docs/INSTALL.md`; under 30 minutes to first scan for IT-literate reader on clean Windows host. |
| 6.4-R4 | **Customer usage guide.** `docs/USING.md`; scenarios reproducible against demo fleet. |
| 6.4-R5 | **Developer extension guide.** `docs/EXTENDING.md`; sufficient for developer to add diagnostic/framework/rule/AI prompt without consulting author. |
| 6.4-R6 | **Anonymized demo fleet.** `tests/demo-fleet/`; 15 machines x 4 scans; generator-built; audit-clean. |
| 6.4-R7 | **Self-test script.** `SCRIPTS/Core/Test-Installation.ps1`; validates fresh install. |
| 6.4-R8 | **Release process documentation.** `RELEASE.md` documenting v0.5.2 flow as canonical. |
| 6.4-R9 | **Security disclosure.** `SECURITY.md`: reporting channel, response targets, supported versions, disclosure timeline. |
| 6.4-R10 | **Contribution governance.** `CONTRIBUTING.md`: process, review standard, test-pass requirement, DCO sign-off. |
| 6.4-R11 | **Versioning policy.** `VERSIONING.md`: SemVer with public/internal API surface calibration. |
| 6.4-R12 | **Public Sector Edition positioning.** README and USING.md address French Public Sector Edition framing from 6.2.4.7. |
| 6.4-R13 | **v0.6.0 GitHub Release.** Tagged release with notes; downloadable USB-deployable zip. |
| 6.4-R14 | **README restraint.** No marketing superlatives, no by-name competitor comparisons. |
| 6.4-R15 | **Demo fleet generator.** `tools/Generate-DemoFleet.ps1`; demo fleet never hand-edited from real data. |
| 6.4-R16 | **License header audit.** `Audit-LicenseHeaders.Tests.ps1` enforces SPDX header on every source file. |
| 6.4-R17 | **Demo fleet audit.** `Audit-NoRealIdentifiersInDemoFleet.Tests.ps1` extends v0.5.2 anonymization audit. |
| 6.4-R18 | **External reviewer pass on INSTALL.md** where reviewer available. |

## 6.4.4 Design

### 6.4.4.1 Repository Topology After Split

```
github.com/msdorley/fieldops-pro                  (Community, Apache 2.0, public)
├── LICENSE                                        Apache License 2.0
├── README.md
├── CONTRIBUTING.md
├── CODE_OF_CONDUCT.md                             Contributor Covenant 2.1
├── SECURITY.md
├── RELEASE.md
├── VERSIONING.md
├── BRAND.md
├── CHANGELOG.md
├── docs/
│   ├── INSTALL.md                                 customer-facing
│   ├── USING.md                                   customer-facing
│   ├── EXTENDING.md                               developer-facing
│   ├── TESTING.md
│   ├── MULTI-FRAMEWORK.md
│   ├── FLEET-DRIFT.md
│   ├── AI-INTEGRATION.md
│   ├── ARCHITECTURE.md
│   └── PHASE-6-DESIGN.md                          (this document)
├── schemas/
├── SCRIPTS/
│   ├── Core/                                      Community
│   ├── Diagnostics/                               Community
│   ├── Network/                                   Community
│   ├── Deployment/                                Community
│   ├── Security/                                  Community
│   ├── Reporting/                                 Community (single-framework + base aggregation)
│   └── Compliance/                                Community (ANSSI single-framework only)
│       └── Build-ANSSIData.ps1
├── CONFIG/
│   ├── lang/                                      Community (French, English)
│   ├── frameworks/anssi.json                      Community (ANSSI only)
│   └── FieldOps.config.json.example
├── PLAYBOOKS/                                     Community (open-source set)
├── templates/anssi-diagnostic.html                Community
├── TOOLS/PowerShellModules/Pester/5.7.1/          bundled offline
├── tests/                                         Community test suite
└── tools/

github.com/msdorley/fieldops-pro-enterprise       (Enterprise, commercial, PRIVATE)
├── LICENSE-COMMERCIAL
├── README.md
├── SCRIPTS/
│   ├── Compliance/
│   │   ├── Invoke-CrossReference.ps1              (Stream 6.2)
│   │   └── Build-MultiFrameworkData.ps1
│   ├── Fleet/                                     (all Stream 6.3)
│   └── AI/FieldOps-AIClient.psm1                  (Stream 6.5)
├── CONFIG/
│   ├── frameworks/nis2.json, rgs.json, iso27001.json
│   ├── frameworks/cross-references.json
│   ├── AIModelPricing.json
│   └── AISeverityKeywords.json
├── templates/
│   ├── multi-framework-diagnostic.html
│   └── fleet-drift-dashboard.html
├── PLAYBOOKS/enterprise/
└── SCRIPTS/AI/prompts/
```

Community remains at `github.com/msdorley/fieldops-pro`. Enterprise is new, private, with access under commercial license. Community's docs reference Enterprise with "contact for commercial license" pointer; no Enterprise source ships in public repo.

**Rationale for Stream 6.5 (`FieldOps-AIClient.psm1`) in Enterprise.** Hardened client with cost ceilings, audit logging, tiered selection is the production-grade integration meeting audit-trail requirements Profile B customers value. Community customers integrating AI in own deployments build their own client (API is documented). Protects commercial differentiation while keeping Community meaningfully complete.

### 6.4.4.2 License Header Convention

**Community:**

```powershell
# FieldOps Pro - Community Edition
# Copyright 2026 Ousman Dorley (Brand Owner per BRAND.md)
# Licensed under the Apache License, Version 2.0
# See LICENSE in the project root for full terms.
# SPDX-License-Identifier: Apache-2.0
```

**Enterprise:**

```powershell
# FieldOps Pro - Enterprise Edition
# Copyright 2026 Ousman Dorley (Brand Owner per BRAND.md)
# Commercial license. See LICENSE-COMMERCIAL for terms.
# SPDX-License-Identifier: LicenseRef-FieldOpsPro-Commercial
```

`tools/Apply-LicenseHeaders.ps1` walks `.ps1`/`.psm1`/`.psd1` files, detects edition by repo, inserts appropriate header (preserving existing below), idempotent. `Audit-LicenseHeaders.Tests.ps1` enforces presence.

### 6.4.4.3 INSTALL.md Structure (Customer-Facing, 30-Minute Target)

```markdown
# Installing FieldOps Pro

## Prerequisites (verify before you start, 5 minutes)
- USB drive >= 32 GB (USB 3.0+ recommended)
- Windows 10 or Windows 11 host for USB preparation
- Ventoy 1.1.12 or later [Ventoy]
- PowerShell 5.1 (built into Windows 10/11)
- Internet connection for setup (offline operation supported thereafter)

## Step 1: Prepare the USB with Ventoy (5 minutes)
[Screenshots]

## Step 2: Copy the FieldOps Pro Release Artifact (3 minutes)
Download fieldops-pro-v0.6.0.zip; extract to Ventoy USB root.

## Step 3: First-Run Configuration (5 minutes)
Open CONFIG/FieldOps.config.json.example; save as FieldOps.config.json.
Edit Technician.Id, Technician.PreferredLanguage, Anthropic.ApiKey.

## Step 4: License Activation (1 minute)
Community: no activation. Enterprise: copy license key to CONFIG/license.key.

## Step 5: Verify Installation (2 minutes)
Run: .\SCRIPTS\Core\Test-Installation.ps1

## Step 6: Run Your First Scan (8 minutes)
Run: .\SCRIPTS\Compliance\Build-ANSSIData.ps1 -Mode Interactive

## Total time elapsed: approximately 29 minutes.

## Troubleshooting (top 5 setup issues)
[Numbered list]
```

### 6.4.4.4 USING.md Structure (Reader-Task Pairings)

| Section | Reader | Task | Time |
|---------|--------|------|-----:|
| §1 Per-machine ANSSI scan | Field technician | French ANSSI report | 5 min |
| §2 Multi-framework scan | Field technician | ANSSI/NIS2/ISO 27001 report | 7 min |
| §3 Fleet drift dashboard (Ent) | MSP operator | Generate from demo fleet | 10 min |
| §4 Anonymized export | MSP operator | External-sharing dashboard | 3 min |
| §5 RGS Public Sector mode | French public IT | Activate RGS framework | 5 min |
| §6 Reading the report | Compliance officer | Interpret coverage gaps | 10 min |
| §7 Cost forecasting | Procurement | Compute expected AI cost | 5 min |

Each scenario reproducible against demo fleet; screenshots included.

### 6.4.4.5 EXTENDING.md Structure (Developer-Facing)

| Section | Reader | Task |
|---------|--------|------|
| §1 Project architecture | New contributor | Module boundaries, data flow |
| §2 Adding a new diagnostic | Tool developer | Write Invoke-*.ps1, register |
| §3 Adding a new framework | Compliance practitioner | Author data file, integrate cross-reference |
| §4 Adding a new rule evaluator | Security engineer | Rule evaluator with tests |
| §5 Adding a new AI prompt | AI practitioner | Prompt template, integrate with client |
| §6 Writing tests | Any contributor | Pester 5.7.1 patterns |
| §7 Locale conventions | Translator/developer | Bundle key naming, rich-text |
| §8 PR workflow | Any contributor | Branch, commit, push, PR, review |

### 6.4.4.6 Demo Fleet Generator

`tools/Generate-DemoFleet.ps1` produces 15 synthetic machines x 4 historical scans. Key properties:

- **Synthetic-only inputs.** Hardcoded fabricated machine profiles: 3 Latitude 3450, 4 Latitude 3540, 2 HP EliteBook, 2 Lenovo ThinkPad, 4 Acer Nitro. Hostnames `DEMO-WS01` through `DEMO-WS15`. Serials `DEMO0000000000000001` through `DEMO0000000000000015`.
- **Realistic distributions.** ~70% satisfied controls, 2-3 problem machines, at least one silent, time-series showing improvements and regressions across 4 scans.
- **Internally consistent.** Machine showing "BitLocker enabled" in scan 1 cannot show "BitLocker not present" in scan 2 without intervening disable event.
- **Multi-framework realistic.** Findings map across ANSSI/NIS2/ISO 27001/RGS per cross-reference table.
- **Audit-clean by construction.** No real hostnames, serials, IPs, technician IDs. Enforced by `Audit-NoRealIdentifiersInDemoFleet.Tests.ps1`.

### 6.4.4.7 Brand Declaration (BRAND.md)

```markdown
# FieldOps Pro - Brand Declaration

## Brand Ownership
The name "FieldOps Pro" and any associated marks, logos, or trade dress
are owned by Ousman Dorley.

## Brand Mark and Codebase Licensing
The codebase is licensed under:
- Apache License 2.0 for the Community Edition (see LICENSE)
- A commercial license for the Enterprise Edition (see LICENSE-COMMERCIAL)

The brand mark is licensed independently of the codebase. This separation
is deliberate: software freedom and trademark protection serve different
purposes.

## Fork Naming Policy
Forks of the Community Edition are welcome under Apache 2.0 terms.
Forks may NOT use "FieldOps Pro" name, logo, or other marks in their
project name, branding, or marketing without written permission from
the Brand Owner. Forks are encouraged to choose a distinct name.

## Contact
For brand-licensing inquiries: ousman.dorley@<contact-domain>

## Revision
This declaration may be updated as ownership or commercial structure
evolves. Material revisions are noted in CHANGELOG.md with effective date.
```

### 6.4.4.8 VERSIONING.md Calibration

Public API surface protected by SemVer from v0.6.0:

- `Invoke-FieldOpsAI` module signature
- Framework data file schema (`schemas/framework-data.json`)
- Cross-reference table schema (`schemas/cross-references.json`)
- Locale bundle key namespace conventions
- AI audit log JSON Lines schema (`schemas/ai-audit-record.json`)
- Rich-text bundle value schema (`schemas/rich-text-bundle-value.json`)
- Scan history store schema (`schemas/fleet-scan-history.json`)
- CLI argument surface of all `Invoke-*.ps1` scripts in `docs/USING.md`
- Playbook front matter schema (`schemas/playbook-frontmatter.json`)

Internal (may change without SemVer bump): implementation details; HTML template internal structure; helpers not exposed via documented entry points; test infrastructure; tooling.

### 6.4.4.9 SECURITY.md

- **Reporting**: `security@<contact-domain>` with `[SECURITY]` prefix. PGP key for sensitive disclosures.
- **Response targets**: acknowledgment within 5 business days; investigation and triage within 15 business days; public disclosure typically 90 days after acknowledgment.
- **Supported versions**: current latest + N-1 (critical fixes only).
- **Coordinated disclosure** preferred; CVE assignment requested where applicable.

### 6.4.4.10 CONTRIBUTING.md Key Provisions

- DCO sign-off required (no formal CLA)
- Every PR passes test suite from Stream 6.6 before merge (pre-commit hook catches most locally)
- Substantive review by maintainer required for changes touching: framework data, cross-references, AI client, audit schema, license headers, brand, security/release governance
- v0.6.0 launch maintainer set: Ousman Dorley (sole). Transfer process documented.
- Community contributions accepted under Apache 2.0; Enterprise contributions require separate CLA
- Contributor Covenant 2.1 code of conduct applies

### 6.4.4.11 v0.6.0 Release Notes (Draft)

```markdown
# FieldOps Pro v0.6.0
Released: <date TBD>
Codename: Phase 6 — From Toolkit to Product

## Overview
v0.6.0 transitions FieldOps Pro from working personal toolkit into
defensible, commercially viable enterprise product. Six work streams
delivered: tested foundation; complete internationalization; production-grade
AI with tiered model selection; four-framework compliance (ANSSI, NIS2,
ISO/IEC 27001, RGS v2.0); AI-narrated fleet drift dashboarding;
dual-license commercial packaging.

## What is new

### Multi-framework compliance reporting (Enterprise)
- Map findings to ANSSI, NIS2 (Directive + IR 2024/2690), ISO/IEC 27001:2022, RGS v2.0
- >= 40 cross-referenced findings with confidence ratings
- Honest coverage-gap reporting
- French Public Sector Edition framing for RGS

### Fleet drift dashboard (Enterprise)
- Aggregate per-machine scans into fleet posture over time
- Per-machine drift detection
- AI-narrated executive summary
- Inline SVG charts; no external dependencies
- Privacy-preserving fleet identifiers; anonymized export
- Cost-bounded AI usage

### Production AI integration (Enterprise)
- Tiered model selection: Haiku 4.5 / Sonnet 4.6 / Opus 4.7
- Estimated 40-60% cost reduction vs uniform-Opus
- Structured audit logging per JSON Schema
- Severity classification with playbook reference validation
- Per-invocation cost ceilings; graceful degradation

### Complete internationalization (Community)
- All ANSSI module titles, rule names, rich-text strings routed through bundles
- Bundle count: 221 -> ~290 keys
- French and English parity validated by audit

### Tested foundation (Community)
- Pester 5.7.1 suite; >= 30 unit + >= 3 property tests
- Pre-commit hook catches regressions
- Bundled offline Pester for locked-down endpoints
- Audit tests enforce repository invariants

### Commercial packaging (Both editions)
- Dual-license split: Apache 2.0 Community / commercial Enterprise
- Brand declaration separating product name from code licensing
- Customer docs: INSTALL/USING/EXTENDING (30-min time-to-first-scan)
- Anonymized 15-machine demo fleet
- Release, security, contribution, versioning policies

## Breaking changes
- Repository split: Enterprise in private repo (commercial license required)
- Direct calls to api.anthropic.com forbidden; must route through FieldOps-AIClient
- Locale bundle keys for module titles / rule names changed

## Acknowledgments
Pester team; ANSSI; European Commission for NIS2 + IR 2024/2690;
ISO/IEC and AFNOR; Anthropic; Ventoy contributors.

## Phase 7 outlook
Candidate streams under consideration: GitHub Actions CI; additional
frameworks (NIST CSF, HDS, SecNumCloud); multi-provider AI; real-time
drift alerting; multi-tenant MSP customer separation; additional language
bundles; cryptographic playbook signing.

## Migration from v0.5.2
See docs/MIGRATION-v0.5-to-v0.6.md.

## Statistics
- Phase 6 investment: ~220 risk-adjusted hours
- Calendar duration: ~9 weeks
- Lines added: ~12,500 net (4,300 Community + 8,200 Enterprise)
- Frameworks supported: 4 (was 1)
- Cross-referenced findings: >= 40 (was 0)
```

## 6.4.5 Deliverables

| ID | Artifact | Path / Location |
|----|----------|-----------------|
| 6.4-D1 | Community LICENSE | `LICENSE` (Apache 2.0) |
| 6.4-D2 | Enterprise LICENSE | `LICENSE-COMMERCIAL` (Enterprise repo) |
| 6.4-D3 | License header migration script | `tools/Apply-LicenseHeaders.ps1` |
| 6.4-D4 | INSTALL.md | `docs/INSTALL.md` |
| 6.4-D5 | USING.md | `docs/USING.md` |
| 6.4-D6 | EXTENDING.md | `docs/EXTENDING.md` |
| 6.4-D7 | ARCHITECTURE.md | `docs/ARCHITECTURE.md` |
| 6.4-D8 | RELEASE.md | `RELEASE.md` |
| 6.4-D9 | SECURITY.md | `SECURITY.md` |
| 6.4-D10 | CONTRIBUTING.md | `CONTRIBUTING.md` |
| 6.4-D11 | VERSIONING.md | `VERSIONING.md` |
| 6.4-D12 | BRAND.md | `BRAND.md` |
| 6.4-D13 | CODE_OF_CONDUCT.md | `CODE_OF_CONDUCT.md` |
| 6.4-D14 | CHANGELOG.md | `CHANGELOG.md` |
| 6.4-D15 | Demo fleet generator | `tools/Generate-DemoFleet.ps1` |
| 6.4-D16 | Demo fleet artifacts | `tests/demo-fleet/` |
| 6.4-D17 | Self-test script | `SCRIPTS/Core/Test-Installation.ps1` |
| 6.4-D18 | Updated README | `README.md` |
| 6.4-D19 | v0.6.0 release notes | GitHub Releases body |
| 6.4-D20 | v0.6.0 USB-deployable zip | GitHub Releases attachment |
| 6.4-D21 | Enterprise repository skeleton | private repo |
| 6.4-D22 | Repository split execution plan | `tools/Split-Repository.md` |
| 6.4-D23 | License header audit test | `tests/audit/Audit-LicenseHeaders.Tests.ps1` |
| 6.4-D24 | Demo fleet audit test | `tests/audit/Audit-NoRealIdentifiersInDemoFleet.Tests.ps1` |
| 6.4-D25 | Migration guide | `docs/MIGRATION-v0.5-to-v0.6.md` |

## 6.4.6 Risks

| ID | Risk | Severity | Mitigation |
|----|------|----------|------------|
| 6.4-Risk-1 | Apache 2.0 patent grant unintended consequences | Medium | DCO sign-off standard; legal review recommended; decision documented |
| 6.4-Risk-2 | Repository split disrupts v0.5.2 users | Low | Split in release notes; migration documented; v0.5.2 tag preserved |
| 6.4-Risk-3 | Customer docs under-tested | Medium | External reviewer walks INSTALL on clean machine before v0.6.0 |
| 6.4-Risk-4 | Demo dataset contains real identifiers | High | Generator-only; audit test enforces |
| 6.4-Risk-5 | Brand/entity decisions delayed | Low | BRAND.md supports later revision |
| 6.4-Risk-6 | Documentation effort underestimated | Medium | P0/P1/P2 prioritization |
| 6.4-Risk-7 | Enterprise repo setup complexity | Medium | Offline keyfile (no online activation server) |
| 6.4-Risk-8 | License header migration breaks comments | Low | Idempotent script preserves existing |

## 6.4.7 Dependencies

**Upstream:** All prior streams stable; Brand Owner decision; Enterprise repo created on GitHub; optional external reviewer.
**Downstream:** Future commercial sales activity; Phase 7 (post-launch operations).

## 6.4.8 Success Criteria

| ID | Criterion | Verification |
|----|-----------|--------------|
| 6.4-SC-1 | Repository split executed; Community public, Enterprise private | Repo inspection |
| 6.4-SC-2 | License headers on every source file in both repos | Audit test |
| 6.4-SC-3 | INSTALL.md walked end-to-end by external reviewer; under 30 min; issues addressed | Reviewer sign-off |
| 6.4-SC-4 | USING.md scenarios reproducible against demo fleet by non-developer | Reviewer sign-off |
| 6.4-SC-5 | EXTENDING.md sufficient for developer to add diagnostic without consulting author | Spot-check by target reader |
| 6.4-SC-6 | Demo fleet: 15 machines x 4 scans, audit-clean, runs through full Phase 6 pipeline | Audit + end-to-end |
| 6.4-SC-7 | Self-test passes on canonical install | Self-test run |
| 6.4-SC-8 | v0.6.0 GitHub Release published with notes + USB-deployable zip | GitHub inspection |
| 6.4-SC-9 | README restraint: zero superlatives, zero by-name comparisons | Editorial review |
| 6.4-SC-10 | All governance documents present and consistent | Document inventory audit |
| 6.4-SC-11 | Migration guide validated against actual v0.5.2 -> v0.6.0 upgrade | Manual walkthrough |
| 6.4-SC-12 | DCO sign-off enforced on first PR after v0.6.0 | Process verification |

## 6.4.9 Estimate Justification

| Sub-task | Hours |
|----------|------:|
| Repository split mechanics | 5 |
| LICENSE files (Apache 2.0 + LICENSE-COMMERCIAL) | 2 |
| Apply-LicenseHeaders.ps1 + verification | 1 |
| INSTALL.md drafting + screenshots + reviewer iteration | 5 |
| USING.md drafting + 7 scenarios + screenshots | 6 |
| EXTENDING.md drafting + 8 sections + examples | 5 |
| ARCHITECTURE.md drafting | 3 |
| Governance docs (RELEASE/SECURITY/CONTRIBUTING/VERSIONING/BRAND/CoC/CHANGELOG) | 5 |
| Demo fleet generator + 15-machine fixture | 4 |
| Self-test script | 2 |
| README rewrite with restraint check | 2 |
| v0.6.0 release notes + acknowledgments | 2 |
| Migration guide v0.5.2 -> v0.6.0 | 2 |
| External reviewer iteration buffer | 3 |
| Repository split execution + verification | 2 |
| **Base total** | **49** |

Note: base sum 49; chapter top-line 40 reflects 9h reuse from v0.5.2 governance precedents. Risk buffer 15% (6 hours). Buffered 46 hours.

Deferrable if overrun: ARCHITECTURE.md (brief overview, expand Phase 7); external reviewer buffer (ship without if unavailable).

## 6.4.10 Open Questions

| ID | Question | Recommendation |
|----|----------|----------------|
| 6.4-OQ-1 | Brand Owner: project author personally or legal entity? | **Author personally for v0.6.0.** Revisit when commercial revenue makes entity formation tax-efficient. |
| 6.4-OQ-2 | Online license activation server or offline keyfile? | **Offline keyfile.** Phase 7+ if piracy materializes. |
| 6.4-OQ-3 | Free Enterprise evaluation period? | **30 days.** License keyfile with `expires` field. |
| 6.4-OQ-4 | Community includes ANSSI or diagnostics-only? | **Community includes ANSSI.** Gatekeeping public ANSSI guide erodes community trust. Multi-framework is Enterprise lever. |
| 6.4-OQ-5 | GitHub Pages doc site? | **In-repo Markdown sufficient.** GitHub Pages Phase 7 candidate. |
| 6.4-OQ-6 | Sign v0.6.0 release zip? | **Yes, GPG detached signature.** Adds ~1h; forty-year-stable. |
| 6.4-OQ-7 | Stream 6.5 prompt caching: 6.5 or 6.4-adjacent? | **Fold into 6.5.** +1-2h absorbed by 6.5 buffer. |

## 6.4.11 Traceability Mini-Matrix

| Requirement | Deliverable(s) | Success Criterion |
|-------------|----------------|-------------------|
| 6.4-R1 | D1, D2 | SC-1 |
| 6.4-R2 | D12 | SC-10 |
| 6.4-R3 | D4 | SC-3 |
| 6.4-R4 | D5 | SC-4 |
| 6.4-R5 | D6 | SC-5 |
| 6.4-R6 | D16, D15 | SC-6 |
| 6.4-R7 | D17 | SC-7 |
| 6.4-R8 | D8 | SC-10 |
| 6.4-R9 | D9 | SC-10 |
| 6.4-R10 | D10 | SC-10, SC-12 |
| 6.4-R11 | D11 | SC-10 |
| 6.4-R12 | D18, D5 | (USING.md §5) |
| 6.4-R13 | D19, D20 | SC-8 |
| 6.4-R14 | D18 | SC-9 |
| 6.4-R15 | D15 | SC-6 |
| 6.4-R16 | D23 | SC-2 |
| 6.4-R17 | D24 | SC-6 |
| 6.4-R18 | (process) | SC-3 |

---

```{=openxml}
<w:p><w:r><w:br w:type="page"/></w:r></w:p>
```

# Appendix A — Glossary and Acronyms Quick Reference

## A.1 Acronyms Quick Reference

| Acronym | Expansion |
|---------|-----------|
| AFNOR | Association Francaise de Normalisation (French standards body, publishes French translations of ISO standards) |
| ANSSI | Agence nationale de la securite des systemes d'information (French national cybersecurity agency) |
| CDN | Content Delivery Network |
| CELEX | EUR-Lex permanent identifier scheme for EU legal acts |
| CISO | Chief Information Security Officer |
| CLA | Contributor License Agreement |
| CSF | Cybersecurity Framework (NIST) |
| DCO | Developer Certificate of Origin |
| DNS | Domain Name System |
| DORA | Digital Operational Resilience Act (EU) |
| DSI | Direction des systemes d'information (French: IT department) |
| EBIOS | Expression des besoins et identification des objectifs de securite (ANSSI risk method) |
| ELI | European Legislation Identifier (EUR-Lex permanent URL scheme) |
| ENISA | European Union Agency for Cybersecurity |
| EUR-Lex | EU legal database (eur-lex.europa.eu) |
| HDS | Hebergeur de Donnees de Sante (French health data hosting certification) |
| IR | Implementing Regulation (EU) |
| ISMS | Information Security Management System |
| ISO | International Organization for Standardization |
| jsonl | JSON Lines (NDJSON) - one JSON object per line |
| MFA | Multi-Factor Authentication |
| MSP | Managed Service Provider |
| MSSP | Managed Security Service Provider |
| MTok | Million Tokens (Anthropic API pricing unit) |
| NIS2 | Network and Information Security Directive 2 (EU) 2022/2555 |
| NIST | National Institute of Standards and Technology (US) |
| PII | Personally Identifiable Information |
| PSGallery | PowerShell Gallery |
| RGPD | Reglement General sur la Protection des Donnees (French: GDPR) |
| RGS | Referentiel General de Securite (French general security reference) |
| SaaS | Software as a Service |
| SecNumCloud | French cloud certification (ANSSI) |
| SHA-256 | Secure Hash Algorithm, 256-bit variant |
| SKU | Stock Keeping Unit |
| SPDX | Software Package Data Exchange (license identifier standard) |
| SVG | Scalable Vector Graphics |
| TLD | Top-Level Domain |
| TPM | Trusted Platform Module |
| UAC | User Account Control (Windows) |
| WCAG | Web Content Accessibility Guidelines |
| WinPE | Windows Preinstallation Environment |
| WMI | Windows Management Instrumentation |

## A.2 Domain Glossary

**Anonymization** — Replacement of identifying machine attributes with synthetic non-identifying placeholders. Applied at rendering time (anonymized export mode) or at history rewrite time (v0.5.2 anonymization commit).

**Audit log** — JSON Lines record produced by `FieldOps-AIClient.psm1` (Stream 6.5) capturing one line per AI invocation, with sufficient information for compliance review without exposing prompt/response content (only SHA-256 hashes stored by default).

**Bundle** — Locale-specific JSON file containing translated strings keyed by namespace (e.g., `fr.json`, `en.json` under `CONFIG/lang/`).

**Community Edition** — Apache 2.0-licensed portion of FieldOps Pro: framework, core diagnostics, ANSSI single-framework reporting. Publicly distributed.

**Confidence rating** — Field on every cross-reference entry (`high`, `medium`, `low`) declaring strength of semantic mapping between FieldOps Pro finding and compliance framework control.

**Cross-reference** — Mapping between one FieldOps Pro technical finding and one or more compliance framework controls. Cross-reference table is canonical artifact.

**Drift** — Change over time in machine's or fleet's compliance posture, measured by comparing scan results at two timestamps.

**Enterprise Edition** — Commercially licensed portion of FieldOps Pro: multi-framework support, fleet drift dashboard, hardened AI client with playbook validation, audit log compliance pack.

**Finding** — Specific assessable technical condition identified by scan (e.g., `BitLockerEnabledSystemDrive`). Unit of cross-reference to frameworks.

**Fleet drift dashboard** — Single self-contained HTML artifact showing fleet compliance posture over time, with per-framework drift detection and AI-narrated executive summary (Stream 6.3).

**Foundations** — Cross-cutting design rules in §2 applying to every chapter (ASCII-only source, two-level Split-Path, tiered AI model selection).

**Framework** — Published set of controls against which machine's posture is assessed. Phase 6.2 supports four: ANSSI Guide d'hygiene informatique, NIS2 Directive, ISO/IEC 27001:2022, RGS v2.0.

**Locale routing** — Architectural pattern where user-facing text is keyed in source code and resolved at render time from language-specific bundle.

**Machine ID hash** — `SHA-256(fleetSalt || ":" || hostname || ":" || serialNumber || ":" || azureAdTenant)`. Stable identifier for fleet tracking; salt prevents cross-fleet correlation if leaked.

**OutputMultiplier** — Per-call-site heuristic in Stream 6.5 cost estimation: `estimated_output_tokens = input_tokens × OutputMultiplier`. Defaults range 0.3 (classification) to 5.0 (long-form).

**Playbook** — Markdown file under `PLAYBOOKS/` describing specific remediation, identified by stable ID (e.g., `RB-AV-001`), referenced by AI responses to anchor recommendations to validated procedures.

**Property test** — Test verifying property holds across generated range of inputs ("for any registry input, rule evaluator never throws"), distinct from test verifying behavior on specific inputs.

**Severity classification** — Automatic assignment by `FieldOps-AIClient.psm1` of AI response to `INFORMATIONAL` / `ADVISORY` / `ACTION_REQUIRED` / `CRITICAL`. Two-tier classifier: keyword + structural.

**SPDX identifier** — Machine-readable license identifier in source file headers (e.g., `Apache-2.0`, `LicenseRef-FieldOpsPro-Commercial`). Enables automated license auditing.

**TaskTier** — Stream 6.5 parameter specifying call-site cost-sensitivity. Three values: `Classification` -> Haiku 4.5, `Narration` -> Sonnet 4.6, `Reasoning` -> Opus 4.7. Operator-overridable.

**USB toolkit** — In competitive landscape (MediCat, Hiren's, NHV, FieldOps Pro), software bundle deployed on bootable USB for technician use against target machines.

---

```{=openxml}
<w:p><w:r><w:br w:type="page"/></w:r></w:p>
```

# Appendix B — Consolidated Risk Register

| ID | Chapter | Risk | Severity | Mitigation Summary |
|----|---------|------|----------|--------------------|
| 6.6-Risk-1 | 6.6 | Pester not installable on locked-down endpoints | Low | Bundled offline copy at TOOLS/PowerShellModules/Pester/5.7.1/ |
| 6.6-Risk-2 | 6.6 | Fixture drift over time | Low-Medium | Quarterly refresh checklist in TESTING.md |
| 6.6-Risk-3 | 6.6 | Property tests flaky from randomization | Medium | Seeded reproducibility, replay capability |
| 6.6-Risk-4 | 6.6 | Test maintenance burden creep | Medium | Risk-path focus, not test count |
| 6.6-Risk-5 | 6.6 | Latent-defect discovery finds nothing | Medium | Escalates to test-design review |
| 6.1-Risk-1 | 6.1 | Hidden-string audit reveals more than estimated | Low | Audit-first sequencing |
| 6.1-Risk-2 | 6.1 | Translator handoff assumption unverified | Low | Architecture supports both modes |
| 6.1-Risk-3 | 6.1 | Template regression from rewires | Low | Audit-LocaleTokenCoverage in pre-commit |
| 6.1-Risk-4 | 6.1 | English translation quality | Low-Medium | Author-drafted; revisit at 6.4 |
| 6.5-Risk-1 | 6.5 | Cost-estimation heuristic too loose | Medium | Per-script OutputMultiplier, variance logging |
| 6.5-Risk-2 | 6.5 | Model pricing drift | Medium | Freshness test, versioned config |
| 6.5-Risk-3 | 6.5 | Audit log unbounded growth | Low | Rotation, compression, retention |
| 6.5-Risk-4 | 6.5 | Severity classifier misclassifies CRITICAL | High | Default ADVISORY, needs_human_review flag |
| 6.5-Risk-5 | 6.5 | Playbook drift from reality | Medium | Update process documented |
| 6.5-Risk-6 | 6.5 | API key leak | Critical | Audit-NoApiKeyInLogs test, code review |
| 6.5-Risk-7 | 6.5 | Opus 4.7 tokenizer migration cost surprise | Medium | tokenizerVariant field, benchmark before migration |
| 6.5-Risk-8 | 6.5 | 20 playbooks effort exceeds estimate | Medium | **Realised.** Reduced to 10; SC-7 amended |
| 6.5-Risk-9 | 6.5 | Graceful degradation untested across call sites | Medium | Refactor explicitly includes fallback paths |
| 6.2-Risk-1 | 6.2 | Framework interpretation requires legal expertise | High | Confidence rating field, primary-authority citations |
| 6.2-Risk-2 | 6.2 | Framework versions drift | Medium | Version pinning, Phase 7 tracking |
| 6.2-Risk-3 | 6.2 | Cross-reference table unwieldy at scale | Low | Flat JSON, revisit if >200 findings |
| 6.2-Risk-4 | 6.2 | Translation quality for non-French frameworks | Medium | Official translations cited (AFNOR, EUR-Lex) |
| 6.2-Risk-5 | 6.2 | "Compliant" vs "posture" misreading | High | Explicit disclaimer on every report |
| 6.2-Risk-6 | 6.2 | RGS positioning misread | Medium | Public Sector Edition opt-in flag |
| 6.2-Risk-7 | 6.2 | NIS2 dual-citation confuses operators | Medium | Decision tree in MULTI-FRAMEWORK.md |
| 6.2-Risk-8 | 6.2 | Chapter effort underestimated | Medium-High | 20% risk buffer; deferrable: RGS depth |
| 6.3-Risk-1 | 6.3 | Scan history grows large fast | Medium | Compact files, rotation, compression |
| 6.3-Risk-2 | 6.3 | AI narration inaccurate | High | Prompt constraints, audit log, override |
| 6.3-Risk-3 | 6.3 | SVG charts brittle on edge cases | Medium | Empty-state per chart type, property tests |
| 6.3-Risk-4 | 6.3 | Privacy claim hard to verify | High | Audit test with edge-case fixtures |
| 6.3-Risk-5 | 6.3 | Fleet aggregation arithmetic subtly wrong | Medium | Property tests for invariants |
| 6.3-Risk-6 | 6.3 | Chapter scope creep (most ambitious) | Medium-High | Success criteria bounded, out-of-scope named |
| 6.3-Risk-7 | 6.3 | SVG cross-browser rendering inconsistency | Medium | Visual regression across 4 viewers |
| 6.3-Risk-8 | 6.3 | Anonymization mapping file leaked | Medium | Excluded from default export bundle |
| 6.3-Risk-9 | 6.3 | Fleet salt loss eliminates correlation | Medium | Operator backup recommended, documented |
| 6.4-Risk-1 | 6.4 | Apache 2.0 patent grant consequences | Medium | DCO sign-off standard; legal review recommended |
| 6.4-Risk-2 | 6.4 | Repository split disrupts users | Low | Migration documented; v0.5.2 tag preserved |
| 6.4-Risk-3 | 6.4 | Customer docs under-tested | Medium | External reviewer required |
| 6.4-Risk-4 | 6.4 | Demo dataset contains real identifiers | High | Generator-only, audit test |
| 6.4-Risk-5 | 6.4 | Brand/entity decisions delayed | Low | BRAND.md supports later revision |
| 6.4-Risk-6 | 6.4 | Documentation effort underestimated | Medium | P0/P1/P2 prioritization |
| 6.4-Risk-7 | 6.4 | Enterprise repository setup complexity | Medium | Offline keyfile activation |
| 6.4-Risk-8 | 6.4 | License header migration breaks comments | Low | Idempotent script preserves existing |

**Severity distribution across Phase 6:**

- Critical: 1 (6.5-Risk-6, API key leak)
- High: 5 (6.5-Risk-4, 6.2-Risk-1, 6.2-Risk-5, 6.3-Risk-2, 6.3-Risk-4, 6.4-Risk-4)
- Medium: 21
- Low to Low-Medium: 12

The 6 critical-or-high risks each have explicit mitigations with audit tests where automatable. Phase 6 execution monitors all 6 explicitly; any unresolved critical or high risk at end of a chapter triggers a hold-and-resolve cycle.

---

```{=openxml}
<w:p><w:r><w:br w:type="page"/></w:r></w:p>
```

# Appendix C — Success Criteria Matrix

Total criteria: 73 (38 from initial draft plus criteria added in premium chapters).

Distribution: 6.6 (10), 6.1 (8), 6.5 (11), 6.2 (12), 6.3 (13), 6.4 (12), cross-chapter (7).

The matrix in detail lives in each chapter's §X.Y.8 — this appendix summarizes by reference rather than reproducing all 73 rows. v0.6.0 ships only when all 73 criteria are met (or explicitly deferred with documented rationale in release notes).

**Cross-chapter success criteria:**

| ID | Criterion | Verification |
|----|-----------|--------------|
| Cross-SC-1 | Full Phase 6 test suite passes on canonical environment | `Run-AllTests.ps1` exit code 0 |
| Cross-SC-2 | All audit tests pass (ASCII, locale coverage, license headers, no direct AI calls, no API key in logs, no real IDs in fixtures, no real IDs in demo fleet, no machine IDs in AI prompts) | Audit suite pass |
| Cross-SC-3 | Phase 6 design document committed to repository | File presence |
| Cross-SC-4 | Phase 6 design document also delivered as Word docx | Artifact attached to PR |
| Cross-SC-5 | All risk-buffered estimates validated within their chapter (no chapter exceeds 25% buffer without re-planning) | Time tracking review |
| Cross-SC-6 | v0.6.0 release notes acknowledge all primary-authority sources | Release notes inspection |
| Cross-SC-7 | Phase 6 launch retrospective scheduled two weeks post-release | Calendar entry |

---

```{=openxml}
<w:p><w:r><w:br w:type="page"/></w:r></w:p>
```

# Appendix D — Full Traceability Matrix

Every numbered requirement (R*) -> deliverable(s) (D*) -> success criterion (SC*). This appendix consolidates per-chapter traceability mini-matrices for cross-chapter review.

Full matrix contains 80 requirement rows across six chapters. Reproducing all 80 here would duplicate per-chapter mini-matrices; this appendix references them by chapter:

- Chapter 6.6 traceability: see §6.6.11 (9 requirements)
- Chapter 6.1 traceability: see §6.1.11 (9 requirements)
- Chapter 6.5 traceability: see §6.5.11 (15 requirements)
- Chapter 6.2 traceability: see §6.2.11 (15 requirements)
- Chapter 6.3 traceability: see §6.3.11 (15 requirements)
- Chapter 6.4 traceability: see §6.4.11 (18 requirements)

Total: 81 numbered requirements across the six chapters, each traced to deliverables and success criteria within its chapter.

Cross-chapter dependencies are visible in each chapter's §X.Y.7 (Dependencies) and consolidated in §3.3 (Dependency Graph) of the front matter.

**Coverage verification:** every requirement maps to at least one deliverable; every deliverable maps to at least one requirement; every success criterion maps to at least one requirement. No orphaned items.

---

```{=openxml}
<w:p><w:r><w:br w:type="page"/></w:r></w:p>
```

# Appendix E — Estimate Reconciliation

| Stream | Sub-task Sum | Chapter Top-Line (Base) | Compression | Risk Buffer | Buffered Total |
|--------|-------------:|------------------------:|------------:|------------:|---------------:|
| 6.6 | 34 | 24 | 10 h (test pattern reuse) | 10% | 26 |
| 6.1 | 16 | 16 | 0 | 10% | 18 |
| 6.5 | 36 | 35 | 1 h (test infra reuse) | 25% | 44 |
| 6.2 | 55 | 52 | 3 h (locale tooling reuse) | 20% | 62 |
| 6.3 | 64 | 56 | 8 h (template + locale reuse) | 25% | 70 |
| 6.4 | 49 | 40 | 9 h (governance precedent reuse) | 15% | 46 |
| **Totals** | **254** | **223** | **31** | **~20% avg** | **266** |

**Reading the table:** sub-task sums are realistic best-case estimates if every sub-task is executed in isolation. Chapter top-lines reflect estimated compression from reusing infrastructure and patterns from prior streams (a chapter that lands later benefits from earlier work). Risk buffers calibrate to chapter risk level (high-risk chapters carry 25%; low-risk chapters carry 10-15%).

**The 266-hour buffered total is the planning basis.** The 223-hour base is the estimation basis if Phase 6 is ever scoped as commercial billable work. The 254-hour sub-task sum is the upper bound if compression assumptions do not materialize.

**Calendar conversion:**

- 266 hours at 40 h/week full-time = 6.7 weeks
- 266 hours at 24 productive h/week (realistic with professional obligations + iteration loops + research dead ends) = 11 calendar weeks
- Recommended planning calendar: **9 weeks** with explicit go/no-go checkpoints at end of each chapter; if 6.5 or 6.3 overruns its buffer, the 9-week target absorbs up to 2 weeks of slippage before requiring re-planning.

**Adjustments from earlier message estimates:**

- Initial draft 216 hours -> Call 1 (tiered model selection, +3h in 6.5) -> 219 hours
- -> Call 3 (NIS2 dual-citation, +4h in 6.2) -> 223 hours
- -> Open Q 6.3-OQ-5 (prompt caching, +1-2h, absorbed by 6.5 buffer) -> base estimate stable at 223 hours
- Buffered total 266 hours within original risk-buffered envelope

---

```{=openxml}
<w:p><w:r><w:br w:type="page"/></w:r></w:p>
```

# Appendix F — Citation Bibliography

All primary-authority references cited in this document, with publication date, retrieval date, and permanent identifier where available.

| Short-form | Full reference | URL | Permanent ID | Retrieved |
|------------|----------------|-----|--------------|-----------|
| [ANSSI-Hyg] | ANSSI, *Guide d'hygiene informatique - Renforcer la securite de son systeme d'information en 42 mesures*. Edition revisee 2017. | https://cyber.gouv.fr/hygiene-informatique | ANSSI-Hyg-2017 | 2026-05-25 |
| [NIS2-Dir] | European Parliament and Council, *Directive (EU) 2022/2555 of 14 December 2022 on measures for a high common level of cybersecurity across the Union (NIS 2 Directive)*. | https://eur-lex.europa.eu/eli/dir/2022/2555/oj | CELEX:32022L2555 | 2026-05-25 |
| [NIS2-IR] | European Commission, *Commission Implementing Regulation (EU) 2024/2690 of 17 October 2024 laying down rules for the application of Directive (EU) 2022/2555 as regards technical and methodological requirements of cybersecurity risk-management measures*. | https://eur-lex.europa.eu/legal-content/EN/TXT/?uri=CELEX%3A32024R2690 | CELEX:32024R2690 | 2026-05-25 |
| [ISO27001-2022] | International Organization for Standardization, *ISO/IEC 27001:2022 Information security, cybersecurity and privacy protection - Information security management systems - Requirements*. 3rd edition, October 2022. | https://www.iso.org/standard/27001 | ISO/IEC 27001:2022 | 2026-05-25 |
| [RGS-v2] | Premier ministre francais, *Arrete du 13 juin 2014 portant approbation du Referentiel general de securite, version 2.0*. ANSSI. | https://cyber.gouv.fr/reglementation/reglementation-identite-confiance-numerique/securite-echanges-voie-electronique/referentiel-general-de-securite/ | RGS-v2.0-2014 | 2026-05-25 |
| [Apache-2.0] | The Apache Software Foundation, *Apache License, Version 2.0*. January 2004. | https://www.apache.org/licenses/LICENSE-2.0 | Apache-2.0 | 2026-05-25 |
| [SPDX] | Linux Foundation, *SPDX License List*. Continuously maintained. | https://spdx.org/licenses/ | SPDX | 2026-05-25 |
| [Pester] | Pester Team, *Pester 5.7.1*. PowerShell test and mock framework. PSGallery. | https://www.powershellgallery.com/packages/Pester/5.7.1 | Pester-5.7.1 | 2026-05-25 |
| [Ventoy] | Hailong Sun (longpanda), *Ventoy 1.1.12*. Bootable USB solution. Released 23 April 2026. | https://www.ventoy.net | Ventoy-1.1.12 | 2026-05-25 |
| [Anthropic-Pricing] | Anthropic, *Claude API Pricing*. May 2026 snapshot: Opus 4.7 at $5/$25 per MTok; Opus 4.6 at $5/$25; Sonnet 4.6 at $3/$15; Haiku 4.5 at $1/$5. | https://www.anthropic.com/pricing | Anthropic-Pricing-2026-05 | 2026-05-25 |
| [MediCat] | MediCat USB project. Bootable USB toolkit for technician use. | https://www.medicatusb.com | MediCat | 2026-05-25 |
| [Hirens] | Hiren's BootCD PE. Windows PE based bootable rescue media. | https://www.hirensbootcd.org | Hirens-PE | 2026-05-25 |
| [NHV] | NHV Boot project. Multi-purpose bootable USB. | (project documentation) | NHV-Boot | 2026-05-25 |

**Citation maintenance.** This bibliography is the canonical reference list for the design document. Updates to external sources trigger a bibliography revision logged in Appendix G.

---

```{=openxml}
<w:p><w:r><w:br w:type="page"/></w:r></w:p>
```

# Appendix G — Revision History

Document amendments after initial publication are logged here with date, section, change, and rationale. The initial publication is row 1.

| Date | Section | Change | Rationale |
|------|---------|--------|-----------|
| 2026-05-25 | All | Initial publication, v0.6.0-design.draft.1 | Phase 6 design document established |

**Amendment template** for future entries:

| Date | Section | Change | Rationale |
|------|---------|--------|-----------|
| YYYY-MM-DD | §X.Y.Z | [summary] | [rationale; reference to underlying event such as framework version update, external research finding, execution learning] |

**Amendment authority.** During Phase 6 execution, the document author may amend any chapter to reflect execution learnings, with revision-history entries. Amendments affecting deliverables, success criteria, or estimates require explicit annotation. Post-v0.6.0 release, the document is frozen as the historical Phase 6 record; Phase 7 work has its own design document.

---

```{=openxml}
<w:p><w:r><w:br w:type="page"/></w:r></w:p>
```

# Appendix H — Competitive Matrix (Detailed)

Extended view of competitive analysis from §1.4.

| Capability | MediCat USB [MediCat] | Hiren's BootCD PE [Hirens] | NHV Boot [NHV] | FieldOps Pro Community v0.6.0 | FieldOps Pro Enterprise v0.6.0 |
|-----------|:---:|:---:|:---:|:---:|:---:|
| **Boot & toolkit** | | | | | |
| Multi-tool bootable USB | yes | yes | yes | yes | yes |
| Windows PE environment | yes | yes | yes | yes | yes |
| Live Linux diagnostics | yes | partial | yes | yes | yes |
| ISO ecosystem (Ventoy-compatible) | partial | partial | partial | yes | yes |
| **Diagnostics** | | | | | |
| Hardware diagnostics | yes | yes | yes | yes | yes |
| Network repair tools | yes | yes | yes | yes | yes |
| Disk analysis | yes | yes | yes | yes | yes |
| **Compliance** | | | | | |
| Per-machine compliance report | — | — | — | ANSSI only | All 4 frameworks |
| ANSSI 42-measure assessment | — | — | — | yes | yes |
| NIS2 Article 21 + IR 2024/2690 mapping | — | — | — | — | yes |
| ISO/IEC 27001:2022 Annex A mapping | — | — | — | — | yes |
| RGS v2.0 mapping (Public Sector Edition) | — | — | — | — | yes |
| Confidence-rated cross-references | — | — | — | — | yes |
| Honest coverage-gap reporting | — | — | — | — | yes |
| **Fleet** | | | | | |
| Fleet aggregation | — | — | — | basic | yes |
| Fleet drift over time | — | — | — | — | yes |
| Per-machine drift detection | — | — | — | — | yes |
| Per-framework drift view | — | — | — | — | yes |
| Privacy-preserving fleet identifiers | — | — | — | — | yes |
| Anonymized export mode | — | — | — | — | yes |
| **AI** | | | | | |
| AI-narrated reports | — | — | — | — | yes |
| Tiered model selection (cost reduction) | — | — | — | — | yes (40-60% savings) |
| Per-invocation cost ceilings | — | — | — | — | yes |
| Per-fleet cost ceilings (day, month) | — | — | — | — | yes |
| Severity classification | — | — | — | — | yes |
| Remediation playbook validation | — | — | — | — | yes |
| Graceful degradation (AI optional) | — | — | — | — | yes |
| **Audit and governance** | | | | | |
| Production-grade audit logging (JSON Schema) | — | — | — | — | yes |
| Property-tested rule evaluators | — | — | — | yes | yes |
| Test suite (Pester 5.x) | — | — | — | yes | yes |
| Audit tests (ASCII, license headers, no API keys) | — | — | — | yes | yes |
| **Commercial** | | | | | |
| Dual-license model (open + commercial) | — | — | — | n/a | yes |
| Commercial support path | — | — | — | community | paid Enterprise |
| Public design documentation (this document) | — | — | — | yes | yes |
| Brand declaration (BRAND.md) | — | — | — | yes | yes |
| Semantic Versioning commitment | — | — | — | yes | yes |
| Security disclosure process | — | — | — | yes | yes |
| Anonymized demo dataset | — | — | — | partial | yes |
| **Internationalization** | | | | | |
| French language support | partial | partial | partial | yes | yes |
| English language support | yes | yes | yes | yes | yes |
| Locale routing architecture | — | — | — | yes | yes |

**Methodological note.** Capability assessments for the three incumbents reflect publicly documented features as of May 2026, drawn from each project's own homepage and documentation. Where assessments could be contested, the assessment is conservative: only ticked where the incumbent's documentation explicitly describes the capability. FieldOps Pro assessments reflect the target state at v0.6.0 ship per this design document.

**The defensible gap.** Of the ~40 capabilities listed, the three incumbents collectively address ~13 (basic toolkit, diagnostics, English support). FieldOps Pro Community addresses ~22 capabilities at v0.6.0 (adding ANSSI compliance, locale architecture, tested foundation, governance documents). FieldOps Pro Enterprise addresses all ~40 capabilities. The 27-capability gap between FieldOps Pro Enterprise and the closest incumbent is the commercial moat.

---

**END OF PHASE 6 DESIGN DOCUMENT**

*v0.6.0-design.draft.1 · Published 25 May 2026 · 80 numbered requirements · 97 numbered deliverables · 73 success criteria · 44 risks · 23 open questions · 6 chapters · 8 appendices*
