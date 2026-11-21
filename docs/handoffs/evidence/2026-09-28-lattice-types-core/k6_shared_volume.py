#!/usr/bin/env python3
"""K6: does the shared volume hold ONE region's lattice only?

Ruling 4 said "in the shared space, only the owner's lattice is laid". Core laid both whole
cells and nothing clipped; a byte-identical STL under reversed declaration order proves
ownership is ORDER-INDEPENDENT, which says nothing about which region's struts occupy the
overlap. This measures the overlap itself.

The straddler fixture: region 1's cell spans x[4.5,10.5] y[0,6], region 2's spans x[0,6]
y[4.5,10.5], both z[6.5,12.5]. They share x[4.5,6] y[4.5,6] z[6.5,12.5].

Ownership is the nearer FACE PLANE: region 1's is y = 0, region 2's is x = 0. So inside the
shared box a point with x > y is nearer region 1's plane and a point with x < y is nearer
region 2's; the diagonal x = y is the seam (an exact tie goes to the lower region id).

So the test is not "the box is empty" -- both regions legitimately reach into it -- but that
each region's struts stay on ITS OWN SIDE of that diagonal. Run with the three output
directories: the seam job (both cells) and each cell alone.
"""
import struct
import sys


def tris(path):
    with open(path, "rb") as f:
        head = f.read(84)
        n = struct.unpack("<I", head[80:84])[0]
        out = []
        for _ in range(n):
            rec = f.read(50)
            if len(rec) < 50:
                break
            v = struct.unpack("<12f", rec[:48])
            out.append(((v[3], v[4], v[5]), (v[6], v[7], v[8]), (v[9], v[10], v[11])))
        return out


BOX = ((4.5, 6.0), (4.5, 6.0), (6.5, 12.5))


def in_box(p):
    return all(BOX[i][0] - 1e-9 <= p[i] <= BOX[i][1] + 1e-9 for i in range(3))


def classify(path, label):
    t = tris(path)
    inside = [tr for tr in t if any(in_box(v) for v in tr)]
    # which side of the diagonal each triangle's centroid sits on
    r1_side = r2_side = seam = 0
    for tr in inside:
        cx = sum(v[0] for v in tr) / 3.0
        cy = sum(v[1] for v in tr) / 3.0
        if cx - cy > 1e-6:
            r1_side += 1            # nearer y = 0: region 1 owns
        elif cy - cx > 1e-6:
            r2_side += 1            # nearer x = 0: region 2 owns
        else:
            seam += 1
    print(f"{label:22s} triangles {len(t):7d} | touching the shared box {len(inside):6d} "
          f"| region-1 side {r1_side:5d} | region-2 side {r2_side:5d} | on the seam {seam:4d}")
    return len(t), len(inside), r1_side, r2_side


def main(seam_dir, only1_dir, only2_dir):
    import glob
    def one(d):
        g = glob.glob(d + "/*lattice*.stl")
        if not g:
            raise SystemExit("no lattice STL in " + d)
        return g[0]
    print("The shared box is x[4.5,6] y[4.5,6] z[6.5,12.5]; the owner's diagonal is x = y.")
    b = classify(one(seam_dir), "seam (both cells)")
    o1 = classify(one(only1_dir), "region 1's cell alone")
    o2 = classify(one(only2_dir), "region 2's cell alone")
    print()
    # The property: in the shared box, the seam run carries region 1's struts only where
    # region 1 owns, and region 2's only where region 2 owns. Unclipped, each region's cell
    # fills the whole box, so the seam run would carry BOTH on BOTH sides.
    print(f"unclipped would be at least the sum of the single-cell boxes: "
          f"{o1[1]} + {o2[1]} = {o1[1] + o2[1]}; the seam run has {b[1]}")
    if b[1] < o1[1] + o2[1]:
        print("=> the shared volume is CLIPPED: the seam run carries fewer triangles there "
              "than the two cells do separately")
    else:
        print("=> NOT clipped: the seam run carries as much as both cells together")


if __name__ == "__main__":
    main(*sys.argv[1:4])
