# AI Integration Guide

FieldOps Pro - Phase 6, Stream 6.5 (6.5-D17)

How the AI features work, what they cost, what they record, and how an auditor
verifies any of it independently.

---

## 1. What the AI does, and what it does not

FieldOps Pro uses a large language model for three things: narrating what
changed between two compliance snapshots, classifying the severity of its own
findings, and referencing validated remediation procedures.

**No AI feature is a hard dependency.** Every AI-using script has a
deterministic local path and takes it whenever the AI is unavailable, refused on
cost, or returns something unusable. A machine with no API key, no network, or
an exhausted credit balance still produces a complete compliance report -- with
rule-based classification instead of narration, and a console message saying
which and why.

This is a design guarantee, not an aspiration. It is enforced by test: every
failure the client can report is asserted to degrade to the local path rather
than throw.

**The AI never decides compliance.** The 42 ANSSI rule evaluations are computed
from observed system state by deterministic code. The AI describes, prioritises
and explains; it does not score.

---

## 2. Architecture in one paragraph

Every call to the provider goes through one module,
`SCRIPTS/AI/FieldOps-AIClient.psm1`. No other deployed script contains the API
endpoint or issues an HTTP request to it, and an audit test asserts that exactly
one file in the tree does. That single boundary is what makes the cost ceilings,
the audit log, the retry policy and the severity classification unavoidable
rather than optional -- there is no path around them.

---

## 3. Configuration

### 3.1 API key

Resolved in this order, first match wins:

1. `ANTHROPIC_API_KEY` environment variable
2. `CONFIG/technician.json`
3. `CONFIG/FieldOps.config.json`
4. `CONFIG/fieldops.json`
5. `CONFIG/config.json`

Within each file the key may appear under any of `AnthropicApiKey`,
`AnthropicKey`, `ApiKey`, `AiKey`, `ClaudeApiKey`, `ClaudeKey`, or `Key`, at the
top level or nested inside an object. A file that exists but carries no key does
not end the search.

```json
{ "TechnicianName": "...", "AnthropicApiKey": "sk-ant-..." }
```

**The environment variable wins over any file.** This lets a technician override
a stale provisioned key without editing the USB.

**The key is never written anywhere.** It does not appear in the audit log, in
any error message, or on any result object. Two audit tests enforce this: one
scans the module source, one scans generated log output for the live key format.

### 3.2 Cost ceilings

| Ceiling | Default | Purpose |
|---------|---------|---------|
| Per invocation | **0.50 USD** | Refuses a single oversized prompt |
| Per session | **5.00 USD** | Caps a whole run, however many calls |

Both are overridable per call. A refused call never reaches the network: the
estimate is computed first, and the refusal is returned before any spend.

**Estimation deliberately errs high.** Token counts round up, the
chars-per-token ratio is set low, and an unrecognised model is priced as the
most expensive current one. The reasoning: an estimate that comes in low admits
a call the ceiling exists to refuse, and the operator discovers it on an
invoice. An estimate that comes in high costs a fallback path, not money.

### 3.3 Model selection

Three task tiers map to models in `CONFIG/AIModelPricing.json`:

| Tier | Used for | Default model |
|------|----------|---------------|
| `Classification` | Short structured judgements | `claude-haiku-4-5-20251001` |
| `Narration` | Report prose | `claude-sonnet-5` |
| `Reasoning` | Compliance diff analysis | `claude-opus-4-8` |

On a 404 -- model unavailable on your plan -- the client falls back down the
price-ordered chain automatically, and reports which model actually answered.
It never falls back *upward* to a more expensive model, and a 400 does not
trigger fallback, because an invalid request repeats identically on every model.

### 3.4 Pricing freshness

`CONFIG/AIModelPricing.json` carries a snapshot date and two thresholds. An
audit test warns as the snapshot ages and fails when it is dangerously stale, so
cost estimates cannot silently drift from published rates.

---

## 4. The audit log

### 4.1 What is written

One JSON Lines record per invocation, appended to `LOGS/ai-audit.jsonl`,
conforming to the published schema at `schemas/ai-audit-record.json`
(schemaVersion 1.1). A record is written for **every** call, including refusals
and failures -- a call refused on cost is exactly the event an auditor wants to
see.

```json
{"schemaVersion":"1.1","ts":"2026-08-15T19:04:11.2340000+02:00","ctx":"ComplianceDiff/Analysis",
 "tier":"Reasoning","model":"claude-sonnet-5","model_override":false,
 "in_tok":1180,"out_tok":642,"est_cost_usd":0.0412,"cost_usd":0.0387,"cost_variance":-0.0025,
 "severity":"ACTION_REQUIRED","severity_method":"keyword",
 "playbook_ref":"RB-AV-001","playbook_valid":true,
 "prompt_sha256":"...","system_sha256":null,"response_sha256":"...",
 "tech":"a3f9c1e08b42","duration_ms":4820,"retries":0,"success":true,
 "failure_reason":null,"needs_human_review":false}
```

### 4.2 Privacy

**Prompts and responses are not stored.** Only SHA-256 hashes of them are. Full
transcripts are written only when explicitly requested, and then to a separate
location.

**`tech` is pseudonymous, not anonymous.** It is a truncated SHA-256 of the
technician name. That keeps names out of a shared log, but a short name space is
brute-forceable by anyone holding a candidate list. It should be described as
pseudonymisation and treated accordingly under GDPR -- it is not anonymised
data, and we do not claim it is.

**`cost_variance`** is `cost_usd - est_cost_usd`. Positive means the estimate
came in low; that is the direction worth monitoring.

### 4.3 Verifying a record independently

This is the procedure for an auditor who wants to confirm a record refers to the
content someone claims it does. It requires no access to FieldOps Pro.

Given a candidate prompt or response text, compute its SHA-256 as **lowercase
hex over the UTF-8 bytes with no trailing newline**, and compare to the field.

PowerShell:

```powershell
$text  = Get-Content -LiteralPath .\candidate-response.txt -Raw
$bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
$sha   = [System.Security.Cryptography.SHA256]::Create()
-join ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') })
```

Linux or macOS:

```bash
printf '%s' "$(cat candidate-response.txt)" | sha256sum
```

A match proves the record refers to that exact text. A mismatch proves it does
not -- including a mismatch caused by a trailing newline, which is why the
encoding is stated precisely rather than left implied.

`system_sha256` is `null` when no system prompt was sent, which is distinct from
the hash of an empty string.

**What this establishes and what it does not.** The hashes prove *correspondence*
between a record and a text you already hold. They are not a tamper-evidence
mechanism: the log is an append-only text file on the technician's media, and
anyone who can write to it can rewrite a line and recompute the hash. Treat it
as an operational record, not as a cryptographic chain of custody. Cryptographic
signing is a Phase 7 candidate and is deliberately not claimed here.

### 4.4 Retention

Rotation at 10 MB or monthly, whichever comes first. Online retention 12 months;
archived retention 7 years under `LOGS/archive/`. Configurable.

---

## 5. Severity classification

Every response is classified into one of four levels:

| Level | Meaning |
|-------|---------|
| `INFORMATIONAL` | No action indicated |
| `ADVISORY` | Improvement suggested |
| `ACTION_REQUIRED` | Must be remediated |
| `CRITICAL` | Immediate action |

Two tiers decide it. **Structural** wins where the response states its own
severity explicitly. **Keyword** applies otherwise, using the vocabulary in
`CONFIG/AISeverityKeywords.json`, which covers English and French.

`needs_human_review` is set when the classifier is uncertain, when a response is
empty, when the keyword configuration cannot be read, or when a playbook
citation fails validation. **It is never cleared by a later step**: once
something flags a response for review, nothing downgrades that.

Accuracy is measured against labelled fixtures in
`tests/fixtures/ai/severity-labeled/`, currently 14 cases across both languages,
with a ceiling of 10 percent misclassification. Those fixtures are data files,
so the evidence can be reviewed and extended without reading test code.

---

## 6. Remediation playbook validation

When a call is made with `-ExpectPlaybookReference`, the client extracts any
cited playbook ID from the response, resolves it against
`PLAYBOOKS/remediation/`, parses the front matter, and checks it conforms to
`schemas/playbook-frontmatter.json`.

`PlaybookValid` is **three-state**, and integrators must treat it as such:

| Value | Meaning |
|-------|---------|
| `$null` | Not checked -- the call did not request validation |
| `$false` | Checked, and the citation does not hold up |
| `$true` | Checked and sound |

Collapsing `$null` and `$false` treats every unvalidated call as clean, which is
the failure this field exists to prevent. "A citation was expected and none was
given" reports `$false`, not `$null` -- the check ran, and the answer is no.

A failed validation forces `needs_human_review`. An AI recommendation citing a
procedure that does not exist reads as authoritative and sends a technician
looking for a document nobody wrote; that is precisely the case a human must
see.

---

## 7. Public API

Six exported functions:

| Function | Purpose |
|----------|---------|
| `Invoke-FieldOpsAI` | Make a governed, audited call |
| `Test-FieldOpsAIAvailability` | Report whether a call could be attempted, without making one |
| `Get-FieldOpsAISessionCost` | Accumulated spend this session |
| `Reset-FieldOpsAISession` | Zero the session counter |
| `Get-FieldOpsAIAuditLogPath` | Absolute path to the audit log |
| `Get-AISeverityClassification` | Classify arbitrary text |

### 7.1 Calling

```powershell
Import-Module .\SCRIPTS\AI\FieldOps-AIClient.psm1

$r = Invoke-FieldOpsAI -Prompt $prompt `
                       -TaskTier 'Narration' `
                       -CallingContext 'MyScript/Summary' `
                       -MaxTokens 2000

if ($r.Success) {
    $r.Response
} else {
    Write-Warning "AI unavailable: $($r.FailureReason)"
    if ($r.FailureDetail) { Write-Warning "  Provider says: $($r.FailureDetail)" }
    # deterministic fallback here
}
```

`CallingContext` lands in the audit log as `ctx`. Set it to something that
identifies the call site, or the log cannot attribute spend.

**`Invoke-FieldOpsAI` never throws.** It always returns a result object. Branch
on `.Success`.

### 7.2 Failure reasons

`.FailureReason` is a **closed vocabulary** and the only field to branch on:

| Value | Meaning |
|-------|---------|
| `NoApiKey` | No key found in environment or config |
| `PricingConfigUnavailable` | Pricing table unreadable; refused rather than spend unmetered |
| `EstimateExceedsCeiling` | Prompt too expensive for the per-call ceiling |
| `SessionCeilingExceeded` | Session budget exhausted |
| `ModelUnavailable` | No configured model available on this plan |
| `TransientFailureRetriesExhausted` | Rate limit or overload, after retries |
| `NonTransientFailure` | 400, 401, 403 -- retrying will not help |
| `MalformedResponse` | Provider returned an unusable shape |
| `UnknownTaskTier` | Configuration error |

**`.FailureDetail` and `.HttpStatus` are advisory and must not be matched on.**
`FailureDetail` is the provider's own wording, recovered from the response body
and redacted -- "your credit balance is too low", "invalid x-api-key". It exists
so an operator can be told what to *do*. The provider may reword it at any time.

`HttpStatus` is `0` when the failure never reached the network -- a ceiling
refusal, a missing key -- which is distinct from any real status code.

### 7.3 Retry policy

Four attempts maximum: immediate, then 1s, 2s, 4s. Seven seconds of waiting
worst case.

Transient (retried): network errors, 429, 5xx, timeouts.
Non-transient (fails fast): 400, 401, 403, 404, malformed responses.

---

## 8. Operating without AI

Set `-NoAI` on any AI-using script, or simply provide no API key. The tools
report which path they took and continue. Nothing degrades silently.

Air-gapped deployment is supported and expected: the toolkit runs from a USB
stick and the test suite itself requires no network.

To confirm configuration on a machine:

```powershell
.\SCRIPTS\Core\Invoke-ComplianceDiff.ps1 -Mode Diagnose
```

This reports the config file found, whether a key was loaded and in what format,
whether pricing is readable, and -- if a key is present -- makes one minimal live
call to confirm the whole path works end to end. That call is audited like any
other, which also proves the audit path functions on this machine.

---

## 9. Verification summary for reviewers

| Claim | How to verify |
|-------|---------------|
| All AI calls are governed | `tests/audit/Audit-NoDirectAnthropicCalls.Tests.ps1` asserts exactly one file owns the transport |
| No key reaches any log | `tests/audit/Audit-NoApiKeyInLogs.Tests.ps1`, static and dynamic |
| Every call is recorded | `tests/unit/AI/AIAudit.Tests.ps1` writes and schema-validates records for success, refusal and failure |
| Records are reproducible | Same suite recomputes each hash from the original text |
| Ceilings hold | `tests/unit/AI/FieldOps-AIClient.Tests.ps1`, `[D11]` block, including that a refused call never reaches the network |
| Classifier accuracy | `tests/unit/AI/AISeverity.Tests.ps1` against the labelled fixture set |
| Nothing is a hard dependency | `tests/unit/AI/ComplianceDiffReroute.Tests.ps1` asserts every failure reason degrades to local rules |

Run the full suite with `.\tests\Run-AllTests.ps1`. It requires no network and
no API key.

---

## 10. Related documents

- `schemas/ai-audit-record.json` -- audit record contract
- `schemas/playbook-frontmatter.json` -- playbook front-matter contract
- `PLAYBOOKS/remediation/SCHEMA.md` -- playbook authoring guide
- `DOCS/TESTING.md` -- test suite reference
- `DOCS/PHASE-6-DESIGN.md` -- authoritative specification
