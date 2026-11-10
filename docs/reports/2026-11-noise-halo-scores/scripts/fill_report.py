"""Write ../index.html from $SCRATCH/fx/{final,candidates,parity,timing}.json.

The prose is in this file; every number in a table or chart comes from those
JSON files (measure_final.py, measure_candidates.py, worker_parity.py,
timing.py). The exploration tables quoted in "How the measures were chosen"
are printed by explore.py.
"""
import html
import json
import os

import probelib as L

HERE = os.path.dirname(os.path.abspath(__file__))
FX = L.scratch('fx')
final = json.load(open(os.path.join(FX, 'final.json')))
cand = json.load(open(os.path.join(FX, 'candidates.json')))
parity = json.load(open(os.path.join(FX, 'parity.json')))
timing = json.load(open(os.path.join(FX, 'timing.json')))


def fmt(v, d=2):
    return '–' if v is None else f'{v:.{d}f}'


def sep(key, cls_key, values):
    """Clean max, grey range, high min for one score."""
    out = {}
    for c in ('clean', 'grey', 'high'):
        vs = [(v, n) for n, v in values.items() if final[n][cls_key] == c and v is not None]
        out[c] = vs
    return out


def strip(key, cls_key, thr, lo, hi, unit):
    """A strip chart: one row per class, a dot per fixture, the threshold."""
    W, H, pad = 900, 150, 110
    rows = {'clean': 30, 'grey': 70, 'high': 110}
    col = {'clean': 'var(--c-clean)', 'grey': 'var(--c-grey)', 'high': 'var(--c-high)'}

    def x(v):
        v = min(max(v, lo), hi)
        return pad + (W - pad - 20) * (v - lo) / (hi - lo)
    parts = [f'<svg viewBox="0 0 {W} {H}" role="img" aria-label="{key} score by ground-truth class">']
    for c, y in rows.items():
        parts.append(f'<text x="8" y="{y + 4}" class="ax">{c}</text>')
        parts.append(f'<line x1="{pad}" x2="{W - 20}" y1="{y}" y2="{y}" class="grid"/>')
    for n, v in final.items():
        s = v[key]
        if s is None:
            continue
        c = v[cls_key]
        parts.append(f'<circle cx="{x(s):.1f}" cy="{rows[c]}" r="4" fill="{col[c]}" fill-opacity="0.7">'
                     f'<title>{html.escape(n)}: {s:.2f}</title></circle>')
    tx = x(thr)
    parts.append(f'<line x1="{tx:.1f}" x2="{tx:.1f}" y1="12" y2="{H - 22}" class="thr"/>')
    parts.append(f'<text x="{tx + 4:.1f}" y="16" class="ax">threshold {thr:g}</text>')
    step = (hi - lo) / 6
    for i in range(7):
        v = lo + i * step
        parts.append(f'<text x="{x(v):.1f}" y="{H - 6}" class="ax" text-anchor="middle">{v:g}</text>')
    parts.append(f'<text x="{W - 20}" y="{H - 6}" class="ax" text-anchor="end">{unit}</text></svg>')
    return '\n'.join(parts)


def fixture_table():
    rows = []
    for n, v in final.items():
        nv, hv = v['noise'], v['halo']
        nc = 'good' if (v['noise_high'] == (v['noise_class'] == 'high')) or v['noise_class'] == 'grey' else 'bad'
        hc = 'good' if (v['halo_high'] == (v['halo_class'] == 'high')) or v['halo_class'] == 'grey' else 'bad'
        sigma = '' if v['sigma'] is None else f"{v['sigma']:g}"
        rows.append(
            f"<tr><td><code>{n}</code></td><td>{html.escape(v['group'])}</td>"
            f"<td>{sigma}</td>"
            f"<td>{html.escape(v['sharpen'] or '')}</td>"
            f"<td>{v['noise_class']}</td><td class='{nc}'>{fmt(nv)}{' ●' if v['noise_high'] else ''}</td>"
            f"<td>{v['halo_class']}</td><td class='{hc}'>{fmt(hv)}{' ●' if v['halo_high'] else ''}</td>"
            f"<td>{v['halo_edges']}</td></tr>")
    return '\n'.join(rows)


def candidate_noise_table():
    """Clean max vs the white sigma 4 and tape sigma 6 fixtures, per candidate."""
    keys = [('whole', 'Immerkær, whole picture'), ('blk10', 'Immerkær, 10th pct of 16×16 blocks'),
            ('temporal', 'frame difference, no motion compensation'), ('tout', 'signalstats TOUT (VCG v1)'),
            ('ydif', 'signalstats YDIF (VCG v1)')]
    # Classes from the final manifest (candidates.json was measured before two relabels).
    clean = [n for n in cand if final[n]['noise_class'] == 'clean' and 'usm' not in n and 'peak' not in n]
    n4 = [n for n in cand if n.endswith('_n4') and not n.startswith('kodak08_10bit')]
    t6 = [n for n in cand if n.endswith('_tape6')]
    rows = []
    for k, label in keys:
        cm = max(clean, key=lambda n: cand[n][k])
        rows.append(f"<tr><td>{label}</td><td>{cand[cm][k]:.3f} <small>({cm})</small></td>"
                    f"<td>{min(cand[n][k] for n in n4):.3f}–{max(cand[n][k] for n in n4):.3f}</td>"
                    f"<td>{min(cand[n][k] for n in t6):.3f}–{max(cand[n][k] for n in t6):.3f}</td></tr>")
    fclean = [n for n, v in final.items() if v['noise_class'] == 'clean' and v['noise'] is not None]
    cm = max(fclean, key=lambda n: final[n]['noise'])
    rows.append(f"<tr class='chosen'><td><strong>motion-compensated, 10th pct of blocks, 25th pct of pairs "
                f"(chosen)</strong></td><td>{final[cm]['noise']:.3f} <small>({cm})</small></td>"
                f"<td>{min(final[n]['noise'] for n in n4):.3f}–{max(final[n]['noise'] for n in n4):.3f}</td>"
                f"<td>{min(final[n]['noise'] for n in t6):.3f}–{max(final[n]['noise'] for n in t6):.3f}</td></tr>")
    return '\n'.join(rows)


def candidate_halo_table():
    clean = [n for n in cand if final[n]['halo_class'] == 'clean']
    usm1 = [n for n in cand if n.endswith('_usm1_1') and n != 'kodak08_10bit_usm1_1']
    rows = []
    for k, label in [('vcg', 'share of strong edges with a two-sided overshoot (VCG v1 idea)'),
                     ('esf', 'mean edge profile, no line coherence')]:
        vals = [cand[n][k] for n in clean if cand[n][k] == cand[n][k]]
        rows.append(f"<tr><td>{label}</td><td>{max(vals):.3f}</td>"
                    + ''.join(f"<td>{cand[n][k]:.3f}</td>" for n in usm1) + '</tr>')
    vals = [final[n]['halo'] for n in final if final[n]['halo_class'] == 'clean' and final[n]['halo'] is not None]
    rows.append("<tr class='chosen'><td><strong>per-edge two-sided overshoot, 7 lines (chosen)</strong></td>"
                f"<td>{max(vals):.3f}</td>" + ''.join(f"<td>{fmt(final[n]['halo'], 3)}</td>" for n in usm1) + '</tr>')
    head = ''.join(f'<th>{n}</th>' for n in usm1)
    return head, '\n'.join(rows)


def parity_table():
    rows = []
    for n, v in parity.items():
        if n.startswith('_') or 'reference' in v:
            continue
        r = v['worker']
        rows.append(f"<tr><td>{n}</td><td>{fmt(r.get('noise'))}</td><td>{fmt(r.get('halo'))}</td>"
                    f"<td>{r.get('haloEdges')}</td><td>{r.get('usablePairs')}</td>"
                    f"<td>{'yes' if r.get('noiseHigh') else 'no'} / {'yes' if r.get('haloHigh') else 'no'}</td></tr>")
    return '\n'.join(rows)


def timing_table():
    return '\n'.join(f"<tr><td>{n}</td><td>{v['seconds']:.1f} s</td><td>{len(v['report'].get('frames', []))}</td></tr>"
                     for n, v in timing.items())


ns = {n: v['noise'] for n, v in final.items()}
hs = {n: v['halo'] for n, v in final.items()}
nclean = max(v for n, v in ns.items() if v is not None and final[n]['noise_class'] == 'clean')
hclean = max(v for n, v in hs.items() if v is not None and final[n]['halo_class'] == 'clean')
fp_n = [n for n in final if final[n]['noise_class'] == 'clean' and final[n]['noise_high']]
fp_h = [n for n in final if final[n]['halo_class'] == 'clean' and final[n]['halo_high']]
miss_n = [n for n in final if final[n]['noise_class'] == 'high' and not final[n]['noise_high']]
miss_h = [n for n in final if final[n]['halo_class'] == 'high' and not final[n]['halo_high']]
n_high = sum(1 for n in final if final[n]['noise_class'] == 'high')
h_high = sum(1 for n in final if final[n]['halo_class'] == 'high')
worst = parity['_worst']
differ = [n for n, v in parity.items() if isinstance(v, dict) and v.get('same_verdict') is False]
hhead, hrows = candidate_halo_table()

template = open(os.path.join(HERE, 'report_template.html')).read()
out = template
for k, v in {
    'NOISE_THR': f'{L.NOISE_HIGH:g}', 'HALO_THR': f'{L.HALO_HIGH:g}',
    'NOISE_CLEAN_MAX': f'{nclean:.2f}', 'HALO_CLEAN_MAX': f'{hclean:.2f}',
    'NOISE_FP': str(len(fp_n)), 'HALO_FP': str(len(fp_h)),
    'NOISE_MISS': f'{len(miss_n)} of {n_high}', 'HALO_MISS': f'{len(miss_h)} of {h_high}',
    'NOISE_MISSED': ', '.join(f'<code>{n}</code>' for n in miss_n),
    'HALO_MISSED': ', '.join(f'<code>{n}</code>' for n in miss_h),
    'N_FIXTURES': str(len(final)),
    'NOISE_STRIP': strip('noise', 'noise_class', L.NOISE_HIGH, 0, 8, 'σ, 8-bit levels'),
    'HALO_STRIP': strip('halo', 'halo_class', L.HALO_HIGH, -10, 50, '% of the step (clipped at 50)'),
    'FIXTURE_ROWS': fixture_table(),
    'CAND_NOISE_ROWS': candidate_noise_table(),
    'CAND_HALO_HEAD': hhead, 'CAND_HALO_ROWS': hrows,
    'PARITY_NOISE': f"{worst['noise']:.2g}", 'PARITY_HALO': f"{worst['halo']:.2g}",
    'PARITY_DIFFER': str(len(differ)),
    'PARITY_ROWS': parity_table(), 'TIMING_ROWS': timing_table(),
}.items():
    out = out.replace('{{' + k + '}}', v)
assert '{{' not in out, out[out.index('{{'):out.index('{{') + 40]
open(os.path.join(HERE, '..', 'index.html'), 'w').write(out)
print('wrote index.html')
