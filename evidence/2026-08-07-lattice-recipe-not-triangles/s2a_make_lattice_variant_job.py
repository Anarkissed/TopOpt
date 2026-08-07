#!/usr/bin/env python3
"""S2(a) — build a `lattice_variant` job from a finished run's RECIPE.

This is the deferred-materialisation path, measured rather than imagined: the
only inputs are the run's own job document and its `design.bin`. No mesh is
read. `topopt-cli lattice-variant` on the result produces the same
`variant_XXX_lattice.stl` the optimize run would have written eagerly, so the
wall time of that command IS the price of the round trip.

It mirrors `RelatticeJobBuilder` (app/TopOptKit/Sources/TopOptFlows/
RelatticeRunner.swift:84-105): mode → "lattice_variant", add a `variant` block
naming the design file + the u64 fingerprint as a DECIMAL STRING, and carry
everything else from the original document untouched.

Usage:
  s2a_make_lattice_variant_job.py <orig_job.json> <design.bin> <vf> <out.json>
                                  [--cell-mode MODE] [--cell-min MM]
                                  [--cell MM] [--skin S]
"""
import json
import struct
import sys


def design_variants(path):
    """[(requested_vf, achieved_vf, fingerprint)] from design.bin v1.

    Format: core/include/topopt/design_store.hpp:46.
    """
    with open(path, "rb") as f:
        blob = f.read()
    if blob[0] != 1:
        raise SystemExit(f"design.bin: unexpected version {blob[0]}")
    nx, ny, nz = struct.unpack_from("<iii", blob, 4)
    nvar = struct.unpack_from("<i", blob, 48)[0]
    voxels = nx * ny * nz
    out = []
    off = 56
    # Per-variant block layout (design_store.hpp:63-77): 5 f64, 2 i32, 3 f64,
    # 2 i32, u64 fingerprint @+80, i64 density_count @+88, then the field @+96.
    for _ in range(nvar):
        req, ach = struct.unpack_from("<dd", blob, off)
        fp = struct.unpack_from("<Q", blob, off + 80)[0]
        n = struct.unpack_from("<q", blob, off + 88)[0]
        if n != voxels:
            raise SystemExit(f"design.bin: density_count {n} != {voxels}")
        out.append((req, ach, fp))
        off += 96 + n * 8
    return out


def main():
    a = sys.argv[1:]
    if len(a) < 4:
        raise SystemExit(__doc__)
    orig_job, design, vf_s, out_json = a[0], a[1], a[2], a[3]
    vf = float(vf_s)

    def opt(flag, default=None):
        return a[a.index(flag) + 1] if flag in a else default

    job = json.load(open(orig_job))
    vars_ = design_variants(design)
    match = [v for v in vars_ if abs(v[0] - vf) < 1e-9]
    if not match:
        raise SystemExit(
            f"design.bin holds no block for vf={vf}; it has "
            + ", ".join(f"{v[0]:.6g}" for v in vars_))
    req, ach, fp = match[0]

    job["mode"] = "lattice_variant"
    variant = {"design": design.split("/")[-1], "fingerprint": str(fp)}
    if ach > 0:
        variant["achieved_volume_fraction"] = ach
    job["variant"] = variant

    lat = dict(job.get("lattice", {}))
    if opt("--skin"):
        lat["skin"] = opt("--skin")
    job["lattice"] = lat

    grad = dict(job.get("grading", {}))
    if opt("--cell-mode"):
        grad["cell_mode"] = opt("--cell-mode")
    if opt("--cell-min"):
        grad["cell_min_mm"] = float(opt("--cell-min"))
    if opt("--cell"):
        grad["cell_mm"] = float(opt("--cell"))
    # `cell_min_mm` / `cell_max_mm` are the SWEPT window and core refuses them
    # under any other mode ("grading \"cell_min_mm\" / \"cell_max_mm\" are only
    # allowed with \"cell_mode\": \"swept\"" — measured, s2_probes.txt P3), so a
    # mode switch must drop them rather than carry them along.
    if grad.get("cell_mode") != "swept":
        grad.pop("cell_min_mm", None)
        grad.pop("cell_max_mm", None)
    if grad:
        job["grading"] = grad

    # `lattice_variant` re-certifies a FIXED design; the ladder keys are noise
    # here and the mode's own validator is the authority on what it accepts.
    json.dump(job, open(out_json, "w"), indent=1)
    print(f"wrote {out_json}")
    print(f"  variant vf={req:.6g} achieved={ach:.6g} fingerprint={fp}")
    print(f"  cell_mode={job.get('grading', {}).get('cell_mode')} "
          f"cell_min_mm={job.get('grading', {}).get('cell_min_mm')} "
          f"skin={job['lattice'].get('skin')}")


if __name__ == "__main__":
    main()
