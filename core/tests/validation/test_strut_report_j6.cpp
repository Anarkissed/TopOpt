// test_strut_report_j6 — bar L2 of task 2026-07-31-lattice-strut-strength-report:
// THE PRODUCTION PATH REPRODUCES PR 259's J6 NUMBERS.
//
// PR 259's probe rebuilt PR 255's three freshly-certified multiscale designs from
// their evidence fields, ran the REAL analyze_fixed_design with an octet posture,
// and applied the measured strut law to every latticed voxel's macro stress
// tensor (evidence/2026-07-31-lattice-dehomogenization-probe/j6_margins.csv):
//
//   design     strut-vm margin   interlayer margin   vm bound    il bound
//   s0_plain   0.6164            0.3936              89.234      76.858
//   s2_gappen  0.6320            0.3799              87.025      79.627
//   s3_contin  0.6266            0.3769              87.772      80.264
//
// This test drives the SAME three designs through the production report path —
// analyze_fixed_design's built-in strut-strength report (the law now embedded in
// core, the same solve, build direction z) — and requires agreement with the
// probe's table. A production path that cannot reproduce the probe is wrong.
//
// Tolerances are the CSV's own print precision (margins/rho %.4f -> 5e-5;
// bounds %.3f -> 5e-4); voxel counts must be exact. Two designs peak at rho
// 0.8980/0.8999, ABOVE the law-table ceiling 0.89598 — the probe clamped there
// silently, the production path clamps AND COUNTS (bar L5), so those two must
// report a nonzero rho_clamped_voxels. The probe's own designs run ~1.5 cells
// through the 6 mm thickness against the 5-cell floor, so every design must
// also be flagged OUT OF REGIME (bar L4) — the strut numbers reproduce, and the
// receipt says exactly how far to trust them.
//
// SKIPs (exit 0 with a loud message) if the PR 255 evidence fields are absent —
// the numbers live in the repo's evidence tree, not in test fixtures.

#include "topopt/analyze.hpp"
#include "topopt/fea.hpp"
#include "topopt/lattice.hpp"
#include "topopt/materials.hpp"
#include "topopt/mesh.hpp"
#include "topopt/strut_strength.hpp"
#include "topopt/voxel.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

using namespace topopt;

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond, msg)                                           \
  do {                                                             \
    ++g_checks;                                                    \
    if (!(cond)) {                                                 \
      ++g_failures;                                                \
      std::fprintf(stderr, "FAIL (line %d): %s\n", __LINE__, msg); \
    }                                                              \
  } while (0)

namespace {

// PR 255 cantilever fixture — verbatim the probe's pr255 namespace (which was
// itself verbatim the feasibility probe's constants).
constexpr int kNx = 48, kNy = 24, kNz = 6;
constexpr double kTipLoadTotal = -200.0;
constexpr double kVoidTol = 1e-3;

VoxelGrid make_grid() {
  VoxelGrid g;
  g.nx = kNx;
  g.ny = kNy;
  g.nz = kNz;
  g.spacing = 1.0;
  g.origin = Vec3{0, 0, 0};
  g.tags.assign(static_cast<std::size_t>(kNx) * kNy * kNz, VoxelTag::Interior);
  return g;
}

void make_bcs_loads(const VoxelGrid& g, std::vector<DirichletBC>& bcs,
                    std::vector<NodalLoad>& loads) {
  for (int j = 0; j < g.ny; ++j)
    for (int k = 0; k < g.nz; ++k) {
      const std::array<int, 8> en = fea_element_nodes(g, 0, j, k);
      for (int n : {en[0], en[3], en[4], en[7]})
        for (int c = 0; c < 3; ++c) bcs.push_back({n, c, 0.0});
    }
  std::sort(bcs.begin(), bcs.end(),
            [](const DirichletBC& a, const DirichletBC& b) {
              return a.node != b.node ? a.node < b.node
                                      : a.component < b.component;
            });
  bcs.erase(std::unique(bcs.begin(), bcs.end(),
                        [](const DirichletBC& a, const DirichletBC& b) {
                          return a.node == b.node && a.component == b.component;
                        }),
            bcs.end());
  std::vector<int> tip;
  for (int k = 0; k <= g.nz; ++k)
    tip.push_back(((k * (g.ny + 1)) + g.ny / 2) * (g.nx + 1) + g.nx);
  for (int n : tip)
    loads.push_back({n, 1, kTipLoadTotal / static_cast<double>(tip.size())});
}

std::vector<double> snap_to_feasible(const std::vector<double>& rho, double lo,
                                     double hi) {
  std::vector<double> out(rho.size());
  for (std::size_t e = 0; e < rho.size(); ++e) {
    const double r = rho[e];
    double s = r;
    if (r <= kVoidTol) s = 0.0;
    else if (r < lo) s = (r < lo / 2.0) ? 0.0 : lo;
    else if (r <= hi) s = r;
    else if (r >= 1.0 - kVoidTol) s = 1.0;
    else s = (r - hi < 1.0 - r) ? hi : 1.0;
    out[e] = s;
  }
  return out;
}

Material pla_material() {
  Material m;
  m.youngs_modulus_mpa = 3500.0;
  m.yield_strength_mpa = 55.0;
  m.density_g_cm3 = 1.24;
  m.z_knockdown = 0.55;
  m.poisson = 0.33;
  m.family = "fdm";
  return m;
}

// Minimal CSV reader for the i,j,k,rho field files.
bool read_field(const std::string& path, const VoxelGrid& g,
                std::vector<double>& rho) {
  FILE* f = std::fopen(path.c_str(), "r");
  if (!f) return false;
  char line[256];
  if (!std::fgets(line, sizeof line, f)) {  // header
    std::fclose(f);
    return false;
  }
  rho.assign(g.voxel_count(), 0.0);
  while (std::fgets(line, sizeof line, f)) {
    int i, j, k;
    double r;
    if (std::sscanf(line, "%d,%d,%d,%lf", &i, &j, &k, &r) == 4)
      rho[g.index(i, j, k)] = r;
  }
  std::fclose(f);
  return true;
}

// The probe's J6 table (j6_margins.csv), at its own print precision.
struct Expected {
  const char* name;
  double margin_strut, margin_il;       // %.4f
  double vm_bound, il_bound;            // %.3f
  double max_macro_vm;                  // %.4f
  double argmax_rho;                    // %.4f
  std::size_t lattice_voxels;           // exact
  bool clamps_above_span;               // argmax rho above the 0.89598 ceiling
};
constexpr Expected kExpected[] = {
    {"s0_plain", 0.6164, 0.3936, 89.234, 76.858, 16.1124, 0.6307, 3648, false},
    {"s2_gappen", 0.6320, 0.3799, 87.025, 79.627, 16.5314, 0.8980, 3833, true},
    {"s3_contin", 0.6266, 0.3769, 87.772, 80.264, 17.7691, 0.8999, 3750, true},
};

}  // namespace

int main() {
  const std::string dir = PR255_FIELD_DIR;
  {
    FILE* probe_f = std::fopen((dir + "/p2_field_s0_plain.csv").c_str(), "r");
    if (!probe_f) {
      std::printf(
          "SKIP: PR 255 evidence fields not found under %s — the J6 "
          "reproduction needs the repo's evidence tree.\n",
          dir.c_str());
      return 0;
    }
    std::fclose(probe_f);
  }

  const VoxelGrid g = make_grid();
  std::vector<DirichletBC> bcs;
  std::vector<NodalLoad> loads;
  make_bcs_loads(g, bcs, loads);
  const double lo = lattice_rho_min(LatticeTopology::Octet);
  const double hi = lattice_rho_max(LatticeTopology::Octet);
  const Material mat = pla_material();
  SimpParams params;
  params.youngs_modulus = mat.youngs_modulus_mpa;
  params.poisson = mat.poisson;
  params.penalty = 3.0;
  const KnockdownSpec kd;

  for (const Expected& ex : kExpected) {
    std::vector<double> raw;
    if (!read_field(dir + "/p2_field_" + ex.name + ".csv", g, raw)) {
      CHECK(false, "field CSV unreadable");
      continue;
    }
    const std::vector<double> snapped = snap_to_feasible(raw, lo, hi);

    std::vector<double> density(g.voxel_count(), 0.0);
    LatticePosture post;
    post.topology = LatticeTopology::Octet;
    post.cell_size_mm = 4.0;
    post.mask.assign(g.voxel_count(), 0);
    post.relative_density.assign(g.voxel_count(), 0.0);
    for (std::size_t e = 0; e < snapped.size(); ++e) {
      if (snapped[e] <= 0.0) continue;
      density[e] = 1.0;
      if (snapped[e] < 1.0) {
        post.mask[e] = 1;
        post.relative_density[e] = snapped[e];
      }
    }

    // THE PRODUCTION PATH: analyze_fixed_design computes the strut report
    // itself (build direction z, the designs' build axis).
    const FixedDesignAnalysis a = analyze_fixed_design(
        g, params, density, bcs, loads, mat, Vec3{0, 0, 1}, 1e-8, 0,
        SolverKind::JacobiCG, 0.5, kd, /*load_path_ok=*/true,
        static_cast<double>(g.solid_count()), &post);
    const StrutStrengthReport& ss = a.lattice_strut;

    char msg[160];
    std::snprintf(msg, sizeof msg, "%s: strut report present", ex.name);
    CHECK(a.lattice_strut_report, msg);
    std::snprintf(msg, sizeof msg, "%s: lattice voxels %zu == probe %zu",
                  ex.name, a.lattice_voxels, ex.lattice_voxels);
    CHECK(a.lattice_voxels == ex.lattice_voxels, msg);

    std::snprintf(msg, sizeof msg,
                  "%s: strut vm margin %.4f == probe %.4f (tol 5e-5)", ex.name,
                  ss.margin_in_plane, ex.margin_strut);
    CHECK(std::fabs(ss.margin_in_plane - ex.margin_strut) < 5e-5, msg);
    std::snprintf(msg, sizeof msg,
                  "%s: interlayer margin %.4f == probe %.4f (tol 5e-5)",
                  ex.name, ss.margin_interlayer, ex.margin_il);
    CHECK(std::fabs(ss.margin_interlayer - ex.margin_il) < 5e-5, msg);
    std::snprintf(msg, sizeof msg,
                  "%s: vm bound %.3f == probe %.3f (tol 5e-4)", ex.name,
                  ss.vm_bound_max_mpa, ex.vm_bound);
    CHECK(std::fabs(ss.vm_bound_max_mpa - ex.vm_bound) < 5e-4, msg);
    std::snprintf(msg, sizeof msg,
                  "%s: interlayer bound %.3f == probe %.3f (tol 5e-4)", ex.name,
                  ss.il_bound_max_mpa, ex.il_bound);
    CHECK(std::fabs(ss.il_bound_max_mpa - ex.il_bound) < 5e-4, msg);
    std::snprintf(msg, sizeof msg,
                  "%s: max lattice macro vm %.4f == probe %.4f", ex.name,
                  ss.max_macro_vm_mpa, ex.max_macro_vm);
    CHECK(std::fabs(ss.max_macro_vm_mpa - ex.max_macro_vm) < 5e-5, msg);
    std::snprintf(msg, sizeof msg, "%s: argmax rho %.4f == probe %.4f",
                  ex.name, ss.vm_argmax_rho, ex.argmax_rho);
    CHECK(std::fabs(ss.vm_argmax_rho - ex.argmax_rho) < 5e-5, msg);

    // Bar L5 made visible on real designs: the probe clamped rho above the law
    // ceiling silently; the production path counts it.
    if (ex.clamps_above_span) {
      std::snprintf(msg, sizeof msg,
                    "%s: above-span rho voxels are COUNTED (%zu > 0)", ex.name,
                    ss.rho_clamped_voxels);
      CHECK(ss.rho_clamped_voxels > 0, msg);
    }

    // Bar L4: these designs run ~1.5 cells through the 6 mm thickness — the
    // report must carry the out-of-regime flag the probe called out.
    std::snprintf(msg, sizeof msg,
                  "%s: cells/member %.2f below floor %.0f -> out of regime",
                  ex.name, a.lattice_min_cells_per_member,
                  lattice_cells_per_member_min(LatticeTopology::Octet));
    CHECK(a.lattice_strut_out_of_regime &&
              a.lattice_min_cells_per_member <
                  lattice_cells_per_member_min(LatticeTopology::Octet),
          msg);

    // Bar L1 on the real designs: the shipped verdict is untouched — these
    // designs were ACCEPTED at margin_stop 0.5 with margins ~1.46-1.50 and the
    // strut report (0.38-0.63) must not change that.
    std::snprintf(msg, sizeof msg,
                  "%s: shipped verdict unchanged (accepted, margin %.4f)",
                  ex.name, a.margin.worst_case);
    CHECK(a.accepted && a.margin.worst_case > 1.4, msg);

    std::printf(
        "%s: strut vm margin %.4f (probe %.4f), interlayer %.4f (probe %.4f), "
        "clamped %zu, cells/member %.2f -> %s\n",
        ex.name, ss.margin_in_plane, ex.margin_strut, ss.margin_interlayer,
        ex.margin_il, ss.rho_clamped_voxels, a.lattice_min_cells_per_member,
        a.lattice_strut_out_of_regime ? "OUT OF REGIME" : "in regime");
  }

  std::fprintf(stderr, "%d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
