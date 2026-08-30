#!/usr/bin/env python3
"""Type 3 fonts in a produced PDF -- i.e. glyphs the browser had to invent.

WHY THIS EXISTS
    Embedding the right font files is not the same as the document USING them.
    On 24/08 all eleven designed faces were embedded and the report still
    carried a Type 3 font: the 8-character field's placeholder asked for Inter
    600 italic, a combination the stylesheet composes from two separate rules
    and which nothing ships, so Chrome slanted a face by hand.

    Static analysis of the CSS did not find it -- the italic comes from one
    selector and the weight from another, and my analyser did not chain them.
    The PDF did find it. A Type 3 font in a Skia PDF means "no real glyph was
    available", which is precisely what premium typography must never contain.

USAGE
    python3 Find-SynthesisedGlyphs.py REPORTS/FOPS-....pdf
"""
import re, sys, zlib

def synthesised(path):
    d = open(path, 'rb').read()
    out = []
    for m in re.finditer(rb'/Subtype\s*/Type3\b', d):
        seg = d[m.start():m.start() + 900]
        tu = re.search(rb'/ToUnicode\s+(\d+)\s+0\s+R', seg)
        chars = []
        if tu:
            om = re.search(rb'(?s)\n' + tu.group(1) + rb' 0 obj\s*<<.*?>>\s*stream\r?\n(.*?)endstream', d)
            if om:
                raw = om.group(1)
                try: txt = zlib.decompress(raw).decode('latin-1')
                except Exception: txt = raw.decode('latin-1')
                for _, dst in re.findall(r'<([0-9a-fA-F]{2,4})>\s*<([0-9a-fA-F]{4,})>', txt):
                    chars.append(''.join(chr(int(dst[i:i+4], 16)) for i in range(0, len(dst), 4)))
        out.append(chars)
    return out

if __name__ == '__main__':
    found = synthesised(sys.argv[1])
    for chars in found:
        print('  synthesised font covering: ' + (''.join(sorted(set(chars))) or '(unknown)'))
    print(('FAIL: %d synthesised font(s) -- some text is not set in a real face' % len(found))
          if found else 'PASS: every glyph comes from an embedded face')
    sys.exit(1 if found else 0)
