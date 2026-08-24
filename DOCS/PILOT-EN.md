# FieldOps Pro Pilot

**IT hygiene diagnostic — ANSSI framework, 42 rules**

Product version: see `CONFIG/version.json` · Licence: Apache 2.0
Companion document in French: `DOCS/PILOT-FR.md`

---

## 1. What this is

FieldOps Pro is a portable diagnostic tool. It assesses a Windows workstation
against the 42 rules of ANSSI's *Guide d'hygiène informatique*, then produces a
paginated, signable A4 report intended to be handed to a client.

It runs from a USB stick. **Nothing is installed on the machine being examined.**

What sets it apart comes down to a single decision: the report carries **three**
verdicts, not two.

| Verdict | Meaning |
|---------|---------|
| **Verified compliant** | The control was observed in place. |
| **Partially verified** | Evidence is incomplete: probe unavailable, hardware absent, or human judgement required. |
| **Out of technical scope** | The rule is not something an endpoint audit can establish. |

A machine with no TPM cannot demonstrate hardware-backed authentication.
Calling that a pass is false; calling it a failure implies a defect that is not
there. An auditor needs to know **which rules were actually verified** — which is
exactly what most compliance dashboards destroy by showing only green and red.

That is the product. Everything else supports it.

---

## 2. What the pilot asks of you

- **Twenty workstations, minimum.** Below that the spread of configurations is
  too narrow for the results to teach you anything.
- **Show at least one report to a real client.** This is the one thing our tests
  cannot establish: a report that satisfies its author and a report that survives
  a client's scrutiny are different objects.
- **Written feedback within six weeks.** The questions are in section 6. One page
  is enough.

No exclusivity is asked, no commitment to continue, no public reference. You can
stop the pilot without giving a reason.

---

## 3. What you get

- **The pilot is free.** It is not a crippled trial: the product is published
  under Apache 2.0 and you could have it regardless. What the pilot adds is
  direct access to the author.
- **Named support** by email, within 48 business hours.
- **Fixes during the pilot**, ahead of the rest of the roadmap.
- **Your findings recorded in the changelog**, if you want them to be and in
  whatever form you choose, including anonymously.

---

## 4. Protocol

1. **Extract** the release archive onto a USB stick. No installation.
2. **Launch** `FieldOps-Launcher.ps1` and run the self-test. It must report
   **READY**. If it reports caveats, send us that output before going further —
   that is already a pilot result.
3. **Collect** on each workstation: SecurityScan, PCHealth, NetRepair.
4. **Produce** the ANSSI diagnostic report. It opens as HTML and converts to PDF.
5. **Complete** the attestation page: your name, your company, place and date.
   Twelve fields, the only writable elements in the document.
6. **Hand a report to a client**, under the conditions in which you normally
   would.

Allow roughly ten minutes per workstation, most of it automatic collection.

### Data confidentiality

The diagnostic and the report are **entirely local**. No data leaves the machine
being examined.

The tool does also carry AI-assisted analysis features, which transmit a
configuration summary to an external provider. **They activate only if you
configure an API key yourself**: with no key, they do not run. For a pilot, we
recommend not configuring one.

---

## 5. What the report does not establish

This section matters as much as the ones before it. A pilot that discovers these
limits in front of a client is a failed pilot.

- **This is neither an ANSSI certification nor a qualification.** ANSSI alone is
  empowered to issue those. The document says so on its cover and in its
  conclusion.
- **The project has no affiliation with ANSSI**, no accreditation, no
  partnership, no approval. The *Guide d'hygiène informatique* is a public
  document; we reference it, nothing more.
- **Sixteen of the forty-two rules are out of scope by design**: training, HR
  procedures, network architecture, governance. No tool running on an isolated
  workstation can attest to them. They appear in the report so the framework
  stays complete, in an annex and without a verdict.
- **The report describes one machine at one moment.** Any later configuration
  change invalidates the finding. The report timestamps each of its sources and
  flags any collection older than thirty days.
- **The tool's console remains very largely French.** The report, by contrast, is
  fully bilingual and verified as such by the test suite.

---

## 6. The feedback we want

Six questions. Answer briefly; short and blunt beats an evaluation report.

1. **Did you show it to a client? What did they say?**
   *The question that matters. The other five are secondary.*
2. Was "partially verified" understood, or did you have to explain it? If so, how
   did you put it?
3. What did you look for in the report and fail to find?
4. What did you find in it that was useless, or wrong?
5. Out of twenty workstations, how many reports would you have handed over as
   they were, with no edit?
6. Would you charge for it? How much, and to which client?

Any format: email, document, or a twenty-minute call if you prefer.

---

## 7. Contact and what follows

Ousman Dorley — <170084095+msdorley@users.noreply.github.com>

Defects and requests: the project's public repository, or direct email during the
pilot.

Terms for later commercial use are open and documented in
`COMMERCIAL-LICENSING.md`. They do not condition this pilot and need not be
discussed in order to take part.
