# Versioning policy

FieldOps Pro - Phase 6, Stream 6.4 (6.4-D11)

FieldOps Pro follows [Semantic Versioning 2.0.0](https://semver.org/), with the
qualifications below. The qualifications exist because "the public API" of a
diagnostic toolkit is not obvious, and leaving it undefined would make the
version number meaningless.

---

## 1. What the version number covers

For a toolkit with no library API, the things a customer can depend on are its
**outputs and its contracts**. These are the public surface:

| Surface | Example |
|---------|---------|
| Report data schema | `report-data.json` keys, `Summary.Total = 42` |
| AI audit record schema | `schemas/ai-audit-record.json`, `schemaVersion` |
| Playbook front-matter schema | `schemas/playbook-frontmatter.json` |
| Compliance status vocabulary | `cv`, `pv`, `hp` |
| Script parameters | `-Mode`, `-Language`, `-NoAI`, `-OutputRoot` |
| Directory layout | `SCRIPTS\`, `CONFIG\`, `REPORTS\`, `LOGS\` |
| Configuration keys | `TechnicianName`, `Language`, `AnthropicApiKey` |
| Locale bundle key names | `report.anssi.r14.name` |
| Exit codes | `0` success, `1` failure |

**Not covered**: internal function names, log line wording, HTML markup within
a report, and the specific prose the AI generates.

---

## 2. What each number means

### MAJOR -- something that was working stops working

- A published schema drops or renames a field
- A status value changes meaning
- A script parameter is removed or its semantics change
- The directory layout changes such that an existing stick stops working
- A configuration key is removed
- The minimum PowerShell version rises

### MINOR -- new capability, existing behaviour intact

- A new diagnostic engine, playbook or language
- A new optional parameter with a backward-compatible default
- An **additive** schema field, where consumers ignoring it still work
- A new report section

### PATCH -- a defect fixed, no contract change

- A rule evaluated wrongly and now evaluates correctly
- A translation corrected
- A crash fixed
- Performance improved

---

## 3. The rule that governs the rest

**A compliance verdict changing is not automatically a MAJOR change -- but it is
always a changelog entry that says so explicitly.**

When R32 was fixed, machines that had reported `cv` began reporting `pv`. No
schema changed and no parameter changed, so by the letter of SemVer it was a
PATCH. But a customer holding a report that said "compliant" needs to know that
the same machine now says otherwise, and why.

The policy: **any change that can alter a rule's verdict on unchanged hardware
gets a named entry in the changelog under Fixed, stating which rule, in which
direction, and why the new answer is the correct one.** Version arithmetic is
not a substitute for telling someone their evidence changed.

---

## 4. Schema versioning

Published schemas carry their own `schemaVersion`, independent of the product
version. A consumer reads the schema version, not the product version.

- **Additive field** -- minor schema bump (`1.1` to `1.2`), product MINOR
- **Removed or renamed field** -- major schema bump (`1.x` to `2.0`), product MAJOR
- **Description or constraint tightened without changing valid data** -- no bump

A drift test ties the code constants to the published schema, so a validator and
its schema cannot silently disagree about what is required.

---

## 5. Pre-1.0

FieldOps Pro is pre-1.0. Under SemVer, `0.x` makes no compatibility promise at
all.

**We do not use that latitude as an excuse.** The rules above are applied as
written during 0.x, with one exception: a breaking change increments MINOR
(`0.6.0` to `0.7.0`) rather than MAJOR, and is called out in the changelog under
its own heading.

`1.0.0` will be declared when the schemas have been stable across two consecutive
minor releases with no breaking change -- not on a date, and not because a
version number looks more marketable.

---

## 6. Version strings

Format: `MAJOR.MINOR.PATCH`, e.g. `0.6.0`. Git tags carry a `v` prefix: `v0.6.0`.

Pre-release: `0.6.0-rc.1`. Pre-releases are for verification on real hardware and
are never shipped to a customer.

The version appears in the release tag, the release zip filename, `CHANGELOG.md`,
and the report footer. `RELEASE.md` lists these as an explicit checklist because
a version string that disagrees with itself across artifacts is the kind of
detail an evaluator notices and draws conclusions from.

---

## Related

- `CHANGELOG.md` -- what actually changed in each version
- `RELEASE.md` -- how a release is cut
- `DOCS/EXTENDING.md` -- the contracts a contributor must not break
