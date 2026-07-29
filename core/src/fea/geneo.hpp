// Internal (non-installed) header for the matrix-free GenEO two-level DEFLATION
// preconditioner (handoff 2026-07-29-geneo-arming; built and measured in
// 2026-07-29-matrixfree-geneo-phase2). The interface is deliberately Eigen-FREE
// so matfree.cpp (which stays Eigen-free) can drive it; the implementation
// (geneo.cpp) links Eigen PRIVATE like multigrid.cpp/assembly.cpp — the public
// topopt/ API stays Eigen-free per ARCHITECTURE §4.
//
// WHAT IT IS. The winning Phase-2 form: a second SPD additive correction on the
// matrix-free Jacobi-CG (the stagnation fallback ONLY — a healthy multigrid rung
// never enters it):
//     M^-1 = D^-1 + V (V^T A V)^-1 V^T          (arXiv 1912.13225 eq. 9)
// where V is the capture-LOBPCG GenEO coarse basis (per-subdomain generalized
// eigenvectors below the lambda cut, partition-of-unity weighted, mapped into the
// reduced kept-DOF space) and A is the PRODUCTION reduced operator apply_kgg.
// The local additive-Schwarz term was measured USELESS with inexact local solves
// (phase 2 §P7b) and is NOT ported; the harness keeps it for the ablation.
//
// Every term is SPD, so the compound preconditioner is SPD: it changes the CG
// ITERATION COUNT, never the converged field or the exact stopping test. The
// certification gate is untouched.
//
// LIFECYCLE (the armed reuse policy, measured in phase 2 §P6):
//   * geneo_solve_begin  — called once at the start of every mf_cg_solve when the
//     feature is enabled and a solve context exists. If a basis is held and its
//     DOF set still matches, the coarse operator V^T A V is REFRESHED against the
//     current operator (N_t matvecs + a small dense factor — mandatory; a stale
//     coarse operator is not a deflation for the new system and diverges) and the
//     preconditioner is ACTIVE from iteration 0. Returns false when no basis is
//     held (the trigger policy applies) or the DOF set changed (basis dropped).
//   * geneo_build_now    — called by mf_cg_solve when a plain solve reaches the
//     stagnation trigger (kGeneoTriggerIters) unconverged: builds the basis for
//     THIS system (the expensive LOBPCG eigensolve). Returns false (and the solve
//     stays plain Jacobi-CG, exact) if the basis would bust the memory cap.
//   * geneo_apply        — z += V (V^T A V)^-1 V^T r, reduced space.
//   * geneo_solve_end    — degradation bookkeeping: a reused-basis solve whose
//     iteration count exceeds kGeneoRebuildFactor x the post-rebuild reference
//     schedules a full rebuild at the next solve's begin.
//
// State is process-global like the Krylov-recycling space (one production run
// drives its solves from one thread); fea_reset_geneo_basis() (public, fea.hpp)
// drops it at run start, mirroring fea_reset_krylov_recycle_space().

#pragma once

#include <cstddef>

#include "fea_matfree.hpp"

namespace topopt {
namespace fea_detail {

// =========================================================================
// TRIPWIRE — the ARMED GenEO recipe constants (handoff 2026-07-29-geneo-arming).
// =========================================================================
// Do NOT change any value here without re-running
//   * core/tests/harness/geneo_twolevel_probe.cpp   p2 / control / amort / healthy
//   * core/tests/harness/geneo_arming_gate.cpp      gate / interaction / stag
// and landing a new before/after table. The recipe is phase 2's measured
// configuration (21.7x on the real stagnating rung; flat ~255 two-level count on
// the controlled sweep), not a tunable surface.
//
// kGeneoCoreCells / kGeneoOverlap / kGeneoBlockM / kGeneoLambdaCut — the
//   subdomain tiling (8^3-element cores, 1-element overlap), the LOBPCG block
//   size and the GenEO eigenvalue cut, exactly phase 2's `core=8, ov=1,
//   block_m=20, cut=0.05`.
// kGeneoCoarseDenseCap — dense-Cholesky the coarse operator when N_t is at or
//   under this; a capped Jacobi-CG inner solve above it (production extents,
//   phase 2 §P3). kGeneoCoarseInnerIters caps that inner solve.
// kGeneoTriggerIters — the STAGNATION TRIGGER: a fallback solve pays the basis
//   build only after burning this many plain Jacobi-CG iterations unconverged.
//   Derivation: the measured healthy-regime Jacobi fallback ceiling is ~327
//   iterations (phase 2 §P7 healthy fixture) and the measured stagnation floor is
//   1,685-41,063 (phase 2 §P2/§P6, handoff 125); 500 sits ~1.5x above the healthy
//   ceiling and ~0.3x under the stagnation floor, so a healthy fallback never
//   pays the eigensolve and a stagnating one pays it 500 iterations in — noise
//   against the thousands it then saves. Once a basis exists the trigger is moot:
//   later fallback solves refresh (cheap) and deflate from iteration 0.
// kGeneoRebuildFactor — the DEGRADATION REBUILD trigger: after a reused-basis
//   solve, if its iteration count exceeded this factor times the post-rebuild
//   reference count, the next solve rebuilds the basis first. Derivation: phase 2
//   §P6 measured reuse staying within 1.42x of a fresh rebuild across 5
//   consecutive OC states (225-251 vs 161-222 iters), so 2.0x clears the healthy
//   reuse band with margin while still catching a design that moves faster than
//   the basis can represent. The degraded solve itself is still EXACT (the
//   preconditioner never changes the answer) — the trigger only costs one solve
//   of extra iterations before the rebuild lands.
// kGeneoMaxBasisMB — memory guard: a build whose stored basis would exceed this
//   is refused and the solve stays plain Jacobi-CG (exact, just slower). 2048 MB
//   holds the 8.44M-DOF projection (~1.2 GB, phase 2 §P3) with margin and leaves
//   >13 GB headroom on the 16 GB machine of record.
constexpr int kGeneoCoreCells = 8;
constexpr int kGeneoOverlap = 1;
constexpr int kGeneoBlockM = 20;
constexpr double kGeneoLambdaCut = 0.05;
constexpr int kGeneoCoarseDenseCap = 6000;
constexpr int kGeneoCoarseInnerIters = 40;
constexpr int kGeneoTriggerIters = 500;
constexpr double kGeneoRebuildFactor = 2.0;
constexpr int kGeneoMaxBasisMB = 2048;

// What the GenEO preconditioner did on ONE solve (forwarded into CgInfo).
//   action: 0 = off / never engaged (plain solve, or trigger never reached)
//           1 = REUSED the held basis + coarse operator unchanged (same system)
//           2 = REFRESHED the coarse operator against this system's operator
//           3 = REBUILT the basis (first build, DOF-set change, or degradation)
//           4 = build REFUSED by the memory cap (solve stayed plain, exact)
//   dim:    N_t, the coarse-space dimension that preconditioned this solve
//   trigger_burn: plain iterations burned before the in-solve build (action 3
//           via the stagnation trigger); 0 when the basis pre-existed.
struct GeneoReport {
  int action = 0;
  int dim = 0;
  int trigger_burn = 0;
};

bool geneo_enabled();
bool geneo_set_enabled(bool enable);  // returns previous
void geneo_reset();                   // drop basis + counters (run start / tests)

// Per-solve lifecycle (see header comment). All no-ops / false when disabled.
bool geneo_solve_begin(const MatfreeReduced& m, const MfSolveContext& ctx);
bool geneo_build_now(const MatfreeReduced& m, const MfSolveContext& ctx,
                     int iterations_burned);
void geneo_apply(const double* r, double* z);
void geneo_solve_end(int iterations, bool converged);
GeneoReport geneo_last_report();

// Cumulative-since-reset diagnostics (run_info echo; public faces in fea.hpp).
long long geneo_basis_builds();
long long geneo_coarse_refreshes();
long long geneo_armed_solves();   // fallback solves on which the deflation applied
int geneo_basis_dim();            // N_t currently held (0 = no basis)
std::size_t geneo_basis_bytes();  // stored coarse-basis bytes currently held

}  // namespace fea_detail
}  // namespace topopt
