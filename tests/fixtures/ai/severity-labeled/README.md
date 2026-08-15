# Labelled severity fixtures

FieldOps Pro - Phase 6, Stream 6.5 (6.5-D16)

These files are the **evidence** behind success criterion 6.5-SC-5: the severity
classifier misclassifies no more than 10 percent of a labelled set of at least
ten cases, covering all four levels in both supported languages.

They are data, not code, so the set can be reviewed, challenged or extended by
someone who does not read PowerShell -- which matters, because roughly half the
cases are French-language classification and the person best placed to judge
those is not necessarily the person maintaining the test harness.

## Files

| File | Contents |
|------|----------|
| `critical.json` | Findings that must classify `CRITICAL` |
| `action-required.json` | Findings that must classify `ACTION_REQUIRED` |
| `advisory.json` | Findings that must classify `ADVISORY` |
| `informational.json` | Findings that must classify `INFORMATIONAL` |
| `hard-cases.json` | Deliberately adversarial cases -- see below |

`AISeverity.Tests.ps1` loads every `*.json` in this directory, so adding a file
adds cases without touching the test.

## Record shape

```json
{
  "lang":   "en",
  "expect": "CRITICAL",
  "text":   "the response text handed to the classifier",
  "note":   "why this case is in the set"
}
```

- **`lang`** -- `en` or `fr`. The set must contain both; a test asserts it.
- **`expect`** -- one of `INFORMATIONAL`, `ADVISORY`, `ACTION_REQUIRED`,
  `CRITICAL`. This is the classifier's vocabulary (6.5-R7), and is unrelated to
  the `severity` field in playbook front matter, which describes a *condition*
  rather than a *response*.
- **`text`** -- what the model would have returned. Write it as a model would
  write it, not as a test fixture: shortened or keyword-stuffed text produces a
  classifier tuned for input it will never see.
- **`note`** -- the reason the case earns its place. A fixture nobody can
  explain is a fixture nobody can safely delete when it starts failing.

## On `hard-cases.json`

These exist to stop the classifier being tuned into a keyword counter:

- **Structural override.** A mild body carrying an explicit `Severity: CRITICAL`
  line. The stated severity must win over the wording.
- **Distress markers that must not downgrade.** An `ACTION_REQUIRED` finding
  that happens to mention a CVE. Security vocabulary is not the same as
  severity, and a classifier that conflates the two inflates every advisory.
- **Security vocabulary at advisory level.** Text dense with security terms
  that nonetheless only recommends a review.

## Adding cases

Add to the matching file, or create a new `*.json`. Keep the accents: French
cases are written without diacritics on purpose here, mirroring the ASCII-clean
constraint that applies to test data read by PowerShell 5.1 -- but the classifier
must handle both, so a fixture *with* diacritics is a welcome addition rather
than a violation.

**A failing fixture is not automatically a bad fixture.** When one starts
failing, decide whether the classifier regressed or the label was wrong, and
record the answer in `note`. Deleting an inconvenient case to restore a green
suite defeats the purpose of having evidence at all.
