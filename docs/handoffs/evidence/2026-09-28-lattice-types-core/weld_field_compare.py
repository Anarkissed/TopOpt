#!/usr/bin/env python3
"""Is the stress FIELD the same under the two weld rules, or did the mechanics change?

The three statistics in weld_statistic.py answer "is the margin shift an artefact of
counting one sample per member". They cannot answer "did the structure get stiffer or
softer", because every one of them is still a summary of the same population.

This compares the two rules' fields at FIXED PLACES instead: bin each piece by the
position of its midpoint and take the LENGTH-WEIGHTED MEAN stress in each bin, which is
a property of the stress field and not of how finely the bin's struts were cut.  If the
two rules agree bin by bin, nothing mechanical changed and the margin shift is entirely
in the statistic.  If they disagree, the shift is at least partly real -- and the bins
that disagree say where.

Usage: weld_field_compare.py <global dump> <per-strut dump> [bin_mm]
"""
import math
import sys


def field(path, bin_mm):
    num, den, peak = {}, {}, {}
    with open(path) as fh:
        for line in fh:
            if not line.startswith("SEG "):
                continue
            f = line.split()
            ax, ay, az, bx, by, bz, r, s = (float(v) for v in f[1:9])
            if s <= 0.0:
                continue
            L = math.dist((ax, ay, az), (bx, by, bz))
            k = (int((ax + bx) / 2 // bin_mm), int((ay + by) / 2 // bin_mm),
                 int((az + bz) / 2 // bin_mm))
            num[k] = num.get(k, 0.0) + s * L
            den[k] = den.get(k, 0.0) + L
            peak[k] = max(peak.get(k, 0.0), s)
    return ({k: num[k] / den[k] for k in num}, peak, den)


def main(pa, pb, bin_mm=8.0):
    a, pka, la = field(pa, bin_mm)
    b, pkb, lb = field(pb, bin_mm)
    shared = sorted(set(a) & set(b))
    ta, tb = math.fsum(la.values()), math.fsum(lb.values())
    # ── CONTROL 1: the two rules cut the SAME struts, so TOTAL strut length is a
    # geometric invariant. If this does not hold, the dumps are not of one geometry
    # and nothing below means anything.
    print(f"control 1: total strut length {ta:.1f} mm vs {tb:.1f} mm "
          f"({(tb/ta-1)*100:+.4f}%) -- must be ~0")
    # ── THE ONE NUMBER THAT NEEDS NO BINNING. A LENGTH-weighted mean over the whole
    # pocket is an estimate of the length-average of the stress FIELD: subdividing a
    # strut more finely adds samples but does not change the average it estimates.
    # So a difference here is a difference in the field, not in how it was sampled.
    ma = math.fsum(a[k] * la[k] for k in a) / ta
    mb = math.fsum(b[k] * lb[k] for k in b) / tb
    print(f"whole-pocket LENGTH-weighted mean stress: global {ma:.5f} MPa, "
          f"per-strut {mb:.5f} MPa  ({(mb/ma-1)*100:+.2f}%)")
    # ── CONTROL 2: a piece is binned by its MIDPOINT, so a bin holding few pieces can
    # gain or lose one when the pieces change length. Such a bin is not comparable.
    # Bins are kept only where the length control holds within 1%, and the fraction of
    # the part's length that those bins carry is reported: the agreement figures below
    # describe THAT fraction and no more.
    ok = [k for k in shared if abs(la[k] - lb[k]) / max(la[k], 1e-12) < 0.01]
    cov = math.fsum(la[k] for k in ok) / ta
    print(f"control 2: {len(ok)}/{len(shared)} shared {bin_mm:g} mm bins have matching "
          f"strut length within 1%, carrying {cov*100:.1f}% of the total length")
    if not ok:
        print("  no comparable bins: the field comparison is not available at this bin size")
        return
    rows = sorted(((b[k] - a[k]) / max(a[k], 1e-12), k) for k in ok)
    within = sum(1 for d, _ in rows if abs(d) < 0.05)
    print(f"of those bins, mean stress agrees within 5%: {within}/{len(ok)} "
          f"({within/len(ok)*100:.1f}%)")
    print("most changed comparable bins (length-weighted mean, global -> per-strut):")
    for d, k in rows[:3] + rows[-3:]:
        print(f"  bin {k}  {a[k]:.5f} -> {b[k]:.5f} MPa  ({d*100:+.1f}%)  "
              f"peak {pka[k]:.4f} -> {pkb[k]:.4f}")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2],
         float(sys.argv[3]) if len(sys.argv) > 3 else 8.0)
