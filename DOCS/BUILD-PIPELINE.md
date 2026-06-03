# Phase 6 Design Document — Build Pipeline

How `docs/PHASE-6-DESIGN.{md,docx,pdf}` is produced from source. Capture this
in case the document needs to be regenerated (typos, amendments under §6,
post-execution revision history entries, etc.).

## Source of truth

`docs/PHASE-6-DESIGN.md` is the canonical source. The docx and pdf are
generated artifacts. Edit the markdown, not the docx.

## Toolchain

| Tool | Version | Role |
|---|---|---|
| pandoc | 3.1.3+ | Markdown → docx conversion |
| Node.js | 20+ | Run `docx-js` build scripts |
| docx (npm) | latest | Generate reference.docx and cover.docx |
| Python | 3.10+ | XML post-processing, merge, UNO bridge |
| lxml | latest | XML manipulation |
| LibreOffice | 7.6+ (with python-uno) | TOC update, PDF export |
| Consolas, Cambria, Calibri | system fonts | Used by the docx styles |

On Windows with the FieldOps build environment (Acer Nitro ANV15-51), all
of these are reproducible via WSL2 Ubuntu 24.04 or a Linux container.

## File inventory

The build pipeline expects this layout (paths relative to the build root):

```
PHASE-6-DESIGN.md           # source markdown (canonical)
build-reference.js          # generates reference.docx (style definitions)
build-cover.js              # generates cover.docx (premium cover + doc control)
merge.py                    # XML merge: prepend cover into pandoc body
postprocess.py              # XML post-process: table borders, fonts, sections, URLs
uno_update_toc.py           # LibreOffice UNO: refresh TOC + page numbers
```

Intermediate artifacts (produced during build, can be deleted between runs):

```
reference.docx              # bespoke style document
cover.docx                  # cover page + Document Control
body-only.md                # markdown with front-matter title stripped
pandoc-body.docx            # pandoc output (before cover merge)
PHASE-6-DESIGN-temp.docx    # after cover merge
PHASE-6-DESIGN-processed.docx  # after XML post-process
```

Final artifacts:

```
PHASE-6-DESIGN.docx         # final Word document with TOC populated
PHASE-6-DESIGN.pdf          # final PDF
```

## Pipeline stages

### Stage 1 — Build reference.docx (style definitions)

`build-reference.js` defines all paragraph and character styles: Heading1-4,
SourceCode (Consolas 9pt with navy left bar), VerbatimChar, BodyText,
Compact. Also defines page geometry (A4, 1440-DXA margins), running
header (italic grey doc title right-aligned), running footer
("Page N of M" centered).

```bash
node build-reference.js
# Outputs: reference.docx
```

Post-process: docx-js emits paragraph borders in non-schema order; fix
with a regex pass over styles.xml to reorder `<w:pBdr>` children to
`top → left → bottom → right`.

### Stage 2 — Build cover.docx (cover page + Document Control)

`build-cover.js` builds the standalone cover page: gold "TECHNICAL DESIGN
DOCUMENT" eyebrow, navy "FieldOps Pro" title 48pt Cambria, gold accent
rule, mid-blue "Phase 6 Design Document" 32pt, italic subtitle,
author/date/version block, github URL + license footer. Then a page break
and the Document Control table (17 rows). Final page break leaves room
for the TOC to follow.

```bash
node build-cover.js
# Outputs: cover.docx
```

### Stage 3 — Strip front matter title from markdown

The first three lines of the canonical markdown are the title block that
becomes the cover page. Strip from `## Executive Summary` onward.

```python
# body-only.md = PHASE-6-DESIGN.md from "## Executive Summary" onward
```

### Stage 4 — Pandoc: markdown → docx with reference

```bash
pandoc body-only.md \
  -o pandoc-body.docx \
  --reference-doc=reference.docx \
  --toc --toc-depth=2 \
  --wrap=preserve \
  -V lang=en-US
```

Pandoc emits an unpopulated TOC field, which LibreOffice will fill in
Stage 7.

### Stage 5 — XML merge: prepend cover into body

`merge.py` reads cover.docx's `<w:body>` children (excluding the trailing
sectPr), prepends them into pandoc-body.docx's `<w:body>` before its first
child. This results in `PHASE-6-DESIGN-temp.docx`.

### Stage 6 — XML post-process

`postprocess.py` applies:

1. **Table borders** on every `<w:tbl>`: full set (top, left, bottom,
   right, insideH, insideV) all `single` 4-half-point gray (#8C8C8C).
   Adds cell margins for breathing room.

2. **Header row shading**: light blue (#D9E2F3) on the first `<w:tr>` of
   every table.

3. **`cantSplit` on all `<w:trPr>`**: prevents rows from breaking
   mid-cell when they span a page break.

4. **9pt cell font**: every `<w:r>` inside `<w:tc>` gets
   `<w:sz w:val="18"/>` (half-points) so wide tables fit gracefully.

5. **URL break opportunities**: in any `<w:t>` containing "http://" or
   "https://", insert U+200B (zero-width space) after each `/`, `?`, `=`,
   `&`, `-`, `.` so Word wraps URLs at natural boundaries instead of
   character-by-character. Special-case to avoid breaking the `://` after
   scheme.

6. **Section breaks for landscape orientation** — insert paragraphs with
   `<w:sectPr>` properties at strategic locations to flip orientation:

   ```
   portrait:  cover, TOC, exec summary, §1, §2, §3
   landscape: §4 Investment Summary (8-col table)
   portrait:  §5, all 6 chapters, Appendix A
   landscape: Appendix B (Risk Register)
   portrait:  Appendix C, D
   landscape: Appendix E, F (Citation Bibliography URLs)
   portrait:  Appendix G
   landscape: Appendix H (Competitive Matrix, 6-col)
   ```

   To make the final section (containing H) landscape, flip the body's
   final `<w:sectPr>` to landscape orientation directly. All other
   transitions use inserted section-break paragraphs.

### Stage 7 — LibreOffice UNO: populate TOC

`uno_update_toc.py` connects to a headless soffice instance via
`com.sun.star.bridge.UnoUrlResolver` and:

1. Loads `PHASE-6-DESIGN-processed.docx`
2. Calls `doc.getTextFields().refresh()` and updates all
   `doc.getDocumentIndexes()` twice (page numbers settle on second pass)
3. Saves as `PHASE-6-DESIGN.docx`

**Critical**: Use an isolated UserInstallation profile
(`-env:UserInstallation=file:///tmp/lo_<unique>`). The default profile
gets corrupted by UNO experiments and breaks subsequent runs.

### Stage 8 — Style restoration

LibreOffice strips custom paragraph styles on save (replaces my Consolas
SourceCode with default Calibri). Re-patch styles.xml after the UNO save:
restore SourceCode with the full pBdr + shading + Consolas runs. Also
remove any Heading1 `<w:pBdr>` that LO re-added (so wrapped chapter titles
don't get sliced).

### Stage 9 — PDF export

Use a fresh `soffice --convert-to pdf` (NOT through UNO bridge — that
would re-strip the styles we just restored):

```bash
soffice --headless --convert-to pdf --outdir /tmp/pdfout \
  -env:UserInstallation=file:///tmp/lo_pdfexport \
  PHASE-6-DESIGN.docx
```

## One-command rebuild

A wrapper script orchestrating all stages is at `scripts/build-design-doc.sh`
(or `.ps1` for Windows). Run it from the repo root.

## Known constraints (PowerShell 5.1 environment quirks irrelevant here, but...)

- **`<w:pBdr>` schema order**: docx-js emits children in JS object key order
  but the schema is strict on `top → left → bottom → right → between → bar`.
  Always post-process docx-js output for paragraph border styles.

- **LibreOffice TOC requires custom-style-free reference.docx**: a clean v2
  reference with new custom styles broke LibreOffice's TOC update silently.
  Solution: derive references from a known-good base via surgical
  styles.xml edits, not from a fresh docx-js build.

- **Landscape margins**: keep landscape pages at 1080-DXA left/right margins
  to maximize column width for wide tables.

## Future work

- If §6 Document Control needs to track future amendments, edit only
  Appendix G (Revision History) per the §6 commitment. The body §6 was
  intentionally removed since the cover-page block is authoritative.

- If new chapters or appendices are added, postprocess.py needs new
  section-break targets if they contain wide tables.

- If new H1 or numbered H2 sections are added that should start fresh
  pages, the markdown page-break injection script (see top of build
  pipeline) needs the new patterns.
