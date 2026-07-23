#!/usr/bin/env python3
"""stub_cli.py — a protocol-faithful stand-in for `topopt-cli`, used by the LAN
offload E2E harness (handoffs 097 + 101).

It emits the EXACT stdout protocol the real CLI emits (`run_job.cpp`):
    PROGRESS rung=<i> rungs=<n> iter=<k>
    VARIANT vf=<req> achieved=<vf> margin=<m> accepted=<0|1> mesh=<path>
writes real binary-STL meshes + a schema-valid `report.json`, and answers
`--version` with a controllable fingerprint. It runs no FEA — it drives the
TRANSPORT (worker + RemoteRunner + RunModel) fast and controllably, which is what
the liveness redesign needs to exercise (heartbeat, reconnect, dedup, unreachable,
cancel). Numerics are the on-device bridge's job, unchanged and covered elsewhere.

Behaviour is selected by TOPOPT_STUB_MODE (default "normal"):
    normal      2 rungs × 3 iters, 2 accepted variants, report, exit 0.
    slow_sparse like normal but with a long gap (TOPOPT_STUB_GAP s, default 4)
                between PROGRESS events — longer than the client's inactivity
                grace, so only the worker heartbeat keeps the run alive. Proves a
                minutes-scale-gap run does NOT false-timeout.
    reject_all  a report ladder with nothing accepted (no VARIANT lines), exit 0.
    bad_mesh    announces a VARIANT whose mesh file is never written (client 404s).
    slow        emit PROGRESS slowly, effectively forever, until killed — the
                cancel control (the client cancels, the worker DELETE kills this).
    drop / dies same event shape as normal but paced (TOPOPT_STUB_GAP) so the
                harness can drop the stream / kill the worker mid-run.

Env:
    TOPOPT_STUB_FINGERPRINT   fingerprint reported by --version (default the app's).
    TOPOPT_STUB_GAP           seconds between paced PROGRESS events (default 0).
"""

import json
import os
import struct
import sys
import time

FINGERPRINT = os.environ.get("TOPOPT_STUB_FINGERPRINT", "b9d0a2fb03e4")
MODE = os.environ.get("TOPOPT_STUB_MODE", "normal")
GAP = float(os.environ.get("TOPOPT_STUB_GAP", "0"))


def emit(line):
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


def write_cube_stl(path, s=10.0):
    """Write a tiny binary-STL unit cube (12 triangles) so the client's STL reader
    returns real geometry (a bodiless/empty part is a reject-class bug it guards)."""
    v = [(0, 0, 0), (s, 0, 0), (s, s, 0), (0, s, 0),
         (0, 0, s), (s, 0, s), (s, s, s), (0, s, s)]
    faces = [(0, 3, 2), (0, 2, 1), (4, 5, 6), (4, 6, 7),
             (0, 1, 5), (0, 5, 4), (2, 3, 7), (2, 7, 6),
             (1, 2, 6), (1, 6, 5), (0, 4, 7), (0, 7, 3)]
    with open(path, "wb") as f:
        f.write(b"\0" * 80)
        f.write(struct.pack("<I", len(faces)))
        for a, b, c in faces:
            f.write(struct.pack("<3f", 0.0, 0.0, 0.0))  # normal (ignored by reader)
            for idx in (a, b, c):
                f.write(struct.pack("<3f", *v[idx]))
            f.write(struct.pack("<H", 0))


# Grid the stub's fields.bin is written against. Deliberately TINY (4³ voxels →
# 5³ nodes) so the container is a few kB on the wire: the point is to exercise the
# fetch + parse + presence gates, not to move a realistic 34 MB/variant payload.
FIELDS_NX, FIELDS_NY, FIELDS_NZ = 4, 4, 4
FIELDS_SPACING = 2.5


def write_fields_bin(path, variants):
    """Write a v1 `fields.bin` (core/include/topopt/fields.hpp) for the accepted
    variants — the per-voxel container a remote run needs for the stress overlay,
    flex, the load-path overlay and the voxel MASS (handoff 122).

    The stub did not write this before handoff 134, which meant every E2E case
    exercised the fetch-FAILED branch only: the whole "remote results light up"
    path — and, worse, the RE-ATTACH path's version of it — was never proven end to
    end over real HTTP. `variants` is [(requested_vf, mass_grams, support_voxels)];
    field VALUES are synthetic but structurally exact (counts must equal the grid's
    voxel/node counts or the app would misindex them).
    """
    voxels = FIELDS_NX * FIELDS_NY * FIELDS_NZ
    nodes = (FIELDS_NX + 1) * (FIELDS_NY + 1) * (FIELDS_NZ + 1)
    with open(path, "wb") as f:
        f.write(struct.pack("<B3x", 1))                       # version + reserved[3]
        f.write(struct.pack("<3i", FIELDS_NX, FIELDS_NY, FIELDS_NZ))
        f.write(struct.pack("<3d", 0.0, 0.0, 0.0))            # grid origin (mm)
        f.write(struct.pack("<2d", FIELDS_SPACING, FIELDS_SPACING ** 3))
        f.write(struct.pack("<i", len(variants)))
        f.write(struct.pack("<i", 0))                         # reserved
        for vf, mass, support in variants:
            f.write(struct.pack("<2d", vf, mass))
            f.write(struct.pack("<i", support))
            f.write(struct.pack("<i", 0))                     # reserved
            # von Mises (per voxel), stress tensor (EMPTY in v1), displacement
            # (3 per node) — each length-prefixed as i64, as the format requires.
            f.write(struct.pack("<3q", voxels, 0, 3 * nodes))
            # A ramp, so a reader that mis-strides produces visibly wrong values
            # rather than a plausible constant.
            f.write(struct.pack("<%df" % voxels, *[1.0 + i * 0.5 for i in range(voxels)]))
            f.write(struct.pack("<%df" % (3 * nodes),
                                *[0.001 * (i % 7) for i in range(3 * nodes)]))


def report_variant(vf, worst, in_plane, interlayer):
    return {
        "volume_fraction": vf,
        "margin": {"worst_case": worst, "in_plane": in_plane, "interlayer": interlayer},
        "orientation": {"x": 0.0, "y": 0.0, "z": 1.0},
        "max_stress_mpa": 12.0,
        "max_interlayer_tension_mpa": 3.0,
        "min_feature_violations": 0,
        "min_feature_warning": "",
    }


def paced_sleep():
    if GAP > 0:
        time.sleep(GAP)


def run(out_dir, job_path=None):
    os.makedirs(out_dir, exist_ok=True)

    # Echo the job.json we were HANDED into the output dir so the E2E can assert, over
    # the wire (GET /files/received_job.json), that the worker stripped worker-level
    # metadata before the CLI saw it — the real CLI's schema is strict and would reject
    # a stray `project` key on a device (handoff 129, item 2 evidence).
    if job_path and os.path.isfile(job_path):
        try:
            with open(job_path) as jf:
                received = jf.read()
            with open(os.path.join(out_dir, "received_job.json"), "w") as rf:
                rf.write(received)
        except OSError:
            pass

    if MODE == "dies":
        # worker_dies_midrun control: emit rung-0 progress + the first variant,
        # give the worker a beat to forward them to the client, then KILL THE WHOLE
        # WORKER (our parent process) to simulate the Mac/worker going away mid-run.
        # The client must then probe, find the worker unreachable, and fail WITHOUT
        # ever sending a DELETE (the harness proxy records the wire to prove it).
        import signal
        for it in range(1, 4):
            emit("PROGRESS rung=0 rungs=2 iter=%d" % it)
            time.sleep(max(GAP, 0.3))
        mesh_path = os.path.join(out_dir, "variant_070.stl")
        write_cube_stl(mesh_path)
        emit("VARIANT vf=0.70 achieved=0.70 margin=2.40 accepted=1 mesh=%s" % mesh_path)
        time.sleep(0.7)   # let the worker flush the variant event to the client
        try:
            os.kill(os.getppid(), signal.SIGKILL)
        except OSError:
            pass
        time.sleep(5)     # we will be killed with our parent; just in case
        return

    if MODE == "slow":
        # Cancel control: stream PROGRESS effectively forever until killed.
        rung, i = 0, 0
        while True:
            i += 1
            emit("PROGRESS rung=%d rungs=2 iter=%d" % (rung, i))
            time.sleep(max(GAP, 0.2))
        return

    if MODE == "reject_all":
        for it in range(1, 4):
            emit("PROGRESS rung=0 rungs=2 iter=%d" % it)
        for it in range(1, 4):
            emit("PROGRESS rung=1 rungs=2 iter=%d" % it)
        report = {"variants": [report_variant(0.60, 1.20, 1.30, 1.20),
                               report_variant(0.50, 1.10, 1.20, 1.10)]}
        with open(os.path.join(out_dir, "report.json"), "w") as f:
            json.dump(report, f)
        return

    if MODE == "bad_mesh":
        for it in range(1, 4):
            emit("PROGRESS rung=0 rungs=2 iter=%d" % it)
        # Announce a variant whose mesh file is deliberately NOT written → the
        # client must 404 on the fetch and FAIL the run (never a silent empty part).
        emit("VARIANT vf=0.70 achieved=0.70 margin=2.40 accepted=1 mesh=%s"
             % os.path.join(out_dir, "variant_070.stl"))
        time.sleep(1.0)
        report = {"variants": [report_variant(0.70, 2.40, 2.60, 2.40)]}
        with open(os.path.join(out_dir, "report.json"), "w") as f:
            json.dump(report, f)
        return

    # normal / slow_sparse / drop / dies: two accepted rungs.
    rungs = [(0, 0.70, 2.40, 2.60, 2.40, "variant_070.stl"),
             (1, 0.50, 1.70, 1.90, 1.70, "variant_050.stl")]
    report_variants = []
    for rung, vf, worst, in_plane, interlayer, mesh in rungs:
        for it in range(1, 4):
            emit("PROGRESS rung=%d rungs=2 iter=%d" % (rung, it))
            paced_sleep()
        mesh_path = os.path.join(out_dir, mesh)
        write_cube_stl(mesh_path)
        emit("VARIANT vf=%.2f achieved=%.2f margin=%.2f accepted=1 mesh=%s"
             % (vf, vf, worst, mesh_path))
        report_variants.append(report_variant(vf, worst, in_plane, interlayer))
    with open(os.path.join(out_dir, "report.json"), "w") as f:
        json.dump({"variants": report_variants}, f)
    # The real CLI writes fields.bin LAST, after the meshes + report (handoff 122);
    # mirror that ordering so the client's post-terminal fetch is exercised the way
    # production sees it. Masses are non-zero on purpose: "real mass present" is
    # half of what the re-attach QA repro asserts.
    write_fields_bin(os.path.join(out_dir, "fields.bin"),
                     [(0.70, 41.5, 120), (0.50, 29.5, 90)])


def main():
    args = sys.argv[1:]
    if args and args[0] == "--version":
        print("topopt-cli version=stub-101 fingerprint=%s" % FINGERPRINT)
        return
    if args and args[0] == "run":
        job_path = args[1] if len(args) > 1 and not args[1].startswith("--") else None
        out_dir = "."
        if "--out" in args:
            out_dir = args[args.index("--out") + 1]
        run(out_dir, job_path)
        return
    sys.stderr.write("stub_cli: unknown invocation %r\n" % (args,))
    sys.exit(2)


if __name__ == "__main__":
    main()
