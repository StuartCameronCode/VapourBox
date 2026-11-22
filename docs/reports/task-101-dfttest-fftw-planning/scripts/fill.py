"""Puts tables.py's output between the TABLES markers of index.html."""
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
page = os.path.join(HERE, '..', 'index.html')
tables = subprocess.run([sys.executable, os.path.join(HERE, 'tables.py')], capture_output=True,
                        text=True, check=True).stdout
with open(page) as fh:
    s = fh.read()
s = re.sub(r'<!-- TABLES -->.*<!-- /TABLES -->', lambda m: '<!-- TABLES -->\n' + tables + '<!-- /TABLES -->',
           s, flags=re.S)
with open(page, 'w') as fh:
    fh.write(s)
