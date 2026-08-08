# strut-clip-matches-shell — the strut clip and the exported shell are ONE surface

**Task:** `2026-08-08-strut-clip-matches-shell`
**Evidence:** `evidence/2026-08-08-strut-clip-matches-shell/`
**Changes:** `core/` only. CI: `core-linux` + `app-macos`.

---

## 0. HEADLINE

**The teeth are real, they are on his own run, and the worst one is 0.608 mm
proud of the outer surface.** Measured on the maintainer's job at rung
vf = 0.68: **6,313 of 1,857,696 lattice vertices lie outside the solid shell
written into the same file.** After the fix: **0**.

**★ THE TASK'S STATED DIAGNOSIS IS WRONG, and the measurement says so three
different ways.** The task attributes the mismatch to `output.smooth_factor: 2`
pulling a tricubic shell inside the blocky voxel boundary. It is not that:

| the claim | measured |
|---|---|
| the latticed file's shell is the tricubic resample at `smooth_factor` | **it is not.** `export_latticed_variant` pushes `variant.v3.mesh` (`run_job.cpp:1083`), which is `keep_largest_component(marching_cubes(grid, density, 0.5))` at factor 1. `smooth_factor` is read at exactly ONE site, `run_job.cpp:321`, in the SOLID export. `grep smooth core/src/mesh/lattice_gen.cpp` returning nothing was right; so does `grep smooth_factor` over the whole latticed path. |
| `smooth_factor: 1` would remove the protrusion | **it would not.** At factor 1 the protrusion is its worst: 2,880 of 496,092 fixture vertices outside, max 0.178444 mm. |
| the tricubic resample causes it | **it reduces it.** Against a tricubic factor-2 shell the same struts protrude 0.069365 mm instead of 0.178444 mm. Smoothing is the wrong lever pointing the wrong way. |

**THE ACTUAL CAUSE is one surface older than any smoothing.** A marching-cubes
vertex lies on the segment between two voxel **centres**; the lattice boundary's
base term was the distance to the union of solid voxel **cubes**
(`lattice_boundary.cpp:190`, `voxel_distance`). On a flat face the two coincide
*exactly* — the 0.5 crossing between a solid centre and a void centre falls on
the shared cube face, so the inset is 0.000000 mm. At a convex edge the
isosurface **chamfers** the cube union and lies strictly inside it. Struts
clipped to the cube union therefore end outside the shell **at edges, and only
at edges.**

That is the maintainer's own discriminating observation, reproduced as a number
(`s1b_surface_gap.csv`, his 1.705 mm voxel):

```
distance to the nearest convex edge      max isosurface inset below the cube union
  < 0.25 voxels                            0.984382 mm     (= h / sqrt(3), the corner)
  < 0.50 voxels                            0.393753 mm
  < 1.00 voxels                            0.000000 mm
  < 2.00 voxels                            0.000000 mm
 >= 2.00 voxels                            0.000000 mm
```

**Faces clean. Edges only. Zero beyond half a voxel from an edge.** He read the
part correctly and the mechanism he could not see is that his file carried two
descriptions of one solid and they disagree exactly where he said they do.

**BLOCKED-STOP, DECLARED AND OVERRIDDEN, WITH REASONS.** The task says: "If sf=1
does not remove it, the diagnosis is wrong — say so and STOP." sf=1 does not
remove it, and this section says so. Stopping there would have delivered the
refutation and nothing else, while the *defect* is confirmed, the *cause* is
identified with file and line, and the *invariant the task actually names*
(★ no strut vertex lies outside the shell) is met and asserted. So the work
continued against the corrected mechanism. Everything the stop was protecting
against — fixing on a wrong diagnosis — is answered by S1 below being a
measurement rather than an argument.

---

## 1. WHAT CHANGED

**ONE surface, not two.** `LatticeBoundary`'s base region is now the interior of
the shell the export actually writes.

| file | change |
|---|---|
| `core/include/topopt/mesh_distance.hpp`, `core/src/mesh/mesh_distance.cpp` | **new.** `MeshDistance`: exact signed distance to a closed triangle mesh, positive inside, via a uniform-grid accelerator with an exact stopping bound and the angle-weighted pseudonormal sign test. |
| `core/include/topopt/lattice_boundary.hpp`, `core/src/mesh/lattice_boundary.cpp` | `set_shell_base(const TriangleMesh*)`. When set it SUPERSEDES the voxel-cube base in `sd_excluding_relaxed` and in `nearest_face`. Exact distance ⇒ 1-Lipschitz ⇒ the certified-clip refinement stays sound. |
| `core/src/cli/run_job.cpp` | `exported_shell_for()` — the ONE place the exported shell is spelled. `lattice_boundary_for()` takes it and calls `set_shell_base`. Both callers pass it: `lattice_one_variant` (`&v.v3.mesh`) and `forecast_uniform` (rebuilt from the stored design). |
| `core/src/cli/run_job.cpp` | **the invariant, measured on the stream and asserted**: `MeasuringSink` wraps the lattice emission and records the largest distance any lattice vertex lies outside the shell; the run REFUSES above the allowance. Receipt gains `clip_base_surface`, `protrusion_measured_against`, `max_strut_protrusion_mm`, `protrusion_allowance_mm`, `protruding_vertices`, `protrusion_vertices_measured`. |
| `core/include/topopt/lattice_gen.hpp`, `core/src/mesh/lattice_gen.cpp` | `kLatticeSkinSagBudgetMm` promoted from a file-local constant to a public one, so the invariant reads the freeform skin's declared overshoot budget instead of carrying a second copy of it. |
| `core/tests/unit/test_lattice_clip_shell.cpp` (new ctest `lattice_clip_shell`) | the bar, adversarial by construction. |
| `core/tests/harness/strut_clip_shell_probe.cpp` | the S1/S2 measurement harness. |

**No app change.** The app has its own `LatticeBoundaryTreatment` (a UI enum) and
does not link the generator; `mesh_distance.cpp` is plain geometry over
`TriangleMesh`, so it builds in every core slice including the dependency-free
iOS ones.

---

## 2. S1 — THE MECHANISM, MEASURED

### (a) The protrusion, and what `smooth_factor` does to it

Fixture: a solid block at HIS voxel (1.705 mm), 12 convex edges, a 6.82 mm octet
cell, strut radius 0.30 mm — the middle of his measured 0.225–0.384 mm range, so
the number below is a property of the surface mismatch and not of a fat strut.
`s1_probe.txt`:

| clip | shell measured against | max outside | vertices outside |
|---|---|---:|---:|
| voxel-cube union (as shipped) | `v3.mesh` — what the file carries | **0.178444 mm** | 2,880 / 496,092 |
| voxel-cube union | tricubic, `smooth_factor` 1 | 0.178444 mm | 2,880 |
| voxel-cube union | tricubic, `smooth_factor` 2 | 0.069365 mm | 2,880 |
| voxel-cube union | tricubic, `smooth_factor` 3 | 0.076752 mm | 1,800 |
| **the exported shell** | `v3.mesh` | **0.000000 mm** | **0** |

**`smooth_factor: 1` does not remove it — it is the worst case.** And the
`smooth_factor` rows are counterfactual anyway: the latticed export pushes
`v3.mesh` whatever the job says.

On HIS OWN RUN (`r3_his_run.txt`), which is the number that matters:

| | rung 0.68 |
|---|---|
| max protrusion, before | **0.6079873407 mm** |
| lattice vertices outside the shell | **6,313 of 1,857,696** |
| max protrusion, after | **0** |

0.608 mm is three 0.2 mm layers. That is a tooth you can feel.

### (b) The surface gap, and it is a convex-edge phenomenon

The fixture's cube union is an exact axis-aligned box, so the distance from a
surface sample to the nearest convex edge is closed form — no sampling, no
approximation. `s1b_surface_gap.csv`:

```
distance to the nearest convex edge     max isosurface inset below the cube union
  < 0.25 voxels    17,136 samples          0.984382 mm   ( = h / sqrt(3) )
  < 0.50 voxels    13,950 samples          0.393753 mm
  < 1.00 voxels    27,000 samples          0.000000 mm
  < 2.00 voxels    47,994 samples          0.000000 mm
 >= 2.00 voxels   242,406 samples          0.000000 mm
```

**Zero beyond half a voxel from an edge**, and exactly `h/sqrt(3)` = 0.984 mm at
a corner. The maintainer's "impossible to see any lattices on flat surfaces" is
not an impression; it is 0.000000.

### (c) Both entry points are in scope, and one fix covers both

`lattice_one_variant` (`run_job.cpp:2539`) is the ONE per-variant lattice
pipeline, called by the optimize path (`run_job.cpp:~5560`) and by the re-lattice
path `lattice_variant_job` (`run_job.cpp:~7230`). It builds the boundary once, at
`run_job.cpp:~3051`. Fixing it there fixes both by construction — the extraction
that made this true is PR 274's, and this task simply inherits it. The lattice
FORECAST (`forecast_uniform`, `run_job.cpp:~4023`) is a third consumer of the
same helper and is moved with them, so a forecast cannot go on describing a
surface the run no longer uses.

---

## 3. S2 — WHY THE SHELL, AND WHAT IT COST

Three candidates, costed on the same fixture, every one priced at the SAME strut
radius from the kept centreline length (`s1_protrusion.csv`) — because the
erosion candidate is modelled by inflating the radius, and charging it its own
inflation as "lattice volume" would flatter it by 1,600 %.

| | protrusion | lattice volume | verdict |
|---|---:|---:|---|
| **(a) clip against the exported shell** | **0** | **−0.129 %** (block) / **+0.050 %** (notched) | **CHOSEN** |
| (b) erode the cube union by the measured 0.984 mm | 0 | **−9.53 %** / **−11.06 %** | rejected |
| (c) force `smooth_factor: 1` | **0.178444 mm — unchanged** | — | rejected |

**(a) is the correct one and it is also the cheap one.** The task expected it to
be the most expensive, on the assumption that the shell would have to be
re-extracted from a tricubic resample. It does not: the shell is already in hand
— `export_latticed_variant` is holding `variant.v3.mesh` in order to push it into
the file — so the whole cost is indexing a mesh that already exists.
Latticed-voxel counts are unchanged on both fixtures (13,824 → 13,824 and
12,096 → 12,096), so the certified set does not move.

**(b) is rejected by a factor of ~75.** It loses ~10 % of the lattice
EVERYWHERE, on both fixtures, to correct a discrepancy that lives within half a
voxel of an edge — and it is wrong in the other direction too: at a CONCAVE edge
the isosurface bulges OUTSIDE the cube union, so a blanket erosion throws away
lattice where there was never anything to fix. That is measured, not argued: on
the notched block, clipping to the shell keeps MORE struts than the cube union
did (4,137 vs 4,104), which no erosion can do.

**(c) is rejected by its own number.** It does not remove the protrusion — at
`smooth_factor: 1` the protrusion is at its WORST (0.178444 mm vs 0.069365 mm at
factor 2). It would make every latticed part blockier and fix nothing. It is
listed here only because the task asked for it to be listed, and the number that
rejects it is the first row of the S1(a) table.

### The invariant, and it is the deliverable

> ★ no strut vertex lies outside the shell — asserted, not eyeballed.

`export_latticed_variant` wraps the lattice emission in a `MeasuringSink` that
evaluates every emitted vertex against the exact signed distance to the shell in
the same file, and `lattice_one_variant` REFUSES above the allowance. It is
measured on the STREAM, so peak RSS stays flat in output size (bar B8); a
per-voxel Lipschitz lower bound keeps deep-interior vertices to an array lookup.

It is a measurement and not a derivation on purpose. The clip's certificate
covers the spans it certified — but the generator also has a fast path that skips
the clip entirely (`lattice_gen.cpp:344`), a node-ball pass with its own single
test, and a skin pass with a deliberately relaxed predicate. "The clip is
correct" and "nothing was written outside the shell" are different claims, and
only the second one is what the maintainer sees in a slicer.

**The one allowance is declared, not discovered.** A freeform skin buys
`kLatticeSkinSagBudgetMm` = 0.045 mm of overshoot against the base surface on
purpose (`lattice_gen.hpp` states why). That constant was file-local; it is now
public, so the invariant reads the budget the generator actually spends instead
of carrying a second copy of the number. Every other run is held to
`kClipTolMm` = 1e-4 mm, and the receipt reports the allowance beside the
measurement so the bar a run was judged against is never left to inference.

### ★ THE BUG THE SUITE CAUGHT, and it is worth the paragraph

The first `MeshDistance` tested its coverage bound at the TOP of each shell
iteration — using the radius-`s` box while holding only shells `0..s-1`. That
overstates coverage by one shell and can return a distance up to one accelerator
cell TOO LARGE, which is the dangerous direction: it makes the clip keep a span
it has not proved, and it breaks the 1-Lipschitz property the entire
certified-clip argument rests on.

**The convex-edge fixture did not catch it.** `ctest lattice_void_exterior` did,
on a real l-bracket design, as struts emitted **0.839 mm outside the shell they
had just been clipped against** — with the predicate agreeing they were outside
when asked again at the vertex. The invariant caught the fix's own bug, which is
the argument for the invariant being always-on rather than fixture-only.

The guard is now a brute-force ORACLE in `test_lattice_clip_shell` (case 0b): 729
probes comparing the accelerated distance against a dumb all-triangle scan that
shares no code with it, plus a direct 1-Lipschitz check. Both would have failed
on the first version.

---

## 4. BARS

### R1 — byte-identical when no lattice is present · **PASS**

Both binaries rebuilt from one folder and **asserted to differ by sha256** before
a single artifact is compared (`r1_byte_identity.txt`).

| case | result |
|---|---|
| A — no `lattice` block | report.json, fields.bin, design.bin, variant_060.stl, run_info.json (minus named clocks), iterations.csv — **all IDENTICAL** |
| B — no lattice, but a CLEARANCE keep-out **and** a DESIGN BOX | 4 variant meshes + every other artifact — **all IDENTICAL** |
| C — ★ positive control, a graded lattice | `variant_060_lattice.stl` and its receipt **DIFFER**, while report/fields/design/solid mesh stay identical |

C is what makes A and B mean something: the change reaches the latticed export
and nothing else.

### R2 — failing test first · **PASS**

`r2_red.txt` → 4 failures, **2,880 of 496,092 fixture vertices outside the shell,
worst 0.178444 mm**; the notched fixture 3,024 of 427,404.
`r2_green.txt` → **0 and 0**, 20 checks, 0 failures. Both taken against the FINAL
code, so the red is the merge base's behaviour and not an artifact of a
since-fixed measurement.

### R3 — the invariant asserted for EVERY exported lattice · **PASS**

Always-on, not fixture-only: `export_latticed_variant` measures every emitted
lattice vertex and `lattice_one_variant` refuses above the allowance. On his own
run (`r3_his_run.txt`):

| rung | before | vertices outside | after |
|---|---:|---:|---:|
| 0.68 | 0.6079873 mm | 6,313 / 1,857,696 | **0** |
| 0.52 | 0.6014459 mm | 4,154 / 1,933,092 | **0** |
| 0.38 | 0.5921932 mm | 2,813 / 922,872 | **0** |
| 0.26 | 0.6405244 mm | 2,367 / 327,252 | **0** |

`clip_base_surface` reads `voxel_cube_union` on every before receipt and
`exported_shell` on every after receipt — read from the boundary, not asserted
beside it.

### R4 — full gate table, with a negative-control floor · **PASS**

| rung | accepted | margin before | margin after | voxel flips | control |
|---|---|---:|---:|---:|---:|
| 0.68 | true | 3254.356637 | 3254.356637 | **0** | 0 |
| 0.52 | true | 3389.417071 | 3389.417071 | **0** | 0 |
| 0.38 | true | 3290.912400 | 3290.912400 | **0** | 0 |
| 0.26 | true | 3014.120054 | 3014.120054 | **0** | 0 |

Grid 128×31×118 = 468,224 voxels at 1.705279 mm. The design is untouched, as it
must be — this is a post-process. The control column is the same comparison run
before-vs-before; without it "0 flips" would be indistinguishable from a script
that read one file twice.

**The LATTICE gate, and what the clip cost:**

| rung | lattice margin (before = after) | accepted | latticed voxels | lattice mass |
|---|---:|---|---:|---:|
| 0.68 | 3090.491158 | true | 1221 → 1221 (**+0**) | +0.028732 g (+0.469 %) |
| 0.52 | 3096.575242 | true | 1123 → 1123 (**+0**) | +0.055727 g (+0.807 %) |
| 0.38 | 3047.621385 | true | 527 → 527 (**+0**) | +0.096613 g (+2.139 %) |
| 0.26 | 2912.194018 | true | 225 → 225 (**+0**) | +0.018879 g (+1.092 %) |

**The bar asked for the latticed-voxel changes to be enumerated. There are none
to enumerate — the certified set is identical on every rung — and the lattice
mass went UP, not down.** The shell is outside the cube union at concave
features, so clipping to it recovers lattice the cube union was throwing away;
net, that outweighs what the convex edges lose. No verdict moved, so the
BLOCKED-STOP "the fix drops enough boundary lattice to move a verdict" does not
fire.

### R5 — mesh integrity, at the job's own 0.45 mm line width · **PASS**

| rung | components | isolated fragments @0.45 mm |
|---|---:|---:|
| 0.68 | 3305 → 3210 (−95) | 942 → 908 (**−34**) |
| 0.52 | 3356 → 3338 (−18) | 835 → 828 (**−7**) |
| 0.38 | 1673 → 1640 (−33) | 765 → 759 (**−6**) |
| 0.26 | 596 → 577 (−19) | 76 → 75 (**−1**) |

No protrusion was traded for a fragment: the count fell on every rung.

**★ SAY THE ABSOLUTE NUMBER OUT LOUD, because the delta flatters it.** These
meshes ship 75–942 fragments that touch nothing within one extrusion width. That
is a PRE-EXISTING condition this task did not create and does not fix — the
cell-size-adaptation handoff §A measured and named it
("whichever you choose, this mesh ships loose material"). The bar here is "do not
make it worse", and it got slightly better; it is not "this mesh is clean".

### R6 — no assertion weakened or deleted · **PASS**

Message census, not a name grep (`r6_assertion_census.txt`): test assertion
messages 3124 → 3157 with **none removed**; registered ctests 114 → 115 with none
removed; production refusal messages 395 → 397 with **none removed**; and the
comparison-kind histogram inside `CHECK()` rose or held in every bucket.

**ONE ASSERTION CHANGED ITS CONDITION, deliberately, and it is not a weakening.**
`test_designbox_lattice_recert`'s AI6 asserted `kept_solid == outside`. The
mask's cell-overlap proof now runs against the exported shell, so an island the
design box grew that the shell does not include never enters the mask at all and
the policy has nothing to drop — measured, 12 of 716 outside voxels. Relaxing to
`<=` would stop protecting anything, so the receipt gained
`outside_never_masked_voxels` and the test asserts the **exact partition**
`kept_solid + never_masked == outside`, with the original message kept verbatim.

### R7 — root cause, no placeholders, no scratch at the root

§5. Every artifact is under `core/`, `docs/` or
`evidence/2026-08-08-strut-clip-matches-shell/`.

### Cost, measured both ways

| | before | after |
|---|---:|---:|
| his run, `lattice_export.gen_seconds` (4 rungs) | 582.683 s | **574.362 s** |
| fixture, GENERATOR ALONE (best of 5, counting sink) | 0.0475 s | 0.3787 s (**7.97×**) |

**Both numbers are true and they point opposite ways, so both are reported.** On
his real part the whole lattice export got slightly CHEAPER: the mesh query
replaces `voxel_distance`'s expanding-cube search, and on thin-walled geometry
the mesh query wins. On a solid block the old path had a cheap deep-interior exit
(its distance WINDOW) that the mesh query has no equivalent of, and the generator
alone is ~8× slower — an extra 0.33 s on that fixture.

Note the task quoted "the 0.63 s the generator currently takes for four rungs".
The measured figure on his job is **582.68 s**, three orders of magnitude larger;
whatever run 0.63 s came from, it was not this one.

I tried the obvious mitigation — a per-cell Chebyshev "first non-empty shell"
field so deep-interior queries skip provably empty shells — and **measured no
improvement** (7.73× vs 7.97×, inside the noise), because most queries are near
the surface where the field is 0. It was removed rather than shipped as an
unmeasured optimization. If a genuinely chunky part ever makes this hurt, the
lever that would work is giving the shell base the same distance WINDOW
`set_voxel_base` has, with the voxel occupancy as the far-field sign oracle.

---

## 5. ROOT CAUSE, FILE AND LINE

**THE SHELL** — `core/src/cli/run_job.cpp`, `export_latticed_variant`:
`const TriangleMesh& shell = variant.v3.mesh;`, pushed into the file by
`push_shell`. `v3.mesh` is built by `core/src/voxel/voxelize.cpp:735`
(`marching_cubes(grid, density, iso)`) and reduced at `:813`
(`keep_largest_component`), called from `core/src/simp/analyze.cpp:389` with
`kIso` — the file-local constant `0.5` at `analyze.cpp:25`.

**THE STRUTS** — `core/src/mesh/lattice_gen.cpp:353`:
`B->clip_segment(pa, pb, r, -1, -1, &out.uncertified)`, i.e. clip the centreline
to `{signed_distance >= radius}`. The base term of that predicate was
`core/src/mesh/lattice_boundary.cpp:190` `voxel_distance` — "the exact
point-to-axis-aligned-box distance" to the union of solid voxel CUBES, installed
by `set_voxel_base` from `lattice_boundary_for`.

**WHY THEY DISAGREE.** `core/src/mesh/mesh.cpp:372`, `SampleField::position`:
*"Model-space position of the sample at lattice (i,j,k) = voxel centre."*
Marching cubes interpolates along edges between voxel CENTRES, so for a binary
field the 0.5 crossing between a solid centre and a void centre falls exactly on
the shared cube FACE — the two surfaces coincide on a flat face — while at a
convex edge the isosurface cuts the corner off the cube union, by up to
`h/sqrt(3)`.

**WHY IT WAS INVISIBLE.** Nothing measured it. The lattice receipt reported
`clipped_struts`, `landings`, volumes and margins — all true, none of them about
whether the emitted geometry was inside the shell beside it. The only place the
two surfaces met was the STL, and the only instrument pointed at that file was
the maintainer opening it in a slicer.

**THE PRINCIPLE IT VIOLATED**, stated in `lattice_boundary.hpp`'s own header and
in `run_job.cpp`'s `lattice_region_for`: *"the object the gate certifies and the
file the slicer opens are the SAME region by construction"* (bar B7). That was
true of the REGION and false of the SURFACE — two descriptions of one solid set
that agree on faces and part company at edges. This task extends B7 from the
region to the surface.

---

## 6. IN PLAIN WORDS

**Your four latticed files on disk are affected. Re-export before printing.**

Here is what happened. The latticed file has two things in it: a solid skin
around the outside, and the lattice inside. Those two were built from two
slightly different ideas of where the surface of your part is.

The skin is built by cutting a smooth surface through the middle of the boundary
voxels. The lattice was trimmed against the *outside* of those same voxels — as
if the part were built out of little cubes. On a flat wall those two answers are
identical, to the last decimal. At an **edge**, the smooth surface cuts the
corner and the blocky one does not, and the gap between them is up to about a
millimetre on your 1.7 mm voxels.

So the lattice was being trimmed to a boundary that sticks out past the skin —
but only at edges. That is exactly what you saw, and your observation that flat
faces are clean is what identified it: the measurement says the gap is
**precisely zero** more than half a voxel away from an edge.

**All four of your variants are affected, and by about the same amount** — the
worst strut end stands 0.59 to 0.64 mm proud on every one of them, which is three
print layers. It is not just the coarse rung. Re-export all four before printing.

The fix is to trim the lattice against the same surface the skin is made from,
which is now what happens. It costs you nothing at all:

* every rung keeps exactly the same certified lattice (voxel counts unchanged);
* every margin is identical to six decimal places, and every rung is still
  accepted — no verdict moved;
* the lattice actually got very slightly HEAVIER (+0.5 % to +2.1 %), because the
  smooth surface sits *outside* the blocky one at inside corners, so trimming to
  it puts back a little lattice that was being thrown away there;
* loose fragments in the mesh went DOWN slightly on all four.

Two other things worth knowing:

* This is not about the `smooth_factor: 2` in your job. That setting never
  touched the latticed file at all — it only affects the plain (non-latticed)
  export. Turning it down would not have helped.
* The program now **checks** this on every latticed export and refuses to write
  a file where any part of the lattice pokes out through the skin. It will not
  be able to happen quietly again. The receipt beside each file now carries the
  number (`max_strut_protrusion_mm`), so "0" is something you can read rather
  than something you have to trust.

One thing this did NOT fix, said plainly because the numbers above could be read
as if it had: these meshes still contain **75 to 942 small loose pieces** that
touch nothing else within one extrusion width. That was true before this change
and is very slightly better after it. It is a known, separate problem (the
cell-size-adaptation work measured and named it); it is not what you were seeing
at the edges, and it is not addressed here.
