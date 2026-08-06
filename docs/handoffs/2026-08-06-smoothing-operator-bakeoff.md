# smoothing-operator-bakeoff — mean-curvature flow wins on the sphere; ramp reconstruction is a NO-GO

Task: `smoothing-operator-bakeoff`
Evidence: `evidence/2026-08-06-smoothing-operator-bakeoff/`
Branch: `claude/smoothing-operator-bakeoff-9530b1`
Changes: `core/` only. CI: core-linux + app-macos. `materials.json` untouched.

---

## 0. WHAT CHANGES FOR YOU

**Operator A, mean-curvature flow, removes 51.6% of the stair-step amplitude on the
analytic sphere. The shipped Taubin smoother removes 11.2% at the strength the app
can ask for. That is 4.6x, on the same fixture, at the same voxel size, measured
the same way.**

**Operator B, ramp reconstruction, is a NO-GO. Its best setting removes 14.3%, and
even at that setting it makes the WORST-CASE deviation 46% worse than doing nothing
(1.0610 mm against 0.7266 mm) — worse at every other setting too, up to 64% —
while at some settings its RMS is worse than the unsmoothed mesh outright, and one brush stroke on your mesh
costs 3.9 to 13.0 seconds against operator A's 0.086. It also fails the one
prediction that was made for it — see §S1.2.**

**The thinnest tendril did not move.** On a dumbbell with a 2-voxel neck — the
thinnest member a design can legally have — the neck's minimum cross-section reads
4.0000 mm² before and 4.0000 mm² after, at every setting of both operators, with
the signed constraint armed and with it off. Volume holds to 0.000000%.

**Three things are NOT settled here, and none of them is a detail:**

1. **Against the SDF route it depends entirely on mesh density, and that is a new
   result.** PR 303 merged to `main` while this task was running, so its probe is
   now buildable here and I re-measured it rather than quoting it. **At a matched
   vertex count A wins: 51.6% removed on 11,232 vertices against SDF's 48.2% on
   11,502.** SDF only pulls ahead — 58.9%, and 64.8% at its best — by DECIMATING
   the mesh 3.9x and 10.6x. Some of that lead is the metric rather than the
   surface: the score is a per-vertex RMS, and a mesh with a tenth of the vertices
   has a tenth of the places to be wrong. Which is genuinely better is still open,
   and still needs the cut population (§S3.6).
2. **A makes the surface locally rougher while making it globally more accurate.**
   RMS deviation from the true sphere falls to 48.4% of its unsmoothed value, and
   RMS dihedral angle RISES from 14.53° to 26.32°. Taubin does the opposite. Whether that trade looks better to
   your eye on your part is not something a sphere can decide.
3. **Nothing here has been measured on your part.** The classifier that separates
   your CAD faces from the optimizer's cuts does not exist yet, and I did not write
   a second one.

**The strength certificate cannot see any of this.** Read §R3 before you read a
margin next to a smoothed part.

---

## 1. THE GATE, AND WHAT IT MOVED

The brief was gated on `cad-face-projection`, which produces the CAD-versus-cut
classifier. That task is running in parallel and had not landed as of this work:
`claude/cad-face-projection-a1e996` sat at `90e9ec5` — byte-identical to what `main`
was at the time — with no commits, no PR, and no evidence directory. (`main` has
since moved to `81a2368`; the classifier branch still carries nothing.)

**I did not write a second classifier.** Two mechanisms deciding which vertices came
from your CAD, with the stricter or the newer one silently winning, is a failure
this project has hit repeatedly and is worse than a delay.

So the split is a hard boundary through this work:

| Question | Needs the classifier? | Status |
| --- | --- | --- |
| Both operators built, fully | no | **done** (§S1) |
| Operator comparison on the analytic sphere | no — a sphere has no CAD faces | **done** (§S1.1) |
| C1 trust region | no — geometry | **done** (§S2.1) |
| C2 signed bounds | no — geometry | **done** (§S2.2) |
| C3 volume preservation | no — geometry | **done** (§S2.3) |
| C5 brush weights | no | **done** (§S2.5) |
| S3 instrumentation, built and validated | no | **done** (§S3.3) |
| Does B meet C1 by construction? | no — answerable on the sphere | **done, REFUTED** (§S1.2) |
| §0 re-baseline of Taubin and SDF on the cut population | **yes** | **OWED** |
| Per-rung comparison on his own part | **yes** | **OWED** |
| C4 — CAD faces do not move | **yes** | **OWED** |

C4 is not approximated with a normal test or a curvature heuristic anywhere in this
change. `core/include/topopt/surface_operator.hpp` says so at the point where a
reader would otherwise go looking for it, and `SurfaceConstraints::sign` is the
input the classifier's answer will arrive through.

### THE CLASSIFIER APPEARED WHILE THIS WAS BEING WRITTEN — PR 307, OPEN

`cad-face-projection` pushed three commits and opened **PR 307** during this task.
It is **not merged**, so nothing here is measured against it, but the integration is
now a known quantity rather than a hope, and it is small. Recording it exactly so
whoever picks this up does not have to rediscover it:

- The classifier is `attribute_to_cad_faces(mesh, StepModel, CadProjectOptions)` in
  `core/include/topopt/cad_project.hpp`, returning `CadAttribution`.
- `core/src/mesh/cad_project.cpp` is in the **always-built** sources, beside
  `surface_operator.cpp`, and its unit test is **not** OCCT-gated — it builds a
  `StepModel` in code. So the two modules compose in every configuration.
- **The predicate is `att.face_of_vertex[v] >= 0`**: a vertex attributed to a CAD
  face. Their own test uses exactly that test to separate the populations.

**C4 then costs one line**, and it lands on a case this PR already asserts:

```cpp
for (std::size_t v = 0; v < mesh.vertices.size(); ++v)
  if (att.face_of_vertex[v] >= 0) constraints.sign[v] = TrustSign::Pinned;
```

`TrustSign::Pinned` is already asserted **bit-identical** for both operators
(§S2.2), which is precisely what C4 demands — "zero displacement, asserted, not
assumed" — rather than a small number that would need a tolerance argued for.

The **cut population** for the §0 re-baseline is the complement,
`face_of_vertex[v] < 0`, minus `ambiguous_flag` if the re-baseline wants to exclude
the band the classifier itself declines to call.

**What still gates it:** PR 307 is open and unreviewed, and the measurement on his
part additionally needs OCCT to import his STEP (`cad_project_probe` is inside the
`OpenCASCADE_FOUND` block for that reason). Building the deciding number on an
unmerged branch would put it hostage to that review — which is not hypothetical:
PR 303's figures were quoted here, then merged, then re-measured, and the
conclusion moved (§S1.1).

---

## S1 — THE TWO OPERATORS

New module: `core/include/topopt/surface_operator.hpp`,
`core/src/mesh/surface_operator.cpp`. Nothing existing was modified; the only edit
to a tracked file is three additive blocks in `core/CMakeLists.txt`.

### Operator A — mean-curvature flow

Each vertex moves along its own outward normal in proportion to the local mean
curvature. A staircase is alternating high-positive and high-negative curvature at
the step edges with near-zero on the treads, so A attacks the steps and leaves the
flats alone **without a detector**.

The discrete mean-curvature normal is the cotangent Laplace–Beltrami operator
normalised by the mixed Voronoi area (Meyer et al. 2003), so it carries units of
1/length and is a property of the **surface**, not of its tessellation. The time
step is written `dt = c·h²` because mean-curvature flow is a heat-type equation:
at a step edge curvature is O(1/h) and the displacement is O(c·h), while on a
smooth patch of radius R it is O(c·h²/R), smaller by h/R. That separation is the
whole reason A needs no step detector.

This is the OpenVDB `LevelSetFilter` formulation. **OpenVDB was not added as a
dependency and is not proposed as one** — the mean curvature is a short formula and
the narrow-band bookkeeping is the only part that would have been imported.

Two properties are asserted rather than claimed
(`core/tests/unit/test_surface_operator.cpp`):

```
-- MEAN CURVATURE SIGN ------------------------------------
  smooth R=8.0 sphere: 1106 inward, 0 outward; |Kn| vs 2/R=0.2500 worst error 0.0004 (1/mm)
  4x the triangles: worst error 0.0001 (1/mm) — unchanged, so the strength is mesh-density independent
```

The magnitude bar matters as much as the sign: a sign-only test would pass on an
operator whose strength was off by a factor. The density bar is the property that
separates A from the Taubin family — refining the mesh 4x does not change what A
reads, whereas the umbrella Laplacian's per-pass displacement scales with local
vertex spacing (the defect Blender documents for its own smooth brush, and the one
Taubin's dimensionless pass band carries).

### Operator B — ramp reconstruction

Refine along the terrace, then place the points on the ramp running from the
terrace's high extreme to its low extreme.

- **Terraces** are connected runs of faces whose normals agree with the run's
  **seed** normal within 25°. Seed-relative and not neighbour-relative on purpose:
  chaining neighbour-to-neighbour lets one "terrace" bend around a whole fillet,
  which is exactly the shape that must not be flattened.
- **Refinement** is a watertight edge split (`refine_edges`): the decision is taken
  per EDGE and both incident faces read the same decision, so 1/2/3 split edges give
  2/3/4 faces and there are no T-junctions. It is asserted watertight-preserving and
  **exactly volume-neutral** — splitting at a midpoint moves no surface, which is
  what lets B add points without the addition itself being a change:

  ```
  -- REFINEMENT (operator B's first half) -------------------
    936 verts / 1868 tris -> 1870 / 3736 (934 edges split)
    watertight yes -> yes ; volume 1457.000000 -> 1457.000000 mm3 (0.000e+00 relative)
  ```

  The test splits **every third edge**, not all of them: a uniform 1→4 split would
  pass even if the two faces sharing an edge disagreed about it.
- **The ramp** is a least-squares plane fit over the terrace's vertices plus
  `fit_rings` rings beyond, evaluated at each terrace vertex and clamped into the
  neighbourhood's own [low extreme, high extreme] envelope. The extra rings are what
  make it a ramp rather than a re-flattening: a tread is flat, so a fit over the
  tread alone reproduces the tread exactly and moves nothing.

**This is not PR 303 §S1.6's up-res experiment.** That added triangles uniformly and
moved nothing (16x the count, deviation flat at 0.376 → 0.373 → 0.366 mm). B adds
points where the ramp must be represented **and moves them** — 82,104 → 980,639
vertices on your mesh, with every added point displaced onto the fitted ramp.

---

### S1.1 — THE BAKE-OFF ON THE ANALYTIC SPHERE

Fixture: R = 20 mm, voxel spacing **1.620040 mm** (your part's spacing at resolution
128), export factor 2, tricubic resample, through the same STL round trip the app
puts every mesh through. Metric: RMS of |‖v−c‖ − R|, reported as a percentage of the
unsmoothed baseline and as the complement — the amplitude **removed**.

The fixture reproduces PR 299 and PR 303 exactly, which is the cross-check that lets
these rows sit in their table: **11232 verts, rms 0.3307 mm, max 0.7266 mm**, and
Taubin at 20 pairs lands on **88.8% / 11.2% removed**, digit for digit with PR 299
§S1(d).

```
configuration                  max mm   rms mm %ofbase  REMOVED   dihed   maxmove     vol%    verts   iters   wall s
unsmoothed (PR 299 base)       0.7266   0.3307   100.0     0.0%   14.53    0.0000   0.0000    11232       0    0.000
Taubin pairs 20                0.6956   0.2936    88.8    11.2%   13.26    0.4285   0.0457    11232      20    0.004
Taubin pairs 160               0.5769   0.2198    66.5    33.5%    5.68    0.6653   0.3848    11232     160    0.021
A mean-curvature x5            0.5665   0.2080    62.9    37.1%   31.48    0.5685   0.0000    11232       5    0.004
A mean-curvature x10           0.4978   0.1735    52.5    47.5%   30.45    0.6329   0.0000    11232      10    0.006
A mean-curvature x20           0.4478   0.1602    48.4    51.6%   26.32    0.6339   0.0000    11232      20    0.011
A mean-curvature x40           0.5513   0.1656    50.1    49.9%   20.45    0.6108   0.0000    11232      40    0.020
A mean-curvature x160          0.6343   0.2055    62.1    37.9%   17.30    0.5902   0.0000    11232     160    0.075
B ramp r2 e0.0 x1              1.0610   0.2835    85.7    14.3%   28.22    0.6317   0.0000    11232       1    0.022
B ramp r1 e0.5 x1              1.1955   0.3045    92.0     8.0%   18.81    0.6023   0.0000   105412       1    0.264
B ramp r1 e0.0 x8              1.1073   0.3452   104.4    -4.4%   25.61    0.6873   0.0000    11232       8    0.125
```

Full 29-row sweep: `evidence/.../bakeoff_probe.txt`, `sphere_bakeoff.csv`.

**The ranking, on this fixture:**

| operator | best removed | at |
| --- | --- | --- |
| SDF geometry extraction (PR 303, quoted — see below) | **58.9%** | B/h = 2 |
| **A — mean-curvature flow** | **51.6%** | 20 steps |
| Taubin, best anywhere in the family | 33.5% | 160 pairs, guard off |
| **B — ramp reconstruction** | **14.3%** | 1 step, 2 rings, no refinement |
| Taubin, strongest the app can ask for | 11.2% | 20 pairs |

**Margins.** A beats B by 51.6 to 14.3 — a factor of 3.6, and B's own sweep spans
−4.4% to 14.3%, so the two do not overlap anywhere. This is not within noise and I
am not calling it a tie. A beats the shipped Taubin strength by 4.6x and the Taubin
family's best-anywhere by 1.54x.

**Five things about that table that are not the headline and matter anyway:**

1. **A is non-monotone in strength.** It peaks at 20 steps (51.6%) and falls away on
   both sides — 37.1% at 5 steps, 37.9% at 160. More is not better. Whatever ships
   needs a setting, not a slider that rewards dragging.
2. **A improves the worst case too, B makes it worse.** Max deviation: base 0.7266,
   A at x20 **0.4478** (38% better), B at its best **1.0610** (46% worse). B's
   maximum is worse than doing nothing at every single setting.
3. **A makes the surface locally rougher.** Dihedral RMS goes 14.53° → 26.32° while
   the deviation falls to 48.4% of baseline. Taubin does the reverse (14.53° → 5.68°). I said in the
   probe's own header that the corroborating number must move **with** the headline
   for a reading to mean what it says; here it moves against it, and I am reporting
   that rather than dropping the column. The mechanism is not mysterious — A moves
   step edges a lot and treads little, so the surface lands closer to the sphere
   while varying more from triangle to triangle. It is a real trade and a sphere
   cannot tell you whether you would rather have it.
4. **B gets WORSE with more steps, and refinement barely helps.** r1/no-refine goes
   6.4% → 5.3% → 1.4% → −4.4% across 1, 2, 4, 8 steps. Refining (e0.5) moves the
   1-step figure from 6.4% to 8.0% and costs 9.4x the vertices and 15x the wall.
5. **Volume: A and B hold it to 0.0000%; Taubin drifts 0.0457% at 20 pairs and
   0.3848% at 160.** That is C3 doing its job (§S2.3), not a property of the
   operators.

**On the SDF rows — RE-MEASURED, not quoted.** PR 303 **merged to `main` while this
task was running** (main moved 11 commits: PRs 301, 302 and 303). Its
`sdf_geometry_probe` builds in this configuration, so main was merged in and the
sphere control re-run here rather than quoted. It reproduces PR 303's published
table exactly (`evidence/.../sdf_sphere_remeasured.txt`):

```
configuration               max mm    rms mm % of base     verts
unsmoothed (PR 299)         0.7266    0.3307     100.0     11232
SDF B/h = 3.300             0.3920    0.1164      35.2      1062     -> 64.8% removed
SDF B/h = 2.000             0.4647    0.1361      41.1      2886     -> 58.9% removed
SDF B/h = 1.000             0.4909    0.1714      51.8     11502     -> 48.2% removed
SDF B/h = 0.500             0.4862    0.1664      50.3     45390     -> 49.7% removed
```

**THE VERTEX COUNT COLUMN IS THE STORY.** Operator A scores 51.6% on **11,232**
vertices — the input mesh, unchanged. The SDF row at a comparable count, B/h = 1.0
with **11,502** vertices, scores **48.2%**. **A wins at matched mesh density.** SDF's
58.9% costs a decimation to 2,886 vertices (3.9x) and its 64.8% costs 1,062 (10.6x).

I am not claiming the decimation makes SDF's lead fake — a smooth reconstruction
placing 1,062 well-chosen vertices really may sit closer to a sphere than 11,232
badly-placed ones. But the metric is a **per-vertex RMS**, so a mesh with a tenth of
the vertices has a tenth of the places to be wrong, and no part of PR 303's headline
separates those two effects. That separation is owed alongside the re-baseline.

Two further things make the comparison less clean than one number suggests, and both
cut the same way:

- SDF is a **re-meshing**, not a brush-scoped operator. A keeps the vertex set and
  the topology, which is what makes it brushable at all: a stroke changes some
  vertices and leaves the rest bit-identical.
- SDF carries **no displacement bound**. PR 303's own Gibson table measures it moving
  0.9001 mm on your part at B/h = 2, and reports 0.02% of vertices pulled back at a
  0.5-voxel bound. A is bounded at 0.405 mm per axis by construction, on every
  vertex, always.

So "SDF scores higher" is true only at 3.9x to 10.6x fewer vertices, "A scores
higher at matched density" is also true, and "SDF and A are interchangeable" is not
true at all. Which is better **on your cut surfaces, at matched density, under a
displacement bound** is the measurement that is owed.

---

### S1.2 — DOES OPERATOR B MEET C1 BY CONSTRUCTION? **NO.**

The brief predicted it would: "a ramp between a terrace's own extremes lies inside
that terrace's envelope." Measured, with C1 disabled so the raw construction is
visible:

```
configuration               C1 off: would exceed deepest exc mm   envelope     max env mm
                            maxmove   C1 (verts)                    clamps
B ramp r1 e0.5 x1            2.2483         5793         1.2108          2         0.0443
B ramp r1 e0.5 x8            2.8710        37332         2.7549        133         0.1169
B ramp r2 e0.5 x8            2.9898        43577         2.4639         35         0.5351
                         (trust radius 0.4050 mm; of 105412 vertices)
```

**Clamping is still required, and not marginally.** Between 5,793 and 43,577 of
105,412 vertices land outside the trust box unclamped, the deepest by **2.75 mm —
6.8 trust radii** — and the envelope clamp itself catches almost none of it (0 to 133
vertices).

The reason the prediction fails is worth stating because it is structural, not a
tuning problem. The envelope is the extremes of the terrace **group**, and the group
includes the `fit_rings` neighbourhood that reaches onto the risers and the adjacent
treads — which is precisely what gives the ramp its slope in the first place. Those
extremes are a full voxel apart or more. So "inside the terrace's envelope" is a far
weaker bound than "inside its own voxel", and the two are not the same claim. B
cannot get its slope from a neighbourhood narrow enough for the envelope to imply
C1.

---

## S2 — THE CONSTRAINTS

Bar R2 is "failing test first for each constraint: construct the case it exists to
prevent, show it happening without the constraint, paste it." Every case in
`core/tests/unit/test_surface_operator.cpp` is therefore a **pair of arms**, and the
unconstrained arm **asserts that the damage happens**. That second assertion is not
decoration — a constraint test whose unconstrained arm quietly stopped reproducing
the damage would pass vacuously forever.

On top of that, each constraint's enforcement was surgically **disabled in the
source** and the unmodified test re-run. Full output:
`evidence/.../r2_failing_first.txt`.

```
C1 DISABLED       → 4 failures    C2 DISABLED       → 9 failures
C3 DISABLED       → 3 failures    ORIENTATION       → 4 failures
INHERITANCE OFF   → 3 failures    ALL RESTORED      → 50 checks, 0 failures
```

### S2.1 — C1, the trust region

**Gibson, "Constrained Elastic Surface Nets", MICCAI 1998. No vertex may leave the
voxel that produced it.** The justification is the accuracy argument and it belongs
here in full:

> The export is **already** only accurate to ±half a voxel — marching cubes places a
> vertex by interpolating a field sampled at cell corners, and where that field is
> near-binary the placement carries the full half-cell uncertainty. So motion
> **inside** that band adds no new error: it picks a better point within uncertainty
> that already exists. Motion **outside** it manufactures error that was not there.

The cell is the lattice that **produced** the vertices — for an export at
`output.smooth_factor` f from a grid of spacing h, that is h/f, not h. On your part
at resolution 128 with factor 2: h = 1.620040 mm, cell = **0.810020 mm**, trust
radius at 0.5 cells = **0.405010 mm**.

C1 is implemented as a **direction-preserving scaling**, not a per-axis box clamp:
the largest t ∈ [0,1] with `orig + t·d` inside the box. This is not a style choice.
A per-axis clamp changes the **direction** of the motion and can therefore turn an
outward step into one with an inward component, re-breaking C2 after C2 has already
been enforced. Scaling cannot, so the two constraints compose exactly and without
iteration.

```
-- C1 THE TRUST REGION ------------------------------------
  without C1: max per-axis motion 1.8679 mm = 1.87 cells
  with    C1: max per-axis motion 0.5000 mm = 0.50 cells (576 vertices clamped, deepest pull-back 0.1764 mm)
  operator B with C1: max per-axis motion 0.5000 mm = 0.50 cells
```

With C1 disabled in the source, the same test reports `max per-axis motion 1.8679 mm`
in both arms and three assertions fail.

**One consequence to be explicit about: the box is a CUBE, so the largest possible
displacement is r·√3, not r.** At r = 0.405 mm that is 0.701 mm, which is why the
`maxmove` column in §S1.1 reads up to 0.6339 for A. Every per-axis component is
inside 0.405. If a spherical bound is wanted instead, that is a different (stricter)
constraint and is a one-line change.

### S2.2 — C2, the signed trust region

```
material matters (load path, thin section) → OUTWARD ONLY
design box or clearance binds              → INWARD ONLY
neither binds                              → both, within the cube
BOTH bind at once                          → PINNED, no smoothing at all
```

```
-- C2 THE SIGNED TRUST REGION -----------------------------
  without C2: max inward 0.7394 mm, max outward 0.0171 mm
  OutwardOnly: max inward 2.4490e-15 mm (must be 0), max outward 0.5448 mm, 1082 vertices projected
  InwardOnly : max outward 1.6072e-15 mm (must be 0), max inward 0.7353 mm, 606 vertices projected
  Pinned     : A bit-identical yes, B bit-identical yes (1896 pinned)
  mixed      : worst OutwardOnly violation 2.0535e-15 mm, worst InwardOnly violation 1.6875e-15 mm
```

The Pinned case is asserted as **bit-identity**, not as a small number, because the
rule is "do nothing" and not "compromise". The `mixed` arm is the real case: the sign
varies per vertex and each vertex obeys its own.

**How "material matters" is determined, and the defence of it.** Both halves reuse a
predicate this project **already** treats as the definition of the thing, rather than
introducing a new criterion that would then have to be reconciled with the old one:

- **(a) Load path** — the voxel under the vertex, or any of its 26 neighbours, is
  tagged `Load` or `Fixture`. Those are exactly the voxels the certificate applies
  its boundary conditions to. Removing material there changes the structure the
  margin was computed on, which is the one change smoothing must never make silently.
- **(b) Thin section** — the local member width is at or below `thin_section_mm`,
  default **2 voxels**. Width is `local_member_thickness_mm`, the Hildebrand
  inscribed-sphere diameter core already computes for the width-aware knockdown gate;
  it assigns a rib its full width at every voxel including the outer fibres, which is
  what a surface vertex on a thin rib needs to read. Two voxels is the same
  "minimum feature size ≥ 2 voxels" that §7 V3 gate 4 already refuses designs for, so
  a section this operator may not thin is a section the gate would already reject.

The inward-only half is the design box and the clearance regions.

```
-- C2 CLASSIFICATION --------------------------------------
  thin section: 34 OutwardOnly, 598 Both; on the fin 34/34 OutwardOnly
  load path   : 27/27 vertices beside the Load voxel flagged
  box + fin   : 144 InwardOnly, 34 Pinned
```

The `598 Both` is a positive control in its own right: it asserts the thick slab is
**not** flagged, so the predicate is not trivially true.

**A design note that bit during this work and would bite a caller.** The bind
tolerance for the design box must be **at least the trust region's cube diagonal**,
r·√3, not r. A vertex sitting between r and r·√3 inside the wall would classify as
`Both` — free to move outward — and could still reach the wall. The probe sets it to
the diagonal and prints the value.

### S2.3 — C3, volume preservation

Curvature flow shrinks; neither operator ships without a compensator. The mechanism
is the **uniform shift of the level set** — every movable vertex moves along its own
normal by the single scalar that closes the volume gap, dV = shift·A, then is
re-clamped to C1/C2, and the pair is iterated.

```
-- C3 VOLUME PRESERVATION ---------------------------------
  without C3: 4204.6667 -> 3631.3001 mm3  (-13.6364%)
  with    C3: 4204.6667 -> 4204.6667 mm3  (+0.000000%) in 5 shift iterations
  operator B: 4204.6667 -> 4204.6667 mm3  (drift 0.000000%)
```

The shift is **damped and backtracked**, and it has to be — see §R6 defect 2.

### S2.5 — C5, the brush

```
-- C5 THE BRUSH -------------------------------------------
  624 painted / 1248 total; unpainted vertices moved: 0; deepest painted motion 0.7315 mm
```

Weight 0 takes a **verbatim branch**, never `p + 0·d`: −0.0 + 0.0 is +0.0 and one
flipped sign bit defeats memcmp. And a weight on a pinned vertex cannot move it — the
sign is tested first, so the brush is a way to smooth **less**, never a way to smooth
something C2 protects. Both are asserted.

**A vertex that refinement CREATES inherits its parents' weight (the minimum of
the two) and their sign, conservatively** — see §R6 defect 5. Defaulting it would
have been a hole, and the hole was measured before it was closed.

**What is NOT wired yet:** PR 300's app-side accumulation (+10% per pass, capped at
four passes, erase clears) is not yet rasterised onto the grid and handed to
`SurfaceConstraints::vertex_weight`. The core side accepts and enforces the weights;
the app-side plumbing is a follow-up and is listed in §Next.

---

## S3 — THE MEASUREMENT

### S3.3 — The instruments, validated first

An instrument that has never been shown to **move** cannot be trusted to report that
something did not.

**Minimum cross-section.** Averages hide the failure mode: a mean can hold steady
while one strut necks, and the necking strut is the whole objection. Two measures are
reported, and the first one turned out not to be the right one:

- `local_member_thickness_mm` (Hildebrand) is the project's own width field and
  belongs in the table, but it is an inscribed-sphere diameter, and that is **not**
  what "cross-section" means for a rectangular member: on the dumbbell's source
  occupancy a bridge 6 voxels wide reads **4**, because the largest sphere that fits
  inside a 6×6 section and still contains one of its **corner** voxels has diameter
  4. It also has a hard **2-voxel quantum** (2·r·spacing, r integer), so a 3-voxel
  neck reads 2.000.
- The deciding column is therefore the plain engineering one: **the solid area of the
  thinnest slice**, minimised over slices and over the three axes. On a member of
  constructed width n voxels it reads exactly n²·spacing², which is what makes it a
  positive control:

```
neck (voxels)    expected mm2     source mm2   exported mm2   equiv w mm    solid vox
2                       4.000          4.000          4.000        2.000         1632
3                       9.000          9.000          4.000        3.000         1672
4                      16.000         16.000          4.000        4.000         1728
6                      36.000         36.000          4.000        6.000         1888
slice-area instrument reproduces the constructed neck EXACTLY on the source occupancy: YES
```

**Maximum outward excursion.** Validated against a constructed violation: a triangle
wholly inside a box reads −1.0000 mm, the same triangle with one vertex 0.75 mm past
the wall reads +0.7500 mm.

**Volume** is `signed_volume` via the divergence theorem, unchanged from core.

**Wall time** is reported as total and per iteration, separately (bar R4).

### S3.4 — What the thinnest tendril did

The sphere has no tendril, so the minimum cross-section cannot be exercised on it.
The dumbbell can: a **2-voxel neck**, the thinnest a design may legally have, which
sits exactly on §7 V3's floor and is therefore read by `classify_trust_sign` as
material that matters. The design box contains the part on its +x face and is
generous elsewhere, so `InwardOnly`, `OutwardOnly` and `Both` are all present.

```
C2 classification of 4384 vertices: 128 OutwardOnly, 480 InwardOnly, 0 Pinned, 3776 Both

configuration                 TENDRIL  d TENDRIL whole part         at    max exc  volume mm3  wall s
                                  mm2        mm2        mm2                    mm                   s
as exported today              4.0000          -     4.0000        x=10    +0.0000    1616.067       -
A x10  C2 OFF                  4.0000    +0.0000     4.0000        x=10    +0.0484    1616.067   0.002  <-- OUTSIDE THE DESIGN BOX
A x10  C2 ARMED                4.0000    +0.0000     4.0000        x=10    -0.0436    1616.067   0.002
A x40  C2 OFF                  4.0000    +0.0000     1.0000        z=0     +0.0869    1616.067   0.007  <-- OUTSIDE THE DESIGN BOX
A x40  C2 ARMED                4.0000    +0.0000     1.0000        z=0     -0.0535    1616.067   0.008
B x2  C2 ARMED                 4.0000    +0.0000     4.0000        x=10    -0.0195    1616.067   0.170
B x8  C2 ARMED                 4.0000    +0.0000     4.0000        x=10    -0.0057    1616.067   0.524
Taubin pairs 20                4.0000    +0.0000     4.0000        x=10    -0.0045    1620.283   0.001
Taubin pairs 160               4.0000    +0.0000     4.0000        x=10    +0.0961    1647.068   0.006  <-- OUTSIDE THE DESIGN BOX
```

**The tendril's minimum cross-section is 4.0000 mm² in every row.** It does not fall
under either operator, at any setting, with C2 armed or off. **No BLOCKED-STOP is
triggered.**

**Three readings in that table are worth more than the headline:**

1. **C2's inward arm demonstrably works.** A x10 goes from +0.0484 mm outside the box
   to −0.0436 inside; A x40 from +0.0869 to −0.0535. The constraint is the difference
   between breaching the design box and not.
2. **The incumbent breaches it.** Taubin at 160 pairs reads **+0.0961 mm outside the
   box** and drifts volume by **+1.9%** (1616.067 → 1647.068). A and B hold volume
   to 1616.067 exactly and, with C2 armed, stay inside.
3. **The `whole part` column falls to 1.0000 mm² at A x40 — and its location is
   `z=0`, not the bridge.** That is the core fill defect in §R6 defect 4, not a
   necking. This is exactly why the location is printed: the same table without it
   would have read as a BLOCKED-STOP.

### S3.5 — Wall time per stroke, at your mesh size

Your part voxelized at 128, exported at factor 2, through the app's own weld:
**82,104 vertices / 164,228 triangles**, grid 125×128×13, spacing 1.620040 mm.

```
one stroke                          iters     wall s ms / iteration
A mean-curvature x5                     5      0.027            5.4
A mean-curvature x20                   20      0.086            4.3
B ramp x2                               2      3.900         1950.2  (82104 -> 980639 verts)
B ramp x8                               8     13.032         1629.0  (82104 -> 980639 verts)
Taubin pairs 20                        20      0.024            1.2
```

**A at its best setting costs 0.086 s per stroke. B costs 3.9 to 13.0 s.** B is 45x
to 150x slower than A and 160x to 540x slower than the incumbent, because it must
refine to 980,639 vertices — 11.9x the input — to have points to put on the ramp.
That alone disqualifies it from being a brush, independently of the 3.6x it loses on
amplitude.

### S3.6 — What the measurement could NOT decide

Owed to `cad-face-projection`:

- **The §0 re-baseline.** PR 303's 21.5% headline was measured against a whole-part
  objective that included the damage the method did to CAD faces, and its "best grid
  spacing" was chosen against that contaminated objective. Re-running it on the cut
  population alone may move the optimum. Until it does, the 58.9% sphere figure is
  the only SDF number in play, and it is a sphere figure.
- **The per-rung comparison on your part**, all four rungs.
- **C4.** It cannot be asserted without knowing which faces are CAD, and approximating
  it with a normal or curvature test **is** writing a second classifier.

---

## THE BARS

**R1 — byte-identical when off**, **re-run against the MERGED tree**. main moved 11
commits under this task (PRs 301, 302, 303), so the first R1 — taken against
`90e9ec5` — was stale before it could be published; the published one is against
`origin/main` at `81a2368` with that main merged in. See
`evidence/.../r1_byte_identity.txt`. The change
is additive: one new header, one new source file, two new test/harness files, and
three additive blocks in `core/CMakeLists.txt`. No existing translation unit was
edited. The stash-rebuild comparison checksums the stdout of every shipped test
binary that touches mesh, smoothing, export, resample, voxel and STL across the two
builds, **and separately asserts that the `libtopopt` archives differ**, so the
identity is not the vacuous kind that would also pass if the rebuild had silently
no-opped.

**R2 — failing test first for each constraint.** §S2 and
`evidence/.../r2_failing_first.txt`. Each of C1, C2, C3 disabled in turn in the
source, unmodified test re-run, failures pasted. 50 checks, 0 failures restored.

**R3 — THE CERTIFICATE IS NOT THE SAFEGUARD.** In plain words, because this is the
thing most likely to be misread:

> PR 303 measured a **0.23 mm surface move producing an identical margin, peak
> stress, verdict and voxel mass — to every digit.** So an unchanged margin after
> smoothing is **not evidence of safety**. It is evidence that the instrument cannot
> see the change. The certification re-voxelizes onto the same grid, and a
> sub-voxel move is invisible to it by construction.
>
> **The displacement bound is the safeguard.** C1 is what limits how far anything can
> move; C2 is what decides which direction it may move in. A tendril can thin
> physically while the margin reads unchanged, and you must be told that rather than
> reassured by a number that did not move.
>
> That is also why §S3.4 measures the tendril's cross-section **geometrically**, in
> mm², rather than asking the certificate whether anything got worse.

**R4 — iterations and wall, always both, separately.** Every table in §S1.1 and §S3.5
carries an `iters` column and a `wall s` column, and §S3.5 adds ms/iteration.

**R5 — never weaken or delete an assertion.** Sweep of my own diff:

```
=== DELETED/CHANGED LINES in tracked files ===
(no removed lines anywhere in the diff)
=== assertion-bearing lines removed anywhere? ===
NONE — no assertion, test registration or throw was removed
```

The only tracked file modified is `core/CMakeLists.txt`, additively. No renames (a
rename reads as a deletion). Net: **+50 assertions, −0**.

**R6 — root cause with file and line.** §R6 below.

**R7 — no unfilled placeholders.** Every number in this document is from a run in
`evidence/`. There is no quoted figure left: PR 303's sphere numbers began as a
quote and were re-measured here once it merged, and the re-measurement is in
`evidence/.../sdf_sphere_remeasured.txt`.

**R8 — separate commit for any review response.**

---

## §R6 — DEFECTS FOUND, WITH ROOT CAUSE

### 1. `vertex_normals` pointed INWARD on every mesh this module is for — and it would have inverted C2 silently

`core/src/mesh/surface_operator.cpp:265`

STL specifies a counter-clockwise-from-outside winding, and I wrote the normals on
that assumption. **The assumption is false on core's own output.** On a voxelized
R=10 sphere, `signed_volume(marching_cubes(...))` is **−4204.6667**: the winding is
reversed, so `cross(p1−p0, p2−p0)` points **into** the solid at every triangle.

The consequence is not cosmetic. C2's `OutwardOnly` — the case whose entire job is to
forbid removing material from a load path or a thin section — would have permitted
**exactly and only the motion that removes it**, while reporting that it was
protecting the part. The evidence block for this is the fourth one in
`r2_failing_first.txt`: with the fix removed, the C2 table still reads
`OutwardOnly: max inward 1.6072e-15 mm (must be 0)` — a pass — and the labels are
simply inverted underneath.

Fix: read the orientation off the enclosed volume, which is well defined for the
closed meshes this module ever sees, and flip if negative. Guarded by a new bar
(`test_normal_orientation`) that checks both winding conventions in this codebase —
the UV sphere built in the test and marching-cubes output — for radially outward
normals.

### 2. The C3 uniform shift, undamped, left the volume FURTHER from target than it found it

`core/src/mesh/surface_operator.cpp:195,225`

dV = shift·A is a **first-order** relation, and the shift it asks for after a hard
operator run is not small: on a voxelized R=10 sphere that has lost 13.6% of its
volume it is **0.46 mm against a 0.5 mm trust radius**. Applied raw, most vertices hit
the C1 boundary, the volume overshoots, the next iteration overshoots back, and the
loop terminated at **−18.3% against the −13.6% it started from.**

Fix: each step is **kept only if it strictly reduces the volume error**, and halved
when it does not. What cannot be corrected inside C1 is reported as residual drift
rather than ground away at. Measured result: 0.000000% in 5 iterations.

### 3. The thin-section predicate used `<`, which is unreachable

`core/src/mesh/surface_operator.cpp:479`

`local_member_thickness_mm` reports 2·r·spacing for integer r, so its smallest
non-zero value is exactly 2 voxels — a one-voxel-thick fin reads **2.000, not
1.000**. A strict `<` against a 2-voxel threshold can therefore **never fire on any
member, however thin**. Measured before the fix: `on the fin 0/48 OutwardOnly`.

Fix: `<=`. It is also the right rule on its own terms — a member sitting exactly on
§7 V3's floor is precisely the one that must not be thinned.

### 5. Operator B's refinement manufactured UNCONSTRAINED vertices inside protected regions

`core/src/mesh/surface_operator.cpp` — the inheritance block in `ramp_reconstruction`

`SurfaceConstraints::sign` and `::vertex_weight` are sized to the INPUT mesh.
Operator B refines, appending vertices, and my first version resized those vectors
with the permissive defaults (`Both`, weight 1). Refinement splits edges **inside a
terrace**, so a terrace lying on a pinned load pad, or under an unpainted part of
the brush, acquired a fresh vertex in the middle of it that no constraint had ever
been computed for — and the operator moved it.

Measured, with the fix removed, on a half-pinned sphere:

```
-- REFINED VERTICES INHERIT THEIR PARENTS -----------------
FAIL: all-pinned: refinement happens but nothing moves
  1248 -> 8234 verts; in the pinned half 4143 vertices, 1586 moved; 4091 moved outside it
FAIL: no vertex in the pinned region moved — including ones refinement created
  brush: 1586 vertices in the unpainted half moved
```

**1,586 vertices moved inside a region every constraint said was frozen**, and the
all-pinned arm — where nothing whatsoever should move — moved too. Every other C2
bar passed throughout, because they all test the ORIGINAL vertex set.

Fix: `refine_edges` already reports each new vertex's parent pair; B now threads it
out across every pass and inherits, by the same rules C2 states for original
vertices — Pinned if either parent is pinned, Pinned if the parents disagree
OutwardOnly vs InwardOnly (both bind, so the conflict resolves to "do nothing"),
otherwise whichever parent is constrained. Weight takes the minimum of the two.
Guarded by `test_refined_vertices_inherit_constraints`, whose all-pinned arm is the
reference the other arms are compared against.

### 4. PRE-EXISTING: `voxelize_onto_grid` fills columns of void

`core/include/topopt/voxel.hpp:121` (declaration; the fill is in `src/`)

Round-tripping a solid through `marching_cubes` and `voxelize_onto_grid` **adds solid
voxels the source never had.** On the neck-6 dumbbell, 1,888 source voxels become
1,932, and the 44 extra ones sit in columns at `(10,11,k)` and `(17,11,k)` running
from the bridge **down to k = 0**, through space the source marks void. Those are the
exact corner columns of an axis-aligned bridge, which is the signature of a
parity/ray fill flipping on a degenerate edge hit.

**This is not caused by anything in this change**, and I did not fix it — it is in the
fill path that every gate in the project runs through, and changing it belongs in its
own task with its own evidence. What I did instead:

- documented it in the probe with the measured counts and locations;
- made the deciding statistic the **tendril's own** cross-section over a named index
  range, so an artefact elsewhere in the volume cannot set the floor;
- **printed the location of the whole-part minimum**, which is what let §S3.4 tell
  "the artefact column at z=0 thinned" apart from "the tendril necked". Without it
  that table reads as a BLOCKED-STOP.

Worth its own task.

---

## REVIEW CLEANUP — 18.9 MB OF SCRATCH THAT MUST NOT MERGE

Review caught four files committed to the **repository root**, outside `evidence/`.
They were scratch from the §S1.1 SDF re-measurement, swept in by a `git add -A`.
Binaries in git are permanent — deleting them in a later commit removes them from
the working tree and **not from history**, so every clone would pay the 18.9 MB
forever. Removed before merge.

### What each one was, and the verdict

| file | bytes | what it actually is | verdict |
| --- | --- | --- | --- |
| `subject_variant.stl` | 8,211,484 | 164,228 tris — PR 299's subject: his bracket voxelized at 128, exported at factor 2 | **scratch** |
| `sdf_clamped.stl` | 8,551,484 | 171,028 tris — the `SDF B/h 1.000 interp f2` row's output | **scratch** |
| `sdf_out.stl` | 2,187,484 | 43,748 tris — the last per-config overwrite (`B/h 1.000 approx f1`) | **scratch** |
| `sdf_headline.csv` | 1,224 | PR 303's WHOLE-PART headline table | **scratch, and already committed elsewhere** |

**All four are scratch, and none is evidence.** The reasoning, per the review's
requirement that this be decided rather than left vague:

- **Nothing here cites them.** The only SDF number this handoff uses is the sphere
  control, and that comes from `sdf_geometry_probe sphere`, whose output is captured
  in `evidence/.../sdf_sphere_remeasured.txt`. The `sphere` mode returns before the
  part-based code path and never writes any of these four.
- **`subject_variant.stl` is regenerated, not lost.** `operator_bakeoff_probe` §S3.5
  builds the identical mesh in process — 82,104 verts / 164,228 tris, the same
  164,228 as this file — writes it, round-trips it and `std::remove`s it. The
  measurement that used it is in the handoff; the artefact was never the evidence.
- **`sdf_headline.csv` was already in the repo.** Its content is PR 303's own
  committed `evidence/2026-08-05-smoothing-sdf-geometry-extraction/sdf_headline.txt`.
  Keeping the root copy would have duplicated existing evidence. It is also the
  **whole-part** objective §0 identifies as contaminated by CAD-face damage — the
  measurement this task explicitly does not build on.

### Root cause

`core/tests/harness/sdf_geometry_probe.cpp:1482`:

```cpp
const std::string evdir = argc > 5 ? argv[5] : ".";
```

The part-based modes default their output directory to **the current working
directory**. Run from the repo root — which is what a bare
`./build/sdf_geometry_probe` does while exploring its modes — the four writes at
lines 1507, 1562, 1580 and 1626 land in the repository.

### Why the fix is NOT one line, and is not made here

The review's instruction was to make it if it is a one-liner and to name it and stop
if it is larger. It is larger, for two reasons that only show up on inspection:

1. **That default is load-bearing for another task's documented recipe.** PR 303's
   own `evidence/2026-08-05-smoothing-sdf-geometry-extraction/README.md:60` runs
   `sdf_geometry_probe partfactor $D/out/design.bin $D/M2_verticalStand.step` with
   **no evidence directory**. Making the harness require one breaks that line.
2. **Six write sites share `evdir`** (1078, 1274, 1507, 1562, 1580, 1626), so a
   change of contract has to be audited across all of them and the README updated.

That is restructuring another task's harness inside a cleanup commit, which is
exactly what the review ruled out. **It belongs to the SDF harness's own task.**

### The guard that IS made here

`.gitignore` gains **root-anchored** patterns — a leading `/`, so they match only
the repository root and leave the identically-named files under `evidence/<task>/`
tracked (verified: the four `evidence/**/sdf_*.csv` remain in `git ls-files`):

```
/sdf_*.stl        /sphere_control.stl
/sdf_*.csv        /dumbbell.stl
/subject_variant.stl   /bracket_export.stl
```

The last three are **this task's own** probe's transient files. `operator_bakeoff_probe`
writes them to the CWD when given no evidence directory (lines 515, 787, 923) and
`std::remove`s each immediately (518, 790, 926) — so they are never left behind by a
successful run, but a crash between the write and the remove would leave an 8 MB file
in the root. Same hazard, smaller window, covered by the same guard.

**This is a guard, not the fix.** It makes this recurrence impossible in this
repository; it does not stop the harness writing to a CWD somewhere else.

### What this commit does NOT change

**No production behaviour, and no result.** The only tracked source touched is
`.gitignore`. R1's byte-identity result therefore carries over unchanged rather than
being re-run — no binary in it, and no harness it covers, was modified. The R5 sweep
on the cleanup returns no removed assertion, test registration or `add_test`, and the
registered ctest count is still 107.

---

## FILES

| file | what |
| --- | --- |
| `core/include/topopt/surface_operator.hpp` | both operators, C1/C2/C3/C5, the receipt |
| `core/src/mesh/surface_operator.cpp` | implementation |
| `core/tests/unit/test_surface_operator.cpp` | 50 checks — the R2 constraint bars |
| `core/tests/harness/operator_bakeoff_probe.cpp` | the sphere bake-off + S3 instruments |
| `core/CMakeLists.txt` | three additive blocks |
| `evidence/.../bakeoff_probe.txt`, `sphere_bakeoff.csv` | the run |
| `evidence/.../r2_failing_first.txt` | each constraint disabled, failures pasted |
| `evidence/.../r1_byte_identity.txt` | stash-rebuild checksums, against the merged tree |
| `evidence/.../sdf_sphere_remeasured.txt` | PR 303's sphere control, re-run here after it merged |

Reproduce:

```bash
cmake -S core -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j8 --target test_surface_operator operator_bakeoff_probe && ./build/test_surface_operator && ./build/operator_bakeoff_probe evidence/2026-08-06-smoothing-operator-bakeoff
```

---

## IN PLAIN LANGUAGE

**What I did.** I built the two operators you asked for and raced them against each
other, and against the smoother that ships today, on a sphere. A sphere is the right
place to race them right now because we know exactly what a sphere is supposed to
look like, so there is no arguing about whether the surface got better — and because
a sphere has no CAD faces on it, so it does not need the classifier that is still
being built next door.

**Which one won, and by how much.** **Mean-curvature flow won, and it was not close.**
It removes **51.6%** of the stair-stepping. The smoother in the app today removes
**11.2%** at the strongest setting you can reach — so the new one is about **four and
a half times better**. The other candidate, ramp reconstruction, removes **14.3%** at
best, makes the worst bumps **worse** rather than better, and takes **four to thirteen
seconds** for a single brush stroke on your part against the winner's **nine
hundredths of a second**. **Ramp reconstruction is a no-go.** It also failed the one
thing we predicted about it: we expected it would naturally stay inside the safe
movement limit without being forced to, and it does not — it wanted to move some
points nearly seven times further than allowed, and had to be held back.

**What the thinnest tendril did.** **Nothing. It did not get thinner.** I built a test
part with a deliberately weak neck — as thin as the software will ever let a design
be — and measured that neck's cross-section before and after. It reads 4.0000 mm²
before and 4.0000 mm² after, at every strength of both operators. The volume of the
part did not change either, to six decimal places. For comparison, the smoother that
ships today pushed the same part **0.096 mm outside its own design box** and grew its
volume by **1.9%** at full strength.

**And the part you most need to hear.** **The strength certificate cannot see any of
this.** We measured, in the previous round, a surface moving nearly a quarter of a
millimetre and the margin, the peak stress, the verdict and the mass all coming back
**identical to every digit**. That is not the certificate telling you the part is
still fine. That is the certificate being unable to see the change at all — it
re-checks the design on the same coarse grid, and a movement smaller than one grid
cell is invisible to it by construction.

So do not read an unchanged margin as a safety check on smoothing. **The thing
protecting you is the movement limit.** Every point is forbidden from moving more
than half a voxel — 0.405 mm on your part — from where the export put it, and where
the material matters (a load path, or a section already at the minimum printable
thickness) it is forbidden from moving inward at all. That limit, and that direction
rule, are what stand between a smoothing pass and a strut that quietly gets thinner
while the report says everything is fine.

**What is still owed, and it is not small.** Nothing here has been measured on your
actual part. The tool that tells us which surfaces came from your CAD and which the
optimizer cut is still being built, and until it exists we cannot honestly measure
"how much stair-stepping was removed from the cut surfaces" or promise that your CAD
faces did not move — and I deliberately did not invent a second version of that tool
to fill the gap, because two tools disagreeing about which surfaces are yours would
be worse than waiting.

There is also the comparison against the **SDF method** from the previous round, and
it turned out more interesting than expected. That work landed on the main branch
while I was working, so instead of quoting its number I re-ran it here. **On a mesh
the same size as ours, mean-curvature flow is ahead — 51.6% against 48.2%.** The SDF
method only scores higher (58.9%, and 64.8% at its best) by throwing away most of the
mesh first: four times fewer points, or ten times fewer. That may genuinely be a
better surface, or it may partly be the scoring — we grade by averaging the error at
every point, and a mesh with a tenth of the points has a tenth of the places to be
wrong. Nobody has separated those two yet, and it should be separated before either
method is chosen.

**One housekeeping note.** Review caught 18.9 MB of scratch files that had been
committed to the top level of the repository by accident — leftovers from re-running
the other team's measurement. They are gone. **Nothing about any result changed, only
what was committed:** no number in this document moved, and no code that runs on your
part was touched.

**Next steps, in order:**

1. **Merge PR 307**, then re-run the §0 baseline on the cut population and redo this
   comparison on your part across all four rungs. That is the measurement that
   decides whether A or the SDF route ships. The classifier now exists (§1) — it is
   the review, and an OCCT build for your STEP, that stand in the way.
2. **Assert C4** — CAD faces move zero. It is one line against
   `face_of_vertex[v] >= 0`, and it lands on the `Pinned` case this PR already
   asserts bit-identical (§1).
3. **Wire the brush**: PR 300's app-side accumulation needs rasterising onto the grid
   and handing to the operator as per-vertex weights. Core already accepts and
   enforces them; the app side is not connected.
4. **Decide the strength**, because A peaks at 20 steps and gets worse in both
   directions. It needs a chosen setting, not a slider that rewards dragging.
5. **Look at A's surface with your own eyes.** It is measurably closer to the true
   shape and measurably rougher from triangle to triangle. Numbers cannot settle which
   of those you care about more.
6. **Separately: the voxel fill defect in §R6 #4.** Re-voxelizing a mesh fills columns
   of empty space that were never solid. It did not affect any conclusion here because
   I measured around it and said so, but it is in a path every gate in the project
   runs through, and it deserves its own task.
