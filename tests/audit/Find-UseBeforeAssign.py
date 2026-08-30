#!/usr/bin/env python3
"""Reads-before-assignment in the top-level flow of a PowerShell script.

WHY THIS EXISTS
    Set-StrictMode -Version 1.0 makes reading an undefined variable a fatal
    error at runtime, not a warning. On 24/08 the renderer resolved the product
    version AFTER the section-measuring pass that consumed it, and every static
    check in the suite passed: tokens resolved, keys existed, brackets balanced.
    None of them modelled EXECUTION ORDER. The run died in the field instead.

    Function bodies are judged at their call site, not where they are written,
    because that is when they run. $script: state read inside a function must
    therefore be assigned before the first call to it.
"""
import re, sys

AUTO = {'_','PSScriptRoot','PSCommandPath','MyInvocation','Matches','true','false','null',
        'args','PSBoundParameters','ErrorActionPreference','LASTEXITCODE','PWD','Host',
        'PSVersionTable','ExecutionContext','StackTrace','Error','input','foreach','switch'}

def analyse(path, params=()):
    src = open(path, encoding='ascii').read()
    known = AUTO | set(params)

    spans = []
    for m in re.finditer(r'(?m)^function\s+([\w-]+)\s*\{', src):
        i, depth = m.end() - 1, 0
        while i < len(src):
            if src[i] == '{': depth += 1
            elif src[i] == '}':
                depth -= 1
                if depth == 0: break
            i += 1
        spans.append((m.group(1), m.start(), i + 1))
    if not spans:
        return []
    tail = max(e for _, _, e in spans)
    caller, off = src[tail:], tail

    bound = dict()
    for m in re.finditer(r'\$(?:script:)?([A-Za-z_]\w*)\s*=(?!=)', caller):
        bound.setdefault(m.group(1), off + m.start())
    for m in re.finditer(r'foreach\s*\(\s*\$([A-Za-z_]\w*)\s+in\b', caller):   # loop bindings
        bound.setdefault(m.group(1), off + m.start())
    for m in re.finditer(r'catch\s*\[\s*[^\]]*\]\s*\{', caller):
        pass

    findings, seen = [], set()
    for m in re.finditer(r'\$(?:script:)?([A-Za-z_]\w*)', caller):
        n, pos = m.group(1), off + m.start()
        if n in known or n in seen: continue
        a = bound.get(n)
        if a is not None and a <= pos: continue
        g = re.search(r'\$script:' + n + r'\s*=', src)
        if g and g.start() < pos: continue
        seen.add(n)
        findings.append((n, src[:pos].count('\n') + 1, src[:a].count('\n') + 1 if a else None))

    for name, s0, e0 in spans:                       # $script: state vs call sites
        body = src[s0:e0]
        for v in sorted(set(re.findall(r'\$script:(\w+)', body))):
            if re.search(r'\$script:' + v + r'\s*=', body): continue
            am = re.search(r'(?m)^\s*\$script:' + v + r'\s*=', src)
            cm = re.search(r'(?<![\w-])' + re.escape(name) + r'\s', src[tail:])
            if not cm: continue
            cpos = tail + cm.start()
            if am is None or am.start() > cpos:
                findings.append((f'{name}() reads $script:{v}',
                                 src[:cpos].count('\n') + 1,
                                 src[:am.start()].count('\n') + 1 if am else None))
    return findings

if __name__ == '__main__':
    target = sys.argv[1]
    params = sys.argv[2].split(',') if len(sys.argv) > 2 else []
    bad = analyse(target, params)
    for n, line, a in bad:
        print(f'  {n}: read at line {line}, assigned {"at line " + str(a) if a else "NEVER"}')
    print(('FAIL: %d read-before-assignment' % len(bad)) if bad else 'PASS: no read-before-assignment')
    sys.exit(1 if bad else 0)
