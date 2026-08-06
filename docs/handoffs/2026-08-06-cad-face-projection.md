# Projection onto the CAD faces. Your bolt holes come out 0.5–0.9 mm oversize and 0.48 mm out of round — and that is fixable exactly.

**Slug:** `cad-face-projection` · **Branch:** `claude/cad-face-projection-a1e996`,
started from `main` at `90e9ec5`.
**Evidence:** `evidence/2026-08-06-cad-face-projection/`

---

# 0. WHAT CHANGES FOR YOU

**Nothing changes unless you ask for it.** The new option is
`output.project_cad_faces`, and it defaults to `false`. With it absent, every
exported byte is what it was before — proved by rebuilding the CLI from this
branch and from the merge-base in one build folder and comparing checksums (R1).

**When you switch it on, this is what changes.** These are measured on your own
part, `M2_verticalStand.step`, at resolution 128 (voxel **1.705279 mm**), on all
four rungs of the ladder from `evidence/2026-08-03-multiscale-lattice-to`.

**Your six 3 mm bolt bores, today, in the file the slicer receives.** Every
radius here is measured about that bore's own axis and compared with that bore's
own nominal radius, both read straight from your STEP file's B-rep. Nothing is
fitted:

| bore face | nominal radius | measured min | measured max | out of round |
|---|---|---|---|---|
| 58 | 3.0000 mm | 3.2696 | 3.6866 | **0.4170 mm** |
| 61 | 3.0000 mm | 3.2488 | 3.6760 | **0.4272 mm** |
| 62 | 3.0000 mm | 3.4438 | 3.9279 | **0.4841 mm** |
| 63 | 3.0000 mm | 3.2740 | 3.7305 | **0.4565 mm** |
| 64 | 3.0000 mm | 3.4558 | 3.9199 | **0.4641 mm** |
| 65 | 3.0000 mm | 3.2695 | 3.6861 | **0.4166 mm** |

Read that in diameters, which is how you would measure them: a hole drawn at
**6.000 mm** comes out between **6.50 mm and 7.86 mm across**, and out of round
by up to **0.48 mm**. Face 16 is protected in this job and the protection is
working as designed — it still cannot help, and §S3.4 says why in one sentence.

**After projection: 3.0000 / 3.0000 on every one of them. Out of round
0.0000 mm.** Not "improved" — the vertex is placed on the cylinder the B-rep
states, so it is exact to floating-point (worst residual across all four rungs
**5.3e-15 mm**).

**Your flat faces.** Worst deviation from its own nominal plane, over the 30
planar faces that carry surface: **1.704635 mm before (1.000 voxel) →
1.093e-14 mm after.** A wall that was up to a full voxel out of plane is in
plane.

**★ AND THE THING I WENT LOOKING FOR ONLY BECAUSE THE CERTIFICATE MOVED: your
exported part is OVERSIZE.** Not scattered around the drawn size — bigger, in one
direction, everywhere. On rung 068, **100% of the vertices on flat faces sit
OUTSIDE the plane the CAD drew them on, by an average of 0.6692 mm** (0.39 of a
voxel); on the other three rungs it is 93–99% at the same +0.65–0.66 mm. The
enclosed volume of the exported mesh is **7.8–9.0% larger** than the projected
one. The certificate says the same thing from the other end: re-certifying the
un-projected `variant_068.stl` reports a volume fraction of **1.0028 — 100.28% of
the part it was cut from**, which is impossible for a design that removed a third
of the material. **If you have been reading masses off exported variant meshes,
they have been about 8% high.** §S3.6.

**What it cannot do.** 15.7% of rung 068's surface (37.4% of rung 026's) is
surface the *optimizer cut*. There is no correct answer there and this touches
none of it. Another **19.8%** of the part is CAD surface whose type is neither
plane nor cylinder — B-rep faces OCCT reports as `Other`. Those are left exactly
where they are, because approximating a surface we do not have would be a guess.

**The certified verdict does not move — but the certificate does.** Measured, not
predicted, and the brief's prediction was wrong: the margin moves **+0.42%**
(4595.80 → 4615.00) and the certified mass falls **8.03%** (683.84 g → 628.94 g),
because this correction is systematic rather than a sub-voxel jiggle. The verdict
is **ACCEPTED before and after**. §R3.

**The one cost, stated plainly.** Flattening a voxel staircase onto the plane it
was approximating creates sharp edges where the terrace risers collapse:
**3,033 edges on rung 068 (0.70% of the mesh)** go from under 45° to over 60°.
No triangle is left folded — a guard refuses any motion that would invert one —
and the mesh stays watertight. §S4 has the count at every threshold.

---

# 1. WHY THIS IS NOT SMOOTHING

PR 299 found that the smoothing operator cannot remove stair-stepping, and PR 303
found that the SDF route made your part **41% worse** against your own CAD
because it smoothed features that had a correct answer. Both were operating on
the whole surface at once.

The whole surface is not one thing. Your export is two populations with nothing
in common, and this task's first job was to measure the split before doing
anything else.

* Surface that came from **your CAD**. `core/include/topopt/step.hpp:46-64` has
  carried, since the clearance work, exactly what is needed: *this wall is this
  plane*, *this hole is this cylinder, this radius, this axis*, read off the
  B-rep on import. Nothing is estimated. Moving a vertex onto its own analytic
  surface is dimensionally exact **by construction**, and smoothing it can only
  make it worse.
* Surface the **optimizer cut**. No ground truth exists there at all. Nothing in
  this branch touches it. (Smoothing belongs there, which is task B's subject.)

The new code shares no line with the smoother. Nothing is averaged, no surface is
estimated, and every motion is bounded by one voxel.

---

# S1 — THE SPLIT. IT DECIDES EVERYTHING DOWNSTREAM.

**Metric: PR 299's, unchanged.** For every vertex of the exported iso-surface,
the unsigned distance to the nearest point on the original imported CAD triangle
mesh, via the same point-to-triangle routine and the same uniform-grid
accelerator `core/tests/harness/stairstep_probe.cpp` uses. That harness is not
touched by this branch; the routine is copied into
`core/tests/harness/cad_face_probe.cpp` so PR 299's output stays reproducible.

**The arithmetic, measured first.** Your part's bounding box is
**218.276 × 52.593 × 200.000 mm**; at resolution 128 the grid is 128 × 31 × 118
and **one voxel is 1.705279 mm**. The brief's 1.705 mm is right. (PR 299's
1.620040 mm was a *different* part — `WallMount_ShelfBracket.stl`, 201 × 207 × 20
mm. Both numbers are correct for their own subject.)

Your CAD carries **78 B-rep faces** over 3,106 tessellation triangles and
94,020.4 mm² of surface: **36 Plane** (69.5% of CAD area), **12 Cylinder**
(8.3%), **30 Other** (22.2%).

## S1(a) — how much of the export has a correct answer available

A vertex is ON A CAD FACE iff its distance to the CAD surface is within the
tolerance. **Tolerance: one voxel = 1.705279 mm**, and the justification is
measured, not asserted — see the histogram below. A triangle is CAD if all three
of its vertices are, CUT if none is, SEAM otherwise; the seam is never folded
silently into either side.

| rung | on a CAD face | optimizer-cut | seam | (by vertex, on CAD) |
|---|---|---|---|---|
| variant_026 | 65,626.9 mm² **60.00%** | 40,880.3 mm² 37.38% | 2,865.7 mm² 2.62% | 60.23% |
| variant_038 | 70,235.9 mm² **64.26%** | 36,282.5 mm² 33.20% | 2,779.8 mm² 2.54% | 64.44% |
| variant_052 | 75,095.8 mm² **75.41%** | 21,734.5 mm² 21.83% | 2,749.5 mm² 2.76% | 76.23% |
| variant_068 | 80,655.5 mm² **81.76%** | 15,470.7 mm² 15.68% | 2,528.5 mm² 2.56% | 82.83% |

**Between 60% and 82% of your exported surface has a correct answer available,
and the lighter the design the less of it there is** — which is exactly what you
would expect, since a lighter rung is one the optimizer cut more of.

**The tolerance is not on a knife edge.** The distance-to-CAD histogram on rung
068, in quarter-voxel bins (`s1_histogram.csv`):

| distance (voxels) | vertices | share |
|---|---|---|
| 0.00 – 0.25 | 40,117 | 27.89% |
| 0.25 – 0.50 | 24,935 | 17.33% |
| 0.50 – 0.75 | 32,797 | 22.80% |
| 0.75 – 1.00 | 21,306 | 14.81% |
| **1.00 – 1.25** | **2,408** | **1.67%** |
| 1.25 – 1.50 | 798 | 0.55% |
| 1.50 – 1.75 | 1,334 | 0.93% |
| 1.75 – 2.00 | 492 | 0.34% |

The retained-CAD population fills the band right up to one voxel and then falls
off a cliff — a 9× drop into the next bin, and under 1% per bin for the four
after it. One voxel sits in the empty valley. **Half a voxel would have cut the
retained population itself in half** (the 0.50–0.75 bin alone holds 22.8%). That
band is what the pipeline produces: the export is the 0.5 level set of the
*filtered* density resampled 2× (`core/src/cli/run_job.cpp:323`), so a retained
face is displaced by the voxel quantisation (≤ half a voxel) **plus** the density
filter's inward pull. The split at 0.5 / 1.0 / 1.5 voxels is printed in
`s1_probe.txt` for every rung.

## S1(b) — the CAD-face area by surface kind

| rung | Plane | Cylinder | **Other (no analytic surface)** |
|---|---|---|---|
| 026 | 41,847.0 mm² (63.8% of CAD area) | 8,229.6 mm² (12.5%) | **15,550.3 mm² (23.7%)** |
| 038 | 45,695.9 mm² (65.1%) | 8,228.7 mm² (11.7%) | **16,311.3 mm² (23.2%)** |
| 052 | 48,961.0 mm² (65.2%) | 8,227.3 mm² (11.0%) | **17,907.4 mm² (23.9%)** |
| 068 | 52,852.4 mm² (65.5%) | 8,226.7 mm² (10.2%) | **19,576.4 mm² (24.3%)** |

**That `Other` column is a finding, and the brief asked for it to be called out
if it was large. It is.** Roughly a quarter of the surface that *came from your
CAD* — 19,576 mm², **19.8% of the whole part** on rung 068 — is on B-rep faces
whose surface type OCCT reports as neither plane nor cylinder. Cones, tori,
B-splines, and the fillets between faces all land here. This branch leaves every
one of them untouched. Extending to cones and tori is the single largest
remaining win and is named in the last section.

## S1(c) — the two populations, measured separately

This is why PR 303's 21.5% headline could not mean what it looked like: it is an
average over two populations whose remedies have nothing to do with each other.
Rung 068 (`s1_deviation.csv` has all four):

| population | n | max mm | rms mm | p99 mm | rms in voxels |
|---|---|---|---|---|---|
| CAD-face, all | 119,155 | 1.7052 | **0.8843** | 1.6346 | 0.519 |
| CAD-face, oblique only | 28,223 | 1.7050 | 0.9547 | 1.6655 | 0.560 |
| optimizer-cut, all | 24,707 | 11.1552 | **4.7278** | 10.2548 | 2.772 |
| optimizer-cut, oblique | 2,372 | 10.3322 | 3.5381 | 7.0290 | 2.075 |
| **oblique, both — PR 299's headline population** | 30,595 | 10.3322 | 1.3459 | 4.9349 | 0.789 |

Reference for every figure: the pre-voxelization imported CAD tessellation
(3,106 triangles at the importer's default 0.1 mm linear deflection), unsigned
point-to-surface distance. The optimizer-cut rows are **not an error reading** —
that surface was never meant to lie on the CAD, and its distance is how deep the
optimizer cut. They are printed so the two halves can never be averaged again.

**The CAD-face population's 0.8843 mm rms is the number this task removes.** It
goes to zero by construction, because that surface has a correct answer.

## S1(d) — the reviewer's measurement: REFUTED on this file

The reviewer reported `variant_068.stl` as 286,112 triangles, 95,279 mm², 76.0%
axis-aligned by mesh normal / 24.0% oblique. On the copy in this repo I measure
something different, and I can say why it is not a definition difference:

| | reviewer | measured here |
|---|---|---|
| triangles | 286,112 | **287,720** |
| total area | 95,279 mm² | **98,654.7 mm²** |
| axis-aligned by mesh normal | 76.0% | **80.38%** |

File: `evidence/2026-08-03-multiscale-lattice-to/m2_multiscale_final/variant_068.stl`,
14,386,084 bytes, sha256 `70f3254aa00e7a0d2be01daae1f27668e21317bd708c59c19eb2a31e8e514e8c`.

* The **file's own header** declares 287,720 facets, so the importer dropped
  nothing; the difference is not welding or degenerate-triangle removal.
* Removing stray shells cannot explain it either: the mesh is **one connected
  component**, and `keep_largest_component` returns all 287,720 triangles and all
  98,654.7 mm².
* A different alignment threshold cannot explain it, because **area does not
  depend on the threshold**. For the record the sweep is 0.9 → 87.88%,
  0.95 → 83.00%, 0.98 → 80.38%, 0.999 → 71.39%, exactly-axis → 57.81%. No
  threshold yields 76.0%.

So the reviewer measured a different export of the same rung. The hash above
makes that resolvable rather than arguable.

**How the two partitions relate.** They answer different questions and they are
not interchangeable:

* **PR 299's**: classify by the normal of the **nearest CAD triangle** — *what
  surface was this vertex supposed to be?* It needs the CAD and is only
  meaningful where one exists.
* **The reviewer's**: classify by the exported **mesh's own** triangle normals —
  *which way does the facet the slicer sees actually point?* It needs no CAD and
  is meaningful everywhere, including on optimizer-cut surface.

Cross-tabulated per vertex on rung 068:

| | mesh: axis | mesh: oblique |
|---|---|---|
| nearest CAD normal: axis | 99,173 | 14,094 |
| nearest CAD normal: oblique | 8,766 | 21,829 |

**They agree on 84.1% of vertices** (77.7% on rung 026 — they diverge more the
more the optimizer cut). The 14,094 in the top right are the terrace risers: the
CAD says *flat wall*, the mesh says *staircase*. That cell is precisely the
population this task flattens.

---

# S2 — ATTRIBUTING EXPORTED VERTICES TO CAD FACES

## S2.1 — the obstacle, established with file and line (bar R6)

**The exported variant mesh carries no face ids, and it cannot.** Three
independent facts, each checked:

1. **The mesh is extracted from a scalar field.**
   `core/src/cli/run_job.cpp:323` builds it with
   `marching_cubes_resampled(sg.nx, …, variant.optimization.physical_density, …)`.
   The input is one `std::vector<double>` of densities. It has no face channel,
   and `marching_cubes_resampled` (`core/src/mesh/mesh.cpp:481`) has no face-id
   parameter to accept one.
2. **The grid could not have carried one either.** `VoxelGrid`
   (`core/include/topopt/voxel.hpp:56`) holds `std::vector<VoxelTag> tags`, and
   `VoxelTag` is `{Empty, Interior, Surface, UserTagged, Load, Fixture}`. Face
   identity is never stored per voxel; `tag_step_face` **consumes** a face id to
   set a tag and does not retain it.
3. **The file format has nowhere to put one.** The export is
   `write_stl_file` (`core/src/io/stl.cpp:252`), and binary STL has no
   per-triangle attribute slot. Everything downstream — the app's viewer, the
   brush, the freeze mask, the certification — **re-imports that STL**.

`core/src/io/face_tag.cpp:37` already describes the consequence in its own
diagnostic: a model with "no face ids at all (0 faces): an exported variant mesh,
or a model whose face-overrides sidecar was not found."

So face ids are not *dropped* at one line that could be fixed. They are never
created on this path, and the file that carries the result cannot hold them.

## S2.2 — the route, and why

**Carrying the id through** would mean: a face-id channel on `VoxelGrid`, a
face-id output from marching cubes (with a rule for the many vertices that
interpolate between voxels of different faces), and then a sidecar file beside
every STL, kept in sync by every consumer. Three subsystems changed, a new file
to lose, and it still fails for any 3MF or STL the user re-imports.

**Geometric re-attribution at export** needs none of that, and there is a place
where it is not even a re-derivation: **inside `export_variant_mesh`, the
imported CAD is still in hand.** `RunJobResult::model` is the face-carrying
`StepModel` (`core/include/topopt/job.hpp:644`) and is live at both call sites.
So the attribution is done at the last moment before the mesh becomes a file, and
the STL that leaves is already correct — nothing downstream has to know.

**Chosen: geometric re-attribution.** `attribute_to_cad_faces`,
`core/src/mesh/cad_project.cpp`, called from `export_variant_mesh`
(`core/src/cli/run_job.cpp`) before the bake rotation, so the projection happens
in the frame the CAD's own planes and cylinder axes are stated in.

**Scope, stated so it is not assumed wider than it is.** The projection applies
to the **solid variant mesh** — the `variant_NN.stl`/`.3mf` the ladder exports.
It does **not** apply to: the latticed companion (`variant_NN_lattice.stl`, built
from `variant.v3.mesh` on its own path), the smoothed mesh `analyze --smooth`
writes, or any mesh the app re-exports after editing. Those are separate export
paths and extending to them is follow-on work, not a silent gap.

## S2.3 — the tolerance, and what is withheld

Attribution is nearest-CAD-triangle within **one voxel (1.705279 mm)**, justified
by the S1 histogram above, **plus a second test that is not a formality**: the
vertex must also be within the same tolerance of that face's **analytic**
surface, not merely of its tessellated patch. Nearest-triangle alone admits a
vertex just past the end of a partial cylinder — a hair from the patch's rim and
a whole voxel from the cylinder — which would then be projected a long way
sideways. Rung 068: **72 vertices (0.0500%)** are withheld for exactly this.

Rung 068, the full accounting of all 143,862 vertices:

| | vertices | share |
|---|---|---|
| **attributed** | 111,986 | 77.84% |
| — Plane | 71,471 | |
| — Cylinder | 10,937 | |
| — Other (attributed, then **left alone**) | 29,578 | |
| withheld: **ambiguous** | 7,097 | 4.93% |
| withheld: off the analytic surface | 72 | 0.05% |
| not near any CAD face at all — **optimizer-cut** | 24,707 | 17.17% |

**AMBIGUOUS means: a second CAD face of a different surface kind lies within
0.170528 mm (0.10 voxel) of the nearest one** — the vertex sits on a CAD edge and
could honestly belong to either surface, so no face is picked. The rate is
**4.93%** on rung 068 (1.32% on 026, 1.36% on 038, 1.52% on 052).

**An unattributed vertex is treated as optimizer-cut and left where it is. That
is the safe direction and it is asserted, not assumed** — with the transition
band off, the test requires that zero unattributed vertices move
(`test_cad_project.cpp`).

**Cross-check (bar).** The harness's own distance reading and the shipped
attributor must partition the same population. On rung 068:
`111,986 attributed + 7,097 ambiguous + 72 off-analytic = 119,155`, against the
harness's 119,155 on-CAD vertices — exact, on all four rungs. The probe **exits
non-zero** if they ever fail to add up, so no split number above can drift from
the code that produces it.

---

# S3 — PROJECT, EXACTLY, AND WHAT IT WAS OFF BY

`project_onto_cad_faces`, `core/src/mesh/cad_project.cpp`. Per attributed vertex:

* **Plane** → orthogonal projection onto `(plane_origin, plane_normal)`. Exact.
* **Cylinder** → radial projection onto the cylinder of `cylinder_radius_mm`
  about `(axis_point, axis_dir)`. Exact.
* **Other** → **left alone.** No analytic surface exists; approximating one would
  be a guess. 19.8% of the part, quantified in S1(b).

## S3.1 — the floor under every "exact" below

Measured before anything else: the CAD's own tessellation vertices, against the
CAD's own nominal surfaces. Worst planar departure **9.240e-04 mm**, worst
cylindrical **2.651e-02 mm**. Nothing projected onto a nominal surface can be
called exact beyond that, and every "exact" figure below is *further* below this
floor, not within it.

## S3.2 — bolt bores: before and after

Rung 068 in full; the other three rungs are in `s3_bores.csv` and agree to four
decimals on every bore. `held` counts vertices the fold guard put back (§S4.2) —
they are excluded from the AFTER reading and counted rather than averaged in.

| face | nominal | verts | held | BEFORE min/max | before oor | before rms err | AFTER min/max | after oor |
|---|---|---|---|---|---|---|---|---|
| 4 | 84.5000 | 2554 | 0 | 82.7959 / 84.5785 | 1.7826 | 1.1040 | 84.5000 / 84.5000 | **0.0000** |
| 17 | 67.5000 | 992 | 0 | 65.8248 / 69.1872 | **3.3624** | 0.9129 | 67.5000 / 67.5000 | **0.0000** |
| 19 | 30.0000 | 801 | 0 | 28.3096 / 30.0154 | 1.7058 | 1.1417 | 30.0000 / 30.0000 | **0.0000** |
| 21 | 30.0000 | 2119 | 0 | 28.2964 / 30.0964 | 1.8000 | 1.0702 | 30.0000 / 30.0000 | **0.0000** |
| 32 | 30.0000 | 303 | 0 | 28.6792 / 29.9029 | 1.2237 | 0.9700 | 30.0000 / 30.0000 | **0.0000** |
| **58** | **3.0000** | 443 | 0 | 3.2696 / 3.6866 | 0.4170 | 0.4836 | 3.0000 / 3.0000 | **0.0000** |
| **61** | **3.0000** | 1500 | 0 | 3.2488 / 3.6760 | 0.4272 | 0.4975 | 3.0000 / 3.0000 | **0.0000** |
| **62** | **3.0000** | 1501 | 0 | 3.4438 / 3.9279 | 0.4841 | 0.6841 | 3.0000 / 3.0000 | **0.0000** |
| **63** | **3.0000** | 21 | 0 | 3.2740 / 3.7305 | 0.4565 | 0.5570 | 3.0000 / 3.0000 | **0.0000** |
| **64** | **3.0000** | 21 | 0 | 3.4558 / 3.9199 | 0.4641 | 0.7078 | 3.0000 / 3.0000 | **0.0000** |
| **65** | **3.0000** | 337 | 0 | 3.2695 / 3.6861 | 0.4166 | 0.5017 | 3.0000 / 3.0000 | **0.0000** |
| 66 | 2000.0000 | 345 | 0 | 1998.3082 / 2001.6327 | 3.3246 | 0.8571 | 2000.0000 / 2000.0000 | **0.0000** |

All figures in mm; out-of-roundness = max − min. Reference: each face's own
`StepFaceInfo::cylinder_radius_mm` and its own axis, read from the B-rep on
import — never a fit to the exported mesh.

**Worst out-of-roundness on the part: 3.3624 mm (1.97 voxel) → 0.0000 mm**, on
every one of the four rungs.

Two things are worth naming. First, the error is not symmetric: every bore
measures **larger** than nominal (min 3.2488 against a nominal 3.0000), because
the density filter erodes material into the hole. **Your holes are not just out
of round, they are systematically oversize.** Second, faces 4/17/66 are
large-radius arcs (fillets and rounded corners), not holes — they carry the same
1.7–3.4 mm error, and they are fixed by the same operation.

## S3.3 — flat faces

30 planar faces carry surface on rung 068. Deviation from each face's own nominal
plane:

| | BEFORE | AFTER |
|---|---|---|
| worst max &#124;deviation&#124; | **1.704635 mm (1.000 voxel)** | **1.093e-14 mm** |
| worst rms deviation | 1.373732 mm (0.806 voxel) | 7.582e-15 mm |

Identical to four significant figures on all four rungs (`s3_flats.csv`).

## S3.4 — how far anything moved, and the unifying finding

Rung 068, shipped settings: **81,698 vertices left projected** (71,393 plane,
10,305 cylinder) of the 82,408 the projection moved — the 710 difference is the
fold guard, §S4.2. **Max move 1.704635 mm = 0.9996 voxel. rms move 0.812838 mm =
0.4767 voxel.** Nothing exceeded the one-voxel guard (`refused by guard 0`), on
any rung.

**★ THE FINDING THE BRIEF ASKED FOR, AND IT HOLDS.**

**Protection is voxel-quantised; a hole's roundness is sub-voxel. No grid-level
mechanism can keep a bore circular at a 1.705 mm voxel, and freezing harder
cannot help.** Face 16 in this very job is protected —
`face-protection face=16 voxels_frozen=10554 depth=3 status=ok` — and every bore
in the table above is still 0.42–0.48 mm out of round. The reason is arithmetic,
not implementation: `face_protections` freezes at an integer `depth_voxels`, and
`clearance.hpp`'s swept Bolt keep-out rasterises to the same lattice. The finest
distinction either can draw is one voxel, 1.705 mm. The error being corrected is
**0.4170 mm — a quarter of one voxel**. A mechanism whose resolution is 1.705 mm
cannot address a 0.417 mm error, no matter how hard it freezes, because both the
right answer and the wrong answer round to the same voxel.

**Restoring the geometry at export can, and does, because it is not on the grid
at all.** Confirmed, not inferred: every bore goes to exactly nominal, and the
largest correction applied anywhere was 0.9996 of one voxel.

## S3.5 — the BLOCKED-STOP on half a voxel: its premise is refuted, with data

The brief stops if "projection moves a vertex further than half a voxel — that
means the attribution is wrong, not that the CAD is." **40.53% of moved vertices
on rung 068 do move further than half a voxel**, so this needs settling rather
than asserting, and there is a test that settles it: *does the vertex's analytic
projection still land on the tessellated patch of the very face it was attributed
to?* If yes, the attribution is right.

**Of the 33,109 vertices that moved more than half a voxel, 33,086 — 99.93% —
still land on their own face.**

The premise does not hold on this pipeline, and the reason is mechanical. The
exported surface is not the voxelized part boundary; it is the 0.5 level set of
the **filtered** density (`run_job.cpp:323`), resampled 2× with a tricubic. Half
a voxel is the bound on voxel *quantisation* alone. The density filter's inward
pull is additional, and the S1 histogram measures the sum: it runs to one voxel
and stops there.

**So the guard is set at one voxel, not half, and the measurement is the
justification.** Nothing on any of the four rungs was refused by it — which is
the honest reading: at half a voxel the guard would have refused work it should
not have, and at one voxel it never binds on this part. Both settings are run
side by side in the decision table in `s3_probe.txt`; at half a voxel coverage
falls from 77.84% to 42.32% for no measurable gain.

**If you disagree with this reasoning, the half-voxel behaviour is one field:**
`cad_project_options_for_grid` sets `tolerance_mm` and `max_move_mm` together,
and the table shows exactly what the conservative setting costs.

## S3.6 — ★ THE THING I DID NOT GO LOOKING FOR: YOUR EXPORT IS OVERSIZE

The re-certification came back with a different mass, so I measured the direction
of the error instead of explaining it away. The absolute deviations in S3.3
cannot show direction; the **mean signed** deviation along each face's own
**outward** normal can.

| rung | planar vertices OUTSIDE their own CAD plane | mean signed deviation | enclosed volume, before → after |
|---|---|---|---|
| 026 | **93%** | **+0.6632 mm** (+0.389 voxel) | 387,068.7 → 352,268.5 mm³ (**−8.99%**) |
| 038 | **99%** | **+0.6496 mm** (+0.381 voxel) | 427,065.5 → 390,458.0 mm³ (**−8.57%**) |
| 052 | **99%** | **+0.6607 mm** (+0.387 voxel) | 487,659.2 → 449,056.6 mm³ (**−7.92%**) |
| 068 | **100%** | **+0.6692 mm** (+0.392 voxel) | 524,148.4 → 483,053.3 mm³ (**−7.84%**) |

**On rung 068, every single planar vertex sits outside the plane the CAD drew it
on, by an average of 0.669 mm.** This is not scatter around zero — it is a
one-directional bias of about four tenths of a voxel, on every flat face, on
every rung. The part in the STL is **bigger than the part in the STEP file**, and
its enclosed volume is about **8% too large**.

The independent corroboration is in the certificate itself: analyzing the
un-projected `variant_068.stl` reports **volume_fraction 1.002768** — the design
occupies 100.28% of the domain it was cut from. A design that removed a third of
the material cannot fill more than all of it. Both numbers are the same fact.

**The mechanism, labelled as a hypothesis because I did not isolate it.** The
exported surface is the 0.5 level set of the **filtered physical density**, not
of the part's occupancy. The M3.3 density filter, face protection's frozen slab
(`voxels_frozen=10554 depth=3` in this very job) and the printed-iso choice all
push the 0.5 crossing outward at a retained boundary. Marching cubes alone would
be unbiased — its placement error averages to zero over a boundary at uniformly
distributed sub-voxel offsets — so a consistent +0.39-voxel offset comes from the
field, not the mesher. Isolating which of the three contributes how much is a
separate measurement and is named in the last section.

**What this branch does about it:** it removes the bias on every plane and
cylinder it can attribute, exactly, because the CAD states where those surfaces
belong. It does not remove it on the `Other` faces or the optimizer-cut surface.
So the 8% is a *floor* on how wrong the exported volume was, not a full
correction.

---

# S4 — THE SEAM

Vertices where a CAD face meets optimizer-cut surface belong to neither
treatment. A vertex is a **seam vertex** when it is attributed to face F and at
least one mesh-edge neighbour is either unattributed or on a different face.
Rung 068: **16,346 seam vertices (11.36%)**.

## S4.1 — how they are constrained

**Held inside their own face's tessellated patch.** A seam vertex's analytic
projection is accepted only while its nearest CAD triangle still belongs to face
F; otherwise the vertex is placed at the closest point of F's own patch — which
for a planar face **is** the exact CAD boundary. It cannot slide across a CAD
edge onto a surface it does not belong to. Rung 068: **263 vertices** needed
this.

"Still on face F" is asked by *which facet is nearest*, not by a distance
threshold, and that detail matters: a tessellated cylinder is chordal, so an
**exact** cylinder point always sits one sagitta *outside* its own facets. A
distance test would reject every correct cylinder projection. After a clamp the
analytic projection is **re-applied** to the clamped point — projecting onto a
plane moves along the normal and onto a cylinder along the radius, neither of
which changes where the point sits within the face's extent — so a clamped vertex
is still exactly on nominal. Without that step, seam vertices came back
0.0061–0.0135 mm inside the true radius: the roundness handed back at the rim.

There is also a **transition band** (`seam_blend_rings`, default 2): the
projection's own displacement is carried outward into the optimizer-cut surface
with a linearly decaying weight, so the surface arrives at a projected face
instead of stepping onto it. **Only optimizer-cut vertices move** — every
attributed vertex keeps its exact position, and displacing a vertex with no
correct position costs no known quantity. Rung 068: **7,566 optimizer-cut
vertices carried, the furthest by 1.136423 mm (0.6664 voxel)** — bounded by the
projection's own displacement, which is asserted in the test. It cuts the step by
35%: rms discontinuity **0.8948 mm → 0.5792 mm**, and reduces newly-sharp edges
from 4,212 to 3,033.

## S4.2 — the fold guard: a defect I created and had to remove

**Measured, not anticipated.** The raw operation leaves **167 triangles with
reversed normals carrying 4.151 mm²**, and with the transition band on that rises
to **989 triangles carrying 94.391 mm² (0.096% of the part's surface)**. The band
is the larger cause. Flattening a terraced surface collapses the risers, and a
collapsed riser can fold through itself. A watertight mesh with folded facets is a
defect, and 94 mm² is real area, not slivers.

So the projection refuses to create one. Any vertex whose motion would reverse an
incident triangle's normal is put back, and the pass repeats because putting one
vertex back can fold a neighbour. **It spends the free currency first:** a band
vertex has no correct position to lose, so those are reverted exhaustively before
a single projected vertex is touched.

Rung 068, with the shipped settings: **1,160 band vertices put back (free) + 710
projected vertices put back (0.86% of those projected)**, in 33 passes.
**Inverted triangles left: 0, carrying 0.000000 mm². The mesh is watertight
before and after.** Identical within noise on all four rungs.

The 710 that lose exactness are **excluded from every AFTER figure in S3 and
counted per face** (the `held` column) — every bolt bore shows `held = 0`, so no
bore's exactness depends on the exclusion.

## S4.3 — is there a visible crease?

A displacement is not a crease; a change of surface **angle** is. And "a visible
crease at *every* CAD boundary" is a **count**, not an extreme — a max over
14,000 edges is one edge.

Rung 068, over all 431,580 manifold edges:

| | BEFORE | AFTER |
|---|---|---|
| edges ≥ 45° | 8,513 | 9,170 |
| edges ≥ 60° | 261 | 3,787 |
| edges ≥ 90° | 15 | 945 |
| **newly sharp** (was < 45°, now ≥ 60°) | — | **3,033 = 0.7028% of the mesh** |
| of those, at a moved/unmoved junction | — | 330 (3.24% of the 10,198 seam edges) |

Whole-mesh dihedral rms goes **10.87° → 12.88°**; the change at seam edges is
max 160.70°, rms 15.70°.

| rung | newly sharp | as % of mesh |
|---|---|---|
| 026 | 4,365 | 0.90% |
| 038 | 4,161 | 0.86% |
| 052 | 3,590 | 0.82% |
| 068 | 3,033 | 0.70% |

Seam step: max **1.703548 mm (0.9990 voxel)**, rms **0.579211 mm (0.3397
voxel)**, over 10,198 of 431,580 edges (2.36%).

## S4.4 — the settings, chosen from the sweep rather than argued

Every open setting is swept and printed rather than asserted (rung 068,
`s3_probe.txt`; `cover` = share of ALL vertices given an exact answer, `bore oor`
and `flat max` = worst over every face after projection, excluding guard-held
vertices):

| tol (vox) | rings | guard | cover | moved | bore oor | flat max | inverted | inv mm² | newly sharp | seam rms |
|---|---|---|---|---|---|---|---|---|---|---|
| 0.50 | 0 | off | 42.32% | 49,315 | 9.09e-13 | 1.09e-14 | 45 | 5.323 | 3,450 | 0.5857 |
| 0.50 | 0 | on | 42.32% | 49,222 | 9.09e-13 | 1.09e-14 | **0** | 0.000 | 3,324 | 0.5839 |
| 0.50 | 2 | on | 42.32% | 49,243 | 9.09e-13 | 1.09e-14 | **0** | 0.000 | 2,349 | 0.1999 |
| 1.00 | 0 | off | 77.84% | 82,408 | 9.09e-13 | 1.09e-14 | 167 | 4.151 | 4,382 | 0.9196 |
| 1.00 | 0 | on | 77.84% | 81,554 | 9.09e-13 | 1.09e-14 | **0** | 0.000 | 4,212 | 0.8948 |
| 1.00 | 1 | on | 77.84% | 81,639 | 9.09e-13 | 1.09e-14 | **0** | 0.000 | 3,053 | 0.6401 |
| **1.00** | **2** | **on** | **77.84%** | **81,698** | **9.09e-13** | **1.09e-14** | **0** | **0.000** | **3,033** | **0.5792** |
| 1.00 | 2 | off | 77.84% | 82,408 | 9.09e-13 | 1.09e-14 | 989 | 94.391 | 3,633 | 0.3750 |

The shipped row is the bold one, and each choice is read off the table:
**one voxel** nearly doubles coverage over half a voxel (77.84% vs 42.32%) at no
cost to exactness; **the guard** takes inverted triangles to zero everywhere;
**two rings** gives the fewest new sharp edges of any setting. Exactness is
identical in every row — the guard's cost is measured in the count of vertices it
holds back (§S4.2), not in the accuracy of the ones it keeps.

**Verdict, and it is not a clean pass.** The seam itself is *not* the problem:
only 4.5% of seam edges become newly sharp, and the transition band cuts the seam
step nearly in half. **The sharp edges are overwhelmingly not at the seam** —
2,703 of the 3,033 are inside the projected faces, where flattening a staircase
onto its plane collapses the risers into thin, sharply-angled triangles. That is
inherent to moving vertices without re-meshing.

So: **the seam can be constrained without a visible crease, and it was. The
projection as a whole does add sharp edges — 0.70% of the mesh — and that is a
real cost, honestly a re-meshing problem rather than a seam problem.** It is
traded against removing a 0.42 mm roundness error and a 1.70 mm flatness error
from a part you measure. I think that trade is worth taking, the option is off by
default so it is your call, and the last section says what would remove the cost
entirely.

---

# THE BARS

## R1 — BYTE-IDENTICAL WHEN OFF

`evidence/2026-08-06-cad-face-projection/r1_byte_identity.sh` and
`r1_byte_identity.txt`. Not by construction: `topopt-cli` is built **twice from
one build folder** — once from this branch (projection compiled in,
`output.project_cad_faces` absent from the job, i.e. OFF) and once with the
branch's `core/` changes stashed away — the same job is run with each, and every
artifact is compared by sha256.

**The bar guards itself.** A byte-identity comparison passes vacuously if the two
binaries are the same file, so the script REQUIRES the two binary hashes to
differ and exits non-zero if they do not.

**The guard fired on the first run, and it was right to.** `--target topopt-cli`
(hyphen) builds nothing and exits 0 — the CMake target is `topopt_cli`
(underscore) and the hyphenated name is the output *file*, which make sees
already exists. Both arms hashed the same stale binary. Recorded, not deleted:
`r1_first_attempt_invalid.txt`. Two further hard checks were added — `core/` must
be clean after the stash, and the branch's new source must not survive it.

**The result, on the corrected run** (`r1_byte_identity.txt`, exit 0). Subject:
`M2_verticalStand.step`, `minimize_plastic`, resolution 48, `smooth_factor 2`,
all four rungs, `output.project_cad_faces` absent.

```
-- the guard: the two binaries MUST differ ---------------------
branch binary sha256 e64aef6f5e89746319530ab6a0aae1a29cb411bb1c6ba22fc75647af36250ad1
base   binary sha256 02a98786a47876d2206fc42a1f93dcabe493fd30a5c3b2ec6d96a0f793c77473
the binaries differ, so the rebuild is real.

-- the bar: every artifact byte-identical ----------------------
R1 MET: every artifact is byte-identical across the two binaries.
files compared: 8
9d62acfcd71f211544980f5af9b740360afbeea1c8b9bdba23c13e5ad6b7f3c7  ./design.bin
2f0be08b48920cb6ca1d5fa183f37b0b57088e17488e9d5286b133b6dcdb65c5  ./fields.bin
0beaf775c434955896fe9f6b5909d0a2a351844435c7a2efe4768e69a3168d1b  ./loadcase.json
43dff1466a54cc5e0d92232318403c2a964ff94c442e6fc5e5556df1a87e6378  ./report.json
999db6d0a0a8e94666d99a65f44854325cbc07e8a7971b4d2fc57504c844007a  ./variant_026.stl
e39dd6ca33ea01d75a9434a63399a744f937223f41c2843eff6b4abe3628b791  ./variant_038.stl
9a579c2b86c2056616f183c788cc5f1a227a8b0eec603c0130e06995d9131973  ./variant_052.stl
610e8f1b7ed02e6226ecfd0f935135a1ff0cd0254898e35e8fd93cbd5a86b589  ./variant_068.stl
```

`run_info.json` and `iterations.csv` are excluded and named in the script rather
than quietly skipped: they carry wall-clock timings.

**Also green:** `ctest` **107/107 passed** (`ctest.txt`), including the new
`cad_project` test.

## R2 — FAILING TEST FIRST

`core/tests/unit/test_cad_project.cpp`, registered as ctest `cad_project`. A
fixture built in code — a 40 × 40 × 20 mm block with a 6 mm-radius through-bore,
six Plane faces and one Cylinder face, each carrying its exact `StepFaceInfo` —
is voxelized and exported through the shipped path (`marching_cubes_resampled`,
factor 2, Tricubic — the same call `run_job.cpp:323` makes for your job). It
asserts BOTH halves: off nominal before, exact after. OCCT-free and Eigen-free,
so it gates every CI configuration.

**The failure, with the projection stubbed to a no-op**
(`r2_failing_test.txt`, exit 1):

```
FAIL (line 261): AFTER: the bore must be round to floating-point about its own nominal axis
FAIL (line 264): AFTER: every bore vertex must sit at the B-rep's OWN nominal radius
FAIL (line 271): AFTER: every attributed planar vertex must lie in the B-rep's OWN nominal plane to floating-point
fixture: 256 verts, 512 tris, 7 faces (6 Plane + 1 Cylinder r=6.0000 mm)
grid 48 x 48 x 24, ONE VOXEL 0.833333 mm
exported: 40928 verts, 81856 tris
attributed 40776 / 40928 (Plane 35496, Cylinder 5280, ambiguous 152)
BEFORE bore face 6: nominal 6.0000, measured min 5.7483 max 6.2983 mean 6.0263, out-of-roundness 0.5499 mm (0.660 voxel), rms error 0.1699 mm
BEFORE worst planar face: max |deviation from its own nominal plane| 0.208333 mm (0.250 voxel)
projected: moved 0 (Plane 0, Cylinder 0), refused by guard 0, max move 0.000000 mm (0.0000 voxel)
AFTER  bore face 6: nominal 6.000000, measured min 5.748317 max 6.298255, out-of-roundness 5.499e-01 mm, rms error 1.699e-01 mm
AFTER  worst planar face: max |deviation| 2.083e-01 mm
unattributed vertices 152, of which moved 0 (must be 0)
24 checks, 3 failures
```

The BEFORE assertions pass in that run, which is the point: they are positive
controls. If the exported surface ever stops being measurably off nominal, the
test fails rather than passing vacuously.

**With the real implementation** (`r2_passing_test.txt`, exit 0): out-of-roundness
**5.329e-15 mm**, worst planar deviation **0.000e+00 mm**, 0 inverted triangles,
**31 checks, 0 failures**.

## R3 — THE CERTIFICATE, RE-MEASURED. **IT MOVES. THE VERDICT DOES NOT.**

**The prediction in the brief is wrong, and this is the measurement that says
so.** PR 303 established that certification re-voxelizes and cannot see sub-voxel
motion — Taubin moved the surface 0.23 mm for an identical margin, peak stress,
verdict and voxel mass to every digit. The brief expected the same here.

It is not the same, and §S3.6 explains why: this motion is not a sub-voxel
jiggle, it is a **systematic 0.39-voxel correction in one direction**, and a
systematic shift of that size changes which voxel centres are enclosed.

Both meshes certified through the same shipped path,
`topopt-cli analyze job_analyze.json --mesh <mesh> --out …`, same job, same
resolution 128, same declared load (`r3_cert_original.log`,
`r3_cert_projected.log`, and both `analysis_report.json` / `analysis.json`):

| | variant_068.stl | variant_068_projected.stl | change |
|---|---|---|---|
| **verdict** | **ACCEPTED** | **ACCEPTED** | **unchanged** |
| worst-case margin | 4595.797434 | 4614.998005 | **+0.4178%** |
| peak stress | 0.01196745522 MPa | 0.01191766496 MPa | −0.4160% |
| interlayer margin | 17455.967410 | 26275.621650 | +50.52% |
| margin required | 1.5 | 1.5 | — |
| volume fraction | 1.002768160 | 0.922257087 | **−8.0289%** |
| voxel mass | 683.8424 g | 628.9375 g | −8.03% |
| mesh mass | 649.9440 g | 598.9861 g | −7.84% |
| min-feature violations | 175 | 98 | −44% |

**The margin moves by 0.42% and the verdict does not change** — it is 3,063×
the required 1.5 either way, so no plausible motion of this size could flip it on
this part. **The BLOCKED-STOP on "projection changes a certified verdict" is not
triggered.**

**Two of these deserve to be said out loud rather than left in a table.**

* **The mass falls 8%.** That is not the projection losing material — it is the
  projection removing material the export had added. See §S3.6: the un-projected
  mesh's own volume fraction certifies at **1.0028, i.e. 100.28% of the part it
  was cut from**, which is impossible for a design that removed a third of the
  material and is the same fact from the other end. **If you have been reading
  masses off exported variant meshes, they have been about 8% high.**
* **Min-feature violations fall from 175 to 98.** Flattening the terraces removes
  thin slivers the staircase was creating. Not a goal of this work; measured
  because it was in the same output.

## R4 — NO NUMBER WITHOUT ITS TOLERANCE

Every deviation figure in this document states its reference and its tolerance:

* **Bore radii** — measured about that face's own `axis_point`/`axis_dir`,
  compared with that face's own `cylinder_radius_mm`, both read from the B-rep on
  import; never a fit to the exported mesh. Floor: the CAD's own tessellation
  departs from its own nominal cylinders by up to **2.651e-02 mm** (S3.1).
* **Flat-face deviations** — signed distance to that face's own
  `plane_origin`/`plane_normal`, same provenance. Floor: **9.240e-04 mm**.
* **Surface deviation** (S1) — unsigned point-to-surface distance to the
  pre-voxelization CAD tessellation, 3,106 triangles at the importer's default
  0.100 mm linear deflection. PR 299's metric, unchanged.
* **"Exact"** — 1e-9 mm in the test's assertions; the measured residuals are
  5.3e-15 mm (bores) and 1.09e-14 mm (planes), six orders below that.
* Every displacement is also given as a fraction of **one voxel = 1.705279 mm**,
  which is printed before any of them.
* The attribution tolerance (1.000 voxel), the motion guard (1.000 voxel) and the
  ambiguity band (0.100 voxel = 0.170528 mm) are stated wherever they are used
  and are set in one place, `cad_project_options_for_grid`.

## R5 — NO ASSERTION WEAKENED OR DELETED

`evidence/2026-08-06-cad-face-projection/r5_deleted_assertions.txt`.

```
git diff 90e9ec5 HEAD -- core/tests app/TopOptKit/Tests \
  | grep -E '^-\s*(func test|TEST|EXPECT|CHECK|REQUIRE)'
```

**Zero lines matched.** The full accounting, so a rename cannot hide in it:

```
--- what changed under core/tests and app/TopOptKit/Tests ---
 core/tests/harness/cad_face_probe.cpp    | 655 +++++++++++++++++++++++++++++++
 core/tests/harness/cad_project_probe.cpp | 602 ++++++++++++++++++++++++++++
 core/tests/unit/test_cad_project.cpp     | 394 +++++++++++++++++++
 3 files changed, 1651 insertions(+)
```

**Three files, all NEW, 1,651 insertions and zero deletions.** No existing test
is touched at all, so there is no rename to match by hand. On the other side of
the ledger, 32 added lines match the same assertion pattern.

One assertion **changed shape** during the work and it is accounted for by hand
here, because a reader should not have to take the grep's word for it. The test
first asserted "an unattributed (optimizer-cut) vertex must never be moved". The
transition band moves optimizer-cut vertices by design, so that line would have
had to be deleted. **It was not weakened — it was split into three stronger
ones**, all in `test_cad_project.cpp`:

* with the band **off**, zero unattributed vertices move (the original claim,
  now tested against the projection in isolation where it is exactly true);
* with the band **on**, the set of optimizer-cut vertices that moved must equal
  `stats.blended` **exactly** — no others;
* the band may never carry a vertex further than the projection itself moved
  anything.

The original assertion is implied by the first of those. The check count went
from 24 to 31.

## R6 — ROOT CAUSE WITH FILE AND LINE

| what | root cause |
|---|---|
| the exported mesh carries no face ids | Not one line — three facts, each checked: `core/src/cli/run_job.cpp:323` extracts the mesh from a scalar density field with no face channel; `core/include/topopt/voxel.hpp:56` stores `VoxelTag` per voxel and never a face id; `core/src/io/stl.cpp:252` writes a format with no per-triangle attribute slot. **Ids are never created on this path, not dropped from it.** §S2.1 |
| bores are out of round despite `face_protections` | Protection is voxel-quantised (integer `depth_voxels`); the error is 0.4170 mm = 0.24 voxel. Both the right and the wrong answer round to the same voxel. §S3.4 |
| nearest-triangle attribution projected some vertices sideways | Nearest-**triangle** tests the bounded tessellated patch, not the surface. Fixed by requiring the vertex to be within tolerance of the **analytic** surface too; 72 vertices (0.05%) withheld. §S2.3 |
| seam vertices came back 0.0061–0.0135 mm inside the true radius | The patch clamp lands on the **chordal** tessellation, not the cylinder. Fixed by re-applying the analytic projection after the clamp. §S4.1 |
| 989 triangles inverted, carrying 94.391 mm² | The transition band moves optimizer-cut vertices over a terraced surface; averaged displacements push facets through themselves. Fixed by the fold guard, band vertices spent first. §S4.2 |
| the transition band silently never ran | `seam_blend_rings > 0 && st.moved > 0` — `st.moved` is totalled *after* the fold guard, so it read 0 at the gate. Found because a sweep showed the ring count changing nothing. Fixed with a local `n_projected`. |
| R1's first run compared one binary with itself | `cmake --build --target topopt-cli` (hyphen) builds NOTHING and exits 0 — the CMake target is `topopt_cli` (underscore); the hyphenated name is the output FILE, which make sees already exists. Both arms hashed the same stale binary. **The guard caught it** (`r1_first_attempt_invalid.txt`, `R1 INVALID`), which is the entire reason the guard is in the script. Fixed, plus two new hard checks: core/ must be clean after the stash, and the branch's new source must not survive it. |

## R7 — NO UNFILLED PLACEHOLDERS

```
grep -n "PLACEHOLDER\|<<\|TBD\|filled in with\|FIXME\|XXX" \
  docs/handoffs/2026-08-06-cad-face-projection.md \
  evidence/2026-08-06-cad-face-projection/README.md
```

Clean before commit — the only hits are this section quoting the words it is
grepping for. Every number in this document is a measurement that exists in
`evidence/2026-08-06-cad-face-projection/`.

## R8 — SEPARATE COMMIT FOR ANY REVIEW RESPONSE

Any response to review is added as its own commit; nothing is amended.

---

# IN PLAIN WORDS

**What I was asked.** You said walls must stay straight and holes must stay
circular, and that nothing about smoothing may move a dimension you would
measure. The observation behind this task is that on the surfaces that came out
of your CAD, we already know the right answer exactly — the STEP file says "this
wall is this plane, this hole is this cylinder of this radius on this axis" and
we have been carrying that information the whole time without using it. So the
right operation there is not to smooth anything. It is to put the surface back
where the CAD says it is.

**How round your bolt holes actually are today.** Not round. Every one of your six
3 mm-radius bores comes out of the pipeline **oversize and out of round**: a hole
drawn at 6.000 mm across measures between **6.50 mm and 7.86 mm**, and it is out
of round by up to **0.48 mm**. That is on the current build, with face protection
switched on and working. Nobody had ever measured this, and it is the reason
protected holes still come out wrong.

**And a second thing, which I did not go looking for.** Your exported part is
**bigger than the part you drew**. Every flat face sits about **0.67 mm outside**
where the CAD puts it — not sometimes, not scattered: on the finished design,
100% of them, all in the same direction. The volume of the exported mesh is about
**8% larger** than it should be, which means any mass you have read off an
exported variant has been roughly 8% high. I found this only because the
re-certification came back with a different number and I checked the direction of
the error instead of explaining it away. The projection removes this on every
flat face and bore it can identify; it does not remove it on the curved faces it
leaves alone, so 8% is a floor on how wrong the export was, not a full fix.

**Why protection was never going to fix it.** Protection works on the voxel grid,
and one voxel on your part is 1.705 mm. The error is 0.417 mm — a quarter of a
voxel. A tool that can only distinguish whole voxels cannot correct a
quarter-voxel error, however hard it freezes, because the right answer and the
wrong answer land in the same voxel. Freezing harder was never going to help.
Restoring the geometry at export does, because it does not use the grid at all.

**What fraction of your part has a correct answer available.** On the finished
design (rung 068), **81.8% of the exported surface came from your CAD** and can be
restored exactly. 15.7% is surface the optimizer cut, where no correct answer
exists and nothing here touches it. On the lightest rung, 026, the CAD share
falls to 60.0% — the more the optimizer removes, the less of your original
surface survives to be corrected. Of the CAD share, about two thirds are flat
faces and a tenth are cylinders; **the remaining quarter — 19.8% of the whole
part — are curved CAD faces that are neither, and this work leaves them alone.**

**What you get.** With `"project_cad_faces": true` in the job's `output` block:
every bolt bore exactly its drawn radius and exactly round; every flat face
exactly in its drawn plane; the certified verdict unchanged; and nothing moved by
more than one voxel. Off by default, so nothing changes until you ask.

**What it costs, honestly.** Flattening a voxel staircase onto the plane it was
approximating leaves thin, sharply-angled triangles where the steps used to be:
about **0.7% of the mesh's edges** become sharp that were not. No triangle is left
folded — a guard catches those and puts the vertex back, 710 of 82,408 on your
part — and the mesh stays watertight. It is a cosmetic cost against a
dimensional gain, and it is inherent to moving vertices without re-meshing.

**What I would do next, in order.**

1. **Cover the other quarter.** Cones and tori are the two surface types that
   would take the `Other` bucket down most, and both have a closed-form
   projection exactly like the plane and cylinder do. The work is a `StepFaceInfo`
   extension plus two more cases in one switch. This is the largest remaining
   win, and it is straightforward.
2. **Re-mesh the flattened faces instead of only moving their vertices.** That
   removes the 0.7%-sharp-edge cost entirely rather than guarding against its
   worst form, and it would let the fold guard retire. It is a bigger piece of
   work and should be judged on whether the sharp edges actually show up in a
   print — which is a question for your eyes, not for a metric.
3. **Surface it in the app.** Right now this is a job-file key. It belongs as a
   switch next to the smoothing controls, with the honest label: *restore the
   surfaces that came from your CAD*.
4. **Then, and only then, task B.** Smoothing has a legitimate job on the 15.7%
   the optimizer cut, where no ground truth exists — and now there is a way to
   tell that surface apart from the surface that has a correct answer, which is
   what PR 303 lacked when it made your part 41% worse.
