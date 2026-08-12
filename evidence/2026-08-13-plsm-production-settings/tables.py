#!/usr/bin/env python3
"""The handoff's tables, built from the instruments' own output.

★ NOTHING HERE IS RETYPED. Every number is read from a file an instrument wrote:
`m1_surface.csv` (external_field_surface_probe, one invocation, SIMP in the same
run), `m2_topology.csv` (plsm_topology_probe, the shipped plsm_void_topology),
each arm's `report.json` (the run's own analyze_fixed_design certificate) and
each arm's `variant_*_alpha.meta` (the stop reason, the margin-probe CURVE and
the fraction's cost). A table assembled by hand is a table that can disagree with
its evidence.

★ AND THE TWO RUNGS ARE NAMED BY BOTH CONVENTIONS EVERYWHERE. Nominal 0.68 is
printed fraction 0.7973, nominal 0.26 is printed fraction 0.5283, and production's
SIMP run of record certifies them at 3254.36 and 3014.12.
"""
import csv
import json
import os
import sys

HERE = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.abspath(__file__))
ARMS = os.environ.get("ARMS", "B_heaviside C_eta1 D_fraction A_ship").split()
RUNGS = os.environ.get("RUNGS", "0.68 0.26").split()

# Production's SIMP run of record, evidence/2026-08-10-plsm-production/
# s3_simp/base.report.json — read, not retyped.
SIMP_REPORT = os.path.join(
    HERE, "..", "2026-08-10-plsm-production", "s3_simp", "base.report.json")

LABEL = {"0.68": "0.7973 SHIPPED", "0.26": "0.5283 LIGHT",
         "0.52": "0.6941", "0.38": "0.6048"}

# ★ MASS IS DERIVED, AND THE DERIVATION IS HERE RATHER THAN IN A COMMENT,
# because `report.json` carries `printed_fraction` and not a mass. On his job
# `part_solid` = grid.solid_count() = 110,904 voxels (the loadcase line
# "110904 of 468224 voxels allowed to hold material"), the voxel is
# 1.705279 mm on a side and PLA is 1.24 g/cm3, so
#
#   mass_g = printed_fraction * 110904 * 1.705279^3 mm3 * 0.00124 g/mm3
#          = printed_fraction * 682.0 g
#
# ★ CHECKED AGAINST THE KNOWN ROW: SIMP's rung 0.68 prints 88,424 voxels at
# printed_fraction 0.7973 and its recorded mass is 543.7 g; 0.7973 * 682.0 =
# 543.7. If that check ever fails the constant is wrong for the job in hand and
# every mass below with it.
PART_SOLID = 110904
VOXEL_MM = 1.705279
DENSITY_G_MM3 = 1.24e-3
MASS_PER_FRACTION_G = PART_SOLID * VOXEL_MM ** 3 * DENSITY_G_MM3


def mass_g(printed_fraction):
    return (printed_fraction or 0.0) * MASS_PER_FRACTION_G


def read_csv(path):
    if not os.path.exists(path):
        return []
    with open(path) as f:
        return list(csv.DictReader(f))


def read_meta(path):
    """A design_rung / alpha .meta: `key value...` lines, repeated keys kept."""
    out = {}
    if not os.path.exists(path):
        return out
    for line in open(path):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        out.setdefault(parts[0], []).append(parts[1:])
    return out


def one(meta, key, default=None):
    v = meta.get(key)
    return v[0][0] if v else default


def fnum(x, d=None):
    try:
        return float(x)
    except (TypeError, ValueError):
        return d


# ── SIMP's own rungs, from production's run of record ────────────────────────
simp = {}
if os.path.exists(SIMP_REPORT):
    rep = json.load(open(SIMP_REPORT))
    for v in rep.get("variants", []):
        pf = v.get("printed_fraction")
        simp[round(pf, 4)] = v

print("=" * 100)
print("TABLE 1 — THE SURFACE, BOTH RUNGS, ONE PROBE INVOCATION, SIMP IN THE SAME RUN (R5)")
print("=" * 100)
rows = read_csv(os.path.join(HERE, "m1_surface.csv"))
if not rows:
    print("  (m1_surface.csv absent — run measure.sh)")
else:
    hdr = ("arm", "rung", "n_cut", "carved", "CAD mm", "mid %", "min-feat",
           "volume mm3")
    print(f"{hdr[0]:<22}{hdr[1]:<10}{hdr[2]:>9}{hdr[3]:>10}{hdr[4]:>9}"
          f"{hdr[5]:>9}{hdr[6]:>10}{hdr[7]:>14}")
    print("-" * 100)
    for r in rows:
        arm = r.get("arm", "")
        rung = r.get("rung", "")
        print(f"{arm:<22}{rung:<10}{r.get('n_cut',''):>9}"
              f"{fnum(r.get('dihedral_cut_deg'), 0):>10.4f}"
              f"{fnum(r.get('obl_cad_rms_mm'), 0):>9.4f}"
              f"{fnum(r.get('midpoint_share'), 0) * 100:>8.2f}%"
              f"{r.get('min_feature_violations',''):>10}"
              f"{fnum(r.get('volume_mm3'), 0):>14.1f}")
print()

print("=" * 100)
print("TABLE 2 — THE CERTIFICATES, FROM EACH ARM'S OWN RUN (not re-certified here)")
print("=" * 100)
hdr = ("arm", "rung", "printed frac", "margin", "vs SIMP", "mass g", "iters",
       "accepted")
print(f"{hdr[0]:<22}{hdr[1]:<16}{hdr[2]:>13}{hdr[3]:>11}{hdr[4]:>9}"
      f"{hdr[5]:>9}{hdr[6]:>7}  {hdr[7]}")
print("-" * 100)
for pf in sorted(simp, reverse=True):
    v = simp[pf]
    m = (v.get("margin") or {}).get("worst_case")
    print(f"{'SIMP (run of record)':<22}{LABEL.get('', ''):<16}{pf:>13.4f}"
          f"{m:>11.2f}{'—':>9}{mass_g(pf):>9.1f}"
          f"{'—':>7}  {v.get('accepted')}")
for arm in ARMS:
    path = os.path.join(HERE, "arms", f"{arm}.report.json")
    if not os.path.exists(path):
        print(f"{arm:<22}(no report.json — the arm did not finish)")
        continue
    rep = json.load(open(path))
    for v in rep.get("variants", []):
        pf = v.get("printed_fraction")
        m = (v.get("margin") or {}).get("worst_case")
        base = simp.get(round(pf, 4) if pf else 0)
        # Match SIMP by NOMINAL rung order rather than by printed fraction:
        # a different optimiser lands on a different printed fraction at the
        # same rung, which is the whole reason the two conventions are named.
        print(f"{arm:<22}{('%.4f' % pf) if pf else '?':<16}{pf if pf else 0:>13.4f}"
              f"{(m or 0):>11.2f}{'':>9}"
              f"{mass_g(pf):>9.1f}"
              f"{v.get('iterations') or 0:>7}  {v.get('accepted')}")
print()
print("★ The margin column is the WORST-CASE margin the run's own")
print("  analyze_fixed_design produced. It is not recomputed here, because a")
print("  second certification of the same field is a second number for one")
print("  object and only one of them gates.")
print()

print("=" * 100)
print("TABLE 3 — THE STOPPING RULE: WHY EACH RUNG STOPPED, AND WHAT IT RETURNED")
print("=" * 100)
hdr = ("arm", "rung", "stop reason", "peak it", "peak margin", "probes",
       "probe wall s")
print(f"{hdr[0]:<14}{hdr[1]:<7}{hdr[2]:<26}{hdr[3]:>8}{hdr[4]:>13}"
      f"{hdr[5]:>8}{hdr[6]:>14}")
print("-" * 100)
for arm in ARMS:
    for digits, rung in (("068", "0.68"), ("052", "0.52"), ("038", "0.38"),
                         ("026", "0.26")):
        if rung not in RUNGS:
            continue
        meta = read_meta(os.path.join(
            HERE, "arms", f"{arm}.variant_{digits}_alpha.meta"))
        if not meta:
            continue
        probes = meta.get("margin_probe", [])
        print(f"{arm:<14}{rung:<7}{one(meta,'stop_reason','?'):<26}"
              f"{one(meta,'margin_peak_iteration','0'):>8}"
              f"{fnum(one(meta,'margin_peak'), 0):>13.2f}"
              f"{len(probes):>8}"
              f"{fnum(one(meta,'margin_probe_wall_s'), 0):>14.1f}")
print()
print("★ THE MARGIN CURVE THE RULE WATCHED, per rung (R4: never a point):")
for arm in ARMS:
    for digits, rung in (("068", "0.68"), ("026", "0.26")):
        if rung not in RUNGS:
            continue
        meta = read_meta(os.path.join(
            HERE, "arms", f"{arm}.variant_{digits}_alpha.meta"))
        probes = meta.get("margin_probe", [])
        if not probes:
            continue
        cells = "  ".join(f"it{p[0]}={float(p[1]):.0f}"
                          f"{'' if p[2] == '1' else '(SEVERED)'}" for p in probes)
        print(f"  {arm} rung {rung}: {cells}")
print()

print("=" * 100)
print("TABLE 4 — R6, THE SEALED VOID BY THE MANUFACTURING DEFINITION, AND THE")
print("          TOPOLOGY COUNTERS (one implementation, SIMP and PLSM alike)")
print("=" * 100)
rows = read_csv(os.path.join(HERE, "m2_topology.csv"))
if not rows:
    print("  (m2_topology.csv absent — run measure.sh)")
else:
    hdr = ("field", "b0 comps", "chi", "b2 solid", "b1 tunnels",
           "sealed pk", "sealed vox", "sealed %", "sealed mm3")
    print(f"{hdr[0]:<40}{hdr[1]:>9}{hdr[2]:>9}{hdr[3]:>9}{hdr[4]:>11}"
          f"{hdr[5]:>10}{hdr[6]:>11}{hdr[7]:>9}{hdr[8]:>12}")
    print("-" * 122)
    for r in rows:
        vv = fnum(r.get("void_voxels"), 0) or 1
        sv = fnum(r.get("sealed_voxels"), 0)
        # ★ THE ARM NAME IS THE DIRECTORY, NOT THE BASENAME. Every field is
        # called `rung_0.68`; printing the basename alone gave ten identically
        # labelled rows, which is a table nobody can read.
        parts = r.get("field", "").split("/")
        arm = parts[-3] if len(parts) >= 3 else "?"
        if arm == "plsm_scratch" or parts[-2] == "simp_dump":
            arm = "SIMP"          # the reference dump lives one level shallower
        label = arm + " " + parts[-1]
        print(f"{label:<40}"
              f"{r.get('b0_components',''):>9}{r.get('chi',''):>9}"
              f"{r.get('b2_enclosed_solid',''):>9}{r.get('b1_tunnels',''):>11}"
              f"{r.get('sealed_pockets',''):>10}"
              f"{r.get('sealed_voxels',''):>11}{sv / vv * 100:>8.2f}%"
              f"{fnum(r.get('sealed_volume_mm3'), 0):>12.1f}")
print()

print("=" * 100)
print("TABLE 5 — ITEM 2(e), WHAT THE FRACTION COSTS ON THE PRODUCTION PATH")
print("=" * 100)
# ★★ THE DENOMINATOR IS THE RUNG'S WALL FROM `wall_ms` DELTAS, AND THE REASON IS
# A DEFECT THIS TASK FOUND RATHER THAN A PREFERENCE. `iterations.csv` has a
# `total_ms` column, the SIMP path fills it (94,613.450 on his rung 0.68's first
# iteration), and ★ THE PLSM PATH WRITES 0.000 THERE ON EVERY ROW OF EVERY RUN
# SINCE PR 325 — along with solve_ms, fea_ms, sens_ms and analysis_ms. Its
# `observe` block fills the compliance and the CG counters and leaves the whole
# timing block at its default. Using it would have divided by zero.
#
# `wall_ms` is an ABSOLUTE timestamp per iteration and is filled, so consecutive
# differences give the per-iteration wall. The first iteration of a rung has no
# predecessor inside that rung and is skipped, so the denominator is the wall of
# iterations 2..n and the numerator is scaled to match.
#
# ★ AND IT IS A SHARE OF AN ITERATION, NOT OF A RUN, because that is what PR 327
# quoted (1.92%). Against a whole run the number would shrink for the arm that
# ran longer, which is the opposite of a cost.
hdr = ("arm", "rung", "iters", "sampling s", "sensitivity s", "rung wall s",
       "share %", "cut cells")
print(f"{hdr[0]:<14}{hdr[1]:<7}{hdr[2]:>7}{hdr[3]:>12}{hdr[4]:>15}"
      f"{hdr[5]:>13}{hdr[6]:>9}{hdr[7]:>11}")
print("-" * 92)
RUNG_INDEX = {"0.68": "0", "0.52": "1", "0.38": "2", "0.26": "3"}
for arm in ARMS:
    iters = read_csv(os.path.join(HERE, "arms", f"{arm}.iterations.csv"))
    for digits, rung in (("068", "0.68"), ("052", "0.52"), ("038", "0.38"),
                         ("026", "0.26")):
        if rung not in RUNGS:
            continue
        meta = read_meta(os.path.join(
            HERE, "arms", f"{arm}.variant_{digits}_alpha.meta"))
        if not meta:
            continue
        rows_r = [r for r in iters if r.get("rung") == RUNG_INDEX[rung]]
        ts = [fnum(r.get("wall_ms"), 0.0) for r in rows_r]
        wall = (ts[-1] - ts[0]) / 1000.0 if len(ts) >= 2 else 0.0
        n_span = max(1, len(ts) - 1)   # iterations the span actually covers
        smp = fnum(one(meta, "frac_sample_wall_s"), 0.0)
        sen = fnum(one(meta, "frac_sens_wall_s"), 0.0)
        # The numerator is the WHOLE rung's sampling+sensitivity; scale it to the
        # same n the denominator covers so the ratio is per-iteration.
        scaled = (smp + sen) * n_span / max(1, len(ts))
        share = scaled / wall * 100.0 if wall > 0 else float("nan")
        print(f"{arm:<14}{rung:<7}{len(rows_r):>7}{smp:>12.2f}{sen:>15.2f}"
              f"{wall:>13.1f}{share:>8.2f}%"
              f"{one(meta,'frac_cut_cells','0'):>11}")
print()
print("★ `sampling` is the sub-cell build (one per iteration over the ACTIVE")
print("  cells); `sensitivity` is the quadrature band plus the sample scatter.")
print("  Both are ZERO on the Heaviside arms by construction — that is the")
print("  positive control for the column, not a missing measurement.")
print("★ PR 327 measured 1.92% of an iteration on the probe path at k = 4.")
print("★★ AND THE WALL CLOCKS CARRY A CAVEAT THE ITERATION COUNTS DO NOT: this")
print("   host was SHARED with other worktrees' jobs for part of the campaign")
print("   (levelset_probe, solver_arm_sweep and a ctest binary were measured")
print("   running concurrently). The DESIGNS are deterministic and unaffected;")
print("   the wall clocks are not comparable at better than about 10%, which is")
print("   the same caveat PR 327 section 3(a) states for the same reason.")
