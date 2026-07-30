# Lattice boundary finish — clipping, skin/rim, protected features

**Date:** 2026-07-29 · **Scope:** core/ only · **Evidence:** `evidence/2026-07-29-lattice-boundary-finish/`

## The problem

`generate_lattice` emitted WHOLE struts for cells selected by a CELL-CENTRE test.
No trim. Three confirmed defects: a staircase silhouette (the lattice fills a
cell-quantised blocky approximation of the part), geometry crossing protected
features (measured on this task's evidence part: struts to radius 4.882 mm inside
a declared 7.500 mm bore at 4 mm cells), and see-through voids where cells whose
centre landed in a hole were dropped whole.

## What was built

One new object and three consumers of it — no third rule anywhere:

* **`LatticeBoundary`** (`core/include/topopt/lattice_boundary.hpp`,
  `core/src/mesh/lattice_boundary.cpp`) — THE shared boundary predicate. A
  1-Lipschitz **lower bound on the true signed distance** to the allowed region,
  built from analytic primitives only: base half-spaces, the **exact** distance
  to the design's solid voxel set (the run_job base — the exact geometric
  distance to the certified voxel region, not a sampled field), and the
  **existing** clearance keep-outs (`ClearanceGeometry`, resolved by
  `resolve_clearance_from_face` / `resolve_clearance_manual` — no second
  keep-out concept). Because `sd(c) ≥ r ⇒ ball(c,r) ⊆ part`, clipping a
  CENTRELINE to `{sd ≥ radius}` keeps the SOLID inside — bar (b)/B3 by
  construction, then measured. `clip_segment` is a Lipschitz-**certified**
  midpoint refinement: kept spans are proven inside; undecidable slivers at the
  1e-4 mm floor are dropped (conservative) and counted
  (`uncertified_spans_dropped` ≈ one 0.1 µm sliver per boundary crossing —
  expected bookkeeping, not pathology).

* **Generator** (`lattice_gen.cpp`) — `LatticeRegion.boundary` (null ⇒ the old
  path, byte-identical; golden tests unchanged). With a boundary: cells activate
  by **overlap** (Lipschitz certificate of non-overlap, never a centre test),
  every strut is clipped to the region eroded by its OWN radius, node balls that
  would breach are dropped. The **skin** (`LatticeSkinSpec`: `none | rim |
  diagrid`): anchor balls at the exact cut ends (landings), a diagrid of skin
  edges linking each landing to its mutual-8-nearest same-face neighbours
  (rings + both diagonal families), and rim loops where faces meet —
  plane-pair lines, and on protected bores rim TORI whose φ=π vertex ring sits
  **exactly at the declared radius** (the collar boss touches the wall to the
  last bit and never crosses it). Skin rides each face's offset surface at the
  LOCAL skin radius — the variable-offset contour B5 demands under grading —
  and the skin radius law is `max(local interior radius, clamp)` with the clamp
  owned by core (`lattice_skin_min_radius_mm`, factor 1.5 on the extrudable
  width — a conservative default with a TRIPWIRE note, not print-validated).
  The skin pass **re-derives** each cell's landings by deterministic recompute
  (27-neighbourhood), so cell-local streaming survives — no global landing set.
  A read-only `LatticeGenObserver` taps landings/elements so the bars are
  measured from the real generator, and a future app preview can consume the
  same feed.

* **run_job** (`run_job.cpp`) — `lattice_boundary_for` builds the ONE object
  from the variant's solid density + the job's resolved clearances;
  `export_latticed_variant` generates against it and
  `build_lattice_posture` masks certification voxels through
  `lattice_certification_mask` — the same predicate, so the emitted silhouette
  and the certified region agree by construction (B7). The per-variant receipt
  and `run_info.lattice_export` now carry the clip/skin record and the B9
  volume accounting (interior / skin / rim mm³, analytic per-primitive sums on
  the soup basis, overlaps not deducted). `JobLattice` gains `skin`
  (default "diagrid") and optional `min_extrudable_width_mm`.

## Bars — MET / MISSED, with the numbers

Evidence part: 48×32×16 mm plate, straight edges, 45° diagonal cut, 15.000 mm
bore declared through `resolve_clearance_manual` (zero margin ⇒ declared radius
7.500). Real generator, real STLs (`evidence_{8,4,2}mm.stl`,
`evidence_graded_{8,4}mm.stl`, `before_{8,4}mm.stl`). All numbers measured from
emitted geometry by `core/tests/harness/lattice_boundary_probe.cpp`; unit gates
in `core/tests/unit/test_lattice_boundary.cpp` (34 checks).

| Bar | Verdict | Measured |
|---|---|---|
| B1 no-lattice byte-identical | **MET** | stash-rebuild checksum: `report.json` and `fields.bin` SHA-256 identical between the pre-change build and this build (`b1_checksums.txt`); full core ctest 79/79 green incl. gate_v2 |
| B2 zero geometry in protected region | **MET** | 8 mm: **0** vertices inside, min radius **7.500** (= declared to 3 dp, the collar torus touching); 4 mm: **0**, **7.500**; 2 mm: **0**, **7.500**. Before: 800 vertices to r=7.200 (8 mm); 17,600 vertices to r=4.882 (4 mm) |
| B3 clip the solid, not the line | **MET** | oblique 45° fixture: real clip max overshoot **≤ 0 (−0.117 mm short of the plane)**; the naive variant (same machinery, boundary pre-offset by r ≡ clipping the centreline at the true surface) protrudes **+0.683 mm** — the test REQUIRES that protrusion, so it fails against a centreline-clipped implementation |
| B4 no see-through voids | **MET** | largest connected patch ≤ **0.38 mm²** (bar 25); totals ≤ 6.38 mm² across all axes/configs. Before (8 mm): largest **9.0 mm²**, total 36 mm² along z |
| B5 part never grows | **MET** | max vertex overshoot **0.000000 mm** (bar 0.05) — uniform AND graded (0.5→1.0 mm field), 8 and 4 mm cells. The graded skin rides a per-vertex variable offset, which is why the prototype's 0.330 mm grading regression does not appear |
| B6 no floating cut ends | **MET** | **0 floating** of 578 (8 mm), 2,558 (4 mm), 10,452 (2 mm) landings — measured STRICTLY: a cut end must touch skin/rim/collar material BEYOND its own anchor ball (anchors alone are 100% by construction; the strict number is also 100%). Prototype: 60/767 floating |
| B7 one boundary predicate | **MET** | generator, cert mask and (future) preview resolve from ONE `LatticeBoundary`; unit test: **0 of 199,872** emitted vertices outside the certification-mask region; masked-voxel-in-keep-out count 0. run_job builds both sides from the same object per variant |
| B8 streaming survives | **MET** | peak RSS **1.93 / 1.95 / 1.97 MB** at 8/4/2 mm while the STL grows **5.7 / 30.9 / 170.7 MB** — flat in output size. Skin anchoring never builds a global landing set (deterministic neighbour recompute) |
| B9 mass accounting | **MET** | receipt + run_info carry interior/skin/rim volumes. 8 mm: 6,737 + 11,431 + 901 mm³ (before: 11,100 interior only); 4 mm: 29,819 + 30,293 + 901 mm³. Soup basis (overlaps not deducted), stated wherever reported |
| B10 determinism | **MET** | byte-identical rerun at every config (`B10_BYTE_IDENTICAL=1`); no RNG, no threads, no float atomics in any new path |

### Predicted ceiling — exceeded, and why (not restated as met)

The task predicted ~+20–25% triangles at equal cell size. Measured: **+196%**
at 8 mm (38,704 → 114,484) and **+118%** at 4 mm (283,656 → 617,884). Three
reasons, in order of weight:

1. **This evidence part is nearly all boundary.** At 8 mm it is 6×4×2 cells —
   every cell touches a face. The skin share falls with surface/volume ratio:
   **76% → 61% → 45%** of triangles at 8 → 4 → 2 mm. On a real 100 mm-class
   part at production cell sizes the boundary layer is a far smaller fraction.
2. **An anchored diagrid is denser than the prototype's arc-length grid.**
   Anchoring to real landings (the thing that took floating ends from 7.8% to
   0) roughly doubles skin node count; the prototype's ~7% skin was the same
   skin that floated 60 ends.
3. **Coincident planes are the worst case.** The plate's faces lie exactly on
   cell planes, so whole in-plane strut families erode away (517 of ~1,580
   struts dropped at 8 mm) and the skin replaces them rather than adding to
   them.

The B9 volume numbers carry the same story honestly (skin ≈ interior volume on
this small part). If the maintainer wants a leaner finish, `skin: "rim"` and
`kSkinDegree` are the two knobs; both are recorded in run_info.

## Blocked-stop paths — none taken

* The boundary is evaluated **analytically** everywhere: planes, capped
  cylinders and slabs in closed form; the run_job base is the **exact**
  geometric distance to the certified voxel set (expanding-shell search, exact
  within its window) — not a sampled distance field, so the prototype's
  0.093 mm contour-sampling overshoot is not inherited (measured 0.000000).
* Skin anchoring did **not** break cell-local streaming (B8 held) — landings
  are recomputed deterministically per neighbourhood, never collected globally.
* Clearance regions expressed everything a lattice keep-out needs (swept
  cylinder + bounded slab); no schema gap to report.

## Honest caveats

* **Facet sag vs the bore wall:** B2 is a VERTEX bar (as specified). Between
  exact vertices, flat facets can chord toward the bore by up to the stated sag
  budgets (rim torus ≤ 0.02 mm by station count; collar edges bounded by the
  1/cos station guard) — the same class of dip any faceted bore wall in any STL
  has.
* **`skipped_nonorthogonal_rims` = 5** on the evidence part counts plane–bore
  pairs not dressed with a torus: the four side walls (which never meet the
  bore) and the 45° cut (a genuine skew pair — an elliptical rim is future
  work, counted loudly, never approximated silently).
* **The skin printability factor (1.5× width)** is a conservative engineering
  default with a TRIPWIRE comment — it has not been print-validated the way
  PR 201 validated the interior floor.
* **Cert mask semantics:** partial boundary cells are now latticed in the
  posture (they carry the octet tensor at the printed rho). The skin adds
  material the homogenized rho does not know about — stiffness-conservative in
  the usual direction, and the receipt discloses the skin volume separately.
* **run_job parts (voxel base):** the design's outer boundary is the voxel
  solid set, which carries no analytic faces — so on a real job the finish
  there is clip + anchor balls, and the exported solid SHELL remains the outer
  skin (as before). The E2E cube job (`out_lattice/`) shows it: 496 struts
  clipped, 592 landings all anchored, zero skin edges on the voxel wall, and
  the composite certification reproduces the solid margin exactly
  (`solid_reconstruction_exact: true`). Rim tori need a plane–bore face pair;
  a bore through a voxel base gets collar edges only where landings attribute
  to the analytic bore term. A full collar on real parts wants the part's
  planar B-rep faces added to the boundary — listed under next steps.

## Files

* NEW `core/include/topopt/lattice_boundary.hpp`, `core/src/mesh/lattice_boundary.cpp` — the shared predicate + certification mask.
* NEW `core/tests/unit/test_lattice_boundary.cpp` (ctest `lattice_boundary`), `core/tests/harness/lattice_boundary_probe.cpp` (evidence probe).
* `core/include/topopt/lattice_gen.hpp/.cpp` — boundary in `LatticeRegion`, overlap activation, certified clipping, skin/rim/collar, observer, stats/volumes. Null-boundary path byte-identical (golden tests pinned).
* `core/src/cli/run_job.cpp` — `lattice_boundary_for` + `lattice_keep_outs_from_job` + shared mask in `build_lattice_posture`; receipt/run_info additions.
* `core/include/topopt/job.hpp`, `core/src/cli/job.cpp` — `lattice.skin`, `lattice.min_extrudable_width_mm`.
* `core/include/topopt/observability.hpp`, `core/src/simp/observability.cpp` — `lattice_export` boundary-finish fields.

## Plain language: what this does and what comes next

Until now, when the app filled a part with a lattice, it worked like laying
whole bricks inside a shape drawn on graph paper: any brick whose middle landed
inside the shape was kept whole, and any brick whose middle landed outside was
thrown away whole. That made stair-stepped edges, left bars poking into bolt
holes, and left brick-sized gaps you could see straight through next to holes.

This change makes the lattice respect the part's true outline. Every bar is
trimmed exactly where the part ends — and trimmed accounting for its own
thickness, so the rounded body of the bar stays inside, not just its
centreline. Any bar that would poke into a bolt hole or a declared keep-out
space is cut back to the hole wall exactly: the new geometry touches the wall
perfectly but never crosses it. Where bars get cut, the cut ends are no longer
left hanging: a woven surface net (the "skin") is laid over the part's faces,
its knots placed exactly where the cut bars meet the surface, and each hole
gets a solid ring around its rim (the "collar") that ties the net and the bars
together. The lattice, the safety check that certifies the part, and the file
sent to the printer all read the part's outline from one single definition, so
they can never disagree about where the part ends.

The honest trade-off: on the small test part the surface net roughly doubles
the file size, because almost the whole part is surface. On bigger real parts
the overhead shrinks a lot, and there is a lighter "rim only" option.

Next steps: a settings panel in the app for the skin options (a separate,
app-only task); slanted hole rims (a hole meeting a slanted face currently gets
no ring there, and it is counted rather than faked); and a real print to
validate the skin thickness rule the same way the original lattice was
validated.
