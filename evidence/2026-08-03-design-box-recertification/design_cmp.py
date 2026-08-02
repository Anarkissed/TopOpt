# Voxel-classification comparator with a NEGATIVE-CONTROL FLOOR (PR 248's
# discipline): read two design.bin containers, report max |drho| and the number
# of voxels whose printed classification (rho >= 0.5) differs — then re-run the
# same comparison against a copy perturbed by exactly 1e-9 at the iso threshold,
# to prove the comparator can SEE a change that small.
import struct, sys

def read(path):
    d = open(path,'rb').read()
    off = 0
    ver, = struct.unpack_from('<B', d, off); off += 4
    assert ver == 1, ver
    nx, ny, nz = struct.unpack_from('<iii', d, off); off += 12
    ox, oy, oz, sp = struct.unpack_from('<dddd', d, off); off += 32
    nvar, _ = struct.unpack_from('<ii', d, off); off += 8
    variants = []
    for _ in range(nvar):
        rq, ach, mw, me, mv = struct.unpack_from('<ddddd', d, off); off += 40
        acc, it = struct.unpack_from('<ii', d, off); off += 8
        bx, by, bz = struct.unpack_from('<ddd', d, off); off += 24
        auto, baked = struct.unpack_from('<ii', d, off); off += 8
        fp, = struct.unpack_from('<Q', d, off); off += 8
        n, = struct.unpack_from('<q', d, off); off += 8
        rho = struct.unpack_from('<%dd' % n, d, off); off += 8*n
        variants.append(dict(rq=rq, mw=mw, acc=acc, fp=fp, rho=rho))
    return (nx,ny,nz,sp), variants

def compare(a, b, label):
    ga, va = a; gb, vb = b
    assert ga == gb, (ga, gb)
    print(f'  {label}: grid {ga[0]}x{ga[1]}x{ga[2]} @ {ga[3]:.6g} mm, {len(va)} variant(s)')
    worst = 0.0; flips = 0
    for x, y in zip(va, vb):
        for p, q in zip(x['rho'], y['rho']):
            dd = abs(p-q)
            if dd > worst: worst = dd
            if (p >= 0.5) != (q >= 0.5): flips += 1
    print(f'    max |d rho| = {worst:.3e}   classification flips (rho>=0.5) = {flips}')
    return worst, flips

head, new = sys.argv[1], sys.argv[2]
A = read(head); B = read(new)
compare(A, B, 'HEAD vs NEW')
# NEGATIVE CONTROL: nudge one voxel across the iso threshold by 1e-9 and re-compare.
import copy
C = (B[0], [dict(v) for v in B[1]])
v0 = C[1][0]; rho = list(v0['rho'])
# the voxel sitting CLOSEST to the iso from above: moving it 1e-9 below the
# threshold makes max |d rho| itself ~1e-9, so the floor is the thing tested.
idx = min((i for i, r in enumerate(rho) if r >= 0.5), key=lambda i: rho[i])
rho[idx] = rho[idx] - (rho[idx] - 0.5) - 1e-9
v0['rho'] = rho
w, f = compare(A, C, 'NEGATIVE CONTROL (one voxel moved 1e-9 below iso)')
print('    negative control ' + ('SEES the change (comparator is live)'
                                 if f >= 1 else '*** BLIND ***'))
