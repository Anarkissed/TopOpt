// Unit tests for the warm-start restrict / prolong utilities (handoff 110,
// Part B). Pure geometry — no Eigen — so this runs on any toolchain. Covers the
// upsample operator correctness (trilinear on a known field, mean conservation),
// the restrict block-average, and the grid/BC/load/mask coarsening.

#include "topopt/warm_start.hpp"

#include <cmath>
#include <cstdio>
#include <vector>

#include "topopt/fea.hpp"
#include "topopt/voxel.hpp"

using namespace topopt;

static int g_failures = 0;
static int g_checks = 0;
#define CHECK(cond, msg)                                             \
  do {                                                               \
    ++g_checks;                                                      \
    if (!(cond)) {                                                   \
      ++g_failures;                                                  \
      std::fprintf(stderr, "FAIL (line %d): %s\n", __LINE__, msg);   \
    }                                                                \
  } while (0)

namespace {

VoxelGrid solid_grid(int nx, int ny, int nz, double h) {
  VoxelGrid g;
  g.nx = nx; g.ny = ny; g.nz = nz; g.spacing = h;
  g.origin = Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(nx) * ny * nz, VoxelTag::Interior);
  return g;
}

double mean_of(const std::vector<double>& v) {
  double s = 0.0;
  for (double x : v) s += x;
  return v.empty() ? 0.0 : s / static_cast<double>(v.size());
}

void test_coarsen_grid_dims() {
  // Even dims halve exactly; odd dims round up; spacing doubles, origin kept.
  VoxelGrid f = solid_grid(8, 4, 6, 2.0);
  f.origin = Vec3{1.0, 2.0, 3.0};
  VoxelGrid c = coarsen_grid(f);
  CHECK(c.nx == 4 && c.ny == 2 && c.nz == 3, "even dims halve exactly");
  CHECK(std::fabs(c.spacing - 4.0) < 1e-12, "spacing doubles");
  CHECK(c.origin.x == 1.0 && c.origin.y == 2.0 && c.origin.z == 3.0,
        "origin preserved");

  VoxelGrid f2 = solid_grid(7, 3, 1, 1.0);
  VoxelGrid c2 = coarsen_grid(f2);
  CHECK(c2.nx == 4 && c2.ny == 2 && c2.nz == 1, "odd dims round up, min 1");
}

void test_coarsen_grid_tag_priority() {
  // A coarse voxel takes the highest-priority child tag: Load > Fixture > solid.
  VoxelGrid f = solid_grid(2, 2, 2, 1.0);           // one coarse voxel
  f.set_tag(0, 0, 0, VoxelTag::Fixture);
  f.set_tag(1, 1, 1, VoxelTag::Load);               // Load wins
  VoxelGrid c = coarsen_grid(f);
  CHECK(c.voxel_count() == 1, "2x2x2 fine -> 1 coarse voxel");
  CHECK(c.tag(0, 0, 0) == VoxelTag::Load, "Load beats Fixture/solid");

  VoxelGrid f2 = solid_grid(2, 2, 2, 1.0);
  for (int i = 0; i < 8; ++i) f2.tags[i] = VoxelTag::Empty;
  f2.set_tag(0, 0, 0, VoxelTag::Fixture);           // one solid child
  VoxelGrid c2 = coarsen_grid(f2);
  CHECK(c2.tag(0, 0, 0) == VoxelTag::Fixture, "Fixture survives among Empty");
}

void test_restrict_block_average() {
  // 2x1x1 fine -> 1 coarse: coarse value is the mean of the two children.
  VoxelGrid f = solid_grid(2, 1, 1, 1.0);
  VoxelGrid c = coarsen_grid(f);
  std::vector<double> fd = {0.2, 0.8};
  std::vector<double> cd = restrict_density(f, c, fd);
  CHECK(cd.size() == 1, "coarse size 1");
  CHECK(std::fabs(cd[0] - 0.5) < 1e-12, "block average of {0.2,0.8} = 0.5");
}

void test_prolong_constant_exact() {
  // A constant coarse field upsamples to the same constant on the fine grid
  // (mean exactly conserved, no boundary bias).
  VoxelGrid f = solid_grid(8, 8, 8, 1.0);
  VoxelGrid c = coarsen_grid(f);
  std::vector<double> cd(c.voxel_count(), 0.37);
  std::vector<double> fd = prolong_density(c, f, cd);
  bool all_const = true;
  for (double x : fd) if (std::fabs(x - 0.37) > 1e-12) all_const = false;
  CHECK(all_const, "prolong(constant) == constant everywhere");
  CHECK(std::fabs(mean_of(fd) - 0.37) < 1e-12, "prolong(constant) conserves mean");
}

void test_prolong_trilinear_known() {
  // Trilinear on a 1D ramp along x. Coarse voxel centres sit at fine coordinates
  // via u = (i+0.5)/2 - 0.5, so a linear coarse field reproduces the same line at
  // interior fine samples. Coarse field c(I) = I along x (constant in y,z).
  VoxelGrid f = solid_grid(8, 1, 1, 1.0);
  VoxelGrid c = coarsen_grid(f);  // nx=4
  std::vector<double> cd(c.voxel_count(), 0.0);
  for (int I = 0; I < c.nx; ++I) cd[c.index(I, 0, 0)] = static_cast<double>(I);
  std::vector<double> fd = prolong_density(c, f, cd);
  // Fine i maps to u = (i+0.5)/2 - 0.5; interior fine samples interpolate the
  // line f(u) = u exactly. Check a mid-domain sample: i=4 -> u = 1.75 -> value 1.75.
  CHECK(std::fabs(fd[f.index(4, 0, 0)] - 1.75) < 1e-9,
        "trilinear ramp: fine i=4 -> 1.75");
  CHECK(std::fabs(fd[f.index(3, 0, 0)] - 1.25) < 1e-9,
        "trilinear ramp: fine i=3 -> 1.25");
  // Boundary clamp: i=0 -> u=-0.25 clamps to coarse 0 -> value 0.
  CHECK(std::fabs(fd[f.index(0, 0, 0)] - 0.0) < 1e-9,
        "trilinear ramp: fine i=0 clamps to 0");
}

void test_prolong_mean_conservation() {
  // A smooth field's mean is (approximately) conserved under upsampling. Build a
  // coarse field with a mild gradient and check the fine mean matches within a
  // small tolerance (boundary clamp gives a tiny bias, not a systematic drift).
  VoxelGrid f = solid_grid(16, 16, 16, 1.0);
  VoxelGrid c = coarsen_grid(f);
  std::vector<double> cd(c.voxel_count(), 0.0);
  for (int K = 0; K < c.nz; ++K)
    for (int J = 0; J < c.ny; ++J)
      for (int I = 0; I < c.nx; ++I)
        cd[c.index(I, J, K)] =
            0.5 + 0.1 * std::sin(0.3 * (I + J + K));
  const double cmean = mean_of(cd);
  std::vector<double> fd = prolong_density(c, f, cd);
  const double fmean = mean_of(fd);
  CHECK(std::fabs(fmean - cmean) < 0.02,
        "prolong conserves the mean within tolerance");
}

void test_restrict_prolong_roundtrip() {
  // restrict then prolong of a constant field is the identity.
  VoxelGrid f = solid_grid(8, 8, 8, 1.0);
  VoxelGrid c = coarsen_grid(f);
  std::vector<double> fd(f.voxel_count(), 0.6);
  std::vector<double> back = prolong_density(c, f, restrict_density(f, c, fd));
  bool same = true;
  for (double x : back) if (std::fabs(x - 0.6) > 1e-12) same = false;
  CHECK(same, "prolong(restrict(constant)) == constant");
}

void test_coarsen_bcs_face() {
  // A fixed x=0 face on the fine grid coarsens to the fixed x=0 face on the
  // coarse grid, deduped (multiple fine nodes map to one coarse node).
  VoxelGrid f = solid_grid(8, 4, 4, 1.0);
  VoxelGrid c = coarsen_grid(f);
  std::vector<DirichletBC> bcs;
  for (int b = 0; b <= f.ny; ++b)
    for (int cc = 0; cc <= f.nz; ++cc) {
      const int n = fea_node_index(f, 0, b, cc);
      bcs.push_back({n, 0, 0.0});
      bcs.push_back({n, 1, 0.0});
      bcs.push_back({n, 2, 0.0});
    }
  std::vector<DirichletBC> cb = coarsen_bcs(f, c, bcs);
  // Coarse x=0 face has (ny+1)*(nz+1) = 3*3 = 9 nodes, 3 components each = 27.
  CHECK(cb.size() == 27, "coarse face BC count = 9 nodes * 3 components");
  bool all_x0 = true;
  for (const DirichletBC& b : cb) {
    int a, bb, ccx; const int nx = c.nx + 1, ny = c.ny + 1;
    a = b.node % nx; int t = b.node / nx; bb = t % ny; ccx = t / ny;
    (void)bb; (void)ccx;
    if (a != 0) all_x0 = false;
  }
  CHECK(all_x0, "all coarse BC nodes lie on the x=0 face");
}

void test_restrict_loads_conserves_force() {
  // Total applied force per component is conserved through restriction.
  VoxelGrid f = solid_grid(8, 4, 4, 1.0);
  VoxelGrid c = coarsen_grid(f);
  std::vector<NodalLoad> loads;
  double total = 0.0;
  for (int b = 0; b <= f.ny; ++b)
    for (int cc = 0; cc <= f.nz; ++cc) {
      const int n = fea_node_index(f, f.nx, b, cc);
      loads.push_back({n, 2, -3.0});
      total += -3.0;
    }
  std::vector<NodalLoad> cl = restrict_loads(f, c, loads);
  double ctotal = 0.0;
  for (const NodalLoad& l : cl) { CHECK(l.component == 2, "component preserved"); ctotal += l.value; }
  CHECK(std::fabs(ctotal - total) < 1e-9, "restrict_loads conserves total force");
}

void test_coarsen_mask() {
  // All-active fine mask -> all-active coarse mask.
  VoxelGrid f = solid_grid(4, 4, 4, 1.0);
  VoxelGrid c = coarsen_grid(f);
  DesignMask m = make_active_mask(f);
  DesignMask cm = coarsen_mask(f, c, m);
  bool all_active = true;
  for (MaskValue v : cm) if (v != MaskValue::Active) all_active = false;
  CHECK(all_active, "all-active fine -> all-active coarse");

  // A single FrozenSolid child makes its coarse voxel FrozenSolid (keep-in wins).
  m[f.index(0, 0, 0)] = MaskValue::FrozenSolid;
  DesignMask cm2 = coarsen_mask(f, c, m);
  CHECK(cm2[c.index(0, 0, 0)] == MaskValue::FrozenSolid,
        "one FrozenSolid child -> FrozenSolid coarse voxel");
}

}  // namespace

int main() {
  test_coarsen_grid_dims();
  test_coarsen_grid_tag_priority();
  test_restrict_block_average();
  test_prolong_constant_exact();
  test_prolong_trilinear_known();
  test_prolong_mean_conservation();
  test_restrict_prolong_roundtrip();
  test_coarsen_bcs_face();
  test_restrict_loads_conserves_force();
  test_coarsen_mask();

  if (g_failures == 0)
    std::printf("PASS: warm_start unit (%d checks)\n", g_checks);
  else
    std::fprintf(stderr, "FAILED: %d/%d checks\n", g_failures, g_checks);
  return g_failures == 0 ? 0 : 1;
}
