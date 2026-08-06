#!/usr/bin/env bash
# S4(b) — THE FULL FLIP TABLE for the case that MOVES: the strut width 0.42 -> 0.45.
#
#   ./S4b_flip_table.sh <branch-build-dir> <out-dir>
#
# S4(a) proves byte-identity where the strut width is UNCHANGED. This is the other
# half, and the task inverts the usual rule for it: the flips ARE the deliverable, so
# every one is enumerated with the width it was computed at (bar R3) and explained
# from the width change, or it is a blocked-stop.
#
# TWO REGION SIZES, because the width acts through TWO different terms and quoting
# only one of them would misdescribe the change:
#
#   THIN (4 mm)   the FINEST PRINTABLE CELL binds. cell = w / phi(rho_max), so the
#                 cell itself moves 1.0950 mm (at 0.42) -> 1.1732 mm (at 0.45),
#                 +7.14 %. This is the "~7.1 % coarser" case.
#   THICK (12 mm) the ACCURACY floor binds. cell = extent / N* = 2.4000 mm at BOTH
#                 widths — the cell does NOT move — and the change lands entirely on
#                 the DENSITY that prints at it, 0.1751 (at 0.42) -> 0.1961 (at 0.45).
#
# ★ THE NEGATIVE CONTROL. A third run at 0.42 + 1e-9 mm establishes the floor: a
# width perturbation nine orders of magnitude below the real one must produce ZERO
# voxel-classification flips and a bit-identical design. Without it, "N voxels
# flipped" is a number with no scale, and this project has shipped a comparison bar
# that passed vacuously before.
#
# SELF-WEIGHT PATH, not a "loads" block: the schema refuses both `ladder` and
# `margin_stop` on the loadcase path and the production ladder runs to the MMA
# plateau, which is hours per side. Here the ladder is stated (three rungs) so
# "every rung, verdict and margin" is a bounded thing to table.
set -euo pipefail
BUILD="$(cd "${1:?usage: S4b_flip_table.sh <build-dir> <out-dir>}" && pwd)"
mkdir -p "${2:?}"
OUT="$(cd "$2" && pwd)"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cp "$REPO/core/tests/fixtures/demo/l-bracket.step" "$OUT/"

python3 - "$OUT" <<'PY'
import json, os, sys
out = sys.argv[1]
def job(width, depth):
    regions = [{"role": "include", "kind": "face",
                "geometry": {"origin": [0.0, 0.0, 10.0], "normal": [0.0, 0.0, 1.0],
                             "half_u_mm": 200.0, "half_w_mm": 200.0,
                             "depth_mm": depth}}]
    return {
      "model": "l-bracket.step", "material": "PLA", "mode": "minimize_plastic",
      "resolution": 40, "simp": {"max_iterations": 20},
      "fixture_faces": [{"kind": "cylindrical", "radius_mm": 2.5}],
      "gravity": {"direction": [0.0, 0.0, -1.0], "magnitude_mm_s2": 9810.0},
      "ladder": [0.8, 0.7, 0.6], "margin_stop": 0.0,
      "lattice": {"topology": "octet", "emit_stl": True, "skin": "none",
                  "min_extrudable_width_mm": width, "regions": regions},
      "grading": {"topology": "octet", "cell_mode": "fit",
                  "min_extrudable_width_mm": width},
      "output": {"report": "report.json", "mesh_format": "stl",
                 "mesh_prefix": "variant"}
    }
for name, w, d in (("thin_042",  0.42,          4.0),
                   ("thin_045",  0.45,          4.0),
                   ("thin_ctrl", 0.42 + 1e-9,   4.0),
                   ("thick_042", 0.42,         12.0),
                   ("thick_045", 0.45,         12.0),
                   ("thick_ctrl", 0.42 + 1e-9, 12.0)):
    json.dump(job(w, d), open(os.path.join(out, f"job_{name}.json"), "w"), indent=1)
PY

run() { # run <name>
  rm -rf "${OUT:?}/$1"
  set +e
  ( cd "$OUT" && "$BUILD/topopt-cli" run "job_$1.json" --out "$1" > "$1.log" 2>&1 )
  local rc=$?
  set -e
  echo "$rc"
}

for n in thin_042 thin_045 thin_ctrl thick_042 thick_045 thick_ctrl; do
  echo "run $n: exit $(run $n)"
done
echo

python3 - "$OUT" <<'PY'
import json, os, struct, sys
out = sys.argv[1]

def read_design(path):
    """design.bin v1 -> (grid dims, [ {rung, achieved, margin_wc, margin_eff,
    max_vm, accepted, iterations, fingerprint, density(list[f64])} ])"""
    with open(path, "rb") as f:
        b = f.read()
    ver = b[0]
    if ver != 1:
        raise SystemExit(f"design.bin version {ver} — reader is v1 only")
    o = 4
    nx, ny, nz = struct.unpack_from("<iii", b, o); o += 12
    o += 24 + 8            # origin (3 f64) + spacing (f64)
    (nvar,) = struct.unpack_from("<i", b, o); o += 8   # + reserved i32
    out_v = []
    for _ in range(nvar):
        rung, ach, mwc, meff, mvm = struct.unpack_from("<ddddd", b, o); o += 40
        acc, iters = struct.unpack_from("<ii", b, o); o += 8
        o += 24            # applied_build_dir (3 f64)
        o += 8             # auto_applied i32 + export_baked i32
        (fp,) = struct.unpack_from("<Q", b, o); o += 8
        (n,) = struct.unpack_from("<q", b, o); o += 8
        rho = struct.unpack_from(f"<{n}d", b, o); o += 8 * n
        out_v.append(dict(rung=rung, achieved=ach, margin_wc=mwc, margin_eff=meff,
                          max_vm=mvm, accepted=bool(acc), iterations=iters,
                          fingerprint=fp, rho=rho))
    return (nx, ny, nz), out_v

# THE CLASSIFICATION, and its floor. A voxel is VOID below 1e-9 (the negative-control
# floor: densities are f64 and the solver's own zero is exact, so anything at or under
# 1e-9 is "not there"), SOLID above 0.5 (the iso-level the mesher extracts at), and
# GRAY between. A flip is a change of class, not a change of value.
def classify(r):
    if r <= 1e-9: return "void"
    return "solid" if r > 0.5 else "gray"

def rung_table(sub):
    p = os.path.join(out, sub, "report.json")
    if not os.path.exists(p): return None
    rows = []
    R = json.load(open(p))
    for v in (R.get("variants") or []):
        rows.append((v.get("volume_fraction"),
                     "ACCEPTED" if v.get("accepted") else "REJECTED",
                     (v.get("margin") or {}).get("worst_case"),
                     v.get("margin_effective"),
                     v.get("printed_fraction")))
    for v in (R.get("rejected_variants") or []):
        rows.append((v.get("volume_fraction"), "REJECTED",
                     (v.get("margin") or {}).get("worst_case"),
                     v.get("margin_effective"),
                     v.get("printed_fraction")))
    return rows

def mesh_hashes(sub):
    import hashlib
    d = os.path.join(out, sub)
    if not os.path.isdir(d): return {}
    hs = {}
    for f in sorted(os.listdir(d)):
        if f.endswith(".stl") or f.endswith("_lattice.report.json"):
            hs[f] = hashlib.sha256(open(os.path.join(d, f), "rb").read()).hexdigest()[:16]
    return hs

def grading(sub):
    p = os.path.join(out, sub, "run_info.json")
    if not os.path.exists(p): return {}
    return (json.load(open(p)).get("grading") or {})

def compare(a, b, label):
    pa = os.path.join(out, a, "design.bin"); pb = os.path.join(out, b, "design.bin")
    if not (os.path.exists(pa) and os.path.exists(pb)):
        print(f"  {label}: design.bin missing on one side — cannot compare"); return None
    ga, va = read_design(pa); gb, vb = read_design(pb)
    if ga != gb or len(va) != len(vb):
        print(f"  {label}: grids/variant counts differ ({ga} x{len(va)} vs {gb} x{len(vb)})")
        return None
    total_flips = 0
    for i, (x, y) in enumerate(zip(va, vb)):
        flips = {}
        dmax = 0.0
        for ra, rb in zip(x["rho"], y["rho"]):
            d = abs(ra - rb)
            if d > dmax: dmax = d
            ca, cb = classify(ra), classify(rb)
            if ca != cb: flips[(ca, cb)] = flips.get((ca, cb), 0) + 1
        n = sum(flips.values())
        total_flips += n
        same_fp = x["fingerprint"] == y["fingerprint"]
        print(f"  {label}  rung {x['rung']:.2f}: voxel-class flips {n}"
              f"   max |d rho| {dmax:.3e}   design fingerprint {'SAME' if same_fp else 'DIFFERS'}")
        for (ca, cb), c in sorted(flips.items()):
            print(f"      {ca} -> {cb}: {c}")
    return total_flips

print("=== 1. THE NEGATIVE CONTROL — a 1e-9 mm width perturbation ===")
print("    0.42 mm vs 0.42 + 1e-9 mm. This must be ZERO flips, or every count below")
print("    is noise and the bar is vacuous.")
ctrl_thin = compare("thin_042", "thin_ctrl", "THIN  4 mm")
ctrl_thick = compare("thick_042", "thick_ctrl", "THICK 12 mm")
for name, v in (("thin", ctrl_thin), ("thick", ctrl_thick)):
    if v is None: print(f"    {name}: NOT ESTABLISHED")
    elif v == 0:  print(f"    {name}: 0 flips — the floor holds.")
    else:         print(f"    ★ {name}: {v} flips at 1e-9 — THE CONTROL FAILED.")
print()

print("=== 2. THE RUNG TABLE — every rung, verdict and margin, both widths ===")
for tag, a, b in (("THIN  4 mm region", "thin_042", "thin_045"),
                  ("THICK 12 mm region", "thick_042", "thick_045")):
    print(f"  --- {tag} ---")
    ta, tb = rung_table(a), rung_table(b)
    if ta is None or tb is None:
        print("    a run produced no report.json; see the .log"); continue
    print("      rung | verdict @0.42mm |   worst-case margin | effective margin | "
          "printed frac || verdict @0.45mm |   worst-case margin | effective margin | "
          "printed frac | MOVED?")
    for ra, rb in zip(ta, tb):
        moved = "no" if ra == rb else "YES"
        print(f"      {ra[0]:.4f} | {ra[1]:>15} | {ra[2]:>19} | {ra[3]:>16} | "
              f"{ra[4]:>12} || {rb[1]:>15} | {rb[2]:>19} | {rb[3]:>16} | "
              f"{rb[4]:>12} | {moved}")
    if len(ta) != len(tb):
        print(f"    ★ the ladder LENGTH moved: {len(ta)} rungs at 0.42 mm, "
              f"{len(tb)} at 0.45 mm")
    # The EMITTED artefacts, so "the design did not move" and "nothing moved" stay
    # distinguishable: the lattice mesh is generated from the derived cell.
    ha, hb = mesh_hashes(a), mesh_hashes(b)
    for f in sorted(set(ha) | set(hb)):
        same = ha.get(f) == hb.get(f)
        print(f"      {f}: {'IDENTICAL' if same else 'DIFFERS'}"
              f"  ({ha.get(f, '-')} vs {hb.get(f, '-')})")
print()

print("=== 3. THE DESIGN ITSELF — 0.42 mm vs 0.45 mm ===")
d_thin = compare("thin_042", "thin_045", "THIN  4 mm")
d_thick = compare("thick_042", "thick_045", "THICK 12 mm")
print()

print("=== 4. THE LATTICE DERIVATION, each figure beside its width (bar R3) ===")
for tag, a, b in (("THIN  4 mm region", "thin_042", "thin_045"),
                  ("THICK 12 mm region", "thick_042", "thick_045")):
    print(f"  --- {tag} ---")
    for sub, w in ((a, 0.42), (b, 0.45)):
        g = grading(sub)
        fit = g.get("fit") or {}
        print(f"    at a {w:.2f} mm stated strut width: cell_size_mm {g.get('cell_size_mm')}  "
              f"printability_floor_mm {g.get('printability_floor_mm')}  "
              f"finest_printable_cell {fit.get('min_printable_cell_mm')}")
        print(f"        latticed {g.get('latticed_voxels')}  "
              f"solid_fallback {g.get('solid_fallback_voxels')}  "
              f"rho_used [{g.get('rho_min_used')}, {g.get('rho_max_used')}]  "
              f"density_raised {fit.get('density_raised_for_print_voxels')}  "
              f"out_of_regime_voxels {fit.get('out_of_regime_voxels')}")
        for r in fit.get("regions", []):
            print(f"        region {r['region_index']}: extent {r['extent_mm']} mm -> "
                  f"cell {r['cell_mm']} mm, rho {r['relative_density']}, "
                  f"strut {r['strut_mm']} mm, {r['cells_per_member']} cells/member, "
                  f"out_of_regime {r['out_of_regime']}, "
                  f"candidates {r['candidate_voxels']}, latticed {r['latticed_voxels']}")
print()

print("=== 5. VERDICT ===")
ok = (ctrl_thin == 0 and ctrl_thick == 0)
print(f"    negative control at 1e-9 mm: {'CLEAN (0 flips both fixtures)' if ok else 'FAILED'}")
print(f"    design voxel-class flips 0.42 -> 0.45 mm: thin {d_thin}, thick {d_thick}")
PY
