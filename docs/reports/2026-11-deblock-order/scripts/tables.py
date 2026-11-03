#!/usr/bin/env python3
"""Prints the report's result tables as HTML, from ../results.csv and
../results_strong.csv (copies of run.sh's and strong.sh's output).

usage: python3 -I tables.py > tables.html
"""
import csv
import os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

ORDER_LABEL = {
    'none': 'no deblock',
    'after': 'after QTGMC (today)',
    'woven': 'woven frame, before',
    'field': 'per field, before',
}


def load(name):
    with open(os.path.join(ROOT, name)) as f:
        return list(csv.DictReader(f))


def table(rows, deint, method, caption, with_vmaf=True, base_rows=None):
    base_rows = [r for r in (base_rows or rows) if r['deint'] == deint]
    rows = [r for r in rows if r['deint'] == deint and r['bitrate'] != 'clean'
            and (r['method'] in (method, '-'))]
    out = [f'<table><caption>{caption}</caption>',
           '<tr><th>Fixture</th><th>kbps</th><th>Order</th><th>PSNR-Y dB</th>'
           '<th>Δ vs none</th><th>SSIM-Y</th>' + ('<th>VMAF</th>' if with_vmaf else '') +
           '<th>Blockiness</th></tr>']
    base = {}
    for r in base_rows:
        if r['order'] == 'none':
            base[(r['fixture'], r['bitrate'])] = float(r['psnr_y'])
    best = {}
    for r in rows:
        k = (r['fixture'], r['bitrate'])
        if r['order'] != 'none':
            best[k] = max(best.get(k, -1), float(r['psnr_y']))
    for r in rows:
        k = (r['fixture'], r['bitrate'])
        p = float(r['psnr_y'])
        d = f'{p - base[k]:+.2f}' if k in base and r['order'] != 'none' else ''
        cls = ' class="best"' if r['order'] != 'none' and p == best.get(k) else ''
        out.append(
            f'<tr{cls}><td>{r["fixture"]}</td><td>{r["bitrate"]}</td>'
            f'<td>{ORDER_LABEL[r["order"]]}</td><td>{p:.2f}</td><td>{d}</td>'
            f'<td>{float(r["ssim_y"]):.4f}</td>' +
            (f'<td>{float(r["vmaf"]):.2f}</td>' if with_vmaf else '') +
            f'<td>{float(r["blockiness"]):.2f}</td></tr>')
    out.append('</table>')
    return '\n'.join(out)


main = load('results.csv')
strong = load('results_strong.csv')
print('<!-- T1 -->')
print(table(main, '1', 'qed', 'Deinterlaced (QTGMC Slower), Deblock_QED 24/26'))
print('<!-- T2 -->')
print(table(main, '0', 'qed', 'Left interlaced, Deblock_QED 24/26'))
print('<!-- T3 -->')
print(table(main, '1', 'simple', 'Deinterlaced, Deblock (simple) quant 24'))
print('<!-- T4 -->')
print(table(strong, '1', 'qed-36/44', 'Deinterlaced, Deblock_QED 36/44 (strong), 1000 kbps',
            with_vmaf=False, base_rows=main))
print(table(strong, '0', 'qed-36/44', 'Left interlaced, Deblock_QED 36/44 (strong), 1000 kbps',
            with_vmaf=False, base_rows=main))
