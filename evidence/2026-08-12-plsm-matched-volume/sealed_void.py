#!/usr/bin/env python3
"""★ SEALED VOID AS A PRINTABILITY NUMBER, not as the probe measures it.

`plsm_topology.hpp`'s `in_region` is `tags != Empty && eff == Active`, so the
FROZEN region counts as outside-the-region and a void pocket walled in by frozen
solid is scored OPEN. That is the right convention for the optimiser, which only
reasons about the active set. It is the WRONG one for manufacturing: powder does
not pass through a bolt boss.

Here the region is the whole part (SIMP's own non-zero density, 110,904 voxels)
and 'outside' is only the true exterior. Void is 6-connected, because solid is
26-connected in this repository (PR 305).
"""
import numpy as np, scipy.ndimage as ndi, sys, os
H = os.path.dirname(os.path.abspath(__file__))
nx, ny, nz, h = 128, 31, 118, 1.7052793026343613
vvol = h ** 3
simp = np.fromfile(f'{H}/sources/rung_0.68.f64').reshape(nz, ny, nx)
inpart = simp > 1e-6
st6 = ndi.generate_binary_structure(3, 1)
outside = ~inpart
print(f"part {int(inpart.sum())} voxels, voxel {vvol:.4f} mm3")
print(f"{'arm':12s} {'void':>8s} {'sealed':>7s} {'sealed mm3':>11s} {'% void':>8s} {'n':>4s}")
for a in sys.argv[1:]:
    f = f'{H}/arms/{a}/snap/it0060.f64'
    if not os.path.exists(f):
        print(f"{a:12s} (no it0060)"); continue
    occ = np.fromfile(f).reshape(nz, ny, nx)
    void = inpart & (occ <= 0.5)
    lab, nc = ndi.label(void, structure=st6)
    openids = set(np.unique(lab[ndi.binary_dilation(outside, structure=st6) & void])) - {0}
    sizes = np.bincount(lab.ravel(), minlength=nc + 1)
    sealed = [i for i in range(1, nc + 1) if i not in openids]
    sv = int(sizes[sealed].sum()) if sealed else 0
    tv = int(void.sum())
    print(f"{a:12s} {tv:8d} {sv:7d} {sv * vvol:11.1f} {sv / max(tv,1) * 100:7.2f}% {len(sealed):4d}")
