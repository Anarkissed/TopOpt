#!/usr/bin/env python3
"""c_octet_tensor_assemble.py SWEEP_DIR PR246_CSV: re-judge the chunked octet sweep the way ONE process would.
Each chunk ran one density, so the probe's reference curve held one point and interp_curve
clamped to it: its drift compared E100 at the row's rho with E100 at the reference's OWN rho
(the density-landing artefact the method exists to remove). Here every chunk's reference point
of a set (vpc96 for HIGH, vpc128 for LOW) forms the curve, and each row's E100 is compared with
it at the row's own rho, exactly tensor_library_nine_probe's interp_curve. Validated := |drift|
< 2.4 % AND vox/strut >= 6 AND converged (the probe's rule, unchanged).

Reproduce (from the repo root; SWEEP_DIR holds the 15 chunks' octet_sweep.csv as low|high/vf_*.csv):
  python3 docs/handoffs/evidence/2026-11-01-lattice-types-k1/c_octet_tensor_assemble.py \
      docs/handoffs/evidence/2026-11-01-lattice-types-k1/c_octet_tensor_sweep \
      evidence/2026-07-29-tensor-library-nine/csv/octet_sweep.csv
Each chunk was `tensor_library_nine_probe sweep octet` at one density (vf_<target>): LOW at
vpc 96 vs 128, HIGH at vpc 64 vs 96."""
import csv, glob, os, sys
oct_dir, pr246 = sys.argv[1], sys.argv[2]

def interp(curve, q):
    if q <= curve[0][0]: return curve[0][1]
    if q >= curve[-1][0]: return curve[-1][1]
    a = 0
    while a + 1 < len(curve) and curve[a + 1][0] < q: a += 1
    (x0, y0), (x1, y1) = curve[a], curve[a + 1]
    return y0 + (q - x0) / (x1 - x0) * (y1 - y0)

out = []
for s in ("low", "high"):
    rows = [r for f in sorted(glob.glob(os.path.join(oct_dir, s, "vf_*.csv")) or
                         glob.glob(os.path.join(oct_dir, s, "vf_*", "octet_sweep.csv")))
            for r in csv.DictReader(open(f))]
    curve = sorted((float(r["rho_ref"]), float(r["E100_ref_interp_MPa"])) for r in rows)
    print("%s: vpc %s vs %s, reference curve of %d points" % (s.upper(), rows[0]["vpc_row"], rows[0]["vpc_ref"], len(curve)))
    for r in sorted(rows, key=lambda r: float(r["rho_row"])):
        rho, e = float(r["rho_row"]), float(r["E100_row_MPa"])
        d = 100 * (e - interp(curve, rho)) / interp(curve, rho)
        ok = abs(d) < 2.4 and float(r["vox_per_strut"]) >= 6 and r["converged"] == "1"
        print("  rho %.5f  vox/strut %6.3f  E100 %9.4f  drift %+6.2f %% (chunk said %+6.2f)  %s"
              % (rho, float(r["vox_per_strut"]), e, d, float(r["drift_pct"]), "VALIDATED" if ok else "not validated"))
        out.append((rho, r, ok, s, d))
for r in csv.DictReader(open(pr246)):
    if r["validated"] == "1":
        out.append((float(r["rho_row"]), r, True, "pr246", float(r["drift_pct"])))
print("\nTHE FULL-OCTET TABLE (validated rows, ascending rho; Row{rho, C11, C12, C44})")
for rho, r, ok, s, d in sorted(out, key=lambda t: t[0]):
    if ok:
        print("    {%.5f, %.4f, %.4f, %.4f, true},  // %s vpc%s vs %s, drift %+.2f %%"
              % (rho, float(r["C11"]), float(r["C12"]), float(r["C44_xy"]), s, r["vpc_row"], r["vpc_ref"], d))
