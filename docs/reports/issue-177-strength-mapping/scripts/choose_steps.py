"""Choose the four Strength steps per method from the probe's runs, and write
data/steps.json (the file the app's schemas are pinned to) and
data/choice.json (every candidate's scores, for the report).

The rule, per method:

* A setting's *strength* is what it costs a clean picture: its luma PSNR
  against the clean source when given that clean source (Noise Reduction), or
  how far it moves a sharp picture (mean absolute luma change, Sharpen). Steps
  must get strictly stronger in that order: Light < Medium < Strong < Very
  strong.
* Medium is the method's current default (the user's decision, so existing
  output does not change), except QTGMC's built-in denoiser, whose default
  (EZDenoise 0) does nothing; its Medium is measured like the other steps.
* Each other step is the setting with the best mean luma PSNR (over the
  fixtures) against the clean source at that step's level: noise sigma 2 / 4 /
  6 / 9 (Noise Reduction) or blur sigma 0.5 / 0.8 / 1.2 / 1.6 px (Sharpen),
  among settings on the right side of its neighbours.
* Ties: any candidate within TIE dB of the best counts as equal. Among equals,
  a value a built-in preset already uses wins (so presets stay on named
  steps), then the weakest (least clean-picture cost), then the fastest.
"""
import json
from collections import defaultdict

from probelib import load, save

TIE = 0.15
NR_LEVELS = {'Light': 2, 'Medium': 4, 'Strong': 6, 'Very strong': 9}
SH_LEVELS = {'Light': 0.5, 'Medium': 0.8, 'Strong': 1.2, 'Very strong': 1.6}
STEPS = list(NR_LEVELS)

NR_DEFAULTS = {
    'smdegrain': {'smDegrainTr': 2, 'smDegrainThSAD': 300, 'smDegrainThSADC': 150,
                  'smDegrainThSCD1': 400},
    'mc_temporal_denoise': {'mcTemporalProfile': 'medium'},
    'mclean': {'mcleanStrength': 20, 'mcleanThsad': 400, 'mcleanRn': 14},
    'qtgmc_builtin': None,  # measured
}


def normalise(method, params):
    """The values a Strength step sets, or None to leave the run out.

    Every step of a method must set the same keys, or choosing a lighter step
    after a stronger one would leave the stronger one's extra value behind."""
    p = dict(params)
    if method == 'smdegrain':
        if p['smDegrainTr'] > 3:
            return None  # tr 4 measured identical to tr 3, and the schema stops at 3
        p.setdefault('smDegrainThSCD1', 400)
    elif method == 'mc_temporal_denoise':
        # sigma is inert (havsfunc uses it only with pfMode 0 or post > 0):
        # every sigma at one profile/radius measured identical. Keep one run.
        if p.pop('mcTemporalSigma') != 4.0:
            return None
        # The profile is MCTD's own strength; radius moved the result far less
        # and mostly costs time, so it stays its own control at its default.
        if p.pop('mcTemporalRadius') != 2:
            return None
    elif method == 'qtgmc_builtin':
        p.pop('qtgmcEzKeepGrain')
    return p
SH_DEFAULTS = {
    'lsfmod': {'strength': 100, 'overshoot': 1, 'undershoot': 1},
    'cas': {'casSharpness': 0.5},
    'awarpsharp2': {'warpDepth': 16},
}
# Values built-in presets use today (processing_preset.dart), preferred on a tie.
PRESET_VALUES = [
    {'smDegrainTr': 1, 'smDegrainThSAD': 200, 'smDegrainThSADC': 100},  # fromPreset(light)
    {'strength': 80, 'overshoot': 1, 'undershoot': 1},                  # VHS Cleanup
    {'casSharpness': 0.3},                                              # SD Tape -> HD
]


def _params_key(p):
    return json.dumps({k: v for k, v in sorted(p.items()) if k != 'method'})


def table(runs, level_field):
    """{method: {params_key: {'params', level: {fixture: run}}}}"""
    t = defaultdict(lambda: defaultdict(lambda: {'params': None, 'by': defaultdict(dict)}))
    inputs = defaultdict(dict)
    for r in runs.values():
        if r['method'] == 'input':
            inputs[r[level_field]][r['fixture']] = r
            continue
        params = normalise(r['method'], {k: v for k, v in r['params'].items() if k != 'method'}) \
            if level_field == 'sigma' else {k: v for k, v in r['params'].items() if k != 'method'}
        if params is None:
            continue
        e = t[r['method']][_params_key(params)]
        e['params'] = params
        e['by'][r[level_field]][r['fixture']] = r
    return t, inputs


def mean(xs):
    xs = list(xs)
    return sum(xs) / len(xs) if xs else float('nan')


def choose(cands, levels, defaults, strength_of, preset_values):
    """cands: list of dicts with 'params', 'score' {level: psnr}, 'cost', 'secs'.
    strength_of(c): bigger = stronger."""
    def is_preset(c):
        return any(all(c['params'].get(k) == v for k, v in pv.items()) and
                   set(pv) <= set(c['params']) for pv in preset_values)

    def best(pool, level):
        if not pool:
            raise SystemExit(f'no candidate is on the right side of its neighbours at {level}')
        top = max(c['score'][level] for c in pool)
        equal = [c for c in pool if c['score'][level] >= top - TIE]
        heaviest = max(levels.values())
        # Then, among settings that score the same here and cost the same on a
        # clean picture, the one that does better at the heaviest level
        # (SMDegrain's raised thSCD1 changes nothing below sigma 9).
        # Then the smallest values (nearest the plugin's defaults: thSCD1 800
        # and 1200 measured identical everywhere); wall-clock time last.
        numeric = lambda c: tuple(v for _, v in sorted(c['params'].items()) if isinstance(v, (int, float)))
        equal.sort(key=lambda c: (not is_preset(c), strength_of(c),
                                  -c['score'][heaviest], numeric(c), c['secs']))
        return equal[0]

    chosen = {}
    if defaults is not None:
        med = [c for c in cands if all(c['params'].get(k) == v for k, v in defaults.items())]
        assert med, f'default {defaults} is not in the grid'
        chosen['Medium'] = med[0]
    else:
        chosen['Medium'] = best(cands, levels['Medium'])
    m = strength_of(chosen['Medium'])
    # A lighter step is never slower than Medium: its temporal radius (what the
    # time grows with; wall-clock times under a parallel probe are too noisy
    # to compare) is not above Medium's.
    radius = lambda c: c['params'].get('smDegrainTr', c['params'].get('mcTemporalRadius', 0))
    chosen['Light'] = best([c for c in cands if strength_of(c) < m and
                            radius(c) <= radius(chosen['Medium'])], levels['Light'])
    # Very strong before Strong: a method whose best setting at the heaviest
    # level is its strongest (CAS at its 1.0 limit) would otherwise leave
    # nothing stronger than Strong.
    chosen['Very strong'] = best([c for c in cands if strength_of(c) > m], levels['Very strong'])
    v = strength_of(chosen['Very strong'])
    chosen['Strong'] = best([c for c in cands if m < strength_of(c) < v], levels['Strong'])
    return chosen


def ladder(cands, defaults, strength_of, ratios):
    """Steps by effect alone, for a method PSNR cannot judge: the candidate
    whose strength is nearest each ratio of Medium's."""
    med = [c for c in cands if all(c['params'].get(k) == v for k, v in defaults.items())][0]
    m = strength_of(med)
    return {st: min(cands, key=lambda c: (abs(strength_of(c) / m - r), strength_of(c)))
            for st, r in ratios.items()}


def nr():
    runs = load('nr_runs.json')
    t, inputs = table(runs, 'sigma')
    out, report = {}, {}
    for method, entries in t.items():
        fixtures = ['vhs'] if method == 'qtgmc_builtin' else ['cam', 'film', 'dvbt']
        cands = []
        for e in entries.values():
            if not all(set(fixtures) <= set(e['by'].get(s, {})) for s in [0] + list(NR_LEVELS.values())):
                continue  # incomplete (a point dropped from the grid part way)
            score = {s: mean(e['by'][s][f]['psnr_y'] for f in fixtures)
                     for s in [0] + list(NR_LEVELS.values())}
            ssim = {s: mean(e['by'][s][f]['ssim_y'] for f in fixtures) for s in score}
            secs = mean(e['by'][4][f]['secs'] / e['by'][4][f]['frames'] for f in fixtures)
            cands.append({'params': e['params'], 'score': score, 'ssim': ssim,
                          'cost': score[0], 'secs': secs})
        if method == 'mclean':
            # mClean's rn puts grain back, so it raises the clean-picture cost
            # while denoising less: the cost no longer orders strength. Light to
            # Strong keep its default rn (14); above Medium the measurement
            # plateaus at rn 14 (strength is already at its maximum, 20), so
            # Very strong is the best at sigma 9 that puts no grain back (rn 0),
            # at least as strong as Strong in strength and thSAD.
            keep = [c for c in cands if c['params']['mcleanRn'] == 14]
            m = [c for c in keep if all(c['params'][k] == v for k, v in NR_DEFAULTS['mclean'].items())][0]
            strength = lambda c: -c['cost']
            chosen = {'Medium': m}
            weaker = [c for c in keep if strength(c) < strength(m)]
            chosen['Light'] = sorted(weaker, key=lambda c: -c['score'][2])[0]
            top = max(c['score'][2] for c in weaker)
            chosen['Light'] = sorted([c for c in weaker if c['score'][2] >= top - TIE],
                                     key=lambda c: (strength(c), c['secs']))[0]
            stronger = [c for c in keep if strength(c) > strength(m)]
            top = max(c['score'][6] for c in stronger)
            chosen['Strong'] = sorted([c for c in stronger if c['score'][6] >= top - TIE],
                                      key=lambda c: (strength(c), -c['score'][9]))[0]
            s = chosen['Strong']['params']
            bare = [c for c in cands if c['params']['mcleanRn'] == 0 and
                    c['params']['mcleanStrength'] >= s['mcleanStrength'] and
                    c['params']['mcleanThsad'] >= s['mcleanThsad']]
            top = max(c['score'][9] for c in bare)
            chosen['Very strong'] = sorted([c for c in bare if c['score'][9] >= top - TIE],
                                           key=lambda c: (c['params']['mcleanStrength'],
                                                          c['params']['mcleanThsad']))[0]
        else:
            chosen = choose(cands, NR_LEVELS, NR_DEFAULTS[method], lambda c: -c['cost'],
                            PRESET_VALUES)
        out[method] = {st: chosen[st]['params'] for st in STEPS}
        inp = {s: mean(inputs[s][f]['psnr_y'] for f in fixtures) for s in [0] + list(NR_LEVELS.values())}
        report[method] = {'input': inp, 'chosen': {st: chosen[st] for st in STEPS},
                          'candidates': sorted(cands, key=lambda c: -c['cost'])}
    return out, report


def sharpen():
    runs = load('sharpen_runs.json')
    t, inputs = table(runs, 'blur')
    out, report = {}, {}
    fixtures = ['cam', 'film', 'dvbt']
    for method, entries in t.items():
        cands = []
        for e in entries.values():
            blurs = [0] + list(SH_LEVELS.values())
            if not all(set(fixtures) <= set(e['by'].get(b, {})) for b in blurs):
                continue
            score = {b: mean(e['by'][b][f]['psnr_y'] for f in fixtures) for b in blurs}
            change = mean(e['by'][0][f]['change'] for f in fixtures)
            halo = {b: mean(e['by'][b][f]['halo'] for f in fixtures
                            if e['by'][b][f]['halo'] is not None) for b in blurs}
            secs = mean(e['by'][0.8][f]['secs'] / 60 for f in fixtures)
            cands.append({'params': e['params'], 'score': score, 'change': change,
                          'halo': halo, 'cost': score[0], 'secs': secs})
        if method == 'awarpsharp2':
            # Warping moves pixels toward edges, which PSNR against the sharp
            # original reads as error at every depth: no depth scores above
            # the blurred input. Its steps are an even ladder of visible
            # effect instead (mean change from the input, x0.5 / 1 / 1.5 / 2
            # of Medium's).
            chosen = ladder(cands, SH_DEFAULTS[method], lambda c: c['change'],
                            {'Light': 0.5, 'Medium': 1.0, 'Strong': 1.5, 'Very strong': 2.0})
        else:
            chosen = choose(cands, SH_LEVELS, SH_DEFAULTS[method], lambda c: c['change'],
                            PRESET_VALUES)
        out[method] = {st: chosen[st]['params'] for st in STEPS}
        inp = {b: mean(inputs[b][f]['psnr_y'] for f in fixtures) for b in [0] + list(SH_LEVELS.values())}
        report[method] = {'input': inp, 'chosen': {st: chosen[st] for st in STEPS},
                          'candidates': sorted(cands, key=lambda c: c['change'])}
    return out, report


def noise_hint():
    """Noise-score thresholds halfway between the levels Medium / Strong /
    Very strong were chosen at, on the worker's own reading of the noisy
    fixtures (it reads white noise ~6 % low)."""
    fx = load('fixtures.json')
    score = {s: mean(fx[f]['noisy'][str(s)]['noise_score'] for f in ['cam', 'film', 'dvbt'])
             for s in NR_LEVELS.values()}
    mid = lambda a, b: round((score[a] + score[b]) / 2, 1)
    return {'Strong': mid(4, 6), 'Very strong': mid(6, 9)}, score


def main():
    nr_steps, nr_report = nr()
    sh_steps, sh_report = sharpen()
    hint, scores = noise_hint()
    save('steps.json', {'noise_reduction': nr_steps, 'sharpen': sh_steps, 'noiseHint': hint})
    save('choice.json', {'noise_reduction': nr_report, 'sharpen': sh_report,
                         'noiseScoreBySigma': scores, 'tie': TIE})
    for group in (nr_report, sh_report):
        for m, r in group.items():
            print(m)
            for st, c in r['chosen'].items():
                print(f"  {st:12} {c['params']}  cost {c['cost']:.2f}  " +
                      ' '.join(f"{k}:{v:.2f}" for k, v in c['score'].items()))
    print('hint', hint)


if __name__ == '__main__':
    main()
