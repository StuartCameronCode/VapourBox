"""Fills index.html's table markers from tables.py's output, so every number
in a table comes straight from the probes' results.

  python3 fill_report.py      (rewrites ../index.html in place; idempotent)
"""
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
html_path = os.path.join(HERE, '..', 'index.html')
out = subprocess.run([sys.executable, os.path.join(HERE, 'tables.py')], capture_output=True, text=True,
                     check=True).stdout

# Split into blocks: each <table>...</table>, and loose <p> lines.
blocks = re.findall(r'(<table>.*?</table>|<p>.*?</p>)', out, re.S)
SECTIONS = {
    'NR_TABLES': lambda b: 'luma / chroma (U) PSNR' in b or 'Depth parity: mean |8-bit run' in b
                           or 'vszip NLMeans vs KNLMeansCL' in b,
    'BENCH': lambda b: '<caption>Speed' in b,
    'AA_TABLES': lambda b: '<caption>Anti-aliasing' in b,
    'FADE_TABLES': lambda b: '<caption>IVTC fade fix' in b,
    'VINE_TABLES': lambda b: '<caption>Dehalo' in b,
    'STINX_TABLES': lambda b: '<caption>mpeg2stinx' in b,
    'PARITY_TABLES': lambda b: '<caption>Ports, depth parity' in b,
}
html = open(html_path).read()
for marker, pick in SECTIONS.items():
    body = '\n'.join(f'<div class="scroll">{b}</div>' if b.startswith('<table') else b
                     for b in blocks if pick(b))
    pattern = re.compile(r'<!--' + marker + r'-->.*?<!--/' + marker + r'-->|<!--' + marker + r'-->', re.S)
    html = pattern.sub(lambda _m: f'<!--{marker}-->\n{body}\n<!--/{marker}-->', html)
open(html_path, 'w').write(html)
print('filled', ', '.join(SECTIONS))
