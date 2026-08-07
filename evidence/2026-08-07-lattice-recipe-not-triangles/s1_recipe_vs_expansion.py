#!/usr/bin/env python3
"""S1(a)/(b) — weigh the RECIPE against the EXPANSION, on the maintainer's run.

Reads a completed `topopt-cli run` output directory for a latticed ladder and
reports, per variant and for the run:

  * the EXPANSION: the bytes and triangles actually written as
    `variant_XXX_lattice.stl`;
  * the RECIPE: the bytes of a compact description sufficient to rebuild that
    file. Two encodings are reported, and the difference between them matters:

      MINIMAL      what core ALREADY writes and the app ALREADY fetches:
                   the job document + this variant's `design.bin` block.
                   The lattice mesh is a pure function of these two (the
                   generator's LatticeBoundary is `set_voxel_base(grid,
                   density, iso, window)` — core/include/topopt/
                   lattice_boundary.hpp:99 — and the cell plan, the grading
                   law, the occupancy and the strut radii are all derived
                   from the job + that field).

      SELF-CONTAINED  MINIMAL plus the DERIVED per-cell layer, so a reader
                   need not re-run the grading law: a 1-bit occupancy mask
                   over the cell block, and one f32 relative density per
                   latticed cell. This is the encoding of the `LatticePosture`
                   core already builds in memory at
                   core/src/cli/run_job.cpp:1199 and throws away.

  * the SOLID COMPANION SHELL, which IS a mesh and stays one.

Nothing here changes core or the app; this reads a run's own artifacts.

Usage:  s1_recipe_vs_expansion.py <out_dir> <job.json> <run.log> [--csv PATH]

`run.log` supplies the AUTHORITATIVE per-variant `cells=` and `tris=` — core's
own `LATTICE vf=...` checkpoint line (core/src/cli/run_job.cpp:7386/7399),
counted by the generator rather than re-derived from the file.
"""
import json
import os
import re
import struct
import sys

STL_HEADER = 84          # 80-byte header + u32 triangle count
STL_TRI = 50             # 12 floats + u16 attribute


def stl_triangles(path):
    """Triangle count from the binary-STL header, and the file's real size."""
    size = os.path.getsize(path)
    with open(path, "rb") as f:
        f.seek(80)
        n = struct.unpack("<I", f.read(4))[0]
    return n, size


def design_bin_geometry(path):
    """(nx, ny, nz, spacing, variant_count, per_variant_bytes) of design.bin v1.

    Format: core/include/topopt/design_store.hpp:46.
    """
    with open(path, "rb") as f:
        head = f.read(56)
    ver = head[0]
    if ver != 1:
        raise SystemExit(f"design.bin: unexpected version {ver}")
    nx, ny, nz = struct.unpack_from("<iii", head, 4)
    spacing = struct.unpack_from("<d", head, 40)[0]
    nvar = struct.unpack_from("<i", head, 48)[0]
    voxels = nx * ny * nz
    # per-variant block: 5 f64 + 2 i32 + 3 f64 + 2 i32 + u64 + i64 + f64[voxels]
    per_variant = 5 * 8 + 2 * 4 + 3 * 8 + 2 * 4 + 8 + 8 + voxels * 8
    return nx, ny, nz, spacing, nvar, per_variant


def lattice_lines(log_path):
    """{mesh basename: {cells, tris, cell_mm}} from core's own LATTICE lines."""
    out = {}
    pat = re.compile(r"^LATTICE\s+(.*)$")
    for line in open(log_path, errors="replace"):
        m = pat.match(line.strip())
        if not m:
            continue
        kv = {}
        for tok in m.group(1).split():
            if "=" in tok:
                k, v = tok.split("=", 1)
                kv[k] = v
        mesh = kv.get("mesh", "")
        if not mesh:
            continue
        out[os.path.basename(mesh)] = dict(
            cells=int(kv.get("cells", 0)),
            tris=int(kv.get("tris", 0)),
            cell_mm=float(kv.get("cell_mm", 0)))
    return out


def main():
    if len(sys.argv) < 4:
        raise SystemExit(__doc__)
    out = sys.argv[1]
    job_path = sys.argv[2]
    log_path = sys.argv[3]
    lat = lattice_lines(log_path)
    csv_path = None
    if "--csv" in sys.argv:
        csv_path = sys.argv[sys.argv.index("--csv") + 1]

    job_bytes = os.path.getsize(job_path)
    dpath = os.path.join(out, "design.bin")
    nx, ny, nz, spacing, nvar, per_variant = design_bin_geometry(dpath)
    voxels = nx * ny * nz
    design_total = os.path.getsize(dpath)

    rows = []
    for name in sorted(os.listdir(out)):
        if not name.endswith("_lattice.stl"):
            continue
        tag = name[: -len("_lattice.stl")]           # e.g. variant_068
        lat_path = os.path.join(out, name)
        file_tris, lat_bytes = stl_triangles(lat_path)

        rcpt_path = os.path.join(out, tag + "_lattice.report.json")
        rcpt = json.load(open(rcpt_path)) if os.path.exists(rcpt_path) else {}

        # The solid companion shell — a real mesh, and it STAYS one. Two
        # numbers, deliberately kept apart: `solid_*` is the separately written
        # `variant_XXX.stl`; `companion_tris` is the kept-solid body core folds
        # INTO the lattice file (run_job.cpp:1093).
        solid_path = os.path.join(out, tag + ".stl")
        solid_tris, solid_bytes = (
            stl_triangles(solid_path) if os.path.exists(solid_path) else (0, 0))
        companion_tris = rcpt.get("solid_region_triangles", 0)

        # cells/tris from core's own generator counters; `tris` there is the
        # LATTICE's triangles, while the file also carries shell + companion.
        L = lat.get(name, {})
        cells = L.get("cells", 0)
        gen_tris = L.get("tris", 0)
        cell_mm = L.get("cell_mm") or rcpt.get("cell_mm") or 0.0
        # The cell BLOCK the occupancy mask spans: the solved grid's extent
        # divided by the cell edge (lattice_region_for, run_job.cpp:928).
        if cell_mm > 0:
            bx = int(nx * spacing / cell_mm) + 1
            by = int(ny * spacing / cell_mm) + 1
            bz = int(nz * spacing / cell_mm) + 1
        else:
            bx = by = bz = 0
        block_cells = bx * by * bz

        occupancy_bytes = (block_cells + 7) // 8      # 1 bit per cell
        rho_bytes = cells * 4                         # f32 per LATTICED cell
        scalars = 64                                  # topology, cell, skin, radii law

        minimal = job_bytes + per_variant
        selfcont = minimal + occupancy_bytes + rho_bytes + scalars

        rows.append(dict(
            tag=tag, tris=file_tris, gen_tris=gen_tris, lat_bytes=lat_bytes,
            solid_tris=solid_tris, solid_bytes=solid_bytes,
            companion_tris=companion_tris,
            cells=cells, cell_mm=cell_mm, block_cells=block_cells,
            occupancy_bytes=occupancy_bytes, rho_bytes=rho_bytes,
            minimal=minimal, selfcont=selfcont))

    def mb(b):
        return b / (1024.0 * 1024.0)

    print(f"grid {nx}x{ny}x{nz} = {voxels:,} voxels, spacing {spacing:.6g} mm")
    print(f"job document        {job_bytes:,} B")
    print(f"design.bin          {design_total:,} B total, "
          f"{per_variant:,} B/variant, {nvar} variant block(s)")
    print()
    hdr = ("variant", "cells", "cell mm", "FILE tris", "strut tris",
           "lattice STL B", "companion tris", "recipe MIN B", "recipe SC B",
           "MIN ratio", "SC ratio")
    print("{:<12}{:>10}{:>9}{:>13}{:>13}{:>16}{:>15}{:>14}{:>13}{:>11}{:>10}"
          .format(*hdr))
    tot = dict(tris=0, gen_tris=0, lat_bytes=0, solid_tris=0, solid_bytes=0,
               companion_tris=0, cells=0, occ=0, rho=0)
    for r in rows:
        print("{:<12}{:>10,}{:>9.4g}{:>13,}{:>13,}{:>16,}{:>15,}{:>14,}{:>13,}"
              "{:>10.1f}x{:>9.1f}x".format(
                  r["tag"], r["cells"], r["cell_mm"], r["tris"], r["gen_tris"],
                  r["lat_bytes"], r["companion_tris"], r["minimal"], r["selfcont"],
                  r["lat_bytes"] / r["minimal"], r["lat_bytes"] / r["selfcont"]))
        for k in ("tris", "gen_tris", "lat_bytes", "solid_tris", "solid_bytes",
                  "companion_tris", "cells"):
            tot[k] += r[k]
        tot["occ"] += r["occupancy_bytes"]
        tot["rho"] += r["rho_bytes"]

    # THE RUN. design.bin is ONE container covering every variant, and the job
    # document is ONE file — so the run's recipe is not the sum of the per-
    # variant recipes, it is the container plus the per-cell layer.
    run_minimal = job_bytes + design_total
    run_selfcont = run_minimal + tot["occ"] + tot["rho"] + 64 * len(rows)
    print()
    print(f"RUN  cells {tot['cells']:,}   file triangles {tot['tris']:,}"
          f"   (of which strut/lattice {tot['gen_tris']:,})")
    print(f"RUN  lattice STL      {tot['lat_bytes']:,} B  ({mb(tot['lat_bytes']):.2f} MiB"
          f" = {tot['lat_bytes']/1e9:.3f} GB)")
    print(f"RUN  recipe MINIMAL   {run_minimal:,} B  ({mb(run_minimal):.2f} MiB)"
          f"   ratio {tot['lat_bytes']/run_minimal:,.1f}x")
    print(f"RUN  recipe SELF-CONT {run_selfcont:,} B  ({mb(run_selfcont):.2f} MiB)"
          f"   ratio {tot['lat_bytes']/run_selfcont:,.1f}x")
    print(f"RUN  solid companion  {tot['solid_bytes']:,} B "
          f"({tot['solid_tris']:,} triangles) — IS a mesh, STAYS a mesh")

    if csv_path:
        cols = ("variant,cells,cell_mm,file_triangles,strut_triangles,"
                "lattice_stl_bytes,companion_triangles,solid_stl_triangles,"
                "solid_stl_bytes,recipe_minimal_bytes,recipe_selfcontained_bytes,"
                "ratio_minimal,ratio_selfcontained\n")
        with open(csv_path, "w") as f:
            f.write(cols)
            for r in rows:
                f.write("{tag},{cells},{cell_mm:.10g},{tris},{gen_tris},"
                        "{lat_bytes},{companion_tris},{solid_tris},{solid_bytes},"
                        "{minimal},{selfcont},".format(**r))
                f.write("{:.6g},{:.6g}\n".format(
                    r["lat_bytes"] / r["minimal"], r["lat_bytes"] / r["selfcont"]))
            f.write("RUN,{},{:.10g},{},{},{},{},{},{},{},{},{:.6g},{:.6g}\n".format(
                tot["cells"], rows[0]["cell_mm"] if rows else 0, tot["tris"],
                tot["gen_tris"], tot["lat_bytes"], tot["companion_tris"],
                tot["solid_tris"], tot["solid_bytes"],
                run_minimal, run_selfcont,
                tot["lat_bytes"] / run_minimal, tot["lat_bytes"] / run_selfcont))
        print(f"\nwrote {csv_path}")


if __name__ == "__main__":
    main()
