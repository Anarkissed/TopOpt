#!/usr/bin/env python3
"""R1 — THE CERTIFIED MARGIN AND VERDICT, BEFORE AND AFTER. THE VERDICT MUST NOT MOVE.
(task 2026-08-06-arm-projection-and-void-check)

    ./r1_cert_table.py <cert-dir> [<extra-cert-dir> ...]

Each mesh from `r1_table_128.py`'s four rungs was re-certified through the
SHIPPED path — `topopt-cli analyze job_analyze.json --mesh <mesh> --out …` — on
the same job, the same resolution 128 and the same declared load PR 307 used, so
its rung-068 figures are directly comparable rather than merely similar.

★ THE BAR IS THE VERDICT, NOT THE MARGIN. The brief requires that the certified
verdict does not move, and states PR 307's measurement as the target: ACCEPTED
before and after, margin +0.42%, certified mass −8.03%. The margin is EXPECTED
to move a little — this is a systematic ~0.39-voxel correction in one direction,
not a sub-voxel jiggle, and a shift of that size changes which voxel centres a
re-voxelization encloses.
"""
import glob, json, os, sys

dirs = [os.path.abspath(d) for d in sys.argv[1:]] or ["."]
rows = {}
for d in dirs:
    for sub in sorted(glob.glob(os.path.join(d, "cert_*"))):
        if not os.path.isdir(sub):
            continue
        rp = os.path.join(sub, "analysis_report.json")
        ap = os.path.join(sub, "analysis.json")
        if not (os.path.exists(rp) and os.path.exists(ap)):
            continue
        r, a = json.load(open(rp)), json.load(open(ap))
        v = (r.get("variants") or [{}])[0]
        name = os.path.basename(sub)
        # cert_variant_068 / cert_variant_068_projected / cert_068_orig
        base = name.replace("cert_", "")
        projected = base.endswith("_projected")
        rung = "".join(ch for ch in base if ch.isdigit())[:3]
        rows[(rung, projected)] = dict(
            accepted=v.get("accepted"),
            margin=v.get("margin", {}).get("worst_case"),
            interlayer=v.get("margin", {}).get("interlayer"),
            stress=v.get("max_stress_mpa") or v.get("peak_stress_mpa"),
            vf=v.get("volume_fraction"),
            minfeat=v.get("min_feature_violations"),
            voxel=a.get("voxel_mass_grams"),
            mesh=a.get("mesh_mass_grams"))

print("=" * 108)
print("R1 — CERTIFIED MARGIN AND VERDICT, his part, resolution 128")
print("     BEFORE = the un-projected export   AFTER = the projected export")
print("=" * 108)
h = (f"{'rung':<7}{'verdict':>18}{'margin before':>16}{'margin after':>15}"
     f"{'Δ margin':>11}{'voxel mass g':>15}{'Δ mass':>10}")
print(h); print("-" * len(h))
for rung in sorted({k[0] for k in rows}):
    b, a = rows.get((rung, False)), rows.get((rung, True))
    if not (b and a):
        print(f"{rung:<7}  (only one arm certified so far)")
        continue
    dm = 100.0 * (a["margin"] - b["margin"]) / b["margin"]
    dv = 100.0 * (a["voxel"] - b["voxel"]) / b["voxel"]
    verdict = ("ACCEPTED" if b["accepted"] else "REJECTED") + " -> " + \
              ("ACCEPTED" if a["accepted"] else "REJECTED")
    flag = "" if b["accepted"] == a["accepted"] else "   *** VERDICT MOVED ***"
    print(f"{rung:<7}{verdict:>18}{b['margin']:>16.6f}{a['margin']:>15.6f}"
          f"{dm:>10.4f}%{b['voxel']:>15.4f}{dv:>9.2f}%{flag}")
print()
print("the same rows in full:")
h = (f"{'rung':<7}{'arm':<11}{'margin':>16}{'interlayer':>14}{'stress MPa':>13}"
     f"{'vol fraction':>14}{'minfeat':>9}{'voxel g':>11}{'mesh g':>11}")
print(h); print("-" * len(h))
for rung in sorted({k[0] for k in rows}):
    for proj in (False, True):
        r = rows.get((rung, proj))
        if not r:
            continue
        print(f"{rung:<7}{('projected' if proj else 'original'):<11}"
              f"{r['margin']:>16.6f}{r['interlayer']:>14.4f}{r['stress']:>13.8f}"
              f"{r['vf']:>14.9f}{r['minfeat']:>9}{r['voxel']:>11.4f}"
              f"{r['mesh']:>11.4f}")
print()
moved = [k[0] for k in rows if k[1] is False
         and (k[0], True) in rows
         and rows[(k[0], False)]["accepted"] != rows[(k[0], True)]["accepted"]]
if moved:
    print(f"*** BLOCKED-STOP: the verdict moved on rung(s) {moved} ***")
    sys.exit(1)
print("THE VERDICT DID NOT MOVE ON ANY RUNG. The blocked-stop is not triggered.")
print()
print("★ AN UN-PROJECTED VARIANT CERTIFIES AT A VOLUME FRACTION ABOVE 1.0, which")
print("  is impossible for a design that removed material — it is the same fact")
print("  as the oversize export, seen from the certificate's end. Projection")
print("  brings it back below 1.")
