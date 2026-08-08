#!/usr/bin/env python3
"""S2(a)/(b) -- WHAT A CUT-CELL SCHEME WOULD ACTUALLY HAVE TO INTEGRATE, on the
maintainer's own four rungs. Measured, not assumed.

Immersed / unfitted FEA (CutFEM, the Finite Cell Method) integrates a boundary
cell only over its MATERIAL SIDE and leaves interior cells identical. That needs
two things the brief takes for granted:

  1. a boundary cell that is actually CUT -- one holding a fraction of a cell of
     material. A cell that is entirely full or entirely empty has nothing to cut,
     and integrating it "only over its material side" IS the current scheme.
  2. a GEOMETRIC interface to cut along. A SIMP density rho in (0,1) is not a
     geometry; it is a stiffness weight. The only geometry the design carries is
     the 0.5 level set of the trilinearly-interpolated density -- the same surface
     marching cubes extracts for the exported mesh.

So this script measures both, per rung:

  * how many cells in the INTERFACE BAND (printed boundary cells plus the void-side
    skin) hold a strictly fractional density at all;
  * for every band cell, the volume fraction of the cell lying on the material side
    of the trilinear 0.5 level set -- `cut_frac`, exactly what a cut-cell quadrature
    would integrate over -- by k^3 sub-sampling of the same interpolant;
  * the gap between that and what the pipeline does today. Today a printed cell
    contributes its WHOLE volume to mass and E*rho^3 over its whole volume to
    stiffness; a cut cell would contribute cut_frac of both. The difference,
    summed, is the volume a cut-cell scheme would move -- in mm^3 and as a
    percentage of the printed volume.

  python3 s2_cut_population.py <design.bin> [subsamples_per_axis]
"""
import struct, sys
import numpy as np

path = sys.argv[1]
K = int(sys.argv[2]) if len(sys.argv) > 2 else 8      # sub-samples per axis
ISO = 0.5

raw = open(path, 'rb').read()
o = 0
ver, = struct.unpack_from('<B', raw, o); o += 4
nx, ny, nz = struct.unpack_from('<iii', raw, o); o += 12
ox, oy, oz = struct.unpack_from('<ddd', raw, o); o += 24
sp, = struct.unpack_from('<d', raw, o); o += 8
nvar, _ = struct.unpack_from('<ii', raw, o); o += 8
print(f"design.bin v{ver}  grid {nx}x{ny}x{nz}  spacing {sp:.10f} mm  variants {nvar}")
print(f"sub-sampling the trilinear interpolant at {K}^3 = {K**3} points per cell")
print()

# sample offsets t in (-0.5, 0.5), cell-centred, midpoint rule
t = (np.arange(K) + 0.5) / K - 0.5

for v in range(nvar):
    rq, ach, mw, me, mvm = struct.unpack_from('<ddddd', raw, o); o += 40
    o += 8 + 24 + 8 + 8
    n, = struct.unpack_from('<q', raw, o); o += 8
    f = np.frombuffer(raw, dtype='<f8', count=n, offset=o).reshape((nz, ny, nx)); o += 8 * n

    printed = f > ISO
    # padded with the VOID background, which is marching cubes' own rule
    P = np.zeros((nz + 2, ny + 2, nx + 2), bool); P[1:-1, 1:-1, 1:-1] = printed
    allnb = (P[0:-2, 1:-1, 1:-1] & P[2:, 1:-1, 1:-1] & P[1:-1, 0:-2, 1:-1] &
             P[1:-1, 2:, 1:-1] & P[1:-1, 1:-1, 0:-2] & P[1:-1, 1:-1, 2:])
    anynb = (P[0:-2, 1:-1, 1:-1] | P[2:, 1:-1, 1:-1] | P[1:-1, 0:-2, 1:-1] |
             P[1:-1, 2:, 1:-1] | P[1:-1, 1:-1, 0:-2] | P[1:-1, 1:-1, 2:])
    boundary = printed & ~allnb
    skin = (~printed) & anynb
    band = boundary | skin

    # density padded with 0.0 outside -- the same background the level set sees
    D = np.zeros((nz + 2, ny + 2, nx + 2)); D[1:-1, 1:-1, 1:-1] = f
    idx = np.argwhere(band)                      # (m, 3) in (k, j, i)
    m = len(idx)
    kk, jj, ii = idx[:, 0] + 1, idx[:, 1] + 1, idx[:, 2] + 1
    # the 3x3x3 neighbourhood of every band cell, gathered once
    nbh = np.empty((3, 3, 3, m))
    for a in (-1, 0, 1):
        for b in (-1, 0, 1):
            for c in (-1, 0, 1):
                nbh[a + 1, b + 1, c + 1] = D[kk + a, jj + b, ii + c]

    # trilinear at cell-local offset t: on each axis the sample lies between the
    # centre and ONE neighbour, so the stencil is two of the three gathered planes
    inside = np.zeros(m, dtype=np.int64)
    for tz in t:
        az, wz = (0, tz + 1.0) if tz < 0 else (2, tz)   # far plane index, weight
        for ty in t:
            ay, wy = (0, ty + 1.0) if ty < 0 else (2, ty)
            for tx in t:
                ax, wx = (0, tx + 1.0) if tx < 0 else (2, tx)
                # gather the 8 corners: axis index 1 is the cell's own centre
                val = 0.0
                for sz, cz in ((1, 1.0 - wz), (az, wz)):
                    for sy, cy in ((1, 1.0 - wy), (ay, wy)):
                        for sx, cx in ((1, 1.0 - wx), (ax, wx)):
                            val = val + (cz * cy * cx) * nbh[sz, sy, sx]
                inside += (val > ISO)
    cut = inside / float(K ** 3)

    band_printed = printed[band]                  # what the pipeline counts today
    grey = (f[band] > 0.05) & (f[band] < 0.95)
    vol = sp ** 3

    print(f"--- rung vf={rq:.2f}   recorded peak vM {mvm:.10g} MPa, margin {mw:.6f}")
    print(f"    printed cells {printed.sum()}   interface band {m} "
          f"(boundary {boundary.sum()} + void-side skin {skin.sum()})")
    print(f"    band cells holding a STRICTLY FRACTIONAL density in (0.05,0.95): "
          f"{grey.sum()} ({100*grey.sum()/m:.3f}%)")
    print(f"    -> a cut-cell scheme has {'SOMETHING' if grey.sum() > 0.01*m else 'ESSENTIALLY NOTHING'} "
          f"to integrate partially on this rung's density")
    # what the level set says, which is the geometry a cut scheme would use
    fully_in = (cut > 0.999).sum(); fully_out = (cut < 0.001).sum()
    partial = m - fully_in - fully_out
    print(f"    by the TRILINEAR 0.5 LEVEL SET (the surface the export already uses):")
    print(f"      band cells fully inside {fully_in}, fully outside {fully_out}, "
          f"genuinely CUT {partial} ({100*partial/m:.3f}%)")
    if partial:
        cp = cut[(cut > 0.001) & (cut < 0.999)]
        print(f"      cut fraction over those: min {cp.min():.4f} median "
              f"{np.median(cp):.4f} max {cp.max():.4f}")
    dv = (cut - band_printed).sum() * vol
    print(f"    VOLUME a cut-cell scheme would MOVE, over the whole band:")
    print(f"      sum(cut_frac) {cut.sum():.2f} cells vs sum(printed) "
          f"{band_printed.sum()} cells -> {dv:+.3f} mm^3 "
          f"({100*(cut.sum()-band_printed.sum())/printed.sum():+.4f}% of printed volume)")
    per = np.abs(cut - band_printed)
    print(f"      per-cell |cut_frac - printed|: mean {per.mean():.4f}, "
          f"p99 {np.percentile(per,99):.4f}, max {per.max():.4f}")
    print(f"      cells the two disagree about by more than half a cell: "
          f"{(per>0.5).sum()} ({100*(per>0.5).sum()/m:.3f}%)")
    print()
