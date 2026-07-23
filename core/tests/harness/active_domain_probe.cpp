// active_domain_probe.cpp — measurement harness (NOT a CI test) for handoff 131,
// ACTIVE DOMAIN Phase 0 (feasibility de-risk, measure-first).
//
// NO production code is changed by this file. Everything below is built from the
// PUBLIC topopt API (minimize_plastic / simp_compliance / oc_update /
// make_density_filter) plus the 117 read-only observability hooks. The
// "restricted" solve is realised by handing simp_compliance a COPY of the grid
// with out-of-band voxels re-tagged Empty — the existing M3.1 void-DOF gate then
// eliminates their DOFs exactly, with a traction-free band boundary. That is the
// stated boundary treatment.
//
// Four measurements, bars stated in the handoff BEFORE the numbers:
//
//   [1] CEILING     — for production-shaped density trajectories, the ACTIVE
//                     fraction per iteration per rung: core = {rho > 1.5*rho_min}
//                     dilated by a k-voxel growth band, k in {2,4,8}. Element
//                     fraction AND node(DOF) fraction. This is the speedup ceiling.
//   [2] CORRECTNESS — full-domain vs band-restricted FEA at TIGHT tolerance on
//                     the same field: compliance delta, sensitivity delta, and
//                     |drho| after N optimizer steps (harness OC loop: identical
//                     filter/updater/move, ONLY the solve differs).
//   [3] MECHANICS   — band-update cadence sweep (every iter vs every K), mask
//                     determinism (bit-identical re-derivation), and the GROWTH
//                     INVARIANT: how far outside the band the FULL-domain solve
//                     wants to put material in one step (the band must grow
//                     before the design can).
//   [4] ARITHMETIC  — measured wall/CG cost of the restricted solve vs the full
//                     solve on identical fields, plus DOF/element/memory counts.
//
// Mask rule under test (pure function of the density field, fixed traversal):
//   active(e) = solid(e) AND [ rho_e > 1.5*rho_min
//                              OR e carries a Load/Fixture tag
//                              OR dist_cheb(e, {rho > 1.5*rho_min}) <= k ]
// Chebyshev (cube) dilation is used, which is the CONSERVATIVE choice: a cube of
// half-width k contains the Euclidean ball of radius k, so every active fraction
// reported here is an UPPER bound on what a Euclidean band of the same k costs.
//
// Build (standalone; NOT wired into CTest):
//   c++ -std=c++17 -O2 -I core/include -I /opt/homebrew/include/eigen3 \
//     -DSETTINGS_RULES_PATH="\"$PWD/core/src/settings/rules.json\"" \
//     core/tests/harness/active_domain_probe.cpp build/libtopopt.a \
//     -o /tmp/active_domain_probe
// Run (TOPOPT_AD_CSV_DIR selects where ceiling.csv / trajectory.csv are appended):
//   ceiling      [1]  driver ladders on 3 fixtures (snug / 10x box / 172x box). HOURS.
//   traj         [2][3] 7 side-by-side full-vs-restricted OC trajectories, 25x box.
//   ultradilute  [1][2][4] 3 trajectories + arithmetic on a 49x box (~2 % part fill).
//   arith        [4] full-vs-restricted solve timing. RUN ON AN IDLE MACHINE.
//   correctness  = traj + arith;  all = ceiling + correctness
//   snapshots <dir>   scan a CLI --snapshots capture (.f16 + .json sidecars)

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dirent.h>
#include <string>
#include <vector>

#include "topopt/fea.hpp"
#include "topopt/materials.hpp"
#include "topopt/observability.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/production.hpp"
#include "topopt/settings.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

using namespace topopt;

namespace {

constexpr double kRhoMin = 1e-3;
constexpr double kActiveThresh = 1.5 * kRhoMin;  // "rho above ~1.5x rho_min"
const int kBandK[] = {0, 2, 4, 8};

// ---------------------------------------------------------------------------
// Mask mechanics — pure function of (grid, density, k). Fixed traversal order.
// ---------------------------------------------------------------------------

// Separable Chebyshev dilation of a 0/1 mask by k voxels (3 axis passes, each a
// window max). Deterministic: no floating point, fixed x->y->z order.
void dilate_cheb(const VoxelGrid& g, std::vector<char>& m, int k) {
  if (k <= 0) return;
  const int nx = g.nx, ny = g.ny, nz = g.nz;
  std::vector<char> t(m.size(), 0);
  // x
  for (int z = 0; z < nz; ++z)
    for (int y = 0; y < ny; ++y)
      for (int x = 0; x < nx; ++x) {
        char v = 0;
        const int lo = x - k < 0 ? 0 : x - k, hi = x + k >= nx ? nx - 1 : x + k;
        for (int a = lo; a <= hi && !v; ++a) v = m[g.index(a, y, z)];
        t[g.index(x, y, z)] = v;
      }
  // y
  for (int z = 0; z < nz; ++z)
    for (int y = 0; y < ny; ++y)
      for (int x = 0; x < nx; ++x) {
        char v = 0;
        const int lo = y - k < 0 ? 0 : y - k, hi = y + k >= ny ? ny - 1 : y + k;
        for (int b = lo; b <= hi && !v; ++b) v = t[g.index(x, b, z)];
        m[g.index(x, y, z)] = v;
      }
  // z
  for (int z = 0; z < nz; ++z)
    for (int y = 0; y < ny; ++y)
      for (int x = 0; x < nx; ++x) {
        char v = 0;
        const int lo = z - k < 0 ? 0 : z - k, hi = z + k >= nz ? nz - 1 : z + k;
        for (int c = lo; c <= hi && !v; ++c) v = m[g.index(x, y, c)];
        t[g.index(x, y, z)] = v;
      }
  m.swap(t);
}

// The band mask. `rho` is grid-indexed physical density.
std::vector<char> band_mask(const VoxelGrid& g, const std::vector<double>& rho,
                            int k, double thresh = kActiveThresh) {
  std::vector<char> m(g.voxel_count(), 0);
  for (int z = 0; z < g.nz; ++z)
    for (int y = 0; y < g.ny; ++y)
      for (int x = 0; x < g.nx; ++x) {
        const std::size_t e = g.index(x, y, z);
        if (g.tags[e] == VoxelTag::Empty) continue;
        if (rho[e] > thresh) m[e] = 1;
      }
  dilate_cheb(g, m, k);
  // Never leave the analysis domain; always keep load/fixture-carrying voxels
  // (a BC/load must retain stiffness or the M3.1 void-load gate rejects).
  for (std::size_t e = 0; e < g.voxel_count(); ++e) {
    if (g.tags[e] == VoxelTag::Empty) { m[e] = 0; continue; }
    if (g.tags[e] == VoxelTag::Load || g.tags[e] == VoxelTag::Fixture) m[e] = 1;
  }
  return m;
}

struct BandStats {
  long long domain_elems = 0, band_elems = 0;
  long long domain_nodes = 0, band_nodes = 0;
};

BandStats band_stats(const VoxelGrid& g, const std::vector<char>& m) {
  BandStats s;
  std::vector<char> dn(static_cast<std::size_t>(fea_node_count(g)), 0);
  std::vector<char> bn(dn.size(), 0);
  for (int z = 0; z < g.nz; ++z)
    for (int y = 0; y < g.ny; ++y)
      for (int x = 0; x < g.nx; ++x) {
        const std::size_t e = g.index(x, y, z);
        if (g.tags[e] == VoxelTag::Empty) continue;
        ++s.domain_elems;
        const bool in = m[e] != 0;
        if (in) ++s.band_elems;
        const std::array<int, 8> nodes = fea_element_nodes(g, x, y, z);
        for (int n : nodes) {
          dn[static_cast<std::size_t>(n)] = 1;
          if (in) bn[static_cast<std::size_t>(n)] = 1;
        }
      }
  for (std::size_t i = 0; i < dn.size(); ++i) {
    if (dn[i]) ++s.domain_nodes;
    if (bn[i]) ++s.band_nodes;
  }
  return s;
}

// The restricted analysis grid: out-of-band voxels become Empty, so the existing
// void-DOF gate eliminates their DOFs exactly (traction-free band boundary).
VoxelGrid restrict_grid(const VoxelGrid& g, const std::vector<char>& m) {
  VoxelGrid r = g;
  for (std::size_t e = 0; e < r.voxel_count(); ++e)
    if (!m[e]) r.tags[e] = VoxelTag::Empty;
  return r;
}

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

Material fdm_material() {
  Material m;
  m.youngs_modulus_mpa = 3500.0;
  m.yield_strength_mpa = 55.0;
  m.density_g_cm3 = 1.24;
  m.z_knockdown = 0.55;
  m.poisson = 0.33;
  m.family = "fdm";
  return m;
}

// The thin L-bracket the 080/082/ladder gates build (same shape as
// cg_tol_probe.cpp's fixture, parameterised so it can be scaled up out of the
// degenerate 8x3x8 regime handoff 130 flagged).
VoxelGrid l_bracket(std::vector<DirichletBC>& bcs, int arm, int span, int ny,
                    int t, double h) {
  VoxelGrid g;
  g.nx = span; g.ny = ny; g.nz = arm; g.spacing = h;
  g.origin = Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(span) * ny * arm, VoxelTag::Empty);
  for (int k = 0; k < arm; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < span; ++i)
        if (i < t || k < t) g.set_tag(i, j, k, VoxelTag::Interior);
  auto solid = [&](int i, int j, int k) {
    if (i < 0 || j < 0 || k < 0 || i >= span || j >= ny || k >= arm) return false;
    return g.tag(i, j, k) != VoxelTag::Empty;
  };
  for (int k = 0; k < arm; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < span; ++i) {
        if (!solid(i, j, k)) continue;
        if (!solid(i-1,j,k)||!solid(i+1,j,k)||!solid(i,j-1,k)||!solid(i,j+1,k)||
            !solid(i,j,k-1)||!solid(i,j,k+1))
          g.set_tag(i, j, k, VoxelTag::Surface);
      }
  for (int j = 0; j < ny; ++j)
    for (int i = 0; i < t; ++i) g.set_tag(i, j, arm - 1, VoxelTag::Fixture);
  bcs.clear();
  for (int b = 0; b <= ny; ++b)
    for (int a = 0; a <= t; ++a) {
      const int node = fea_node_index(g, a, b, arm);
      bcs.push_back({node, 0, 0.0});
      bcs.push_back({node, 1, 0.0});
      bcs.push_back({node, 2, 0.0});
    }
  for (int k = 0; k < t; ++k)
    for (int j = 0; j < ny; ++j) g.set_tag(span - 1, j, k, VoxelTag::Load);
  return g;
}

// A DILUTE design-box analysis grid built DIRECTLY (no driver expansion), so the
// harness owns the load/BC node ids exactly: a box of `bx x by x bz` voxels, all
// design voxels (Interior), with an L-bracket-shaped SOLID part placed at the
// origin corner and tagged Fixture (mount) / Load (tip). `fill` prints as the
// part-volume : box-volume ratio — the production complaint (10-60x) lives here.
struct DiluteBox {
  VoxelGrid grid;
  std::vector<DirichletBC> bcs;
  std::vector<NodalLoad> loads;
  long long part_voxels = 0;
};

DiluteBox dilute_box(int bx, int by, int bz, int arm, int span, int ny, int t,
                     double h, double tip_force) {
  DiluteBox d;
  VoxelGrid& g = d.grid;
  g.nx = bx; g.ny = by; g.nz = bz; g.spacing = h;
  g.origin = Vec3{0.0, 0.0, 0.0};
  // EVERY box voxel is an analysis element (the design box is the domain) —
  // exactly the production shape: the FEA runs on the whole box every iteration.
  g.tags.assign(static_cast<std::size_t>(bx) * by * bz, VoxelTag::Interior);
  for (int k = 0; k < arm && k < bz; ++k)
    for (int j = 0; j < ny && j < by; ++j)
      for (int i = 0; i < span && i < bx; ++i)
        if (i < t || k < t) { g.set_tag(i, j, k, VoxelTag::Surface); ++d.part_voxels; }
  // Mount: the top of the vertical arm, clamped.
  for (int j = 0; j < ny && j < by; ++j)
    for (int i = 0; i < t && i < bx; ++i) g.set_tag(i, j, arm - 1, VoxelTag::Fixture);
  for (int b = 0; b <= ny && b <= by; ++b)
    for (int a = 0; a <= t && a <= bx; ++a) {
      const int node = fea_node_index(g, a, b, arm);
      d.bcs.push_back({node, 0, 0.0});
      d.bcs.push_back({node, 1, 0.0});
      d.bcs.push_back({node, 2, 0.0});
    }
  // Tip load face.
  for (int k = 0; k < t && k < bz; ++k)
    for (int j = 0; j < ny && j < by; ++j) g.set_tag(span - 1, j, k, VoxelTag::Load);
  d.loads = traction_loads(g, VoxelTag::Load, Vec3{0.0, 0.0, -tip_force});
  return d;
}

// ---------------------------------------------------------------------------
// [1] CEILING — production-shaped trajectories through the REAL driver
// ---------------------------------------------------------------------------

FILE* g_ceiling_csv = nullptr;

void ceiling_row(const char* fixture, std::size_t rung, int iter, bool boundary,
                 const VoxelGrid& g, const std::vector<double>& rho) {
  BandStats s[4];
  for (int a = 0; a < 4; ++a) s[a] = band_stats(g, band_mask(g, rho, kBandK[a]));
  if (!g_ceiling_csv) return;
  std::fprintf(g_ceiling_csv,
               "%s,%zu,%d,%d,%lld,%lld,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f\n",
               fixture, rung, iter, boundary ? 1 : 0, s[0].domain_elems,
               s[0].domain_nodes,
               double(s[0].band_elems) / double(s[0].domain_elems),
               double(s[1].band_elems) / double(s[0].domain_elems),
               double(s[2].band_elems) / double(s[0].domain_elems),
               double(s[3].band_elems) / double(s[0].domain_elems),
               double(s[0].band_nodes) / double(s[0].domain_nodes),
               double(s[1].band_nodes) / double(s[0].domain_nodes),
               double(s[2].band_nodes) / double(s[0].domain_nodes),
               double(s[3].band_nodes) / double(s[0].domain_nodes));
  std::fflush(g_ceiling_csv);
}

// Run one production ladder and stream the ceiling rows. `iter_cap` bounds each
// rung so a large dilute box finishes inside a probe budget (stated honestly).
void ceiling_fixture(const char* label, const VoxelGrid& part,
                     const std::vector<DirichletBC>& bcs,
                     const std::vector<NodalLoad>& loads,
                     const SettingsRules& rules, const Material& material,
                     bool with_box, const DesignBox& box, int iter_cap) {
  MinimizePlasticOptions o;
  configure_production_options(o);
  o.volume_fraction_ladder = production_reduction_ladder();
  o.margin_stop = 1.5;
  o.external_loads = loads;
  o.gravity = 9810.0 * 1e-9;
  o.gravity_direction = Vec3{0.0, 0.0, -1.0};
  o.infill_percent = 100.0;
  if (with_box) o.design_box = box;
  if (iter_cap > 0) o.simp.max_iterations = iter_cap;

  const VoxelGrid solved = minimize_plastic_solved_grid(part, o);
  std::printf("\n===== [CEILING] %s =====\n", label);
  std::printf("  part %dx%dx%d (%zu solid) -> analysis grid %dx%dx%d (%zu elements)"
              "  fill=%.2f%%  dilution=%.1fx  iter_cap=%d  updater=%s\n",
              part.nx, part.ny, part.nz, part.solid_count(), solved.nx, solved.ny,
              solved.nz, solved.solid_count(),
              100.0 * double(part.solid_count()) / double(solved.solid_count()),
              double(solved.solid_count()) / double(part.solid_count()), iter_cap,
              o.updater == SimpUpdater::MMA ? "MMA" : "OC");

  int rows = 0;
  o.on_density_snapshot = [&](const DensitySnapshotEvent& ev) {
    if (!ev.density || !ev.grid) return;
    ceiling_row(label, ev.rung_index, ev.iteration, ev.boundary, *ev.grid,
                *ev.density);
    ++rows;
  };
  const auto t0 = std::chrono::steady_clock::now();
  const MinimizePlasticResult r =
      minimize_plastic(part, material, "fdm", bcs, rules, o);
  const double wall =
      std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
  std::printf("  ladder: %zu rungs evaluated, %.1f s wall, %d ceiling rows\n",
              r.evaluated.size(), wall, rows);
  for (std::size_t i = 0; i < r.evaluated.size(); ++i) {
    const auto& v = r.evaluated[i];
    // Terminal-design active fractions, the row that matters most.
    const VoxelGrid& G = r.solved_grid;
    std::vector<BandStats> s;
    for (int a = 0; a < 4; ++a)
      s.push_back(band_stats(G, band_mask(G, v.optimization.physical_density,
                                          kBandK[a])));
    std::printf("    rung %zu vf=%.2f iters=%3d %s | terminal active%% "
                "k=0 %.2f  k=2 %.2f  k=4 %.2f  k=8 %.2f  (nodes k=4 %.2f)\n",
                i, v.requested_volume_fraction, v.optimization.iterations,
                v.accepted ? "accept" : "REJECT",
                100.0 * double(s[0].band_elems) / double(s[0].domain_elems),
                100.0 * double(s[1].band_elems) / double(s[0].domain_elems),
                100.0 * double(s[2].band_elems) / double(s[0].domain_elems),
                100.0 * double(s[3].band_elems) / double(s[0].domain_elems),
                100.0 * double(s[2].band_nodes) / double(s[0].domain_nodes));
  }
}

// ---------------------------------------------------------------------------
// [2]+[3]+[4] CORRECTNESS / MECHANICS / ARITHMETIC
// ---------------------------------------------------------------------------

double mean_abs(const std::vector<double>& a, const std::vector<double>& b) {
  double s = 0.0;
  for (std::size_t i = 0; i < a.size(); ++i) s += std::fabs(a[i] - b[i]);
  return a.empty() ? 0.0 : s / double(a.size());
}
double max_abs(const std::vector<double>& a, const std::vector<double>& b) {
  double m = 0.0;
  for (std::size_t i = 0; i < a.size(); ++i) m = std::max(m, std::fabs(a[i] - b[i]));
  return m;
}

struct SolveTiming {
  double wall = 0.0;
  int cg_iters = 0;
  bool used_mg = false;
  long long elems = 0, nodes = 0;
  double compliance = 0.0;
};

SolveTiming timed_solve(const VoxelGrid& g, const SimpParams& params,
                        const std::vector<double>& rho,
                        const std::vector<DirichletBC>& bcs,
                        const std::vector<NodalLoad>& loads, double tol,
                        SolverKind kind, SimpCompliance& out) {
  const auto t0 = std::chrono::steady_clock::now();
  out = simp_compliance(g, params, rho, bcs, loads, tol, 0, nullptr, nullptr, kind);
  SolveTiming t;
  t.wall = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
  t.cg_iters = out.cg.iterations;
  t.used_mg = out.cg.used_multigrid;
  t.compliance = out.compliance;
  t.elems = static_cast<long long>(g.solid_count());
  const BandStats bs = band_stats(g, std::vector<char>(g.voxel_count(), 1));
  t.nodes = bs.domain_nodes;
  return t;
}

FILE* g_traj_csv = nullptr;

// The core experiment. Runs TWO harness OC loops side by side from the identical
// start with the identical filter / updater / move / volume target; the ONLY
// difference is which grid the FEA solve sees (full domain vs band-restricted).
// Reports per iteration: compliance delta, sensitivity delta on the band, the
// resulting |drho| between the two designs, the active fraction, and the GROWTH
// INVARIANT probe (how much density the FULL solve wants OUTSIDE the band).
void trajectory(const char* label, const DiluteBox& d, const Material& material,
                double rung_vf, int iters, int band_k, int cadence, double cg_tol,
                SolverKind kind) {
  const VoxelGrid& g = d.grid;
  SimpParams params;
  params.youngs_modulus = material.youngs_modulus_mpa;
  params.poisson = material.poisson;
  params.penalty = 3.0;
  params.density_min = kRhoMin;

  // PART-RELATIVE rung target, exactly as minimize_plastic derives it on a
  // design-box run (handoff 080's effective_vf): rung `vf` means "keep vf of the
  // PART's worth of material", so on a dilute box the domain-relative target is
  // vf * part_voxels / domain_voxels. Using the raw rung value here would ask the
  // optimizer to fill 26-68% of an empty box — not the production shape.
  const double vf = std::max(kRhoMin, rung_vf * double(d.part_voxels) /
                                          double(g.solid_count()));
  // Production min-feature filter radius (2.5 mm physical, handoff 060), not the
  // bare 1.5-voxel floor — the gray halo it creates is part of the active set.
  const double rmin = physical_filter_radius(2.5, g.spacing);
  const DensityFilter filter = make_density_filter(g, rmin);

  std::vector<double> x_full = simp_uniform_density(g, vf);
  std::vector<double> x_rest = x_full;

  std::printf("\n----- [TRAJECTORY] %s  rung_vf=%.2f -> domain vf=%.4f  rmin=%.2f "
              "k=%d cadence=%d tol=%.0e iters=%d -----\n",
              label, rung_vf, vf, rmin, band_k, cadence, cg_tol, iters);
  std::printf("  it | active%% | C_full         C_rest       dC/C     "
              "| max|dSens|/|Sens| (band) | mean|drho|  max|drho| | outside-band want "
              "| band escapes\n");

  std::vector<char> band;
  double worst_dc = 0.0, worst_mean_drho = 0.0, worst_max_drho = 0.0;
  double worst_dsens = 0.0, worst_outside = 0.0, worst_max_escape = 0.0;
  long long worst_escapes = 0;

  for (int it = 1; it <= iters; ++it) {
    const std::vector<double> xp_full = filter.filter_density(x_full);
    const std::vector<double> xp_rest = filter.filter_density(x_rest);

    SimpCompliance cf, cr;
    cf = simp_compliance(g, params, xp_full, d.bcs, d.loads, cg_tol, 0, nullptr,
                         nullptr, kind);

    if (band.empty() || ((it - 1) % cadence) == 0)
      band = band_mask(g, xp_rest, band_k);
    const VoxelGrid rg = restrict_grid(g, band);
    cr = simp_compliance(rg, params, xp_rest, d.bcs, d.loads, cg_tol, 0, nullptr,
                         nullptr, kind);

    const BandStats bs = band_stats(g, band);
    const double active = double(bs.band_elems) / double(bs.domain_elems);

    // Sensitivity agreement ON THE BAND, measured against the full-domain solve
    // of the SAME field (xp_rest) — this isolates the solve substitution from
    // trajectory drift.
    SimpCompliance cf_same =
        simp_compliance(g, params, xp_rest, d.bcs, d.loads, cg_tol, 0, nullptr,
                        nullptr, kind);
    double num = 0.0, den = 0.0, outside = 0.0;
    for (std::size_t e = 0; e < g.voxel_count(); ++e) {
      if (g.tags[e] == VoxelTag::Empty) continue;
      if (band[e]) {
        num = std::max(num, std::fabs(cr.dcompliance[e] - cf_same.dcompliance[e]));
        den = std::max(den, std::fabs(cf_same.dcompliance[e]));
      } else {
        // Growth invariant probe: the magnitude the FULL solve assigns OUTSIDE
        // the band, relative to the largest in-band magnitude.
        outside = std::max(outside, std::fabs(cf_same.dcompliance[e]));
      }
    }
    const double dsens = den > 0.0 ? num / den : 0.0;
    const double outside_rel = den > 0.0 ? outside / den : 0.0;
    const double dc = std::fabs(cf_same.compliance) > 0.0
                          ? std::fabs(cr.compliance - cf_same.compliance) /
                                std::fabs(cf_same.compliance)
                          : 0.0;

    // GROWTH INVARIANT, measured directly on the FULL-domain trajectory: derive
    // the band from THIS iteration's field, take the full-domain step, and count
    // how many voxels the step pushes above the active threshold OUTSIDE that
    // band. Zero == the k-voxel margin anticipated everything the optimizer
    // wanted; non-zero == the band would have had to grow first.
    const std::vector<char> band_full = band_mask(g, xp_full, band_k);
    const std::vector<double> x_full_next =
        oc_update(g, filter, x_full, cf.dcompliance, vf, 0.2, kRhoMin);
    const std::vector<double> xp_full_next = filter.filter_density(x_full_next);
    long long escapes = 0;
    double max_escape = 0.0;
    for (std::size_t e = 0; e < g.voxel_count(); ++e) {
      if (g.tags[e] == VoxelTag::Empty || band_full[e]) continue;
      if (xp_full_next[e] > kActiveThresh) ++escapes;
      max_escape = std::max(max_escape, xp_full_next[e]);
    }

    x_full = x_full_next;
    x_rest = oc_update(g, filter, x_rest, cr.dcompliance, vf, 0.2, kRhoMin);

    const double mean_d = mean_abs(x_full, x_rest);
    const double max_d = max_abs(x_full, x_rest);
    worst_dc = std::max(worst_dc, dc);
    worst_mean_drho = std::max(worst_mean_drho, mean_d);
    worst_max_drho = std::max(worst_max_drho, max_d);
    worst_dsens = std::max(worst_dsens, dsens);
    worst_outside = std::max(worst_outside, outside_rel);

    worst_escapes = std::max(worst_escapes, escapes);
    worst_max_escape = std::max(worst_max_escape, max_escape);

    std::printf("  %2d | %6.2f%% | %-14.8g %-12.8g %8.2e | %8.2e            "
                "  | %10.3e %9.3e | %8.2e | %6lld (max rho %.4f)\n",
                it, 100.0 * active, cf.compliance, cr.compliance, dc, dsens,
                mean_d, max_d, outside_rel, escapes, max_escape);
    if (g_traj_csv)
      std::fprintf(g_traj_csv,
                   "%s,%d,%d,%d,%.6f,%.10g,%.10g,%.6e,%.6e,%.6e,%.6e,%.6e,%lld,%.6f\n",
                   label, band_k, cadence, it, active, cf.compliance,
                   cr.compliance, dc, dsens, mean_d, max_d, outside_rel, escapes,
                   max_escape);
  }
  std::printf("  WORST over %d iters: dC/C=%.2e  max|dSens|/|Sens|=%.2e  "
              "mean|drho|=%.3e  max|drho|=%.3e  outside-band want=%.2e  "
              "band escapes=%lld (max escaping rho %.4f)\n",
              iters, worst_dc, worst_dsens, worst_mean_drho, worst_max_drho,
              worst_outside, worst_escapes, worst_max_escape);
  if (g_traj_csv) std::fflush(g_traj_csv);
}

// [3] determinism: the mask is a pure function of the field — re-deriving it
// twice (and from a bit-identical copy) must give bit-identical masks.
void mask_determinism(const DiluteBox& d) {
  const VoxelGrid& g = d.grid;
  const DensityFilter f = make_density_filter(g, 1.5);
  std::vector<double> x = simp_uniform_density(g, 0.5);
  for (std::size_t e = 0; e < x.size(); ++e)
    if (g.tags[e] != VoxelTag::Empty)
      x[e] = 0.5 * (1.0 + std::sin(double(e) * 0.0137));  // deterministic texture
  const std::vector<double> xp = f.filter_density(x);
  bool ok = true;
  for (int k : {0, 2, 4, 8}) {
    const std::vector<char> a = band_mask(g, xp, k);
    const std::vector<char> b = band_mask(g, xp, k);
    std::vector<double> xp2 = xp;
    const std::vector<char> c = band_mask(g, xp2, k);
    if (a != b || a != c) ok = false;
  }
  std::printf("\n[MECHANICS] mask determinism (pure function, fixed traversal): %s\n",
              ok ? "PASS (bit-identical across re-derivations)" : "FAIL");
}

// [4] arithmetic: full vs restricted solve cost on the SAME field.
void arithmetic(const char* label, const DiluteBox& d, const Material& material,
                const std::vector<double>& rho, int band_k, double cg_tol,
                SolverKind kind) {
  const VoxelGrid& g = d.grid;
  SimpParams params;
  params.youngs_modulus = material.youngs_modulus_mpa;
  params.poisson = material.poisson;
  params.penalty = 3.0;
  params.density_min = kRhoMin;

  const std::vector<char> band = band_mask(g, rho, band_k);
  const VoxelGrid rg = restrict_grid(g, band);

  SimpCompliance cf, cr;
  // Interleave 3 repeats to blunt thermal drift (113 protocol); report the median.
  std::vector<double> wf, wr;
  SolveTiming tf, tr;
  for (int rep = 0; rep < 3; ++rep) {
    tf = timed_solve(g, params, rho, d.bcs, d.loads, cg_tol, kind, cf);
    wf.push_back(tf.wall);
    tr = timed_solve(rg, params, rho, d.bcs, d.loads, cg_tol, kind, cr);
    wr.push_back(tr.wall);
  }
  std::sort(wf.begin(), wf.end());
  std::sort(wr.begin(), wr.end());
  const double mf = wf[1], mr = wr[1];
  // Peak solver storage is dominated by the reduced free-DOF vectors: the CG
  // state (x, r, p, z, plus the operator's two full-length scratch buffers).
  const double bytes_full = 8.0 * (5.0 * 3.0 * double(tf.nodes) + 2.0 * 3.0 * double(tf.nodes));
  const double bytes_rest = 8.0 * (5.0 * 3.0 * double(tr.nodes) + 2.0 * 3.0 * double(tr.nodes));
  std::printf("\n[ARITHMETIC] %s  k=%d  tol=%.0e\n", label, band_k, cg_tol);
  std::printf("  full      : elems=%8lld nodes=%8lld  cg=%5d mg=%d  C=%-14.8g wall=%.4fs\n",
              tf.elems, tf.nodes, tf.cg_iters, tf.used_mg ? 1 : 0, tf.compliance, mf);
  std::printf("  restricted: elems=%8lld nodes=%8lld  cg=%5d mg=%d  C=%-14.8g wall=%.4fs\n",
              tr.elems, tr.nodes, tr.cg_iters, tr.used_mg ? 1 : 0, tr.compliance, mr);
  std::printf("  ratios    : elems=%.3f  nodes=%.3f  cg_iters=%.3f  WALL=%.2fx  "
              "solver-vector bytes %.1f MB -> %.1f MB (%.2fx)\n",
              double(tr.elems) / double(tf.elems),
              double(tr.nodes) / double(tf.nodes),
              tf.cg_iters ? double(tr.cg_iters) / double(tf.cg_iters) : 0.0,
              mr > 0.0 ? mf / mr : 0.0, bytes_full / 1048576.0,
              bytes_rest / 1048576.0, bytes_full / bytes_rest);
  std::printf("  per-element cost: full %.3f us/elem/solve, restricted %.3f us/elem/solve\n",
              1e6 * mf / double(tf.elems), 1e6 * mr / double(tr.elems));
  std::printf("  compliance delta (restricted vs full, same field): %.3e relative\n",
              std::fabs(cf.compliance) > 0
                  ? std::fabs(cr.compliance - cf.compliance) / std::fabs(cf.compliance)
                  : 0.0);
}

// ---------------------------------------------------------------------------
// Snapshot scanner — the 117 capture path (CLI --snapshots) turned into a
// ceiling table for a REAL production job.
// ---------------------------------------------------------------------------

// Minimal sidecar reader: pull an integer/array field out of the tiny JSON the
// 117 writer emits (hand-rolled to match its hand-rolled writer).
bool json_int_array3(const std::string& s, const char* key, int out[3]) {
  const std::size_t p = s.find(std::string("\"") + key + "\"");
  if (p == std::string::npos) return false;
  const std::size_t b = s.find('[', p);
  if (b == std::string::npos) return false;
  return std::sscanf(s.c_str() + b, "[%d,%d,%d]", &out[0], &out[1], &out[2]) == 3 ||
         std::sscanf(s.c_str() + b, "[ %d, %d, %d ]", &out[0], &out[1], &out[2]) == 3;
}
long json_int(const std::string& s, const char* key, long dflt) {
  const std::size_t p = s.find(std::string("\"") + key + "\"");
  if (p == std::string::npos) return dflt;
  const std::size_t c = s.find(':', p);
  if (c == std::string::npos) return dflt;
  return std::strtol(s.c_str() + c + 1, nullptr, 10);
}
std::string slurp(const std::string& path) {
  FILE* f = std::fopen(path.c_str(), "rb");
  if (!f) return {};
  std::string out;
  char buf[4096];
  std::size_t n;
  while ((n = std::fread(buf, 1, sizeof buf, f)) > 0) out.append(buf, n);
  std::fclose(f);
  return out;
}

FILE* g_thresh_csv = nullptr;

int scan_snapshots(const std::string& dir, bool sweep_thresholds) {
  DIR* dp = opendir(dir.c_str());
  if (!dp) { std::fprintf(stderr, "cannot open %s\n", dir.c_str()); return 1; }
  std::vector<std::string> bases;
  for (dirent* e; (e = readdir(dp));) {
    const std::string n = e->d_name;
    if (n.size() > 5 && n.compare(n.size() - 5, 5, ".json") == 0)
      bases.push_back(n.substr(0, n.size() - 5));
  }
  closedir(dp);
  std::sort(bases.begin(), bases.end());
  std::printf("\n===== [CEILING] CLI SNAPSHOT CAPTURE  %s  (%zu snapshots) =====\n",
              dir.c_str(), bases.size());
  std::printf("  rung  iter  bnd |   elements | active%% k=0   k=2    k=4    k=8 | "
              "nodes%% k=4\n");
  for (const std::string& b : bases) {
    const std::string js = slurp(dir + "/" + b + ".json");
    if (js.empty()) continue;
    int dims[3] = {0, 0, 0};
    if (!json_int_array3(js, "dims", dims)) continue;
    const long voxels = json_int(js, "voxels", 0);
    const long rung = json_int(js, "rung", -1);
    const long iter = json_int(js, "iter", -1);
    const bool bnd = js.find("\"boundary\": true") != std::string::npos ||
                     js.find("\"boundary\":true") != std::string::npos;
    VoxelGrid g;
    g.nx = dims[0]; g.ny = dims[1]; g.nz = dims[2];
    g.spacing = 1.0;
    g.tags.assign(static_cast<std::size_t>(voxels), VoxelTag::Interior);
    const std::vector<float> rf =
        read_density_f16(dir + "/" + b + ".f16", static_cast<std::size_t>(voxels));
    if (rf.size() != static_cast<std::size_t>(voxels)) continue;
    std::vector<double> rho(rf.begin(), rf.end());
    // The snapshot covers the whole solved grid; voxels the driver never made
    // design variables read exactly 0 and are treated as OUTSIDE the domain.
    for (std::size_t e = 0; e < rho.size(); ++e)
      if (rho[e] <= 0.0) g.tags[e] = VoxelTag::Empty;
    BandStats s[4];
    for (int a = 0; a < 4; ++a) s[a] = band_stats(g, band_mask(g, rho, kBandK[a]));
    if (sweep_thresholds && g_thresh_csv) {
      // Threshold sensitivity — the ceiling as a function of what counts as
      // "material". 1.5*rho_min is the task's stated rule; the higher entries
      // show how much of the ceiling is MMA's gray fringe rather than structure.
      for (double th : {kActiveThresh, 0.01, 0.05, 0.1, 0.3, 0.5})
        for (int k : {0, 2, 4, 8}) {
          const BandStats t = band_stats(g, band_mask(g, rho, k, th));
          std::fprintf(g_thresh_csv, "%ld,%ld,%d,%.4g,%d,%lld,%.6f,%.6f\n", rung,
                       iter, bnd ? 1 : 0, th, k, t.domain_elems,
                       double(t.band_elems) / double(t.domain_elems),
                       double(t.band_nodes) / double(t.domain_nodes));
        }
    }
    std::printf("  %4ld %5ld  %3d | %10lld | %6.2f %6.2f %6.2f %6.2f | %6.2f\n",
                rung, iter, bnd ? 1 : 0, s[0].domain_elems,
                100.0 * double(s[0].band_elems) / double(s[0].domain_elems),
                100.0 * double(s[1].band_elems) / double(s[0].domain_elems),
                100.0 * double(s[2].band_elems) / double(s[0].domain_elems),
                100.0 * double(s[3].band_elems) / double(s[0].domain_elems),
                100.0 * double(s[2].band_nodes) / double(s[0].domain_nodes));
    if (g_ceiling_csv)
      std::fprintf(g_ceiling_csv,
                   "cli_snapshot,%ld,%ld,%d,%lld,%lld,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f\n",
                   rung, iter, bnd ? 1 : 0, s[0].domain_elems, s[0].domain_nodes,
                   double(s[0].band_elems) / double(s[0].domain_elems),
                   double(s[1].band_elems) / double(s[0].domain_elems),
                   double(s[2].band_elems) / double(s[0].domain_elems),
                   double(s[3].band_elems) / double(s[0].domain_elems),
                   double(s[0].band_nodes) / double(s[0].domain_nodes),
                   double(s[1].band_nodes) / double(s[0].domain_nodes),
                   double(s[2].band_nodes) / double(s[0].domain_nodes),
                   double(s[3].band_nodes) / double(s[0].domain_nodes));
  }
  return 0;
}

void open_csvs() {
  const char* dir = std::getenv("TOPOPT_AD_CSV_DIR");
  if (!dir) return;
  g_ceiling_csv = std::fopen((std::string(dir) + "/ceiling.csv").c_str(), "a");
  if (g_ceiling_csv) {
    std::fseek(g_ceiling_csv, 0, SEEK_END);
    if (std::ftell(g_ceiling_csv) == 0)
      std::fprintf(g_ceiling_csv,
                   "fixture,rung,iter,boundary,domain_elems,domain_nodes,"
                   "elem_frac_k0,elem_frac_k2,elem_frac_k4,elem_frac_k8,"
                   "node_frac_k0,node_frac_k2,node_frac_k4,node_frac_k8\n");
  }
  g_traj_csv = std::fopen((std::string(dir) + "/trajectory.csv").c_str(), "a");
  if (g_traj_csv) {
    std::fseek(g_traj_csv, 0, SEEK_END);
    if (std::ftell(g_traj_csv) == 0)
      std::fprintf(g_traj_csv,
                   "fixture,band_k,cadence,iter,active_frac,C_full,C_restricted,"
                   "dC_rel,dSens_rel,mean_drho,max_drho,outside_band_rel,"
                   "band_escapes,max_escaping_rho\n");
  }
}

}  // namespace

int main(int argc, char** argv) {
  // Line-buffer stdout: these runs are hours long and are routinely redirected to
  // a file, so a block-buffered stream loses the whole human table if the probe is
  // cut short by its budget (it was, once — the CSVs survived because they flush
  // per row; make stdout behave the same way).
  std::setvbuf(stdout, nullptr, _IOLBF, 0);
  const std::string mode = argc > 1 ? argv[1] : "all";
  open_csvs();

  if (mode == "snapshots") {
    if (argc < 3) { std::fprintf(stderr, "usage: %s snapshots <dir>\n", argv[0]); return 2; }
    const char* cdir = std::getenv("TOPOPT_AD_CSV_DIR");
    if (cdir) {
      g_thresh_csv = std::fopen((std::string(cdir) + "/threshold_sweep.csv").c_str(), "w");
      if (g_thresh_csv)
        std::fprintf(g_thresh_csv,
                     "rung,iter,boundary,threshold,band_k,domain_elems,elem_frac,node_frac\n");
    }
    const int rc = scan_snapshots(argv[2], g_thresh_csv != nullptr);
    if (g_thresh_csv) std::fclose(g_thresh_csv);
    if (g_ceiling_csv) std::fclose(g_ceiling_csv);
    if (g_traj_csv) std::fclose(g_traj_csv);
    return rc;
  }

  SettingsRules rules;
  try {
    rules = load_settings_rules_file(SETTINGS_RULES_PATH);
  } catch (const std::exception& e) {
    std::fprintf(stderr, "FAIL: rules.json: %s\n", e.what());
    return 1;
  }
  const Material material = fdm_material();
  const DesignBox no_box{};

  if (mode == "all" || mode == "ceiling") {
    // F1 — snug part domain (the NON-dilute control): the L-bracket alone.
    {
      std::vector<DirichletBC> bcs;
      VoxelGrid part = l_bracket(bcs, /*arm*/ 32, /*span*/ 32, /*ny*/ 10, /*t*/ 8, 1.0);
      const std::vector<NodalLoad> tip =
          traction_loads(part, VoxelTag::Load, Vec3{0.0, 0.0, -30.0});
      ceiling_fixture("F1_lbracket_snug", part, bcs, tip, rules, material, false,
                      no_box, 0);
    }
    // F2 — design box ~4.4x the part bbox, ~10x the part volume.
    {
      std::vector<DirichletBC> bcs;
      VoxelGrid part = l_bracket(bcs, 32, 32, 10, 8, 1.0);
      const std::vector<NodalLoad> tip =
          traction_loads(part, VoxelTag::Load, Vec3{0.0, 0.0, -30.0});
      DesignBox box;
      box.min = Vec3{-8.0, -5.0, -8.0};
      box.max = Vec3{40.0, 15.0, 40.0};
      ceiling_fixture("F2_designbox_10x", part, bcs, tip, rules, material, true,
                      box, 60);
    }
    // F3 — the production complaint: a design box ~50x the part volume.
    {
      std::vector<DirichletBC> bcs;
      VoxelGrid part = l_bracket(bcs, 24, 24, 6, 6, 1.0);
      const std::vector<NodalLoad> tip =
          traction_loads(part, VoxelTag::Load, Vec3{0.0, 0.0, -30.0});
      DesignBox box;
      box.min = Vec3{-20.0, -21.0, -20.0};
      box.max = Vec3{44.0, 43.0, 44.0};
      ceiling_fixture("F3_designbox_dilute", part, bcs, tip, rules, material, true,
                      box, 40);
    }
  }

  // An ULTRA-dilute box (~2 % part fill, the production complaint's shape) driven
  // by the same side-by-side OC comparison. This exists because BOTH real CLI
  // captures at 1.7 % fill were compromised (§1c): it is the converged
  // ultra-dilute data point, at the cost of being a harness fixture rather than a
  // driver run.
  if (mode == "ultradilute") {
    const DiluteBox d = dilute_box(/*bx*/ 48, /*by*/ 32, /*bz*/ 48,
                                   /*arm*/ 24, /*span*/ 24, /*ny*/ 6, /*t*/ 6,
                                   /*h*/ 1.0, /*tip*/ 30.0);
    std::printf("\n===== [ULTRA-DILUTE] box %dx%dx%d = %zu elements, part %lld "
                "voxels (%.2f%% fill, %.1fx dilution) =====\n",
                d.grid.nx, d.grid.ny, d.grid.nz, d.grid.solid_count(),
                d.part_voxels,
                100.0 * double(d.part_voxels) / double(d.grid.solid_count()),
                double(d.grid.solid_count()) / double(d.part_voxels));
    const SolverKind kind = SolverKind::MultigridCG_Matfree;
    for (int k : {2, 4, 8})
      trajectory("ultradilute_vf026", d, material, 0.26, 40, k, 1, 1e-10, kind);
    // Same arithmetic measurement, at production dilution.
    SimpParams params;
    params.youngs_modulus = material.youngs_modulus_mpa;
    params.poisson = material.poisson;
    params.penalty = 3.0;
    params.density_min = kRhoMin;
    const double vf = 0.26 * double(d.part_voxels) / double(d.grid.solid_count());
    const DensityFilter f =
        make_density_filter(d.grid, physical_filter_radius(2.5, d.grid.spacing));
    std::vector<double> x = simp_uniform_density(d.grid, vf);
    std::vector<double> xp;
    for (int it = 0; it < 40; ++it) {
      xp = f.filter_density(x);
      const SimpCompliance c = simp_compliance(d.grid, params, xp, d.bcs, d.loads,
                                               1e-8, 0, nullptr, nullptr, kind);
      x = oc_update(d.grid, f, x, c.dcompliance, vf, 0.2, kRhoMin);
    }
    xp = f.filter_density(x);
    for (int k : {2, 4, 8})
      arithmetic("ultradilute @ iter40 (rung vf 0.26)", d, material, xp, k, 1e-8, kind);
    if (g_ceiling_csv) std::fclose(g_ceiling_csv);
    if (g_traj_csv) std::fclose(g_traj_csv);
    return 0;
  }

  const bool want_traj = mode == "all" || mode == "correctness" || mode == "traj";
  const bool want_arith = mode == "all" || mode == "correctness" || mode == "arith";
  if (want_traj || want_arith) {
    // A dilute box the harness owns end to end (load/BC node ids exact).
    const DiluteBox d = dilute_box(/*bx*/ 40, /*by*/ 24, /*bz*/ 40,
                                   /*arm*/ 24, /*span*/ 24, /*ny*/ 6, /*t*/ 6,
                                   /*h*/ 1.0, /*tip*/ 30.0);
    std::printf("\n===== [CORRECTNESS] dilute box %dx%dx%d = %zu elements, "
                "part %lld voxels (%.2f%% fill, %.1fx dilution) =====\n",
                d.grid.nx, d.grid.ny, d.grid.nz, d.grid.solid_count(),
                d.part_voxels,
                100.0 * double(d.part_voxels) / double(d.grid.solid_count()),
                double(d.grid.solid_count()) / double(d.part_voxels));

    // Tight tolerance: the bar is "deltas at solver-tolerance level".
    const double tight = 1e-10;
    const SolverKind kind = SolverKind::MultigridCG_Matfree;

    if (want_traj) {
      mask_determinism(d);
      // Band sweep at the LIGHTEST production rung (0.26 — the one 125/128 report
      // breaks structurally, and the most dilute).
      for (int k : {2, 4, 8})
        trajectory("dilute40_vf026", d, material, 0.26, 40, k, /*cadence*/ 1, tight, kind);
      // Heaviest rung too, so the table is not a single-rung claim.
      trajectory("dilute40_vf068", d, material, 0.68, 40, 4, 1, tight, kind);
      // Cadence sweep at the mid band.
      for (int cad : {2, 5, 10})
        trajectory("dilute40_vf026", d, material, 0.26, 40, 4, cad, tight, kind);
    }

    // Arithmetic on a converged-shaped field: take the terminal design of a
    // short full-domain OC run and time both solves on it.
    if (want_arith) {
      SimpParams params;
      params.youngs_modulus = material.youngs_modulus_mpa;
      params.poisson = material.poisson;
      params.penalty = 3.0;
      params.density_min = kRhoMin;
      const double vf = 0.26 * double(d.part_voxels) / double(d.grid.solid_count());
      const DensityFilter f =
          make_density_filter(d.grid, physical_filter_radius(2.5, d.grid.spacing));
      std::vector<double> x = simp_uniform_density(d.grid, vf);
      std::vector<double> xp = f.filter_density(x);
      for (int it = 0; it < 40; ++it) {
        xp = f.filter_density(x);
        const SimpCompliance c = simp_compliance(d.grid, params, xp, d.bcs, d.loads,
                                                 1e-8, 0, nullptr, nullptr, kind);
        x = oc_update(d.grid, f, x, c.dcompliance, vf, 0.2, kRhoMin);
      }
      xp = f.filter_density(x);
      for (int k : {2, 4, 8})
        arithmetic("dilute40 @ iter40 (rung vf 0.26)", d, material, xp, k, 1e-8, kind);
    }
  }

  if (g_ceiling_csv) std::fclose(g_ceiling_csv);
  if (g_traj_csv) std::fclose(g_traj_csv);
  return 0;
}
