#!/usr/bin/env python3
"""R9: is octet byte-identical between two output directories of the same job?

usage: r9_compare.py REF_DIR NEW_DIR

Every file is compared byte for byte. A file that differs is accepted ONLY when every
difference is in a leaf known to vary run to run or to name the binary:
  * JSON (run_info.json, *.report.json, ...): leaves whose key ends in _ms, _s, _seconds,
    or is created_wall_ms / gen_fraction (a time ratio), fingerprint, build_time,
    cli_version.
  * iterations.csv: the timing columns (*_ms, *wall*, *_s).
  * *_alpha.meta: lines naming the output path or ending in _wall_s.
Anything else is a REAL difference and the script exits 1, naming it.
"""
import csv
import json
import os
import sys

VOLATILE_KEYS = ("created_wall_ms", "gen_fraction", "fingerprint", "build_time", "cli_version")


def volatile_key(k):
    return k in VOLATILE_KEYS or k.endswith(("_ms", "_s", "_seconds"))


def json_diff(a, b, path=""):
    if isinstance(a, dict) and isinstance(b, dict):
        out = []
        for k in sorted(set(a) | set(b)):
            if k not in a or k not in b:
                out.append(path + "/" + k + " (present in one only)")
            else:
                out += json_diff(a[k], b[k], path + "/" + k)
        return out
    if isinstance(a, list) and isinstance(b, list):
        if len(a) != len(b):
            return [path + " (length)"]
        out = []
        for i, (x, y) in enumerate(zip(a, b)):
            out += json_diff(x, y, path + "[%d]" % i)
        return out
    if a == b:
        return []
    leaf = path.rsplit("/", 1)[-1].split("[")[0]
    return [] if volatile_key(leaf) else [path]


def csv_diff(pa, pb):
    a = list(csv.reader(open(pa)))
    b = list(csv.reader(open(pb)))
    if len(a) != len(b) or a[0] != b[0]:
        return ["rows or header"]
    timing = {i for i, c in enumerate(a[0]) if c.endswith(("_ms", "_s")) or "wall" in c}
    bad = set()
    for ra, rb in zip(a[1:], b[1:]):
        for i, (x, y) in enumerate(zip(ra, rb)):
            if x != y and i not in timing:
                bad.add(a[0][i])
    return sorted(bad)


def meta_diff(pa, pb):
    a = open(pa).read().splitlines()
    b = open(pb).read().splitlines()
    if len(a) != len(b):
        return ["line count"]
    return [x for x, y in zip(a, b)
            if x != y and not (x.startswith("# alpha is") or x.split(" ")[0].endswith("_wall_s"))]


def main(ref, new):
    files = sorted(os.listdir(ref))
    real = []
    same = 0
    for f in files:
        pa, pb = os.path.join(ref, f), os.path.join(new, f)
        if not os.path.exists(pb):
            real.append(f + ": missing in NEW")
            continue
        if open(pa, "rb").read() == open(pb, "rb").read():
            same += 1
            continue
        if f.endswith(".json"):
            d = json_diff(json.load(open(pa)), json.load(open(pb)))
        elif f == "iterations.csv":
            d = csv_diff(pa, pb)
        elif f.endswith(".meta"):
            d = meta_diff(pa, pb)
        else:
            d = ["binary content"]
        print("  %-36s differs only in timing/identity leaves" % f if not d else
              "  %-36s REAL DIFFERENCE: %s" % (f, d[:5]))
        real += [f + ": " + x for x in d]
    print("VERDICT: %d files, %d byte-identical, %d real differences" % (len(files), same, len(real)))
    return 1 if real else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2]))
