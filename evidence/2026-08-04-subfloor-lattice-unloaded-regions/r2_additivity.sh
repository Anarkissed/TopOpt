#!/usr/bin/env bash
# A-3 — ADDITIVITY: is retaining TWO regions the same as retaining each alone?
# (per-region follow-on to 2026-08-04-subfloor-lattice-unloaded-regions)
#
#   ./r2_additivity.sh <cli> <out-dir>
#
# THE QUESTION PER-REGION ACTUALLY RAISES. Everything measured so far — §10's
# six-station sweep, the maintainer's wall — retained ONE region. Per-region
# evaluation lets several qualify at once, and the maintainer's own part cannot
# test that: exactly one of his eight regions is quiet enough (r1_per_region.txt),
# so per-region retains the same 822 voxels scoping-to-the-wall already did. N=1
# proves nothing about N>1.
#
# So this builds a part with TWO genuinely quiet regions and measures four runs:
#
#   none  neither region armed          (the control)
#   A     only the top slab retained
#   B     only the far-x slab retained
#   AB    both retained
#
# THE TEST, pre-stated in r0_preregistration.md (A-3): if Δ(AB) exceeds the worst
# single region's Δ by more than a factor of 2, the effects are NOT additive, the
# one-region measurement does not extrapolate, and that is the finding.
#
# ★ AND THE CAVEAT THAT GOVERNS HOW MUCH THIS IS WORTH, stated before the numbers
# rather than after: the certification is STRUCTURALLY BLIND to cells-per-member
# (lattice.hpp ★★). A flat result here is therefore WEAK evidence — it shows the
# macro solve did not notice, not that the lattice is accurate. It is run because
# a NON-flat result would still be informative: it could only mean something worse
# than the blindness already implies.
#
# THE TWO REGIONS WERE MEASURED, NOT GUESSED — and the first attempt got it wrong,
# which is why this note exists. A slab picked by eye at the x MINIMUM had ZERO
# candidate voxels (the optimizer leaves no material there), so "AB" was silently a
# one-region test that reported a serene additive result. Both regions are now taken
# from a scan of this part's own von Mises field at this resolution:
#   z-hi, 5.00 mm deep :   384 voxels, peak 0.0175 of the part's peak
#   x-hi, 5.00 mm deep : 5,233 voxels, peak 0.1095
# Both clear the 0.20 ceiling on their own, and both carry real material.
#
# ★ THE AGGREGATE CAP IS LIFTED HERE, deliberately and with the number stated. This
# fixture has only 13,291 printed voxels, so either region alone is a large share of
# it (z-hi is 2.9 %, x-hi far more) and the 3.0 % production cap refuses before the
# additivity question can even be asked — the first run of this script produced four
# IDENTICAL configurations, all retaining nothing, and called it additive. That is a
# vacuous pass, not a result. The cap is tested on its own in test_grading 13j and
# measured on the real part in r1_per_region.txt (0.930 % against 3.0 %); mixing the
# two questions here answers neither. This script now FAILS LOUDLY if any armed
# configuration retains nothing.
set -euo pipefail

CLI="${1:?usage: r2_additivity.sh <cli> <out-dir>}"
OUT="${2:?}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

mkdir -p "$OUT"
cp "$REPO/core/tests/fixtures/demo/l-bracket.step" "$OUT/"

python3 - "$OUT" <<'PY'
import json, os, sys
out = sys.argv[1]
base = {
  "model": "l-bracket.step", "material": "PLA", "mode": "minimize_plastic",
  "resolution": 48, "simp": {"max_iterations": 14},
  "loads": {"anchors": [{"kind": "cylindrical", "radius_mm": 2.5}],
            "groups": [{"face_ids": [2], "force": [0.0, 0.0, -60.0]}]},
  "lattice": {"topology": "octet", "emit_stl": True, "skin": "rim",
              "min_extrudable_width_mm": 0.42, "regions": []},
  "grading": {"topology": "octet", "cell_mode": "swept", "cell_min_mm": 4.0,
              "cell_max_mm": 16.0, "min_extrudable_width_mm": 0.42},
  "output": {"report": "report.json", "mesh_format": "stl",
             "mesh_prefix": "variant"},
}
# The slab runs from `origin` ALONG +normal, so a normal pointing INTO the part
# takes the material behind that face.
A = {"role": "include", "kind": "face",
     "geometry": {"origin": [0.0, 0.0, 60.0], "normal": [0.0, 0.0, -1.0],
                  "half_u_mm": 200.0, "half_w_mm": 200.0, "depth_mm": 5.0}}
B = {"role": "include", "kind": "face",
     "geometry": {"origin": [30.0, 0.0, 0.0], "normal": [-1.0, 0.0, 0.0],
                  "half_u_mm": 200.0, "half_w_mm": 200.0, "depth_mm": 5.0}}
for name, regions, armed in (("none", [A, B], False), ("A", [A], True),
                             ("B", [B], True), ("AB", [A, B], True)):
    j = json.loads(json.dumps(base))
    j["lattice"]["regions"] = regions
    if armed:
        j["grading"]["retain_subfloor_in_unloaded_regions"] = True
        # See the ★ note at the top: the cap is lifted so this script measures
        # ADDITIVITY rather than re-measuring the cap on an unrepresentatively
        # small fixture.
        j["grading"]["subfloor_aggregate_cap"] = 1.0
    json.dump(j, open(os.path.join(out, f"job_{name}.json"), "w"), indent=1)
PY

for n in none A B AB; do
  rm -rf "${OUT:?}/out_$n"
  ( cd "$OUT" && "$CLI" run "job_$n.json" --out "out_$n" > "$n.log" 2>&1 ) || {
    echo "RUN FAILED ($n)"; tail -20 "$OUT/$n.log"; exit 1; }
done

python3 - "$OUT" <<'PY'
import json, os, struct, sys
out = sys.argv[1]

def receipts(d):
    r = {}
    for f in sorted(os.listdir(os.path.join(out, d))):
        if f.endswith("_lattice.report.json"):
            r[f] = json.load(open(os.path.join(out, d, f)))
    return r

def read_fields(path):
    b = open(path, "rb").read()
    o = 4
    nx, ny, nz = struct.unpack_from("<iii", b, o); o += 12
    o += 8 * 3 + 8 + 8
    nvar, _ = struct.unpack_from("<ii", b, o); o += 8
    res = {}
    for _ in range(nvar):
        vf, = struct.unpack_from("<d", b, o); o += 8
        o += 16
        vm_n, st_n, dp_n = struct.unpack_from("<qqq", b, o); o += 24
        res[round(vf, 4)] = struct.unpack_from(f"<{vm_n}f", b, o) if vm_n else ()
        o += 4 * (vm_n + st_n + dp_n)
    return nx, ny, res

def argmax(vm, nx, ny):
    bi, best = 0, vm[0]
    for e in range(1, len(vm)):
        if vm[e] > best:
            best, bi = vm[e], e
    return best, (bi % nx, (bi // nx) % ny, bi // (nx * ny))

print("=== A-3 — ADDITIVITY: two quiet regions, alone and together ===")
print()
print("--- what each configuration retained ---")
print(f"{'cfg':>5} {'retained':>9} {'exposure':>10} {'cap':>8} {'over':>6}  per-region")
tot = {}
for n in ("none", "A", "B", "AB"):
    rs = receipts(f"out_{n}")
    ret = 0; expo = 0.0; cap = 0.0; over = False; rows = []
    for f, j in rs.items():
        s = ((j.get("grading") or {}).get("subfloor_retention") or {})
        ret += s.get("voxels_retained") or 0
        expo = max(expo, s.get("exposure_fraction_of_part") or 0.0)
        cap = s.get("aggregate_cap_fraction") or cap
        over = over or bool(s.get("over_budget"))
        for x in (s.get("regions") or []):
            if x.get("qualified"):
                rows.append(f"id{x['region_id']}@{x['stress_fraction_measured']:.4f}"
                            f"->{x['retained_voxels']}")
    tot[n] = ret
    print(f"{n:>5} {ret:>9} {expo:>9.4%} {cap:>7.1%} {str(over):>6}  "
          + ", ".join(sorted(set(rows))[:4]))
print()
# ★ THE GUARD THAT WAS MISSING. If an armed configuration retained nothing, every
# margin below is the SAME run four times and any "additive" verdict is vacuous.
vacuous = [n for n in ("A", "B", "AB") if tot[n] == 0]
if vacuous:
    print(f"  *** {', '.join(vacuous)} RETAINED NOTHING — this script measured "
          f"NOTHING. ***")
    print("  Four identical runs cannot answer whether two regions compose. Fix the")
    print("  fixture (regions with real sub-floor material, cap lifted) and re-run.")
    sys.exit(1)
print()
print(f"  retained(A) + retained(B) = {tot['A']} + {tot['B']} = {tot['A']+tot['B']}")
print(f"  retained(AB)              = {tot['AB']}")
print("  " + ("the two regions are DISJOINT and both were kept — AB is their sum."
      if tot['AB'] == tot['A'] + tot['B'] else
      "AB is NOT the sum of the singles — the regions overlap or the cap bound."))
print()

print("--- the composite certified margin, per rung ---")
print(f"{'rung':>7} {'none':>14} {'A':>14} {'B':>14} {'AB':>14} "
      f"{'dA':>9} {'dB':>9} {'dAB':>9}")
base = receipts("out_none")
worst_single = 0.0
worst_ab = 0.0
flip = False
for f in sorted(base):
    m = {}
    acc = {}
    for n in ("none", "A", "B", "AB"):
        j = receipts(f"out_{n}").get(f)
        m[n] = (j or {}).get("lattice_margin_worst_case")
        acc[n] = bool((j or {}).get("lattice_accepted"))
    if any(v is None for v in m.values()):
        continue
    d = {n: 100.0 * (m[n] - m["none"]) / m["none"] for n in ("A", "B", "AB")}
    for n in ("A", "B", "AB"):
        if acc[n] != acc["none"]:
            flip = True
    worst_single = max(worst_single, abs(d["A"]), abs(d["B"]))
    worst_ab = max(worst_ab, abs(d["AB"]))
    rung = f.replace("_lattice.report.json", "").replace("variant_", "")
    print(f"{rung:>7} {m['none']:>14.6f} {m['A']:>14.6f} {m['B']:>14.6f} "
          f"{m['AB']:>14.6f} {d['A']:>+8.4f}% {d['B']:>+8.4f}% {d['AB']:>+8.4f}%")
print()
print(f"  worst |d| for a SINGLE region : {worst_single:.4f}%")
print(f"  worst |d| for BOTH together   : {worst_ab:.4f}%")
print(f"  pre-stated bound (A-2)        : 0.10%")
ratio = (worst_ab / worst_single) if worst_single > 0 else float("inf")
print(f"  ratio AB / worst single       : {ratio:.2f}x  (A-3 flags > 2.00x)")
print()
# NOTE the guard above already rejected the vacuous case, so worst_single == 0.0
# here means the retained material genuinely did not move the margin — which, given
# the blindness, is the expected and least informative outcome rather than a pass to
# lean on.
ok = worst_ab <= 0.10 and (worst_single == 0.0 or ratio <= 2.0)
print("  A-2 " + ("MET" if worst_ab <= 0.10 else "EXCEEDED — BLOCKED-STOP"))
print("  A-3 " + ("MET — the effects are additive within the stated factor."
                  if worst_single == 0.0 or ratio <= 2.0 else
                  "NOT MET — retaining both moved the margin by more than 2x the "
                  "worst single region.\n       The one-region measurement does "
                  "NOT extrapolate. THIS IS THE FINDING."))
print(f"  verdict flips: {'YES — BLOCKED-STOP' if flip else 'none'}")
print()

print("--- A-1: the argmax, with BOTH regions retained ---")
nx, ny, vn = read_fields(os.path.join(out, "out_none", "fields.bin"))
_, _, va = read_fields(os.path.join(out, "out_AB", "fields.bin"))
print(f"{'rung':>7} {'peak none':>13} {'argmax none':>18} "
      f"{'peak AB':>13} {'argmax AB':>18}")
moved = False
for vf in sorted(set(vn) & set(va), reverse=True):
    if not vn[vf] or not va[vf]:
        continue
    p0, a0 = argmax(vn[vf], nx, ny)
    p1, a1 = argmax(va[vf], nx, ny)
    moved = moved or (a0 != a1)
    print(f"{vf:>7.2f} {p0:>13.6f} {str(a0):>18} {p1:>13.6f} {str(a1):>18}"
          f"  {'MOVED' if a0 != a1 else 'same'}")
print()
print("  A-1 " + ("FAILED — THE ARGMAX MOVED with both regions retained. "
                  "BLOCKED-STOP." if moved else
                  "MET — the peak von Mises stayed at the same voxel."))
print()
print("★ HOW MUCH THE MARGIN RESULTS ABOVE ARE WORTH: not much, and that is not a")
print("  hedge. The certification is STRUCTURALLY BLIND to cells-per-member — §10's")
print("  control swept the cell across the floor at fixed density and the margin was")
print("  identical to ten decimal places. A flat Δ here shows the macro solve did")
print("  not notice the change; it is NOT evidence the retained lattice is accurate.")
print("  The argmax result (A-1) is the load-bearing one, because a MOVING argmax")
print("  would indicate non-local redistribution the blind margin could still miss.")
sys.exit(0 if (not flip and not moved and ok) else 1)
PY
