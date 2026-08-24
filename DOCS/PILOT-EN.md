# FieldOps Pro Pilot

**Portable Windows field toolkit for work on the machine in front of you**

Product version: see `CONFIG/version.json` · Licence: Apache 2.0
Companion document in French: `DOCS/PILOT-FR.md`

---

## 1. What this is

FieldOps Pro runs from a USB stick and puts sixteen tools in the hands of the
technician standing at a machine: hardware and disk diagnostics, network repair,
security posture, software deployment, directory enrolment, VPN setup, fleet
reporting, incident reports, remediation playbooks, guided self-healing,
configuration diff, and ANSSI compliance assessment.

**Nothing is installed on the machine being examined.** Everything works offline.

### What sets it apart

Field tools answer *pass* or *fail*. When a probe cannot run, when the hardware
is absent, or when the answer needs human judgement, they pick one anyway and
move on.

FieldOps Pro has a third verdict, and it is the reason to use it.

| Verdict | Meaning |
|---------|---------|
| **Verified** | The control was observed directly. |
| **Could not determine** | Evidence is incomplete: probe unavailable, hardware absent, or human judgement required. |
| **Out of scope** | Not something an endpoint examination can establish. |

A machine with no TPM cannot demonstrate hardware-backed authentication. Calling
that a pass is false; calling it a failure implies a defect that is not there.

### Where that discipline stands today

Let us be precise, because this is exactly what a pilot should test.

The compliance module applies it in full, across all 42 rules. **The other
engines do not yet**: they do detect what they could not establish, then discard
it before display. Bringing them under the same contract is the next piece of
work, starting with the security engine.

Put plainly: the promise holds over part of the product, and your feedback
decides the order in which it reaches the rest.

---

## 2. What the pilot asks of you

- **Twenty workstations, minimum**, on your real jobs. Below that the spread of
  configurations is too narrow to learn anything.
- **Use the tools that serve you**, not the ones we put forward. If you never
  open the compliance module, that is a result, not a failed pilot.
- **If compliance is relevant to you: show at least one report to a client.**
  This is the one thing our tests cannot establish — a report that satisfies its
  author and a report that survives a client's scrutiny are different objects.
- **Written feedback within six weeks.** The questions are in section 6. One page
  is enough.

No exclusivity, no commitment to continue, no public reference. You can stop the
pilot without giving a reason.

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

1. **Extract** the archive onto a USB stick. No installation.
2. **Launch** `FieldOps-Launcher.ps1` and run the self-test. It must report
   **READY**. If it reports caveats, send us that output before going further —
   that is already a pilot result.
3. **Carry the stick on your jobs** for six weeks and use it wherever it earns
   its place. We are not prescribing an order: what you reach for unprompted
   tells us more than a guided tour would.
4. **If compliance is relevant to you**: collect with SecurityScan, PCHealth and
   NetRepair, produce the ANSSI report, complete the attestation page (twelve
   fields, the only writable elements in the document), and hand it to a client
   under your normal conditions.

Allow roughly ten minutes per workstation for the full compliance chain, most of
it automatic collection. The other tools stand alone and are used as needed.

### Data confidentiality

Diagnostics and reports are **entirely local**. No data leaves the machine being
examined.

The tool does also carry AI-assisted analysis features, which transmit a
configuration summary to an external provider. **They activate only if you
configure an API key yourself**: with no key, they do not run. For a pilot, we
recommend not configuring one.

---

## 5. What the product does not establish

This section matters as much as the ones before it. A pilot that discovers these
limits in front of a client is a failed pilot.

- **The third verdict does not yet cover the whole product.** It is complete in
  the compliance module and absent from the other engines, which still show a
  binary result. That is the principal limitation, and it is being worked on.
- **The compliance report is neither an ANSSI certification nor a
  qualification.** ANSSI alone is empowered to issue those. The document says so
  on its cover and in its conclusion.
- **The project has no affiliation with ANSSI**, no accreditation, no
  partnership, no approval. The *Guide d'hygiène informatique* is a public
  document; we reference it, nothing more. The rest of the toolkit depends on no
  framework and no country.
- **Sixteen of the forty-two rules are out of scope by design**: training, HR
  procedures, network architecture, governance. No tool running on an isolated
  workstation can attest to them.
- **A report describes one machine at one moment.** Any later configuration
  change invalidates the finding. The report timestamps each of its sources and
  flags any collection older than thirty days.
- **The console remains very largely French.** The compliance report, by
  contrast, is fully bilingual and verified as such by the test suite.

---

## 6. The feedback we want

Six questions. Answer briefly; short and blunt beats an evaluation report.

1. **Which tools did you actually use, and which did you never open?**
   *The question that matters. A tool nobody opens does not exist.*
2. Was there a moment when the tool told you it could not reach a conclusion?
   Did that help, or irritate?
3. What did you have to do with another tool because this one did not do it, or
   did it badly?
4. If you handed a compliance report to a client: what did they say?
5. Across twenty jobs, how many times would you have picked the stick up again
   if it had not been provided?
6. Would you charge for it? How much, for which part, and to which client?

Any format: email, document, or a twenty-minute call if you prefer.

---

## 7. Contact and what follows

Ousman Dorley — <170084095+msdorley@users.noreply.github.com>

Defects and requests: the project's public repository, or direct email during the
pilot.

Terms for later commercial use are open and documented in
`COMMERCIAL-LICENSING.md`. They do not condition this pilot and need not be
discussed in order to take part.
