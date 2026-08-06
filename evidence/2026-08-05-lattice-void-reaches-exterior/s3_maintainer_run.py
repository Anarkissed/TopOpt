#!/usr/bin/env python3
"""S3 — WOULD HIS OWN RUN HAVE BEEN REFUSED?
(task 2026-08-05-lattice-void-reaches-exterior)

    ./s3_maintainer_run.py <cli> <out-dir> [resolutions...]

WHAT THIS IS, EXACTLY, so the answer is not read as more than it is.

The brief names his overnight run by DESIGN FINGERPRINT (b3abcf880554,
resolution 128, uniform, 8 mm cell, seven include regions). That run's
`design.bin` is not in this repo, and the rule is evaluated on a DESIGN — so the
literal run cannot be re-decided here.

What this repo DOES own is his job DOCUMENT, captured verbatim during
2026-08-04-protect-freeze-vs-solidity: M2_verticalStand.step, resolution 128,
his anchor/load/protection faces and his lattice ROLE REGIONS (8 include + 1
exclude in the captured copy — the brief says seven; the difference is which
capture, and it is stated rather than smoothed over). This script runs THAT
document with the grading block replaced by the UNIFORM 8 mm cell the brief
describes, and the rule ARMED, and reports the verdict per rung.

TWO DEVIATIONS, both stated:
  * the grading block is dropped for the uniform cell, which is what the brief
    asks for and also side-steps the cells-per-member floor that leaves his
    graded job with almost nothing latticed (his own forecast: 8 of 8 include
    regions thinner than the 40 mm the floor needs);
  * an iteration cap is written into the job, and IT IS NOT HONOURED — in
    LOADCASE mode run_job.cpp:5120 applies `simp.max_iterations` only on the
    non-loadcase branch, so his job runs the full production ladder to its own
    termination. Stated rather than quietly assumed: the designs measured here
    ARE the ladder's own converged designs for the job as given, and the run
    costs what it costs.

Run it at several resolutions to see whether the verdict is resolution-stable.
"""
import json, os, shutil, subprocess, sys, time

CLI = sys.argv[1] if len(sys.argv) > 1 else "topopt-cli"
OUT = os.path.abspath(sys.argv[2] if len(sys.argv) > 2 else "s3_maintainer")
RESOLUTIONS = [int(x) for x in sys.argv[3:]] or [64, 128]
REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
SRC = os.path.join(REPO, "evidence", "2026-08-04-protect-freeze-vs-solidity")

os.makedirs(OUT, exist_ok=True)
shutil.copy(os.path.join(SRC, "M2_verticalStand.step"), OUT)
his = json.load(open(os.path.join(SRC, "job_maintainer.json")))

inc = sum(1 for r in his["lattice"]["regions"] if r["role"] == "include")
exc = sum(1 for r in his["lattice"]["regions"] if r["role"] == "exclude")
print(f"his captured job: {his['model']}, resolution {his['resolution']}, "
      f"{inc} include + {exc} exclude lattice regions, "
      f"grading {his.get('grading', {}).get('cell_mode')}")
print()

ITERS = int(os.environ.get("ITERS", "6"))
rows = []
for res in RESOLUTIONS:
    j = json.loads(json.dumps(his))
    j["resolution"] = res
    j.pop("grading", None)                       # UNIFORM, per the brief
    j["lattice"]["cell_mm"] = 8.0
    j["lattice"]["strut_radius_mm"] = 1.2        # rho ~0.41, inside the band
    j["lattice"].pop("min_extrudable_width_mm", None)
    j["lattice"]["require_lattice_void_reaches_exterior"] = True
    j["simp"] = {"max_iterations": ITERS}
    sub = f"his_{res}"
    shutil.rmtree(os.path.join(OUT, sub), ignore_errors=True)
    json.dump(j, open(os.path.join(OUT, sub + ".json"), "w"), indent=1)
    t0 = time.time()
    r = subprocess.run([CLI, "run", sub + ".json", "--out", sub], cwd=OUT,
                       capture_output=True, text=True)
    dt = time.time() - t0
    open(os.path.join(OUT, sub + ".log"), "w").write(r.stdout + r.stderr)
    ri_path = os.path.join(OUT, sub, "run_info.json")
    if r.returncode != 0 or not os.path.exists(ri_path):
        print(f"res {res}: RUN FAILED after {dt:.0f} s — see {sub}.log")
        tail = (r.stderr or "").strip().splitlines()[-3:]
        for t in tail:
            print("   " + t[:160])
        rows.append((res, "RUN FAILED", None, dt))
        continue
    ve = (json.load(open(ri_path)).get("lattice_export") or {}).get("void_escape")
    rows.append((res, "REFUSE" if (ve and ve["sealed"]) else "pass", ve, dt))
    # Per-rung detail: which rungs were refused, and the receipts of those that
    # were not.
    # NOT "{ITERS} iterations per rung": the cap in the job document is IGNORED
    # in loadcase mode (run_job.cpp:5120 applies it only on the non-loadcase
    # branch), so this is the production ladder's own termination.
    print(f"--- resolution {res} ({dt:.0f} s wall; the job's iteration cap is "
          f"IGNORED in loadcase mode, so this is the production ladder's own "
          f"termination) ---")
    if ve is None:
        print("   no lattice_export record: this job latticed nothing at all")
        continue
    print(f"   run-level: sealed={ve['sealed']} sealed_variants="
          f"{ve['sealed_variants']} sealed_cells={ve['sealed_cells']} "
          f"sealed_voxels={ve['sealed_voxels']} "
          f"sealed_volume_mm3={ve['sealed_volume_mm3']:.1f}")
    print(f"   open lattice: cells={ve['latticed_cells']} "
          f"voxels_reached={ve['latticed_voxels_reached']} "
          f"escape_depth={ve['escape_depth_voxels']} "
          f"faces={ve['escape_faces'] or '-'} "
          f"reachable_void_mm3={ve['reachable_void_volume_mm3']:.0f}")
    print(f"   pre-existing enclosed voids holding NO lattice (reported, never "
          f"refused): {ve['sealed_pockets_without_lattice']}")
    print(f"   check cost: {ve['wall_seconds']:.4f} s over {ve['bfs_visits']} "
          f"voxel pushes")
    for f in sorted(os.listdir(os.path.join(OUT, sub))):
        if not f.endswith("_lattice.report.json"):
            continue
        v = json.load(open(os.path.join(OUT, sub, f)))["void_escape"]
        print(f"     {f}: sealed={v['sealed']} latticed={v['latticed_voxels']} "
              f"reached={v['latticed_voxels_reached']} "
              f"cells={v['latticed_cells']} depth={v['escape_depth_voxels']} "
              f"faces={v['escape_faces']}")
    print()

print("SUMMARY")
for res, verdict, ve, dt in rows:
    print(f"  resolution {res:>4}: {verdict}"
          + (f"  ({ve['sealed_cells']} sealed cells, "
             f"{ve['sealed_volume_mm3']:.1f} mm^3)" if ve and ve["sealed"] else "")
          + f"   [{dt:.0f} s]")
