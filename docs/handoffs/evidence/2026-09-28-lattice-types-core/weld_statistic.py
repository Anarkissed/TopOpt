#!/usr/bin/env python3
"""Why the margin moved when the weld piece changed: the statistic, or the mechanics?

Reads core's own per-member dump (TOPOPT_ORGANIC_STRESS_DUMP, written by
certify_organic_structural for the GOVERNING load case) and recomputes the verdict
statistic three ways.  Core is not changed and not asked anything new: every number
here comes out of the dump core already writes.

  SEG ax ay az bx by bz radius stress stress_distributed knockdown

The certificate's verdict statistic (beam_network.cpp:2966-2999) is the p99 of the
RATIO stress/(allowable*knockdown) taken over members, ONE SAMPLE PER MEMBER
irrespective of how long that member is.  margin = 1/ratio_p99.  That is the quantity
under suspicion, so it is the quantity recomputed: unweighted (core's own), weighted by
element LENGTH, and weighted by element VOLUME (pi r^2 L).

Weighted percentile: sort ascending by value, accumulate weight, take the first value
whose cumulative weight reaches 0.99 of the total.  The "unweighted (same rule)" column
applies that identical rule with every weight 1, so the three are like for like;
"unweighted (core)" uses core's own truncated-index convention and is the CONTROL --
it must reproduce the printed p99 and margin, or this script is wrong and nothing
below it means anything.
"""
import math
import sys

ALLOWABLE_MPA = 55.0   # the probe's call: certify_organic_structural(..., 55.0, 0.8, ...)


def read(path):
    rows = []
    with open(path) as fh:
        for line in fh:
            if not line.startswith("SEG "):
                continue
            f = line.split()
            ax, ay, az, bx, by, bz, r, s, _sd, kd = (float(v) for v in f[1:11])
            # Core's population: members carrying something.  A member at exactly 0.0
            # is excluded there (and its exclusion is reported as zero_stress_fraction),
            # so it is excluded here.  Dropped members are not in the dump's columns;
            # every run analysed reported dropped 0, which is why that is sound.
            if s <= 0.0:
                continue
            L = math.dist((ax, ay, az), (bx, by, bz))
            rows.append((s / (ALLOWABLE_MPA * kd), s, L, math.pi * r * r * L, r))
    return rows


def wq(vals_weights, f=0.99):
    """First value whose cumulative weight reaches f of the total."""
    v = sorted(vals_weights)
    tot = math.fsum(w for _, w in v)
    if tot <= 0.0:
        return float("nan")
    target, acc = f * tot, 0.0
    for val, w in v:
        acc += w
        if acc >= target:
            return val
    return v[-1][0]


def core_q(vals, f=0.99):
    """Core's convention: v[(size_t)(f * (n-1))] into the sorted vector."""
    v = sorted(vals)
    return v[int(f * (len(v) - 1))]


def main(paths):
    print(f"{'plan/rule':<18} {'members':>9} {'max':>8} {'p99 core':>9} "
          f"{'p99 same':>9} {'p99 byL':>9} {'p99 byV':>9}   (margins) "
          f"{'max':>7} {'core':>7} {'same':>7} {'byL':>7} {'byV':>7}")
    for p in paths:
        rows = read(p)
        ratio = [r[0] for r in rows]
        name = p.split("dump_")[-1].replace(".txt", "")
        mx = max(ratio)
        q_core = core_q(ratio)
        q_same = wq([(r[0], 1.0) for r in rows])
        q_len = wq([(r[0], r[2]) for r in rows])
        q_vol = wq([(r[0], r[3]) for r in rows])
        s_core = core_q([r[1] for r in rows])
        print(f"{name:<18} {len(rows):>9,} {mx:>8.4f} {q_core:>9.4f} "
              f"{q_same:>9.4f} {q_len:>9.4f} {q_vol:>9.4f}            "
              f"{1/mx:>7.1f} {1/q_core:>7.1f} {1/q_same:>7.1f} "
              f"{1/q_len:>7.1f} {1/q_vol:>7.1f}")
        print(f"{'':<18} control: stress p99 (core rule) {s_core:.4g} MPa, "
              f"stress max {max(r[1] for r in rows):.4g} MPa -- must match the probe's "
              f"printed p99/max; margin {1/q_core:.4g} must match its printed margin")
        # The mechanism the statistic hypothesis rests on: whether the two rules give
        # the thick struts a different share of the samples.
        byr = {}
        for _, _, L, _v, r in rows:
            k = round(r, 4)
            a, b = byr.get(k, (0, 0.0))
            byr[k] = (a + 1, b + L)
        tot_n = sum(a for a, _ in byr.values())
        tot_l = math.fsum(b for _, b in byr.values())
        parts = [f"r{k}: {a/tot_n:.3f} of members / {b/tot_l:.3f} of length "
                 f"(mean piece {b/a:.4g} mm)" for k, (a, b) in sorted(byr.items())]
        print(f"{'':<18} " + "; ".join(parts))


if __name__ == "__main__":
    main(sys.argv[1:])
