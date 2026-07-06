// Gate V5 validation (ROADMAP M4.4, ARCHITECTURE §7 V5): orientation scoring on
// the hook fixture. The scorer combines the M4.3 support proxy with the max
// tensile stress across the print layer planes, knocked down by z_knockdown, and
// must rank the known-correct build direction first.
//
// The hook (tests/fixtures/orient/hook.stl, ground truth in expected_values.json)
// is a J-hook whose profile lies in the XY plane, extruded 8 mm in Z. Printed
// LYING FLAT (build +Z) the layers are parallel to the XY profile plane, so the
// bending tension path through the curve stays WITHIN layers and the flat
// silhouette needs ~no support. Printed UPRIGHT (build +Y) the layer planes are
// XZ, so that same tension path crosses layer boundaries (the classic snapped-hook
// failure) and the curve underside is an unsupported overhang. The scorer must
// rank [0,0,1] strictly better than [0,1,0] and first among all candidates, for
// PLA (z_knockdown 0.55). Numeric scores are not pinned — only the ORDER (per the
// fixture's ORDINAL-ONLY assertion). This test drives fea_solve (Eigen), so it is
// gated on Eigen in CMake like the other validation gates.

#include "topopt/fea.hpp"
#include "topopt/mesh.hpp"
#include "topopt/orient.hpp"
#include "topopt/stl.hpp"
#include "topopt/voxel.hpp"

#include <array>
#include <cmath>
#include <cstddef>
#include <cstdio>
#include <stdexcept>
#include <string>
#include <vector>

using topopt::CgInfo;
using topopt::DirichletBC;
using topopt::FeaSolution;
using topopt::NodalLoad;
using topopt::OrientationScore;
using topopt::TriangleMesh;
using topopt::Vec3;
using topopt::VoxelGrid;
using topopt::VoxelTag;

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond, msg)                                            \
  do {                                                             \
    ++g_checks;                                                    \
    if (!(cond)) {                                                 \
      ++g_failures;                                                \
      std::fprintf(stderr, "FAIL (line %d): %s\n", __LINE__, msg); \
    }                                                              \
  } while (0)

namespace {

double dot(const Vec3& a, const Vec3& b) {
  return a.x * b.x + a.y * b.y + a.z * b.z;
}

// Element-centroid Voigt stress recovered from the nodal solution (same pattern
// as the V4 gate). DOF order matches hex8_stiffness (node-major interleaved).
std::array<double, 6> element_stress(const VoxelGrid& g, const FeaSolution& s,
                                     double E, double nu, int i, int j, int k) {
  const std::array<int, 8> en = topopt::fea_element_nodes(g, i, j, k);
  std::array<double, 24> ue{};
  for (int a = 0; a < 8; ++a)
    for (int c = 0; c < 3; ++c)
      ue[static_cast<std::size_t>(3 * a + c)] = s.at(en[a], c);
  return topopt::hex8_stress(E, nu, g.spacing, ue).sigma;
}

// The scored candidate whose build_dir is parallel to `d` (exact direction, sign
// significant).
const OrientationScore& find_dir(const std::vector<OrientationScore>& v,
                                 const Vec3& d) {
  const double dl = std::sqrt(dot(d, d));
  const Vec3 u{d.x / dl, d.y / dl, d.z / dl};
  for (const OrientationScore& os : v)
    if (dot(os.build_dir, u) > 1.0 - 1e-6) return os;
  std::fprintf(stderr, "FAIL: direction (%.2f,%.2f,%.2f) not in candidate set\n",
               d.x, d.y, d.z);
  ++g_failures;
  return v.front();
}

}  // namespace

int main() {
  const std::string path = std::string(ORIENT_FIXTURE_DIR) + "/hook.stl";
  TriangleMesh mesh;
  try {
    mesh = topopt::import_stl_file(path);
  } catch (const std::exception& e) {
    std::fprintf(stderr, "FAIL: could not import hook.stl: %s\n", e.what());
    return 1;
  }

  // Voxelize. Longest axis is Y (46 mm); resolution 32 gives ~1.44 mm voxels, so
  // ~6 layers through the 8 mm thickness — enough to resolve the flat/upright
  // support difference and the through-thickness (sigma_zz) stress.
  const int resolution = 32;
  VoxelGrid grid = topopt::voxelize(mesh, resolution);

  // Tag the load case by coordinate (STL has no face identity; the fixture's
  // load_case describes the regions). Fixture: back-plate voxels against the x=0
  // wall face, over the plate's y extent [8,40]. Load: the inner surface of the
  // upturned tip / inner curve where a hung object bears (x~22, y~8..14), pulled
  // down (-y), matching load_direction_part_frame [0,-1,0].
  int fixture_voxels = 0, load_voxels = 0;
  for (int k = 0; k < grid.nz; ++k)
    for (int j = 0; j < grid.ny; ++j)
      for (int i = 0; i < grid.nx; ++i) {
        if (!grid.solid(i, j, k)) continue;
        const Vec3 c = grid.voxel_center(i, j, k);
        if (i == 0 && c.y >= 8.0 && c.y <= 40.0) {
          grid.set_tag(i, j, k, VoxelTag::Fixture);
          ++fixture_voxels;
        } else if (c.x >= 20.0 && c.x <= 27.0 && c.y >= 7.0 && c.y <= 15.0) {
          grid.set_tag(i, j, k, VoxelTag::Load);
          ++load_voxels;
        }
      }
  CHECK(fixture_voxels > 0, "back-plate fixture region has solid voxels");
  CHECK(load_voxels > 0, "tip load region has solid voxels");

  // Build BCs (clamp the whole back-plate face) and the downward tip load.
  const std::vector<int> fix_nodes =
      topopt::fea_tagged_nodes(grid, VoxelTag::Fixture);
  const std::vector<int> load_nodes =
      topopt::fea_tagged_nodes(grid, VoxelTag::Load);
  CHECK(!fix_nodes.empty(), "fixture nodes present");
  CHECK(!load_nodes.empty(), "load nodes present");

  std::vector<DirichletBC> bcs;
  for (int n : fix_nodes)
    for (int comp = 0; comp < 3; ++comp) bcs.push_back(DirichletBC{n, comp, 0.0});

  std::vector<NodalLoad> loads;
  const double total_force = -1.0;  // -y; magnitude is irrelevant to the ranking
  const double per_node = total_force / static_cast<double>(load_nodes.size());
  for (int n : load_nodes) loads.push_back(NodalLoad{n, 1, per_node});

  // Isotropic solve (the z_knockdown enters only in scoring, §7 V5). PLA-ish
  // isotropic constants; the ranking is scale-invariant, so exact values do not
  // matter. Use the Jacobi-CG solver (ARCHITECTURE §4's voxel-FEA solver): its
  // M3.1 void-DOF safety gate handles the near-zero-stiffness "hinge" nodes that a
  // staircased organic boundary produces, which the strict pivot check in the
  // direct fea_solve rejects.
  const double E = 3500.0, nu = 0.33;
  CgInfo cg_info;
  FeaSolution sol;
  try {
    sol = topopt::fea_solve_cg(grid, E, nu, bcs, loads, 1e-8, 0, &cg_info);
  } catch (const std::exception& e) {
    std::fprintf(stderr, "FAIL: fea_solve_cg threw: %s\n", e.what());
    return 1;
  }
  CHECK(cg_info.converged, "V5 solve: CG converged");

  // Recover the per-voxel stress field (grid-indexed Voigt; Empty voxels stay 0).
  std::vector<std::array<double, 6>> stress(grid.voxel_count(),
                                            std::array<double, 6>{});
  for (int k = 0; k < grid.nz; ++k)
    for (int j = 0; j < grid.ny; ++j)
      for (int i = 0; i < grid.nx; ++i)
        if (grid.solid(i, j, k))
          stress[grid.index(i, j, k)] = element_stress(grid, sol, E, nu, i, j, k);

  const std::vector<Vec3> candidates = topopt::orientation_candidates(mesh);
  CHECK(candidates.size() >= 26, "candidate set includes the sphere sampling");

  // ------------------------------------------------------------------
  // Gate V5: rank the correct orientation first, for PLA (z_knockdown 0.55).
  // ------------------------------------------------------------------
  const double k_pla = 0.55;
  std::vector<OrientationScore> ranked =
      topopt::score_orientations(grid, stress, candidates, k_pla);
  CHECK(ranked.size() == candidates.size(), "one score per candidate");

  const OrientationScore& flat = find_dir(ranked, Vec3{0, 0, 1});   // correct
  const OrientationScore& upright = find_dir(ranked, Vec3{0, 1, 0});  // must lose

  const OrientationScore& best = ranked.front();
  // The winner must be a flat (build-along-Z) orientation. [0,0,-1] ties [0,0,1]
  // (flat either face down) and tying is acceptable per the fixture.
  CHECK(std::fabs(dot(best.build_dir, Vec3{0, 0, 1})) > 0.999,
        "V5: top-ranked build direction is flat (parallel to +/-Z)");
  // [0,0,1] is the (tied) best.
  CHECK(std::fabs(flat.score - best.score) < 1e-9,
        "V5: [0,0,1] is tied for the best score");
  // [0,0,1] strictly beats the upright [0,1,0].
  CHECK(flat.score < upright.score,
        "V5: [0,0,1] ranks strictly better than [0,1,0]");

  // Both terms favour flat: support proxy AND interlayer tension.
  CHECK(flat.support_voxels == 0,
        "flat prism rests on the plate: zero support voxels");
  CHECK(upright.support_voxels > flat.support_voxels,
        "upright has a supported overhang (more support than flat)");
  CHECK(upright.interlayer_tension > flat.interlayer_tension,
        "upright carries more tension across its layer planes than flat");

  // ------------------------------------------------------------------
  // Mechanism (§7 V5): the ranking is driven at least in part by the z_knockdown
  // penalty on tension across layer planes, and that penalty responds to
  // z_knockdown. At z_knockdown = 1.0 (resin) the stress term loses its
  // preference (penalty 0 for every candidate); the support term may still
  // prefer flat.
  // ------------------------------------------------------------------
  CHECK(upright.stress_penalty > flat.stress_penalty,
        "penalty term prefers flat at z_knockdown 0.55");

  std::vector<OrientationScore> ranked_iso =
      topopt::score_orientations(grid, stress, candidates, 1.0);
  bool any_penalty = false;
  for (const OrientationScore& os : ranked_iso)
    if (os.stress_penalty != 0.0) any_penalty = true;
  CHECK(!any_penalty,
        "z_knockdown 1.0: stress penalty is 0 for every candidate (no preference)");
  // The raw interlayer tension is unchanged (it is the geometry/stress, not the
  // knockdown) — so the penalty change is due to z_knockdown alone.
  const OrientationScore& upright_iso = find_dir(ranked_iso, Vec3{0, 1, 0});
  CHECK(std::fabs(upright_iso.interlayer_tension - upright.interlayer_tension) < 1e-9,
        "interlayer tension is independent of z_knockdown");
  // With the stress term off, support alone still ranks a flat orientation first.
  CHECK(std::fabs(dot(ranked_iso.front().build_dir, Vec3{0, 0, 1})) > 0.999,
        "z_knockdown 1.0: support proxy alone still ranks flat first");

  std::printf(
      "V5 orientation ranking (hook.stl, res %d, %zu candidates, PLA k=%.2f):\n"
      "  fixture voxels=%d  load voxels=%d\n"
      "  best        dir=(%.2f,%.2f,%.2f) support=%d tension=%.4g penalty=%.4g "
      "score=%.4g\n"
      "  flat  [0,0,1] support=%d tension=%.4g penalty=%.4g score=%.4g\n"
      "  upright[0,1,0] support=%d tension=%.4g penalty=%.4g score=%.4g\n",
      resolution, candidates.size(), k_pla, fixture_voxels, load_voxels,
      best.build_dir.x, best.build_dir.y, best.build_dir.z, best.support_voxels,
      best.interlayer_tension, best.stress_penalty, best.score,
      flat.support_voxels, flat.interlayer_tension, flat.stress_penalty,
      flat.score, upright.support_voxels, upright.interlayer_tension,
      upright.stress_penalty, upright.score);

  if (g_failures == 0) {
    std::printf("V5 orientation scoring (M4.4): all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "V5 orientation scoring (M4.4): %d/%d checks FAILED\n",
               g_failures, g_checks);
  return 1;
}
