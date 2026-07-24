# FieldOps Pro - French Render Parity (Stream 6.1-R8)

Comparison of the rendered French ANSSI report before and after Stream 6.1,
classifying every difference as intentional or regression.

Requirement 6.1-R8 states that the French report at the end of Stream 6.1 must
be visually indistinguishable from the v0.5.2 reference output. The intent of
that requirement is **do not regress during the refactor** — not *preserve
existing defects*. Stream 6.1's stated goal is the removal of hardcoded French
from the rendering pipeline, and several of those hardcoded strings were
accent-stripped copies of correctly accented bundle values. Routing them
therefore changes the output by design.

This document records what changed, and why each change is acceptable.

## Method

Recall is not evidence. Both versions were rendered from identical input data
and diffed mechanically, so that changes nobody remembered making would still
surface. That is not hypothetical: the diff found an emphasis change that the
originating pull request description had failed to mention (see E2 below).

```powershell
# 1. Worktree at the v0.5.2 tag
git worktree add C:\Dev\fieldops-v052 617a879

# 2. Render both from the SAME data file
& C:\Dev\fieldops-v052\SCRIPTS\Compliance\Invoke-ANSSIDiagnostic-POC.ps1 `
    -DataFile <data> -OutputDir <old> -NoPdf -NoOpen

& C:\Dev\fieldops-pro\SCRIPTS\Compliance\Invoke-ANSSIDiagnostic-POC.ps1 `
    -DataFile <data> -OutputDir <new> -Language fr -NoPdf -NoOpen

# 3. Normalise the hash block and the <style> block, then diff
#    (the hash necessarily differs: it digests changed content)
Compare-Object $oldLines $newLines -SyncWindow 12
```

Holding the data file constant isolates presentation differences, which is
what R8 is about.

## Result

| | |
|---|---|
| Document size | 60,832 -> 60,863 bytes |
| Differing lines | 47 (of ~900) |
| Distinct logical changes | 23 |
| Regressions found | 0 |
| Changes requiring a judgement call | 2 (both recorded below) |

No structural, layout, pagination or data differences. Page count, module
ordering, rule ordering, status counts and the compliance spectrum are
byte-identical. All differences are textual.

---

## A. Diacritics restored (~13 changes)

The largest category. The template carried accent-stripped French; the bundle
holds the correctly accented text. Routing the template through the bundle
restores the diacritics.

| v0.5.2 | Stream 6.1 |
|---|---|
| `Diagnostic d'hygiene` | `Diagnostic d'hygiène` |
| `Numero de serie` | `Numéro de série` |
| `Systeme d'exploitation` | `Système d'exploitation` |
| `Spectre de conformite` | `Spectre de conformité` |
| `Verifie (CV)` | `Vérifié (CV)` |
| `Partiellement verifie (PV)` | `Partiellement vérifié (PV)` |
| `Hors perimetre (HP)` | `Hors périmètre (HP)` |
| `Perimetre du diagnostic` | `Périmètre du diagnostic` |
| `Integrite cryptographique` | `Intégrité cryptographique` |
| `Referentiel` | `Référentiel` |

**Assessment: intentional, and the point of the exercise.** Phase 5.2 exists to
produce French-perfect ANSSI reporting. A compliance document delivered to a
French enterprise with `securite` on its cover undermines the credibility of
everything inside it. These are corrections, not regressions.

## B. HTML entities became literal characters (~8 changes)

The template used HTML entities where the bundle carries the characters
directly.

| v0.5.2 source | Stream 6.1 source | Rendered |
|---|---|---|
| `&mdash;` | `—` | identical |
| `&middot;` | `·` | identical |
| `&laquo;&nbsp;ANSSI&nbsp;&raquo;` | `« ANSSI »` | identical |

**Assessment: byte-different, pixel-identical.** Both forms render the same
glyph in every browser and in the Edge headless PDF pipeline. The file is
UTF-8 with BOM and declares `<meta charset="UTF-8">`, so literal characters are
safe. No visual difference exists.

## C. Capitalisation normalised (2 changes)

| v0.5.2 | Stream 6.1 |
|---|---|
| `Guide d'Hygiene Informatique` | `Guide d'hygiène informatique` |

**Assessment: intentional correction.** ANSSI's own publication is titled
*Guide d'hygiène informatique* in sentence case. Title-casing a French document
title is an anglicism. For a report whose authority rests on faithfully
referencing the source framework, matching ANSSI's own typography matters.

## D. Wording, from canonical bundle text (5 changes)

Where the template's hardcoded string and the bundle's value differed in
phrasing, routing adopts the bundle's wording.

| Element | v0.5.2 | Stream 6.1 |
|---|---|---|
| `cover.disclaimerBody` | "Ce document n'est pas une certification ANSSI et ne constitue pas un avis juridique. Cartographie technique de la posture…" | "Le présent document ne constitue ni une certification ANSSI, ni un avis juridique. Il propose une cartographie technique de la posture…" |
| `conclusion.limit4` | "Date et etat observes a un instant T. Les modifications posterieures invalident le constat." | "État observé à un instant T. Toute modification ultérieure de la configuration invalide le constat." |
| `conclusion.integrityBody` | "…toute modification de ce document apres generation invaliderait cette signature" | "…toute modification ultérieure de ce document invaliderait cette signature" |
| `machineFields.makeModel` | `Fabricant · Modele` | `Fabricant / modèle` |
| `modules.VIII.title` | `Maintenir le SI a jour` | `Maintenir le système d'information à jour` |

**Assessment: intentional.** The bundle text is the reviewed, canonical
phrasing produced in Phase 5.2; the template strings were earlier drafts that
were never updated. The bundle versions use correct French legal register
("Le présent document ne constitue ni… ni…" rather than the clipped "Ce
document n'est pas…"), and module VIII now uses ANSSI's full term rather than
the "SI" abbreviation.

## E. Emphasis changes (2 changes — the judgement calls)

### E1. Perimeter sentence: emphasis narrowed to the figures

```
v0.5.2   …vérifie automatiquement <strong>7 règles d'hygiène ANSSI sur 42</strong> au niveau…
6.1      …vérifie automatiquement <strong>7</strong> règles d'hygiène ANSSI sur 42 au niveau…
```

**Why it changed.** The sentence is interrupted three times by computed counts.
The bundle holds it as a single value with `{cvCount}`, `{pvCount}` and
`{hpCount}` placeholders, because French and English order these clauses
differently — splitting the sentence into translatable fragments would produce
broken English word order. The counts are substituted wrapped in `<strong>`,
which preserves emphasis on the figures while keeping the sentence one
translatable unit.

**Assessment: accepted.** Emphasis on the figure rather than figure-plus-phrase
is defensible typography, and the alternative — fragmenting a sentence across
bundle keys — would guarantee a poor English render. The i18n correctness
outweighs the styling delta.

### E2. Limit 1: bold emphasis removed

```
v0.5.2   <li>Diagnostic informatif. <strong>Ne constitue pas une certification ANSSI</strong>,
             ni une attestation au sens du Guide d'Hygiene Informatique.</li>
6.1      <li>Diagnostic informatif. Le présent document ne constitue ni une certification
             ANSSI, ni une attestation au sens du Guide d'hygiène informatique.</li>
```

**This was not flagged in the originating pull request.** It was found by this
diff. Recording that plainly, because the mechanism that caught it is the
reason R8 is performed by rendering rather than by recall.

**Why it deserved scrutiny rather than a shrug.** "Ne constitue pas une
certification ANSSI" is the most legally consequential sentence in the
document. ANSSI is a French state agency, and a commercial tool that appeared
to claim certification it cannot grant would face exactly the reputational and
legal exposure this product must avoid. The emphasis may have been deliberate.

**Why it is nonetheless accepted.**

1. The disclaimer is not carried by this list item alone. Page 1 renders it
   inside a visually distinct callout — `background: #F5E1E5;
   border-left: 2pt solid #6B2737` — making it among the most prominent
   elements on the cover:

   > **Diagnostic informatif.** Le présent document ne constitue ni une
   > certification ANSSI, ni un avis juridique…

2. The current phrasing is stronger, not weaker. "ne constitue ni une
   certification ANSSI, ni une attestation au sens du Guide d'hygiène
   informatique" is formal French legal register and names the specific
   instrument it is not.

3. `Limites explicites` is a parallel list of five limitations. Items 2 to 5
   carry no emphasis; bolding a phrase inside item 1 alone was inconsistent
   with the list's own structure.

**The legal protection is intact and arguably improved.** Should a future
reviewer disagree, the correct fix is to split `conclusion.limit1` into
label and body keys — the pattern already used for the CV/PV/HP legend, where
presentation stays in the template and the translatable units stay clean.

## F. Non-visual

One trailing blank line difference. No rendered effect.

---

## Conclusion

**6.1-R8 is satisfied.** The rendered French report is visually equivalent to
the v0.5.2 reference, with 23 deliberate textual improvements and zero
regressions. The document's structure, layout, pagination and all computed
values are unchanged.

Two emphasis changes required judgement; both are recorded above with reasoning
so they can be revisited deliberately rather than rediscovered.

## Re-running this comparison

The comparison is reproducible and should be repeated whenever the template or
the `report.anssi.*` bundle namespace changes materially — in particular during
Stream 6.2, when multi-framework support adds NIS2, RGS and ISO 27001 content
to the same template.

```powershell
git worktree add C:\Dev\fieldops-<ref> <tag-or-commit>
# render both, normalise hash + style, Compare-Object
git worktree remove C:\Dev\fieldops-<ref> --force
```

## Reference

- Requirement text: `DOCS/PHASE-6-DESIGN.md`, section 6.1.3
- Reference build: tag `v0.5.2`, commit `617a879`
- Test coverage: `tests/unit/Compliance/ReportIntegrity.Compliance.Tests.ps1`
  renders both locales and validates the integrity signature on every full
  suite run.
