#!/usr/bin/env python3
"""R1 — THE MESHES MOVED, AND ONLY IN THE WAY THIS FIX IS ALLOWED TO MOVE THEM.

    python3 r1_geometry_unchanged.py <before.stl> <after.stl>

"The bytes differ" is not a bar — every wrong change also makes the bytes differ.
The claim this fix has to earn is much narrower:

  ★ THE SET OF TRIANGLES IS IDENTICAL; each one is either UNCHANGED or has its
    last two vertices SWAPPED. No vertex moved, none appeared, none vanished.

That is provable rather than eyeballable, so it is proved here: each facet is
reduced to its three vertices, and the after-mesh's multiset of facets is matched
against the before-mesh's, counting how many matched in the same rotation
(unchanged winding) and how many matched only when reversed (flipped winding).
Anything that matches neither is geometry that MOVED, and is reported.

★ THE BAR IS `unmatched == 0`. That is the exact, unambiguous claim: the multiset
of facets, taken up to orientation, is identical.

The same/flipped SPLIT is reported alongside it as information, not as a bar. It
is expected to be mixed on a latticed file — the strut prisms and rim tori flip
while the node icosahedra do not, because the icosahedron table was already
outward — so a lattice mesh reporting 100% flipped would mean the node balls had
been wrongly flipped too. But the split is NOT asserted to equal any particular
primitive count: a facet that collapses to a degenerate triple under the 1e-4
quantisation is symmetric and lands in "same" regardless of how it was wound, so
attributing the split exactly would be reading more into it than it carries.

Facet vertices are compared after rounding to 1e-4 mm, far below the print
resolution and far above float32 STL round-off.
"""
import struct
import sys
from collections import Counter


def read_binary_stl(path):
    with open(path, "rb") as f:
        data = f.read()
    n = struct.unpack("<I", data[80:84])[0]
    out = []
    for i in range(n):
        o = 84 + i * 50
        f12 = struct.unpack_from("<12f", data, o)
        out.append((f12[3:6], f12[6:9], f12[9:12]))
    return out


def q(v):
    return tuple(round(c / 1e-4) for c in v)


def canon_rotations(t):
    """The three rotations of a triangle — same winding, same facet."""
    a, b, c = q(t[0]), q(t[1]), q(t[2])
    return min([(a, b, c), (b, c, a), (c, a, b)])


def canon_reversed(t):
    a, b, c = q(t[0]), q(t[1]), q(t[2])
    return min([(a, c, b), (c, b, a), (b, a, c)])


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    before, after = sys.argv[1], sys.argv[2]
    tb, ta = read_binary_stl(before), read_binary_stl(after)
    print(f"  before {before.split('/')[-1]}: {len(tb)} facets")
    print(f"  after  {after.split('/')[-1]}: {len(ta)} facets")
    if len(tb) != len(ta):
        print("  ★ FAIL — facet COUNT changed; this fix may not add or remove geometry")
        return 1

    pool = Counter(canon_rotations(t) for t in tb)
    same = flipped = unmatched = 0
    for t in ta:
        k = canon_rotations(t)
        if pool.get(k):
            pool[k] -= 1
            same += 1
            continue
        r = canon_reversed(t)
        if pool.get(r):
            pool[r] -= 1
            flipped += 1
            continue
        unmatched += 1

    print(f"  facets matched with the SAME winding : {same}")
    print(f"  facets matched only REVERSED         : {flipped}")
    print(f"  facets that matched NEITHER          : {unmatched}")
    ok = unmatched == 0 and flipped > 0
    print("  BAR     every facet is the same triangle, unchanged or reversed; "
          "at least one reversed (else the fix did nothing)")
    print("  VERDICT " + ("HOLDS — geometry identical, orientation corrected"
                          if ok else "★ FAILS"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
