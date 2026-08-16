# Brand and naming

FieldOps Pro - Phase 6, Stream 6.4 (6.4-D14)

How the product is named, described and written about. This exists so that the
report a customer receives, the documentation they read, and the repository they
audit all sound like the same product.

---

## 1. The name

**FieldOps Pro** -- two words, both capitalised, capital P on Pro.

| Correct | Wrong |
|---------|-------|
| FieldOps Pro | Fieldops Pro, FieldOPS Pro, Field Ops Pro |
| FieldOps Pro | fieldops-pro *(in prose)* |

`fieldops-pro` is the repository and release-artifact name. It is correct in a
URL, a filename, or a command. It is wrong in a sentence.

The name is not translated. In French documentation it stays **FieldOps Pro**.
A test whitelists it as a permitted non-translated string in the locale bundle
rather than silently dropping it, so a genuine untranslated string cannot hide
behind the brand exception.

### Trademark

Apache 2.0 **section 6 grants no trademark rights**. The `NOTICE` file states
this. A fork may use the code; it may not present itself as FieldOps Pro.

---

## 2. What it is, in one line

> A portable Windows diagnostic and ANSSI compliance toolkit that runs from a USB
> stick, with no installation on the machine being examined.

Longer, when there is room:

> FieldOps Pro evaluates a Windows machine against the 42 rules of the ANSSI
> *Guide d'hygiene informatique* and produces a signed, bilingual report that
> distinguishes what was verified from what could not be. It runs air-gapped from
> a USB stick, installs nothing, and works on any hardware.

**Lead with the compliance report.** Diagnostics are the mechanism; the evidence
is the product.

---

## 3. Claims we make, and how they are worded

Everything below is defensible. The wording is deliberate, and loosening it makes
it false.

| Claim | Wording that is accurate |
|-------|--------------------------|
| ANSSI coverage | "Evaluates against the 42 rules of the ANSSI Guide d'hygiene informatique" |
| Portability | "Runs from a USB stick. Nothing is installed on the target machine" |
| Offline | "Every core function works air-gapped" |
| Hardware | "Runs on any Windows PC. Probes that cannot answer degrade rather than guess" |
| Bilingual | "French and English at full parity, enforced by test" |
| Report integrity | "Each report embeds a SHA-256 of its own delivered bytes" |
| AI | "Optional. No feature requires it. It never decides compliance" |

### What we never say

- **"ANSSI certified" or "ANSSI approved."** It is neither. The `NOTICE` file
  disclaims endorsement explicitly. Implying otherwise is a false claim about a
  government agency, and a French enterprise buyer will know it is false
- **"Guarantees compliance."** It evaluates and reports. Compliance is the
  customer's, and depends on rules no endpoint scan can assess
- **"Tamper-proof."** The signature is a correspondence check between a report
  and its content. Someone who regenerates the report regenerates the hash
- **"Anonymous."** The AI audit log uses a **pseudonymous** technician id -- a
  hash, which is stable and therefore linkable
- **"AI-powered diagnostics."** The diagnostics are deterministic. The AI
  narrates

**The discipline behind this table is the product's actual differentiator.** A
toolkit that reports honestly about its own limits is the one an auditor can
use. Overclaiming in the marketing undermines the exact quality the software was
built to have.

---

## 4. Vocabulary

| Use | Not |
|-----|-----|
| technician | user, operator |
| the machine, the target machine | the endpoint, the asset |
| finding | issue, problem |
| verified / partially verified / out of scope | pass / warn / fail |
| report | output, results |
| playbook | runbook, SOP |
| stick | drive, key, dongle |

The status vocabulary matters most. `cv` / `pv` / `hp` are **not** a traffic
light, and describing them as pass/warn/fail collapses the distinction the whole
product exists to preserve.

### French

French documentation and reports use the ANSSI guide's own terminology:
*conforme verifie*, *partiellement verifie*, *hors perimetre*. Where the guide has
a term, we use the guide's term rather than a better-sounding synonym -- an
auditor reading the report should recognise the vocabulary from the guide they
already know.

---

## 5. Voice

**Precise, plain, and unafraid of a limitation.**

Write for a competent technician who is short of time. State what a thing does,
what it does not do, and what happens when it fails. Explain the reasoning behind
a decision that would otherwise look arbitrary.

Do not use: *seamless, robust, powerful, cutting-edge, revolutionary,
enterprise-grade, best-in-class, leverage, unlock, empower*.

Prefer a concrete fact to an adjective:

> Not: "Robust hardware compatibility"
> But: "Runs on any Windows PC. Where a probe cannot answer -- no TPM, no
> BitLocker, a VM with no SMART data -- the affected rule reports as partially
> verified rather than failing or reporting a false pass."

The second is longer and does more work. It tells the reader what actually
happens, which is what they wanted to know.

---

## 6. In the interface

- Console output is ASCII: `[OK]`, `[WARN]`, `[FAIL]`, `[INFO]`. No emoji, no box
  drawing, no colour as the only signal -- WinPE and redirected output are both
  real environments
- Every user-visible string comes from the locale bundle. A hardcoded English
  string is a test failure
- Errors say what failed, why, and what to do next. "An error occurred" is not an
  error message

---

## 7. Documentation conventions

- Second person for instructions: "Run the self-test", not "The user should run"
- Present tense: "The report embeds a SHA-256", not "will embed"
- Commands in fenced blocks with the language tagged
- `--` rather than an em dash in any file under `SCRIPTS\`; audit A1 fails on
  non-ASCII source
- Cross-references by path (`DOCS/INSTALL.md`), not by phrases like "see above"

---

## Related

- `NOTICE` -- attribution, trademark reservation, ANSSI non-endorsement
- `DOCS/USING.md` -- the vocabulary in use
- `VERSIONING.md` -- how releases are numbered
