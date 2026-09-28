#!/usr/bin/env python3
"""F11/F13 byte-identity check, task 2026-09-28-flexible-squish-maths.

    identity_compare.py <out_base_dir> <out_new_dir>

Compares every file two runs of the same job wrote (base binary vs this branch's).
Identical bytes pass outright. A file that differs passes ONLY if it is identical
after masking the things that differ between ANY two runs of the same binary:

  * wall-clock timings: JSON keys ending in _ms, _s, _seconds, "wall", "build_time",
    "created_wall_ms"; iterations.csv's *_ms columns; .meta lines "*_wall_s";
  * the output directory's own name where a file quotes its path.

Everything else — every number the run computed, every mesh, fields.bin, design.bin —
must match byte for byte. Prints one line per file and exits non-zero on any
difference that survives the mask.
"""
import csv
import io
import json
import os
import re
import sys

TIME_KEY = re.compile(r"(_ms|_s|_seconds|wall|^build_time$|^created_wall_ms$)")


def mask_json(v):
    if isinstance(v, dict):
        return {k: ("<t>" if TIME_KEY.search(k) else mask_json(x)) for k, x in v.items()}
    if isinstance(v, list):
        return [mask_json(x) for x in v]
    return v


def masked(path, text, root):
    text = text.replace(root, "<out>")
    name = os.path.basename(path)
    if name.endswith(".json"):
        return json.dumps(mask_json(json.loads(text)), sort_keys=True)
    if name == "iterations.csv":
        rows = list(csv.reader(io.StringIO(text)))
        keep = [i for i, h in enumerate(rows[0]) if not h.endswith("_ms")]
        return "\n".join(",".join(r[i] for i in keep if i < len(r)) for r in rows)
    if name.endswith(".meta"):
        return "\n".join(l for l in text.splitlines() if not re.match(r"\S*_wall_s ", l))
    return text


def main():
    a, b = sys.argv[1], sys.argv[2]
    files = sorted(set(os.listdir(a)) | set(os.listdir(b)))
    bad = 0
    for f in files:
        pa, pb = os.path.join(a, f), os.path.join(b, f)
        if not (os.path.isfile(pa) and os.path.isfile(pb)):
            print("MISSING  ", f)
            bad += 1
            continue
        ba, bb = open(pa, "rb").read(), open(pb, "rb").read()
        if ba == bb:
            print("identical", f)
            continue
        try:
            ta = masked(pa, ba.decode(), os.path.basename(os.path.dirname(os.path.abspath(a))) + "/" + os.path.basename(a))
            tb = masked(pb, bb.decode(), os.path.basename(os.path.dirname(os.path.abspath(b))) + "/" + os.path.basename(b))
        except (UnicodeDecodeError, ValueError):
            print("DIFFERENT", f, "(binary)")
            bad += 1
            continue
        if ta == tb:
            print("same after masking timings/paths:", f)
        else:
            print("DIFFERENT", f)
            bad += 1
    print("RESULT:", "IDENTICAL" if bad == 0 else "%d DIFFERENCES" % bad)
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
