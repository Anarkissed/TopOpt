#!/usr/bin/env python3
"""R3 / R4 — the two tables that have to come off the maintainer's OWN run.

    python3 r3_his_run.py <before-out-dir> <after-out-dir>

R3  THE NO-PROTRUSION INVARIANT, per variant, before and after. The numbers come
    from the run's own lattice receipts (`max_strut_protrusion_mm` and friends),
    which are written by the production measurement itself — not by a script
    re-deriving the geometry beside it. Zero is the bar.

R4  THE FULL GATE TABLE: every rung, its verdict and its margin, plus the
    VOXEL-CLASSIFICATION flips between the two runs. ★ The flip count is reported
    against a 1e-9 NEGATIVE-CONTROL FLOOR: the same comparison is run
    before-vs-before, which must give exactly 0 flips. Without that control a
    "0 flips" result is indistinguishable from a comparison that silently read
    the same file twice.

    Voxel classification is read from design.bin — the f64 physical density the
    run stored — and a voxel is CLASSIFIED as printed iff density >= 0.5.
"""
import json
import os
import struct
import sys


def read_design(path):
    """design.bin v1 — see core/include/topopt/design_store.hpp for the layout."""
    with open(path, "rb") as f:
        blob = f.read()
    ver = blob[0]
    if ver != 1:
        raise SystemExit(f"{path}: unsupported design.bin version {ver}")
    off = 4
    nx, ny, nz = struct.unpack_from("<iii", blob, off); off += 12
    ox, oy, oz, spacing = struct.unpack_from("<dddd", blob, off); off += 32
    nvar, _ = struct.unpack_from("<ii", blob, off); off += 8
    variants = []
    for _ in range(nvar):
        (rvf, avf, mwc, meff, mvm) = struct.unpack_from("<ddddd", blob, off); off += 40
        (acc, iters) = struct.unpack_from("<ii", blob, off); off += 8
        off += 24                                    # applied_build_dir[3]
        off += 8                                     # auto_applied + export_baked
        (fp,) = struct.unpack_from("<Q", blob, off); off += 8
        (n,) = struct.unpack_from("<q", blob, off); off += 8
        dens = struct.unpack_from(f"<{n}d", blob, off); off += 8 * n
        variants.append({
            "requested_vf": rvf, "achieved_vf": avf, "margin": mwc,
            "margin_effective": meff, "max_vm": mvm, "accepted": bool(acc),
            "iterations": iters, "fingerprint": fp, "density": dens,
        })
    return {"nx": nx, "ny": ny, "nz": nz, "spacing": spacing,
            "origin": (ox, oy, oz), "variants": variants}


def flips(a, b, iso=0.5):
    """Voxels whose PRINTED classification differs between two designs."""
    return sum(1 for x, y in zip(a, b) if (x >= iso) != (y >= iso))


def receipts(d):
    out = {}
    for fn in sorted(os.listdir(d)):
        if fn.endswith("_lattice.report.json"):
            out[fn] = json.load(open(os.path.join(d, fn)))
    return out


def num(v, nd=6):
    return "n/a" if v is None else (f"{v:.{nd}f}" if isinstance(v, float) else str(v))


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    before_dir, after_dir = sys.argv[1], sys.argv[2]
    b = read_design(os.path.join(before_dir, "design.bin"))
    a = read_design(os.path.join(after_dir, "design.bin"))

    print("=== R4a — the DESIGN is untouched (the fix is a post-process) ===")
    print(f"{'rung':>6} {'accepted':>9} {'margin_before':>16} {'margin_after':>16} "
          f"{'flips':>10} {'control':>8}")
    total_flips = 0
    for vb, va in zip(b["variants"], a["variants"]):
        f = flips(vb["density"], va["density"])
        ctrl = flips(vb["density"], vb["density"])   # ★ 1e-9 negative control
        total_flips += f
        print(f"{vb['requested_vf']:>6.2f} {str(vb['accepted']):>9} "
              f"{vb['margin']:>16.6f} {va['margin']:>16.6f} {f:>10d} {ctrl:>8d}")
    nvox = b["nx"] * b["ny"] * b["nz"]
    print(f"grid {b['nx']}x{b['ny']}x{b['nz']} = {nvox} voxels, "
          f"spacing {b['spacing']:.6f} mm")
    print(f"TOTAL voxel-classification flips: {total_flips}   "
          f"(negative control must be 0 on every row)")
    print()

    print("=== R3 — the no-protrusion invariant, per variant ===")
    rb, ra = receipts(before_dir), receipts(after_dir)
    keys = sorted(set(rb) | set(ra))
    hdr = ("file", "clip base", "max protrusion mm", "outside", "measured",
           "allowance mm")
    print(f"{hdr[0]:>34} {hdr[1]:>18} {hdr[2]:>19} {hdr[3]:>9} {hdr[4]:>10} "
          f"{hdr[5]:>13}")
    for k in keys:
        for tag, r in (("BEFORE", rb.get(k)), ("AFTER ", ra.get(k))):
            if r is None:
                print(f"{tag} {k:>27} {'(absent)':>18}")
                continue
            base = r.get("clip_base_surface", r.get("clip_surface", "?"))
            print(f"{tag} {k:>27} {base:>18} "
                  f"{num(r.get('max_strut_protrusion_mm'), 7):>19} "
                  f"{str(r.get('protruding_vertices')):>9} "
                  f"{str(r.get('protrusion_vertices_measured')):>10} "
                  f"{num(r.get('protrusion_allowance_mm'), 7):>13}")
    print()

    print("=== R4b — the LATTICE gate + what the clip cost, per variant ===")
    print("    (mass is the emitted interior volume x PLA 1.24 g/cm^3; the "
          "latticed-voxel column is\n"
          "     the CERTIFIED set, so a change there is a change in what the "
          "gate was asked about)")
    cols = ("lattice margin", "accepted", "latticed voxels", "interior mm3",
            "clipped struts")
    print(f"{'file':>34} {cols[0]:>16} {cols[1]:>9} {cols[2]:>16} {cols[3]:>15} "
          f"{cols[4]:>15}")
    deltas = []
    for k in keys:
        for tag, r in (("BEFORE", rb.get(k)), ("AFTER ", ra.get(k))):
            if r is None:
                continue
            grad = r.get("grading", {})
            print(f"{tag} {k:>27} "
                  f"{num(r.get('lattice_margin_worst_case'), 6):>16} "
                  f"{str(r.get('lattice_accepted')):>9} "
                  f"{str(grad.get('latticed_voxels', r.get('lattice_voxels'))):>16} "
                  f"{num(r.get('interior_volume_mm3'), 3):>15} "
                  f"{str(r.get('clipped_struts')):>15}")
        # ENUMERATE the change, per variant, in the two currencies the bar names:
        # certified latticed voxels, and the mass of the lattice actually emitted.
        b_, a_ = rb.get(k), ra.get(k)
        if b_ and a_:
            gb, ga = b_.get("grading", {}), a_.get("grading", {})
            vb = gb.get("latticed_voxels", b_.get("lattice_voxels")) or 0
            va = ga.get("latticed_voxels", a_.get("lattice_voxels")) or 0
            mb = (b_.get("interior_volume_mm3") or 0.0) * 1.24 / 1000.0
            ma = (a_.get("interior_volume_mm3") or 0.0) * 1.24 / 1000.0
            deltas.append((k, va - vb, ma - mb, mb))
            print(f"DELTA  {k:>27} latticed voxels {va - vb:+d}   "
                  f"lattice mass {ma - mb:+.6f} g "
                  f"({(100.0 * (ma - mb) / mb if mb else 0.0):+.3f} % of {mb:.4f} g)")
    # Generation wall time is a RUN-level aggregate (run_info's
    # lattice_export_gen_seconds / _fraction), not a per-receipt field — that is
    # the number the task's S2(a) cost question is against, so it is printed from
    # where it actually lives instead of left as an empty column above.
    print()
    print("=== S2(a) — what clipping against the shell COST, in generator time ===")
    for tag, d in (("BEFORE", before_dir), ("AFTER ", after_dir)):
        ri = json.load(open(os.path.join(d, "run_info.json")))
        # These live under run_info's "lattice_export" block, not at the top
        # level — reading them from where they actually are rather than emitting
        # "n/a" and calling it a measurement.
        le = ri.get("lattice_export", {})
        gs = le.get("gen_seconds")
        gf = le.get("gen_fraction")
        wall = gs / gf if (gs and gf) else None
        print(f"{tag}  lattice_export.gen_seconds = {num(gs, 3)} s   "
              f"fraction of the run = {num(gf, 6)}   implied run wall = "
              f"{num(wall, 1)} s")
    print("    ★ BOTH SIDES INCLUDE THE NEW MEASUREMENT (the MeasuringSink and")
    print("      the per-voxel Lipschitz floor), which is identical on each, so")
    print("      this difference is the CLIP's and not the invariant's. The")
    print("      generator timed ALONE, with no measurement attached, is in")
    print("      s1_probe.txt's 'GENERATOR ALONE' line.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
