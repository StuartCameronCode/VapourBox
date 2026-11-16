#!/usr/bin/env python3
"""Fill index.template.html's tables from results.json; writes ../index.html."""
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
r = json.load(open(os.path.join(HERE, "results.json")))
page = open(os.path.join(HERE, "index.template.html")).read()


def same(ok, yes="identical", no="different"):
    return f'<td class="{"good" if ok else "warn"}">{yes if ok else no}</td>'


rows = []
for name, row in r["encoder_bitstreams"].items():
    rows.append(f"<tr><td>{name}</td>{same(row['bitstream_identical'])}{same(row['decoded_identical'])}</tr>")
page = page.replace("<!--ENCODER_ROWS-->", "\n".join(rows))

rows = []
for fx, codecs in r["quality"].items():
    for codec, q in codecs.items():
        e, m = q["evermeet"], q["mr"]
        assert e["psnr_y"] == m["psnr_y"] and e["ssim_all"] == m["ssim_all"], (fx, codec)
        rows.append(f"<tr><td>{fx}</td><td>{codec}</td><td class=\"num\">{e['bytes']:,}</td>"
                    f"<td class=\"num\">{m['bytes']:,}</td><td class=\"num\">{m['psnr_y']:.2f} dB</td>"
                    f"<td class=\"num\">{m['ssim_all']:.4f}</td>{same(e['decoded_md5'] == m['decoded_md5'])}</tr>")
page = page.replace("<!--QUALITY_ROWS-->", "\n".join(rows))

mp3 = r["mp3"]
line = (f"Both files are {mp3['evermeet']['bytes']:,} bytes and decode to identical samples "
        f"({mp3['samples_compared']:,} compared)." if mp3["identical_decode"] else
        f"The decodes differ: {mp3['difference_db_below_signal']} dB below the signal, "
        f"largest sample difference {mp3['max_abs_sample_difference']}.")
page = page.replace("<!--MP3_LINE-->", line)

dec = r["decoders"]
same_n = sum(d["identical"] for d in dec.values())
bad = [f for f, d in dec.items() if not d["identical"]]
line = f"<strong>{same_n} of {len(dec)} decode identically</strong>" + (
    "." if not bad else f"; different: {', '.join(bad)}.")
page = page.replace("<!--DECODE_LINE-->", line)

rows = []
for key, a in r["av1"].items():
    if not isinstance(a, dict) or "codec_name" not in a:
        continue
    depth, ext = key.split()
    fps = a.get("fps_under_rosetta", a.get("fps"))
    rows.append(f"<tr><td>{depth}</td><td>{ext.upper()}</td><td>{a['codec_name']} {a['pix_fmt']}</td>"
                f"<td class=\"num\">{a['nb_read_frames']}</td><td class=\"num\">{a['psnr_y']:.2f} dB</td>"
                f"<td class=\"num\">{a['ssim_all']:.4f}</td><td class=\"num\">{a['bytes']:,}</td>"
                f"<td class=\"num\">{fps}</td></tr>")
page = page.replace("<!--AV1_ROWS-->", "\n".join(rows))

assert "<!--" not in page.split("</style>", 1)[1], "a placeholder was left unfilled"
open(os.path.join(HERE, "..", "index.html"), "w").write(page)
print("wrote index.html")
