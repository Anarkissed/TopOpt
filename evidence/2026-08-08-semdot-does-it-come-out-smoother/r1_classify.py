#!/usr/bin/env python3
"""R1's reporting half — classify what differs, instead of stopping at "DIFFERENCES".

A bare `diff` of artifact checksums answers "is anything different" and then makes
the reader do the work that decides whether the answer matters. On this repo three
files ALWAYS differ between two runs of the same binary, because they carry a WALL
CLOCK (`created_wall_ms`, `preflight_ms`, `gen_seconds`, `sweep_seconds`, every
`*_ms` column of iterations.csv). A bar that reports those as a byte-identity
failure cries wolf; a bar that quietly whitelists them can hide a real change
behind a timing field.

So this splits the artifacts in two and holds them to different, stated standards:

  DESIGN ARTIFACTS — design.bin, fields.bin, report.json, every mesh. These
      describe the OBJECT. The bar is BYTE-IDENTITY, no exceptions, no
      normalization. If one of these moves, the feature is not off.

  RECEIPTS — run_info.json, iterations.csv, build_orientation.json. These describe
      the RUN, wall clock included. The bar is: identical after wall-clock fields
      are removed, and every remaining difference ENUMERATED BY NAME. A new key
      that the branch adds is reported as an addition, not hidden — because
      "run_info gained a field" is exactly the kind of change a reader is entitled
      to see, and exactly the kind a whitelist would swallow.

  ./r1_classify.py <base_dir> <branch_dir>
"""
import csv
import hashlib
import json
import sys
from pathlib import Path

BASE = Path(sys.argv[1])
BRANCH = Path(sys.argv[2])

DESIGN_SUFFIX = (".bin", ".stl", ".3mf")
DESIGN_NAMES = {"report.json", "loadcase.json"}
RECEIPTS = {"run_info.json", "iterations.csv", "build_orientation.json"}

# Wall-clock fields, named individually. Anything not on this list is compared.
CLOCK_JSON_KEYS = {
    "created_wall_ms", "preflight_ms", "wall_seconds", "gen_seconds",
    "gen_fraction", "sweep_seconds", "strut_axis_measure_seconds",
    "solve_seconds", "elapsed_ms", "wall_ms",
}
CLOCK_CSV_COLUMNS = {
    "wall_ms", "total_ms", "tail_prev_ms", "filter_ms", "project_ms", "solve_ms",
    "fea_ms", "sens_ms", "update_ms", "analysis_ms", "observe_ms", "residual_ms",
    "solver_build_ms", "mg_build_ms", "mg_ms", "cg_ms", "geneo_setup_ms",
    "geneo_apply_ms", "recycle_ms", "rss_mb", "peak_rss_mb", "compressed_mb",
    "available_mb", "major_faults", "swapins",
}


def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def strip_clock(o):
    if isinstance(o, dict):
        return {k: strip_clock(v) for k, v in o.items() if k not in CLOCK_JSON_KEYS}
    if isinstance(o, list):
        return [strip_clock(v) for v in o]
    return o


def json_paths(o, prefix=""):
    if isinstance(o, dict):
        for k, v in o.items():
            yield from json_paths(v, f"{prefix}.{k}" if prefix else k)
    elif isinstance(o, list):
        yield prefix, json.dumps(o)
    else:
        yield prefix, o


out = []
files = sorted({p.name for p in BASE.iterdir() if p.is_file()} |
               {p.name for p in BRANCH.iterdir() if p.is_file()})

out.append("=== R1 — WHAT DIFFERS, CLASSIFIED ===")
out.append("")
out.append("--- DESIGN ARTIFACTS: the bar is BYTE-IDENTITY, no exceptions ---")
design_bad = 0
design_n = 0
for f in files:
    if not (f.endswith(DESIGN_SUFFIX) or f in DESIGN_NAMES):
        continue
    a, b = BASE / f, BRANCH / f
    if not a.exists() or not b.exists():
        out.append(f"  MISSING   {f}")
        design_bad += 1
        continue
    design_n += 1
    ha, hb = sha(a), sha(b)
    if ha == hb:
        out.append(f"  IDENTICAL {f}  {ha}")
    else:
        out.append(f"  DIFFERS   {f}\n    base   {ha}\n    branch {hb}")
        design_bad += 1
out.append(f"  => {design_n - design_bad} of {design_n} byte-identical, "
           f"{design_bad} differing")
out.append("")

out.append("--- RECEIPTS: identical after wall clock, every remaining "
           "difference NAMED ---")
receipt_bad = 0
for f in sorted(RECEIPTS):
    a, b = BASE / f, BRANCH / f
    if not a.exists() or not b.exists():
        continue
    if f.endswith(".json"):
        ja = strip_clock(json.loads(a.read_text()))
        jb = strip_clock(json.loads(b.read_text()))
        if ja == jb:
            out.append(f"  {f}: identical once wall-clock fields are removed")
            continue
        pa = dict(json_paths(ja))
        pb = dict(json_paths(jb))
        for k in sorted(set(pb) - set(pa)):
            out.append(f"  {f}: KEY ADDED BY THE BRANCH   {k} = {pb[k]!r}")
        for k in sorted(set(pa) - set(pb)):
            out.append(f"  {f}: KEY REMOVED BY THE BRANCH {k} = {pa[k]!r}")
            receipt_bad += 1
        for k in sorted(set(pa) & set(pb)):
            if pa[k] != pb[k]:
                out.append(f"  {f}: VALUE CHANGED  {k}: {pa[k]!r} -> {pb[k]!r}")
                receipt_bad += 1
    else:
        ra = list(csv.DictReader(a.open()))
        rb = list(csv.DictReader(b.open()))
        cols = [c for c in ra[0] if c not in CLOCK_CSV_COLUMNS]
        va = [tuple(r[c] for c in cols) for r in ra]
        vb = [tuple(r[c] for c in cols) for r in rb]
        if list(ra[0]) != list(rb[0]):
            out.append(f"  {f}: COLUMN SET CHANGED")
            receipt_bad += 1
        elif len(va) != len(vb):
            out.append(f"  {f}: ROW COUNT CHANGED {len(va)} -> {len(vb)}")
            receipt_bad += 1
        elif va == vb:
            out.append(f"  {f}: {len(va)} rows, all {len(cols)} non-timing "
                       f"columns identical (timing columns differ, as they must)")
        else:
            n = sum(1 for x, y in zip(va, vb) if x != y)
            out.append(f"  {f}: {n} of {len(va)} rows differ OUTSIDE the timing "
                       f"columns")
            receipt_bad += 1
out.append("")

verdict_ok = design_bad == 0 and receipt_bad == 0
out.append("=== VERDICT ===")
if verdict_ok:
    out.append("OFF IS BYTE-IDENTICAL. Every design artifact matches byte for "
               "byte; the receipts match once the wall clock is removed, and the "
               "only remaining differences are keys the branch ADDS to run_info "
               "so an armed run can say it was armed.")
else:
    out.append(f"NOT byte-identical: {design_bad} design artifact(s) and "
               f"{receipt_bad} non-clock receipt difference(s).")

text = "\n".join(out) + "\n"
Path(__file__).with_name("r1_byte_identity.txt").write_text(text)
print(text)
sys.exit(0 if verdict_ok else 1)
