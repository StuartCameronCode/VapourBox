"""Write ../index.html from data/*.json. Run after choose_steps.py and
make_images.py."""
import html
import json
import os

from probelib import REPORT, load

choice = load('choice.json')
steps = load('steps.json')
fx = load('fixtures.json')
scd = load('scd.json')
STEPS = ['Light', 'Medium', 'Strong', 'Very strong']
NAMES = {'smdegrain': 'SMDegrain', 'mc_temporal_denoise': 'MCTemporalDenoise',
         'qtgmc_builtin': 'QTGMC built-in', 'mclean': 'mClean',
         'lsfmod': 'LSFmod', 'cas': 'CAS', 'awarpsharp2': 'aWarpSharp2'}
LABELS = {'smDegrainTr': 'Temporal Radius', 'smDegrainThSAD': 'Luma Threshold',
          'smDegrainThSADC': 'Chroma Threshold', 'smDegrainThSCD1': 'Scene-change threshold',
          'mcTemporalProfile': 'Settings', 'qtgmcEzDenoise': 'EZ Denoise',
          'mcleanStrength': 'Strength', 'mcleanThsad': 'Motion threshold', 'mcleanRn': 'Grain restore',
          'strength': 'Strength', 'overshoot': 'Overshoot', 'undershoot': 'Undershoot',
          'casSharpness': 'CAS Sharpness', 'warpDepth': 'Depth'}
NR_ORDER = ['smdegrain', 'mc_temporal_denoise', 'qtgmc_builtin', 'mclean']
SH_ORDER = ['lsfmod', 'cas', 'awarpsharp2']


def esc(x):
    return html.escape(str(x))


def values(p):
    return ', '.join(f'{LABELS.get(k, k)} {v}' for k, v in p.items())


def nr_table(method):
    r = choice['noise_reduction'][method]
    inp = r['input']
    rows = []
    rows.append('<tr class="input"><td>Input (noisy)</td><td></td>' +
                ''.join(f'<td>{inp[s]:.2f}</td>' for s in ['2', '4', '6', '9']) + '<td>—</td></tr>')
    for st in STEPS:
        c = r['chosen'][st]
        cells = []
        for s in ['2', '4', '6', '9']:
            best = max(x['score'][s] for x in r['candidates'])
            cls = ' class="own"' if {'Light': '2', 'Medium': '4', 'Strong': '6', 'Very strong': '9'}[st] == s else ''
            cells.append(f'<td{cls}>{c["score"][s]:.2f}<small> / {best:.2f}</small></td>')
        rows.append(f'<tr><td><b>{st}</b></td><td>{esc(values(c["params"]))}</td>{"".join(cells)}'
                    f'<td>{c["score"]["0"]:.2f}</td></tr>')
    return ('<table><tr><th>Step</th><th>Values</th><th>σ 2</th><th>σ 4</th><th>σ 6</th>'
            '<th>σ 9</th><th>clean in</th></tr>' + ''.join(rows) + '</table>')


def sh_table(method):
    r = choice['sharpen'][method]
    inp = r['input']
    rows = ['<tr class="input"><td>Input (blurred)</td><td></td>' +
            ''.join(f'<td>{inp[b]:.2f}</td>' for b in ['0.5', '0.8', '1.2', '1.6']) + '<td>0</td><td></td></tr>']
    for st in STEPS:
        c = r['chosen'][st]
        cells = []
        for b in ['0.5', '0.8', '1.2', '1.6']:
            best = max(x['score'][b] for x in r['candidates'])
            cls = ' class="own"' if {'Light': '0.5', 'Medium': '0.8', 'Strong': '1.2', 'Very strong': '1.6'}[st] == b else ''
            cells.append(f'<td{cls}>{c["score"][b]:.2f}<small> / {best:.2f}</small></td>')
        halo = c['halo'].get('0')
        rows.append(f'<tr><td><b>{st}</b></td><td>{esc(values(c["params"]))}</td>{"".join(cells)}'
                    f'<td>{c["change"]:.2f}</td><td>{"—" if halo is None else f"{halo:.1f}"}</td></tr>')
    return ('<table><tr><th>Step</th><th>Values</th><th>blur 0.5</th><th>blur 0.8</th>'
            '<th>blur 1.2</th><th>blur 1.6</th><th>change</th><th>halo</th></tr>' + ''.join(rows) + '</table>')


def grid(prefix, method, input_name, input_label):
    cells = [f'<figure><a href="img/film_clean.png"><img src="img/film_clean.png" alt=""></a><figcaption>Clean original</figcaption></figure>',
             f'<figure><a href="img/{input_name}.png"><img src="img/{input_name}.png" alt=""></a><figcaption>{input_label}</figcaption></figure>']
    for st in STEPS:
        f = f'img/{prefix}_{method}_{st.replace(" ", "_")}.png'
        if os.path.exists(os.path.join(REPORT, f)):
            cells.append(f'<figure><a href="{f}"><img src="{f}" alt=""></a><figcaption>{st}</figcaption></figure>')
    return '<div class="grid">' + ''.join(cells) + '</div>'


def scd_table():
    rows = []
    for sigma in ['0', '6', '9']:
        for th in ['800', '2000']:
            cells = ''.join(f'<td>{scd[f"{s}|{th}|{sigma}"]["away_mean"]:.2f} / {scd[f"{s}|{th}|{sigma}"]["near_min"]:.2f}</td>'
                            for s in ['400', '800', '1200', '2000', '4000'])
            rows.append(f'<tr><td>σ {sigma}</td><td>{th}</td>{cells}</tr>')
    return ('<table><tr><th>Noise</th><th>thSAD</th><th>thSCD1 400</th><th>800</th><th>1200</th>'
            '<th>2000</th><th>4000</th></tr>' + ''.join(rows) + '</table>')


nr = choice['noise_reduction']
sm = nr['smdegrain']
sm_med, sm_vs = sm['chosen']['Medium'], sm['chosen']['Very strong']
sm_best4 = max(c['score']['4'] for c in sm['candidates'])
fixture_rows = ''.join(
    f'<tr><td>{f}</td><td>{fx[f]["info"]["width"]}×{fx[f]["info"]["height"]} {fx[f]["info"]["pix_fmt"]}</td>' +
    ''.join(f'<td>{fx[f]["noisy"][s]["rms_y"]:.2f} / {fx[f]["noisy"][s]["noise_score"]:.2f}</td>' for s in ['2', '4', '6', '9']) +
    '</tr>' for f in ['cam', 'film', 'dvbt', 'vhs'])
hint = steps['noiseHint']
ns = choice['noiseScoreBySigma']

body = f"""
<h1>One Strength control for Noise Reduction and Sharpen</h1>
<p class="meta">Issue #177 · task #140 · 2026-11-28 · measured on Apple M1 (macOS arm64), deps 1.18.0-rc5, the debug worker</p>

<h2>Summary</h2>
<p>Issue #177 found Noise Reduction and Sharpen "not effective". The passes work, but their defaults are
gentle and the controls that make them stronger are per-method jargon. In simple mode each method now has
one <b>Strength</b> control (Light / Medium / Strong / Very strong) that sets the method's own parameters.
<b>Medium is each method's existing defaults</b> (the user's decision: existing output does not change), and
Light, Strong and Very strong were measured here. Advanced mode hides the control and shows the values it set.</p>
<ul>
<li><b>SMDegrain switched itself off on heavy noise.</b> At noise σ 9 it removed nothing at any Luma Threshold up
to 4000 ({sm['input']['9']:.2f} dB in, {sm_med['score']['9']:.2f} out at its default). The cause is MVTools'
scene-change threshold (<code>thSCD1</code>, havsfunc's 400): the block SAD of that much noise alone is over it,
so every frame read as a cut and was left alone. With <code>thSCD1</code> 800, tr 3 and thSAD 2000 the same clip
reaches {sm_vs['score']['9']:.2f} dB. A real hard cut is still found at every value up to 4000. A new parameter,
<code>smDegrainThSCD1</code> (default 400, so no existing script changes), is raised by SMDegrain's Strong and Very strong.</li>
<li><b>MCTemporalDenoise's Sigma control does nothing.</b> havsfunc reads <code>sigma</code> only for its pfMode 0 prefilter
or a <code>post</code> pass, and VapourBox passes neither: every sigma from 2 to 12 gave identical output at every profile.
The Strength steps set MCTD's own profile (low / medium / high / very high). The dead control is task #141.</li>
<li><b>QTGMC's built-in denoiser did nothing by default</b> (EZDenoise 0). Its default is now the measured Medium, 5.</li>
<li><b>SMDegrain's default is well short of what it can do</b> at moderate noise: σ 4 is {sm_med['score']['4']:.2f} dB at
the default, {sm_best4:.2f} at its best here. The default stays (Medium = defaults); Strong is where that gain is.</li>
</ul>

<h2>Method</h2>
<p>Every output in this report was made by the worker itself (<code>vapourbox-worker --config</code>, FFV1, lossless), so the
numbers are for exactly what the app runs.</p>
<h3>Fixtures</h3>
<p>Clean sources cut from committed test footage, stored losslessly and retimed to exactly 25 fps
(<code>build_fixtures.py</code>). Noisy copies add Gaussian noise with the app's own Grain pass (AddGrain, animated,
luma σ, chroma σ/2). Soft copies (Sharpen) blur every plane with ffmpeg's <code>gblur</code>.</p>
<table><tr><th>Fixture</th><th>Picture</th><th>σ 2</th><th>σ 4</th><th>σ 6</th><th>σ 9</th></tr>{fixture_rows}</table>
<p class="cap">Measured noise per fixture: luma RMS of noisy − clean / the worker's own noise score (<code>--detect-noise-halo</code>).
<code>cam</code> is small_clip.mp4 (camera, 320×240), <code>film</code> colorize_test.mp4 (640×480), <code>dvbt</code> the
top fields of the DVB-T broadcast clip, <code>vhs</code> interlaced_test.avi (used only for QTGMC's denoiser, which needs
deinterlacing on; its reference is the clean source through the same QTGMC with no denoising).</p>
<p class="correction"><b>Correction, in place:</b> the first fixtures kept their source rates (29.97 and 24 fps) in Matroska,
whose 1 ms time base can't hold them exactly. The worker's source grid then repeated and dropped frames against ffmpeg's
frame-by-frame reading, and an untouched passthrough read 33 dB instead of identical. Every fixture is now retimed to 25 fps;
the passthrough is bit-exact on all four. No number below comes from the first fixtures.</p>

<h3>Measures and their limits</h3>
<ul>
<li><b>Noise Reduction:</b> luma PSNR of the output against the clean source, mean over <code>cam</code>, <code>film</code>,
<code>dvbt</code>, at noise σ 2, 4, 6, 9. PSNR rewards smoothing: a setting that wipes texture can score well. So each
setting's <b>cost on a clean picture</b> (the clean source through it, against itself) is measured too, and is what orders
"stronger" (more damage to a clean picture = stronger). SSIM is recorded in <code>choice.json</code> and agrees on the order.</li>
<li><b>Sharpen:</b> luma PSNR against the <b>unblurred</b> original of a copy blurred by σ 0.5, 0.8, 1.2, 1.6 px: how much of
the softening a setting undoes. That rewards restoring detail, not perceived crispness, and a blur is not every kind of
softness (an upscale, a tape). "Stronger" is the mean absolute luma change a setting makes to a sharp picture. Halos are
the worker's halo score (% of the step; the pass list's threshold is 6), which under-reports ringing on soft edges.</li>
<li>Three short clips (60 frames) are not a population, and this is Apple Silicon only. Filters here are deterministic
across platforms (FFT3DFilter, DFTTest patched), but timings are not.</li>
</ul>

<h3>The rule</h3>
<p>Per method (<code>choose_steps.py</code>): Medium is the current default. Every other step is the setting with the best
mean PSNR at its own level (noise σ 2 / — / 6 / 9, blur 0.5 / — / 1.2 / 1.6), among settings on the right side of its
neighbours (Light weaker than Medium, Very strong stronger than Medium, Strong between). Any candidate within
{choice['tie']} dB of the best counts as equal; among equals a value a built-in preset uses wins, then the weakest, then
the better at the heaviest level, then the smallest values. Light may not have a larger temporal radius than Medium (it
would be slower). Each step sets the same parameters, so choosing Light after Very strong resets everything.
Exceptions, each for a measured reason, are stated with the method.</p>

<h2>Noise Reduction</h2>
<p>Each cell: the step's luma PSNR (dB) / the best any measured setting reached at that level. The shaded cell is the
level the step was chosen at. "clean in" is the cost on a clean picture (higher is gentler).</p>
"""

for m in NR_ORDER:
    body += f'<h3>{NAMES[m]}</h3>' + nr_table(m)
    if m == 'smdegrain':
        body += (f'<p>Grid: tr 1–4 × thSAD 150–4000 at thSCD1 400, then tr 2–3 × thSAD 400–2000 × thSCD1 800 / 1200. '
                 'tr 4 measured identical to tr 3 (havsfunc stops at 3) and was dropped. thSCD1 800 and 1200 gave identical output '
                 'everywhere, and both identical to 400 on a clean picture and at σ ≤ 6.</p>'
                 '<p>Light is tr 2 / 200, not the old <code>fromPreset(light)</code> tr 1 / 200, which was 1.1 dB worse at σ 2. '
                 'The DV Camcorder, Low-Light and SD Tape → HD presets used that and now use Light (output changes, slightly '
                 'stronger and slower).</p>')
        body += '<h4>Does a higher thSCD1 blend across real cuts?</h4>' + scd_table() + (
            '<p class="cap">A hard cut to another shot (<code>probe_scd.py</code>): mean luma PSNR away from the cut / the lowest of the '
            'six frames around it, tr 3. Every thSCD1 from 800 to 4000 gives identical output: the cut is still detected, since '
            'its block SAD is far above all of them. The one cost is at σ 6, thSAD 2000: the frames at the cut 0.8 dB lower '
            'than at 400. At σ 9 the default 400 leaves the whole clip noisy.</p>')
    if m == 'mc_temporal_denoise':
        body += ('<p>Strength sets the profile only. Sigma is inert (identical results for 2–12 at every profile and radius; '
                 'havsfunc uses it only for pfMode 0 or <code>post</code> &gt; 0). Radius moved results far less than the profile '
                 'and mostly costs time, so it stays its own control at its default (2).</p>')
    if m == 'qtgmc_builtin':
        body += ('<p>Its default was EZDenoise 0, which does nothing; Medium is measured like the other steps and becomes the '
                 'default. Very strong is at the top of the grid (10), and σ 9 was still improving there. On the interlaced '
                 '<code>vhs</code> fixture only.</p>')
    if m == 'mclean':
        body += ('<p>mClean\'s Grain restore (rn) puts grain back, which costs a clean picture while denoising less, so the clean '
                 'cost doesn\'t order its strength. Light to Strong keep the default rn 14. Above Medium the measurement plateaus '
                 '(strength is already at its maximum, 20, by default; a higher motion threshold helps only at σ 9), so Very '
                 'strong is the best at σ 9 that puts no grain back (rn 0). Strength sets Strength, Motion threshold and Grain restore.</p>')
    if m != 'qtgmc_builtin':
        body += grid('nr', m, 'nr_input_n6', 'Input, σ 6 noise')
        body += '<p class="cap">Frame 30 of <code>film</code> with σ 6 noise, 200×150 at 1:1, shown 2× (nearest neighbour). Click for full size.</p>'

body += """
<h2>Sharpen</h2>
<p>Each cell: luma PSNR against the unblurred original (dB) / the best any setting reached. "change" is the mean absolute
luma change on a sharp picture (8-bit levels), "halo" the worker's halo score on it (negative = none found).</p>
"""
for m in SH_ORDER:
    body += f'<h3>{NAMES[m]}</h3>' + sh_table(m)
    if m == 'lsfmod':
        body += ('<p>Grid: strength 50–500 × over/undershoot 1, 2, 4, 8 (equal). Strength above the old maximum (200) scored '
                 'best at the heavier blurs, so the schema\'s maximum rises. Light is strength 50 with overshoot 8: at a slight '
                 'blur a gentle strength that may overshoot restored more than a stronger one held to 1 level, which is what made '
                 'the old default barely visible (issue #177). The VHS Cleanup preset (80 / 1) now uses Light.</p>')
    if m == 'cas':
        body += ('<p>CAS stops at 1.0 (the plugin\'s limit), which is the best at the heaviest blur, so Very strong was chosen '
                 'before Strong. The SD Tape → HD preset (0.3) now uses Light, 0.4.</p>')
    if m == 'awarpsharp2':
        body += ('<p><b>PSNR cannot judge this method.</b> It warps pixels toward edges instead of raising contrast, and PSNR '
                 'against the sharp original reads moved pixels as error: no depth scored above the blurred input except '
                 'marginally at blur 1.6. Its steps are an even ladder of visible effect instead, the depth whose change is '
                 'nearest ½, 1, 1.5 and 2× Medium\'s (16). Judge it by the crops.</p>')
    body += grid('sh', m, 'sh_input_b12', 'Input, blur σ 1.2')
    body += '<p class="cap">Frame 30 of <code>film</code> blurred by σ 1.2 px, 200×150 at 1:1, shown 2×.</p>'

body += f"""
<h2>The noise hint</h2>
<p>For a source the worker already judged noisy (its <code>noiseHigh</code>), the Noise Reduction panel says which step usually
suits it. Advisory only: it never changes a value. Thresholds are halfway between the worker's own reading of the levels each
step was chosen at (σ 4, 6, 9 read as {ns['4']:.2f}, {ns['6']:.2f}, {ns['9']:.2f}; it reads white noise about 6% low):
Strong from {hint['Strong']}, Very strong from {hint['Very strong']}, Medium below. Below the worker's threshold nothing is
said, since a low score is not evidence (codec-skipped blocks read noiseless).</p>

<h2>Decisions</h2>
<ul>
<li><b>A four-step dropdown per method</b> (the user's choice), built on the schema's existing <code>parameterPresets</code>: in
simple mode it replaces the controls it sets. The step isn't stored; the dropdown shows the step the values match, and
"Custom" when none does.</li>
<li><b>Medium = existing defaults</b> (the user's choice). Exception: QTGMC built-in, whose default did nothing.</li>
<li><b>Built-in presets land on named steps</b> (the user's choice): DV Camcorder, Low-Light and SD Tape → HD Noise Reduction
move from tr 1 to tr 2 (Light); VHS Cleanup's LSFmod 80/1 moves to Light (50/8); SD Tape → HD's CAS 0.3 to 0.4.</li>
<li><b>SMDegrain's scene-change threshold becomes a parameter</b> rather than a fixed value: without it Strong and Very strong could
not reach heavy noise at all.</li>
<li><b>No Strength for advanced-only methods</b> (BM3D, KNLMeans, …): a preset is hidden in advanced mode, the only place they are offered.</li>
</ul>

<h2>Not tested</h2>
<ul>
<li>Real (not synthetic) noise and grain with a clean reference; temporal grain from film; compression noise.</li>
<li>x86 platforms, and the speed of each step on slower machines.</li>
<li>Strength above the grid's top where the best was still improving: QTGMC EZDenoise above 10, LSFmod above 500.</li>
<li>Perceptual measures (VMAF, a viewing panel). The crops are the check on PSNR.</li>
<li><b>Why MCTemporalDenoise's low and medium profiles do almost nothing at σ 6 and nothing at σ 9</b> (the heavy test's Light run
on σ 6 noise came out identical to its input). It looks like SMDegrain's scene-change fault (MCTD runs MVTools with its own
thresholds), but that was not tested; noted on task #141. Its Strong and Very strong profiles do work there.</li>
</ul>

<h2>Reproduce</h2>
<pre>cd docs/reports/issue-177-strength-mapping/scripts
export SCRATCH=/path/to/scratch       # ~2 GB of fixtures and outputs
python3 build_fixtures.py             # data/fixtures.json
python3 probe_nr.py                   # data/nr_runs.json   (~3 h on an M1)
python3 probe_scd.py                  # data/scd.json
python3 probe_sharpen.py              # data/sharpen_runs.json (~1.5 h)
python3 choose_steps.py               # data/steps.json, data/choice.json
python3 make_images.py                # img/
python3 fill_report.py                # index.html</pre>
<p>Needs the repo's deps bundle in <code>deps/&lt;platform&gt;</code> (or <code>$DEPS</code>) and a worker build
(<code>cd worker &amp;&amp; cargo build</code>; <code>$WORKER</code> overrides). Python 3 standard library only.
<code>data/steps.json</code> is what the app's schemas are pinned to (<code>strength_presets_test.dart</code>,
<code>test_272</code>).</p>
"""

page = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Strength mapping</title>
<style>
:root {{ --bg:#fff; --fg:#1d1d1f; --muted:#666; --line:#ddd; --own:#e8f0fe; --input:#f6f6f6; --corr:#fff4e5; }}
@media (prefers-color-scheme: dark) {{ :root {{ --bg:#16171a; --fg:#e8e8ea; --muted:#9a9a9f; --line:#333; --own:#1f2d44; --input:#222327; --corr:#3a2c14; }} }}
body {{ background:var(--bg); color:var(--fg); font:15px/1.55 -apple-system,system-ui,sans-serif; max-width:1100px; margin:0 auto; padding:24px 16px 64px; }}
h1 {{ font-size:1.7em; margin-bottom:.2em }} h2 {{ margin-top:2em; border-bottom:1px solid var(--line); padding-bottom:.2em }}
.meta, .cap, small {{ color:var(--muted) }} .cap {{ font-size:.9em }}
table {{ border-collapse:collapse; margin:.6em 0 1em; font-size:.9em; display:block; overflow-x:auto }}
th, td {{ border:1px solid var(--line); padding:4px 8px; text-align:right; white-space:nowrap }}
td:nth-child(2), th:nth-child(2), td:first-child {{ text-align:left }}
td.own {{ background:var(--own) }} tr.input td {{ background:var(--input) }}
.correction {{ background:var(--corr); padding:8px 12px; border-radius:6px }}
.grid {{ display:grid; grid-template-columns:repeat(auto-fill,minmax(200px,1fr)); gap:8px }}
figure {{ margin:0 }} figure img {{ width:100%; image-rendering:pixelated; display:block }} figcaption {{ font-size:.85em; color:var(--muted) }}
code, pre {{ font-family:ui-monospace,Menlo,monospace; font-size:.9em }} pre {{ background:var(--input); padding:10px; overflow-x:auto }}
</style></head><body>{body}</body></html>
"""
with open(os.path.join(REPORT, 'index.html'), 'w') as f:
    f.write(page)
print('wrote index.html')
