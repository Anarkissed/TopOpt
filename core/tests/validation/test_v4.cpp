// V4 validation gate (ROADMAP M4.2 / ARCHITECTURE §7 V4): self-weight loading.
// "Column under gravity matches hand-calculated axial stress within 2%."
//
// Two parts:
//   (A) unit checks on self_weight_loads: the generated nodal load vector is
//       gravity x density x voxel_volume per solid voxel, lumped 1/8 to the
//       eight corner nodes and accumulated over shared nodes, in the requested
//       direction (default -z), with argument validation.
//   (B) the V4 gate: a prismatic column standing on a laterally-free u_z base,
//       loaded by its own weight, whose recovered axial stress sigma_zz matches
//       the analytical rho*g*(H - z) to <= 2% at the element centroids.
//
// No third-party test framework (ARCHITECTURE §4); the same self-contained CHECK
// harness as the other tests, public API only. Eigen-gated (drives fea_solve).

#include "topopt/fea.hpp"
#include "topopt/voxel.hpp"

#include <array>
#include <cmath>
#include <cstddef>
#include <cstdio>
#include <vector>

using topopt::DirichletBC;
using topopt::FeaSolution;
using topopt::Hex8Stress;
using topopt::NodalLoad;
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

VoxelGrid solid_grid(int nx, int ny, int nz, double h) {
  VoxelGrid g;
  g.nx = nx;
  g.ny = ny;
  g.nz = nz;
  g.spacing = h;
  g.origin = Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(nx) * ny * nz, VoxelTag::Interior);
  return g;
}

// Accumulate the generated loads into a per-node force vector (x,y,z) so a
// specific node's total self-weight share can be read back. Also asserts the
// generator emits at most one entry per (node, component).
std::vector<std::array<double, 3>> node_forces(const VoxelGrid& g,
                                               const std::vector<NodalLoad>& l) {
  const int N = topopt::fea_node_count(g);
  std::vector<std::array<double, 3>> f(static_cast<std::size_t>(N),
                                       std::array<double, 3>{0, 0, 0});
  std::vector<std::array<int, 3>> seen(static_cast<std::size_t>(N),
                                       std::array<int, 3>{0, 0, 0});
  for (const NodalLoad& nl : l) {
    f[static_cast<std::size_t>(nl.node)][static_cast<std::size_t>(nl.component)] +=
        nl.value;
    seen[static_cast<std::size_t>(nl.node)][static_cast<std::size_t>(nl.component)]++;
  }
  int dup = 0;
  for (const auto& s : seen)
    for (int c = 0; c < 3; ++c)
      if (s[static_cast<std::size_t>(c)] > 1) ++dup;
  CHECK(dup == 0, "self_weight_loads: one entry per (node, component)");
  return f;
}

// Element sigma_zz at the centroid, recovered from the nodal solution.
Hex8Stress element_stress(const VoxelGrid& g, const FeaSolution& s, double E,
                          double nu, int i, int j, int k) {
  const std::array<int, 8> en = topopt::fea_element_nodes(g, i, j, k);
  std::array<double, 24> ue{};
  for (int a = 0; a < 8; ++a)
    for (int c = 0; c < 3; ++c)
      ue[static_cast<std::size_t>(3 * a + c)] = s.at(en[a], c);
  return topopt::hex8_stress(E, nu, g.spacing, ue);
}

// -------------------------------------------------------------------------
// Part A: self_weight_loads generation
// -------------------------------------------------------------------------
void test_load_generation() {
  const double h = 2.0, rho = 3.0, grav = 9.81;
  VoxelGrid g = solid_grid(3, 3, 4, h);  // 36 solid voxels
  const double fvox = grav * rho * g.voxel_volume();  // per-voxel body force
  const int nvox = 36;

  std::vector<NodalLoad> loads = topopt::self_weight_loads(g, rho, grav);

  // Default direction is -z: every entry is a z force, all downward (negative).
  bool all_z = true, all_down = true, all_finite = true;
  double sum_z = 0.0;
  for (const NodalLoad& l : loads) {
    if (l.component != 2) all_z = false;
    if (!(l.value < 0.0)) all_down = false;
    if (!std::isfinite(l.value)) all_finite = false;
    sum_z += l.value;
  }
  CHECK(all_z, "default direction -z: all loads on the z component");
  CHECK(all_down, "default direction -z: all loads point down");
  CHECK(all_finite, "loads are finite");

  // Total applied weight equals the hand calc rho*g*V_total (equilibrium: the
  // base reaction must carry the whole column's weight).
  CHECK(std::fabs(sum_z - (-fvox * nvox)) <= 1e-9 * fvox * nvox,
        "total z force == -gravity*density*total_volume");

  std::vector<std::array<double, 3>> f = node_forces(g, loads);

  // A fully-solid grid touches every corner node, so there is exactly one load
  // per node (the z share).
  CHECK(static_cast<int>(loads.size()) == topopt::fea_node_count(g),
        "one load per node on a fully-solid grid");

  // Corner node (0,0,0) belongs to a single voxel -> exactly 1/8 of one voxel's
  // weight.
  const int corner = topopt::fea_node_index(g, 0, 0, 0);
  CHECK(std::fabs(f[static_cast<std::size_t>(corner)][2] - (-fvox / 8.0)) <=
            1e-9 * fvox,
        "corner node carries 1/8 of one voxel weight");

  // Node (1,1,1) is shared by 8 voxels -> a full voxel weight (8 * 1/8).
  const int interior = topopt::fea_node_index(g, 1, 1, 1);
  CHECK(std::fabs(f[static_cast<std::size_t>(interior)][2] - (-fvox)) <=
            1e-9 * fvox,
        "interior node (8 voxels) carries one full voxel weight");
  CHECK(std::fabs(f[static_cast<std::size_t>(corner)][0]) == 0.0 &&
            std::fabs(f[static_cast<std::size_t>(corner)][1]) == 0.0,
        "axis-aligned -z direction emits no x/y load");

  // Empty voxels carry no weight: removing one voxel drops exactly its weight.
  {
    VoxelGrid g2 = g;
    g2.set_tag(1, 1, 1, VoxelTag::Empty);
    std::vector<NodalLoad> l2 = topopt::self_weight_loads(g2, rho, grav);
    double s2 = 0.0;
    for (const NodalLoad& l : l2) s2 += l.value;
    CHECK(std::fabs(s2 - (-fvox * (nvox - 1))) <= 1e-9 * fvox * nvox,
          "empty voxels carry no self-weight");
  }

  // Direction need not be unit length: {0,0,-5} normalises to -z, same result.
  {
    std::vector<NodalLoad> l3 =
        topopt::self_weight_loads(g, rho, grav, Vec3{0.0, 0.0, -5.0});
    double s3 = 0.0;
    for (const NodalLoad& l : l3) s3 += l.value;
    CHECK(std::fabs(s3 - (-fvox * nvox)) <= 1e-9 * fvox * nvox,
          "non-unit direction is normalised");
  }

  // A general (diagonal) direction spreads the same total magnitude across the
  // three components in proportion to the unit direction.
  {
    const Vec3 d{1.0, 1.0, 1.0};
    const double inv = 1.0 / std::sqrt(3.0);
    std::vector<NodalLoad> l4 = topopt::self_weight_loads(g, rho, grav, d);
    std::vector<std::array<double, 3>> f4 = node_forces(g, l4);
    double sx = 0, sy = 0, sz = 0;
    for (const auto& v : f4) {
      sx += v[0];
      sy += v[1];
      sz += v[2];
    }
    const double comp = fvox * nvox * inv;  // total magnitude * unit component
    CHECK(std::fabs(sx - comp) <= 1e-9 * fvox * nvox &&
              std::fabs(sy - comp) <= 1e-9 * fvox * nvox &&
              std::fabs(sz - comp) <= 1e-9 * fvox * nvox,
          "diagonal direction splits the load across x,y,z");
  }

  // Argument validation.
  bool threw;
  threw = false;
  try {
    topopt::self_weight_loads(g, -1.0, grav);
  } catch (const std::invalid_argument&) {
    threw = true;
  }
  CHECK(threw, "negative density throws");
  threw = false;
  try {
    topopt::self_weight_loads(g, rho, -1.0);
  } catch (const std::invalid_argument&) {
    threw = true;
  }
  CHECK(threw, "negative gravity throws");
  threw = false;
  try {
    topopt::self_weight_loads(g, rho, grav, Vec3{0.0, 0.0, 0.0});
  } catch (const std::invalid_argument&) {
    threw = true;
  }
  CHECK(threw, "zero-length direction throws");
}

// -------------------------------------------------------------------------
// Part B: V4 column gate
// -------------------------------------------------------------------------
void test_v4_column() {
  const double E = 1000.0, nu = 0.3, rho = 2.5, grav = 9.81, h = 1.0;
  const int W = 2, Nz = 32;
  VoxelGrid g = solid_grid(W, W, Nz, h);
  const double H = Nz * h;  // physical column height

  // Base plane held vertically (u_z = 0) but free to contract laterally, plus a
  // minimal in-plane pin/roller to remove the remaining rigid modes without
  // over-constraining the Poisson lateral expansion. This reproduces the clean
  // uniaxial self-weight stress state (sigma_zz only).
  std::vector<DirichletBC> bcs;
  for (int b = 0; b <= g.ny; ++b)
    for (int a = 0; a <= g.nx; ++a)
      bcs.push_back({topopt::fea_node_index(g, a, b, 0), 2, 0.0});  // u_z base
  bcs.push_back({topopt::fea_node_index(g, 0, 0, 0), 0, 0.0});       // pin u_x
  bcs.push_back({topopt::fea_node_index(g, 0, 0, 0), 1, 0.0});       // pin u_y
  bcs.push_back({topopt::fea_node_index(g, g.nx, 0, 0), 1, 0.0});    // roller u_y

  std::vector<NodalLoad> loads = topopt::self_weight_loads(g, rho, grav);
  FeaSolution s = topopt::fea_solve(g, E, nu, bcs, loads);

  // Per-layer averaged sigma_zz vs analytical rho*g*(H - z_centroid).
  double base_rel = 0.0, worst_rel = 0.0, max_lat = 0.0;
  double prev_mag = 1e300;
  bool monotone = true;
  const double base_sigma = rho * grav * H;  // hand calc: weight / area at base
  std::printf("V4 self-weight column (W=%d, Nz=%d): sigma_zz vs rho*g*(H-z)\n", W,
              Nz);
  for (int k = 0; k < Nz; ++k) {
    double szz = 0.0, sxx = 0.0, syy = 0.0;
    int cnt = 0;
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        Hex8Stress st = element_stress(g, s, E, nu, i, j, k);
        szz += st.sigma[2];
        sxx += st.sigma[0];
        syy += st.sigma[1];
        ++cnt;
      }
    szz /= cnt;
    sxx /= cnt;
    syy /= cnt;
    const double zc = (k + 0.5) * h;
    const double ana = -rho * grav * (H - zc);
    const double rel = std::fabs(szz - ana) / std::fabs(ana);
    const double lat = std::fabs(sxx) / base_sigma;
    const double lat2 = std::fabs(syy) / base_sigma;
    if (rel > worst_rel) worst_rel = rel;
    if (lat > max_lat) max_lat = lat;
    if (lat2 > max_lat) max_lat = lat2;
    if (k == 0) base_rel = rel;
    // Compressive magnitude must decrease as we go up the column.
    if (std::fabs(szz) > prev_mag + 1e-9) monotone = false;
    prev_mag = std::fabs(szz);
    if (k < 4 || k == Nz - 1)
      std::printf("  k=%2d zc=%5.2f  fea=%+10.4f  ana=%+10.4f  rel=%.4f%%\n", k,
                  zc, szz, ana, 100.0 * rel);
  }
  std::printf("  base rel=%.4f%%  worst rel=%.4f%%  max lateral/base=%.4f%%\n",
              100.0 * base_rel, 100.0 * worst_rel, 100.0 * max_lat);

  // V4 gate: base (peak) axial stress within 2% of the hand-calculated value.
  CHECK(base_rel <= 0.02, "V4: base axial stress within 2% of rho*g*(H-z)");
  // Every element centroid across the whole column within 2% (the full linear
  // self-weight profile, not just the peak).
  CHECK(worst_rel <= 0.02, "V4: axial stress within 2% at every layer");
  // The state is essentially uniaxial: lateral normal stresses are negligible,
  // so the compared sigma_zz really is the axial stress.
  CHECK(max_lat <= 0.02, "V4: lateral normal stress negligible (uniaxial)");
  CHECK(monotone, "V4: axial compression decreases up the column");

  // Equilibrium hand-check: the total applied weight equals rho*g*(volume).
  double sum_z = 0.0;
  for (const NodalLoad& l : loads) sum_z += l.value;
  const double W_total = rho * grav * g.solid_volume();
  CHECK(std::fabs(sum_z + W_total) <= 1e-9 * W_total,
        "V4: total self-weight == rho*g*column_volume");
}

}  // namespace

int main() {
  test_load_generation();
  test_v4_column();

  if (g_failures == 0) {
    std::printf("V4 self-weight validation: all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "V4 self-weight validation: %d/%d checks FAILED\n",
               g_failures, g_checks);
  return 1;
}
