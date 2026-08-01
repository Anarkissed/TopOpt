// geneo_disarm_gate.cpp — THE ENGAGEMENT GATE, measured (task geneo-disarm;
// handoff docs/handoffs/2026-08-02-geneo-disarm.md).
//
// NOT a CTest target, NOT linked into any production path: a standalone
// measurement harness like geneo_arming_gate.cpp / geneo_standing_probe.cpp. It
// links the production library and drives the SHIPPED GenEO provider — its
// basis, its reuse policy, its rebuild policy, its fingerprints — through the
// real matrix-free solve path.
//
// THE ONE PROPERTY THAT MAKES THIS HARNESS HONEST. The PRE-change posture is
// exactly reachable from the harness-only probe surface: `engage_threshold = 0`
// means "engage the held basis from iteration 0", which IS what geneo_solve_begin
// did before this task. So ARMED (before) and GATED (after) are two settings of
// ONE binary and can be INTERLEAVED solve-by-solve inside one process. Every
// wall claim here comes from an interleaved comparison, so stationary machine
// load hits both postures equally and cancels — the discipline PR 275 had to
// adopt after separately-run postures on a loaded host differed 2.8x.
//
// Modes:
//   regime  find/confirm the two operating points this task must separate: the
//           LATCHED rung-3 state (~200-900 plain Jacobi-CG per solve) and a
//           genuinely CATASTROPHIC solve (PR 248's 1,685-41,063 band).
//   aa1prod THE RESCUE CASE STILL WINS — on the PRODUCTION path (minimize_plastic
//           over PR 248's big-stagnation design box, the regime that actually
//           reaches the 1,685-41,063 band). This is the load-bearing AA1 run.
//   aa1     the same question on a hand-rolled OC fixture (kept because it is
//           cheap and isolates the solve path; see the handoff for why it CANNOT
//           reach the catastrophic band). Catastrophic solve, three postures
//           (plain / armed / gated), wall AND iterations. If the gate kills the
//           rescue, the rule is wrong.
//   aa2     THE 215-ITERATION TAX IS GONE. The latched reproduction, ARMED vs
//           GATED interleaved, wall per design iteration + the phase split, and
//           what fraction of the iteration is still accelerator overhead.
//   bench   THE LOAD-ROBUST WALL COMPARISON: alternating ARMED/GATED whole
//           trajectories in ABBA order, pooled medians. Every wall claim in the
//           handoff comes from here, not from separately-run postures.
//   aa4     EXACTNESS + DETERMINISM. One design solved never-armed / always-armed
//           / gated; fields compared; the gated posture rerun for bit-identity.
//   aa6     RECYCLING IS UNAFFECTED. Recycle setup matvecs + wall, before/after.
//
// Build (library Release first):
//   cmake -S core -B core/build -DCMAKE_BUILD_TYPE=Release -DTOPOPT_USE_OCCT=OFF
//   cmake --build core/build --target topopt -j
//   c++ -std=c++17 -O2 -I core/include -I core/src \
//     -DSETTINGS_RULES_PATH="\"$PWD/core/src/settings/rules.json\"" \
//     core/tests/harness/geneo_disarm_gate.cpp core/build/libtopopt.a \
//     -o core/build/geneo_disarm_gate
// Evidence dir: TOPOPT_GDG_DIR (default ./gdg_evidence).

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

#include "topopt/fea.hpp"
#include "topopt/materials.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/production.hpp"
#include "topopt/settings.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

#include "fea/geneo.hpp"  // the harness-only probe override surface

using namespace topopt;
using topopt::fea_detail::GeneoProbeConfig;

namespace {

std::string evidence_dir() {
  const char* d = std::getenv("TOPOPT_GDG_DIR");
  return d ? std::string(d) : std::string("gdg_evidence");
}

double now_s() {
  return std::chrono::duration<double>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

constexpr double kTol = 1e-8;
constexpr double kNu = 0.33;
constexpr double kE0 = 3500.0;
constexpr double kRhoMin = 1e-3;

// The pinned post-latch solve path: multigrid ABSENT, every solve a matrix-free
// Jacobi-CG. Reached directly and deterministically (an odd axis + the legacy
// parity-pad rejection) rather than by waiting on three consecutive
// stagnations — the same isolation PR 275 used, and for the same reason: WHY
// multigrid is absent does not enter this arithmetic, and pinning it removes the
// latch noise that would otherwise contaminate every posture comparison.
void pin_to_jacobi_fallback() {
  fea_set_mg_parity_pad_mode(0);
  fea_matfree_reset_mg_stagnation_latch();
}

// ---------------------------------------------------------------------------
// THE THREE POSTURES. All three drive the SAME shipped provider; only the
// engagement threshold differs, so nothing else can explain a difference.
// ---------------------------------------------------------------------------
enum class Posture { Plain, Armed, Gated };

const char* posture_name(Posture p) {
  switch (p) {
    case Posture::Plain: return "plain (GenEO off)";
    case Posture::Armed: return "ARMED (pre-change: deflate from iteration 0)";
    case Posture::Gated: return "GATED (this task's engagement gate)";
  }
  return "?";
}

void set_posture(Posture p) {
  GeneoProbeConfig cfg;  // defaults ARE the shipped recipe
  if (p == Posture::Armed) cfg.engage_threshold = 0;
  fea_detail::geneo_set_probe_config(cfg);
  fea_set_geneo_twolevel(p != Posture::Plain);
}

void reset_posture() {
  fea_set_geneo_twolevel(false);
  fea_reset_geneo_basis();
  fea_detail::geneo_set_probe_config(GeneoProbeConfig{});
}

// ---------------------------------------------------------------------------
// FIXTURE. A wall-mount bracket load path in a dilute designable box with four
// bolt clearances carved out as permanently void voxels. `dil` sets how dilute
// the box is, which is the knob that moves the plain Jacobi-CG count between the
// LATCHED band and the CATASTROPHIC band.
// ---------------------------------------------------------------------------
struct Case {
  VoxelGrid grid;
  std::vector<DirichletBC> bcs;
  std::vector<NodalLoad> loads;
  double vf = 0.35;
  // Voxels PINNED SOLID every iteration (the imported part inside a design box).
  // Empty on the uniform-box fixture. This is what makes the CATASTROPHIC regime
  // catastrophic: a solid load path threading a near-void box is a 1e9 modulus
  // contrast across a one-voxel interface, and that — not the grid size and not
  // the volume fraction — is what makes Jacobi-CG grind. Measured below.
  std::vector<char> pinned_solid;
  std::string label;
};

Case make_case(int n, double dil, double vf) {
  Case C;
  C.vf = vf;
  VoxelGrid& g = C.grid;
  const int pad = std::max(1, static_cast<int>(n * dil));
  g.nx = n + pad;
  g.ny = std::max(6, n / 2);
  g.nz = n + pad;
  if (g.nz % 2 == 0) ++g.nz;  // ODD axis => hierarchy rejected under pad mode 0
  g.spacing = 1.5;
  g.origin = Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(g.nx) * g.ny * g.nz,
                VoxelTag::Interior);

  const int cr = std::max(1, n / 12);
  const int cdepth = std::max(2, n / 5);
  const int yq[2] = {g.ny / 4, (3 * g.ny) / 4};
  const int zq[2] = {g.nz / 4, (3 * g.nz) / 4};
  for (int yc : yq)
    for (int zc : zq)
      for (int i = 0; i < cdepth; ++i)
        for (int j = yc - cr; j <= yc + cr; ++j)
          for (int k = zc - cr; k <= zc + cr; ++k)
            if (j >= 0 && j < g.ny && k >= 0 && k < g.nz)
              g.set_tag(i, j, k, VoxelTag::Empty);

  for (int c = 0; c <= g.nz; ++c)
    for (int b = 0; b <= g.ny; ++b) {
      const int nd = fea_node_index(g, 0, b, c);
      C.bcs.push_back({nd, 0, 0.0});
      C.bcs.push_back({nd, 1, 0.0});
      C.bcs.push_back({nd, 2, 0.0});
    }
  const int tip_band = std::max(2, n / 8);
  for (int k = 0; k < tip_band; ++k)
    for (int j = 0; j < g.ny; ++j) g.set_tag(g.nx - 1, j, k, VoxelTag::Load);
  C.loads = traction_loads(g, VoxelTag::Load, Vec3{0.0, 0.0, -40.0});

  char buf[200];
  std::snprintf(buf, sizeof buf,
                "bracket %dx%dx%d (%zu voxels) dil=%.2f vf=%.2f, 4 clearances",
                g.nx, g.ny, g.nz, g.voxel_count(), dil, vf);
  C.label = buf;
  return C;
}

// THE CATASTROPHIC FIXTURE — the AD/GenEO gate's "big stagnation" regime
// (geneo_arming_gate.cpp make_big_stagnation, the 48.8x-dilution design box):
// an L-bracket load path PINNED SOLID inside a large near-void designable box.
// PR 248 measured 1,685-41,063 plain Jacobi-CG iterations in a single solve on
// this class, and that is the regime GenEO was armed for and must keep.
Case make_stagnation_case(int arm, double dil, double vf) {
  Case C;
  C.vf = vf;
  const int t = std::max(2, arm / 4);
  const int ny = std::max(4, arm / 4);
  const int pad = std::max(2, static_cast<int>(arm * dil));
  const int pady = std::max(1, pad / 2);
  VoxelGrid& g = C.grid;
  // The part is placed against the +x and +z faces of the box so its LOAD and
  // FIXTURE voxels sit on the grid boundary and have exposed faces; the dilute
  // margin is on the -x / -z sides (and both y sides). Everything in the box is
  // designable; only the part is pinned solid.
  g.nx = pad + arm;
  g.ny = ny + 2 * pady;
  g.nz = pad + arm;
  const int part_z1 = g.nz;          // the wall reaches the +z boundary
  if (g.nz % 2 == 0) ++g.nz;         // ODD axis => hierarchy rejected, pad mode 0
  g.spacing = 1.0;
  g.origin = Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(g.nx) * g.ny * g.nz,
                VoxelTag::Interior);
  C.pinned_solid.assign(g.voxel_count(), 0);

  // The L: a vertical wall at the +x end, a horizontal shelf at the +z end.
  for (int k = pad; k < part_z1; ++k)
    for (int j = pady; j < pady + ny; ++j)
      for (int i = pad; i < g.nx; ++i)
        if (i >= g.nx - t || k >= part_z1 - t)
          C.pinned_solid[g.index(i, j, k)] = 1;

  // FIXED: the top face of the vertical wall (the +z boundary node plane).
  for (int j = pady; j <= pady + ny; ++j)
    for (int i = g.nx - t; i <= g.nx; ++i) {
      const int nd = fea_node_index(g, i, j, part_z1);
      C.bcs.push_back({nd, 0, 0.0});
      C.bcs.push_back({nd, 1, 0.0});
      C.bcs.push_back({nd, 2, 0.0});
    }
  // LOADED: the shelf's free end at the -x side of the part, tagged on voxels
  // whose -x neighbour is outside the part but INSIDE the box — so the load
  // rides the part, and the box around it is the dilute material the solver has
  // to push a load path through. Tagging on the +z boundary keeps a face exposed.
  for (int j = pady; j < pady + ny; ++j)
    for (int i = pad; i < pad + t && i < g.nx; ++i)
      g.set_tag(i, j, g.nz - 1, VoxelTag::Load);
  C.loads = traction_loads(g, VoxelTag::Load, Vec3{0.0, 0.0, -30.0});

  std::size_t solid = 0;
  for (char c : C.pinned_solid) solid += c ? 1u : 0u;
  char buf[220];
  std::snprintf(buf, sizeof buf,
                "STAGNATION L-bracket %dx%dx%d (%zu voxels), part %zu solid "
                "(%.1fx dilution), box vf=%.3f",
                g.nx, g.ny, g.nz, g.voxel_count(), solid,
                solid ? double(g.voxel_count()) / double(solid) : 0.0, vf);
  C.label = buf;
  return C;
}

// ---------------------------------------------------------------------------
// One OC design trajectory on the pinned Jacobi path. Records EVERY per-solve
// number the gate's decision is graded on.
// ---------------------------------------------------------------------------
struct Rec {
  int iter = 0, cg = 0, action = 0, dim = 0, burn = 0, threshold = 0;
  int recycle_setup_matvecs = 0;
  double solve_s = 0.0, cg_ms = 0.0, geneo_setup_ms = 0.0, geneo_apply_ms = 0.0;
  double recycle_ms = 0.0, compliance = 0.0;
};

struct Run {
  std::string label;
  std::vector<Rec> its;
  long long cg_total = 0;
  double wall = 0.0, solve_s = 0.0;
  long long builds = 0, refreshes = 0, armed = 0, declined = 0;
  double build_s = 0.0, refresh_s = 0.0, apply_s = 0.0;
  std::vector<double> x_final;
};

double penalty_at(int it) { return it < 3 ? 1.0 + it : 3.0; }

Run trajectory(const std::string& label, const Case& C, int iters, Posture p,
               bool recycling, bool trace) {
  pin_to_jacobi_fallback();
  fea_set_krylov_recycling(recycling);
  fea_reset_krylov_recycle_space();
  reset_posture();
  set_posture(p);
  fea_reset_geneo_basis();

  Run R;
  R.label = label;
  const DensityFilter filt =
      make_density_filter(C.grid, physical_filter_radius(2.5, C.grid.spacing));
  std::vector<double> x = simp_uniform_density(C.grid, C.vf);
  auto pin = [&](std::vector<double>& v) {
    for (std::size_t i = 0; i < C.pinned_solid.size() && i < v.size(); ++i)
      if (C.pinned_solid[i]) v[i] = 1.0;
  };
  pin(x);
  const double t0 = now_s();
  for (int it = 0; it < iters; ++it) {
    SimpParams params;
    params.youngs_modulus = kE0;
    params.poisson = kNu;
    params.penalty = penalty_at(it);
    params.density_min = kRhoMin;
    std::vector<double> xp = filt.filter_density(x);
    pin(xp);  // the filter blurs the part boundary; the CONTRAST is the fixture
    const double ts = now_s();
    const SimpCompliance c =
        simp_compliance(C.grid, params, xp, C.bcs, C.loads, kTol, 0, nullptr,
                        nullptr, SolverKind::MultigridCG_Matfree);
    Rec r;
    r.iter = it + 1;
    r.cg = c.cg.iterations;
    r.action = c.cg.geneo_action;
    r.dim = c.cg.geneo_dim;
    r.burn = c.cg.geneo_trigger_burn;
    r.threshold = c.cg.geneo_threshold;
    r.recycle_setup_matvecs = c.cg.recycle_setup_matvecs;
    r.solve_s = now_s() - ts;
    r.cg_ms = c.cg.t_cg_ms;
    r.geneo_setup_ms = c.cg.t_geneo_setup_ms;
    r.geneo_apply_ms = c.cg.t_geneo_apply_ms;
    r.recycle_ms = c.cg.t_recycle_ms;
    r.compliance = c.compliance;
    R.its.push_back(r);
    R.cg_total += r.cg;
    R.solve_s += r.solve_s;
    if (trace)
      std::printf("      it %-3d cg=%-6d act=%d N_t=%-5d burn=%-6d thr=%-6d "
                  "%7.3f s  (cg %6.0f  geneo %7.0f+%6.0f  rec %5.0f ms)\n",
                  r.iter, r.cg, r.action, r.dim, r.burn, r.threshold, r.solve_s,
                  r.cg_ms, r.geneo_setup_ms, r.geneo_apply_ms, r.recycle_ms);
    x = oc_update(C.grid, filt, x, c.dcompliance, C.vf, 0.2, kRhoMin);
    pin(x);
  }
  R.wall = now_s() - t0;
  R.builds = fea_geneo_basis_builds();
  R.refreshes = fea_geneo_coarse_refreshes();
  R.armed = fea_geneo_armed_solves();
  R.declined = fea_geneo_declined_solves();
  R.build_s = fea_detail::geneo_probe_build_seconds();
  R.refresh_s = fea_detail::geneo_probe_refresh_seconds();
  R.apply_s = fea_detail::geneo_probe_apply_seconds();
  R.x_final = x;
  reset_posture();
  fea_set_krylov_recycling(false);
  fea_set_mg_parity_pad_mode(1);
  return R;
}

double median(std::vector<double> v) {
  if (v.empty()) return 0.0;
  std::sort(v.begin(), v.end());
  return v[v.size() / 2];
}

void write_csv(const std::string& path, const Run& R) {
  FILE* fp = std::fopen(path.c_str(), "w");
  if (!fp) return;
  std::fprintf(fp,
               "iter,cg_iters,geneo_action,geneo_dim,geneo_burn,"
               "geneo_threshold,solve_s,cg_ms,geneo_setup_ms,geneo_apply_ms,"
               "recycle_ms,recycle_setup_matvecs,compliance\n");
  for (const Rec& r : R.its)
    std::fprintf(fp, "%d,%d,%d,%d,%d,%d,%.5f,%.3f,%.3f,%.3f,%.3f,%d,%.10g\n",
                 r.iter, r.cg, r.action, r.dim, r.burn, r.threshold, r.solve_s,
                 r.cg_ms, r.geneo_setup_ms, r.geneo_apply_ms, r.recycle_ms,
                 r.recycle_setup_matvecs, r.compliance);
  std::fclose(fp);
  std::printf("  wrote %s\n", path.c_str());
}

double rel_u_diff(const std::vector<double>& a, const std::vector<double>& b) {
  if (a.size() != b.size() || a.empty()) return 1.0;
  double num = 0.0, den = 0.0;
  for (std::size_t i = 0; i < a.size(); ++i) {
    num = std::max(num, std::fabs(a[i] - b[i]));
    den = std::max(den, std::fabs(a[i]));
  }
  return den > 0 ? num / den : num;
}

int env_i(const char* k, int d) {
  const char* e = std::getenv(k);
  return e ? std::atoi(e) : d;
}
double env_d(const char* k, double d) {
  const char* e = std::getenv(k);
  return e ? std::atof(e) : d;
}

// ---------------------------------------------------------------------------
// THE PRODUCTION PATH. The catastrophic regime is not reachable by hand-rolled
// OC on a small grid — PR 275 showed why: plain Jacobi's count grows with the
// grid DIAMETER while N_t (the refresh price) grows with its VOLUME, so a grid
// small enough to have a cheap basis is also too small to stagnate. The 1,685-
// 41,063 band lives on a real ladder driving a real design box down, which is
// exactly what geneo_arming_gate.cpp's `make_big_stagnation` fixture reproduces
// (the AD gate's regime, verbatim). So the rescue case is measured HERE, through
// minimize_plastic with the full production posture, and the per-iteration
// numbers come from PR 273's observation stream rather than a harness clock.
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

VoxelGrid l_bracket_part(std::vector<DirichletBC>& bcs, int arm, int span,
                         int ny, int t, double h) {
  VoxelGrid g;
  g.nx = span; g.ny = ny; g.nz = arm; g.spacing = h; g.origin = Vec3{0, 0, 0};
  g.tags.assign(static_cast<std::size_t>(span) * ny * arm, VoxelTag::Empty);
  for (int k = 0; k < arm; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < span; ++i)
        if (i < t || k < t) g.set_tag(i, j, k, VoxelTag::Interior);
  for (int j = 0; j < ny; ++j)
    for (int i = 0; i < t; ++i) g.set_tag(i, j, arm - 1, VoxelTag::Fixture);
  bcs.clear();
  for (int b = 0; b <= ny; ++b)
    for (int a = 0; a <= t; ++a) {
      const int nd = fea_node_index(g, a, b, arm);
      bcs.push_back({nd, 0, 0.0});
      bcs.push_back({nd, 1, 0.0});
      bcs.push_back({nd, 2, 0.0});
    }
  for (int k = 0; k < t; ++k)
    for (int j = 0; j < ny; ++j) g.set_tag(span - 1, j, k, VoxelTag::Load);
  return g;
}

struct ProdIter {
  int cg = 0, action = 0, dim = 0, burn = 0, threshold = 0, used_mg = 0;
  double solve_ms = 0, cg_ms = 0, setup_ms = 0, apply_ms = 0, rec_ms = 0;
};
struct ProdRun {
  std::vector<ProdIter> its;
  double wall = 0.0;
  long long cg_total = 0, builds = 0, refreshes = 0, armed = 0, declined = 0;
};

ProdRun production_run(Posture p, int max_iters, const SettingsRules& rules) {
  std::vector<DirichletBC> bcs;
  // geneo_arming_gate.cpp make_big_stagnation, verbatim: 73,728 elements, 48.8x
  // dilution — the regime where multigrid falls to Jacobi-CG.
  VoxelGrid part = l_bracket_part(bcs, 24, 24, 6, 6, 1.0);
  const std::vector<NodalLoad> loads =
      traction_loads(part, VoxelTag::Load, Vec3{0.0, 0.0, -30.0});
  MinimizePlasticOptions o;
  configure_production_options(o);
  o.draft_quality = false;  // keep fallbacks in the Jacobi regime (PR 248 §A6)
  o.volume_fraction_ladder = {0.50};
  o.margin_stop = 0.0;
  o.external_loads = loads;
  o.gravity = 9810.0 * 1e-9;
  o.gravity_direction = Vec3{0.0, 0.0, -1.0};
  o.infill_percent = 100.0;
  DesignBox box;
  box.min = Vec3{-12.0, -13.0, -12.0};
  box.max = Vec3{36.0, 19.0, 36.0};
  o.design_box = box;
  o.simp.max_iterations = max_iters;
  o.simp.mma_plateau_window = 0;
  o.simp.change_tol = 0.0;

  ProdRun R;
  o.on_iteration = [&](std::size_t, std::size_t,
                       const SimpIterationObservation& ob) {
    ProdIter r;
    r.cg = ob.cg_iterations;
    r.action = ob.cg_geneo_action;
    r.dim = ob.cg_geneo_dim;
    r.burn = ob.cg_geneo_burn;
    r.threshold = ob.cg_geneo_threshold;
    r.used_mg = ob.cg_used_multigrid ? 1 : 0;
    r.solve_ms = ob.phases.solve_ms;
    r.cg_ms = ob.phases.solver_cg_ms;
    r.setup_ms = ob.phases.solver_geneo_setup_ms;
    r.apply_ms = ob.phases.solver_geneo_apply_ms;
    r.rec_ms = ob.phases.solver_recycle_ms;
    R.its.push_back(r);
    R.cg_total += r.cg;
  };
  reset_posture();
  set_posture(p);
  fea_reset_geneo_basis();
  fea_reset_krylov_recycle_space();
  const double t0 = now_s();
  const MinimizePlasticResult res =
      minimize_plastic(part, fdm_material(), "fdm", bcs, rules, o);
  (void)res;
  R.wall = now_s() - t0;
  R.builds = fea_geneo_basis_builds();
  R.refreshes = fea_geneo_coarse_refreshes();
  R.armed = fea_geneo_armed_solves();
  R.declined = fea_geneo_declined_solves();
  reset_posture();
  fea_set_krylov_recycling(false);
  return R;
}

#include "geneo_disarm_gate_modes.inc"

}  // namespace

int main(int argc, char** argv) {
  std::setvbuf(stdout, nullptr, _IOLBF, 0);
  const std::string mode = argc > 1 ? argv[1] : "regime";
  const std::string dir = evidence_dir();

  if (!fea_detail::geneo_probe_defaults_match_tripwire()) {
    std::fprintf(stderr,
                 "FAIL: the probe override DEFAULTS no longer equal the shipped "
                 "GenEO recipe — every number below would be measuring "
                 "something other than production.\n");
    return 1;
  }
  std::printf("probe defaults == shipped recipe: YES  (trigger=%d "
              "refresh_cost/col=%.2f defl_iter_cost=%.2f rebuild=%.1f)\n",
              fea_geneo_trigger_iters(), fea_geneo_refresh_cost_per_column(),
              fea_geneo_deflated_iter_cost(), fea_geneo_rebuild_factor());

  if (mode == "regime") return mode_regime(dir);
  if (mode == "aa1") return mode_aa1(dir);
  if (mode == "aa1prod") return mode_aa1prod(dir);
  if (mode == "aa2") return mode_aa2(dir);
  if (mode == "bench") return mode_bench(dir);
  if (mode == "aa4") return mode_aa4(dir);
  if (mode == "aa6") return mode_aa6(dir);
  std::fprintf(stderr, "unknown mode: %s\n", mode.c_str());
  return 2;
}
