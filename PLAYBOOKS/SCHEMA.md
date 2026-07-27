# Remediation Playbook Schema

Authoring contract for `PLAYBOOKS/RB-*.md`. The machine-readable version is
[`schemas/playbook-frontmatter.json`](../schemas/playbook-frontmatter.json);
this document explains the reasoning the schema cannot carry.

FieldOps Pro - Phase 6, Stream 6.5 (6.5-D5, 6.5-R8)

## Why playbooks are validated

The AI client can be asked to validate that a response cites a real remediation
procedure (`Invoke-FieldOpsAI -ExpectPlaybookReference`). When it is, the client
extracts the playbook ID from the response, resolves it to a file, parses the
front matter, and checks conformance. The outcome lands on the result object as
`PlaybookRef` / `PlaybookValid` and in the audit record as `playbook_ref` /
`playbook_valid`.

An unchecked citation is worse than no citation: it reads as authoritative and
sends a technician looking for a document nobody wrote. Validation is what turns
a citation into a claim.

`PlaybookValid` is three-state and callers must treat it as such:

| Value | Meaning |
|-------|---------|
| `$null` | Not checked -- the call did not pass `-ExpectPlaybookReference` |
| `$false` | Checked, and the citation does not resolve to a conformant, current playbook |
| `$true` | Checked and sound |

A caller that collapses `$null` and `$false` will silently treat every
unvalidated call as clean.

## File naming

One playbook per file, named for its ID: `RB-AV-001` lives in `RB-AV-001.md`.
The validator resolves by filename, then confirms the front matter's `id` agrees.
A disagreement fails validation -- that drift is precisely what would make a
citation resolve to the wrong procedure.

## ID allocation

Pattern: `RB-<2-4 letter category>-<3-digit serial>`

| Prefix | Domain |
|--------|--------|
| `RB-AV` | Anti-malware |
| `RB-BL` | BitLocker / encryption |
| `RB-FW` | Firewall |
| `RB-UAC` | User Account Control |
| `RB-WU` | Windows Update |
| `RB-NET` | Networking |
| `RB-CRED` | Credentials |
| `RB-AUD` | Auditing / logging |

> **On `AUD` rather than `AUDIT`.** The ID pattern admits 2-4 letters, so
> `RB-AUDIT-*` could never match it. The Phase 6 design doc listed that category
> next to the very pattern forbidding it, and `schemas/ai-audit-record.json` had
> already shipped the 2-4 pattern for `playbook_ref` under schemaVersion 1.1.
> The published schema wins; the category is `AUD`. A test asserts both schemas
> still declare the same pattern, so they cannot drift apart again.

Serials are allocated sequentially within a category, starting at `001`.

**IDs are permanent.** Audit records and AI responses reference them
indefinitely, so a retired playbook is never deleted and its ID is never reused.
Mark it `deprecated: true` (optionally with `supersededBy`) and leave the file in
place: historical audit records stay interpretable, while the validator stops
accepting it as a citation for new recommendations.

## Front matter

Fenced by `---` on the first line and a matching `---` below. Required fields:

| Field | Type | Notes |
|-------|------|-------|
| `id` | string | Must match the pattern and the filename |
| `title` | string | 8-120 chars, imperative |
| `category` | enum | Must equal the id's category segment |
| `severity` | enum | `critical` / `high` / `medium` / `low`, lowercase |
| `estimatedDurationMinutes` | integer | 1-480 |
| `revertable` | boolean | See below |
| `schemaVersion` | string | `"1.0"`, quoted |

Optional: `prerequisites` (list), `relatedRules` (map), `deprecated` (boolean),
`supersededBy` (playbook ID).

### On `severity`

This is the severity of the **condition being remediated**, not the risk of
performing the remediation. It is also a different vocabulary from the client's
response severity classification (`INFORMATIONAL` / `ADVISORY` /
`ACTION_REQUIRED` / `CRITICAL`, 6.5-R7), which describes an AI response rather
than a finding. The two are unrelated; do not map one onto the other.

### On `revertable`

`true` only when the playbook documents a **complete** rollback returning the
machine to its prior state. This flag gates whether a procedure may be offered
as an automated fix, so it is deliberately conservative. When in doubt, `false`.

Documenting a rollback that returns the machine to a *less secure* state is
still correct -- see RB-AV-001 -- but say so plainly in the Rollback section.

### On `relatedRules`

```yaml
relatedRules:
  anssi:    [R8]
  nis2:     [Art21-2-c]
  iso27001: [A.8.7]
```

Every framework key is optional. **ANSSI is the only framework live today.** The
`nis2`, `iso27001` and `rgs` keys are carried as data ahead of Stream 6.2
activating them -- populate them if you know the mapping, but nothing reads them
yet, and a wrong mapping now becomes a wrong cross-reference later.

## Front matter parser limits

PowerShell 5.1 ships no YAML parser, and the toolkit must run air-gapped off a
USB stick, so the client parses a bounded subset by hand:

```yaml
key: scalar
key: [a, b]
key:
  - item
key:
  sub: [a, b]
```

Anything else -- tabs for indentation, nested containers more than one level
deep, multi-line strings, anchors -- makes the parser return `$null`, which
fails validation.

This is fail-closed on purpose. A half-understood front matter that happened to
yield the required keys would validate, and the point of the check is to refuse
to vouch for a document the parser did not actually read. **A playbook the
parser cannot handle is a playbook to reformat, not a parser to extend.**

## Body

The front matter is the contract; the body is for the technician. No structure is
enforced, but the useful shape is:

1. **When to use this** -- and, as importantly, when *not* to
2. **Verify the condition first** -- the check that confirms the diagnosis
3. **Procedure** -- numbered, each step independently verifiable
4. **Rollback** -- concrete commands, honest about what reverting costs
5. **If it does not hold** -- the two or three usual root causes
6. **Related** -- framework references in prose

The "when not to use this" and "if it does not hold" sections are what separate a
playbook from a snippet. A technician following step 3 of a procedure that never
applied to their machine is worse off than one with no playbook at all.

## Keeping playbooks honest

Procedures drift from reality as Windows changes (6.5-Risk-5). A playbook is
reviewed when:

- a step stops working on a currently supported Windows build
- the cmdlet or registry path it uses is deprecated
- a technician reports the rollback did not restore prior state

Update in place, keeping the ID. Bump `schemaVersion` only when this
front-matter contract changes -- not when the procedure text changes.
