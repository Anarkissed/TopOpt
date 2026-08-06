#!/usr/bin/env python3
"""R1 — THE FULL BEFORE/AFTER ON HIS OWN PART, RESOLUTION 128, ALL FOUR RUNGS.
(task 2026-08-06-arm-projection-and-void-check)

    ./r1_before_after.py <base-cli> <branch-cli> <out-dir>

THERE IS NO BYTE-IDENTITY CLAIM HERE AND THERE MUST NOT BE. Both defaults are
armed on purpose, so the default export path CHANGES. What this measures is the
change itself, on the part he actually runs:

    BEFORE = the MERGE-BASE binary (d9fe8f7), job document as-is.
             `output.project_cad_faces` and
             `lattice.require_lattice_void_reaches_exterior` are both ABSENT,
             which on that binary means BOTH OFF.
    AFTER  = the BRANCH binary, THE SAME job document, keys still ABSENT —
             which now means BOTH ON.

The two runs differ by the binary and by nothing else. That is deliberate: it is
exactly the experience of a user who updates and reruns the job they already
have, which is what "armed by default" does to him.

SUBJECT. His job DOCUMENT, captured verbatim during
2026-08-04-protect-freeze-vs-solidity: M2_verticalStand.step, resolution 128,
his anchor / load / face-protection selections and his lattice role regions
(8 include + 1 exclude in the captured copy). Same subject PR 305 measured, and
for the same reason: it is the one job in this repo that exercises BOTH features
at once — a real lattice for the void check AND a CAD B-rep for the projection.

THREE DEVIATIONS FROM THE CAPTURED DOCUMENT, all inherited from PR 305 §6 and
all restated rather than assumed:

  * the `grading` block is dropped for the UNIFORM 8 mm cell the brief
    describes. This also side-steps the cells-per-member floor, which leaves his
    graded job with almost nothing latticed (his own forecast: 8 of 8 include
    regions thinner than the 40 mm the floor needs);
  * `simp.max_iterations` IS NOT HONOURED in loadcase mode
    (run_job.cpp applies it only on the non-loadcase branch), so both runs go to
    the production ladder's own termination. Stated rather than quietly assumed:
    the designs measured here ARE the ladder's converged designs for this job;
  * his job says `"skin": "rim"`, set to `"none"` here. NOT a choice made by
    this task: on a voxel-silhouette part a non-"none" finish emits nothing and
    run_job REFUSES the run for that reason (the lattice-cell-fit-mode M4 bar,
    merged before this task started). That refusal would abort both runs before
    either default could be measured.

`skin` is the SAME in both arms, so it cannot be the source of any difference.
"""
import json, os, shutil, subprocess, sys, time

BASE = os.path.abspath(sys.argv[1])
BRANCH = os.path.abspath(sys.argv[2])
OUT = os.path.abspath(sys.argv[3] if len(sys.argv) > 3 else "r1_work")
REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
SRC = os.path.join(REPO, "evidence", "2026-08-04-protect-freeze-vs-solidity")

os.makedirs(OUT, exist_ok=True)
shutil.copy(os.path.join(SRC, "M2_verticalStand.step"), OUT)
his = json.load(open(os.path.join(SRC, "job_maintainer.json")))

j = json.loads(json.dumps(his))
j.pop("grading", None)                                # UNIFORM, per the brief
j["lattice"]["cell_mm"] = 8.0
j["lattice"]["strut_radius_mm"] = 1.2                 # rho ~0.41, inside the band
j["lattice"].pop("min_extrudable_width_mm", None)
j["lattice"]["skin"] = "none"                         # see the docstring
# NEITHER KEY IS WRITTEN. That is the whole point: the document is what it
# always was, and the binary decides what it means.
assert "project_cad_faces" not in j["output"]
assert "require_lattice_void_reaches_exterior" not in j["lattice"]
json.dump(j, open(os.path.join(OUT, "job.json"), "w"), indent=1)

inc = sum(1 for r in j["lattice"]["regions"] if r["role"] == "include")
exc = sum(1 for r in j["lattice"]["regions"] if r["role"] == "exclude")
print(f"subject: {j['model']}, resolution {j['resolution']}, "
      f"{inc} include + {exc} exclude lattice regions, uniform 8.0 mm cell, "
      f"skin none")
print(f"BEFORE binary: {BASE}")
print(f"AFTER  binary: {BRANCH}")
print("neither key is present in the job document — the binary's default decides")
print(flush=True)

for arm, cli in (("before", BASE), ("after", BRANCH)):
    sub = os.path.join(OUT, arm)
    shutil.rmtree(sub, ignore_errors=True)
    t0 = time.time()
    r = subprocess.run([cli, "run", "job.json", "--out", arm], cwd=OUT,
                       capture_output=True, text=True)
    dt = time.time() - t0
    open(os.path.join(OUT, arm + ".log"), "w").write(r.stdout + r.stderr)
    print(f"{arm}: exit={r.returncode} wall={dt:.1f}s", flush=True)
