#!/usr/bin/env python3
"""S2e — DOES ANYTHING IN THIS REPO NOW REFUSE THAT DID NOT BEFORE?
(task 2026-08-06-arm-projection-and-void-check)

    ./s2e_refusal_sweep.py <base-cli> <branch-cli> <out-dir> [max-resolution]

"None found" is only worth anything if the search is stated, so this is the
search: EVERY job document committed anywhere in this repo is run TWICE — once
with the MERGE-BASE binary (both defaults OFF) and once with the BRANCH binary
(both defaults ON) — and the two outcomes are compared.

Running both arms is what makes the answer attributable. A job that fails on the
branch tells you nothing on its own: this repo already contains recipes that
refuse on `main` for rules merged before this task (the lattice-cell-fit-mode M4
bar refuses a non-"none" `skin` that emits no geometry, which several captured
jobs trip). Only a job that SUCCEEDS on base and FAILS on branch is caused by
these default flips.

WHAT IS SEARCHED: every *.json under core/tests, docs, evidence, tools and app
that parses as a job document (has both "mode" and "model"), whose model file
sits beside it, and whose declared resolution is at or below the cap. Anything
skipped is PRINTED with its reason — a sweep that quietly drops rows reads as
"covered everything" when it did not.

The void check's own verdict is read out of `run_info.lattice_export.void_escape`
rather than inferred from the exit code, so a job that refuses for an unrelated
reason is never miscounted as a void refusal.
"""
import json, os, shutil, subprocess, sys, glob

BASE = os.path.abspath(sys.argv[1])
BRANCH = os.path.abspath(sys.argv[2])
OUT = os.path.abspath(sys.argv[3] if len(sys.argv) > 3 else "s2e_work")
MAXRES = int(sys.argv[4]) if len(sys.argv) > 4 else 48
REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
MATERIALS = os.path.join(REPO, "core", "src", "materials", "materials.json")
RULES = os.path.join(REPO, "core", "src", "settings", "rules.json")
assert os.path.exists(MATERIALS), MATERIALS
assert os.path.exists(RULES), RULES

os.makedirs(OUT, exist_ok=True)

# Many committed job documents name a model that lives elsewhere in the repo
# (`l-bracket.step` beside the demo fixture, a part captured in another evidence
# directory). Resolving those REPO-WIDE rather than only beside the job takes the
# sweep from 59 runnable to nearly all of them, which matters: a "none found"
# over a third of the corpus is a much weaker statement than one over all of it.
# First match by basename wins, and the resolved path is printed per row.
_index = {}
for _root in ("core/tests", "docs", "evidence", "tools", "app"):
    for _p in sorted(glob.glob(os.path.join(REPO, _root, "**", "*"), recursive=True)):
        _b = os.path.basename(_p).lower()
        if _b.endswith((".step", ".stp", ".stl", ".3mf")) and os.path.isfile(_p):
            _index.setdefault(os.path.basename(_p), _p)


def resolve_model(jobpath, name):
    beside = os.path.join(os.path.dirname(jobpath), os.path.basename(name))
    if os.path.exists(beside):
        return beside
    return _index.get(os.path.basename(name))


# ── discover ────────────────────────────────────────────────────────────────
found, skipped = [], []
for root in ("core/tests", "docs", "evidence", "tools", "app"):
    for p in sorted(glob.glob(os.path.join(REPO, root, "**", "*.json"),
                              recursive=True)):
        if ".build" in p or "node_modules" in p:
            continue
        try:
            j = json.load(open(p))
        except Exception:
            continue
        if not (isinstance(j, dict) and "mode" in j and "model" in j):
            continue
        rel = os.path.relpath(p, REPO)
        model = resolve_model(p, j["model"])
        if model is None:
            skipped.append((rel, f"model file {os.path.basename(j['model'])} is "
                                 f"nowhere in the repo"))
            continue
        res = j.get("resolution") or 0
        if res > MAXRES:
            skipped.append((rel, f"resolution {res} is above the {MAXRES} cap "
                                 f"for this sweep"))
            continue
        found.append((rel, p, j, model))

print(f"searched: core/tests, docs, evidence, tools, app — every *.json that "
      f"parses as a job document (has \"mode\" and \"model\")")
print(f"runnable here: {len(found)}    skipped: {len(skipped)}    "
      f"resolution cap: {MAXRES}")
print()
if skipped:
    print("SKIPPED, and why — nothing is dropped silently:")
    for rel, why in skipped:
        print(f"  {rel}\n      {why}")
    print()


def run(cli, jobpath, model, tag):
    d = os.path.join(OUT, tag)
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d, exist_ok=True)
    j = json.load(open(jobpath))
    # Copy the resolved model in under the name the job asks for, so a job whose
    # model lives elsewhere in the repo runs unmodified in every other respect.
    shutil.copy(model, os.path.join(d, os.path.basename(j["model"])))
    shutil.copy(jobpath, os.path.join(d, "job.json"))
    cmd = [cli, "run", "job.json", "--out", "out"]
    if os.path.exists(MATERIALS):
        cmd += ["--materials", MATERIALS]
    if os.path.exists(RULES):
        cmd += ["--rules", RULES]
    r = subprocess.run(cmd, cwd=d, capture_output=True, text=True, timeout=3600)
    log = r.stdout + r.stderr
    open(os.path.join(d, "run.log"), "w").write(log)
    ve = None
    ri = os.path.join(d, "out", "run_info.json")
    if os.path.exists(ri):
        try:
            ve = (json.load(open(ri)).get("lattice_export") or {}).get("void_escape")
        except Exception:
            ve = None
    return r.returncode, log, ve


rows, regressions = [], []
for i, (rel, p, j, model) in enumerate(found):
    rc_b, log_b, _ = run(BASE, p, model, f"case{i:03d}_base")
    rc_x, log_x, ve = run(BRANCH, p, model, f"case{i:03d}_branch")
    sealed = bool(ve.get("sealed")) if isinstance(ve, dict) else False
    void_refused = sealed and (rc_x != 0 or "does not reach the exterior" in log_x)
    newly = (rc_b == 0 and rc_x != 0)
    rows.append((rel, rc_b, rc_x, bool(ve), sealed, void_refused, newly))
    if newly:
        regressions.append((rel, log_x[-1400:]))
    print(f"  {rel}\n      base exit={rc_b}  branch exit={rc_x}  "
          f"void_escape={'yes' if ve else 'no'}  sealed={sealed}"
          f"{'   *** NEWLY REFUSED ***' if newly else ''}", flush=True)

print()
print("=" * 78)
print(f"job documents run in both arms : {len(rows)}")
print(f"succeeded on BOTH              : {sum(1 for r in rows if r[1] == 0 and r[2] == 0)}")
print(f"failed on BOTH (pre-existing)  : {sum(1 for r in rows if r[1] != 0 and r[2] != 0)}")
print(f"carried a void_escape record   : {sum(1 for r in rows if r[3])}")
print(f"SEALED (would refuse)          : {sum(1 for r in rows if r[4])}")
print(f"★ NEWLY REFUSED BY THE BRANCH  : {len(regressions)}")
print("=" * 78)
for rel, tail in regressions:
    print(f"\n--- {rel} ---\n{tail}")
sys.exit(1 if regressions else 0)
