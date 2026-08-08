#!/usr/bin/env python3
"""S1 -- THE CENSUS THAT REFRAMES THE QUESTION.

The brief's premise is that "a boundary cell's material is smeared uniformly
across the cell: the cell knows HOW MUCH material it holds and nothing about
WHERE". That premise is only true of a cell holding a FRACTION of a cell of
material. A cell that is entirely full or entirely empty is not smeared at all --
its boundary lies exactly on the grid, and integrating it "only over its material
side" is what the current scheme already does.

So before measuring anything, measure that: per rung, how much of the interface
is actually grey. On the design's own lattice, restricted to the populations that
matter -- BOUNDARY (printed, with a face-neighbour not printed; off-grid reads as
void, marching cubes' own rule), INTERIOR (printed, all six face-neighbours
printed), and the void-side SKIN.

  python3 field_census.py <design.bin>
"""
import struct, sys
import numpy as np

p = sys.argv[1]
b = np.fromfile(p, dtype=np.uint8)
raw = b.tobytes()
o = 0
ver, = struct.unpack_from('<B', raw, o); o += 4
nx,ny,nz = struct.unpack_from('<iii', raw, o); o += 12
ox,oy,oz = struct.unpack_from('<ddd', raw, o); o += 24
spacing, = struct.unpack_from('<d', raw, o); o += 8
nvar, resv = struct.unpack_from('<ii', raw, o); o += 8
N = nx*ny*nz
print(f"design.bin v{ver}  grid {nx}x{ny}x{nz} = {N} voxels  spacing {spacing:.10f} mm  variants {nvar}")
print(f"grid extent: {nx*spacing:.4f} x {ny*spacing:.4f} x {nz*spacing:.4f} mm")
print()
ISO = 0.5
rows = []
for v in range(nvar):
    rq,ach,mw,me,mvm = struct.unpack_from('<ddddd', raw, o); o += 40
    acc,it = struct.unpack_from('<ii', raw, o); o += 8
    bx,by,bz = struct.unpack_from('<ddd', raw, o); o += 24
    auto,baked = struct.unpack_from('<ii', raw, o); o += 8
    fp, = struct.unpack_from('<Q', raw, o); o += 8
    n, = struct.unpack_from('<q', raw, o); o += 8
    d = np.frombuffer(raw, dtype='<f8', count=n, offset=o); o += 8*n
    f = d.reshape((nz,ny,nx))   # x fastest
    printed = f > ISO
    # BOUNDARY of the printed set: a printed voxel with >=1 face-neighbour not printed
    # (out of grid counts as not printed -- background is void, MC's own rule)
    pad = np.zeros((nz+2,ny+2,nx+2), dtype=bool)
    pad[1:-1,1:-1,1:-1] = printed
    nb = (pad[0:-2,1:-1,1:-1] & pad[2:,1:-1,1:-1] &
          pad[1:-1,0:-2,1:-1] & pad[1:-1,2:,1:-1] &
          pad[1:-1,1:-1,0:-2] & pad[1:-1,1:-1,2:])
    interior = printed & nb
    boundary = printed & ~nb
    npr = printed.sum(); nb_ = boundary.sum(); ni = interior.sum()
    def greyfrac(mask, lo, hi):
        x = f[mask]
        return ((x > lo) & (x < hi)).sum()
    print(f"--- rung vf={rq:.2f}  achieved {ach:.10f}  accepted={acc}  iters={it}  fp={fp}")
    print(f"    recorded: margin_worst={mw!r}  margin_eff={me!r}  max_vm={mvm!r} MPa")
    print(f"    printed voxels (rho>0.5): {npr}   boundary {nb_} ({100*nb_/npr:.2f}% of printed)   interior {ni}")
    for lo,hi,lbl in ((0.05,0.95,'(0.05,0.95)'),(0.01,0.99,'(0.01,0.99)'),(1e-6,1-1e-6,'(1e-6,1-1e-6)')):
        gb = greyfrac(boundary, lo, hi); gi = greyfrac(interior, lo, hi)
        # also grey among ALL voxels adjacent to the printed set (incl. sub-iso skin)
        print(f"      grey {lbl:16s}: boundary {gb:7d} ({100*gb/nb_:6.3f}% of bdry)   interior {gi:7d} ({100*gi/max(ni,1):6.3f}%)")
    # the SKIN on the void side: voxels <= iso with a printed face-neighbour
    padp = np.zeros((nz+2,ny+2,nx+2), dtype=bool); padp[1:-1,1:-1,1:-1] = printed
    anynb = (padp[0:-2,1:-1,1:-1] | padp[2:,1:-1,1:-1] |
             padp[1:-1,0:-2,1:-1] | padp[1:-1,2:,1:-1] |
             padp[1:-1,1:-1,0:-2] | padp[1:-1,1:-1,2:])
    skin = (~printed) & anynb
    ns = skin.sum()
    gs = ((f[skin] > 0.05)).sum()
    print(f"    void-side skin voxels: {ns}, of which rho>0.05: {gs} ({100*gs/max(ns,1):.3f}%)")
    # THE CUT-CELL POPULATION: cells whose density is strictly fractional at all
    # (anything a cut-cell scheme would integrate partially), on either side of iso
    band = boundary | skin
    for lo,hi,lbl in ((0.05,0.95,'(0.05,0.95)'),(0.01,0.99,'(0.01,0.99)')):
        x = f[band]; c = ((x>lo)&(x<hi)).sum()
        print(f"    INTERFACE band (bdry+skin, {band.sum()} cells): grey {lbl} = {c} ({100*c/band.sum():.3f}%)")
    rows.append((rq, npr, nb_, ni))
    print()
