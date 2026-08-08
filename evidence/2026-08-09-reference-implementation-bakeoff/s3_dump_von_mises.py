#!/usr/bin/env python3
"""Dump a variant's per-voxel von Mises field out of a `fields.bin` as raw
float64, so S3's PicoGK arm can be driven by a field that actually VARIES.

The format is core/include/topopt/fields.hpp's documented v1 layout, read here
rather than through core because nothing else in this task needs a C++ reader
and the layout is fully specified in that header.

★ WHICH RUN THIS COMES FROM, AND WHY IT IS NOT THE SIMP ARM'S. PR 319's SIMP run
did not commit its fields.bin. The one used here is the MULTISCALE sibling —
evidence/2026-08-03-multiscale-lattice-to/m2_multiscale_final/fields.bin, the
same job document with `lattice.multiscale: true`, on the SAME grid (128 x 31 x
118, same origin and spacing). Its stress values are therefore NOT the SIMP
arm's, and no number derived from it is quoted as his. It is used for one thing
only: to give the grading mechanism a field with real spatial variation, so S3(b)
can tell "the tool cannot grade continuously" apart from "the field it was given
is binary". Both readings are reported.
"""
import struct, sys, array

def main(path, want_vf, out):
    b = open(path, "rb").read()
    o = 0
    ver, = struct.unpack_from("<B", b, o); o += 4
    assert ver == 1, f"fields.bin version {ver}, expected 1"
    nx, ny, nz = struct.unpack_from("<iii", b, o); o += 12
    ox, oy, oz, sp, vv = struct.unpack_from("<ddddd", b, o); o += 40
    nvar, _ = struct.unpack_from("<ii", b, o); o += 8
    n = nx * ny * nz
    print(f"grid {nx} x {ny} x {nz}, spacing {sp!r}, origin ({ox!r}, {oy!r}, {oz!r})")
    print(f"variants {nvar}")
    for v in range(nvar):
        vf, mass = struct.unpack_from("<dd", b, o); o += 16
        sup, _ = struct.unpack_from("<ii", b, o); o += 8
        nvm, nst, ndi = struct.unpack_from("<qqq", b, o); o += 24
        vm = array.array("f"); vm.frombytes(b[o:o + 4 * nvm]); o += 4 * nvm
        o += 4 * nst + 4 * ndi
        lo, hi = (min(vm), max(vm)) if nvm else (0, 0)
        hit = abs(vf - want_vf) < 1e-9
        print(f"  vf {vf:.4f}  mass {mass:.3f} g  von Mises {nvm} "
              f"[{lo:.6g}, {hi:.6g}] MPa  disp {ndi}{'   <== dumped' if hit else ''}")
        if hit:
            assert nvm == n, f"von Mises count {nvm} != {n} voxels"
            out_arr = array.array("d", vm)
            with open(out, "wb") as f:
                out_arr.tofile(f)
            nz_count = sum(1 for x in vm if x > 0)
            print(f"    wrote {out} ({len(out_arr)*8} bytes); "
                  f"{nz_count} of {n} voxels non-zero ({100*nz_count/n:.2f}%)")

if __name__ == "__main__":
    main(sys.argv[1], float(sys.argv[2]), sys.argv[3])
