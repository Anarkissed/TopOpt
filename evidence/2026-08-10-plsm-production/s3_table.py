#!/usr/bin/env python3
"""S3(b) — the solver win on SIMP, read off the four arms' own artefacts.

★ NOTHING IS RETYPED. Every number below comes out of `iterations.csv` (the
per-iteration record the run wrote for itself) or `report.json` (the certificate),
both produced by the same binary in the same run. The script computes sums and
ratios and nothing else.

★ TWO BARS, NOT ONE, FOR THE ACCURACY COLUMN. PR 313 set the margin-reproduction
tolerance at 1.0e-06 relative and measured the machinery's own warm-vs-cold noise
floor at 3e-10 to 3e-9. A deviation is reported against BOTH, because "inside the
tolerance" and "inside the noise" are different claims and only the second means
the trajectory landed in the same place.

★ AND THE VERDICTS ARE COMPARED RUNG BY RUNG. R5 is that no verdict moves; a
margin that shifted inside the band while an accept flipped would be a failure,
not a success, so the accept/reject vector is checked separately from the margin.
"""
import json
import sys
import os


def read_iterations(path):
    """(rows, header index map) from a run's iterations.csv."""
    with open(path) as f:
        lines = [l.rstrip("\n") for l in f if l.strip()]
    head = lines[0].split(",")
    idx = {h: i for i, h in enumerate(head)}
    rows = [l.split(",") for l in lines[1:]]
    return rows, idx


def totals(path):
    rows, idx = read_iterations(path)
    cg = sum(int(r[idx["cg_iters"]]) for r in rows)
    ms = sum(float(r[idx["total_ms"]]) for r in rows)
    per_rung = {}
    for r in rows:
        k = int(r[idx["rung"]])
        e = per_rung.setdefault(k, {"iters": 0, "cg": 0, "ms": 0.0})
        e["iters"] += 1
        e["cg"] += int(r[idx["cg_iters"]])
        e["ms"] += float(r[idx["total_ms"]])
    return {"iters": len(rows), "cg": cg, "ms": ms, "rungs": per_rung}


def variants(path):
    with open(path) as f:
        rep = json.load(f)
    out = []
    for v in rep.get("variants", []):
        out.append({
            "vf": v.get("volume_fraction"),
            "requested": v.get("requested_volume_fraction", v.get("volume_fraction")),
            "margin": v.get("margin", {}).get("worst_case")
                      if isinstance(v.get("margin"), dict) else v.get("margin_worst_case"),
            "margin_effective": v.get("margin_effective"),
            "accepted": v.get("accepted"),
            "mass": v.get("mass_grams"),
            "max_stress": v.get("max_stress_mpa"),
        })
    return out


ARMS = ["base", "loose", "warm", "both"]
LABEL = {
    "base": "tight + cold  (what runs today)",
    "loose": "loose + cold  (the draft block)",
    "warm": "tight + warm  (the matrix-free warm start)",
    "both": "loose + warm  ★",
}

# PR 313's bars.
REPRO_TOL = 1.0e-06
NOISE_HI = 3.0e-09


def main(out_dir):
    tot = {}
    var = {}
    for a in ARMS:
        ip = os.path.join(out_dir, f"{a}.iterations.csv")
        rp = os.path.join(out_dir, f"{a}.report.json")
        if not os.path.exists(ip):
            print(f"MISSING: {ip}")
            return 1
        tot[a] = totals(ip)
        var[a] = variants(rp)

    print("== S3(b) — THE SOLVER WIN ON SIMP, HIS OWN JOB, FOUR RUNGS, 3 THREADS ==")
    print()
    print("Solver steps and wall are the SUM over every trajectory iteration of")
    print("every rung, read from each run's own iterations.csv. Wall is that CSV's")
    print("`total_ms` (the per-iteration wall the run measured itself), so it")
    print("excludes import, voxelization and the four certifications — the parts")
    print("neither arm changes.")
    print()
    b = tot["base"]
    print(f"{'arm':<44} {'iters':>7} {'solver steps':>13} {'wall s':>10} "
          f"{'vs base':>9} {'steps vs base':>14}")
    for a in ARMS:
        t = tot[a]
        print(f"{LABEL[a]:<44} {t['iters']:>7} {t['cg']:>13,} "
              f"{t['ms']/1000.0:>10.1f} "
              f"{t['ms']/b['ms']:>8.3f}x {t['cg']/b['cg']:>13.3f}x")
    print()
    print("-- per rung, solver steps")
    rungs = sorted(b["rungs"].keys())
    print(f"{'arm':<44} " + " ".join(f"{'rung '+str(k):>12}" for k in rungs))
    for a in ARMS:
        t = tot[a]
        print(f"{LABEL[a]:<44} " +
              " ".join(f"{t['rungs'].get(k, {'cg': 0})['cg']:>12,}" for k in rungs))
    print()
    print("-- per rung, wall (s)")
    for a in ARMS:
        t = tot[a]
        print(f"{LABEL[a]:<44} " +
              " ".join(f"{t['rungs'].get(k, {'ms': 0})['ms']/1000.0:>12.1f}"
                       for k in rungs))
    print()

    # ── R5: NO VERDICT MOVES ────────────────────────────────────────────────
    print("== R5 — NO VERDICT MOVES, AND THE MARGIN AGAINST BOTH BARS ==")
    print()
    print("PR 313's margin-reproduction tolerance is 1.0e-06 RELATIVE; the")
    print("machinery's own warm-vs-cold noise floor is 3e-10 to 3e-9. A deviation")
    print("inside the noise means the trajectory landed in the same place; one")
    print("inside the tolerance but outside the noise means it landed somewhere")
    print("else that still certifies the same. Both are stated.")
    print()
    base_v = var["base"]
    ok = True
    for a in ARMS:
        v = var[a]
        if len(v) != len(base_v):
            print(f"{a}: ★ DIFFERENT NUMBER OF EVALUATED RUNGS "
                  f"({len(v)} vs {len(base_v)}) — the ladder walked differently")
            ok = False
            continue
        print(f"-- {LABEL[a]}")
        for i, (bv, av) in enumerate(zip(base_v, v)):
            bm, am = bv["margin"], av["margin"]
            rel = abs(am - bm) / abs(bm) if bm else float("nan")
            verdict_same = bv["accepted"] == av["accepted"]
            if not verdict_same:
                ok = False
            flag = ("SAME" if verdict_same else "★ VERDICT MOVED")
            band = ("inside the noise floor" if rel <= NOISE_HI else
                    "inside PR 313's 1e-06" if rel <= REPRO_TOL else
                    "★ OUTSIDE PR 313's 1e-06")
            if rel > REPRO_TOL:
                ok = False
            print(f"   rung {bv['requested']:.2f}  margin {bm:.9g} -> {am:.9g}  "
                  f"rel {rel:.3e}  {band}   accept {bv['accepted']}->"
                  f"{av['accepted']} {flag}")
        print()
    print("VERDICT: " + ("no verdict moved and every margin is inside PR 313's "
                         "1.0e-06 relative bar."
                         if ok else
                         "★ SOMETHING MOVED — read the rows above."))
    return 0 if ok else 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "."))
