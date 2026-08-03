// frozen_buttress_probe.cpp — task 2026-08-04-protect-freeze-vs-solidity, item 9:
// FREEZE + DESIGN BOX SHOULD LET THE OPTIMIZER BUTTRESS.
//
// THE QUESTION, as posed and untested. A frozen wall cannot be thickened — its
// own density is pinned and it has no sensitivity. But the voxels BESIDE it do
// have sensitivity, and adding material against a thin frozen wall reduces its
// bending. Does the optimizer actually do it?
//
// And the named alternative, which is the interesting outcome if the answer is
// no: the frozen region's ZERO sensitivity may be starving the neighbours'
// signal, so the optimizer never learns that material there would help.
//
// WHAT IS MEASURED, three configurations of the same wall and the same load:
//
//   A  WALL ALONE, no design box. The wall is the whole domain; nothing can be
//      added. This is the reference the wall's own peak stress is read from.
//   B  WALL + DESIGN BOX, wall FROZEN. The question's configuration.
//   C  WALL + DESIGN BOX, wall ACTIVE (not frozen). The control that separates
//      "the optimizer will not buttress" from "the FREEZE stopped it": if C
//      places material beside the wall and B does not, the freeze is the cause,
//      and the starved-sensitivity hypothesis is the explanation. If neither
//      does, the freeze is exonerated and the answer is about the objective.
//
// Reported per configuration: material placed in the box (voxel count and where
// relative to the wall), and the WALL'S OWN peak von Mises — the number the
// question turns on.
//
// Prints a table; asserts nothing.

#include "topopt/analyze.hpp"
#include "topopt/fea.hpp"
#include "topopt/materials.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/production.hpp"
#include "topopt/settings.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

using namespace topopt;

namespace {

// 1 mm voxels. A wall standing in the y-z plane at x in [0, kWallT), 10 mm thick,
// 40 mm wide (y), 40 mm tall (z). It is clamped at its base (z = 0) and pushed in
// +X at its top edge — pure cantilever bending, the load case a buttress helps.
// The design box extends the domain to x in [0, kBoxX): 30 mm of empty space on
// the wall's +X side, exactly where a buttress would go.
constexpr int kWallT = 10;
constexpr int kBoxX = 40;
constexpr int kNY = 40, kNZ = 40;

struct Config {
  std::string name;
  bool box = false;
  bool freeze_wall = true;
  double vf = 0.6;
};

struct Result {
  long long added_voxels = 0;      // printed voxels OUTSIDE the wall
  long long adjacent_voxels = 0;   //   ... in the first 5 mm beside the wall
  double added_reach_mm = 0.0;     // furthest printed voxel from the wall face
  double wall_peak_vm = 0.0;       // the wall's OWN peak von Mises
  double wall_mean_vm = 0.0;
  bool converged = false;
};

}  // namespace

int main() {
  const MaterialLibrary lib = load_materials_file(MATERIALS_JSON_PATH);
  const Material mat = lib.at("PLA");
  const SettingsRules rules = load_settings_rules_file(SETTINGS_RULES_PATH);

  auto run = [&](const Config& cfg) {
    Result r;
    const int nx = cfg.box ? kBoxX : kWallT;
    VoxelGrid g;
    g.nx = nx; g.ny = kNY; g.nz = kNZ;
    g.spacing = 1.0;
    g.origin = Vec3{0.0, 0.0, 0.0};
    g.tags.assign(static_cast<std::size_t>(nx) * kNY * kNZ, VoxelTag::Empty);
    DesignMask mask(g.voxel_count(), MaskValue::Active);
    for (int k = 0; k < kNZ; ++k)
      for (int j = 0; j < kNY; ++j)
        for (int i = 0; i < nx; ++i) {
          const std::size_t e = g.index(i, j, k);
          // Everything is solid material the optimizer may hold: the WALL is the
          // part, the box region is the growth envelope (Interior, as
          // expand_design_domain tags it).
          g.tags[e] = VoxelTag::Interior;
          if (i < kWallT)
            mask[e] = cfg.freeze_wall ? MaskValue::FrozenSolid : MaskValue::Active;
        }

    // Clamp the wall's base (z = 0) across its own thickness only.
    std::vector<DirichletBC> bcs;
    for (int j = 0; j <= kNY; ++j)
      for (int i = 0; i <= kWallT; ++i) {
        const int n = fea_node_index(g, i, j, 0);
        bcs.push_back({n, 0, 0.0});
        bcs.push_back({n, 1, 0.0});
        bcs.push_back({n, 2, 0.0});
      }
    // Push the wall's top edge in +X — the bending the buttress would resist.
    std::vector<NodalLoad> loads;
    for (int j = 0; j <= kNY; ++j)
      loads.push_back({fea_node_index(g, 0, j, kNZ), 0, 4.0});

    MinimizePlasticOptions opt;
    configure_production_options(opt);
    opt.external_loads = loads;
    opt.require_external_loads = true;
    opt.design_mask = mask;
    opt.volume_fraction_ladder = {cfg.vf};
    opt.margin_stop = 0.0;
    opt.simp.max_iterations = 40;
    opt.keyframe_count = 0;

    MinimizePlasticResult res;
    try {
      res = minimize_plastic(g, mat, "PLA", bcs, rules, opt);
    } catch (const std::exception& e) {
      std::fprintf(stderr, "  [%s] run failed: %s\n", cfg.name.c_str(), e.what());
      return r;
    }
    if (res.evaluated.empty()) return r;
    const MinimizePlasticVariant& v = res.evaluated.front();
    r.converged = true;
    const std::vector<double>& d = v.optimization.physical_density;

    for (int k = 0; k < kNZ; ++k)
      for (int j = 0; j < kNY; ++j)
        for (int i = kWallT; i < nx; ++i)
          if (d[g.index(i, j, k)] >= 0.5) {
            ++r.added_voxels;
            if (i < kWallT + 5) ++r.adjacent_voxels;
            r.added_reach_mm =
                std::max(r.added_reach_mm, (i - kWallT + 1) * g.spacing);
          }
    double sum = 0.0;
    long long n = 0;
    for (int k = 0; k < kNZ; ++k)
      for (int j = 0; j < kNY; ++j)
        for (int i = 0; i < kWallT; ++i) {
          const std::size_t e = g.index(i, j, k);
          if (!(d[e] >= 0.5)) continue;
          const double vm = v.von_mises_field[e];
          r.wall_peak_vm = std::max(r.wall_peak_vm, vm);
          sum += vm;
          ++n;
        }
    r.wall_mean_vm = n > 0 ? sum / static_cast<double>(n) : 0.0;
    return r;
  };

  std::printf("=== item 9 — does a design box let the optimizer buttress a "
              "FROZEN wall? ===\n");
  std::printf("wall %d mm thick x %d x %d mm, clamped at z=0, pushed +X at the "
              "top edge\n", kWallT, kNY, kNZ);
  std::printf("design box adds %d mm of empty domain on the wall's +X side\n\n",
              kBoxX - kWallT);

  // The volume fraction is swept BECAUSE the first run of this probe was
  // uninformative at vf 0.6: the box saturates, both configs fill the whole
  // 5 mm slab beside the wall, and "material was placed" says nothing about
  // whether the optimizer CHOSE to put it there. At a tight budget it must
  // choose, and where it spends is the actual answer.
  std::printf("%-26s %6s %8s %10s %10s %10s %12s\n", "config", "vf", "conv",
              "added_vox", "adjacent", "reach_mm", "wall_peak_vM");
  for (const double vf : {0.60, 0.30, 0.15, 0.08}) {
    const Config configs[] = {
        {"A wall alone, no box     ", false, true, vf},
        {"B wall + box, wall FROZEN", true, true, vf},
        {"C wall + box, wall ACTIVE", true, false, vf},
    };
    Result rs[3];
    for (int i = 0; i < 3; ++i) rs[i] = run(configs[i]);
    for (int i = 0; i < 3; ++i)
      std::printf("%-26s %6.2f %8s %10lld %10lld %10.2f %12.6f%s\n",
                  configs[i].name.c_str(), vf, rs[i].converged ? "yes" : "NO",
                  rs[i].added_voxels, rs[i].adjacent_voxels, rs[i].added_reach_mm,
                  rs[i].wall_peak_vm,
                  i == 0 ? ""
                         : (rs[0].wall_peak_vm > 0.0 && rs[i].wall_peak_vm > 0.0
                                ? (rs[i].wall_peak_vm < rs[0].wall_peak_vm
                                       ? "  (wall stress FELL)" : "  (wall stress rose)")
                                : ""));
    std::printf("\n");
  }

  std::printf("READ IT LIKE THIS.\n"
      "  `adjacent` is printed voxels within 5 mm of the frozen wall's face —\n"
      "  where a buttress goes. `reach_mm` is how far the added material extends.\n"
      "  B is the question's configuration; C is the control that separates \"the\n"
      "  optimizer will not buttress\" from \"the FREEZE stopped it\": if C places\n"
      "  material beside the wall and B does not, the frozen region's zero\n"
      "  sensitivity is starving the neighbours' signal. If B places it too, the\n"
      "  freeze is exonerated — the adjoint still carries the frozen wall's own\n"
      "  compliance contribution into its neighbours' sensitivities, which is\n"
      "  what makes buttressing reachable at all.\n"
      "  At a LOOSE budget both saturate and the comparison is uninformative;\n"
      "  read the tight-budget rows.\n");
  return 0;
}
