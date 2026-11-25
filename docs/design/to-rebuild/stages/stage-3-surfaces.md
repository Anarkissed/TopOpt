# Stage 3: smooth surfaces (TOSurface)

Branch `claude/topopt-stage-3-surfaces-7f58fd`, from 2b40bcf4. Status: IN PROGRESS. Nothing here is released.

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

| test | before | after |
|---|---|---|
| A known shapes (gate 0.05 mm) | | |
| B drawn faces (0.02 mm) | | |
| F ripple 1-10 mm (0.05 mm) | | |
| J one clean solid | | |
| K, M, P | | |

## The open choice: basis, reach, knot spacing

## Reference table, before and after

## Not done yet

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
