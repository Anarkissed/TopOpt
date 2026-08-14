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
// LIFECYCLE (the armed reuse policy, measured in phase 2 §P6; the ENGAGEMENT
// GATE added by handoff 2026-08-02-geneo-disarm):
//   * geneo_solve_begin  — called once at the start of every mf_cg_solve when the
//     feature is enabled and a solve context exists. Drops a basis whose DOF set
//     no longer matches and resets the per-solve report. It does NOT engage the
//     deflation: EVERY solve starts plain, and the engagement gate below decides.
//   * geneo_engage_threshold — the plain-iteration burn this solve must reach
//     before the deflation may engage (see THE ENGAGEMENT GATE below).
//   * geneo_engage_now   — called by mf_cg_solve when the burn reaches that
//     threshold unconverged. With no basis held it BUILDS one (the expensive
//     LOBPCG eigensolve); with a basis held it REFRESHES the coarse operator
//     (N_t matvecs + a small dense factor — mandatory; a stale coarse operator is
//     not a deflation for the new system and diverges) and engages. Returns false
//     (and the solve stays plain Jacobi-CG, exact) if a build would bust the
//     memory cap.
//   * geneo_apply        — z += V (V^T A V)^-1 V^T r, reduced space.
//   * geneo_solve_end    — degradation bookkeeping: a reused-basis solve whose
//     DEFLATED iteration count exceeds kGeneoRebuildFactor x the post-rebuild
//     reference schedules a full rebuild, paid at the next solve that clears the
//     gate. Also records the DECLINE (action 5) of a solve the gate kept plain.
//
// State is process-global like the Krylov-recycling space (one production run
// drives its solves from one thread); fea_reset_geneo_basis() (public, fea.hpp)
// drops it at run start, mirroring fea_reset_krylov_recycle_space().

#pragma once

#include <cstddef>

#include "topopt/fea.hpp"  // CgInfo

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
//   against the thousands it then saves. This constant governs the FIRST build on
//   a structure ONLY. Once a basis exists, N_t is known and the ENGAGEMENT GATE
//   below governs, because it is N_t that prices the refresh and no fixed
//   iteration count can see it.
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

// =========================================================================
// THE ENGAGEMENT GATE (handoff 2026-08-02-geneo-disarm).
// =========================================================================
// THE DEFECT IT FIXES. Arming used to be ONE-WAY. `geneo_solve_begin` keyed the
// coarse-operator refresh on a moduli fingerprint; the per-voxel penalised
// modulus moves EVERY design iteration by construction, so the fingerprint
// always differed, the refresh was mandatory on every fallback solve, and — the
// real defect — a held basis DEFLATED FROM ITERATION 0 on every later solve
// regardless of whether that solve was hard. PR 273 measured the bill on the
// maintainer's own run: 87.9 % of a latched design iteration was accelerator
// overhead the iteration counter cannot see (coarse setup 54.7 %, correction
// 26.0 %) on solves running ~215 CG iterations, far under the 500 trigger.
//
// WHY A FIXED ITERATION COUNT CANNOT BE THE GATE. Re-requiring
// kGeneoTriggerIters per solve restores PR 248's intent but not its economics: a
// count cannot see N_t, and N_t is what prices the refresh. The maintainer's run
// measured N_t = 7,588 — a refresh there costs ~27x the entire solve it
// accelerates (PR 275). The same 500 that is generous at N_t = 300 is absurd at
// N_t = 7,588.
//
// THE GATE. Once a basis is held, both terms of PR 275's break-even inequality
// are KNOWN to the run, so the threshold is computed from them per solve, in
// PLAIN-ITERATION EQUIVALENTS:
//
//     engage when   burn_iters  >=  kGeneoRefreshCostPerColumn * N_t
//                                 + engaged_burn
//                                 + kGeneoDeflatedIterCost * engaged_tail
//
// The right-hand side is the MEASURED all-in price of the armed alternative:
// the coarse refresh, plus the plain and deflated legs the last basis-building
// solve actually ran. So the rule reads literally as "engage only once finishing
// plain has already cost more than the whole armed alternative did last time".
// Below the threshold the plain solve is, by the run's own measurements, the
// cheaper way to finish — so it finishes plain and pays GenEO nothing.
//
// That is the ski-rental rule, and it is the optimal deterministic online
// policy: it can lose at most 2x to the offline optimum in either direction —
// at most 2x by waiting too long on a solve GenEO would have rescued, and at
// most 2x by switching on a solve that was about to finish plain.
//
// TWO THINGS THE GATE DOES NOT DO. It does not DISARM GenEO — the basis is kept,
// so a later genuinely hard solve re-engages it with a cheap refresh and never a
// fresh eigensolve. And it does not govern the FIRST build on a structure, nor a
// scheduled degradation REBUILD: both pay an eigensolve, and when a solve may
// pay an eigensolve is the question kGeneoTriggerIters was derived to answer.
// That trigger stands unchanged; a rebuild solve must clear BOTH bars.
//
// WHY THIS IS NOT BLIND TO DIFFICULTY. PR 275 measured the DEFLATED count to be
// flat (191/202/201/213 while the grid grew 15x and plain Jacobi climbed
// 388->977), so N_defl is a poor proxy for how hard a solve is. This gate never
// reads it as one: the quantity compared against the threshold is the PLAIN burn
// of the solve being decided, measured on the undeflated recurrence. The flat
// N_defl enters only on the COST side, where flatness makes it an unusually good
// predictor of what the deflated alternative will cost.
//
// WHY COUNTS AND NOT WALL. A wall-clock threshold would make the arming point
// depend on machine load, so the CG path — and with it the converged field to
// solver tolerance — would stop being reproducible run to run. Every quantity
// above is a deterministic count.
//
// kGeneoRefreshCostPerColumn — plain-iteration equivalents per basis column for
//   ONE coarse-operator refresh. build_coarse_operator costs N_t full operator
//   applies plus an N_t^2 Galerkin assembly and a dense factor; PR 275 prices the
//   whole refresh at "~2 x N_t matvec-equivalents" and a plain CG iteration is
//   one matvec, hence 2.0.
// kGeneoDeflatedIterCost — plain-iteration equivalents per DEFLATED CG iteration
//   (its own matvec plus the basis apply). PR 275's interleaved benchmark timed
//   one apply at ~1.22 ms against a plain matvec at ~1.15 ms => 2.06; PR 273's
//   per-phase medians give 4.70 ms / 2.05 ms = 2.29. 2.0 is the LOW end of both,
//   deliberately: under-pricing GenEO's own cost makes the gate MORE willing to
//   engage, which is the safe direction for the rescue case (AA1).
constexpr double kGeneoRefreshCostPerColumn = 2.0;
constexpr double kGeneoDeflatedIterCost = 2.0;

// =========================================================================
// PROBE OVERRIDE SURFACE — task geneo-standing-preconditioner-probe.
// =========================================================================
// MEASUREMENT ONLY. Nothing in the production build touches any of this: the
// defaults below ARE the tripwire constants above (asserted at first use by
// geneo_probe_defaults_match_tripwire(), and by test_geneo), the setter is
// never called outside core/tests/, and the getter is a plain read of a
// zero-initialised static. So the shipped recipe, the arming decision and the
// byte-identity evidence are all unchanged by its presence.
//
// WHY IT EXISTS. The standing-preconditioner question ("does GenEO pay as an
// ALWAYS-ON accelerator rather than an emergency rescue?") is a question about
// the SHIPPED machinery under different CONSTANTS — the reuse policy, the
// rebuild policy, the fingerprints, the amortisation across design iterations.
// A harness copy of the eigensolve (geneo_twolevel_probe.cpp) cannot answer it,
// because the whole economics live in the lifecycle, not the eigensolve. So the
// probe drives the real provider and overrides the constants from outside.
//
//   trigger_iters  kGeneoTriggerIters. 0 => the deflation arms on the FIRST
//                  fallback solve of a run (the standing posture under test).
//   core_cells     kGeneoCoreCells — the agglomerate tiling (W4).
//   overlap        kGeneoOverlap.
//   block_m        kGeneoBlockM — the LOBPCG block size (caps modes/subdomain).
//   lambda_cut     kGeneoLambdaCut — the GenEO eigenvalue cut, i.e. N_t (W3).
//   eig_weighting  the local eigenproblem's B operator:
//                    0 = D A^Neu D, the shipped GenEO pencil;
//                    1 = diag(D A^Neu D) = D_i^2 diag(K_agglomerate) — the
//                        Alexandersen & Lazarov (arXiv 1411.3923) cheap
//                        weighting (W5a). Spectrally equivalent in their
//                        report; here it is MEASURED, not assumed.
struct GeneoProbeConfig {
  int trigger_iters = kGeneoTriggerIters;
  int core_cells = kGeneoCoreCells;
  int overlap = kGeneoOverlap;
  int block_m = kGeneoBlockM;
  double lambda_cut = kGeneoLambdaCut;
  int eig_weighting = 0;
  // engage_threshold — override the ENGAGEMENT GATE's computed threshold with a
  // fixed plain-iteration burn. -1 (the default, and the shipped behaviour) uses
  // the measured cost model. Exists so a CI test can pin BOTH gate branches
  // deterministically on one small fixture: the decline branch is what this
  // fixture's own numbers produce, and setting this to 0 opens the gate so the
  // ENGAGE branch — refresh, reuse, deflate — is exercised on the same held
  // basis. Never set outside core/tests/.
  int engage_threshold = -1;
};
const GeneoProbeConfig& geneo_probe_config();
void geneo_set_probe_config(const GeneoProbeConfig& cfg);  // tests/harness only
bool geneo_probe_defaults_match_tripwire();  // the shipped recipe is the default

// =========================================================================
// R6 — THE TILING IS PER-AXIS, AND THIS IS WHAT PINS IT (task
// geneo-subdomain-tiling-sweep).
// =========================================================================
// TEST/HARNESS ONLY. Reports what `tile_cores` (geneo.cpp) actually produced
// for a grid and a core size. It does not tile anything itself and no
// production path calls it — it exists so the per-axis rule is asserted against
// the SHIPPED function rather than against a reimplementation of it in a test,
// which is the failure mode that lets a rule pass its own test and break in
// production.
//
// WHY THE RULE NEEDS PINNING AT ALL. `tile_cores` steps each axis
// independently, so a grid of 128x31x118 at core=24 tiles 6 x 2 x 5. The trap
// it must never regress into is keying the tiling to a single scalar derived
// from the grid — `std::min(nx,ny,nz)`, or a cube-root of the voxel count.
// On his part the thin axis is 31 against a long axis of 128, a 4.1:1 slab, so
// a minimum-keyed tiling would size EVERY axis to the thin one and multiply the
// subdomain count — and N_t with it — by roughly the aspect ratio squared. That
// is not hypothetical: handoff 2026-08-10-parametric-level-set records a day
// lost to `GridapTopOpt`'s alpha rule keying on `minimum(el_size)` and
// under-regularising by 5x on exactly this slab.
struct GeneoTileCounts {
  int tx = 0;  // tiles along x
  int ty = 0;  // tiles along y
  int tz = 0;  // tiles along z
  long long total = 0;
  // The SMALLEST extent produced on each axis — the last tile's remainder when
  // the axis does not divide evenly. Reported so a test can tell a genuine
  // per-axis tiling (short remainder tiles) from a padded or clamped one.
  int min_extent_x = 0;
  int min_extent_y = 0;
  int min_extent_z = 0;
};
GeneoTileCounts geneo_tile_counts_for_test(const VoxelGrid& g, int core);

// W5b: force a full basis rebuild at the next geneo_solve_begin (the harness
// calls this at a CONTINUATION-parameter change, the paper's forced-rebuild
// point). Inert unless a basis is held; the shipped degradation policy is
// untouched, this only ADDS a rebuild the harness asked for.
void geneo_request_rebuild();

// Cost instrumentation (cumulative since geneo_reset). The refresh/rebuild
// economics are the whole question, and CG iteration counts do not price them:
// each coarse-operator (re)build costs N_t FULL matvecs on the production
// operator, which at the operating point under test can exceed an entire
// baseline solve.
long long geneo_probe_coarse_matvecs();
double geneo_probe_build_seconds();    // eigensolve + first coarse operator
double geneo_probe_refresh_seconds();  // coarse-operator refreshes only
double geneo_probe_apply_seconds();    // in-CG deflation applies

// What the GenEO preconditioner did on ONE solve (forwarded into CgInfo).
//   action: 0 = off / never engaged, no basis held (plain solve, trigger unmet)
//           1 = REUSED the held basis + coarse operator unchanged (same system)
//           2 = REFRESHED the coarse operator against this system's operator
//           3 = REBUILT the basis (first build, DOF-set change, or degradation)
//           4 = build REFUSED by the memory cap (solve stayed plain, exact)
//           5 = DECLINED by the engagement gate: a basis WAS held, and this
//               solve converged inside `threshold` plain iterations, so paying
//               the refresh + deflation would have cost more than finishing
//               plain. The solve stayed plain Jacobi-CG — exact, and cheaper.
//   dim:    N_t, the coarse-space dimension that preconditioned this solve
//           (on action 5: the dimension of the basis that was NOT engaged)
//   trigger_burn: plain iterations burned before the deflation engaged. On
//           action 5 it is the whole solve's iteration count — the number the
//           gate's decision is graded against.
//   threshold: the engagement gate's burn requirement for this solve, in
//           plain-iteration equivalents. 0 when no basis was held (the
//           kGeneoTriggerIters policy governed instead).
struct GeneoReport {
  int action = 0;
  int dim = 0;
  int trigger_burn = 0;
  int threshold = 0;
};

// ONE arm/disarm decision, as recorded for run_info (handoff
// 2026-08-02-geneo-disarm, bar AA5): the reason AND the numbers it fired on, so
// the next investigation reads the decision rather than re-instrumenting for it.
struct GeneoDecision {
  long long solve = 0;   // fallback-solve index since geneo_reset()
  int action = 0;        // GeneoReport::action — see above
  int burn = 0;          // plain iterations this solve burned before deciding
  int threshold = 0;     // the gate's requirement, plain-iteration equivalents
  int dim = 0;           // N_t the threshold was computed from (0 = no basis)
  int engaged_burn = 0;  // plain leg of the armed cost the threshold was sized on
  int engaged_tail = 0;  // deflated leg of that same measured armed cost
  int iterations = 0;    // the solve's total iteration count
  int converged = 0;
};

// THE ONE MAPPING from the per-solve report into CgInfo. Both matrix-free entry
// points (mf_cg_solve's caller and the multigrid route's Jacobi fallback) copy
// the report through HERE and nowhere else. Written as one function because the
// field-by-field copy had already drifted once: the multigrid site kept
// reporting `geneo_trigger_burn` while silently dropping `geneo_threshold`, so a
// real production run wrote `geneo_threshold = 0` on every row while the unit
// test — which uses the other entry point — read it correctly. A future field
// added to GeneoReport must be added here once, not twice.
inline void geneo_fill_cg_info(CgInfo& diag, const GeneoReport& gr) {
  diag.geneo_dim = gr.dim;
  diag.geneo_action = gr.action;
  diag.geneo_trigger_burn = gr.trigger_burn;
  diag.geneo_threshold = gr.threshold;
}

bool geneo_enabled();
bool geneo_set_enabled(bool enable);  // returns previous
void geneo_reset();                   // drop basis + counters (run start / tests)

// Per-solve lifecycle (see header comment). All no-ops / false when disabled.
// geneo_solve_begin NEVER engages the deflation — it drops a stale-DOF basis and
// resets the per-solve report. Every solve starts plain; geneo_engage_threshold
// says when it may stop being plain.
void geneo_solve_begin(const MatfreeReduced& m, const MfSolveContext& ctx);
// Plain iterations this solve must burn, unconverged, before geneo_engage_now
// may be called. With no basis held this is kGeneoTriggerIters (PR 248's
// stagnation trigger, unchanged, governing the first build on a structure);
// with a basis held it is the ENGAGEMENT GATE's cost threshold. Negative means
// "never" (disabled, or a memory-refused structure).
int geneo_engage_threshold();
// Engage the deflation on a solve that reached the threshold unconverged:
// refresh-and-reuse when a basis is held, a full LOBPCG build when not. False
// leaves the solve plain Jacobi-CG (exact).
bool geneo_engage_now(const MatfreeReduced& m, const MfSolveContext& ctx,
                      int iterations_burned);
void geneo_apply(const double* r, double* z);
void geneo_solve_end(int iterations, bool converged);
GeneoReport geneo_last_report();

// Cumulative-since-reset diagnostics (run_info echo; public faces in fea.hpp).
long long geneo_basis_builds();
long long geneo_coarse_refreshes();
long long geneo_armed_solves();   // fallback solves on which the deflation applied
long long geneo_declined_solves();  // solves the engagement gate kept plain
int geneo_basis_dim();            // N_t currently held (0 = no basis)
std::size_t geneo_basis_bytes();  // stored coarse-basis bytes currently held

// The arm/disarm decision log (AA5). Every TRANSITION between engaging and
// declining is recorded, as is every build, rebuild and memory refusal; runs of
// identical consecutive decisions are not, so the log stays legible on a long
// ladder. Capped at kGeneoDecisionLogCap entries; geneo_decisions_dropped()
// reports what the cap swallowed rather than letting the log lie by omission.
constexpr int kGeneoDecisionLogCap = 256;
int geneo_decision_count();
GeneoDecision geneo_decision_at(int i);
long long geneo_decisions_dropped();

}  // namespace fea_detail
}  // namespace topopt
