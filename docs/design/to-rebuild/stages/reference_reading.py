#!/usr/bin/env python3
"""What a stress reading over a size SHOULD give on tests E's two textbook cases.

The reading (stress_measure.hpp) is the average of the von Mises stress over the
material inside a ball of a stated diameter, and the number reported is the
largest such average. This script takes the same average on the EXACT solutions
(Kirsch for the plate with a hole, finite-width factor 3.03 / 3; Lame for the
thick ring, plane stress), so a measured reading can be judged against the
reading's own true value and not against the peak, which an average is below by
design. Hole / inner radius 6 mm, ring outer radius 12 mm, far stress / pressure 1.

    python3 reference_reading.py
"""
import numpy as np


def ball_reference(vm, inside, centres, diameter, thickness):
    radius = diameter / 2
    xs = np.linspace(-radius, radius, 61)
    X, Y = np.meshgrid(xs, xs)
    rho2 = X**2 + Y**2
    in_ball = rho2 <= radius * radius
    # The ball's chord through a plate of the given thickness, centred mid-plane.
    w = np.where(in_ball, np.minimum(thickness, 2 * np.sqrt(np.maximum(radius * radius - rho2, 0))), 0.0)
    best = 0.0
    for cx, cy in centres:
        px, py = cx + X, cy + Y
        m = inside(px, py) & in_ball
        if m.any():
            best = max(best, float((vm(px, py) * w * m).sum() / (w * m).sum()))
    return best


A = 6.0


def kirsch_vm(x, y):
    r = np.maximum(np.hypot(x, y), A)
    th = np.arctan2(y, x)
    q = A * A / r**2
    c2, s2 = np.cos(2 * th), np.sin(2 * th)
    srr = 0.5 * (1 - q) + 0.5 * (1 - 4 * q + 3 * q * q) * c2
    stt = 0.5 * (1 + q) - 0.5 * (1 + 3 * q * q) * c2
    srt = -0.5 * (1 + 2 * q - 3 * q * q) * s2
    return np.sqrt(srr**2 + stt**2 - srr * stt + 3 * srt**2) * (3.03 / 3.0)


RI, RO = 6.0, 12.0


def lame_vm(x, y):
    r = np.clip(np.hypot(x, y), RI, RO)
    k = RI * RI / (RO * RO - RI * RI)
    st, sr = k * (1 + RO * RO / r**2), k * (1 - RO * RO / r**2)
    return np.sqrt(st**2 + sr**2 - st * sr)


if __name__ == "__main__":
    for name, vm, inside, at, peak in (
        ("plate with a hole", kirsch_vm, lambda x, y: np.hypot(x, y) >= A, lambda e: (0.0, A + e), 3.03),
        ("ring under pressure", lame_vm, lambda x, y: (np.hypot(x, y) >= RI) & (np.hypot(x, y) <= RO),
         lambda e: (RI + e, 0.0), 7.0 / 3.0),
    ):
        print(f"{name}: textbook peak {peak:.3f}")
        for d in (0.9, 1.8, 3.6):
            centres = [at(e) for e in np.linspace(0.0, d, 25)]
            # Plate two voxels thick at hole radius 3, 4, 5, 6 voxels (voxel 2.0 to 1.0 mm).
            vals = [ball_reference(vm, inside, centres, d, 2 * 6.0 / rv) for rv in (3, 4, 5, 6)]
            print(f"  read over {d} mm: " + " / ".join(f"{v:.3f}" for v in vals))
