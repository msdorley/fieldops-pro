# Commercial licensing: brief for counsel

FieldOps Pro - Phase 6, Stream 6.4 (6.4-D2, 6.4-D21)

**This document is not a licence, not an offer, and not legal advice.** It is
preparation: the decisions the owner must make, and the questions a qualified
software lawyer needs answered, before any commercial licence exists.

No clause text appears here deliberately. A file that looks contract-shaped
tends to reach a customer during a fast-moving deal, and a banner is a weak
defence against that. Nothing in this repository should be signable.

**This file is public on purpose.** It is a working brief and an unsettled
position, and it stays visible for the same reason the report distinguishes
`pv` from `cv`: a supplier who has not yet worked out where their liability
sits should say so, rather than let a customer find out during a contract
review.

---

## 1. Read this part first

**Apache 2.0 already permits commercial use.**

This is the most common and most expensive misunderstanding about
dual-licensing, and getting it wrong shapes a pricing model that cannot work.

Dual-licensing is a well-known pattern under the **GPL**, where the open licence
is copyleft: a company that wants to embed the code without open-sourcing their
own product must buy a commercial licence. The copyleft obligation is what
creates the demand.

**Apache 2.0 is permissive and creates no such obligation.** Under the licence
already published in this repository, anyone may:

- use FieldOps Pro commercially, including selling services built on it
- modify it and keep their modifications entirely private
- redistribute it inside a closed-source product
- sublicense it

subject only to attribution, preserving `NOTICE`, and stating that files were
changed (section 4).

So a commercial licence for FieldOps Pro **cannot** be sold on the basis of
"permission to use it commercially." That permission is already granted, free,
irrevocably. A prospect's lawyer will notice this immediately, and a pricing
model built on it will not survive the first procurement review.

### What a commercial licence can actually offer

Things Apache 2.0 explicitly withholds or disclaims:

| Offer | Basis in Apache 2.0 |
|-------|---------------------|
| **Warranty** | section 7 disclaims all warranties. A commercial agreement can provide one |
| **Liability** | section 8 disclaims liability entirely. A commercial agreement can accept a capped amount |
| **Indemnity** | Not granted. Enterprises frequently require IP indemnification |
| **Support and SLA** | Not addressed at all. Response times, escalation, named contacts |
| **Trademark use** | section 6 grants no trademark rights. A partner reselling under the name needs a separate grant |
| **Relief from attribution** | section 4 obligations can be waived by separate agreement for an OEM embedding the code |
| **Proprietary features** | Code never published under Apache is not covered by it |

**For a French enterprise buyer, the first three are usually the actual
purchase.** Procurement is buying a counterparty who carries risk. The software
is often already acceptable under Apache; what is missing is somebody to hold
responsible.

That should shape the offering: this is closer to a support-and-indemnity
subscription than a licence sale.

---

## 2. Decisions the owner must make before engaging counsel

A lawyer cannot answer these. Bringing answers converts an expensive
exploratory conversation into a short drafting brief.

### Commercial model

- [ ] Perpetual licence, annual subscription, or support contract?
- [ ] Priced per technician, per endpoint assessed, per site, or flat?
- [ ] Does the price include updates? For how long?
- [ ] Is there a free tier for small operators, and where is the boundary?

### Support commitment

- [ ] Response time offered, and hours of coverage
- [ ] Realistic obligation for a **single-maintainer** project. Overcommitting here is the fastest route to breaching your own contract
- [ ] What happens if the maintainer is unavailable for a period

### Risk

- [ ] Liability cap: a multiple of fees paid, or a fixed sum?
- [ ] IP indemnification: offered, and to what limit?
- [ ] Warranty: what exactly is warranted? "Conforms to documentation" is narrower and safer than "fit for purpose"
- [ ] Is professional indemnity insurance held? Most enterprise contracts require it, and its limit constrains what can safely be promised

### Territory and language

- [ ] Governing law and jurisdiction
- [ ] Is a French-language version required? For enforceability against a French counterparty this generally matters, and a translation is not a formality
- [ ] Which currency, and are contracts in scope for VAT / TVA

### Data protection

- [ ] With AI enabled, prompt content is transmitted to a third-party provider. Does that make the customer a controller and the provider a processor, and is a DPA needed in the chain?
- [ ] Does any customer data reach the maintainer at all? (Today: no. Keeping that true is worth far more than any clause about it)

---

## 3. Questions for counsel

Grouped so a first meeting can be short.

**Structure**

1. Given Apache 2.0 is already published, what is the cleanest structure for a paid offering - a services and support agreement, a separate licence for proprietary components, or both?
2. Can a licence already granted under Apache 2.0 be withdrawn or narrowed for future versions? (Believed not for versions already released - please confirm, because the answer determines whether open-core is viable at all.)

**Contributions**

3. If a third party contributes under Apache 2.0, can their contribution be included in a proprietary commercial build?
4. Is a Contributor Licence Agreement needed, and should it assign copyright or grant a licence? **This matters before the second contributor arrives, not after** - retroactive CLAs require tracking down everyone who ever sent a patch.

**Risk**

5. What liability cap is realistic and enforceable for a sole trader in this jurisdiction?
6. Does French law limit how far liability may be excluded in a business-to-business contract?
7. What entity structure should hold this - is contracting personally acceptable, and does that need to change before the first customer?

**Compliance claims**

8. The product assesses against a published ANSSI guide and explicitly disclaims endorsement. Does describing it as "an ANSSI compliance toolkit" create any regulatory or advertising exposure?
9. Does producing a compliance report for a customer create any advisory duty or professional liability?

**Trademark**

10. Should "FieldOps Pro" be registered, in which classes, and in which territories?

---

## 4. The open-core boundary (6.4-D21)

Deciding this before code accretes across the line is much cheaper than
untangling it afterwards. Recorded now; no separate repository exists yet.

### Free, under Apache 2.0 - permanently

Everything shipped in v0.6.0 stays free. Withdrawing something previously
published would be seen for what it is, and the reputational cost would exceed
any revenue.

- All 42 ANSSI evaluations, and the report
- All diagnostic engines
- Snapshot, diff and rollback
- Both languages
- Remediation playbooks
- The full test suite

**The compliance report is the product and it stays free.** A crippled
assessment behind a paywall would undermine the honesty that makes the report
credible in the first place.

### Candidates for a commercial tier

Things that are valuable to an organisation running many machines, and
irrelevant to a single technician:

- Central aggregation across sites over time
- Multi-tenant reporting for a managed service provider
- Integration with a customer's existing systems (SIEM, ticketing, MDM)
- Signed reports under an organisation's own identity
- Custom rule sets beyond the ANSSI 42
- Priority support and a response commitment

### The technical rule that keeps them separable

**A commercial feature may consume the open core's published outputs. It may
never be required for the open core to function.**

Concretely: the free toolkit must produce a complete, valid, signed report on a
machine that has never heard of the commercial tier. Any commercial component
reads `report-data.json`, `LOGS\*.json` or the audit log - the same published
contracts any third party could read.

This rule is worth holding to because it is testable. If the free suite passes
in a checkout with no commercial code present, the boundary is intact. It also
means the commercial tier is built on the same public interfaces documented in
`DOCS/EXTENDING.md`, which keeps them honest.

---

## 5. What must be true before any commercial licence exists

- [ ] Reviewed and drafted by a qualified software lawyer in the relevant jurisdiction
- [ ] Commercial decisions in section 2 answered by the owner, not by counsel guessing
- [ ] Entity and insurance position settled
- [ ] French version prepared if selling into France
- [ ] The support commitment checked against what one person can actually deliver

**Until every box is ticked, FieldOps Pro is Apache 2.0 and nothing else.**
That is a coherent, defensible position, and there is no deadline forcing it to
change.

---

## Related

- [LICENSE](LICENSE) - Apache 2.0, the licence in force
- [NOTICE](NOTICE) - attribution, trademark reservation, ANSSI non-endorsement
- [BRAND.md](BRAND.md) - the claims that are defensible, and the ones that are not
- [DOCS/EXTENDING.md](DOCS/EXTENDING.md) - the published contracts a commercial tier would build on
