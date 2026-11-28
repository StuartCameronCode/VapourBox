"""Write ../index.html: the prose below with tables.py's tables spliced in."""
import os

import tables

HERE = os.path.dirname(os.path.abspath(__file__))

STYLE = """
:root { --bg:#fff; --fg:#1d1d1f; --muted:#666; --line:#ddd; --input:#f6f6f6; --corr:#fff4e5; }
@media (prefers-color-scheme: dark) { :root { --bg:#16171a; --fg:#e8e8ea; --muted:#9a9a9f; --line:#333; --input:#222327; --corr:#3a2c14; } }
body { background:var(--bg); color:var(--fg); font:15px/1.55 -apple-system,system-ui,sans-serif; max-width:1100px; margin:0 auto; padding:24px 16px 64px; }
h1 { font-size:1.7em; margin-bottom:.2em } h2 { margin-top:2em; border-bottom:1px solid var(--line); padding-bottom:.2em }
.meta, .cap { color:var(--muted) } .cap { font-size:.9em }
table { border-collapse:collapse; margin:.6em 0 1em; font-size:.9em; display:block; overflow-x:auto }
th, td { border:1px solid var(--line); padding:4px 8px; text-align:right; white-space:nowrap }
td:first-child, th:first-child { text-align:left }
code, pre { font-family:ui-monospace,Menlo,monospace; font-size:.9em } pre { background:var(--input); padding:10px; overflow-x:auto }
"""

BODY = """
<h1>MCTemporalDenoise's Sigma, and what replaced it</h1>
<p class="meta">Task #141 (found by task #140, issue #177) · 2026-11-28 · measured on Apple Silicon (macOS arm64), deps 1.18.0-rc5, the debug worker</p>

<h2>Summary</h2>
<ul>
<li><b>Sigma did nothing.</b> The Noise Reduction pass's MCTemporalDenoise method passed its Sigma slider as
<code>sigma=</code> to havsfunc r31's <code>MCTemporalDenoise</code>, which reads it only for its <code>pfMode=0</code>
(FFT3DFilter) prefilter. VapourBox never passes <code>pfMode</code> (havsfunc's default is 3, a DFTTest prefilter with a
fixed sigma), so every Sigma gave the same picture, to the sample. The control and its field
(<code>mcTemporalSigma</code>) are removed; saved jobs and presets that carry it still load.</li>
<li><b>Post-denoise replaces it</b> (<code>mcTemporalPost</code>, advanced mode, default 0 = off): havsfunc's own
<code>post</code>, an FFT3DFilter pass after the temporal denoise at that sigma. It acts strongly and in order
(medium at noise σ 6: 34.5 dB → 43.1 at post 8), but it is spatial, so on a clean picture it costs
1.3–10.7 dB (up to 4.4 at σ 2), and it slows the pass by 1.3–1.8x. That is why it is off by default, and why the Strength steps don't use it.
Off, the call is today's minus <code>sigma=</code>, which changes nothing.</li>
<li><b><code>pfMode=0</code> was the other way to make Sigma act</b>, and was rejected: it replaces the prefilter for
every job, so the default output would change, and it recovers less than <code>post</code> at heavy noise.</li>
<li><b>The low and medium profiles doing nothing on heavy noise is not SMDegrain's scene-change fault.</b>
Raising <code>thSCD1</code> (issue #177's fix for SMDegrain) gains at most 0.7 dB; <code>thSAD</code> 600/1200 at most
0.15; <code>limit=0</code> (no cap at the prefilter's change) about 3 dB at σ 6 (medium only) and nothing at σ 9, at 2–5 dB on clean
pictures. Low and medium are profiles for light noise; high and very high (Strong and Very strong) are the ones
for heavy noise, as the Strength steps' descriptions say. Nothing changes for it.</li>
<li><b>Found on the way: the preview of MCTD's high and very high profiles was not the encode.</b> They run
MDegrain twice and a stabilizing TTempSmooth, so they read up to 6 frames each side (8 with <code>post</code> at very
high); the preview decoded 3, and high's preview was up to 2 levels off its lossless encode. The worker now
declares MCTD's reach from its profile, radius and <code>post</code> (<code>NoiseReductionParameters::mctd_reach</code>),
and the preview matches the encode sample for sample
(<code>integration_fft3dfilter_determinism_test.dart</code>).</li>
</ul>

<h2>Method</h2>
<p>Fixtures are issue #177's (<a href="../issue-177-strength-mapping/index.html">report</a>): 60 frames each of
<code>cam</code> (small_clip.mp4, 320x240), <code>film</code> (colorize_test.mp4, 640x480) and <code>dvbt</code>
(a broadcast field, 720x288), all 4:2:0 8-bit at 25 fps, lossless, and copies with the worker's AddGrain noise at
luma σ 2, 4, 6 and 9 (chroma σ/2). Every MCTD run is an encode by the worker with the Noise Reduction pass off and
the call in Custom VapourSynth, so it is the template's call plus the probed arguments, at radius 2 (the app's
default), to lossless FFV1. The score is ffmpeg's luma PSNR against the clean clip, frames 0–2 skipped.
Scripts: <code>scripts/probe_grid.py</code> (everything but the cut), <code>scripts/probe_cut.py</code>,
<code>scripts/tables.py</code> and <code>scripts/make_report.py</code> (this page); data in <code>data/</code>.</p>
<pre>SCRATCH=/your/scratch python3 ../issue-177-strength-mapping/scripts/build_fixtures.py
SCRATCH=/your/scratch JOBS=6 python3 scripts/probe_grid.py
SCRATCH=/your/scratch python3 scripts/probe_cut.py
python3 scripts/make_report.py</pre>
<p><b>Limits.</b> Synthetic, uncorrelated noise; three 60-frame clips; one machine (Apple Silicon); PSNR only
(no visual review), which favours smoothing. Times are whole worker jobs run six at a time, including
start-up, so only their ratios mean anything.</p>

<h2>1. Sigma is inert</h2>
<p>Luma PSNR (dB) at the app's call before this task (sigma 4). Sigma 2, 8 and 16 were run in every cell too.</p>
<!-- table:sigma -->

<h2>2. Post-denoise (<code>post</code>)</h2>
<p>Luma PSNR (dB). "input" is the noisy clip against the clean one.</p>
<!-- table:post -->

<h2>3. <code>pfMode=0</code> against <code>post</code> (medium profile)</h2>
<p>With <code>pfMode=0</code> Sigma does act, but it moves the default picture (σ 4 is not "today"), and at σ 6–9
<code>post</code> recovers more.</p>
<!-- table:pf0 -->

<h2>4. Low and medium on heavy noise</h2>
<p>What issue #177 suggested (<code>thSCD1</code>), and the profile's other thresholds, against <code>post</code>.</p>
<!-- table:heavy -->

<h2>5. Should the Strength steps add <code>post</code>?</h2>
<p>Strong (high) and Very strong (very high) at their own noise level (issue #177's hints, σ 4.7 and 7.0, nearest
fixture) and on the clean clip. <code>post</code> adds at most half a dB where the step is meant to be used and
costs 1.3–3.4 dB on clean pictures, so the steps stay as task #140 measured them.</p>
<!-- table:steps -->

<h2>6. Speed</h2>
<p>Mean time per job over the five noise levels (seconds; see the limits above).</p>
<!-- table:timing -->

<h2>7. <code>thSCD1</code> at a real cut</h2>
<p>Issue #177's cut fixture. Each cell: lowest PSNR of the six frames around the cut / mean of the frames away
from it. Every <code>thSCD1</code> gives the default's numbers: raising it would neither help nor hurt here.</p>
<!-- table:cut -->

<h2>8. The preview's window</h2>
<p>From havsfunc r31's defaults per profile (very low, low, medium, high, very high): <code>twopass</code>
F F F T T, <code>stabilize</code> F F F T T, <code>maxr</code> 1 1 2 2 2, FFT3D <code>bt</code> 1 3 3 3 4. MDegrain reads
<code>radius</code> frames each side, a second pass reads the first's neighbours (2 × radius), TTempSmooth
<code>maxr</code> more, and <code>post</code> FFT3D's window (bt 2–3 one frame back, bt 4 two). So the reach is 2
(very low, radius 2) to 8 (very high, radius 2, with <code>post</code>), and 10 at radius 4. With the old fixed
window of 3, two previews of frame 48 of <code>colorize_test.mp4</code> at high (trim 40–59) agreed with each other
and were up to 2 levels from the lossless encode (mean 0.0017); medium was exact. With the reach declared, high and
very high, with and without <code>post</code>, are exact.</p>
"""


def main():
    html = BODY
    for name, fn in tables.SECTIONS.items():
        html = html.replace(f'<!-- table:{name} -->', fn())
    with open(os.path.join(HERE, '..', 'index.html'), 'w') as f:
        f.write('<!doctype html>\n<html lang="en"><head><meta charset="utf-8">'
                '<meta name="viewport" content="width=device-width,initial-scale=1">\n'
                '<title>MCTD Sigma</title>\n<style>' + STYLE + '</style></head><body>\n'
                + html.strip() + '\n</body></html>\n')


if __name__ == '__main__':
    main()
