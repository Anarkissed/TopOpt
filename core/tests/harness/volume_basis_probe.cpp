// volume_basis_probe.cpp — WHAT DENOMINATOR `achieved_vf` USES (task
// 2026-08-02-iteration-phase-timing, bar Y5). NOT a CI test. READ-ONLY: it
// voxelizes and counts, and never runs a solve or an optimizer step.
//
// THE QUESTION. A real design-box run reported ladder rung 3 targeting volume
// fraction 0.26 while iterations.csv's `achieved_vf` column read 0.0071 — a 37x
// apparent miss — and rung 0 targeting 0.68 while the column read 0.039. Two
// readings of ONE number cannot both be right, so: which base is each on, and
// did the rung actually fail to reach its target?
//
// WHAT THIS PROBE DOES. It reconstructs, by counting rather than by fitting, the
// three quantities minimize_plastic's whole-domain rescale is built from:
//
//   P = part_solid       solid voxels of the ORIGINAL part grid
//   A = active_effective solved-grid voxels the volume constraint MOVES
//                        (mask Active, tag not Load/Fixture/Empty)
//   F = frozen_effective solved-grid voxels effective_mask PINS solid
//                        (tag Load/Fixture, or mask FrozenSolid)
//
// It then prints, for each ladder rung, the EFFECTIVE fraction the optimizer is
// actually driven to,
//                    opt.volume_fraction = (vf * P - F) / A,
// which is exactly what `achieved_vf` measures once the constraint is met (both
// are "sum of physical density over the Active set, divided by the Active
// count"). The counting loop below is a transcription of the one in
// core/src/simp/minimize_plastic.cpp; the mask and grid come from the SAME
// public entry point the driver solves on (minimize_plastic_solved_grid /
// expand_design_domain with kDesignBoxCoarsenAlign), so nothing here is a
// re-derivation that could drift from what runs.
//
// Build:
//   c++ -std=c++17 -O2 -I include -I /opt/homebrew/include/eigen3 \
//       -DVB_MODEL='"tests/fixtures/demo/l-bracket.step"' \
//       tests/harness/volume_basis_probe.cpp build/libtopopt.a \
//       $(pkg-config --libs opencascade 2>/dev/null) -o build/volume_basis_probe
//   ./build/volume_basis_probe

#include <cmath>
#include <cstdio>
#include <vector>

#include "topopt/pipeline.hpp"
#include "topopt/step.hpp"
#include "topopt/voxel.hpp"

using namespace topopt;

#ifndef VB_MODEL
#define VB_MODEL "tests/fixtures/demo/l-bracket.step"
#endif

int main() {
  // The reproduction job (evidence/2026-08-02-iteration-phase-timing/ladder32.json).
  constexpr int kResolution = 32;
  const std::vector<double> kLadder = {0.68, 0.52, 0.38, 0.26};

  const StepModel model = import_step_file(VB_MODEL);
  VoxelGrid grid = voxelize(model.mesh, kResolution);
  // The fixture selector of the job: every cylindrical face of radius 2.5 mm.
  for (int fid = 0; fid < model.face_count; ++fid) {
    const StepFaceInfo& f = model.faces[static_cast<std::size_t>(fid)];
    if (f.kind == StepSurfaceKind::Cylinder &&
        std::fabs(f.cylinder_radius_mm - 2.5) <= 1e-6)
      tag_step_face(grid, model, fid, VoxelTag::Fixture);
  }

  MinimizePlasticOptions opts;
  DesignBox box;
  box.min = Vec3{-35.0, -27.5, -6.0};
  box.max = Vec3{45.0, 27.5, 64.0};
  opts.design_box = box;
  opts.freeze_imported_part = false;  // whole-domain optimize (the CLI default)

  const DesignDomain domain =
      expand_design_domain(grid, box, opts.keep_out_boxes,
                           opts.freeze_imported_part, kDesignBoxCoarsenAlign);
  const VoxelGrid& G = domain.grid;

  // Transcription of minimize_plastic's part_relative counting loop.
  const double P = static_cast<double>(grid.solid_count());
  double A = 0.0, F = 0.0;
  for (int k = 0; k < G.nz; ++k)
    for (int j = 0; j < G.ny; ++j)
      for (int i = 0; i < G.nx; ++i) {
        const std::size_t idx = G.index(i, j, k);
        const VoxelTag t = G.tag(i, j, k);
        if (t == VoxelTag::Load || t == VoxelTag::Fixture ||
            domain.mask[idx] == MaskValue::FrozenSolid) {
          F += 1.0;
          continue;
        }
        if (domain.mask[idx] != MaskValue::Active) continue;
        if (t == VoxelTag::Empty) continue;
        A += 1.0;
      }

  std::printf("part grid   : %dx%dx%d, spacing %.4f mm, solid P = %.0f voxels\n",
              grid.nx, grid.ny, grid.nz, grid.spacing, P);
  std::printf("solved grid : %dx%dx%d, spacing %.4f mm\n", G.nx, G.ny, G.nz,
              G.spacing);
  std::printf("active A    = %.0f voxels   frozen F = %.0f voxels\n", A, F);
  std::printf("A / P       = %.3f   (the design box is this many part-volumes)\n",
              A / P);
  std::printf("F / P       = %.4f\n\n", F / P);

  std::printf("%-6s %-10s %-22s %s\n", "rung", "ladder vf",
              "effective target (vf*P-F)/A", "ratio vf / effective");
  for (std::size_t r = 0; r < kLadder.size(); ++r) {
    const double vf = kLadder[r];
    const double eff = (vf * P - F) / A;
    std::printf("%-6zu %-10.2f %-22.6f %.1f\n", r, vf, eff, vf / eff);
  }
  std::printf(
      "\nThe CSV column `achieved_vf` measures sum(rho over Active) / A on the\n"
      "SOLVED grid; the ladder's vf is a fraction OF THE PART. The right-hand\n"
      "ratio is the whole apparent 'miss'. It is NOT constant across the ladder\n"
      "because the frozen term F is subtracted before dividing, so the two bases\n"
      "diverge further as vf shrinks.\n");
  return 0;
}
