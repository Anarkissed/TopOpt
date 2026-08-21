# Bridge-span coupon — how to print it and what to record

## What this settles

The GRADED scope was gated on a 45-degrees-from-vertical rule applied to STRUTS.
That rule is a heuristic for overhanging SURFACES. A strut between two anchored
nodes is a BRIDGE, and bridges are governed by unsupported SPAN, not angle. This
coupon measures where the real limit is, so the scope rests on a measurement
instead of on either my assumption or the literature's inherited convention.

## Print settings — keep them the same as the real part

* material PLA, the same spool/profile as the part
* extrusion width **0.42 mm** (the value the job states), layer height as normal
* **supports OFF** — the entire point is that these bridge unsupported
* no brim under the specimens beyond the base slabs already in the model
* do not "repair" the mesh: it is an interpenetrating triangle soup by design
  (that is how the shipped generator emits a lattice), so slicers should union it
  on load. It is NOT watertight and does not need to be.

## The layout

162 x 160 x 34 mm. Four rows:

| row | strut diameter | spans (mm) |
|---|---|---|
| A | 0.42 mm (band floor) | 1.41, 2.83, 5.66, 11.31, 16.97, 22.63 |
| B | 0.84 mm | same |
| C | 1.68 mm | same |
| D | **positive control** — 2x2x2 blocks at his run's own cell sizes and radii | 1.41, 2.83, 5.66 |

Row D is geometry already printed successfully. **If row D fails, the coupon or the
profile is wrong — stop and fix that before reading rows A-C.** That is the control
that keeps a bad print from being read as a real limit.

## Which struts to score

Each specimen is one octet cell. It carries struts at two angles: 45 degrees
(24 of 36) and horizontal (12 of 36). Score only the ones actually in mid air:

* **the four top-face horizontals** — the clearest bridge, printed last, easiest to
  measure droop on;
* **the four mid-height octahedron edges**.

**Ignore the four bottom-face horizontals** — they lie on the base slab and are not
bridges.

## What to record, per specimen

| | |
|---|---|
| completed? | did the bridge finish, or did it break/curl/pull loose |
| droop | max sag at mid-span, mm (calipers or a photo against a rule) |
| delivered diameter | measure the strut, compare to the nominal in the MAP |
| quality note | stringing, sagging strands, poor adhesion at the landing nodes |

The number that matters is **the largest span that still completes cleanly at each
diameter**. That single number replaces the 45-degree rule in the scope.

## What each outcome means

* **Everything to 22.63 mm prints** — the overhang constraint is a non-issue at
  lattice scale for FDM. The traced/graded method is NOT gated on self-support, my
  65 %-beyond-45-degrees figure is irrelevant to buildability, and the whole
  anisotropy cost (4-16x C33/C11, the tetragonal tensor, the certification
  extension) disappears with it.
* **It fails somewhere in the middle** — that span IS the constraint, expressed in
  mm rather than degrees. A traced lattice would then be gated on the distribution
  of unsupported SPAN, which is a different and much cheaper measurement than the
  one I ran, and the octet is unaffected either way (its spans are 1.41-5.66 mm on
  his part, well inside anything this coupon is likely to show).
* **Row A fails early but B and C hold** — the limit is diameter-dependent, and the
  band floor is the thing to watch rather than the span alone.

## Reproducing the coupon

`bridge_coupon.cpp`, linked against `libtopopt.a`. Every strut comes from the
shipped `generate_lattice` (octet), so what is on the plate is what production
emits. Only the base slabs are authored here. Deterministic: same arguments produce
a byte-identical STL.

    c++ -std=c++17 -O2 -I core/include bridge_coupon.cpp core/build-lg/libtopopt.a -o coupon
    ./coupon bridge_span_coupon.stl bridge_span_coupon_MAP.txt 0.42
