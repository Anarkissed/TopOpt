# The SDF route removes three times more stair-stepping than the app's smoother — and it is still not a drop-in replacement.

**Slug:** `smoothing-sdf-geometry-extraction` · **Branch:**
`claude/smoothing-sdf-geometry-477925` · started from `main` at `b3abcf8`, with
PR 299's harness commit `3eedf16` cherry-picked so its metric could be re-used
rather than re-typed.
**Evidence:** `evidence/2026-08-05-smoothing-sdf-geometry-extraction/`

---

# S1's ANSWER, IN ONE SENTENCE

**On your part it removes 21.5% of the stair-step amplitude — three times the
6.9% your app's smoother manages on the same surface, and 58.9% on an exact
sphere against that smoother's 11.2% — but it does not beat the strongest Taubin
setting that exists (23.4%), and on all four of your real rungs it leaves the
original part surface 41% *less* well covered than today and produces a mesh the
certification refuses outright.**

---

# 0. WHAT CHANGES FOR YOU

**Nothing in the app changes. No production file was touched. This is a
measurement, and the answer is "partly, and not on the part you are printing".**

PR 299 told you the smoother you have cannot remove stair-stepping. That stands.
This task measured the replacement you chose — the signed-distance route of
Ježek, Kopačka, Isoz, Gabriel, Šotola, Maršálek, Rybanský and Halama
(arXiv:2512.06976) — on **your** part, your four rungs, and an exact sphere, with
PR 299's ruler unchanged and the old smoother re-run on the same shapes so the
comparison is fair.

**What it does well.** On a smooth curved surface it is a large, genuine
improvement: 58.9% of the deviation gone on an exact sphere where your smoother
manages 11.2%. It holds volume to a ten-thousandth of a percent, better than the
0.03% the paper claims for itself. And on every one of your four rungs it removes
**80–86% of the min-feature violations** — 388 → 53, 527 → 106, 604 → 92,
674 → 113 — where the smoother you have removes essentially none at any setting.
That is the print-reliability count, not a cosmetic one.

**What it does badly, and it is not small.** Your part is a stand: flat faces,
bolt bores, sharp edges. The method smooths those too. Measured from a fixed set
of points on your original CAD shape — the same points for every version, so
nothing can flatter itself — the SDF surface covers your part **41% worse** than
what you export today, on every rung. And the mesh it produces **cannot be
certified at all**: the strength check refuses it, because the smoothing eats 34
of the 5,165 voxels that carry your declared load and the certification only
carries a load onto a mesh that still has material there.

**Three things worth knowing regardless of what you decide.**

* **Most of the method is not doing the work.** The pipeline has five stages;
  the first two — average the densities onto cell corners, contour that — deliver
  19.3% in 0.6 seconds. The signed-distance field and the RBF smoothing that
  follow take another 7 seconds and change the answer by under 1%. With the
  reference implementation's own default settings the RBF stage is very nearly
  the identity, and I can show why in its code.
* **Your certificate cannot see a smoothing at all.** Smoothing your rung-0.68
  mesh with Taubin moved its surface 0.23 mm and produced a certificate with the
  *same* margin, the same peak stress, the same verdict and the same voxel mass,
  to every digit. That is S4, and option 3 there is a day of work that stops the
  page implying otherwise.
* **A "resolution" slider over triangle count would be a lie, on your part
  specifically.** Measured here: factor 1 → 2 → 4 is 16× the triangles, the
  deviation flat at 0.376 → 0.373 → 0.366 mm, and the dihedral roughness cut by
  63%. It would look like a big improvement in every readout and be the same
  surface in the same place.

---

# S1 — DOES IT BEAT 10.6% ON HIS OWN PART? **PARTLY. Three times better than the smoother you have; not better than the strongest Taubin setting that exists.**

## S1.0 The one-sentence answer

**On your part the SDF route removes 21.5% of the stair-step amplitude at its
best grid spacing, against the 6.9% your app's smoother achieves on the same
surface — and against 23.4% for the strongest Taubin setting PR 299 could find.
On an exact sphere it removes 58.9% against Taubin's 11.2%. It moves the surface
0.90 mm (0.53 voxel) doing it, though never outside a vertex's own voxel cube
(S3.4), and on all four of your real rungs it leaves the original part surface
41% less well covered than today.**

## S1.1 First: your part is not the part PR 299 measured, and that matters

PR 299 measured on `WallMount_ShelfBracket.stl`, an older job's fixture. The run
this task is about is `M2_verticalStand.step`, worker job `7ba2442960a24050` —
your four rungs `[0.68, 0.52, 0.38, 0.26]`, `conditional_projection_fired
[false, true, true, true]`, resolution 128. Its grid is **128 × 31 × 118 at
1.705279 mm**, so its longest axis is 128 × 1.705279 = **218.28 mm**.

**Those are exactly the two numbers the original brief quoted** — "218.28 mm
across with a ~1.705 mm voxel". PR 299 read them against `WallMount_ShelfBracket`
and reported them as wrong (that fixture is 207.365 mm at 1.620 mm, and it is).
Both readings are correct; they are about different parts. The brief was
describing THIS run all along.

**So the "10.6%" bar could not simply be carried over.** Taubin is re-run here on
these subjects, at the strength the app can ask for and at the best setting
PR 299 found anywhere in the family (λ = 0.90, k_PB = 0.05, 20 pairs), so every
comparison below is between rows measured on the same mesh with the same code.

**And the reference itself is better here.** Your part is a STEP, so the CAD it
is measured against can be tessellated as finely as wanted. Measured control:

```
run tessellation   1555 verts,  3106 tris (linear defl 0.100 mm, angular 0.50 rad)
fine tessellation 48016 verts, 96028 tris (linear defl 0.005 mm, angular 0.05 rad)  <- THE REFERENCE
run tessellation deviates from it: max 0.0588 mm  rms 0.0073 mm (0.4% of one voxel)
```

The reference's own faceting is **0.4% of a voxel**. On PR 299's bracket it was
not: that fixture is a 2,224-triangle mesh whose curved faces meet at more than
30°, and when this probe classifies vertices by proximity to a ≥30° reference
edge, **all 28,884 of PR 299's oblique vertices on the bracket are "near a sharp
reference edge"**. A slice of the 0.3424 mm PR 299 measured there is the
reference's own faceting, which no smoother can remove because it is not on the
part. The bracket run is kept for continuity (`sdf_headline.txt`, 4.6% removed)
but the numbers that matter are on your part.

## S1.2 The metric (bar R3) — unchanged, and proven unchanged

Surface deviation from the pre-voxelization CAD, in millimetres, per vertex,
restricted to OBLIQUE vertices classified by the normal of the nearest CAD
triangle (within 0.02 of an axis ⇒ axis-aligned). Max, RMS, p99, all-vertex RMS
and dihedral RMS, in PR 299's own table shape.

**It is not a re-implementation.** PR 299's measurement code was *moved* into
`core/tests/harness/stairstep_metric.hpp` and both probes now include it.
`stairstep_probe`'s output across that move is in
`evidence/.../r3_metric_move.txt`: **every geometric figure is identical to the
last printed digit** and only wall-clock columns differ.

**Two additions, both reported beside the unchanged number, never instead of it.**

1. **The CAD-side reading.** The oblique set is re-derived per mesh — it has to
   be, because the SDF route *re-extracts* the surface and its vertices have no
   correspondence with the old ones. That means a stage which pushes the surface
   away can shrink its own sample. So a second reading runs the other way: a
   FIXED set of points on the CAD (the fine tessellation's triangle centroids
   that had material against them in the unsmoothed variant — 94,705 to 96,028
   points depending on the rung), and the distance from each to the mesh. The
   same points score every row. Nothing a stage does changes which points are
   scored. **Its one bias, stated rather than left to be found:** the sample
   points are centroids of a CURVATURE-ADAPTIVE tessellation, so they are denser
   where the CAD is curved or near an edge than on a big flat face. It therefore
   weights the geometry the SDF route is worst at more heavily than an
   area-weighted reading would. It is reported for what it is — a check that the
   mesh-side reading is not flattering itself — and the mesh-side oblique number
   stays the headline.
2. **The part skin.** An optimizer variant's surface is mostly surface the
   optimizer CUT, which never existed in the CAD. PR 299's metric is undefined
   there and reads 11–15 mm on your rungs — that is how much material came out,
   not how stair-stepped anything is. The skin reading restricts the same metric
   to vertices within one voxel of the CAD. Counts are printed on every row.

## S1.3 (b) THE ANALYTIC SPHERE — the reference that cannot be blamed

R = 20 mm at a 1.620040 mm voxel, through the same export path and the same STL
round trip PR 299 used, so the baseline row is PR 299's row.

```
configuration               max mm    rms mm % of base     verts
unsmoothed (PR 299)         0.7266    0.3307     100.0     11232
SDF B/h = 3.300             0.3920    0.1164      35.2      1062
SDF B/h = 2.000             0.4647    0.1361      41.1      2886
SDF B/h = 1.000             0.4909    0.1714      51.8     11502
SDF B/h = 0.500             0.4862    0.1664      50.3     45390
SDF B/h = 0.250             0.4898    0.1674      50.6    180342
SDF B/h = 0.125             0.4906    0.1683      50.9    721205
```

**48.2% removed at the paper's own recommended spacing (B = the element size),
58.9% at B/h = 2, 64.8% at B/h = 3.3.** Volume comes back to 33096.3 mm³ against
a target of 33096.3 mm³ on every row.

PR 299's Taubin on this identical sphere: **11.2%** at the shipped maximum and
**33.5%** at 160 pairs — eight times what the app can ask for, by which point the
sphere is visibly melted. Against the shipped maximum the SDF route is **4.3×
better** at the paper's spacing and **5.3× better** at the best one; against
Taubin pushed eight times past its limit it is still **1.4× to 1.8× better**, and
it holds the volume exactly while doing it.

**On a smooth closed surface with a known answer, the SDF route wins and it is
not close.**

One warning the sphere gives that his part then confirms in the other direction:
**the coarsest spacing is the BEST here and the WORST on his part.** A sphere has
no fine geometry to lose, so a coarse SDF grid is pure smoothing; his part has
plenty, and at B/h = 3.3 the same setting takes his min-feature violations from
36 to 367 (S1.7). Do not read "B/h = 3.3 removes 65%" as a recommendation.

## S1.4 (a) YOUR PART — the occupancy subject, where a CAD reference exists everywhere

This is your part voxelized on your run's own grid and exported through your own
path (`marching_cubes_resampled`, factor 2, Tricubic, then the STL round trip).
Every row is measured with the same code on the same mesh.

```
configuration          obl max  obl rms  obl p99  all rms  CAD-side  dihed  motion  removed   mf  comp
                            mm       mm       mm       mm    rms mm    deg      mm        %  viol
as exported today       0.9589   0.3728   0.7539   0.2826    0.7632   7.67  0.0000     0.0%   36     1
isocontour only         1.1160   0.3008   0.6899   0.2765    1.0717   4.14  0.8990    19.3%   31     1
SDF B/h 1 interp f2     1.1179   0.3046   0.6720   0.2735    1.0619   4.16  0.7562    18.3%   28     1
SDF B/h 2 interp f2     1.1373   0.2927   0.7380   0.2804    1.1504   6.39  0.9001    21.5%    8     1
Taubin shipped max      0.8756   0.3471   0.7352   0.2735    0.7880   7.24  0.1584     6.9%   36     1
Taubin best-found       0.8958   0.2855   0.6438   0.2517    0.8540   4.48  0.4508    23.4%   36     1
```

**The bar, re-measured on your own part: your app's smoother removes 6.9%. The
SDF route removes 21.5%. Taubin's best-found setting removes 23.4%.**

* Against what the app can actually ask for, the SDF route is **3.1× better**.
* Against the strongest Taubin setting that exists anywhere, it is **8% worse**.
* It moves the surface **0.90 mm** (0.53 voxel) doing it; Taubin's best-found
  moves it **0.45 mm**.
* It takes the min-feature violation count from **36 to 8**. Taubin leaves it at
  36 — at both settings, on every subject measured.
* It holds the volume to **+0.0001%**. Taubin drifts +0.0228% (shipped) and
  +0.0708% (best-found).
* **And it is 39% worse on the CAD-side reading** (0.7632 → 1.0619 mm), where
  Taubin's best-found is 12% worse (0.8540) and Taubin's shipped setting 3%
  (0.7880). That column is the one no stage can flatter, and it is the column
  that says the SDF route is trading sharp-feature fidelity for smoothness. The
  sharp-edge split is the mechanism: on the smooth part of the oblique surface it
  gains **+20.9%** while on the part near a sharp CAD edge it loses **−6.4%**.

## S1.5 The stage decomposition — the SDF and the RBF are almost all cost

The pipeline has five stages. Running only the first two — map element densities
to nodes, take the volume-matched isocontour, extract that, **no SDF and no RBF
at all** — gives:

```
isocontour only          0.3008 rms   19.3% removed   dihedral 4.14   0.6 s
SDF B/h 1 interp f2      0.3046 rms   18.3% removed   dihedral 4.16   7.4 s
```

**The isocontour alone gets 19.3% and costs 0.6 s. The full pipeline gets 18.3%
and costs 7.4 s** — twelve times the wall clock for a result that is, on this
subject, slightly worse. On your four rungs the two track each other closely
too: the largest gap in any deviation column is 6.7% and the largest in the
min-feature count is 14% (81 against 92, on rung 0.38), with the isocontour ahead
on two rungs and behind on two.

What the SDF and RBF stages *do* buy is exact volume control (the isocontour's
threshold bisection lands −0.094% on the occupancy subject; the shifted SDF lands
+0.0001%) and slightly less surface motion. They do not buy smoothness.

There is a structural reason, and it is worth stating because the paper's text
does not: **with the reference's own default settings the RBF step is very nearly
the identity.** `rho2sdf.jl` defaults to `rbf_interp = true` and
`rbf_grid = :same`, which means it solves `A s = φ` so the smoothed field
reproduces φ *exactly at every grid point*, and then evaluates it *on those same
grid points*. The smoothing in this method is in the NODAL MAPPING — averaging
element densities onto nodes is an approximating (not interpolating) operator,
and that is what takes the terraces out. The approximation variant (weights = the
raw SDF, i.e. a true Gaussian blur) was measured too and is strictly worse:
−11.2% on PR 299's fixture, i.e. it makes the deviation larger.

## S1.6 (a) YOUR FOUR RUNGS — where it does not help

Per rung, because the amount of grayscale differs per rung exactly as the brief
said: `conditional_projection_fired = [false, true, true, true]`, with rung
mnd `[0.0648, 0.1007, 0.1090, 0.1077]`.

**The oblique headline is meaningless on a rung** and it is important to say so
rather than quote it: it reads 1.28 / 2.15 / 3.02 / 3.57 mm as exported, which is
the distance from the CAD to a surface the optimizer *cut*, not a staircase.

The CAD-side fixed-sample reading is the honest one, and it says the same thing
on all four:

```
rung   as exported   isocontour   SDF B/h1   Taubin shipped   Taubin best
0.68      0.7680       1.1164      1.0864       0.7929          0.8596   mm rms
0.52      0.7690       1.1045      1.0879       0.7940          0.8611
0.38      0.7692       1.0988      1.0818       0.7942          0.8614
0.26      0.7693       1.0874      1.0762       0.7944          0.8616
```

**The SDF route makes the CAD-side deviation 40–42% WORSE on every rung**, and
Taubin makes it 3% (shipped) to 12% (best-found) worse. Nothing improves it,
because it is dominated by the CAD surface the optimizer legitimately removed.
What it separates cleanly is which method disturbs the *remaining* boundary more,
and the answer is the SDF route by a factor of three to twelve. It is
not a measurement artefact: the same reading on the occupancy subject moves
0.7632 → 1.0619 (39% worse), and the sample set is FIXED — 94,705 to 96,028 CAD
points, the same points for every row of a subject, chosen before any stage runs. The mechanism is visible in the sharp-edge split — on the
occupancy subject the smooth-surface part of the oblique set improves **+20.9%**
while the near-sharp-edge part gets **−6.4% worse**. The method rounds features
that are supposed to be sharp. Your part is a stand: flat faces, bores and edges.
It has comparatively little of the smoothly curved surface the method is good at,
and a great deal of the sharp geometry it damages.

**What it does do on your rungs, and Taubin does not:**

```
rung   min-feature violations           components
       exported  SDF   Taubin(both)     exported  SDF
0.68     388      53      384 / 382       11       9
0.52     527     106      527 / 524       17       9
0.38     604      92      604 / 604        5       4
0.26     674     113      674 / 674        2       1
```

**80–86% of the min-feature violations gone, on every rung, at exactly preserved
volume** (86.3 / 79.9 / 84.8 / 83.2%; the isocontour-only stage is 82–87%).
Taubin removes between 0% and 1.5% of them. That is not a cosmetic
number — it is the print-reliability count the V3 gate reads, and terracing is
what generates it.

## S1.7 The SDF grid spacing (the paper's §5.2, re-measured on your part)

The paper's guidance is that the spacing should approximately match the element
size, that too coarse loses geometry, and that too fine loses the smoothing
because the method starts reproducing the original element isocontours. **Two of
those three reproduce on your part; the third does not.**

```
B/h    obl rms   removed   dihed   motion   min-feature   verts    wall
       mm                  deg     mm       violations             s
--     0.3728      0.0%    7.67    0.000        36        139688   —
3.300  0.3728      0.0%    9.01    1.701       367         13084   4.3
2.000  0.2927     21.5%    6.39    0.900         8         38254   4.1
1.500  0.3012     19.2%    5.35    0.905         5         62718   4.9
1.000  0.3046     18.3%    4.16    0.756        28        154524   7.3
0.750  0.3057     18.0%    3.12    0.881        28        250840   11.4
0.500  0.2997     19.6%    2.73    0.908        28        563135   23.9
```

* **Too coarse is a catastrophe, exactly as the paper says.** At B/h = 3.3 the
  deviation is no better than doing nothing, the surface has moved 1.70 mm (a
  whole voxel), and the min-feature violations go from 36 to **367**. Geometry is
  being lost, not smoothed.
* **The optimum is B/h ≈ 1.5–2, not 1.** The paper recommends matching the
  element size; measured, B/h = 2 is the best row on your part (21.5%) and on the
  sphere (58.9% vs 48.2%).
* **Too fine does NOT lose the smoothing here.** From B/h = 1 down to 0.5 the
  deviation is flat at ~0.30 mm; it converges rather than degrading, and the
  sphere confirms it down to B/h = 0.125. The reason is structural: in this
  pipeline the smoothing comes from the nodal averaging (S1.5), which happens
  before the SDF grid exists, so refining the SDF grid resolves that already
  smooth surface better rather than re-finding element isocontours. **What too
  fine costs is time and triangles** — 23.9 s and 563,135 vertices at B/h = 0.5
  against 4.1 s and 38,254 at B/h = 2.

That table is the evidence behind any slider (S5).

## S1.8 The reference implementation, and what it could and could not do (bar R4)

**Every number the paper reports is a claim; the ones testable here were tested.**

* **"Volume fraction 0.3000 → 0.3001", i.e. 0.03%.** REPRODUCED and beaten: the
  volume-preserving shift lands within **0.0001%** on your part and on the sphere,
  on every configuration in every table above. This part of the paper is solid.
* **"Peak stress 0.3010 → 0.2543 MPa" and the deformation energies.** NOT
  reproduced here — they are properties of the paper's own cantilever, not of
  your part. The analogous measurement on your part is S2, and it does not agree
  in direction.
* **"Convergence order p ≈ 1.94."** NOT tested. It is a statement about the
  volume error of a discrete isocontour under refinement, which is a property of
  the quadrature, not of what the method does to a staircase.
* **"May affect precision at boundary condition interfaces."** REPRODUCED, and it
  is the single most important sentence in the paper for this project. See S3.

**The reference implementation could not be driven from your density field, and
the reason is one line.** `Sign_Detection_HEX8`
(`src/SignedDistances/SignDetection.jl:29`) builds its candidate list with

```julia
candidate_elements = [el for el in 1:nel if is_point_inside_aabb(x, element_aabbs[el]...)]
```

inside a loop over every grid point. Your run is **468,224 elements** and the SDF
grid at the paper's own recommended spacing is **487,620 points** — 2.3 × 10¹¹
AABB tests for a single field, before any distance is computed. It would also
have to be given a hex mesh of 468,224 elements and 487,620 nodes as
`Vector{Vector{Float64}}`, which is a further problem of a different kind.

**So S1 is measured by a port, and the port is checked against the reference
rather than asserted to match it.** `evidence/.../julia_reference/crosscheck.jl`
drives rho2sdf.jl v0.1.0 on a 12×12×12 regular hex grid with a grayscale radial
density ramp — small enough for the reference to finish, regular enough to
exercise exactly the specialisation the port claims. Result:

```
target volume   reference 284.783683815   port 284.783683815   (diff 1.592e-10)
rho_t           reference 0.416259765625  port 0.416259765625   (diff 0.000e+00)
nodal densities 2197 values: worst |port - reference| 4.697e-13, rms 1.303e-13
SDF 6859 points: within 2 cells of the surface (916 points) worst 0.0197 mm
```

The threshold agrees **bit for bit**. The nodal densities agree to 4.7e-13, which
is the check that matters most: the port claims that on a regular grid the
paper's least-squares linear fit (eq. 7–9) *is* the arithmetic mean of the
incident elements, and that is now measured rather than argued. The distance
field agrees to 0.0197 mm (1.2% of a cell) near the surface, which is the
tessellation bound of the port's substitution for the reference's Newton
projection. (Away from the surface the reference stores a ±1e10 sentinel for
points it never projected, which its own `process_vector` clamps later; the port
bands instead. That is the whole of the large "worst" figure in the raw output.)

**One trap for anyone repeating this.** rho2sdf.jl crashes on Julia 1.12 unless
the thread pools are pinned: it sizes per-thread buffers with
`Threads.nthreads()` and indexes them with `Threads.threadid()`, and on 1.12
`maxthreadid()` exceeds `nthreads()` because of the interactive pool. `julia -t 4`
still crashes (`maxthreadid() == 8`). Only `julia -t 1,0` ran.

# S2 — VOLUME PRESERVATION IS NOT MARGIN PRESERVATION

## S2.1 The paper's volume claim holds. Better than it claims.

The paper reports the uniform shift holding the volume fraction to about 0.03%
(gripper 0.3000 raw → 0.3001 SDF). **Measured on your part and on the sphere, on
every configuration in every table in S1: 0.0001% or better.** The bisection on
the shift parameter c converges in 18–34 evaluations and the achieved volume
tracks the target to five or six significant figures. This part of the method is
not in doubt.

The shift values themselves are small and are reported per row in
`sdf_part.txt` — c = +0.032 mm on the occupancy subject at B/h = 1, for example.

**One defect in the reference implementation, found here and worth naming.**
`RBFs4Smoothing.jl` solves the shift on the COARSE grid
(`th = LS_Threshold(LSF_array, coarse_grid, mesh, 4)`) and then applies it to the
FINE one (`fine_LSF .+ th`). The coarse trilinear volume of an RBF field is not
the fine one, and on your part that costs **1.42% of volume** — fifty times the
paper's own stated tolerance. Solving the shift where the surface is actually
extracted brings it back to 0.0001%. The port defaults to the corrected
behaviour and can reproduce the reference's; both are in `sdf_geometry_probe.cpp`
(`Config::shift_on_fine`).

## S2.2 The certified margin: two of the four meshes have one

Through the shipped seam, `topopt-cli analyze job_analyze.json --mesh <mesh>`,
on his own job with the mode switched to `analyze`:

```
rung   mesh                worst-case margin   peak stress   voxel mass   mesh mass   min-feature   wall
0.68   as exported today          2942         0.0187 MPa      543.6 g      540.2 g       388        91.6 s
0.68   Taubin shipped max         2942         0.0187 MPa      543.6 g      540.3 g       384        86.2 s
0.68   isocontour only        REFUSED — see S2.3                                                     14.4 s
0.68   SDF B/h 1 interp f2    REFUSED — see S2.3                                                     14.4 s

0.52   as exported / Taubin       3077         0.01787 MPa     472.5 g      469.6 g       527    85.3 / 83.7 s
0.38   as exported / Taubin       2983         0.01844 MPa     411.5 g      408.9 g       604    80.7 / 82.3 s
0.26   as exported / Taubin       2743         0.02005 MPa     359.1 g      356.8 g       674    72.5 / 74.9 s
```

(Full output in `s2_certification.txt`. Three of the four margins the exported
meshes reproduce — 2743, 2983, 3077 — are the numbers his run itself recorded in
`report.json` (2742.86, 2982.94, 3077.40), so the seam is answering the same
question the run answered. Rung 0.68 comes back 2942 against a recorded 2952.96,
a 0.4% gap, because this path re-voxelizes the exported STL where the run
certified the density field directly.)

**Two things fall out of that table immediately.**

1. **The certificate very nearly cannot see the smoothing.** The exported mesh
   and the Taubin-smoothed mesh certify to *identical* worst-case margin,
   identical peak stress, identical verdict and identical voxel mass on all four
   rungs; on rungs 0.52, 0.38 and 0.26 the mesh mass and the min-feature count are
   identical too, to every digit printed. The single difference anywhere in the
   table is rung 0.68's mesh mass (540.2 → 540.3 g) and its min-feature count
   (388 → 384). Taubin moved that surface 0.23 mm and the certified margin did
   not move at all — because the mesh is re-voxelized onto the same 1.705 mm grid
   before a single element is assembled (S4).
2. **The margins are enormous.** 2,743 to 3,077 against a required 1.5. Your part
   is three orders of magnitude stronger than the 24.5 N load asks for, so on
   THIS job no amount of smoothing could plausibly threaten the verdict. That is
   a property of this job, not a general safety argument, and it is why S2's
   answer here is about *reachability* rather than about a margin that fell.

(On mass: this run's variants read 356.8–540.2 g as meshes and 318.8–502.0 g
latticed. The 186.1 g in the task brief does not appear anywhere in this job's
artefacts, so that figure is from a different variant or a different run.)

## S2.3 BLOCKED-STOP: the SDF mesh has no certified margin, because it cannot be certified

Not "the margin fell". The seam refuses:

```
$ topopt-cli analyze job_analyze.json --mesh meshes/v068_sdf.stl
topopt-cli: fea_solve_mgcg_matfree: under-constrained system
            (load applied to a void DOF with no stiffness — no equilibrium possible)
```

on the SDF mesh and on the isocontour-only mesh, on every rung. Root cause and
counts are in S3.3: the smoothing erodes 34 of the 5,165 load-tagged voxels
(0.66%), the fixture survives intact, and `run_job.cpp:3745-3752` carries the
Load tag onto a substitute mesh only where that mesh still has material.

**So the S2 numbers the task asked for — margin before and after, through the
shipped seam — do not exist for the SDF route, and cannot be made to exist
without changing production code.** That is a listed BLOCKED-STOP ("the load
group ... moves enough to matter"), and it is reported rather than worked around.
The fix, if the maintainer chooses this route, is at that exact line and is the
same forcing core already applies to its own smoothing; making it here would be
building on a route that has not been chosen.

**What can be said about the margin without it:** the volume and therefore the
mass are preserved to 0.0001%, so nothing about the *quantity* of material
changed; what changed is 34 voxels of *where*, at the one interface the solver
cannot tolerate a hole in.

# S3 — THE FEATURES THAT MUST NOT MOVE

The paper names this limitation itself: its global smoothing "may affect
precision at boundary condition interfaces". On your part it is not a footnote.

**The measurement.** For each named face set, every mesh vertex sitting within
one voxel of it, and the SIGNED offset from the CAD surface — positive OUTWARD —
so "the bore rounded off" and "the anchor face drifted" are different numbers
with different signs rather than one unsigned blur. Bores additionally get their
radius read back directly against the B-rep cylinder axis
(`StepFaceInfo::axis_point` / `axis_dir` / `cylinder_radius_mm`), which is exact
and needs no tessellation at all. Full tables for all four rungs in
`sdf_features.txt` / `.csv`; rung 0.68 below.

## S3.1 The named interfaces

```
face set                      as exported today                SDF B/h 1 interp f2
                       signed mean   range              signed mean   range
anchor face 18            -0.1258   [-0.4869, -0.0353]     -0.0523   [-0.9481, +0.0569]
protected face 16         -0.0513   [-1.5110, +1.2395]     +0.0025   [-1.3854, +1.6847]
load group (21 faces)     +0.1537   [-1.6745, +1.6890]     +0.1240   [-1.6953, +1.7040]
every cylindrical face    -0.1741   [-1.7043, +1.6890]     -0.2520   [-1.7050, +1.7040]
```

**On average every one of them moves less than a tenth of a millimetre, and the
anchor face actually moves TOWARDS the CAD plane** (mean −0.126 → −0.052 mm).
That is the good news and it is real.

**The worst case is the problem.** The anchor face's most out-of-plane vertex
goes from 0.487 mm below the CAD plane to **0.948 mm below it** — the excursion
roughly doubles, to more than half a voxel. On a mounting face that is what
decides whether the part sits flat.

(The ±1.70 mm figures in the range columns are the selection cutoff — vertices
are gathered within one voxel of the face — not a measured excursion. The mean
and the bore radii below are the readings to trust.)

## S3.2 The bolt bores DO NOT round off

Read directly against each B-rep cylinder, rung 0.68:

```
bore face   CAD radius   as exported            SDF                   change
     19      30.0000 mm  29.9980 (-0.0020)      29.9836 (-0.0164)     -0.0144 mm
     21      30.0000 mm  29.9861 (-0.0139)      29.9661 (-0.0339)     -0.0200 mm
     32      30.0000 mm  30.0940 (+0.0940)      30.0950 (+0.0950)     +0.0010 mm
     58       3.0000 mm   2.9871 (-0.0129)       2.9346 (-0.0654)     -0.0525 mm
     61       3.0000 mm   3.1406 (+0.1406)       3.1130 (+0.1130)     -0.0276 mm
     62       3.0000 mm   3.0547 (+0.0547)       3.0982 (+0.0982)     +0.0435 mm
     63       3.0000 mm   3.0898 (+0.0898)       3.0861 (+0.0861)     -0.0037 mm
     64       3.0000 mm   2.9638 (-0.0362)       3.0845 (+0.0845)     +0.1207 mm
     65       3.0000 mm   3.0465 (+0.0465)       3.0053 (+0.0053)     -0.0412 mm
```

**No bore moves by more than 0.12 mm and most move by less than 0.05 mm.** This
was the disqualifier the task was most worried about and **it does not happen.**

The pattern inside the table is the same one S1 found everywhere. The three 30 mm
bores are 17.6 voxels in radius — plenty of surface for the method to work on —
and they move by at most **0.020 mm**. The six 3 mm bores are 1.76 voxels in
radius, which is barely resolved at all, and they carry every larger number in
the column, up to 0.12 mm on face 64 (which is also the smallest sample here,
281 vertices as exported and 227 after). Even there it is a twentieth of a
millimetre per side on a 3 mm hole: **nothing in this table would stop a bolt
going through.**

## S3.3 The thing that DOES break, and it breaks hard

**The certification refuses the SDF mesh outright.** Not a margin that fell — a
margin that cannot be produced:

```
$ topopt-cli analyze job_analyze.json --mesh meshes/v068_sdf.stl
topopt-cli: fea_solve_mgcg_matfree: under-constrained system
            (load applied to a void DOF with no stiffness — no equilibrium possible)
```

Root cause, measured rather than inferred (`sdf_geometry_probe loadcheck`,
`s2_loadcheck.txt`):

```
his load case on the solved grid 128 x 31 x 118 @ 1.705279 mm:
   5165 Load voxels, 3348 Fixture voxels

mesh                          Load kept  Load LOST   Fix kept   Fix LOST
v068_exported.stl                  5165          0       3348          0
v068_sdf.stl                       5131         34       3348          0
v068_isocontour.stl                5100         65       3348          0
v068_taubin.stl                    5165          0       3348          0
```

**34 of the 5,165 load-tagged voxels (0.66%) lose their material.** The fixture
survives intact; it is the load interface alone. And the code says exactly why —
`core/src/cli/run_job.cpp:3745-3752`:

```cpp
if (cert_grid.tags[i] == VoxelTag::Load) {
  // When WE smoothed, the loaded cap is restored solid (see above). For a raw
  // substitute mesh (no smoothing) keep 228's contract — certify what was
  // handed in, carrying the Load tag only where the mesh has material ...
  if (smooth.enabled) design_grid.tags[i] = VoxelTag::Load;
  else if (design_grid.tags[i] != VoxelTag::Empty)
    design_grid.tags[i] = VoxelTag::Load;
}
```

When core does the smoothing itself the loaded cap is FORCED solid. A mesh handed
in from outside does not get that, by design — and an SDF-smoothed mesh is
exactly a mesh handed in from outside. **This is a one-line reachability gap with
a named fix site, and it is deliberately NOT fixed here**: fixing it is building
on a route the maintainer has not chosen yet, which the task forbids.

## S3.4 The hard bound: Gibson's constrained elastic surface nets

Gibson (MICCAI 1998 / MERL TR99-24) constrains every surface node to remain
within its ORIGINAL surface cube, which bounds the error to one voxel BY
CONSTRUCTION rather than by tuning. The SDF route re-extracts rather than
relaxes, so the constraint is applied as its consequence: no output vertex may
sit further than `bound` from the unsmoothed surface, and any that does is pulled
back along the line to its closest point on it.

**Measured on HIS part** (`sdf_gibson.txt`), on the occupancy subject and on
rung 0.68, at both useful spacings:

```
                       obl max  obl rms  all rms  dihed  motion   removed   mf   pulled back   deepest
occupancy(CAD)
  as exported today     0.9589   0.3728   0.2826   7.67  0.0000     0.0%    36        —           —
  SDF B/h 1             1.1179   0.3046   0.2735   4.16  0.7562    18.3%    28        —           —
    + Gibson 0.5 voxel  1.1179   0.3046   0.2735   4.16  0.7562    18.3%    28     0.00%      0.0000 mm
    + Gibson 1.0 voxel  1.1179   0.3046   0.2735   4.16  0.7562    18.3%    28     0.00%      0.0000 mm
  SDF B/h 2             1.1373   0.2927   0.2804   6.39  0.9001    21.5%     8        —           —
    + Gibson 0.5 voxel  1.1178   0.2927   0.2804   6.39  0.8526    21.5%     8     0.02%      0.0474 mm
    + Gibson 1.0 voxel  1.1373   0.2927   0.2804   6.39  0.9001    21.5%     8     0.00%      0.0000 mm
rung 0.68
  SDF B/h 1            10.8761   1.2974   2.3307   5.42  1.0069    -1.5%    53        —           —
    + Gibson 0.5 voxel 10.8761   1.2974   2.3307   5.44  0.8526    -1.5%    53     0.27%      0.1543 mm
    + Gibson 1.0 voxel 10.8761   1.2974   2.3307   5.42  1.0069    -1.5%    53     0.00%      0.0000 mm
  SDF B/h 2            11.0353   1.3293   2.2853   8.68  1.6704    -4.0%    99        —           —
    + Gibson 0.5 voxel 11.0353   1.3271   2.2847   8.78  0.8528    -3.8%   108     0.60%      0.8177 mm
    + Gibson 1.0 voxel 11.0353   1.3293   2.2853   8.68  1.6704    -4.0%    99     0.00%      0.0000 mm
```

**At Gibson's own one-voxel bound the constraint is completely inert: 0.00% of
vertices move, on both subjects and at both spacings, and every S1 figure is
unchanged to four decimal places.** Tightened to half a voxel it touches 0.00% to
0.60% of vertices, pulls the worst of them back by at most 0.82 mm, and moves the
headline by at most 0.2 percentage points (−4.0% → −3.8% on rung 0.68 at B/h = 2,
where it also costs nine min-feature violations).

**That is the answer the task wanted, and it is a good one.** *The SDF route does
NOT beat Taubin by moving further than one voxel.* It is already inside Gibson's
bound everywhere, so whatever it gains is not "a different shape" — the gain is
real geometry within the error budget the voxelization already had. The `motion`
column quoted throughout S1 is a one-sided Hausdorff distance to the *nearest
point* of the old surface, which is a much weaker statement than "a vertex left
its own cube"; this is the measurement that separates the two, and it clears the
route.

# S4 — SCOPE ONLY: WHAT THE CERTIFICATE MUST DESCRIBE

**Your ruling, restated so it is on the record: you do not accept certifying the
blocky version. The certified object must be the object you print.**

## S4.0 The gap, with file and line

Certification is voxel-based end to end. `core/src/simp/analyze.cpp` works in
`grid.solid(i,j,k)` and `grid.voxel_count()` throughout (`:160`, `:223`, `:227`,
`:256-259`, `:296`), and the FEA it drives is an 8-node hexahedron on a regular
lattice (`core/include/topopt/fea.hpp:12, 43`). Any mesh handed to
`topopt-cli analyze --mesh` is re-voxelized onto the run's solved grid before a
single element is assembled — `core/src/cli/run_job.cpp:3741`:

```cpp
design_grid = voxelize_onto_grid(design_mesh, cert_grid);
```

The provenance file already says so in as many words (`run_job.cpp:4032`: *"the
analysed geometry is voxelized onto the SOLVED grid"*). **So sub-voxel surface
motion is invisible to the certificate by construction**, and S2.2 is that
statement measured: the exported mesh and the Taubin-smoothed mesh — 0.23 mm
apart — produce identical margins, identical stresses, identical masses and
identical min-feature counts on all four rungs.

## S4.1 Option 1 — certify on a finer grid derived from the smoothed SDF

**What resolution.** To see motion of the size this task is about you need the
certification grid to resolve it, which means at least halving the voxel:
resolution 256, 1.705279 → 0.852640 mm, 3.75 million elements against today's
468,224. The SDF grid itself is the natural source — at B/h = 1 it is already
144 × 47 × 134 = 906,912 points, about twice the design grid, and being a signed
distance field it can be resampled onto any lattice without re-meshing anything.

**A finding before the cost: the shipped seam CANNOT do this today.** The first
attempt certified the same exported mesh at each of the three resolutions.
Resolution 128 worked; **192 and 256 were both REFUSED with the same
under-constrained error the SDF mesh gets** — re-voxelizing a mesh onto a grid
finer than the one it came from leaves load-tagged voxels empty
(`s4_mesh_substitution_refused.txt`). So "certify the smoothed geometry on a
finer grid" is not a configuration change; it needs the same load-interface work
S2.3 names, on top of everything else. The cost below is therefore measured on
the object that CAN be certified at any resolution — the part itself.

**What it costs, measured on his part rather than extrapolated:**

```
resolution  voxel mm   elements    wall s   user s   peak RSS   margin   peak stress   min-feature
   128      1.705279    468,224     99.92    172.45    584 MB     2941    0.01870 MPa       36
   192      1.136853  1,580,256    769.49   1040.93   1,407 MB    2082    0.02641 MPa       13
   256      0.852640  3,745,792   see below — it did not finish
```

**The 256 row is a refusal by the machine, and that is the useful answer.** It
allocated a peak of 1.86 GB and then fell to about 2% duty — 20 minutes of CPU
accumulated over more than two hours of wall clock, at 93% of one core — while
this 16 GB Mac sat at 139 MB free with 1.9 million pages in the compressor. It
was not compute-bound, it was MEMORY-bound, and it was stopped rather than left
to thrash. At 3.7 million elements a certification of your part does not fit in
this machine alongside anything else.

(`s4_resolution_cost.txt`. All three rows were measured with two unrelated
optimization runs from other worktrees on the same Mac, so the wall figures are
an upper bound; user CPU time and peak RSS are the safer columns, and the memory
pressure that stopped the 256 row was partly theirs.)

**R5 note, and it is the same gap PR 299 found.** `FixedDesignAnalysis` records
the CG iteration count only on NON-convergence (`analyze.hpp:33-35`,
`non_convergent_iteration`). A converged certification does not surface it, so
the rows above carry wall clock and peak RSS but no iteration count. I did not
fabricate one and did not re-implement the solve to get one.

**The honest reading of that table has two halves, and the second one is the
important one.**

*It costs more than the element count says.* 128 → 192 is 3.4× the elements and
**6.0× the CPU time** and 2.4× the memory. Extrapolating that exponent (work
∝ elements^1.55) puts 256 at roughly 25× the 128 run — of the order of an hour of
CPU and 2.5 GB — for what today is a 100-second certification. On his device
rather than this Mac, and inside a page that already runs two certifications on
the first Apply (PR 299's S2(a)), that is not a background detail.

*And it does not answer the same question.* **The certified margin MOVED: 2941 at
resolution 128, 2082 at 192 — a 29% fall — with peak stress rising 0.01870 →
0.02641 MPa and the min-feature count falling 36 → 13.** Nothing about the part
changed; the grid resolved its stress concentrations better. So "certify the
smoothed geometry on a finer grid" is not a more accurate reading of the same
number. It is a different number, on a different grid, and every recorded margin
in every artefact this project has ever written was computed at the old one. A
finer certification has to come with a story about what happens to those — and
about a rung that passes at 128 and might not at 256.

## S4.2 Option 2 — certify on a tetrahedral mesh

The paper uses Isosurface Stuffing (Labelle & Shewchuk 2007) for exactly this,
and its advantages are real: guaranteed dihedral-angle bounds, adaptive
resolution near boundaries, and thin features — all three of which are properties
this project's designs have and its voxel grid handles badly.

**And it is a very large change. Saying so is the useful answer.**

What it touches, concretely:

* **The element library.** `fea.hpp` is hex8-only (`:12, :43`), plus a
  transversely isotropic hex8 for the layer model (`:51`). A tet path needs a
  tet4 or tet10 stiffness, a new quadrature, and a second transversely isotropic
  derivation for the interlayer knockdown.
* **The solver.** The matrix-free operator, the geometric multigrid hierarchy and
  the GenEO coarse space are all built on the regular lattice — coarsening is
  index arithmetic. On a tet mesh none of that survives; it becomes algebraic
  multigrid, which this project already measured as a NO-GO on its own
  (`algebraic-level1`, `hybrid-amg`).
* **Every gate.** `min_feature_violations`, the V3 suite, the clearance
  rasterizer, `voxelize_onto_grid`, the lattice boundary code and the design box
  are all grid-indexed.
* **The design itself.** The optimizer produces a density per voxel. A tet
  certification of a voxel design needs a mapping between them, which is the same
  interpolation question this whole task is about, now inside the certificate.

This is not a sprint. It is the shape of a different codebase, and it should not
be started to fix a 0.3 mm surface question.

## S4.3 Option 3 — the interim: say which object the margin describes

Not a fix. It stops the page implying something untrue while 1 or 2 is decided,
and it is a text change plus one already-computed number.

The certification already knows the gap — `run_job.cpp` discloses the
"quantization gap (mesh surface vs this voxelization)" in the provenance. The
page does not. The interim is:

* on the smoothing page, next to the margin, state the grid the margin was
  computed on and its voxel size in millimetres;
* state that surface changes smaller than one voxel do not move it — with the
  measured fact behind it, that a 0.23 mm Taubin smooth produces a certificate
  identical to the last digit;
* and when a smoothed mesh is shown, say whether the certificate on screen was
  computed for THAT mesh or for the one before it.

## S4.4 Recommended ORDER (your decision, not mine)

1. **Option 3 first, immediately.** It is a day of work, it removes an untruth
   from the screen, and it is independent of everything else. Nothing should ship
   before it.
2. **Then option 1, but scoped as a measurement rather than a feature.** The
   first thing to learn is not what it costs — that is measured above — but what
   it does to the VERDICTS. Re-certify a handful of already-accepted variants at
   192 and see how many stay accepted. On his part the margin fell 29% between
   128 and 192 while remaining 1,400× the requirement, so nothing flipped; on a
   part that passes at 2.0× rather than 2941×, it would. Until that is known, a
   finer certification is a change that can only lose verdicts, and it needs the
   load-interface fix from S2.3 before it can even be pointed at a smoothed mesh.
3. **Option 2 last, and only if 1 fails on its own terms.** Isosurface stuffing
   is the right answer to a question this project has not yet earned the right to
   ask — it is worth a great deal *if* the geometry is right and the certificate
   is the last thing standing in the way. It is worth nothing if S1 says the
   geometry is not yet right, which is where S1 currently stands.

# S5 — SCOPE ONLY: THE RESOLUTION CONTROL YOU ASKED FOR

Four separate answers, kept separate because two of them are traps.

## S5.1 WIREFRAME / X-RAY / INSPECTOR VIEWS — do it, small work

No measurement needed and no downside. **Most of it already exists.**

`MetalMeshView.swift` already carries a translucent x-ray body: a
`translucentBodyPipeline` (premultiplied "over" blending) with a depth state that
tests but does not write, "so back walls show through the front (the x-ray
read)", driven by a `bodyAlpha` uniform in buffer 1
(`MetalMeshView.swift:118-121`, `:505-506`, `:538-545`). It is wired to the load-flow modes
only. Pointing the smoothing page's stage at it is a binding change, not a
rendering project.

**Wireframe does not exist and is the only real work.** Two options, and the
second is the one to take:

* `setTriangleFillMode(.lines)` on the existing pipeline — one line, but it
  draws every triangle edge of a 300,000-triangle mesh, which at this density
  reads as grey fog rather than as structure, and it cannot show the *original*
  edges separately from the tessellation.
* A barycentric-coordinate edge shader (pass a per-vertex barycentric attribute,
  discard/darken near an edge in the fragment shader). Costs one attribute and
  ~10 fragment-shader lines, gives a controllable line width, and can be
  overlaid on the shaded surface instead of replacing it. This is the standard
  approach and it composes with the x-ray pass already there.

**Scope:** one new pipeline + one attribute in `MetalMeshView`, a two-state
segmented control on the smoothing page beside the existing Original/Smoothed
tabs, and the `bodyAlpha` binding. No core change, no solve, no certificate.

## S5.2 A SLIDER OVER MESH TESSELLATION — this would be a LIE. Do not ship it.

PR 299 measured export factor 1/2/4 on its own fixture and found the deviation
flat while the dihedral halved. **Re-measured here on YOUR part, so the claim is
about your geometry and not someone else's** (`sdf_partfactor.txt`):

```
-- your part's own voxelization --
factor        verts       tris  obl max mm  obl rms mm  dihed deg
1             34922      69840      0.8575      0.3757      12.29
2            139688     279372      0.9589      0.3728       7.67   <- what you export
4            558728    1117452      0.9917      0.3660       4.53

-- rung 0.68, the variant you actually print --
factor        verts       tris  obl max mm  obl rms mm  dihed deg
1             37434      74832     10.0444      1.3058      14.94
2            149256     298476     11.2928      1.2780       8.94   <- what you export
4            597676    1195316     11.1538      1.2781       5.11
```

**Sixteen times the triangles buys nothing about where the surface is.** The
dihedral angle falls by more than half, so the mesh *looks* smoother in a
wireframe and in any "roughness" readout — and it is the same surface in the same
wrong place. A control labelled "resolution" that does this is a control that
lies to the user about the object they are about to print.

If a tessellation control ships at all it must be labelled as what it is —
**triangle count / file size** — and it must sit nowhere near a claim about
accuracy.

## S5.3 A SLIDER OVER THE SDF GRID — this is the real one

It changes the exported surface, needs no FEA solve, and has a measured optimum
with two measured failure modes. S1.7 is its evidence:

```
B/h    obl rms   removed   dihed   motion   min-feature   verts    wall
--     0.3728      0.0%    7.67    0.000        36        139688    —
3.300  0.3728      0.0%    9.01    1.701       367         13084   4.3 s
2.000  0.2927     21.5%    6.39    0.900         8         38254   4.1 s
1.500  0.3012     19.2%    5.35    0.905         5         62718   4.9 s
1.000  0.3046     18.3%    4.16    0.756        28        154524   7.3 s
0.750  0.3057     18.0%    3.12    0.881        28        250840  11.4 s
0.500  0.2997     19.6%    2.73    0.908        28        563135  23.9 s
```

**What the control must say, and why:**

* **The useful range is B/h 1 to 2**, i.e. one to two voxels. Below 1 nothing
  improves and the cost triples; above 2 the part is damaged.
* **Coarser is NOT "faster and rougher", it is WRONG.** At B/h = 3.3 the surface
  has moved a whole voxel, the deviation is back to where it started, and the
  min-feature violation count goes from 36 to 367. That end of the slider must
  either not exist or must be labelled as destructive — it is not a
  quality/speed trade, it is a correctness cliff.
* **Finer is not better either, it is just slower.** From B/h = 1 to 0.5 the
  deviation is flat and the wall clock goes 7.3 s → 23.9 s and the mesh 154k →
  563k vertices. The user must be told this, because "finer = better" is the
  default assumption every slider carries.
* Note this contradicts one of the paper's own stated failure modes, honestly:
  §5.2.1 says too fine a grid "loses its intended smoothing capability and begins
  to faithfully preserve individual element isocontours". **Measured, it does
  not** — see S1.7 for why (the smoothing lives in the nodal mapping, upstream of
  the SDF grid). What too fine actually costs here is time and triangles.

**The honest label is not "resolution". It is something like "smoothing scale —
1 to 2 voxels", with the current voxel size shown next to it in millimetres, and
the two ends of the range explained.**

## S5.4 REMESH — recommend against it as a smoothing tool

Nomad's voxel remesher forces a uniform polygon size so that a sculpting brush
has predictable topology under it. That is a *sculpting* need, not an accuracy
one. **It cannot add surface accuracy, because the information is not in the
mesh** — it is in the field, and S5.2 is the direct measurement of that: change
the tessellation by 16× and the surface does not move.

Worse, a remesh would *lose* accuracy. It resamples an existing surface, so
whatever error that surface already carries is preserved and the resampling adds
its own. And it would break the one thing this project cannot break: the mesh the
certificate describes would no longer be the mesh the field produced.

**Recommend against it for smoothing.** If free-form sculpting is ever wanted for
its own sake, that is a different feature with a different justification, and it
must not be reachable from a page that shows a certified margin.

---

# BARS

**R1 — byte-identical when off, by stash-rebuild checksum, both binaries rebuilt
from one folder.** No production source is touched: `git diff origin/main --
core/src core/include app/TopOptKit/Sources` is **empty (0 lines)**. Everything on
this branch is a harness, a CMake block that is `EXCLUDE_FROM_ALL`, or evidence.
Proven rather than asserted, in two fresh build directories configured with
identical flags — one from the working tree, one from a clean `origin/main`
worktree:

```
digest of all 45 objects, working tree   : 47669432db84403491cedb838d3f46f0
digest of all 45 objects, origin/main    : 47669432db84403491cedb838d3f46f0
BYTE-IDENTICAL
extracted archive members: NO BYTE DIFFERS
```

**That is also the digest PR 299 recorded** (`evidence/2026-08-05-smoothing-must-
actually-smooth/r1_byte_identity.txt`), which is a second, independent
confirmation: two tasks, two independent harnesses, one metric moved between
files — and the shipped library has not moved a byte.

Full record in `evidence/.../r1_byte_identity.txt`, including the note on why the
objects are checksummed rather than the `.a` archive (`ar` embeds member mtimes;
both archives were also extracted and every member diffed).

**R2 — failing test first for anything I fix.** *Nothing was fixed.* This task is
a measurement with a qualified answer and two BLOCKED-STOPs (S2.3, and the "does
not clearly beat" reading of S1); the task's own instruction on that outcome is
to report and build nothing. Writing a test that asserts a reduction the method
delivers on a sphere and not on his part, and leaving it red in CI, would be
scaffolding of exactly the kind the task forbids. What exists instead is a
harness whose numbers ARE the result, plus three reproductions of defects found
along the way that are recorded rather than asserted:

* the reference implementation's `threadid()` indexing crash, reproduced verbatim
  in `evidence/.../README.md` trap 2;
* the reference's coarse-grid volume shift losing 1.42% of volume on his part,
  reproducible by flipping `Config::shift_on_fine` (S2.1);
* the certification's refusal of the SDF mesh, reproduced by one CLI command and
  root-caused by count in `s2_loadcheck.txt` (S2.3 / S3.3).

**R3 — the metric is PR 299's, unchanged.** Not re-implemented: PR 299's
measurement code was MOVED into `core/tests/harness/stairstep_metric.hpp` and both
probes include it. `stairstep_probe`'s output across the move is diffed in
`evidence/.../r3_metric_move.txt` — **every geometric figure identical to the last
printed digit**, only wall-clock columns differ. Two additions are reported BESIDE
the unchanged number and never instead of it, both named and justified in S1.2:
the CAD-side fixed-sample reading (because the oblique set must be re-derived on a
re-extracted mesh and could otherwise flatter itself) and the part-skin
restriction (because PR 299's metric is undefined on the surface an optimizer cut).
One procedural difference is stated rather than buried: for a re-extracted mesh
the oblique classification is re-derived by the same rule, because there is no
vertex correspondence to carry it across.

**R4 — every number quoted from the paper is a claim, tested.** S1.8 lists them
one by one: the volume-preservation claim reproduced and beaten (0.0001% against
their stated 0.03%); the stress and energy figures not reproduced because they
belong to their cantilever and not to his part, with the analogous measurement
being S2; the convergence order not tested and said so; and the "may affect
precision at boundary condition interfaces" caveat reproduced, in the strongest
possible form — it is the reason S2 has no margin to report.

**R5 — iterations and wall, always both, separately.** Every operator timing
carries its own count and its own clock: the RBF solve reports CG iterations and
relative residual per row (`sdf_part.csv` `cg_iters`, `cg_res` — 95–96 iterations
to 9.1e-09 on his part); the volume-shift bisection reports its evaluation count
(18–34); the threshold bisection reports its own. **The one gap is named rather
than filled:** `FixedDesignAnalysis` records the CG iteration count only on
NON-convergence (`analyze.hpp:33-35`), so every converged certification in S2 and
S4 is reported as wall clock and peak RSS with no iteration count. I did not
fabricate one. This is the same gap PR 299 found and handled the same way.

**R6 — no assertion weakened or deleted.** Nothing was removed or relaxed. The
only edit to an existing file is the metric MOVE, and R3 proves it output-
preserving. PR 299's own evidence files are untouched (its `stairstep_sweep.csv`
was overwritten by a re-run and restored from its branch).

**R7 — root cause with file and line for every defect found.**

* The certification refuses the SDF mesh: `core/src/cli/run_job.cpp:3745-3752` —
  the Load tag is carried onto a substitute mesh only where that mesh has
  material, and the SDF route erodes 34 of 5,165 load voxels (S3.3, counted).
* The certificate cannot see a smoothing: `core/src/cli/run_job.cpp:3741`
  (`voxelize_onto_grid(design_mesh, cert_grid)`) with `analyze.cpp:160, 223, 227,
  256-259, 296` working in `grid.solid()` throughout (S4.0).
* The reference implementation cannot be driven from his field:
  `rho2sdf.jl/src/SignedDistances/SignDetection.jl:29` (S1.8).
* The reference implementation crashes on Julia 1.12:
  `rho2sdf.jl/src/SignedDistances/sdfOnDensityField.jl:52, 193` —
  `nthreads()`-sized buffers indexed by `threadid()`.
* The reference implementation loses 1.42% of volume on his part:
  `rho2sdf.jl/src/SdfSmoothing/RBFs4Smoothing.jl`, `LS_Threshold` on the coarse
  grid applied to the fine one (S2.1).
* My own, found and fixed inside this task's harness before any number was
  quoted: the nodal lattice needed a one-element zero pad or marching cubes hung
  the surface half a voxel outside the part (`sdf_geometry.hpp`,
  `nodal_from_elements`); and `SharpEdges` built a `TriGrid` over a local mesh,
  leaving a dangling pointer that crashed in `dist2_point_triangle`.

**R8 — no unfilled placeholders.** Grepped. Every number in this document is in
`evidence/2026-08-05-smoothing-sdf-geometry-extraction/` and reproducible by the
commands in its README.

## Suites

**core (`ctest`, 106 tests): 100% passed**, 1106 s.

```
100% tests passed out of 106
Total Test time (real) = 1106.29 sec
```

**app (`swift build` on `app/TopOptKit`): Build complete! (75.41 s)**, after
`LIB3MF_PREFIX=/nonexistent ./app/scripts/build_core.sh` to provision the
worktree's `vendor/TopOptCore.xcframework` (without it SwiftPM cannot even
resolve the package here — the known worktree trap, and nothing to do with this
branch). The only diagnostic is a pre-existing Swift 6 `@Sendable` warning in a
local function, untouched by this work.

Both were run with two unrelated optimization jobs from other worktrees on the
same Mac, which is why the ctest wall clock is longer than PR 299 recorded for
the same suite.

## If any of this is taken further

Nothing here needs a rebuild to use — no production code changed, so the app, the
worker and the CLI are exactly as they were. **If S4's option 3 or S5's views are
picked up, or if the one-line load-tag gap in S2.3 is closed, that IS a core
change and the maintainer must then run `./app/scripts/build_core.sh` AND
`cmake --build core/build --target topopt_cli`, restart the worker, and rebuild
the app.** Note the UNDERSCORE: `--target topopt-cli` with a hyphen is the output
file name and make silently reports it up to date without building anything.
Nothing in this task requires any of it.

---

# IN PLAIN LANGUAGE

## What I did

You picked a method from a paper to replace the smoother that didn't work, and
asked whether it does better on your part. That's the whole of this task: measure
it, don't build on it.

I did four things.

**I got the paper's own code running.** The authors publish their implementation
in Julia. It turned out it can't be pointed at your part — one line inside it
compares every grid point against every element of the mesh, which for your run
works out to about 230 billion comparisons for a single pass. So I rewrote the
method in C++ instead, and then checked my version against theirs on a small
test case both could handle. They agree: the threshold value comes out bit for
bit identical, and the intermediate numbers agree to twelve decimal places. My
version is the same method, not a lookalike.

**I measured it with the exact same ruler PR 299 used**, so the numbers are
comparable. I didn't retype that ruler — I moved the code into a shared file and
proved the old measurements still come out identical, digit for digit.

**I measured your actual part, not a stand-in.** PR 299 used an older bracket
fixture. Your run is the vertical stand, and I read its four rungs straight out
of the design file your worker wrote, so nothing had to be reconstructed. I also
re-ran the old smoother on those same shapes, so "the new method vs the old one"
is a fair fight on identical geometry.

**And I measured a plain sphere**, where the right answer is known exactly and
there's no argument about whether the reference shape is itself a bit lumpy.

## What I found

**On the sphere the new method is a clear win.** It takes about 59% of the
stair-stepping away where the old smoother takes 11%. Five times better, and it
holds the volume exactly instead of drifting.

**On your part it's a draw, and a strange one.** It removes 21.5% — three times
what your app's smoother actually achieves (6.9%). But the strongest setting the
old smoother *can* be pushed to removes 23.4%, slightly more, while moving the
surface half as far. So the new method beats what you have, and doesn't beat what
you could have had by turning the old dial up.

The reason for the difference between sphere and part is worth understanding,
because it decides whether any of this is worth doing. **The method is good at
smoothly curved surfaces and bad at sharp edges.** Your stand is mostly flat
faces, bolt holes and corners. There isn't much curved surface on it to fix, and
there is a lot of sharp geometry to damage. I measured both halves separately:
on the genuinely curved parts of the surface it improves things by 21%; on the
parts near a sharp edge it makes them 6% worse.

**On your four real rungs it doesn't help the surface at all.** I measured this
two ways, because measuring from the part's surface outwards and from the shape
inwards can disagree, and here they do. Measured the honest way — a fixed set of
points on your original CAD shape, the same points for every version — the new
method leaves the original shape about 41% *less* well covered than what you
export today. The old smoother is 3% worse at the setting your app uses and 12%
worse at its strongest. Neither helps, and the new method hurts most.

**But there is one thing the new method does that nothing else does.** Your
rungs currently fail the minimum-feature check in 388 to 674 places. The new
method takes that down to between 53 and 113 — between 80% and 86% of those
failures gone, on every rung, with the volume held to a ten-thousandth of a
percent. The old smoother removes essentially none of them at any setting. That
is not a cosmetic number: it is the print-reliability count, and terracing is
what creates it.

**Two things I'd have missed if I'd trusted the paper.** First, most of the
machinery isn't doing the work. The method has five stages; the first two —
averaging the densities onto the corners of each cell and taking the contour of
that — do essentially all of the smoothing, in 0.6 seconds. The signed-distance
field and the radial-basis smoothing that follow take another 7 seconds and
change the answer by less than 1%. With the paper's own default settings, that
last stage is very close to doing nothing at all, for a reason I can show in the
code. Second, the paper's own reference implementation computes its volume
correction on a coarse grid and applies it to a fine one, which on your part
throws away 1.4% of the volume — fifty times worse than the accuracy the paper
claims for it.

**And one hard stop.** The new method's mesh **cannot be certified at all**. The
strength check refuses it: "load applied to a void DOF with no stiffness". I
tracked down exactly why — the smoothing eats 34 of the 5,165 voxels that carry
your declared load, and the certification only carries a load onto a mesh where
that mesh still has material. It's 0.66% of the loaded face and it's fatal. That
is fixable in one line, and I deliberately did not fix it, because fixing it
means committing to this route and that's your call.

## What I did not do, and why

I built nothing on top of it. The app is exactly as it was — no production source
file was touched, and I proved that by building the library twice, once from this
branch and once from `main`, and checking every object file byte for byte.

I did not fix the one-line certification gap, did not add the grid slider, did
not wire the x-ray view. All of that is scoped in S4 and S5 with what it would
cost, and none of it is worth doing until you've decided whether this route is
the route.

## What I'd suggest next

**The uncomfortable honest summary: this method is a better fit for a different
part than yours.** It shines on smooth organic shapes and it is at its weakest on
a machined-looking bracket. If your future parts look like this one, the headline
gain is small and it comes with a real loss on sharp features.

Three things I'd consider, in this order:

**One — say what the margin describes, today.** The strength number on your page
is computed on the blocky version, and the smoothed shape you're looking at is
not the shape it describes. I proved that: smoothing the mesh by a quarter of a
millimetre produces a certificate with the same margin, the same peak stress, the
same verdict and the same voxel mass on all four rungs — and identical in every
printed digit on three of them. That's a day of work
and it removes something untrue from the screen. It should happen regardless of
what you decide about smoothing.

**Two — take the cheap two-fifths of the method, not the whole thing.** Averaging
the densities onto cell corners and contouring that gives 19.3% of the
stair-stepping back on your part, cuts your min-feature failures by 82–87% across
the four rungs, runs in 0.6 seconds, and is a change to the export call rather
than a new subsystem. The signed-distance and radial-basis stages that follow it
cost twelve times as much wall clock and move the answer by about a percentage
point — sometimes downward. If any part of this route ships, that is the part.

**Three — and this is the one I'd actually push for — apply it only where the
optimizer made the surface, and leave your original part's skin alone.** Every
loss I measured is on the part boundary: the sharp edges, the anchor face, the
loaded interface, the bolt holes. Every gain is in the interior the optimizer
carved. The app already knows which voxels are which — the frozen regions, the
protected face, the anchor — so this is a mask, not a new algorithm. It would
keep the 80%-plus min-feature improvement and the exact volume, drop the 41%
coverage loss and the certification refusal, and it turns the method's own worst
property (it smooths boundary conditions, as the paper itself warns) into a
non-issue.

If none of that appeals, then the position is unchanged from PR 299: what removes
stair-stepping is resolution, and this route is not a substitute for it.
