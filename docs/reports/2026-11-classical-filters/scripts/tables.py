"""Prints the report's result tables as HTML from the probes' output in
../results (nr_results.json from parse_nr_log.py, nr_parity.txt,
ports_results.json, bench_results.json).

  python3 tables.py > tables.html
"""
import json
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
S = os.environ.get('RESULTS', os.path.join(HERE, '..', 'results'))


def load(name):
    p = os.path.join(S, name)
    return json.load(open(p)) if os.path.exists(p) else None


nr = load('nr_results.json')
if nr:
    for fx, by_sigma in nr['fixtures'].items():
        print(f'<table><caption>{fx}: luma / chroma (U) PSNR in dB, each method at its best strength</caption>')
        sigmas = list(by_sigma)
        print('<tr><th>method</th>' + ''.join(f'<th>σ {float(s):g}: Y</th><th>U</th><th>strength</th>' for s in sigmas)
              + '</tr>')
        print('<tr><td>noisy input</td>' + ''.join(
            f'<td>{by_sigma[s]["noisy_psnr_y"]:.2f}</td><td></td><td></td>' for s in sigmas) + '</tr>')
        methods = list(by_sigma[sigmas[0]]['methods'])
        for m in methods:
            cells = ''
            for s in sigmas:
                r = by_sigma[s]['methods'][m]
                best_y = max(v['psnr_y'] for v in by_sigma[s]['methods'].values())
                mark = ' class="b"' if r['psnr_y'] == best_y else ''
                cells += f'<td{mark}>{r["psnr_y"]:.2f}</td><td>{r["psnr_u"]:.2f}</td><td>{r["best_strength"]:g}</td>'
            print(f'<tr><td>{m}</td>{cells}</tr>')
        print('</table>')
par = os.path.join(S, 'nr_parity.txt')
if os.path.exists(par):
    print('<table><caption>Depth parity: mean |8-bit run − N-bit run|, 8-bit levels (luma), kodim08 sigma 8'
          '</caption><tr><th>method</th><th>10-bit</th><th>16-bit</th></tr>')
    for line in open(par):
        m = re.match(r'\s+(.+?)\s+10-bit ([\d.]+)\s+16-bit ([\d.]+)', line)
        if m:
            print(f'<tr><td>{m.group(1)}</td><td>{m.group(2)}</td><td>{m.group(3)}</td></tr>')
        elif 'vszip NLMeans vs KNLMeansCL' in line:
            print('</table><p>' + line.strip() + '</p>')

bench = load('bench_results.json')
if bench:
    print('<table><caption>Speed: vspipe, median of runs, frames per second (M1 Pro)</caption>'
          '<tr><th>method</th>' + ''.join(f'<th>{res}</th>' for res in bench) + '</tr>')
    first = list(bench)[0]
    for m in bench[first]:
        print(f'<tr><td>{m}</td>' + ''.join(f'<td>{bench[res][m]["median_fps"]:.1f}</td>' for res in bench) + '</tr>')
    print('</table>')

ports = load('ports_results.json')
if ports:
    for fx, rows in ports['vine'].items():
        print(f'<table><caption>Dehalo, {fx} (oversharpened): luma PSNR vs the clean pan</caption>'
              '<tr><th>method</th><th>Y dB</th></tr>')
        for n, r in rows.items():
            print(f'<tr><td>{n}</td><td>{r["psnr_y"]:.2f}</td></tr>')
        print('</table>')
    print('<table><caption>mpeg2stinx: PSNR vs the clean pan (Y / U dB)</caption><tr><th>fixture</th>'
          + ''.join(f'<th>{n}</th>' for n in next(iter(ports['mpeg2stinx'].values()))) + '</tr>')
    for fx, rows in ports['mpeg2stinx'].items():
        print(f'<tr><td>{fx}</td>' + ''.join(f'<td>{r["psnr_y"]:.2f} / {r["psnr_u"]:.2f}</td>' for r in rows.values())
              + '</tr>')
    print('</table>')
    f = ports['fades']
    print('<table><caption>IVTC fade fix (kodim23 pan, faded after the field split)</caption>'
          '<tr><th>measure</th><th>value</th></tr>')
    for k, v in f.items():
        print(f'<tr><td>{k}</td><td>{v:.4f}</td></tr>')
    print('</table>')
    print('<table><caption>Anti-aliasing (kodim08 pan)</caption><tr><th>method</th><th>mean change, levels</th></tr>')
    for n, r in ports['sangnom'].items():
        print(f'<tr><td>{n}</td><td>{r["change_vs_src"]:.2f}</td></tr>')
    print('</table>')
    print('<table><caption>Ports, depth parity: mean |8-bit − N-bit|, levels</caption>'
          '<tr><th>block</th><th>10-bit</th><th>16-bit</th></tr>')
    for n, r in ports['parity'].items():
        print(f'<tr><td>{n}</td><td>{r["10"]:.3f}</td><td>{r["16"]:.3f}</td></tr>')
    print('</table>')
