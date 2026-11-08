#!/usr/bin/env python3
"""Print the report's flicker and speed tables (HTML) from bench.sh's
results.jsonl and flicker.py's JSON.

    python tables.py <results.jsonl> <flicker.json>
"""
import json
import sys

LABELS = {
    "input": "Input (pass at strength 0)",
    "rf_r0": "RestoreFormer++, smoothing off",
    "rf_r1_landmarks": "RestoreFormer++, landmarks smoothed only (r=1)",
    "rf_r1": "RestoreFormer++, landmarks + blend (r=1, strength 1)",
    "rf_r2": "RestoreFormer++, landmarks + blend (r=2)",
    "rf_r1_s08": "RestoreFormer++, r=1, strength 0.8 (the default)",
    "rf_r1_mnet": "RestoreFormer++, r=1, mobilenet detector",
    "gfpgan_r0": "GFPGAN, smoothing off",
    "gfpgan_r1": "GFPGAN, r=1",
    "codeformer_r0": "CodeFormer (w 0.7), smoothing off",
    "codeformer_r1": "CodeFormer (w 0.7), r=1",
}


def main():
    runs = {}
    for line in open(sys.argv[1]):
        d = json.loads(line)
        runs[d["tag"]] = d
    fl = json.load(open(sys.argv[2]))["rows"]
    clean = fl["clean reference"]
    print('<table>\n<tr><th>Variant</th><th class="num">flick</th><th class="num">tdiff</th>'
          '<th class="num">vs clean</th></tr>')
    print(f'<tr><td>Clean source (the floor)</td><td class="num">{clean["flick"]:.3f}</td>'
          f'<td class="num">{clean["tdiff"]:.3f}</td><td class="num">—</td></tr>')
    for tag, label in LABELS.items():
        if tag in fl:
            r = fl[tag]
            print(f'<tr><td>{label}</td><td class="num">{r["flick"]:.3f}</td><td class="num">{r["tdiff"]:.3f}</td>'
                  f'<td class="num">{r["errVsClean"]:.3f}</td></tr>')
    print('</table>')
    print('<table>\n<tr><th>Run</th><th>Size</th><th class="num">Frames</th><th class="num">fps</th>'
          '<th class="num">Session setup (s)</th><th>Restorer on</th></tr>')
    for tag, d in runs.items():
        if tag.startswith("speed"):
            print(f'<tr><td>{tag}</td><td>{d["size"]}</td><td class="num">{d["frames"]}</td>'
                  f'<td class="num">{d["fps"]:.2f}</td><td class="num">{d["setupSeconds"]:.1f}</td>'
                  f'<td>{d["providers"]["restorer"]}</td></tr>')
    print('</table>')


if __name__ == "__main__":
    main()
