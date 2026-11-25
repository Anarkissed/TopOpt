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
