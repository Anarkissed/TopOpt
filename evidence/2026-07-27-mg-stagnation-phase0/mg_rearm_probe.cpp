// mg_rearm_probe.cpp — Phase-0 measurement for the multigrid stagnation LATCH
// re-arm question (task: "why multigrid never engages on a real job").
//
// NOT a CI test, NOT wired into CTest, NOT linked into any production path.
//
// THE QUESTION. The production run's `mg_mode="stagnated-latched"` means the
// per-run stagnation latch (multigrid.cpp, kMgLatchThreshold=3) fired inside
// RUNG 0 and disabled multigrid for the WHOLE run (all four rungs). The leading
// hypothesis is that iteration 3 of rung 0 — a near-uniform gray haze — is the
// WORST moment to judge multigrid, and that re-arming at each rung boundary
// would let the hierarchy CARRY once real structure exists.
//
// This harness tests that hypothesis's MECHANISM directly, on the EXACT
// production entry point `fea_solve_mgcg_matfree` (graded overload), by:
//   (1) SCAN — measuring geometric MG on the UNIFORM (iteration-0) field across
//       regimes and extents, to locate where stagnation begins (M1);
//   (2) LADDER — developing a REAL OC density field down the ladder
//       {0.68,0.52,0.38,0.26} with warm-start INHERITANCE (rung k+1 seeds from
//       rung k, exactly as production's warm_start_inherit), and measuring
//       geometric MG at the START of each rung (the field the latch would judge
//       if re-armed there) and the Jacobi fallback cost (M2/M3/M4/M5).
//
// TWO REGIMES, because the answer is geometry-dependent and prior work already
// split them:
//   * WITH-HOLE  — a clearance bore (VoxelTag::Empty) through a thin part in a
//     large empty box: handoff 125's super-additive stagnation regime.
//   * NO-HOLE    — the same thin part, no bore: the shape whose real developed
//     field the AMG Phase-1 handoff (§6) measured CARRYING geometric MG.
//
// B4 (task): this is NOT the maintainer's STEP part. It brackets the run's
// regime with the two families prior work measured; it does not reproduce the
// specific run. See the handoff's "what fixture would be needed" section.
//
// BUILD (library must be built Release first):
//   cmake -S core -B core/build -DCMAKE_BUILD_TYPE=Release
//   cmake --build core/build --target topopt -j8
//   c++ -std=c++17 -O2 -I core/include -I core/src/fea \
//       core/tests/harness/mg_rearm_probe.cpp core/build/libtopopt.a -o mg_rearm_probe
// RUN:  ./mg_rearm_probe scan            (fast: uniform-field geometric MG)
//       ./mg_rearm_probe ladder          (OC develop + per-rung MG, both regimes)

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

#include "topopt/fea.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

using namespace topopt;

namespace {

constexpr double kE0 = 3500.0;   // FDM PLA modulus (MPa)
constexpr double kNu = 0.33;
constexpr double kH = 1.0;       // voxel edge (mm)
constexpr int kSimpP = 3;
constexpr double kRhoMin = 1e-3;

double now_s() {
  using clock = std::chrono::steady_clock;
  return std::chrono::duration<double>(clock::now().time_since_epoch()).count();
}

struct System {
  VoxelGrid grid;
  std::vector<DirichletBC> bcs;
  std::vector<NodalLoad> loads;
  long long nsolid = 0, nbore = 0, nempty = 0;
  // Part (design-domain) footprint, so the develop step optimises only the part.
  int x0 = 0, x1 = 0, y0 = 0, y1 = 0;
};

// A centred thin rectangular part spanning the full box height, floating in an
// empty design-box expanse, optionally punched by a clearance bore (Empty).
// Mirrors amg_probe.cpp:build_system (handoff 131) so the geometry family is the
// documented 125 one; BC = fixed base, LOAD = transverse shear at the top
// (bending, the low-energy mode a coarse grid loses first).
System build_part_box(int ex, int ey, int ez, double occ, double hole,
                      int hole_axis = 2) {
  System S;
  VoxelGrid& g = S.grid;
  g.nx = ex; g.ny = ey; g.nz = ez;
  g.spacing = kH;
  g.origin = Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(ex) * ey * ez, VoxelTag::Empty);

  const int px = std::max(1, static_cast<int>(std::lround(occ * ex)));
  const int py = std::max(1, static_cast<int>(std::lround(occ * ey)));
  S.x0 = (ex - px) / 2; S.x1 = S.x0 + px;
  S.y0 = (ey - py) / 2; S.y1 = S.y0 + py;

  const double cx = 0.5 * ex, cy = 0.5 * ey, cz = 0.5 * ez;
  const double r = hole * 0.5 * std::min(ex, ey);
  const double r2 = r * r;

  for (int k = 0; k < ez; ++k)
    for (int j = 0; j < ey; ++j)
      for (int i = 0; i < ex; ++i) {
        const bool in_part = (i >= S.x0 && i < S.x1 && j >= S.y0 && j < S.y1);
        if (!in_part) { ++S.nempty; continue; }
        bool in_bore = false;
        if (r > 0.0) {
          const double vx = i + 0.5, vy = j + 0.5, vz = k + 0.5;
          double d2 = 0.0;
          if (hole_axis == 2) d2 = (vx-cx)*(vx-cx) + (vy-cy)*(vy-cy);
          else if (hole_axis == 1) d2 = (vx-cx)*(vx-cx) + (vz-cz)*(vz-cz);
          else d2 = (vy-cy)*(vy-cy) + (vz-cz)*(vz-cz);
          in_bore = (d2 <= r2);
        }
        if (in_bore) { ++S.nbore; continue; }
        g.set_tag(i, j, k, VoxelTag::Interior);
        ++S.nsolid;
      }

  const int nn = fea_node_count(g);
  std::vector<char> touched(static_cast<std::size_t>(nn), 0);
  for (int k = 0; k < ez; ++k)
    for (int j = 0; j < ey; ++j)
      for (int i = 0; i < ex; ++i) {
        if (g.tag(i, j, k) == VoxelTag::Empty) continue;
        const std::array<int, 8> en = fea_element_nodes(g, i, j, k);
        for (int e : en) touched[static_cast<std::size_t>(e)] = 1;
      }
  for (int b = S.y0; b <= S.y1; ++b)
    for (int a = S.x0; a <= S.x1; ++a) {
      const int nd = fea_node_index(g, a, b, 0);
      if (!touched[static_cast<std::size_t>(nd)]) continue;
      S.bcs.push_back({nd, 0, 0.0});
      S.bcs.push_back({nd, 1, 0.0});
      S.bcs.push_back({nd, 2, 0.0});
    }
  std::vector<int> top;
  for (int b = S.y0; b <= S.y1; ++b)
    for (int a = S.x0; a <= S.x1; ++a) {
      const int nd = fea_node_index(g, a, b, ez);
      if (touched[static_cast<std::size_t>(nd)]) top.push_back(nd);
    }
  if (!top.empty()) {
    const double per = 100.0 / static_cast<double>(top.size());
    for (int nd : top) S.loads.push_back({nd, 0, per});
  }
  return S;
}

// E = clamp(rho, rho_min, 1)^p * E0 on the part voxels; 0 on Empty (the void
// gate treats near-zero E as void, exactly the production high-contrast field).
std::vector<double> youngs_from_density(const System& S,
                                        const std::vector<double>& rho) {
  std::vector<double> E(S.grid.tags.size(), 0.0);
  for (std::size_t i = 0; i < E.size(); ++i) {
    if (S.grid.tags[i] == VoxelTag::Empty) continue;
    const double r = std::min(1.0, std::max(kRhoMin, rho[i]));
    E[i] = std::pow(r, kSimpP) * kE0;
  }
  return E;
}

std::vector<double> uniform_youngs(const System& S, double rho) {
  std::vector<double> u(S.grid.tags.size(), rho);
  return youngs_from_density(S, u);
}

struct GeoResult {
  bool ran = false, used_mg = false, hier_built = false;
  int mg_levels = 0, cycles = 0, iterations = 0;
  double residual = 0.0, seconds = 0.0;
  std::string error;
};

// Geometric MG via the EXACT production entry point. Resets the per-run latch
// first so each measurement is independent (the harness process is not "a run";
// production resets once per run in minimize_plastic.cpp).
GeoResult measure_geo(const System& S, const std::vector<double>& youngs,
                      double tol, int max_it) {
  GeoResult g;
  CgInfo info;
  fea_matfree_reset_mg_stagnation_latch();
  const double t0 = now_s();
  try {
    fea_solve_mgcg_matfree(S.grid, youngs, kNu, S.bcs, S.loads, tol, max_it, &info);
    g.ran = true;
  } catch (const std::exception& e) { g.error = e.what(); }
  g.seconds = now_s() - t0;
  g.used_mg = info.used_multigrid;
  g.hier_built = info.hier_built;
  g.mg_levels = info.mg_levels;
  g.cycles = info.mg_cycles_attempted;
  g.iterations = info.iterations;
  g.residual = info.residual;
  return g;
}

// Jacobi-CG fallback cost (the exact matrix-free path the latch forces).
GeoResult measure_jacobi(const System& S, const std::vector<double>& youngs,
                         double tol, int max_it) {
  GeoResult g;
  CgInfo info;
  const double t0 = now_s();
  try {
    fea_solve_cg_matfree(S.grid, youngs, kNu, S.bcs, S.loads, tol, max_it, &info);
    g.ran = true;
  } catch (const std::exception& e) { g.error = e.what(); }
  g.seconds = now_s() - t0;
  g.iterations = info.iterations;
  g.residual = info.residual;
  return g;
}

const char* verdict(const GeoResult& g) {
  if (!g.ran) return "ERROR";
  if (g.used_mg) return "CARRIES";
  if (g.hier_built) return "STAGNATED";  // built but did not contract
  return "no-hier";                       // build-rejection
}

// Develop `iters` OC steps at part-relative volume fraction `vf`, seeding from
// `x` (warm-start inheritance) and leaving the converged design in `x`. The
// physical (filtered) density is returned for measurement. Uses the production
// SIMP compliance + OC updater with a moderate develop tolerance for speed; the
// MEASUREMENT below is at the production 1e-6 tol on the developed field.
std::vector<double> develop_rung(const System& S, const SimpParams& params,
                                 const DensityFilter& filt, std::vector<double>& x,
                                 double vf, int iters, double dev_tol,
                                 int* last_cg) {
  std::vector<double> xp;
  for (int it = 0; it < iters; ++it) {
    xp = filt.filter_density(x);
    const std::vector<double> E = youngs_from_density(S, xp);
    // Graded penalized solve on the current physical density (self-contained:
    // build E directly so E-void voxels gate out, matching the MG measurement).
    SimpCompliance c = simp_compliance(S.grid, params, xp, S.bcs, S.loads,
                                       dev_tol, 0, nullptr, nullptr,
                                       SolverKind::MultigridCG_Matfree);
    if (last_cg) *last_cg = c.cg.iterations;
    x = oc_update(S.grid, filt, x, c.dcompliance, vf, 0.2, kRhoMin);
  }
  return filt.filter_density(x);
}

// ---------------------------------------------------------------------------
void mode_scan() {
  std::printf("\n=== SCAN — geometric MG on the UNIFORM (iteration-0) field ===\n");
  std::printf("Entry point: fea_solve_mgcg_matfree (production). tol=1e-6.\n");
  std::printf("Locates where stagnation BEGINS (M1). rho=0.5 uniform, no structure.\n\n");
  struct Case { const char* name; int ex, ey, ez; double occ, hole; };
  const std::vector<Case> cases = {
    {"64^3      occ1.0 nohole", 64, 64, 64, 1.0, 0.0},
    {"64^3      occ0.4 hole0.4", 64, 64, 64, 0.4, 0.4},
    {"128x80x96 occ0.45 nohole", 128, 80, 96, 0.45, 0.0},
    {"128x80x96 occ0.45 hole0.4",128, 80, 96, 0.45, 0.4},
    {"192x112x128 occ0.4 nohole",192,112,128, 0.4, 0.0},
    {"192x112x128 occ0.4 hole0.4",192,112,128,0.4, 0.4},
  };
  std::printf("%-28s %9s %9s | %-10s lvl %6s %6s %10s | %8s\n",
              "case", "nsolid", "nbore", "verdict", "cyc", "cgit", "resid", "sec");
  for (const Case& c : cases) {
    System S = build_part_box(c.ex, c.ey, c.ez, c.occ, c.hole);
    const std::vector<double> E = uniform_youngs(S, 0.5);
    GeoResult g = measure_geo(S, E, 1e-6, 20000);
    std::printf("%-28s %9lld %9lld | %-10s %3d %6d %6d %10.2e | %8.2f\n",
                c.name, S.nsolid, S.nbore, verdict(g), g.mg_levels, g.cycles,
                g.iterations, g.residual, g.seconds);
  }
}

void mode_ladder(int ex, int ey, int ez, double occ, int oc_iters, double dev_tol) {
  const std::vector<double> ladder = {0.68, 0.52, 0.38, 0.26};
  std::printf("\n=== LADDER — develop real OC field, measure geometric MG at each "
              "rung START (M2/M4/M5) ===\n");
  std::printf("extents=%dx%dx%d occ=%.2f  oc_iters/rung=%d  develop_tol=%.0e  "
              "measure_tol=1e-6\n", ex, ey, ez, occ, oc_iters, dev_tol);
  std::printf("Warm-start INHERIT: rung k+1 seeds from rung k's converged field "
              "(production warm_start_inherit).\n");
  std::printf("'rung START field' = what the latch would judge if re-armed at "
              "that boundary.\n");

  struct Regime { const char* name; double hole; };
  const std::vector<Regime> regimes = {
    {"NO-HOLE (AMG-P1 §6 dilute regime)", 0.0},
    {"WITH-HOLE (125 super-additive regime)", 0.4},
  };

  for (const Regime& rg : regimes) {
    System S = build_part_box(ex, ey, ez, occ, rg.hole);
    SimpParams params;
    params.youngs_modulus = kE0; params.poisson = kNu; params.penalty = kSimpP;
    params.density_min = kRhoMin;
    const DensityFilter filt =
        make_density_filter(S.grid, physical_filter_radius(2.5, S.grid.spacing));

    // Part-relative vf: rung vf is a fraction of the part's own voxels, spread
    // over the design domain (matches production part-relative rungs, 080).
    const long long design_vox = S.nsolid;  // part voxels available to the design
    std::printf("\n--- REGIME: %s ---\n", rg.name);
    std::printf("  part(design) voxels=%lld  bore=%lld  empty=%lld\n",
                S.nsolid, S.nbore, S.nempty);
    std::printf("  %-8s %-9s | START-field geometric MG            | Jacobi | "
                "END-field (converged rung) geometric MG\n", "rung", "vf");
    std::printf("  %-8s %-9s | %-9s lvl %5s %6s  %8s | %6s | %-9s %5s %6s\n",
                "", "", "verdict", "cyc", "cgit", "sec", "cgit", "verdict", "cyc",
                "cgit");

    std::vector<double> x = simp_uniform_density(S.grid, ladder[0]);
    for (std::size_t r = 0; r < ladder.size(); ++r) {
      const double vf = ladder[r];
      // START field = the inherited field (uniform for rung 0, previous rung's
      // converged design otherwise) — the moment a re-armed latch would judge.
      const std::vector<double> start_phys = filt.filter_density(x);
      const std::vector<double> Estart = youngs_from_density(S, start_phys);
      GeoResult gs = measure_geo(S, Estart, 1e-6, 20000);
      GeoResult js = measure_jacobi(S, Estart, 1e-6, 40000);
      std::printf("  [rung %zu vf %.3f: start measured (%s, cyc %d, jac %d); "
                  "developing %d OC iters...]\n", r, vf, verdict(gs), gs.cycles,
                  js.iterations, oc_iters);

      // Develop this rung.
      int last_cg = 0;
      const std::vector<double> end_phys =
          develop_rung(S, params, filt, x, vf, oc_iters, dev_tol, &last_cg);
      const std::vector<double> Eend = youngs_from_density(S, end_phys);
      GeoResult ge = measure_geo(S, Eend, 1e-6, 20000);

      std::printf("  %-8zu %-9.3f | %-9s %3d %5d %6d  %8.2f | %6d | %-9s %5d %6d\n",
                  r, vf, verdict(gs), gs.mg_levels, gs.cycles, gs.iterations,
                  gs.seconds, js.iterations, verdict(ge), ge.cycles, ge.iterations);
    }
  }
}

}  // namespace

int main(int argc, char** argv) {
  std::setvbuf(stdout, nullptr, _IONBF, 0);  // unbuffered: incremental progress
  const std::string mode = argc > 1 ? argv[1] : "scan";
  std::printf("mg_rearm_probe — Phase-0 latch re-arm measurement\n");

  if (mode == "scan" || mode == "all") mode_scan();
  if (mode == "ladder" || mode == "all") {
    // Default: a real-ish design box, moderate OC to develop structure.
    int ex = 128, ey = 80, ez = 96, oc = 18;
    double occ = 0.45, dev_tol = 1e-4;
    if (argc > 2) ex = std::atoi(argv[2]);
    if (argc > 3) ey = std::atoi(argv[3]);
    if (argc > 4) ez = std::atoi(argv[4]);
    if (argc > 5) occ = std::atof(argv[5]);
    if (argc > 6) oc = std::atoi(argv[6]);
    if (argc > 7) dev_tol = std::atof(argv[7]);
    mode_ladder(ex, ey, ez, occ, oc, dev_tol);
  }
  std::printf("\ndone.\n");
  return 0;
}
