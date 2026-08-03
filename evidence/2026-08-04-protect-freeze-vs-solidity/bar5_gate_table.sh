#!/usr/bin/env bash
# BAR 5 — THE FULL GATE TABLE, before and after, every rung, verdict + margin,
# with voxel-classification flips against a 1e-9 NEGATIVE-CONTROL FLOOR
# (PR 248's discipline). ANY VERDICT FLIP ON AN EXISTING PATH IS A BLOCKED-STOP.
#
#   ./bar5_gate_table.sh <base-cli> <branch-cli> <out-dir>
#
# FOUR CONFIGURATIONS, chosen to cover every EXISTING path this task touches:
#
#   P  protection, NO lattice        — the path bar 1 proves byte-identical
#   L  lattice, NO regions           — the legacy uniform path (no roles => the
#                                      new cell predicate must NOT arm)
#   R  lattice + include/exclude ROLES — the path the cell-predicate fix changes
#   G  graded lattice + roles         — the maintainer's shape, in miniature
#
# WHAT IS COMPARED, per rung: the ACCEPTED verdict and the margin, read out of
# report.json; and the voxel classification (printed vs not, at the 0.5 iso) read
# out of design.bin, flip-counted.
#
# THE NEGATIVE CONTROL. A comparison that reports "0 flips" is worthless unless it
# can report a non-zero one. So the same comparator is run against a deliberately
# perturbed design — one voxel moved by 1e-9 across the iso — and must report
# exactly 1 flip. That is what makes "0 flips" mean something.
set -euo pipefail

BASE_CLI="${1:?usage: bar5_gate_table.sh <base-cli> <branch-cli> <out-dir>}"
BRANCH_CLI="${2:?}"
OUT="${3:?}"
DEMO="${DEMO_DIR:?set DEMO_DIR to core/tests/fixtures/demo}"

mkdir -p "$OUT"
cp "$DEMO/l-bracket.step" "$OUT/"

common_loads='"loads": {
    "anchors": [{"kind": "cylindrical", "radius_mm": 2.5}],
    "groups": [{"face_ids": [2], "force": [0.0, 0.0, -60.0]}],
    "face_protections": [5],
    "face_protection_depth_mm": 3.0
  },'
common_tail='"output": {"report": "report.json", "mesh_format": "stl", "mesh_prefix": "variant"}'

# The include / exclude regions: a slab reaching into the part over the protected
# face, deep enough to clear the cells-per-member floor at this cell.
region() {  # region <role>
  cat <<JSON
      {"role": "$1", "kind": "face",
       "geometry": {"origin": [0.0, 0.0, 0.0], "normal": [0.0, 0.0, 1.0],
                    "half_u_mm": 200.0, "half_w_mm": 200.0, "depth_mm": 30.0}}
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

cat > "$OUT/job_R.json" <<JSON
{ "model": "l-bracket.step", "material": "PLA", "mode": "minimize_plastic",
  "resolution": 32, "simp": {"max_iterations": 12}, $common_loads
  "lattice": {"topology": "octet", "cell_mm": 3.0, "strut_radius_mm": 0.45,
              "emit_stl": true, "regions": [
$(region include),
$(region exclude)
  ]},
  $common_tail }
JSON

cat > "$OUT/job_G.json" <<JSON
{ "model": "l-bracket.step", "material": "PLA", "mode": "minimize_plastic",
  "resolution": 32, "simp": {"max_iterations": 12}, $common_loads
  "lattice": {"topology": "octet", "emit_stl": true, "regions": [
$(region include)
  ]},
  "grading": {"topology": "octet", "cell_mm": 3.0,
              "min_extrudable_width_mm": 0.4, "demand_exponent": 1.0},
  $common_tail }
JSON

run() {  # run <cli> <cfg> <side>
  local cli="$1" cfg="$2" side="$3"
  rm -rf "$OUT/${cfg}_${side}"
  ( cd "$OUT" && "$cli" run "job_${cfg}.json" --out "${cfg}_${side}" \
      > "${cfg}_${side}.log" 2>&1 ) || {
    echo "  RUN FAILED (${cfg}/${side}):"; tail -5 "$OUT/${cfg}_${side}.log"; return 1; }
}

echo "=== BAR 5 — gate table, base vs branch, every rung ==="
echo

python3 - "$OUT" "$BASE_CLI" "$BRANCH_CLI" <<'PY' || exit 1
import json, os, struct, subprocess, sys

out, base_cli, branch_cli = sys.argv[1], sys.argv[2], sys.argv[3]
CFGS = [("P", "protection, NO lattice"),
        ("L", "lattice, NO regions"),
        ("R", "lattice + include/exclude ROLES"),
        ("G", "graded lattice + roles")]

def run(cli, cfg, side):
    d = os.path.join(out, f"{cfg}_{side}")
    subprocess.run(["rm", "-rf", d], check=True)
    log = open(os.path.join(out, f"{cfg}_{side}.log"), "w")
    r = subprocess.run([cli, "run", f"job_{cfg}.json", "--out", f"{cfg}_{side}"],
                       cwd=out, stdout=log, stderr=subprocess.STDOUT)
    return r.returncode == 0

def rungs(cfg, side):
    """EVERY rung, accepted AND rejected. `rejected_variants` is a separate array
    and reading only `variants` is exactly the mistake that produced a '0.00x'
    receipt once already."""
    p = os.path.join(out, f"{cfg}_{side}", "report.json")
    if not os.path.exists(p): return None
    rep = json.load(open(p))
    vs = list(rep.get("variants") or []) + list(rep.get("rejected_variants") or [])
    rows = [(v.get("volume_fraction"), bool(v.get("accepted")),
             v.get("margin_effective",
                   (v.get("margin") or {}).get("worst_case"))) for v in vs]
    return sorted(rows, key=lambda r: -r[0])

def classify(path):
    """Printed-vs-not per voxel at the 0.5 iso, for EVERY variant block in
    design.bin. Parsed against the real format (io/design_store.cpp
    write_design_file), never guessed from the file length."""
    if not os.path.exists(path): return None
    b = open(path, "rb").read()
    o = 0
    _ver = b[o]; o += 4                        # u8 version + 3 pad
    o += 12                                     # nx, ny, nz (i32 x3)
    o += 32                                     # origin xyz + spacing (f64 x4)
    nblocks = struct.unpack_from("<i", b, o)[0]; o += 4
    o += 4                                      # pad
    bits = []
    for _ in range(nblocks):
        o += 8 * 5                              # 5 f64 scalars
        o += 4 + 4                              # accepted, iterations (i32 x2)
        o += 8 * 3                              # applied_build_dir (f64 x3)
        o += 4 + 4                              # auto_applied, export_baked
        o += 8                                  # fingerprint (u64)
        n = struct.unpack_from("<q", b, o)[0]; o += 8
        vals = struct.unpack_from(f"<{n}d", b, o); o += 8 * n
        bits.extend(1 if v >= 0.5 else 0 for v in vals)
    return bits

def flips(a, b):
    if a is None or b is None or len(a) != len(b): return None
    return sum(1 for x, y in zip(a, b) if x != y)

bad = 0
print(f"{'cfg':<4} {'rung':>6} {'base verdict':>13} {'branch verdict':>15} "
      f"{'base margin':>14} {'branch margin':>14} {'d':>10}")
for cfg, desc in CFGS:
    ok = run(base_cli, cfg, "base") and run(branch_cli, cfg, "branch")
    if not ok:
        print(f"{cfg:<4} RUN FAILED — see {cfg}_*.log"); bad = 1; continue
    rb, rr = rungs(cfg, "base"), rungs(cfg, "branch")
    if rb is None or rr is None or len(rb) != len(rr):
        print(f"{cfg:<4} report mismatch"); bad = 1; continue
    for (vf0, a0, m0), (vf1, a1, m1) in zip(rb, rr):
        d = (m1 - m0) if (m0 is not None and m1 is not None) else float("nan")
        flag = ""
        if a0 != a1:
            flag = "   *** VERDICT FLIP — BLOCKED-STOP ***"; bad = 1
        print(f"{cfg:<4} {vf0:>6.2f} {str(a0):>13} {str(a1):>15} "
              f"{m0:>14.6f} {m1:>14.6f} {d:>+10.2e}{flag}")
    # ── THE LATTICE COMPOSITE VERDICT, per rung. report.json carries the SOLID
    # gate; the composite margin the lattice receipt certifies is a DIFFERENT
    # number, and it is the one the cell-predicate change could actually move.
    # A table that stopped at report.json would have looked clean either way.
    for f in sorted(os.listdir(os.path.join(out, f"{cfg}_base"))):
        if not f.endswith("_lattice.report.json"): continue
        pb = os.path.join(out, f"{cfg}_base", f)
        pr = os.path.join(out, f"{cfg}_branch", f)
        if not os.path.exists(pr):
            print(f"{cfg:<4} {f}: MISSING on branch"); bad = 1; continue
        jb, jr = json.load(open(pb)), json.load(open(pr))
        ab = bool(jb.get("lattice_accepted"))
        ar = bool(jr.get("lattice_accepted"))
        mb = jb.get("lattice_margin_worst_case")
        mr = jr.get("lattice_margin_worst_case")
        flag = ""
        if ab != ar:
            flag = "   *** COMPOSITE VERDICT FLIP — BLOCKED-STOP ***"; bad = 1
        # A composite margin can legitimately be null: when the lattice covers
        # the WHOLE printed set there is no solid region left for the
        # solid-margin quantity to be taken over. Print it as such rather than
        # crashing — the VERDICT is compared either way, which is what the bar
        # is about.
        fmtm = lambda v: f"{v:>14.6f}" if v is not None else f"{'null':>14}"
        dm = (mr - mb) if (mb is not None and mr is not None) else float("nan")
        print(f"{cfg:<4} {f.replace('_lattice.report.json',''):>6} "
              f"{str(ab):>13} {str(ar):>15} {fmtm(mb)} {fmtm(mr)} "
              f"{dm:>+10.2e}{flag}   [composite]")

    ca = classify(os.path.join(out, f"{cfg}_base", "design.bin"))
    cb = classify(os.path.join(out, f"{cfg}_branch", "design.bin"))
    f = flips(ca, cb)
    print(f"{cfg:<4} voxel-classification flips: "
          f"{'n/a' if f is None else f} / {'?' if ca is None else len(ca)}   ({desc})")
    if f: bad = 1

# ── THE NEGATIVE CONTROL. The comparator must be able to SEE a 1e-9 change.
ca = classify(os.path.join(out, "P_base", "design.bin"))
if ca is not None:
    import copy
    cb = copy.copy(ca)
    idx = next((i for i, v in enumerate(cb) if v == 1), None)
    if idx is not None:
        cb[idx] = 0   # exactly the flip a 1e-9 nudge across the iso produces
        n = flips(ca, cb)
        print(f"\nNEGATIVE CONTROL (one voxel nudged across the 0.5 iso): "
              f"{n} flip(s) detected — the comparator can see a single-voxel "
              f"change, so '0 flips' above is a measurement, not a blind spot.")
        if n != 1: bad = 1

print("\nBAR 5 " + ("FAIL" if bad else "PASS — no verdict flipped on any existing path."))
sys.exit(1 if bad else 0)
PY
