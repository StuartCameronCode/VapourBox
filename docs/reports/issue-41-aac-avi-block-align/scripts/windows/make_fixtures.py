"""The AVIs the Windows timing probe reads, made with the deps bundle's ffmpeg.

    FFMPEG=... python make_fixtures.py <work dir>

- mono256.avi          mono AAC 256 kbps (Very High): packets over 768 bytes,
                       header as avienc writes it (nBlockAlign 768)
- mono256_patched.avi  the same bytes with nBlockAlign = its largest chunk
                       (the worker's fix, riff_block_align.py patch)
- mono192.avi / mono192_patched.avi  the same at High (192 kbps)
- stereo192.avi        a control: stereo AAC 192 kbps, no packet over 1536
Each also gets a .packets.json: ffmpeg's packet sizes in file order, so the
analysis can index the readers' times against the chunk sizes.
"""
import json
import os
import shutil
import subprocess
import sys

here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(here))
import riff_block_align  # noqa: E402

ffmpeg = os.environ['FFMPEG']
ffprobe = os.path.join(os.path.dirname(ffmpeg), 'ffprobe' + ('.exe' if ffmpeg.endswith('.exe') else ''))
work = sys.argv[1]
os.makedirs(work, exist_ok=True)
stereo_wav, mono_wav = os.path.join(work, 'harsh_stereo.wav'), os.path.join(work, 'harsh_mono.wav')
subprocess.run([sys.executable, os.path.join(os.path.dirname(here), 'harsh_audio.py'), ffmpeg, stereo_wav, mono_wav],
               check=True)


def encode(src, name, kbps):
    out = os.path.join(work, name + '.avi')
    subprocess.run([ffmpeg, '-v', 'error', '-y', '-i', src, '-c:a', 'aac', '-b:a', f'{kbps}k', out], check=True)
    sizes = subprocess.run([ffprobe, '-v', 'error', '-select_streams', 'a:0', '-show_entries', 'packet=size',
                            '-of', 'csv=p=0', out], check=True, capture_output=True, text=True).stdout.split()
    json.dump([int(s) for s in sizes], open(os.path.join(work, name + '.packets.json'), 'w'))
    return out


for kbps in (256, 192):
    orig = encode(mono_wav, f'mono{kbps}', kbps)
    patched = os.path.join(work, f'mono{kbps}_patched.avi')
    shutil.copyfile(orig, patched)
    shutil.copyfile(os.path.join(work, f'mono{kbps}.packets.json'), os.path.join(work, f'mono{kbps}_patched.packets.json'))
    print(json.dumps({'file': patched, 'fixes': riff_block_align.patch(patched)}))
encode(stereo_wav, 'stereo192', 192)
for name in ('mono256', 'mono256_patched', 'mono192', 'mono192_patched', 'stereo192'):
    for a in riff_block_align.audio_streams(os.path.join(work, name + '.avi')):
        print(json.dumps({'file': name, **a}))
