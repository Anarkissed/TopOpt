# ★ THE GRADED COUPON PRINTED. THE OVERHANG GATE IS REFUTED BY EXPERIMENT.

The maintainer printed `graded_flow_coupon` — the flowing lattice traced from his own
stress field, 342 curves, all three principal families, 0.80 mm struts at 3.0 mm
spacing, **supports off** — and it came out clean. Struts formed, structure intact,
nothing collapsed, no sagging failures.

## What this kills

| claim | status |
|---|---|
| "65.13 % of traced arc violates the 45 deg overhang limit, so graded is a no-go" | ★ **WRONG.** The 45 deg rule is a heuristic for overhanging SURFACES. A strut between two anchored nodes is a BRIDGE, governed by unsupported SPAN. The measurement was of ANGLE and never established buildability. |
| "self-supporting cells are therefore required" | **WITHDRAWN** — it followed from the above |
| "which forces a z-stretched cell, 4-16x C33/C11 anisotropy" | **WITHDRAWN** |
| "which forces a tetragonal tensor and a certification extension" | **WITHDRAWN** |
| "build direction becomes structural" | **WITHDRAWN** |

That whole cost structure rested on a rule taken from the brief and never tested. One
print removed it. The maintainer called it twice — first that he had printed a bridged
lattice successfully, then that a sample print should settle it rather than an
assumption — and was right both times.

**The longest unsupported run in this coupon is 41.78 mm** (median 3.41, p90 7.67).
It printed. So at 0.80 mm diameter the bridging limit is somewhere above 41.78 mm,
which is far beyond anything the octet path can produce (his part's octet spans are
1.41-5.66 mm).

## What survives, and what it now measures

* (i) **printable spacing window 1.17-4.93 mm at a 0.45 mm nozzle** — unaffected,
  that gate passed on arithmetic and still does.
* (ii) the **angle distribution** is still a correct measurement. It is simply not a
  measurement of BUILDABILITY. What it actually describes is the SHAPE OF THE STRESS
  FIELD, and read that way it says something useful (below).
* the two **method findings** from building the coupon stand on their own:
  a single family is disconnected noodles, and Jobard & Lefer separation must be
  applied PER FAMILY or the families can never reach connector range.
* the **6 sealed cavities** found by welding stand — a traced lattice seals voids,
  which is a real drainability cost for graded.

## ★ THE NEW GATE, VISIBLE IN THE PRINT

The printed coupon is **almost entirely axis-aligned**: vertical struts, roughly
horizontal ties, a few diagonals. It does not look like flowing organic curves. That
is exactly what the angle histogram said and what nobody read correctly: 28.2 % of the
major family lies within 10 degrees of VERTICAL and 35.8 % sits in the 80-90 degree
band. A bimodal, axis-aligned field.

The reason is the part. A vertical stand under a downward load carries its major
principal direction straight down the columns, and orthogonality puts the other two
in the horizontal plane. There is little diagonal flow to follow.

**So the honest question for graded is no longer "can it be built" — it is "does it
differ enough from a stepped octet to be worth it ON THIS PART".** The octet already
places struts at 45 and 90 degrees on a regular grid; a traced lattice whose curves
are 28 % vertical and 36 % horizontal is approximating the same thing with far more
machinery, a sealed-void problem, and no measured tensor.

That is a CHEAP question to answer and it does not need a printer: compare compliance
of the traced lattice against a stepped octet at matched mass on his part. It should
be the next gate. It replaces the overhang gate, which is now closed by experiment.

## Method note, for the next person

The no-go was reached by taking a constraint from the task brief ("the 45-degree rule
is the constraint") and measuring against it without ever asking whether it applied to
struts. Every number in that chain was correct. The conclusion was not, because the
premise was never tested and was cheap to test.

---

## ★ THE PRINT RAN AT 0.12 mm LAYERS, AND THAT IS PART OF THE RESULT

The maintainer kept line width at 0.42 mm but dropped LAYER HEIGHT to 0.12 mm for the
coupon's size. That is not a footnote — it moves the overhang limit, and it needs to be
recorded beside the verdict.

### The 45-degree rule is `tan(th_max) = c · W / h`

A strut at angle `th` from vertical shifts sideways by `h·tan(th)` every layer, and it
bonds while that shift stays within some fraction `c` of the line width.

| W / h | ratio | limit (c = 0.5) | limit (c = 1.0) |
|---|---|---|---|
| 0.42 / **0.20** (typical) | 2.10 | **46.4 deg** | 64.5 deg |
| 0.42 / 0.16 | 2.62 | 52.7 deg | 69.1 deg |
| 0.42 / **0.12**  ← HIS PRINT | 3.50 | **60.3 deg** | 74.1 deg |
| 0.42 / 0.10 | 4.20 | 64.5 deg | 76.6 deg |

★ **Look at the first row.** At the usual `W/h ≈ 2` the conservative limit is 46.4 deg.
The "45-degree rule" IS this formula at one operating point. It was never a law of
nature, and the brief stated it as one.

★ At `h = 0.12` the limit moves to **60-74 deg**. Dropping layer height was exactly the
right lever and is part of WHY the coupon printed.

### And the 65 % splits into two unrelated populations

A segment of length `L` at angle `th` spans `L·cos(th)` vertically. Below one layer
height it lies WITHIN a single layer — it is bridged, not stacked. At the coupon's
`L = 0.853 mm` step and `h = 0.12`, that boundary is **81.9 deg**.

| family | ≤ 60 deg (stacks, fine) | 60-80 deg (genuinely at risk) | 80-90 deg (single-layer BRIDGES) |
|---|---|---|---|
| MAJOR  | 62.1 % | **2.1 %** | 35.8 % |
| MIDDLE | 10.2 % | 20.6 % | 69.2 % |
| MINOR  |  3.1 % | 19.6 % | 77.3 % |
| **ALL**| 37.8 % | **10.4 %** | 51.7 % |

So of the 65.13 % I called "violations", **51.7 points are bridges** (governed by span —
measured worst case 41.78 mm, printed clean) and only **10.4 points** are genuine
overhang risk. Lumping the two together was the error, and the layer height is what
sets the boundary between them.

## WHAT THIS MEANS FOR THE PRODUCT

**Layer height should be a declared input that reaches core. It currently does not.**

`app/.../PrintParams.swift:16` states it outright: *"`layerHeightMM` is CAPTURED BUT NOT
WIRED: the M5.1 engine's `SlicerSettings` has no layer-height field, so there is nothing
to override with it yet."* The user already sets it on the print-params sheet and it is
persisted on the project — it simply never reaches the core. Core has **no** layer-height
parameter at all (`grep` finds none in `core/include` or `core/src`).

Consequences:
* the grading law cannot compute its own sloped-strut printability limit, because that
  limit is `c·W/h` and it does not know `h`;
* `min_extrudable_width_mm` is honoured as a stated input while `h` — the other half of
  the same ratio — is invisible.

★ **THE RIGHT SHAPE, and it follows the codebase's existing rule that printability is a
USER INPUT and never a default:** the user declares `layer_height_mm` (they already do);
the law computes, from the geometry IT emitted, the steepest strut it contains and hence
the `W/h` that geometry requires; and it REPORTS that requirement — refusing, or naming
the number, when the declared pair cannot print what was generated. Deriving a layer
height from "model size" would be a silent default, which is the thing that rule exists
to prevent. Size is not the driver; the steepest emitted strut is.

## CAVEAT ON THE VERDICT ABOVE

The clean print is at `W/h = 3.50`. At a typical `W/h = 2.10` the conservative limit
falls to 46.4 deg and the at-risk band widens. **The result is conditional on the ratio,
and any future statement of it must carry the ratio with it.**
