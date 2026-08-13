#!/usr/bin/env python3
"""★ SEALED VOID, CORRECTED — v1 over-counted by treating grid-boundary voxels
as enclosed.

v1 (`evidence/2026-08-12-*/sealed_void.py`) defined 'exterior' as ONLY the
outside-the-part set. ★ THAT IS WRONG WHERE THE PART TOUCHES THE GRID BOUNDARY,
and on this part 15,099 voxels do. A void voxel on the grid face is on the part's
own surface and is open to atmosphere.

★ BOTH the harness (`plsm_topology.hpp`) and PRODUCTION agree on the correct
rule. `core/src/mesh/lattice_void.cpp:128` states it: "A component touching any
face reaches the exterior (everything outside the grid is exterior)." v1 was the
outlier, and it was mine.

Verified: with the grid-face term added, this reproduces the C++ column exactly
on X_robust_recheck (2250 voxels / 16 pockets, against v1's 3338 / 19).
"""
import numpy as np, scipy.ndimage as ndi, sys, os
nz, ny, nx, h = 118, 31, 128, 1.7052793026343613
vv = h ** 3
REPO = '/Users/nadim/dev/TopOpt/TopOpt/.claude/worktrees/lattice-page-core-hookup-bf5ecc'
simp = np.fromfile(f'{REPO}/evidence/2026-08-12-plsm-penalty-production/sources/rung_0.68.f64').reshape(nz, ny, nx)
inpart = simp > 1e-6
st6 = ndi.generate_binary_structure(3, 1)
outside = ~inpart
border = np.zeros_like(inpart)
border[0] = border[-1] = True
border[:, 0] = border[:, -1] = True
border[:, :, 0] = border[:, :, -1] = True

def measure(path):
    occ = np.fromfile(path).reshape(nz, ny, nx)
    void = inpart & (occ <= 0.5)
    lab, nc = ndi.label(void, structure=st6)
    open_ids = set(np.unique(lab[ndi.binary_dilation(outside, structure=st6) & void])) - {0}
    open_ids |= set(np.unique(lab[border & void])) - {0}      # ★ the grid-face term v1 lacked
    sz = np.bincount(lab.ravel(), minlength=nc + 1)
    sealed = [i for i in range(1, nc + 1) if i not in open_ids]
    sv = int(sz[sealed].sum()) if sealed else 0
    return int(void.sum()), sv, len(sealed)

print(f"{'arm':14s} {'snap':>7s} {'void':>7s} {'sealed':>7s} {'mm3':>10s} {'% void':>7s} {'n':>4s}")
for spec in sys.argv[1:]:
    label, path = spec.split('=', 1)
    if not os.path.exists(path):
        print(f"{label:14s} (missing {path})"); continue
    tv, sv, n = measure(path)
    print(f"{label:14s} {os.path.basename(path)[:7]:>7s} {tv:7d} {sv:7d} {sv*vv:10.1f} {sv/max(tv,1)*100:6.2f}% {n:4d}")
