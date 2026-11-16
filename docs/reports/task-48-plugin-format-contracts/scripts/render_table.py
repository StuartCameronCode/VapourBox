#!/usr/bin/env python3
"""Writes the per-call tables in ../index.html (between the TABLE markers)
from Tests/TestResources/plugin_format_table.json, and the identity results
(between the IDENTITY markers) from the identity.py output given as argv[1]."""
import html
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, '..', '..', '..', '..'))
TABLE = os.path.join(REPO, 'Tests', 'TestResources', 'plugin_format_table.json')
INDEX = os.path.join(HERE, '..', 'index.html')

DEPTHS = [8, 10, 12, 16]
SS = ['420', '422', '444']


def esc(s):
    return html.escape(str(s))


def grid(cells):
    """3 x 4 cells (subsampling x depth) at the base size; a cell shows which
    field flags (p, b, t) were refused."""
    rows = []
    for ss in SS:
        tds = []
        for b in DEPTHS:
            refused = [f for f, tag in ((0, 'p'), (1, 'b'), (2, 't'))
                       if not cells.get('%sp%d/f%d/160x120' % (ss, b, f), {'ok': True})['ok']]
            if not refused:
                tds.append('<td class="ok">ok</td>')
            elif len(refused) == 3:
                tds.append('<td class="no">refused</td>')
            else:
                tds.append('<td class="part">%s refused</td>' % '/'.join(
                    {0: 'prog', 1: 'BFF', 2: 'TFF'}[f] for f in refused))
        rows.append('<tr><th>4:%s:%s</th>%s</tr>' % (ss[1], ss[2], ''.join(tds)))
    return ('<table class="grid"><tr><th></th>%s</tr>%s</table>'
            % (''.join('<th>%d-bit</th>' % b for b in DEPTHS), ''.join(rows)))


def errors(cells):
    seen = {}
    for k, r in sorted(cells.items()):
        if not r['ok']:
            seen.setdefault(r['error'], []).append(k)
    return ''.join('<li><code>%s</code> <span class="muted">(%d cells, e.g. %s)</span></li>'
                   % (esc(e), len(ks), esc(', '.join(ks[:3]))) for e, ks in seen.items())


def doc_rows(cells):
    out = []
    for k in ('411p8/f0/160x120', '411p8/f2/160x120', '420p9/f0/160x120', '420p14/f0/160x120'):
        r = cells.get(k)
        if r:
            out.append('%s %s' % (k.split('/')[0] + ('' if '/f0/' in k else ' TFF'),
                                  'ok' if r['ok'] else 'refused'))
    return ', '.join(out)


def render_table():
    t = json.load(open(TABLE))
    calls = t['calls']
    limited, free = [], []
    for key, entry in sorted(calls.items()):
        s = entry.get('summary', {})
        lim = ('broken' in s or len(s.get('depths', [])) != 4 or len(s.get('subsampling', [])) != 3
               or not s.get('field_based', True) or s.get('irregular') or s.get('sizes_refused'))
        (limited if lim else free).append((key, entry, s))
    parts = ['<p>Measured on <code>%s</code>. %d calls probed; %d refuse part of what a pass can be '
             'handed (below, each with its errors); %d accept all of it.</p>'
             % (esc(t.get('platform') or '?'), len(calls), len(limited), len(free))]
    for key, entry, s in limited:
        cells = entry['cells']
        parts.append('<h3><code>%s</code></h3>' % esc(key))
        parts.append(grid(cells))
        notes = []
        if s.get('sizes_refused'):
            notes.append('Sizes refused inside its accepted formats: <code>%s</code>'
                         % esc(', '.join(s['sizes_refused'])))
        if s.get('irregular'):
            notes.append('Refused inside its accepted formats at 160x120: <code>%s</code>'
                         % esc(', '.join(s['irregular'])))
        if s.get('crashes'):
            notes.append('<span class="bad">Crashed</span>: <code>%s</code>' % esc(', '.join(s['crashes'])))
        dr = doc_rows(cells)
        if dr:
            notes.append('Outside the reachable set: %s' % esc(dr))
        parts.append('<ul class="notes">%s<li>Errors:<ul>%s</ul></li></ul>'
                     % (''.join('<li>%s</li>' % n for n in notes), errors(cells)))
    rows = []
    for key, entry, s in free:
        rows.append('<tr><td><code>%s</code></td><td>%s</td></tr>' % (esc(key), esc(doc_rows(entry['cells']))))
    parts.append('<h3>Accepting the whole reachable set, at every size</h3>'
                 '<table><tr><th>Call</th><th>Outside the reachable set</th></tr>%s</table>' % ''.join(rows))
    return '\n'.join(parts)


def render_identity(path):
    lines = [l.rstrip('\n') for l in open(path) if l.strip()]
    summary = lines[-1]
    body = []
    for l in lines[:-1]:
        cols = l.split()
        if not cols:
            continue
        if cols[0] == 'identical':
            status = 'identical' + (' (no change from the source)' if 'no change' in l else '')
            cls = 'ok'
            p, f, fo = cols[1:4]
        else:
            m = re.match(r'(BOTH FAIL|DIFFERS(?: \(fails \w+\))?)\s+(\S+)\s+(\S+)\s+(\S+)', l)
            status, p, f, fo = m.groups()
            cls = 'no' if status.startswith('DIFFERS') else 'part'
        body.append('<tr><td>%s</td><td>%s</td><td>%s</td><td class="%s">%s</td></tr>'
                    % (esc(p), esc(f), esc(fo), cls, esc(status)))
    return ('<p><strong>%s</strong></p><details><summary>Every job</summary><table>'
            '<tr><th>Pass</th><th>Source</th><th>Field order</th><th>Old vs new</th></tr>%s</table></details>'
            % (esc(summary), ''.join(body)))


def splice(doc, marker, content):
    a, b = '<!-- %s -->' % marker, '<!-- /%s -->' % marker
    i, j = doc.index(a) + len(a), doc.index(b)
    return doc[:i] + '\n' + content + '\n' + doc[j:]


def main():
    doc = open(INDEX).read()
    doc = splice(doc, 'TABLE', render_table())
    if len(sys.argv) > 1:
        doc = splice(doc, 'IDENTITY', render_identity(sys.argv[1]))
    open(INDEX, 'w').write(doc)


if __name__ == '__main__':
    main()
