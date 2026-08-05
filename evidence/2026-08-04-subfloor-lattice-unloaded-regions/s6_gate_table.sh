#!/usr/bin/env bash
# S6 — THE FULL GATE TABLE, before and after, every rung, verdict + margin, with
# voxel-classification flips against a 1e-9 NEGATIVE-CONTROL FLOOR (PR 248's
# discipline). ANY VERDICT FLIP IS A BLOCKED-STOP.
# (task 2026-08-04-subfloor-lattice-unloaded-regions)
#
#   ./s6_gate_table.sh <base-cli> <branch-cli> <out-dir>
#
# FIVE CONFIGURATIONS. The first four are EXISTING paths and are compared BASE vs
# BRANCH: none of them opts in, so every one of them must be unchanged.
#
#   P  protection, NO lattice          — no grading at all
#   L  lattice, NO grading             — the legacy uniform lattice path
#   G  graded lattice, uniform cell    — grade_lattice on the Fixed path
#   W  graded lattice, SWEPT + roles   — the maintainer's shape, in miniature
#
# The fifth exists only on the branch, so it is compared BRANCH-OFF vs BRANCH-ON —
# which is the only honest comparison for a feature base cannot express:
#
#   S  W + retain_subfloor_in_unloaded_regions: true
#
# WHAT IS COMPARED, per rung: the ACCEPTED verdict and the margin from report.json;
# the COMPOSITE lattice verdict and margin from each per-variant lattice receipt
# (a different number from the solid gate, and the one this change could actually
# move); and the voxel classification (printed vs not, at the 0.5 iso) from
# design.bin, flip-counted.
#
# THE NEGATIVE CONTROL. A comparison that reports "0 flips" is worthless unless it
# CAN report a non-zero one. So the same comparator is run against a deliberately
# perturbed design — one voxel moved by 1e-9 across the iso — and must report
# exactly 1 flip. That is what makes every "0 flips" above it mean something.
set -euo pipefail

BASE_CLI="${1:?usage: s6_gate_table.sh <base-cli> <branch-cli> <out-dir>}"
BRANCH_CLI="${2:?}"
OUT="${3:?}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEMO="$REPO/core/tests/fixtures/demo"

mkdir -p "$OUT"
cp "$DEMO/l-bracket.step" "$OUT/"

common_loads='"loads": {
    "anchors": [{"kind": "cylindrical", "radius_mm": 2.5}],
    "groups": [{"face_ids": [2], "force": [0.0, 0.0, -60.0]}],
    "face_protections": [5],
    "face_protection_depth_mm": 3.0
  },'
common_tail='"output": {"report": "report.json", "mesh_format": "stl", "mesh_prefix": "variant"}'

# An include region: a slab reaching into the part from the top face. Deliberately
# shallow (6 mm) so it catches THIN material — that is the population sub-floor
# retention is about, and a region that only covered thick material would make
# configuration S a no-op and prove nothing.
region() {  # region <role> <depth>
  cat <<JSON
      {"role": "$1", "kind": "face",
       "geometry": {"origin": [0.0, 0.0, 0.0], "normal": [0.0, 0.0, 1.0],
                    "half_u_mm": 200.0, "half_w_mm": 200.0, "depth_mm": $2}}
JSON
}

cat > "$OUT/job_P.json" <<JSON
{ "model": "l-bracket.step", "material": "PLA", "mode": "minimize_plastic",
  "resolution": 32, "simp": {"max_iterations": 12}, $common_loads $common_tail }
JSON

cat > "$OUT/job_L.json" <<JSON
{ "model": "l-bracket.step", "material": "PLA", "mode": "minimize_plastic",
  "resolution": 32, "simp": {"max_iterations": 12}, $common_loads
  "lattice": {"topology": "octet", "cell_mm": 3.0, "strut_radius_mm": 0.45,
              "emit_stl": true},
  $common_tail }
JSON

cat > "$OUT/job_G.json" <<JSON
{ "model": "l-bracket.step", "material": "PLA", "mode": "minimize_plastic",
  "resolution": 32, "simp": {"max_iterations": 12}, $common_loads
  "lattice": {"topology": "octet", "emit_stl": true},
  "grading": {"topology": "octet", "cell_mm": 3.0,
              "min_extrudable_width_mm": 0.4, "demand_exponent": 1.0},
  $common_tail }
JSON

cat > "$OUT/job_W.json" <<JSON
{ "model": "l-bracket.step", "material": "PLA", "mode": "minimize_plastic",
  "resolution": 32, "simp": {"max_iterations": 12}, $common_loads
  "lattice": {"topology": "octet", "emit_stl": true, "regions": [
$(region include 6.0)
  ]},
  "grading": {"topology": "octet", "cell_mode": "swept", "cell_min_mm": 2.0,
              "cell_max_mm": 8.0, "min_extrudable_width_mm": 0.4},
  $common_tail }
JSON

# Q / S — THE CONFIGURATION WHERE RETENTION ACTUALLY FIRES.
#
# W's include region reaches in from the BOTTOM face, which on this part is where
# the load and the anchor are: it measures ~1.00 of peak stress and retention
# correctly refuses it. That proves the predicate REFUSES, which is necessary but
# is not a demonstration that the feature works.
#
# So Q reaches in from the OPPOSITE face. That slab was measured, not guessed, off
# W's own fields.bin: peak von Mises there is 0.0219 of the part's peak — a piece
# of this bracket that genuinely carries almost nothing, which is the maintainer's
# "back wall that exists for geometry" as closely as an l-bracket can express it.
#
#   Q = the quiet region, NOT armed   (the control)
#   S = the same job, ARMED           (the treatment)
#
# Both run on the BRANCH binary, because base cannot parse the key at all. The
# pair is what prices the feature: same design, same region, retention the only
# difference.
python3 - "$OUT" <<'PY'
import json, os, sys
out = sys.argv[1]
d = json.load(open(os.path.join(out, "job_W.json")))
# The slab runs from `origin` ALONG +normal for `depth` — so to take the TOP
# 8 mm the normal points DOWN from the z=60 face. Pointing it up put the slab
# entirely outside the part and the region came back empty (region_voxels 0,
# composite margin identical to the solid one) — which is exactly how that
# mistake announced itself, and why the "retained N of M" column is printed.
quiet = [{"role": "include", "kind": "face",
          "geometry": {"origin": [0.0, 0.0, 60.0], "normal": [0.0, 0.0, -1.0],
                       "half_u_mm": 200.0, "half_w_mm": 200.0,
                       "depth_mm": 8.0}}]
d["lattice"]["regions"] = quiet
# COARSEN THE LADDER for this pair. At the 2-8 mm ladder W uses, the material in
# this region is thick enough to clear the cells-per-member floor, so retention
# qualifies and then has nothing to retain ("0 of 0") — a row that tests nothing.
# At 4-16 mm the floor demands 5 x 4 = 20 mm of member and an 8 mm-deep slab
# cannot supply it, so the region is genuinely sub-floor and the treatment bites.
d["grading"]["cell_min_mm"] = 4.0
d["grading"]["cell_max_mm"] = 16.0
json.dump(d, open(os.path.join(out, "job_Q.json"), "w"), indent=1)
d2 = json.loads(json.dumps(d))
d2["grading"]["retain_subfloor_in_unloaded_regions"] = True
json.dump(d2, open(os.path.join(out, "job_S.json"), "w"), indent=1)
PY

echo "=== S6 — gate table, every rung ==="
echo "base   cli: $BASE_CLI"
echo "branch cli: $BRANCH_CLI"
echo

python3 - "$OUT" "$BASE_CLI" "$BRANCH_CLI" <<'PY' || exit 1
import json, os, struct, subprocess, sys

out, base_cli, branch_cli = sys.argv[1], sys.argv[2], sys.argv[3]

# (cfg, description, left-side cli, right-side cli, left label, right label)
CFGS = [("P", "protection, NO lattice",        "base",   "branch"),
        ("L", "lattice, NO grading",           "base",   "branch"),
        ("G", "graded lattice, uniform cell",  "base",   "branch"),
        ("W", "graded lattice, SWEPT + roles", "base",   "branch"),
        ("S", "QUIET region, retention ARMED vs not", "offarm", "onarm")]
CLI = {"base": base_cli, "branch": branch_cli,
       "offarm": branch_cli, "onarm": branch_cli}
# Configuration S's two sides are the SAME binary run on two JOBS: the left side
# is job_W (not armed), the right is job_S (armed). Every other row runs the same
# job on two binaries.
JOB = {"P": {}, "L": {}, "G": {}, "W": {}, "S": {"offarm": "Q", "onarm": "S"}}


def run(cfg, side):
    job = JOB[cfg].get(side, cfg)
    d = f"{cfg}_{side}"
    subprocess.run(["rm", "-rf", os.path.join(out, d)], check=True)
    log = open(os.path.join(out, f"{d}.log"), "w")
    r = subprocess.run([CLI[side], "run", f"job_{job}.json", "--out", d],
                       cwd=out, stdout=log, stderr=subprocess.STDOUT)
    return r.returncode == 0


def rungs(cfg, side):
    """EVERY rung, accepted AND rejected. `rejected_variants` is a separate array
    and reading only `variants` is exactly the mistake that produced a '0.00x'
    receipt once already."""
    p = os.path.join(out, f"{cfg}_{side}", "report.json")
    if not os.path.exists(p):
        return None
    rep = json.load(open(p))
    vs = list(rep.get("variants") or []) + list(rep.get("rejected_variants") or [])
    rows = [(v.get("volume_fraction"), bool(v.get("accepted")),
             v.get("worst_case_margin",
                   (v.get("margin") or {}).get("worst_case"))) for v in vs]
    return sorted(rows, key=lambda r: -r[0])


def classify(path):
    """Printed-vs-not per voxel at the 0.5 iso, for EVERY variant block in
    design.bin. Parsed against the real format, never guessed from file length."""
    if not os.path.exists(path):
        return None
    b = open(path, "rb").read()
    o = 0
    o += 4                                      # u8 version + 3 pad
    o += 12                                     # nx, ny, nz
    o += 32                                     # origin xyz + spacing
    nblocks = struct.unpack_from("<i", b, o)[0]; o += 4
    o += 4                                      # pad
    bits = []
    for _ in range(nblocks):
        o += 8 * 5                              # 5 f64 scalars
        o += 4 + 4                              # accepted, iterations
        o += 8 * 3                              # applied_build_dir
        o += 4 + 4                              # auto_applied, export_baked
        o += 8                                  # fingerprint
        n = struct.unpack_from("<q", b, o)[0]; o += 8
        vals = struct.unpack_from(f"<{n}d", b, o); o += 8 * n
        bits.extend(1 if v >= 0.5 else 0 for v in vals)
    return bits


def flips(a, b):
    if a is None or b is None or len(a) != len(b):
        return None
    return sum(1 for x, y in zip(a, b) if x != y)


bad = 0
print(f"{'cfg':<4} {'rung':>7} {'L verdict':>11} {'R verdict':>11} "
      f"{'L margin':>15} {'R margin':>15} {'d':>11}")
print("-" * 82)
for cfg, desc, ls, rs in CFGS:
    print(f"[{cfg}] {desc}   ({ls} vs {rs})")
    if not (run(cfg, ls) and run(cfg, rs)):
        print(f"{cfg:<4} RUN FAILED — see {cfg}_*.log"); bad = 1; continue
    rl, rr = rungs(cfg, ls), rungs(cfg, rs)
    if rl is None or rr is None or len(rl) != len(rr):
        print(f"{cfg:<4} report mismatch"); bad = 1; continue
    for (vf0, a0, m0), (vf1, a1, m1) in zip(rl, rr):
        d = (m1 - m0) if (m0 is not None and m1 is not None) else float("nan")
        flag = ""
        if a0 != a1:
            flag = "   *** VERDICT FLIP — BLOCKED-STOP ***"; bad = 1
        print(f"{cfg:<4} {vf0:>7.2f} {str(a0):>11} {str(a1):>11} "
              f"{m0:>15.6f} {m1:>15.6f} {d:>+11.2e}{flag}")
    # THE COMPOSITE verdict, per rung. report.json carries the SOLID gate; the
    # margin the lattice receipt certifies is a DIFFERENT number, and it is the
    # one sub-floor retention actually moves. A table that stopped at report.json
    # would have looked clean either way.
    ldir = os.path.join(out, f"{cfg}_{ls}")
    for f in sorted(os.listdir(ldir)):
        if not f.endswith("_lattice.report.json"):
            continue
        pr = os.path.join(out, f"{cfg}_{rs}", f)
        if not os.path.exists(pr):
            print(f"{cfg:<4} {f}: MISSING on the right side"); bad = 1; continue
        jl, jr = json.load(open(os.path.join(ldir, f))), json.load(open(pr))
        al, ar = bool(jl.get("lattice_accepted")), bool(jr.get("lattice_accepted"))
        ml, mr = jl.get("lattice_margin_worst_case"), jr.get("lattice_margin_worst_case")
        flag = ""
        if al != ar:
            flag = "   *** COMPOSITE VERDICT FLIP — BLOCKED-STOP ***"; bad = 1
        fm = lambda v: f"{v:>15.6f}" if v is not None else f"{'null':>15}"
        dm = (mr - ml) if (ml is not None and mr is not None) else float("nan")
        # ...and what retention actually retained, where it is armed.
        sub = ((jr.get("grading") or {}).get("subfloor_retention") or {})
        extra = ""
        if sub.get("armed"):
            gr = jr.get("grading") or {}
            extra = (f"   [region {gr.get('region_voxels')} vox, latticed "
                     f"{gr.get('latticed_voxels')}, retained "
                     f"{sub.get('voxels_retained')} of "
                     f"{sub.get('voxels_below_floor')} below-floor, region frac "
                     f"{sub.get('region_stress_fraction_measured'):.4f}]")
            if not gr.get("region_voxels"):
                extra += "  *** REGION IS EMPTY — this row tests NOTHING ***"
                bad = 1
            elif not sub.get("voxels_below_floor"):
                extra += ("  *** NOTHING BELOW THE FLOOR — retention had nothing "
                          "to do, so this row tests NOTHING ***")
                bad = 1
        print(f"{cfg:<4} {f.replace('_lattice.report.json',''):>7} "
              f"{str(al):>11} {str(ar):>11} {fm(ml)} {fm(mr)} "
              f"{dm:>+11.2e}{flag}   [composite]{extra}")
    # VOXEL CLASSIFICATION FLIPS.
    cl = classify(os.path.join(out, f"{cfg}_{ls}", "design.bin"))
    cr = classify(os.path.join(out, f"{cfg}_{rs}", "design.bin"))
    n = flips(cl, cr)
    if n is None:
        print(f"{cfg:<4} {'design.bin':>7}  classification not comparable"); bad = 1
    else:
        note = ""
        if cfg != "S" and n != 0:
            note = "   *** CLASSIFICATION FLIP ON AN EXISTING PATH ***"; bad = 1
        print(f"{cfg:<4} {'design.bin':>7}  voxel-classification flips: {n}"
              f" of {len(cl)}{note}")
    print()

# ── THE NEGATIVE CONTROL. Without it "0 flips" is not a measurement.
print("--- negative control: the comparator must be able to SEE one voxel ---")
ctrl = classify(os.path.join(out, "P_base", "design.bin"))
if ctrl is None:
    print("no design.bin to perturb — control could not run"); bad = 1
else:
    perturbed = list(ctrl)
    # Flip exactly one voxel's classification — the effect a 1e-9 nudge across
    # the 0.5 iso has on the quantity being compared.
    idx = next((i for i, v in enumerate(perturbed) if v == 1), None)
    perturbed[idx] = 0
    got = flips(ctrl, perturbed)
    ok = (got == 1)
    print(f"one voxel moved by 1e-9 across the iso -> comparator reports "
          f"{got} flip(s); expected 1: {'PASS' if ok else 'FAIL'}")
    if not ok:
        bad = 1

print()
if bad:
    print("S6 FAIL — see the flagged rows above.")
    sys.exit(1)
print("S6 PASS — no verdict flip on any rung of any configuration, solid or")
print("          composite; no voxel-classification flip on any existing path;")
print("          and the negative control proves the comparator can see a")
print("          single-voxel difference.")
PY
