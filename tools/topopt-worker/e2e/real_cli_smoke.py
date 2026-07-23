#!/usr/bin/env python3
"""real_cli_smoke.py — schema-drift guard (handoff 129, item 3).

Feeds a REPRESENTATIVE job.json — the exact shape RemoteRunner.buildJobJSON emits
(model, material, mode, resolution, output, design_box/keep_outs, and a full loads
block: anchors, groups, clearances, face_protections, infill, build_dir) — to the
ACTUAL topopt-cli binary and asserts the CLI ACCEPTS the schema. This is the one
place app→worker→CLI schema drift is caught in the worker suite BEFORE it can reach
a device: the CLI's job schema is strict (`reject_unknown_keys`), so a new app key
the CLI doesn't know, or a dropped required key, fails HERE.

SKIP-IF-ABSENT: the binary is found via $TOPOPT_REAL_CLI, else $TOPOPT_CLI, else a
few common build paths. When none is present (e.g. a checkout with no C++ build)
the test SKIPS cleanly (exit 0) — it is a guard, not a build gate.

How it asserts "schema accepted" without a full solve: the CLI parses job.json
(schema) BEFORE it imports the model. We hand it a throwaway model path, so the run
fails FAST at model import — AFTER the schema passed. We then assert the output
carries no schema-rejection marker ("unknown key", "missing required key", "job.json:
...", "is not allowed"). As a paired positive control, the SAME job with a stray
`project` key must be REJECTED — proving the strip in the worker (item 2) is load-
bearing, not decorative.

Run:  python3 real_cli_smoke.py         (exit 0 = pass or skip; 1 = drift)
"""

import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))

# Markers the CLI prints ONLY for a schema/parse rejection (job.cpp: every schema_fail
# is a JobError prefixed "job.json: ...", and the JSON parser throws "job.json parse
# error ..."). A later model-import failure ("cannot open", "watertight", OCCT noise)
# carries none of these — that means the schema was accepted, which is what we want.
# Kept specific to avoid false positives on unrelated error prose.
SCHEMA_MARKERS = ["unknown key", "missing required key", "is not allowed",
                  "job.json:", "job.json parse error"]


def find_cli():
    for env in ("TOPOPT_REAL_CLI", "TOPOPT_CLI"):
        p = os.environ.get(env)
        if p and os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    candidates = [
        os.path.join(REPO, "core", "build", "src", "cli", "topopt-cli"),
        os.path.join(REPO, "core", "build", "topopt-cli"),
        os.path.join(REPO, "core", "cmake-build-debug", "src", "cli", "topopt-cli"),
        os.path.join(REPO, "core", "cmake-build-release", "src", "cli", "topopt-cli"),
    ]
    for c in candidates:
        if os.path.isfile(c) and os.access(c, os.X_OK):
            return c
    return None


def representative_job(with_project=False):
    """Mirror RemoteRunner.buildJobJSON for a STEP loadcase run (every optional block
    populated so the whole schema surface is exercised)."""
    job = {
        "model": "m.step",
        "material": "PLA",
        "mode": "minimize_plastic",
        "resolution": 32,
        "output": {"report": "report.json", "mesh_format": "stl",
                   "mesh_prefix": "variant", "smooth_factor": 2},
        "design_box": {"min": [0.0, 0.0, 0.0], "max": [40.0, 40.0, 40.0]},
        "keep_outs": [{"min": [5.0, 5.0, 5.0], "max": [10.0, 10.0, 10.0]}],
        "loads": {
            "minimize_plastic": True,
            "build_dir": [0.0, 0.0, 1.0],
            "anchor_face_ids": [1, 2],
            "groups": [{"face_ids": [3, 4], "force": [0.0, 0.0, -50.0]}],
            "infill_percent": 40,
            "clearances": [
                {"face_id": 5, "kind": "bolt",
                 "concentric_margin_mm": 3.0, "axial_clearance_mm": 5.0},
                {"face_id": 6, "kind": "face", "slab_depth_mm": 4.0},
            ],
            "face_protections": [7, 8],
            "face_protection_depth_mm": 5.0,
        },
    }
    if with_project:
        job["project"] = "Should Be Rejected"
    return job


def run_cli(cli, job):
    work = tempfile.mkdtemp(prefix="cli-smoke-")
    job_path = os.path.join(work, "job.json")
    with open(job_path, "w") as f:
        json.dump(job, f)
    # A throwaway model so the run fails fast at import, AFTER the schema parse.
    with open(os.path.join(work, "m.step"), "w") as f:
        f.write("ISO-10303-21;\nENDSEC;\n")
    out_dir = os.path.join(work, "out")
    try:
        p = subprocess.run([cli, "run", job_path, "--out", out_dir],
                           capture_output=True, text=True, timeout=60)
        return (p.stdout or "") + (p.stderr or "")
    except subprocess.TimeoutExpired as e:
        return "TIMEOUT: " + ((e.stdout or "") + (e.stderr or "") if isinstance(e.stdout, str) else "")


def has_schema_rejection(output):
    low = output.lower()
    return any(m.lower() in low for m in SCHEMA_MARKERS)


def main():
    cli = find_cli()
    if not cli:
        print("SKIP: no topopt-cli binary found "
              "(set TOPOPT_REAL_CLI or build core/) — schema drift guard not run.")
        return 0
    print("== real-CLI parse smoke: %s ==" % cli)

    fails = []

    # (1) The representative app job.json must NOT trigger a schema rejection.
    out = run_cli(cli, representative_job())
    if has_schema_rejection(out):
        print(" FAIL  the representative job.json was rejected by the CLI schema:")
        print("        " + " | ".join(out.strip().splitlines()[-4:]))
        fails.append("representative job rejected")
    else:
        print("  OK   the representative app job.json passes the CLI schema "
              "(any failure was past parse, i.e. model import)")

    # (2) Positive control: the SAME job with a stray `project` key MUST be rejected —
    #     this is why the worker strips it (item 2). If the CLI ever silently accepted
    #     it, the strip could rot unnoticed; this keeps the guard honest.
    out_p = run_cli(cli, representative_job(with_project=True))
    if has_schema_rejection(out_p):
        print("  OK   a stray `project` key IS rejected by the CLI (the worker strip "
              "is load-bearing)")
    else:
        print(" FAIL  the CLI did NOT reject a stray `project` key — the schema is no "
              "longer strict; the item-2 strip may be silently unnecessary or the CLI "
              "changed. Investigate before trusting the round-trip.")
        fails.append("project key not rejected")

    if fails:
        print("FAILED: %d check(s): %s" % (len(fails), ", ".join(fails)))
        return 1
    print("OK: the real CLI accepts the app's job.json schema and rejects worker "
          "metadata — no app→worker→CLI drift.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
