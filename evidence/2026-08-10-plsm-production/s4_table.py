#!/usr/bin/env python3
"""S4 — does a PLSM design still lattice, and does it lattice the same way?

★ NOTHING IS RETYPED. Every number comes out of the two runs' own
`lattice_variant_report.json` / `<prefix>_<vf>_lattice.report.json`. The two runs
differ ONLY in which `design.bin` they name; the lattice and grading blocks are
his, byte for byte the same object on both sides.

★ THE INTERESTING OUTCOME IS A REFUSAL. `lattice-variant` re-certifies the
restored design and refuses unless the run's RECORDED margin reproduces; the
grading law, the boundary rule, the cells-per-member floor and the sub-floor
predicate each refuse in their own way. A refusal on the parametric side and not
on the SIMP side would be the finding, so the script prints whatever each side
said rather than assuming both succeeded.
"""
import json
import os
import sys

SIDES = ["simp", "plsm"]


def load(path):
    if not os.path.exists(path):
        return None
    try:
        with open(path) as f:
            return json.load(f)
    except json.JSONDecodeError:
        return None


def walk(d, key, depth=0):
    """First value for `key` anywhere in a nested dict/list."""
    if depth > 8 or d is None:
        return None
    if isinstance(d, dict):
        if key in d:
            return d[key]
        for v in d.values():
            r = walk(v, key, depth + 1)
            if r is not None:
                return r
    elif isinstance(d, list):
        for v in d:
            r = walk(v, key, depth + 1)
            if r is not None:
                return r
    return None


ROWS = [
    ("recorded margin (worst case)", "recorded_margin_worst_case"),
    ("reproduced margin", "margin_worst_case"),
    ("reproduction relative delta", "reproduction_relative_delta"),
    ("reproduction band", "reproduction_band"),
    ("reproduced within band", "reproduction_within_band"),
    ("latticed voxels", "latticed_voxels"),
    ("solid voxels", "voxels_solid"),
    ("void voxels", "voxels_void"),
    ("band voxels", "voxels_band"),
    ("min cells per member", "min_cells_per_member"),
    ("members below the floor", "below"),
    ("out of regime", "out_of_regime"),
    ("strut diameter min (mm)", "strut_diameter_min_mm"),
    ("strut diameter max (mm)", "strut_diameter_max_mm"),
    ("cell size min (mm)", "cell_min_mm"),
    ("cell size max (mm)", "cell_max_mm"),
    ("lattice margin (worst case)", "lattice_margin_worst_case"),
    ("lattice margin effective", "lattice_margin_effective"),
    ("ACCEPTED", "accepted"),
    ("triangles exported", "triangles"),
    ("mass (g)", "mass_grams"),
]


def main(out_dir):
    print("== S4 — DOES A PARAMETRIC DESIGN STILL LATTICE? ==")
    print()
    print("Two `lattice-variant` runs, HIS lattice and grading blocks verbatim,")
    print("differing only in which design.bin they name. Rung 0.68 on both.")
    print()
    docs = {}
    for s in SIDES:
        docs[s] = {
            "variant": load(os.path.join(out_dir, f"{s}.lattice_variant_report.json")),
            "prov": load(os.path.join(out_dir, f"{s}.lattice_variant.json")),
            "lattice": load(os.path.join(out_dir, f"{s}.lattice.report.json")),
            "report": load(os.path.join(out_dir, f"{s}.report.json")),
        }
        log = os.path.join(out_dir, f"{s}.log")
        tail = ""
        if os.path.exists(log):
            lines = [l.rstrip() for l in open(log) if l.strip()]
            tail = lines[-1] if lines else ""
        docs[s]["tail"] = tail

    for s in SIDES:
        if all(docs[s][k] is None for k in ("variant", "prov", "lattice", "report")):
            print(f"★ {s.upper()}: the run produced no report. Its last line was:")
            print(f"    {docs[s]['tail']}")
            print()

    w = 34
    print(f"{'':<{w}}" + "".join(f"{s.upper():>22}" for s in SIDES))
    print("-" * (w + 22 * len(SIDES)))
    for label, key in ROWS:
        vals = []
        for s in SIDES:
            v = None
            for d in (docs[s]["lattice"], docs[s]["variant"], docs[s]["prov"],
                      docs[s]["report"]):
                v = walk(d, key)
                if v is not None:
                    break
            if v is None:
                vals.append("—")
            elif isinstance(v, bool):
                vals.append("yes" if v else "NO")
            elif isinstance(v, float):
                vals.append(f"{v:.6g}")
            else:
                vals.append(str(v))
        if all(v == "—" for v in vals):
            continue
        print(f"{label:<{w}}" + "".join(f"{v:>22}" for v in vals))
    print()
    print("A '—' means that side's reports do not carry that key under that name;")
    print("the raw documents are beside this file and are the authority.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "."))
