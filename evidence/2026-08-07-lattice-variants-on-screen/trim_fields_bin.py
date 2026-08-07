#!/usr/bin/env python3
"""trim_fields_bin.py — derive a REPOSITORY-SIZED fields.bin from a real one.

The maintainer's run wrote a 31 MB `out/fields.bin`: a v1 container (see
core/include/topopt/fields.hpp) holding, per accepted rung, the requested volume
fraction, the printed MASS, the support-voxel count, and then the per-voxel von
Mises / stress-tensor / per-node displacement arrays. The masses are 8 bytes each;
the arrays are the other 31 MB.

The app reads the mass from this container and NOTHING ELSE reads it for the
lattice work, so the fixture keeps the real header and the real per-rung scalars —
grid dims, spacing, voxel volume, requested VF, mass, support — and writes ZERO
LENGTH for the three overlay arrays. The result is a valid v1 container the app's
own `RemoteFieldsContainer.parse` accepts, carrying his real numbers, at 108 bytes
instead of 31 MB.

What this costs, stated plainly: a test using the trimmed container exercises the
mass path but NOT the stress/flex overlays, whose arrays are gone. Those overlays
have their own coverage (RemoteFieldsTests, ResultsRemoteFieldsTests) and are not
what this task is about.

Usage:  ./trim_fields_bin.py <real fields.bin> <output fields.bin>
"""
import struct
import sys


def main(src, dst):
    b = open(src, "rb").read()
    cur = 0
    version = b[0]
    if version != 1:
        raise SystemExit("unsupported fields.bin version %d" % version)
    # Run header (RemoteFields.swift / fields.hpp): u8 version + 3 reserved, 3×i32
    # grid, 3×f64 origin, f64 spacing, f64 voxel volume, i32 variant count,
    # 4 reserved = 64 bytes.
    head = b[0:64]
    cur = 64
    (nx, ny, nz) = struct.unpack_from("<iii", b, 4)
    (vcount,) = struct.unpack_from("<i", b, 56)

    out = bytearray(head)
    for _ in range(vcount):
        vf, mass = struct.unpack_from("<dd", b, cur); cur += 16
        (support,) = struct.unpack_from("<i", b, cur); cur += 4
        cur += 4                                              # reserved
        vm_n, st_n, disp_n = struct.unpack_from("<qqq", b, cur); cur += 24
        cur += 4 * (vm_n + st_n + disp_n)                     # skip the arrays
        out += struct.pack("<dd", vf, mass)
        out += struct.pack("<i", support)
        out += b"\0\0\0\0"
        out += struct.pack("<qqq", 0, 0, 0)                   # arrays: none
        print("  rung vf=%.4f mass=%.3f g support=%d "
              "(dropped %d vm + %d tensor + %d disp floats)"
              % (vf, mass, support, vm_n, st_n, disp_n))

    open(dst, "wb").write(bytes(out))
    print("grid %dx%dx%d, %d rungs: %d bytes -> %d bytes"
          % (nx, ny, nz, vcount, len(b), len(out)))


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    main(sys.argv[1], sys.argv[2])
