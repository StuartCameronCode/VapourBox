"""Survey real sources for timestamp resets (task #21, step 1):

    python3 reset_survey.py FILE_OR_DIR...

Runs the worker's own --scan-timestamps (the shipped rule) on every .ts,
.m2ts, .mts, .mpg, .mpeg, .vob under each argument. For a VIDEO_TS folder,
scan what the app's DVD import writes (`vapourbox-worker --dvd-extract`)
too: that extraction copies the whole title set (every title and angle; see
the report), so its resets are not only the title's own.
"""
import os
import sys

from resetlib import worker_json

EXT = ('.ts', '.m2ts', '.mts', '.mpg', '.mpeg', '.vob')


def files(arg):
    if os.path.isfile(arg):
        yield arg
        return
    for root, _, names in os.walk(arg):
        for n in sorted(names):
            if n.lower().endswith(EXT):
                yield os.path.join(root, n)


def main():
    total = with_reset = 0
    for arg in sys.argv[1:]:
        for f in files(arg):
            s = worker_json('--scan-timestamps', f)[0]
            if 'resets' not in s:
                print(f'{f}: {s}')
                continue
            total += 1
            video = [r['packet'] for r in s['resets'] if r['codecType'] == 'video']
            with_reset += bool(s['resets'])
            print(f'{f}: {s["format"]}, {s["videoPackets"]} video packets, '
                  f'{len(s["resets"])} reset(s), video at {video}')
    print(f'{with_reset} of {total} files have a reset')


if __name__ == '__main__':
    main()
