#Requires -Version 5.1
<#
.SYNOPSIS
    Patches Invoke-AutoFixPlan.ps1 to use line-based FixRules extraction
    instead of the broken state-machine approach.
.DESCRIPTION
    The original Get-FixRulesFromAutoFix function in Invoke-AutoFixPlan.ps1
    used a paren-balancing state machine to extract $script:FixRules from
    Invoke-AutoFix.ps1. The state machine had an off-by-one bug in its
    closing-paren detection (it checked depth before the decrement
    instead of after), causing it to walk off the end of the file.

    This patch replaces the function with a simple, line-based extractor
    that finds the line ending in '$script:FixRules = @(' and the next
    line containing only ')' (with optional whitespace), extracting
    everything between them.

    It is much simpler and immune to the quote/paren edge cases that
    tripped the state machine.
.NOTES
    Run from C:\Dev\fieldops-pro\ or wherever your repo lives.
#>

$ErrorActionPreference = 'Stop'

$scriptPath = '.\SCRIPTS\Core\Invoke-AutoFixPlan.ps1'
if (-not (Test-Path $scriptPath)) {
    Write-Host "  [X] $scriptPath not found. Run this from your repo root." -ForegroundColor Red
    return
}

# Backup
$bak = "$scriptPath.prepatch.bak"
Copy-Item $scriptPath $bak -Force
Write-Host "  [OK] Backup: $bak" -ForegroundColor Green

# Read the file
$content = Get-Content $scriptPath -Raw

# The new function body (replaces the existing one)
$newFunctionBody = @'
function Get-FixRulesFromAutoFix {
    if (-not (Test-Path $AutoFixPath)) {
        throw "Invoke-AutoFix.ps1 not found at $AutoFixPath"
    }

    # Line-based extraction. Find the line where the array opens, and the
    # line where it closes. Boring, correct, robust.
    #
    # Opening signature: a line ending in '$script:FixRules = @(' (any
    # leading whitespace, optional trailing whitespace). Closing signature:
    # a line whose only non-whitespace content is ')'.
    $lines    = Get-Content $AutoFixPath
    $startLn  = -1
    $endLn    = -1

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $stripped = $lines[$i].Trim()
        if ($startLn -lt 0) {
            if ($stripped -match '^\$script:FixRules\s*=\s*@\(\s*$') {
                $startLn = $i
            }
            continue
        }
        if ($stripped -eq ')') {
            $endLn = $i
            break
        }
    }

    if ($startLn -lt 0) {
        throw "Could not find '`$script:FixRules = @(' in Invoke-AutoFix.ps1"
    }
    if ($endLn -lt 0) {
        throw "Could not find closing ')' for `$script:FixRules in Invoke-AutoFix.ps1"
    }

    # Extract the body lines between (exclusive) and re-evaluate as an array.
    $bodyLines = $lines[($startLn + 1)..($endLn - 1)]
    $rulesBody = $bodyLines -join "`n"
    $rulesArray = Invoke-Expression "@($rulesBody)"
    return @($rulesArray)
}
'@

# Find the existing function definition. It starts at "function Get-FixRulesFromAutoFix {"
# and ends at the closing "}" that matches the function's opening brace.
# Simpler approach: find the function and the next function definition,
# then replace everything between (exclusive of the next function header).

$startPattern = 'function Get-FixRulesFromAutoFix {'
$startIdx = $content.IndexOf($startPattern)
if ($startIdx -lt 0) {
    Write-Host "  [X] Could not locate 'function Get-FixRulesFromAutoFix {' in the file." -ForegroundColor Red
    Write-Host "      The file may have been hand-edited. Aborting." -ForegroundColor Red
    return
}

# Walk forward from $startIdx, balancing braces, ignoring those inside
# strings and comments. This is a SHORT walk (a single function body),
# and the FieldOps codebase doesn't use brace-confusing constructs in
# function bodies, so this is safe.
$depth = 0
$i = $startIdx
$inSingle = $false
$inDouble = $false
$inLineCom = $false
$inBlockCom = $false
$endIdx = -1
$started = $false

while ($i -lt $content.Length) {
    $c = $content[$i]
    $next = if ($i + 1 -lt $content.Length) { $content[$i + 1] } else { '' }

    if ($inLineCom) {
        if ($c -eq "`n") { $inLineCom = $false }
        $i++; continue
    }
    if ($inBlockCom) {
        if ($c -eq '>' -and $i -gt 0 -and $content[$i - 1] -eq '#') { $inBlockCom = $false }
        $i++; continue
    }
    if ($inSingle) {
        if ($c -eq "'") {
            if ($next -eq "'") { $i += 2; continue }
            $inSingle = $false
        }
        $i++; continue
    }
    if ($inDouble) {
        if ($c -eq '`') { $i += 2; continue }
        if ($c -eq '"') { $inDouble = $false }
        $i++; continue
    }

    if ($c -eq '#') {
        if ($next -eq '>') { $inBlockCom = $true; $i += 2; continue }
        $inLineCom = $true; $i++; continue
    }
    if ($c -eq '<' -and $next -eq '#') { $inBlockCom = $true; $i += 2; continue }
    if ($c -eq "'") { $inSingle = $true; $i++; continue }
    if ($c -eq '"') { $inDouble = $true; $i++; continue }

    if ($c -eq '{') {
        $depth++
        $started = $true
        $i++; continue
    }
    if ($c -eq '}') {
        $depth--
        if ($started -and $depth -eq 0) {
            $endIdx = $i
            break
        }
        $i++; continue
    }
    $i++
}

if ($endIdx -lt 0) {
    Write-Host "  [X] Could not find closing '}' of Get-FixRulesFromAutoFix function." -ForegroundColor Red
    return
}

# Replace [startIdx, endIdx] (inclusive of both) with the new function body.
$before = $content.Substring(0, $startIdx)
$after  = $content.Substring($endIdx + 1)
$newContent = $before + $newFunctionBody + $after

# Write back
[System.IO.File]::WriteAllText((Resolve-Path $scriptPath), $newContent, [System.Text.UTF8Encoding]::new($true))

$newSize = (Get-Item $scriptPath).Length
$bakSize = (Get-Item $bak).Length
Write-Host "  [OK] Function replaced." -ForegroundColor Green
Write-Host "       Size: $bakSize -> $newSize bytes" -ForegroundColor DarkGray

# Sanity check: the new function name should appear exactly once
$check = Get-Content $scriptPath -Raw
$count = ([regex]::Matches($check, 'function Get-FixRulesFromAutoFix \{')).Count
if ($count -eq 1) {
    Write-Host "  [OK] Function definition count: 1 (correct)" -ForegroundColor Green
} else {
    Write-Host "  [!] Function definition count: $count (expected 1)" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "  Now re-run: .\SCRIPTS\Core\Invoke-AutoFixPlan.ps1 -DryRun -FixId SEC-012" -ForegroundColor Cyan
