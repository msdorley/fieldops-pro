# AI transport fixtures

FieldOps Pro - Phase 6, Stream 6.5 (6.5-D15)

Canonical mocked responses for the one function that touches the network,
`Invoke-AIHttpRequest`. Every AI test mocks that boundary, so these files are
the shared definition of what the provider is assumed to return.

## Why they exist as files

Before this, each test file hand-rolled its own mock. Three problems followed:

1. **Duplication.** The same success-shaped object appeared in three test files
   and seven separate `Mock` blocks.
2. **Drift from reality.** Hand-rolled mocks contained only the fields the test
   happened to read. A response shape that passes tests but does not resemble
   what Anthropic actually sends proves less than it appears to.
3. **No single place to update.** When the provider changes a response shape,
   the fix should be one file, not a search across the suite.

`responses/*.json` therefore hold **realistic** bodies -- the fields the API
actually returns, not the subset the assertions need.

## Contents

| File | Represents |
|------|------------|
| `responses/success.json` | A normal 200 messages response |
| `responses/error-credits.json` | 400, credit balance exhausted |
| `responses/error-auth.json` | 401, invalid API key |
| `responses/error-model-not-found.json` | 404, model unavailable on this plan |
| `responses/error-rate-limit.json` | 429, rate limited |
| `responses/error-overloaded.json` | 529, provider overloaded |
| `responses/malformed.json` | 200 with a body the parser cannot use |
| `New-AIHttpFixture.ps1` | Builds transport-shaped objects from the above |

## Usage

```powershell
BeforeAll {
    . "$PSScriptRoot\..\..\fixtures\ai\New-AIHttpFixture.ps1"
}

Mock Invoke-AIHttpRequest { New-AIHttpFixture -Kind Success }
Mock Invoke-AIHttpRequest { New-AIHttpFixture -Kind Credits }
Mock Invoke-AIHttpRequest { New-AIHttpFixture -Kind Success -InputTokens 500 -Text 'custom' }
```

The helper returns the shape `Invoke-AIHttpRequest` itself returns -- `Success`,
`StatusCode`, `Body`, `ErrorMessage`, `ErrorDetail` -- so a test using it is
exercising the same contract the real transport satisfies.

## On the error bodies

The `error-*.json` files carry the provider's real envelope:

```json
{ "type": "error", "error": { "type": "...", "message": "..." } }
```

That shape matters. `ConvertFrom-AIErrorBody` reads `error.message` to produce
`FailureDetail`, which is what tells a technician to add credits or replace a
key. A fixture that flattened the envelope would let a regression in that
parsing pass unnoticed.

## Keeping them honest

These are a snapshot of provider behaviour, and provider behaviour changes.
When a real failure in the field does not match anything here, add it -- a
fixture set that only contains the failures we already handle cannot surface
the ones we do not.
