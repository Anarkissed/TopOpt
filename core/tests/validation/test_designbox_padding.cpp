// Design-box coarsening-alignment test (design-box on-device fix).
//
// expand_design_domain now rounds the expanded ELEMENT dims UP to a multiple of
// `coarsen_align` (the driver passes 8) by APPENDING Empty voxels on the HIGH
// side of each axis. This lets the geometric-multigrid hierarchy coarsen every
// axis; without it an odd axis (the device case 90x78x91) makes the hierarchy
// bail to an effectively-hung Jacobi-CG on the ~1e-9-contrast design-box system.
//
// The padding must be PHYSICALLY INERT — Empty voxels carry no FEA element and
// are removed by the void-DOF gate, so the solved result is unchanged — and it
// must keep the BC/load remap correct (offset unchanged, since only the high side
// grows). This test proves all three:
//   (A) EQUIVALENCE: the SAME design-box graded solve on the UNPADDED grid
//       (coarsen_align=1, an odd axis -> Jacobi-CG fallback, but it completes)
//       and the PADDED grid (coarsen_align=8 -> multigrid) yields the SAME
//       compliance to solver tolerance (padding adds no physics).
//   (B) MULTIGRID ENGAGES: the padded matrix-free solve reports
//       used_multigrid==true with mg_levels>=3 (it could not on the odd grid).
//   (C) REMAP AT NONZERO OFFSET: the part sits at a nonzero voxel offset and its
//       corner node remaps onto the expanded grid unchanged by the alignment.
//
// Public API only, self-contained CHECK harness (ARCHITECTURE §4). Eigen-gated in
// CMake like the other solver tests.

#include "topopt/fea.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

#include <cmath>
#include <cstddef>
#include <cstdio>
#include <vector>

using topopt::CgInfo;
using topopt::DesignBox;
using topopt::DesignDomain;
using topopt::DirichletBC;
using topopt::MaskValue;
using topopt::NodalLoad;
using topopt::SimpCompliance;
using topopt::SimpParams;
using topopt::Vec3;
using topopt::VoxelGrid;
using topopt::VoxelTag;

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond, msg)                                            \
  do {                                                              \
    ++g_checks;                                                     \
    if (!(cond)) {                                                  \
      ++g_failures;                                                 \
      std::fprintf(stderr, "FAIL (line %d): %s\n", __LINE__, msg);  \
    }                                                               \
  } while (0)

namespace {

// A solid block part (all Interior), spacing 1, origin at 0.
VoxelGrid solid_block(int nx, int ny, int nz) {
  VoxelGrid g;
  g.nx = nx; g.ny = ny; g.nz = nz;
  g.spacing = 1.0;
  g.origin = Vec3{0, 0, 0};
  g.tags.assign(static_cast<std::size_t>(nx) * ny * nz, VoxelTag::Interior);
  return g;
}

// The design-box graded density field on an expanded domain: the frozen part is
// pinned to 1.0, the (solid) Active design voxels sit at `active_rho`, Empty
// voxels (out-of-box + high-side padding) are 0. Classified per-voxel by mask +
// tag, so the UNPADDED and PADDED domains produce the identical PHYSICAL field on
// their shared voxels (the padded domain only ADDS zero-density Empty voxels).
std::vector<double> designbox_density(const DesignDomain& d, double active_rho) {
  const VoxelGrid& g = d.grid;
  std::vector<double> rho(g.voxel_count(), 0.0);
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        const std::size_t e = g.index(i, j, k);
        if (!g.solid(i, j, k)) continue;  // Empty padding / out-of-box -> 0
        rho[e] = (d.mask[e] == MaskValue::FrozenSolid) ? 1.0 : active_rho;
      }
  return rho;
}

// Clamp the part's k=0 face and load its k=nz top face in -z, remapped onto the
// expanded grid `d` (the remap depends on d's node strides, so it is rebuilt per
// domain; the PHYSICAL nodes are identical across domains with the same offset).
void remapped_bcs_loads(const VoxelGrid& part, const DesignDomain& d,
                        std::vector<DirichletBC>& bcs,
                        std::vector<NodalLoad>& loads) {
  bcs.clear();
  loads.clear();
  auto pnode = [&](int a, int b, int c) {
    return topopt::fea_node_index(part, a, b, c);
  };
  for (int b = 0; b <= part.ny; ++b)
    for (int a = 0; a <= part.nx; ++a) {
      const int rn = topopt::remap_node_to_domain(part, d, pnode(a, b, 0));
      bcs.push_back({rn, 0, 0.0});
      bcs.push_back({rn, 1, 0.0});
      bcs.push_back({rn, 2, 0.0});
    }
  for (int b = 0; b <= part.ny; ++b)
    for (int a = 0; a <= part.nx; ++a)
      loads.push_back(
          {topopt::remap_node_to_domain(part, d, pnode(a, b, part.nz)), 2,
           -1.0e-2});
}

}  // namespace

int main() {
  // A solid block, and a design box that pads the LOW x face (a nonzero offset,
  // exercising the remap) and grows the domain to ODD unpadded dims on some axes
  // (so coarsen_align=1 hits the multigrid-bailing path the fix removes).
  const VoxelGrid part = solid_block(8, 8, 8);
  DesignBox box;
  box.min = Vec3{-3.5, -0.5, -0.5};   // lo_pad in x -> nonzero offset_i
  box.max = Vec3{12.5, 8.5, 8.5};     // grow beyond the far faces

  const DesignDomain d1 = topopt::expand_design_domain(part, box, {}, 1);
  const DesignDomain d8 = topopt::expand_design_domain(part, box, {}, 8);

  std::printf("[pad] unpadded grid = %dx%dx%d  padded grid = %dx%dx%d  "
              "offset=(%d,%d,%d)\n",
              d1.grid.nx, d1.grid.ny, d1.grid.nz, d8.grid.nx, d8.grid.ny,
              d8.grid.nz, d8.offset_i, d8.offset_j, d8.offset_k);

  // (C) Nonzero offset + alignment leaves the offset (and hence the remap) intact.
  CHECK(d1.offset_i == d8.offset_i && d1.offset_j == d8.offset_j &&
            d1.offset_k == d8.offset_k,
        "alignment does not change the part offset (high-side padding only)");
  CHECK(d8.offset_i > 0, "the design box produces a nonzero voxel offset");
  CHECK(d8.grid.nx % 8 == 0 && d8.grid.ny % 8 == 0 && d8.grid.nz % 8 == 0,
        "padded element dims are all multiples of 8");
  CHECK(d8.grid.nx >= d1.grid.nx && d8.grid.ny >= d1.grid.ny &&
            d8.grid.nz >= d1.grid.nz,
        "padding only grows the grid");
  const int part_corner = topopt::fea_node_index(part, 0, 0, 0);
  const int want = topopt::fea_node_index(d8.grid, d8.offset_i, d8.offset_j,
                                          d8.offset_k);
  CHECK(topopt::remap_node_to_domain(part, d8, part_corner) == want,
        "remap: the part origin node maps to the offset corner on the padded grid");

  SimpParams params;
  params.youngs_modulus = 2000.0;
  params.poisson = 0.30;
  params.penalty = 3.0;

  // (A) EQUIVALENCE: identical physical field on both grids -> identical
  // compliance to solver tolerance. Use a moderate Active density so the UNPADDED
  // (Jacobi-CG fallback) solve completes quickly; padding-inertness is
  // field-independent.
  const double active_rho = 0.5;
  const std::vector<double> rho1 = designbox_density(d1, active_rho);
  const std::vector<double> rho8 = designbox_density(d8, active_rho);

  std::vector<DirichletBC> b1, b8;
  std::vector<NodalLoad> l1, l8;
  remapped_bcs_loads(part, d1, b1, l1);
  remapped_bcs_loads(part, d8, b8, l8);

  CgInfo cg1, cg8;
  const SimpCompliance c1 = topopt::simp_compliance(
      d1.grid, params, rho1, b1, l1, 1e-9, 0, nullptr, nullptr,
      topopt::SolverKind::JacobiCG);
  const SimpCompliance c8 = topopt::simp_compliance(
      d8.grid, params, rho8, b8, l8, 1e-9, 0, nullptr, nullptr,
      topopt::SolverKind::JacobiCG);
  cg1 = c1.cg;
  cg8 = c8.cg;

  const double rel =
      std::abs(c1.compliance - c8.compliance) / std::abs(c1.compliance);
  std::printf("[pad] compliance unpadded=%.10e padded=%.10e  rel.diff=%.2e\n",
              c1.compliance, c8.compliance, rel);
  CHECK(c1.compliance > 0.0 && c8.compliance > 0.0,
        "both solves produced a positive compliance");
  CHECK(rel < 1e-6,
        "EQUIVALENCE: padded compliance matches the unpadded solve (padding "
        "adds no physics)");

  // (B) MULTIGRID ENGAGES on the padded grid via the matrix-free solver, on the
  // real ~1e-9-contrast design-box field (frozen=1, grown=rho_min).
  const double rho_min = 1e-3;  // rho_min^p = 1e-9 with p=3
  const std::vector<double> soft1 = designbox_density(d1, rho_min);
  const std::vector<double> soft8 = designbox_density(d8, rho_min);
  // Modulus per voxel = rho^p * E0.
  auto to_youngs = [&](const std::vector<double>& rho) {
    std::vector<double> ey(rho.size(), 0.0);
    for (std::size_t e = 0; e < rho.size(); ++e)
      ey[e] = std::pow(rho[e], params.penalty) * params.youngs_modulus;
    return ey;
  };
  CgInfo imf1, imf8;
  bool threw1 = false;
  try {
    topopt::fea_solve_mgcg_matfree(d1.grid, to_youngs(soft1), params.poisson, b1,
                                   l1, 1e-8, 0, &imf1);
  } catch (const std::exception&) {
    threw1 = true;  // odd unpadded grid: MG cannot build, Jacobi-CG may need a
                    // huge iteration count and hit the cap — that is the HANG the
                    // padding removes; not asserted, just informative.
  }
  const topopt::FeaSolution smf8 = topopt::fea_solve_mgcg_matfree(
      d8.grid, to_youngs(soft8), params.poisson, b8, l8, 1e-8, 0, &imf8);
  std::printf("[pad] matfree: unpadded used_mg=%d (threw=%d) | padded used_mg=%d "
              "mg_levels=%d iters=%d converged=%d\n",
              imf1.used_multigrid, threw1 ? 1 : 0, imf8.used_multigrid,
              imf8.mg_levels, imf8.iterations, imf8.converged);
  CHECK(!imf1.used_multigrid,
        "unpadded (odd) grid cannot build a multigrid hierarchy");
  CHECK(imf8.used_multigrid,
        "MULTIGRID ENGAGES: padded grid uses the matrix-free multigrid path");
  CHECK(imf8.mg_levels >= 3, "padded hierarchy has >= 3 levels");
  CHECK(imf8.converged, "padded matrix-free multigrid solve converged");
  CHECK(smf8.u.size() == static_cast<std::size_t>(3) *
                             topopt::fea_node_count(d8.grid),
        "padded solution is sized to the padded grid");

  if (g_failures == 0)
    std::printf("designbox_padding: all %d checks passed\n", g_checks);
  else
    std::fprintf(stderr, "designbox_padding: %d/%d checks FAILED\n", g_failures,
                 g_checks);
  return g_failures == 0 ? 0 : 1;
}
