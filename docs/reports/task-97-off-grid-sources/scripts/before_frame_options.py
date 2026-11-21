#!/usr/bin/env python3 -I
"""The HDR before frame of an off-grid source (table "Before frame options").

Compares two ways to get zscale an on-grid frame with the worker's preview,
which tone-maps the frame padded by pipe_source and crops after (emulated
here with ffmpeg's pad on an odd HEIGHT only, which pads exactly; its pad
drops an odd width's last column). Also measures FFmpeg's own RGB conversion
of an odd-height 4:2:0 frame against the padded one (section "A conversion
trap"). DEPS / WORK as in common.sh."""
import os, subprocess, tempfile

here = os.path.dirname(os.path.abspath(__file__))
repo = os.path.abspath(os.path.join(here, '..', '..', '..', '..'))
deps = os.environ.get('DEPS', os.path.join(repo, 'deps', 'macos-arm64'))
ff = os.path.join(deps, 'ffmpeg', 'ffmpeg')
work = os.environ.get('WORK') or tempfile.mkdtemp()
TM = ('setparams=colorspace=bt2020nc:color_primaries=bt2020:color_trc=smpte2084:range=tv,'
      'zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0,'
      'zscale=t=bt709:r=full,format=rgb24,setparams=colorspace=gbr')
PREVIEW = 'scale=out_range=pc:flags=accurate_rnd+full_chroma_int'


def run(*args):
    return subprocess.run([ff, '-v', 'error', *args], capture_output=True)


def rgb(src, vf):
    return run('-i', src, '-frames:v', '1', '-vf', vf, '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-').stdout


def diff(a, b):
    d = [abs(x - y) for x, y in zip(a, b)]
    return round(sum(d) / len(d), 3), max(d)


hdr = os.path.join(work, 'hdr_1280x719.mkv')
run('-y', '-f', 'lavfi', '-i', 'testsrc2=s=1280x720:d=0.2', '-vf', 'scale=1280:719,format=yuv420p10le',
    '-color_primaries', 'bt2020', '-color_trc', 'smpte2084', '-colorspace', 'bt2020nc',
    '-color_range', 'tv', '-c:v', 'ffv1', hdr)
plain = run('-i', hdr, '-frames:v', '1', '-vf', TM, '-f', 'null', '-')
print('tone map as it is:', 'fails' if plain.returncode else 'runs', plain.stderr.decode()[:90].strip())
preview = rgb(hdr, f'pad=1280:720:0:0,fillborders=bottom=1:mode=smear,{TM},crop=1280:718:0:0')
below = rgb(hdr, f'crop=1280:718:0:0,{TM}')
print('crop to the grid below vs padded preview (mean, max):', diff(below, preview))
inner = lambda b: b[:1280 * 716 * 3]
print('  away from the last two rows:', diff(inner(below), inner(preview)))
full444 = rgb(hdr, f'format=yuv444p16le,{TM},crop=1280:718:0:0')
print('convert to 4:4:4 first vs padded preview:', diff(full444, preview))

sdr = os.path.join(work, 'sdr_64x33.mkv')
run('-y', '-f', 'lavfi', '-i', 'testsrc2=s=128x96:d=0.2', '-vf', 'scale=64:33,format=yuv420p', '-c:v', 'ffv1', sdr)
direct = rgb(sdr, PREVIEW)
padded = rgb(sdr, f'pad=64:34:0:0,fillborders=bottom=1:mode=smear,{PREVIEW},crop=64:33:0:0')
print("FFmpeg's direct RGB of 64x33 4:2:0 vs the padded conversion:", diff(direct, padded))
