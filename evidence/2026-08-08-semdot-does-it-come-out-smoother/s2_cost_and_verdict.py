#!/usr/bin/env python3
"""S2(b)/(c) — COST AND VERDICT, per rung, both arms.

The geometry half of S2 is the probe (s2_semdot_vs_simp.csv). This is the other
half the brief asks for and the probe deliberately does not compute, because it
belongs to the RUN and not to the surface: compliance, certified margin, verdict,
mass and achieved_vf against target — and ITERATIONS AND WALL, SEPARATELY (bar
R6), because "fewer iterations" is the one claim in the SEMDOT paper that would
make the method cheaper as well as better, and an iteration count that fell while
the wall rose is not that claim.

Reads, for each arm: report.json (verdict, margin, achieved vf, min-feature),
run_info.json (the armed configuration and the per-rung outcome vectors) and
iterations.csv (the per-iteration wall and compliance the run actually recorded).

  ./s2_cost_and_verdict.py [evidence_dir]
"""
import csv
import json
import sys
from collections import defaultdict
from pathlib import Path

EV = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).resolve().parent)
PLA_G_CM3 = 1.24  # core/src/materials/materials.json — read, never retyped as a guess

ARMS = [("SIMP", EV / "s2_simp"), ("SEMDOT", EV / "s2_semdot")]


def load_arm(d):
    out = {}
    out["report"] = json.loads((d / "report.json").read_text())
    out["run_info"] = json.loads((d / "run_info.json").read_text())
    per = defaultdict(lambda: {"iters": 0, "wall_ms": 0.0, "cg": 0,
                               "first_c": None, "last_c": None, "solve_ms": 0.0,
                               "gray_iters": 0, "gray_wall_ms": 0.0,
                               "proj_iters": 0, "proj_wall_ms": 0.0})
    with (d / "iterations.csv").open() as f:
        for r in csv.DictReader(f):
            k = int(r["rung"])
            p = per[k]
            p["iters"] += 1
            p["wall_ms"] += float(r["total_ms"])
            p["solve_ms"] += float(r["solve_ms"])
            p["cg"] += int(r["cg_iters"])
            # THE POLISH PHASE, SEPARATED. Under SIMP the conditional Heaviside
            # gate (handoff 123) continues a gray rung into a beta-projection
            # phase whose rows carry a non-zero beta; under SEMDOT that gate is
            # disarmed because the level set is the sharpening mechanism. Lumping
            # the two together would credit SEMDOT with an iteration saving that
            # is really "the polish phase did not run", so both splits are
            # reported and the reader decides which comparison they want.
            if float(r["beta"]) > 0.0:
                p["proj_iters"] += 1
                p["proj_wall_ms"] += float(r["total_ms"])
            else:
                p["gray_iters"] += 1
                p["gray_wall_ms"] += float(r["total_ms"])
            c = float(r["compliance"])
            if p["first_c"] is None:
                p["first_c"] = c
            p["last_c"] = c
    out["per_rung"] = dict(per)
    return out


rows = []
data = {}
for name, d in ARMS:
    if not (d / "report.json").exists():
        print(f"MISSING: {d} — run run_s2.sh first")
        sys.exit(2)
    data[name] = load_arm(d)

print("=== S2(b)/(c) — COST AND VERDICT, per rung, both arms ===\n")

for name in ("SIMP", "SEMDOT"):
    a = data[name]
    ri = a["run_info"]
    print(f"### ARM {name}")
    print(f"  semdot={ri.get('semdot')} grid_points={ri.get('semdot_grid_points')}"
          f"  solver={ri.get('solver')} cg_multigrid={ri.get('cg_multigrid')}")
    print(f"  conditional_projection_fired={ri.get('conditional_projection_fired')}")
    print(f"  rung_infeasible={ri.get('rung_infeasible')}"
          f"  rung_non_convergent={ri.get('rung_non_convergent')}")
    if ri.get("semdot"):
        print(f"  semdot_rung_level_set={ri.get('semdot_rung_level_set')}")
        print(f"  semdot_rung_fractional_voxels="
              f"{ri.get('semdot_rung_fractional_voxels')}"
              f" of {ri.get('semdot_rung_design_voxels')}")
    accepted = a["report"]["variants"]
    rejected = a["report"].get("rejected_variants", [])
    allv = accepted + rejected
    for i, v in enumerate(allv):
        p = a["per_rung"].get(i, {})
        rows.append({
            "arm": name, "rung_index": i,
            "achieved_vf": v["volume_fraction"],
            "printed_fraction": v["printed_fraction"],
            "margin_worst_case": v["margin"]["worst_case"],
            "margin_effective": v["margin_effective"],
            "margin_required": v["margin_required"],
            "accepted": int(bool(v["accepted"])),
            "max_stress_mpa": v["max_stress_mpa"],
            "min_feature_violations": v["min_feature_violations"],
            "iterations": p.get("iters", 0),
            "gray_iterations": p.get("gray_iters", 0),
            "projection_iterations": p.get("proj_iters", 0),
            "wall_s": round(p.get("wall_ms", 0.0) / 1000.0, 3),
            "gray_wall_s": round(p.get("gray_wall_ms", 0.0) / 1000.0, 3),
            "projection_wall_s": round(p.get("proj_wall_ms", 0.0) / 1000.0, 3),
            "solve_s": round(p.get("solve_ms", 0.0) / 1000.0, 3),
            "cg_iters_total": p.get("cg", 0),
            "compliance_first": p.get("first_c"),
            "compliance_last": p.get("last_c"),
            "rejection_reason": v.get("rejection_reason", ""),
        })
    print()

ladder = data["SIMP"]["run_info"]["ladder"]


def get(arm, i):
    for r in rows:
        if r["arm"] == arm and r["rung_index"] == i:
            return r
    return None


print("--- PER RUNG, SIMP against SEMDOT " + "-" * 40)
hdr = (f"{'rung':>5} | {'arm':<6} | {'iters':>5} {'wall s':>9} {'solve s':>9} "
       f"{'cg tot':>8} | {'compliance':>12} | {'margin':>10} {'m_eff':>10} "
       f"{'ok':>3} | {'ach vf':>8} {'miss':>9} | {'minfeat':>7}")
print(hdr)
print("-" * len(hdr))
for i, vf in enumerate(ladder):
    for arm in ("SIMP", "SEMDOT"):
        r = get(arm, i)
        if r is None:
            print(f"{vf:>5.2f} | {arm:<6} |  (rung not evaluated)")
            continue
        print(f"{vf:>5.2f} | {arm:<6} | {r['iterations']:>5} {r['wall_s']:>9.1f} "
              f"{r['solve_s']:>9.1f} {r['cg_iters_total']:>8} | "
              f"{r['compliance_last']:>12.6g} | {r['margin_worst_case']:>10.4g} "
              f"{r['margin_effective']:>10.4g} {('yes' if r['accepted'] else 'NO'):>3} | "
              f"{r['achieved_vf']:>8.5f} {r['achieved_vf']-vf:>+9.5f} | "
              f"{r['min_feature_violations']:>7}")
    print()

print("--- TOTALS " + "-" * 40)
for arm in ("SIMP", "SEMDOT"):
    rs = [r for r in rows if r["arm"] == arm]
    print(f"  {arm:<6}  rungs {len(rs)}   iterations {sum(r['iterations'] for r in rs)}"
          f" (gray {sum(r['gray_iterations'] for r in rs)}"
          f" + polish {sum(r['projection_iterations'] for r in rs)})"
          f"   wall {sum(r['wall_s'] for r in rs):.1f} s"
          f"   solve {sum(r['solve_s'] for r in rs):.1f} s"
          f"   CG {sum(r['cg_iters_total'] for r in rs)}")
si = sum(r["iterations"] for r in rows if r["arm"] == "SIMP")
se = sum(r["iterations"] for r in rows if r["arm"] == "SEMDOT")
sw = sum(r["wall_s"] for r in rows if r["arm"] == "SIMP")
ew = sum(r["wall_s"] for r in rows if r["arm"] == "SEMDOT")
sg = sum(r["gray_iterations"] for r in rows if r["arm"] == "SIMP")
eg = sum(r["gray_iterations"] for r in rows if r["arm"] == "SEMDOT")
if si and sw:
    print(f"\n  ITERATIONS, ALL:  SEMDOT / SIMP = {se/si:.3f}x   "
          f"(the paper's claim is < 1)")
    if sg:
        print(f"  ITERATIONS, GRAYSCALE PHASE ONLY: SEMDOT / SIMP = {eg/sg:.3f}x")
        print("    (the honest like-for-like: SIMP's polish phase has no SEMDOT "
              "counterpart,\n     so the ALL row credits SEMDOT with work that "
              "simply did not run.)")
    print(f"  WALL:       SEMDOT / SIMP = {ew/sw:.3f}x   "
          f"(reported SEPARATELY on purpose — bar R6)")

out = EV / "s2_cost_and_verdict.csv"
with out.open("w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
    w.writeheader()
    w.writerows(rows)
print(f"\nwrote {out}")
