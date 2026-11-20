"""Put tables.py's output into index.html: each <!--T:name--> slot (or a
previous fill of it, between <!--T:name--> and <!--/T-->) is replaced by the
table tables.py prints under <!-- name -->. argv: none."""
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
out = subprocess.run([sys.executable, os.path.join(HERE, 'tables.py')], capture_output=True,
                     text=True, check=True).stdout
parts = {}
for m in re.finditer(r'<!-- (.+?) -->\n(.*?)(?=\n<!-- |\Z)', out, re.S):
    parts[m.group(1)] = m.group(2).strip()
page = os.path.join(HERE, '..', 'index.html')
html = open(page, encoding='utf-8').read()


def sub(m):
    name = m.group(1)
    if name not in parts:
        raise SystemExit('no table named %r' % name)
    return '<!--T:%s-->\n%s\n<!--/T-->' % (name, parts[name])


html = re.sub(r'<!--T:(.+?)-->(?:.*?<!--/T-->)?', sub, html, flags=re.S)
open(page, 'w', encoding='utf-8').write(html)
print('filled', len(parts), 'tables')
