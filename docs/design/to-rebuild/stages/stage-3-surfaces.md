# Stage 3: smooth surfaces (TOSurface)

Branch `claude/topopt-stage-3-surfaces-7f58fd`, from 2b40bcf4. Status: IN PROGRESS, PAUSED 2026-11-26 00:35 EST (weekly usage at 94 %; his rule). Nothing here is released.

## Where I stopped (read this first)

- Code: everything below is committed and pushed. Tests A, B, F, J pass their gates (`--gate` in ctest). Off path byte-identical (M); switch-on runs repeat byte for byte (K).
- Findings since hold 1: (1) design-box runs now use the new export (Stand v4 went through the voxel export in hold 1); (2) the re-fit runs just before each margin probe; (3) the re-fit's own CG stops at its 2,000-iteration cap with residual up to 2e-6 on real parts, and the slope at shipped designs is still median 3 (not 1): NOT RESOLVED; a gentler far weight (0.1) cost test A its gate (0.075 mm), so it stays 0.01; the move statistic was corrected (distance before against after) and not yet read on a real run; (4) at res 32, stage 1 + stage 3 together remove the ladder strips and lumps along Top Motor Mount's box (`stage-3-pics/topmotor_res32_stage3_alone_vs_stage1and3.png`): the final table must be stage 1 + 3.
- Next, when usage allows: run `agent-scratch/tosurface/launch_ref2.sh` (stage 1 + 3 on frozen build 6f2b3dac, three lock holds: stand128 / topmotor / standv4; base / pressing / pillow L+R; topmotor@64 knots 2 against 1.5). Announced to TOReview; not started. Then: read the corrected re-fit statistics; decide the knot spacing; fill the before/after table with `measure_area.py` (before = ledger D's STLs, same ruler); report.
- Not started: close-out (delete the switch and the old path) waits for the gate and his OK.

## Report (04-tests.md "What a stage report contains"; numbers filled from the final batch)

- **Repo tests, failing -> passing:** A (known shapes: 0.12-0.24 mm -> worst 0.049, the 5 mm hole; walls 0.002) now `--gate`; B (drawn faces: flats 0.0000, bores 0.0007, a protected layer's face 0.003), F (ripple 0.015), J (one clean solid; also the edge-touching cases the stand forced) new and `--gate`. Held: M (switch off byte-identical to the tip build), K (switch on, same job twice, identical bytes). P (run time): from the final batch, below.
- **Open choice settled:** basis = cubic B-spline (reach 2 by its degree) with a band-weighted fit; measured against Gaussian (today), Wendland C2 and C4 at reach 2/3/4, at knot spacings 1, 1.5 and 2 voxels (test A matrix, below). Knot spacing: 2 voxels (today's rule) unless hold C (1.5 against 2 on Top Motor Mount) says otherwise. The plan's 2-4 line widths are under one voxel at every resolution he runs; one voxel made the re-fit unstable (surface moved up to 10 mm).
- **Reference table:** stage 1 + stage 3 (the configuration that ships: without stage 1 the protections are voxels), before = ledger D on the same ruler (`measure_area.py`). [to fill]
- **Refused:** nothing.
- **Known and handed on:** the device preview and the `.meta` basis name (#362's files, lines below); the slope of phi at shipped designs is not yet held near one (median about 3; a warm-started re-fit is the next measurement).

## What is built (all behind ONE switch, `TOPOPT_SURFACE`, default off = today)

| item | what | where |
|---|---|---|
| X-01, X-04 | The print surface is the zero surface of the optimiser's own function, meshed directly (marching tetrahedra on a body-centred grid, every vertex root-found to 1 um on the true zero set; Manifold::LevelSet). No fill fractions, no resample. | `mesh/level_surface.cpp` `mesh_level_surface`, `function_surface_mesh` |
| C-01, C-02, C-03, B (rule 9) | Drawn faces exact: the function's surface is CUT BY THE DRAWN PART (exact boolean), so every drawn face the design keeps is the drawn face itself, any surface type (fillets, cones, splines too). The CAD snap is not called. | `function_surface_mesh`, `to_export.inc` |
| I-02 | The STEP part is tessellated at 0.01 mm / 0.1 rad (was 0.1 mm / 0.5 rad) so its triangles meet the 0.02 mm target. | `io/step.cpp` |
| F-01 | The curvature flow does not run (`FinishContext::flow`). The thin-spot cleanup still runs (stage 4). | `finish.cpp` |
| B-01 | Crease-free bases: Wendland C4 and the cubic B-spline (tensor product; reproduces any flat wall exactly) beside today's Gaussian and Wendland C2. | `plsm_basis.hpp` |
| V-02 (optimiser side) | Outside the part nothing acted on the function, so its zero set floated between the last part voxel and the drawn face (a smoothed staircase). Each Empty voxel within the basis reach now takes its nearest part voxel's value before every re-distance and fit, so the design's own decision reaches the drawn face. | `plsm.cpp` `extend_into_empty` |
| P-04 (part) | The frozen voxels the function does not already explain are recovered from the shipped density, sample for sample on the optimiser's own sub-cell lattice, so the file holds exactly what was certified. Still voxel-shaped inside the part: see "not done". | `function_surface_mesh` |
| P-11 | Every re-fit's move of the surface is measured and reported (max, RMS). | `plsm.cpp` |
| P-05 | Volume offset: warm bracket, about 40 passes instead of 100. | `plsm.cpp` |
| P-16, P-17 | Hard 1/64 count off under the switch; border stencil fixed. | `plsm.cpp`, `plsm_frac.hpp` |

Switch values: `on` (the chosen basis), or a measurement arm `on:<basis>:<reach>:<knot line widths>`.

## Tests

Run on a Release build of this branch (2026-11-25).

| test | target | before (today's export) | after (switch on) | ctest |
|---|---|---|---|---|
| A known shapes, voxel 1.7 mm (vertices AND triangle interiors) | 0.05 mm | 0.12 to 0.24 mm (walls 0.12-0.19, holes 0.22-0.24, sphere 0.20) | walls 0.001-0.003, hole 10 mm 0.011, sphere 0.015, hole 5 mm 0.049 | `--gate` |
| B drawn faces (block with a bore, 17/9 deg to the grid; a 4 mm protected layer with a cavity cut into it) | 0.02 mm | (CAD snap: planes and cylinders only, within one voxel; ledger C-02) | flats 0.0000, bore 0.0001 (mean radius 4.9999 of 5.0), protected layer's inner face 0.015 | `--gate` |
| F ripple at 1-10 mm (a 40 mm wave tilted 13/7 deg) | 0.05 mm | not measured on the old path | 0.016 | `--gate` |
| J one clean solid | no bad edge, no point contact | | 0 / 0 / 0, one body (after welding as written: the exact cut can leave a float-coincident sliver) | `--gate` |
| K same job twice | same bytes | | TOReview's in-process test K runs for hours on the demo fixture; mine is the stand job run twice through the CLI, compared byte for byte (below) | |
| M off path unchanged | same bytes as before | | stand at res 64, switch off, against TOReview's tip build (same TO sources as 2b40bcf4) (below) | |
| P Release time | within 10 % | | (below) | |

## The open choice: basis, reach, knot spacing

Test A's worst distance over all eight shapes (mm), the shape fitted the way the optimiser's own re-fit fits it, its zero surface meshed directly:

| basis, reach | knots 1 voxel | 1.5 voxels | 2 voxels (today's rule at 1.7 mm) |
|---|---|---|---|
| Gaussian, 2 (today) | 0.029 | 0.076 | 0.134 |
| Gaussian, 3 / 4 | 0.094 / 0.106 | | |
| Wendland C2, 2 / 3 / 4 | 0.032 / 0.020 / 0.020 | - / 0.077 / 0.108 | - / 0.138 / 0.138 |
| Wendland C4, 2 / 3 / 4 | 0.098 / 0.025 / 0.020 | - / 0.083 / 0.079 | - / 0.134 / 0.136 |
| cubic B-spline (reach 2 by degree) | 0.022 | 0.075 | 0.119 |
| **cubic B-spline, band-weighted fit** | 0.022 (more knots than voxels: the fit interpolates, the weight cannot act) | **0.040** | **0.049** |

The band-weighted fit puts weight 1 on the voxels within 1.5 voxels of the surface and 0.01 elsewhere (plsm_solve_normal's W, which existed and was never armed): only the surface carries geometry, so the fit spends its accuracy there. Flat walls go from 0.02 to 0.002 mm with it. Reading: the B-spline is the best basis at every spacing, and the cheapest (64 knots per point; Wendland reach 4 at one voxel touches about 270). Settled for the switch: **cubic B-spline, band-weighted fit**. The knot spacing is set by the real-part runs below.

## Reference table, before and after

### 2040 Extrusion Stand at res 64 (quick part; 77 % of it frozen, so this rung keeps only the frozen set and the design barely moves)

Release build, same job; "before" is TOReview's tip build (same TO sources as 2b40bcf4). Wall patches = TOReview's measure_surface.py, 3 mm patches on sloped and curved walls (the drawn flats and sharp edges are counted apart).

| run | margin (certified -> file re-check) | grams (file) | wall patches: median / 90th pct / worst | share over 0.05 mm |
|---|---|---|---|---|
| before (today's export) | 4.696 -> 4.731 | 90.5 | 0.092 / 0.32 / 0.56 mm | 68 % |
| switch off (this branch) | byte-identical to before (test M) | | | |
| stage 3 on | 4.679 -> 5.014 | 84.5 | 0.000 / 0.09 / 0.17 mm | 37 % |
| stage 3 on, run twice | byte-identical files (test K) | | | |
| stage 1 (TOReview's, face loads) alone | 4.896 | 90.5 | 0.104 / 0.32 / 0.57 | 71 % |
| stage 1 + stage 3 | 4.884 -> 4.979 | 87.3 | 0.023 / 0.32 / 0.85 | 39 % |

Why the file is 6 g lighter: it follows his 211 keep regions EXACTLY, where today's file keeps every frozen voxel whole (half a 3.4 mm voxel past a keep region's boundary) plus the Catmull-Rom overshoot into empty neighbours (probed point by point). Without stage 1 the frozen faces come from stamped voxels (smoothed as today's export does); with stage 1 they come from the drawn faces by true distance.

What the real part forced (all fixed, all inside the switch): the design-box check read the grid's margin as a design box (the export silently fell back); 91 frozen bodies queried one by one (47 s; merged by depth: 11 s); a body list that moved its meshes under the distance finders (crash with two or more bodies); keep regions joined by a second, nudged union along faces that are now exactly the part's (bad edges: now joined before the one cut); two voxels or two keep regions that share only an edge (now fused 0.01 mm); pinch points where the mesher snapped a saddle onto a grid point (two sheets at one float position: each copy moves 1 um into its own solid).

### Hold 1 of the reference batch (2026-11-25, Release, frozen binary 157609bc, switch on; stage 1 off)

"Before" is ledger D (TOReview's runs of the released worker CLI). Wall patches as above; their count n changes because the drawn flats are now exact and counted apart.

| part (res) | before: versions, margin, grams | after: versions, margin (certified -> file), grams | wall patches before: median / p90 / worst, share > 0.05 | after |
|---|---|---|---|---|
| Stand (128) | 1; 2.40; 86.6 g | 1; 2.39 -> 2.65; 84.8 g | 0.160 / 0.33 / 0.40, 98 % (n 145) | 0.000 / 0.15 / 0.25, 38 % (n 16) |
| Top Motor Mount (96), rung 0.68 | 4 versions; 1.64; 105.3 g | 4 versions; 1.64 -> 1.61; 104.5 g | 0.011 / 0.26 / 0.57, 35 % | **0.083 / 0.32 / 0.78, 64 % (worse)** |
| Top Motor Mount, rung 0.38 | 1.67; 100.6 g | 1.67 -> 1.64; 99.7 g | 0.037 / 0.28 / 0.61, 46 % | **0.057 / 0.30 / 0.81, 56 % (worse)** |
| Stand v4 (96) | NO version (file not one clean solid, X-05) | 1; 1.84 -> 1.88; 77.2 g (through the VOXEL export: design-box runs fell back; fixed since, not yet re-run) | - | 0.198 / 0.30 / 0.59, 93 % (voxel export) |

Pictures (depth-tested, same camera: as drawn | today | stage 3): `stage-3-pics/stand128_drawn_today_stage3.png`, `stage-3-pics/topmotor_drawn_today_stage3.png`. On Top Motor Mount the stage 3 file is visibly cleaner: round cut-outs where today's are voxel-stepped, exact countersinks, no stepped bumps at the joints. The side "lumps" on the stand are frozen pads that, with stage 1 off, can only come from voxels: they look alike in both.

**The 3 mm patch measure misread exact files; replaced by an area-sampled one.** TOReview's script finds its patches around mesh CORNERS, so an exact drawn face (a few large triangles) barely counts, and the two files are not sampled alike. `measure_area.py` (beside this file) samples both surfaces evenly by AREA and classes each 3 mm patch as DRAWN (on the drawn part within 0.05 mm), CUT (the optimiser's own surface) or SEAM (both), leaving sharp patches apart as before. Worst residual per patch, mm:

| file | cut surface: n, median / p90 / worst, share > 0.05 | seams: n, median / worst, share > 0.05 | drawn: worst, share > 0.05 |
|---|---|---|---|
| Stand 128, today | 22, 0.010 / 0.158 / 0.231, 41 % | 0 | 0.41, 5 % |
| Stand 128, stage 3 | 100, 0.006 / 0.008 / **0.009, 0 %** | 0 | 0.45, 3 % |
| Top Motor Mount 0.68, today | 4, 0.022 / 0.107 / 0.142, 25 % | 49, 0.238 / 0.568, 73 % | 0.40, 5 % |
| Top Motor Mount 0.68, stage 3 | 23, 0.112 / 0.249 / 0.299, **56 % (worse)** | 11, 0.168 / **0.190**, 100 % | 0.52, 9 % |
| Top Motor Mount 0.26, today | 25, 0.062 / 0.139 / 0.175, 56 % | 55, 0.228 / 0.625, 67 % | 0.39, 4 % |
| Top Motor Mount 0.26, stage 3 | 45, **0.000 / 0.053 / 0.129, 11 %** | 13, 0.149 / **0.277**, 100 % | 0.44, 8 % |

Sampling, fixed so the numbers repeat: the drawn part at one point per 0.05 mm x 0.05 mm (400 per mm2), each file at one per 0.25 mm x 0.25 mm (16 per mm2), 4,000 patch centres, 3 mm patches of 30 points or more, random seed 1. The BEFORE files are ledger D's own STLs (agent-scratch/toreview/baseline), read in place.

Old ruler against new, one row per part (wall patches, the old tool's single class; the new tool's cut surface):

| part | old tool, today -> stage 3: median / worst, share > 0.05 | new tool (cut surface), today -> stage 3: median / worst, share > 0.05 |
|---|---|---|
| Stand 128 | 0.160 / 0.40, 98 % -> 0.000 / 0.25, 38 % | 0.010 / 0.23, 41 % -> 0.006 / 0.009, 0 % |
| Top Motor Mount 0.68 | 0.011 / 0.57, 35 % -> 0.083 / 0.78, 64 % | 0.022 / 0.14, 25 % -> 0.112 / 0.30, 56 % |
| Top Motor Mount 0.26 | (not run on the old tool) | 0.062 / 0.18, 56 % -> 0.000 / 0.13, 11 % |

Why they differ: the old tool centres its patches on mesh corners, so it samples each file by its tessellation (today's voxel files have corners everywhere, stage 3's exact faces have few) and mixes drawn faces, cut walls and seams in one class; the new one samples by area and keeps them apart.

The "drawn" worst (0.4-0.5 in every file) is his own countersinks and small fillets, which no quadric fits at 3 mm. Reading: cut walls and seams are clearly better except the cut surface of Top Motor Mount's 0.68 version, where the rough chunk beside the box sits; at res 32 that roughness is already in the unfinished function surface, where this run has stamped voxels, so the stage 1 + stage 3 run decides whether the exact protection depths remove it.

 Two causes are being separated (runs at res 64, stage 1 on and off): (1) without stage 1 its protected faces come as stamped voxels (2,000-6,600 per version), now without the curvature flow that used to sand them; (2) between re-fits the optimiser's steps leave bumps at the knot spacing (about 3 mm) in the function itself, which the old export's fill, resample and flow low-passed and the exact surface shows. The re-fit now runs just before each margin probe so every certified design is re-normalised (the slope band), and its move is measured only where phi has a slope.

## Not done yet

- B-02, B-03, P-10 (single-pass basis build, a thread pool, per-iteration allocations): priced, not done. About 50 thread start-ups and six vector allocations per iteration cost milliseconds against a 1-28 s solve per iteration; the basis is built once per run. Worth doing only in the stage 10 clean-out.
- X-03 (the file re-check writes an STL and re-runs the whole analysis): the re-check is stage 1's R-07 (TOReview's to_run.inc); unchanged here.

## Research behind it (2026-11-25)

Read for this stage: 01-research.md section 3a; Swierstra 2020 section 4.3 (slope bound); Noël 2020 sections 1 and 7.1 (B-splines "promote smooth designs", slope held by a penalty on |grad phi|). Searched for newer work:

- Adaptive immersed isogeometric level-set topology optimisation (Struct Multidisc Optim 2025; free copy at par.nsf.gov/servlets/purl/10655130): higher-order B-spline level sets give smoother designs, and the analysis follows the smooth boundary. Supports the B-spline choice here, and idea 3 below.
- Smooth geometry extraction from SIMP results by a signed-distance RBF with volume preservation (arXiv 2512.06976, Dec 2025), and a sequential SIMP-to-level-set refinement (arXiv 2605.04735, 2026): both take the surface from a smooth function and then refine the SHAPE by optimisation, not by mesh smoothing (our candidate 6).
- 3MF Volumetric extension v1.0 (published 2025-11-13): a 3MF file can carry a level-set function instead of triangles (idea 1).
- Not found free: Sotola et al. 2024 on surface-based smoothing of optimisation results (title and DOI still to pin down).

## Ideas beyond the plan (for discussion with him; NOT acted on)

1. ~~Ship the design, not a mesh.~~ DROPPED 2026-11-25: no consumer slicer reads 3MF's implicit/level-set extension (his earlier check, confirmed: PrusaSlicer, Orca and Bambu import STEP and 3MF meshes and triangulate everything at import; nothing found for implicit 3MF).
2. **A CAD file for engineers (STEP)** (he likes this one; discussion 2026-11-25). What blocks a STEP that edits in every CAD program: (a) a solid is a jigsaw of smooth patches stitched at about 0.001 mm, and cutting an organic, many-holed surface into a clean patch layout automatically is the hard part (nTop's own route, quad mesh to CAD body, "works reliably only on fairly simple models"); (b) patches that miss each other by more than the CAD kernel's tolerance import as loose surfaces, not a solid; (c) the seams with his drawn faces must be cut exactly on both sides, and each kernel (Parasolid: SolidWorks, NX, Onshape; ShapeManager: Fusion, Inventor; CGM: CATIA; OCCT: FreeCAD) re-checks with its own tolerances; (d) thousands of patches are slow; (e) "editable" means direct edits (holes, cuts, fillets, shell), never a feature history. What we have for it: his drawn faces stay his exact B-rep faces (only trimmed), our shape is already one smooth cubic B-spline (fitting is well posed), and OCCT, already in core, can build NURBS faces, sew, fix, check validity and write STEP. Proven route elsewhere: quad remesh, then a subdivision surface, then NURBS patches (Rhino, Fusion). Next step if he wants it: a one-part prototype, checked valid in OCCT and FreeCAD, opened by him in his CAD program, before any estimate.
3. **Certify the smooth surface itself.** Today the strength check reads voxels and the file is smooth. An analysis that cuts the voxels at the true surface (Andreasen 2020; the 2025 immersed paper) would make "certified = printed" true by construction and steady the stress number across resolutions (stage 2's A-02). Large; joint with stage 2.
4. **Auto and engineer controls for smoothness.** Auto: the knot spacing follows the printer's line width and the resolution; nothing on screen. Engineer: one "Detail (mm)" control, the smallest feature the shape may have, with an (i).
5. **A last polish on the real surface.** After the ladder, a short shape pass with the analysis on the smooth surface (Swierstra 2020 stage 3; the 2026 preprint). The "designed" look, possibly some margin back. Cost: about one more optimisation.

## For #362 (carried by TOReview with the switch flip; not edited here)

Known until then: with the switch on, the `.meta` beside the coefficients names the basis "wendland" for the new bases, and the device preview is still meshed from the voxels, so it differs from the print file (rule 12) until the second change lands.

1. `core/src/cli/run_job.cpp:480`, the `.meta` writer. Replace the two lines

        << "basis " << (variant.plsm_basis_kind == PlsmBasisKind::Gaussian
                            ? "gaussian" : "wendland") << "\n"

   with

        << "basis " << plsm_basis_name(variant.plsm_basis_kind) << "\n"

2. `app/TopOptKit/Sources/TopOptBridge/bridge.cpp:348-360`, `export_display_mesh`. Give it the imported part (`const topopt::TriangleMesh* part`, the STEP's `StepModel::drawn_mesh()` or the STL's mesh) and, when the run has them, `const std::vector<topopt::FrozenFaceSet>* frozen` and `const topopt::StepModel* model`; then, before the resample:

        if (topopt::to_surface_on() && part != nullptr) {
          std::string why;
          topopt::TriangleMesh m = topopt::function_surface_mesh(
              v, solved_grid, *part, factor, /*printed_iso=*/0.5, &why, nullptr, frozen, model);
          if (!m.triangles.empty()) { scratch = std::move(m); return scratch; }
        }

   (`#include "topopt/level_surface.hpp"`). The display then IS the print file's surface (before the finish's thin-spot cleanup and the Keep clear cut, which the CLI applies after).
