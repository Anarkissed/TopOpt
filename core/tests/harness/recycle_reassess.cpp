// recycle_reassess.cpp — DOES THE KRYLOV RECYCLER STILL EARN ITS COST?
// (task krylov-recycle-reassessment;
//  handoff docs/handoffs/2026-08-03-krylov-recycle-reassessment.md)
//
// NOT a CTest target and NOT linked into any production path: a standalone
// measurement harness like geneo_disarm_gate.cpp, whose structure and protocol
// this file follows deliberately. It links the production library and drives the
// SHIPPED recycler — its dimension, its cadence, its wrap-multigrid rule, its
// carried basis — through the real matrix-free solve path.
//
// WHY IT EXISTS. PR 248 measured recycling's value ON TOP OF an always-armed
// GenEO deflation and found -2.8% / -1.0%, recommending it stay armed as "cheap,
// never harmful". PR 278 then gated GenEO off the steady-state path, so the
// stacked posture PR 248 measured no longer exists, and the recycler's share of a
// latched solve went from 16.8% to 31.3% — every remaining point of accelerator
// overhead. Both halves of "cheap, never harmful" therefore need re-measuring in
// the posture that actually ships.
//
// THE PROPERTY THAT MAKES THIS HARNESS HONEST — and it is the same one PR 278
// relied on: recycling has a first-class OFF (fea_set_krylov_recycling(false)),
// and with it off every call site is inert by construction (RecycleSession does
// nothing, allocates nothing, charges no matvec). So ON and OFF are two settings
// of ONE binary and can be INTERLEAVED whole-trajectory-by-whole-trajectory
// inside a single process. No baseline here is estimated or modelled.
//
// THE TWO BARS, ALWAYS REPORTED SEPARATELY (never averaged, never traded):
//   * DOF-WEIGHTED WORK — a DETERMINISTIC count, identical on any machine under
//     any load:  (CG iterations + recycle setup matvecs) x free DOFs, summed over
//     the trajectory. Operator applies are the unit because the matrix-free
//     matvec is what a solve is made of; weighting by DOFs lets fixtures of
//     different size be compared without averaging them together. It does NOT
//     charge the per-iteration correction's streaming traffic — that is exactly
//     why wall is reported beside it and never folded into it.
//   * WALL — machine-dependent, so taken ONLY from interleaved postures, pooled,
//     as medians, with the spread printed so the reader can see the host's noise
//     rather than take a median on faith.
// This project has twice been burned by iteration-count-only decisions (GenEO's
// arming; PR 273's finding that 88% of the cost was invisible to cg_iters). Two
// bars, side by side, is the response.
//
// Modes (argv[1]):
//   regime   the THREE fixture classes this task must keep separate, pinned and
//            characterised before anything is graded.
//   ab       AG1 — THE HONEST A/B in today's posture: recycling ON vs OFF, GenEO
//            armed with its shipped engagement gate, ABBA-interleaved, on the
//            latched path and on the healthy-multigrid path.
//   cert     AG1(c) — the certification solves, warm-basis and cold-basis.
//   phases   AG2 — where the recycle bill actually goes: begin / setup matvecs /
//            setup other / augment / observe / commit, with call counts.
//   dim      AG3 — the dimension sweep, k in {0,4,8,16,32}.
//   cycle    AG4 — the cadence sweep, rc_cycle in {1,2,4,8}.
//   wrapmg   AG5 — krylov_recycle_wrap_multigrid on the HEALTHY path.
//   exact    AG7 — exactness against the recycling-off posture, and determinism.
//
// Build (library Release first):
//   cmake -S core -B core/build -DCMAKE_BUILD_TYPE=Release -DTOPOPT_USE_OCCT=OFF
//   cmake --build core/build --target topopt -j
//   c++ -std=c++17 -O2 -I core/include -I core/src \
//     core/tests/harness/recycle_reassess.cpp core/build/libtopopt.a \
//     -o core/build/recycle_reassess
// Evidence dir: TOPOPT_RRA_DIR (default ./rra_evidence).

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "topopt/fea.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

#include "fea/recycle.hpp"  // the phase-timing instrument (AG2)

using namespace topopt;
using topopt::fea_detail::RcPhaseTimes;

namespace {

std::string evidence_dir() {
  const char* d = std::getenv("TOPOPT_RRA_DIR");
  return d ? std::string(d) : std::string("rra_evidence");
}

double now_s() {
  return std::chrono::duration<double>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

int env_i(const char* k, int d) {
  const char* e = std::getenv(k);
  return e ? std::atoi(e) : d;
}
double env_d(const char* k, double d) {
  const char* e = std::getenv(k);
  return e ? std::atof(e) : d;
}

constexpr double kTol = 1e-8;
constexpr double kNu = 0.33;
constexpr double kE0 = 3500.0;
constexpr double kRhoMin = 1e-3;

// The host's 1-minute load average, printed beside every wall table. The machine
// of record is SHARED for the duration of this task (a concurrent task owns the
// multigrid coarsening probe), and a wall number whose host load is not recorded
// is not evidence — PR 275 learned that when the same plain baseline came out
// 2.8x apart on two separate runs.
double load_avg_1m() {
  double la[3] = {0.0, 0.0, 0.0};
  return getloadavg(la, 3) > 0 ? la[0] : -1.0;
}

// ---------------------------------------------------------------------------
// FIXTURES — the three classes, kept separate and never averaged.
//
// (a) and (b) are the SAME bracket geometry. That is deliberate: the only thing
// that differs between the latched and healthy classes is whether the multigrid
// hierarchy is available, so any difference in the recycler's verdict between
// them is attributable to the preconditioner and to nothing else.
// ---------------------------------------------------------------------------
struct Case {
  VoxelGrid grid;
  std::vector<DirichletBC> bcs;
  std::vector<NodalLoad> loads;
  double vf = 0.35;
  bool latched = false;  // pin the solve path to plain Jacobi-CG
  std::string label;
  // Free DOFs of the reduced system — the weight in "DOF-weighted work".
  long long ndof = 0;
};

// The bracket, verbatim from geneo_disarm_gate.cpp's make_case so that the
// numbers in this handoff sit directly beside PR 278's. `odd_axis` forces one
// odd axis, which under parity-pad mode 0 makes the hierarchy unbuildable and
// reproduces the latched state deterministically; false leaves the grid
// coarsenable so the healthy V-cycle path runs.
Case make_bracket(int n, double dil, double vf, bool latched) {
  Case C;
  C.vf = vf;
  C.latched = latched;
  VoxelGrid& g = C.grid;
  const int pad = std::max(1, static_cast<int>(n * dil));
  g.nx = n + pad;
  g.ny = std::max(6, n / 2);
  g.nz = n + pad;
  if (latched && g.nz % 2 == 0) ++g.nz;  // ODD axis => hierarchy rejected
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

  C.ndof = 3LL * fea_node_count(g) - static_cast<long long>(C.bcs.size());
  char buf[220];
  std::snprintf(buf, sizeof buf,
                "%s bracket %dx%dx%d (%zu voxels, %lld free DOFs) dil=%.2f "
                "vf=%.2f, 4 clearances",
                latched ? "LATCHED" : "HEALTHY", g.nx, g.ny, g.nz,
                g.voxel_count(), C.ndof, dil, vf);
  C.label = buf;
  return C;
}

// ---------------------------------------------------------------------------
// POSTURE — every dial this task touches, in one struct, so no measurement can
// silently differ in more than the axis it claims to vary.
// ---------------------------------------------------------------------------
struct Posture {
  bool recycling = true;
  int dim = 16;        // production_krylov_recycle_dim()
  int cycle = 1;       // rc_cycle default
  bool wrap_mg = false;  // production pins this false
  bool geneo = true;   // ARMED WITH THE SHIPPED ENGAGEMENT GATE (PR 278)
  std::string name = "ON";
};

Posture posture_on() { Posture p; p.name = "ON"; return p; }
Posture posture_off() {
  Posture p;
  p.recycling = false;
  p.name = "OFF";
  return p;
}

void apply_posture(const Posture& p, const Case& C) {
  // The latched class is reached the way PR 275 and PR 278 reached it — by
  // pinning, not by waiting on three stagnations. WHY multigrid is absent does
  // not enter this arithmetic, and pinning removes the latch noise that would
  // otherwise contaminate every posture comparison.
  fea_set_mg_parity_pad_mode(C.latched ? 0 : 1);
  fea_matfree_reset_mg_stagnation_latch();
  fea_set_geneo_twolevel(p.geneo);
  fea_reset_geneo_basis();
  fea_set_krylov_recycling(p.recycling);
  fea_set_krylov_recycle_dim(p.dim > 0 ? p.dim : 16);
  fea_set_krylov_recycle_cycle(p.cycle);
  fea_set_krylov_recycle_wrap_multigrid(p.wrap_mg);
  fea_reset_krylov_recycle_space();
}

void clear_posture() {
  fea_set_geneo_twolevel(false);
  fea_reset_geneo_basis();
  fea_set_krylov_recycling(false);
  fea_set_krylov_recycle_dim(16);
  fea_set_krylov_recycle_cycle(1);
  fea_set_krylov_recycle_wrap_multigrid(false);
  fea_reset_krylov_recycle_space();
  fea_set_mg_parity_pad_mode(1);
  fea_matfree_reset_mg_stagnation_latch();
}

// ---------------------------------------------------------------------------
// One OC design trajectory. Records every per-solve number either bar is
// computed from, plus the recycler's own phase split when the instrument is on.
// ---------------------------------------------------------------------------
struct Rec {
  int iter = 0, cg = 0, rec_dim = 0, rec_setup_mv = 0, geneo_action = 0;
  bool used_mg = false, hier_built = false;
  double solve_s = 0.0, cg_ms = 0.0, recycle_ms = 0.0;
  double geneo_setup_ms = 0.0, geneo_apply_ms = 0.0, compliance = 0.0;
  RcPhaseTimes ph;
};

struct Run {
  std::string label;
  std::vector<Rec> its;
  long long cg_total = 0, setup_mv_total = 0;
  double wall = 0.0;
  std::vector<double> x_final;   // final density
  std::vector<double> u_final;   // final displacement field (the exactness bar)
  long long ndof = 0;
};

double penalty_at(int it) { return it < 3 ? 1.0 + it : 3.0; }

// `freeze_at` >= 0 stops the OC update at that iteration and keeps solving the
// SAME design — the certification pattern (a fixed design, solved once more).
Run trajectory(const std::string& label, const Case& C, int iters,
               const Posture& p, bool trace, bool reset_space = true) {
  apply_posture(p, C);
  if (!reset_space) { /* caller owns the carried basis */ }

  Run R;
  R.label = label;
  R.ndof = C.ndof;
  const DensityFilter filt =
      make_density_filter(C.grid, physical_filter_radius(2.5, C.grid.spacing));
  std::vector<double> x = simp_uniform_density(C.grid, C.vf);
  const double t0 = now_s();
  for (int it = 0; it < iters; ++it) {
    SimpParams params;
    params.youngs_modulus = kE0;
    params.poisson = kNu;
    params.penalty = penalty_at(it);
    params.density_min = kRhoMin;
    const std::vector<double> xp = filt.filter_density(x);
    fea_detail::rc_phase_reset();
    const double ts = now_s();
    const SimpCompliance c =
        simp_compliance(C.grid, params, xp, C.bcs, C.loads, kTol, 0, nullptr,
                        nullptr, SolverKind::MultigridCG_Matfree);
    Rec r;
    r.iter = it + 1;
    r.cg = c.cg.iterations;
    r.rec_dim = c.cg.recycle_dim;
    r.rec_setup_mv = c.cg.recycle_setup_matvecs;
    r.geneo_action = c.cg.geneo_action;
    r.used_mg = c.cg.used_multigrid;
    r.hier_built = c.cg.hier_built;
    r.solve_s = now_s() - ts;
    r.cg_ms = c.cg.t_cg_ms;
    r.recycle_ms = c.cg.t_recycle_ms;
    r.geneo_setup_ms = c.cg.t_geneo_setup_ms;
    r.geneo_apply_ms = c.cg.t_geneo_apply_ms;
    r.compliance = c.compliance;
    r.ph = fea_detail::rc_phase_times();
    R.its.push_back(r);
    R.cg_total += r.cg;
    R.setup_mv_total += r.rec_setup_mv;
    if (trace)
      std::printf("      it %-3d cg=%-6d mg=%d rec_dim=%-3d setup_mv=%-3d "
                  "%7.3f s  (cg %7.1f  rec %7.1f  geneo %6.1f+%5.1f ms)\n",
                  r.iter, r.cg, r.used_mg ? 1 : 0, r.rec_dim, r.rec_setup_mv,
                  r.solve_s, r.cg_ms, r.recycle_ms, r.geneo_setup_ms,
                  r.geneo_apply_ms);
    R.u_final = c.solution.u;
    x = oc_update(C.grid, filt, x, c.dcompliance, C.vf, 0.2, kRhoMin);
  }
  R.wall = now_s() - t0;
  R.x_final = x;
  clear_posture();
  return R;
}

double median(std::vector<double> v) {
  if (v.empty()) return 0.0;
  std::sort(v.begin(), v.end());
  return v[v.size() / 2];
}
std::string spread(std::vector<double> v) {
  if (v.empty()) return "-";
  std::sort(v.begin(), v.end());
  char b[96];
  std::snprintf(b, sizeof b, "%.3f..%.3f", v.front(), v.back());
  return std::string(b);
}

// The DETERMINISTIC bar. Operator applies x free DOFs, summed over the run.
double dof_work(const Run& R) {
  return static_cast<double>(R.cg_total + R.setup_mv_total) *
         static_cast<double>(R.ndof);
}

// Worst RELATIVE deviation between two fields, and whether they are bit-equal.
double rel_diff(const std::vector<double>& a, const std::vector<double>& b) {
  if (a.size() != b.size() || a.empty()) return 1.0;
  double num = 0.0, den = 0.0;
  for (std::size_t i = 0; i < a.size(); ++i) {
    num = std::max(num, std::fabs(a[i] - b[i]));
    den = std::max(den, std::fabs(a[i]));
  }
  return den > 0 ? num / den : num;
}
bool bit_equal(const std::vector<double>& a, const std::vector<double>& b) {
  return a.size() == b.size() &&
         std::memcmp(a.data(), b.data(), a.size() * sizeof(double)) == 0;
}

// A pooled posture: the steady-state per-solve numbers, ABBA-interleaved.
struct Pool {
  std::vector<double> solve_s, cg_ms, rec_ms, cg_iters;
  long long cg_total = 0, setup_mv = 0, solves = 0;
  double wall = 0.0;
  long long ndof = 0;
};
void absorb(Pool& P, const Run& R, int skip_first) {
  for (std::size_t i = static_cast<std::size_t>(skip_first); i < R.its.size();
       ++i) {
    const Rec& r = R.its[i];
    P.solve_s.push_back(r.solve_s);
    P.cg_ms.push_back(r.cg_ms);
    P.rec_ms.push_back(r.recycle_ms);
    P.cg_iters.push_back(r.cg);
    P.cg_total += r.cg;
    P.setup_mv += r.rec_setup_mv;
    ++P.solves;
  }
  P.wall += R.wall;
  P.ndof = R.ndof;
}
double pool_dof_work(const Pool& P) {
  return static_cast<double>(P.cg_total + P.setup_mv) *
         static_cast<double>(P.ndof);
}

}  // namespace

#include "recycle_reassess_modes.inc"

int main(int argc, char** argv) {
  const std::string mode = argc > 1 ? argv[1] : "ab";
  const std::string dir = evidence_dir();
  std::printf("recycle_reassess — mode=%s  evidence=%s\n", mode.c_str(),
              dir.c_str());
  std::printf("host 1-min load average at start: %.2f\n", load_avg_1m());
  // The shipped defaults this whole task is a reassessment OF. Printed first so
  // no table below can be read against the wrong baseline.
  std::printf("shipped defaults: dim=%d cycle=%d wrap_multigrid=%d "
              "phase_timing=%d\n",
              fea_krylov_recycle_dim(), fea_krylov_recycle_cycle(),
              fea_krylov_recycle_wrap_multigrid() ? 1 : 0,
              fea_detail::rc_phase_timing() ? 1 : 0);

  if (mode == "regime") return mode_regime(dir);
  if (mode == "ab") return mode_ab(dir);
  if (mode == "cert") return mode_cert(dir);
  if (mode == "phases") return mode_phases(dir);
  if (mode == "dim") return mode_dim(dir);
  if (mode == "cycle") return mode_cycle(dir);
  if (mode == "wrapmg") return mode_wrapmg(dir);
  if (mode == "exact") return mode_exact(dir);
  std::printf("unknown mode '%s'\n", mode.c_str());
  return 2;
}
