// Internal (non-installed) header shared by the matrix-free FEA translation
// units: matfree.cpp (the matrix-free operator + matrix-free Jacobi-CG) and
// multigrid.cpp (which reuses the matrix-free apply, diagonal, void gate and
// reduced-system build as the FINE level of the matrix-free multigrid solver).
//
// It exposes the element table, the element-by-element apply, the reduced,
// void-gated matrix-free system, and the matrix-free Jacobi-CG so the multigrid
// solver builds its FINEST level WITHOUT ever assembling the global stiffness K
// — that assembled fine K is what OOMs on large design-box grids. Everything
// here is deliberately Eigen-FREE (like matfree.cpp): no Eigen header, no sparse
// matrix; the only dense storage representing K is the single 24x24 reference
// element stiffness Ke (576 doubles), independent of grid size.
//
// This header is NOT part of the public topopt/ API (which stays Eigen-free per
// ARCHITECTURE §4); it is compiled only into the library.

#pragma once

#include <chrono>
#include <functional>
#include <vector>

#include "topopt/fea.hpp"
#include "topopt/voxel.hpp"

namespace topopt {
namespace fea_detail {

// Monotonic wall clock in milliseconds, for the per-solve phase timing the
// CgInfo t_*_ms fields carry (task 2026-08-02-iteration-phase-timing). STEADY,
// not system_clock: a phase duration must never be perturbed by an NTP step, and
// the difference of two samples is the only thing anyone reads. Pure
// observation — no solver decision consults it, so a timed build converges to
// the identical field as an untimed one.
inline double mf_steady_ms() {
  return std::chrono::duration<double, std::milli>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

// Number of element colours: a 2x2x2 (parity of i,j,k) partition of the regular
// voxel grid. Two elements of the same colour differ by an even offset on at least
// one axis by construction, so on this axis they are >= 2 cells apart and their
// node spans are disjoint — no two same-colour elements share a node. Threading
// the apply one colour at a time is therefore race-free, and because each node is
// written by at most one element per colour, the scatter into that node happens in
// a FIXED colour order (0..7) independent of thread count or scheduling — the
// result is deterministic and identical for 1 vs N threads (see mf_apply_full).
constexpr int kNumColors = 8;

// One solid element: its per-voxel modulus scale and its 24 global DOF indices
// (node-major interleaved, matching hex8_stiffness). The element table is stored
// SORTED BY COLOUR (colour 0 first, then 1, .., 7); within a colour the elements
// keep grid-scan order. `color_offsets` (size kNumColors+1) delimits each colour's
// contiguous range: colour k spans [color_offsets[k], color_offsets[k+1]).
struct MfElem {
  double factor = 1.0;
  int edof[Hex8Stiffness::kDof];
};

// One CUBIC (latticed) element: its three constitutive coefficients and its 24
// global DOF indices. The element stiffness is the EXACT three-block
// decomposition (PR 252, worst rel err 8.5e-16 over 8,696 cases):
//   Ke(C11,C12,C44) = C11*K_A + C12*K_B + C44*K_C
// with K_A/K_B/K_C the three FIXED reference blocks (hex8_cubic_reference_blocks)
// — the same 0/1-D-matrix integrals the production hex8_stiffness_cubic performs,
// split by linearity of Ke in D. Stored in its own colour-sorted table beside the
// isotropic one; an empty table keeps every apply byte-for-byte the scalar path.
struct MfCubElem {
  double a = 0.0, b = 0.0, c = 0.0;  // C11, C12, C44
  int edof[Hex8Stiffness::kDof];
};

// Pointer bundle for the per-voxel lattice arrays of the composite
// isotropic-or-cubic operator (fea_solve_cg_lattice's contract): mask[e] != 0
// selects the cubic element (c11/c12/c44[e]); mask[e] == 0 the isotropic graded
// one. All-null (the default) is the pure scalar path, byte-for-byte.
struct MfLatticeArrays {
  const std::vector<char>* mask = nullptr;
  const std::vector<double>* c11 = nullptr;
  const std::vector<double>* c12 = nullptr;
  const std::vector<double>* c44 = nullptr;
  bool present() const { return mask != nullptr; }
};

// The three fixed reference blocks of the cubic decomposition, integrated by the
// PRODUCTION Gauss rule (hex_element.cpp's integrate_hex8 on the 0/1 D-matrices
// D_A = diag(1,1,1,0,0,0), D_B = normal off-diagonal ones, D_C = diag(0,0,0,1,1,1))
// — so C11*K_A + C12*K_B + C44*K_C recomposes hex8_stiffness_cubic to summation
// roundoff (PR 252 bar d1). Defined in hex_element.cpp beside the integrator.
void hex8_cubic_reference_blocks(double element_size, Hex8Stiffness& KA,
                                 Hex8Stiffness& KB, Hex8Stiffness& KC);

// The cubic-tensor admissibility test of hex8_stiffness_cubic (C44 > 0,
// C11 - C12 > 0, C11 + 2*C12 > 0), shared so the matrix-free build validates
// per-voxel tensors by the SAME rule as the assembled path. Throws
// std::invalid_argument naming `who` on a non-physical tensor.
void hex8_cubic_validate(double C11, double C12, double C44, const char* who);

// Build the solid-element table (edof + factor), SORTED BY COLOUR. `elem_youngs`
// selects the graded path (factor = per-voxel modulus, validated > 0) when
// non-null; otherwise the uniform path (factor = 1, the modulus already baked into
// Ke). If `color_offsets` is non-null it is filled with the kNumColors+1 range
// delimiters. `who` names the caller in thrown messages.
//
// ACTIVE DOMAIN (active-domain phase 1). `active_mask`, when non-null, is a
// grid-indexed per-voxel flag (size == grid.voxel_count()): a solid voxel whose
// entry is 0 contributes NO ELEMENT. This is the ENTIRE mechanism of the active
// domain feature — everything downstream follows from it for free and stays
// EXACT on the surviving system: the M3.1 void-DOF gate drops every DOF no
// surviving element touches, the reduced numbering, the Jacobi diagonal, the
// multigrid hierarchy (built from the element table and the kept DOFs) and
// apply_kgg are all unchanged code operating on the smaller system. The band
// boundary is therefore the EXISTING traction-free free surface — no new solver
// and no new boundary-condition code. A null mask is the pre-feature path,
// byte-for-byte. Throws std::invalid_argument on a size mismatch.
std::vector<MfElem> mf_build_elems(const VoxelGrid& grid,
                                   const std::vector<double>* elem_youngs,
                                   const char* who,
                                   std::vector<int>* color_offsets = nullptr,
                                   const std::vector<char>* active_mask = nullptr);

// Build the CUBIC (latticed) element table, colour-sorted with the same 2x2x2
// parity rule and grid-scan order as mf_build_elems: a solid voxel with
// lattice.mask[e] != 0 (and, when `active_mask` is given, active_mask[e] != 0 —
// the Active Domain skip applies to both lists uniformly) contributes one
// MfCubElem carrying (c11[e], c12[e], c44[e]), validated by the SAME
// admissibility rule as hex8_stiffness_cubic (hex8_cubic_validate). Throws
// std::invalid_argument on a size mismatch or a non-physical tensor.
std::vector<MfCubElem> mf_build_cubic_elems(
    const VoxelGrid& grid, const MfLatticeArrays& lattice, const char* who,
    std::vector<int>* color_offsets = nullptr,
    const std::vector<char>* active_mask = nullptr);

// Set the worker-thread count for the matrix-free element apply. n<=0 selects an
// automatic count (hardware concurrency). Threading is deterministic (see
// kNumColors): the result never depends on the count. Returns the previous value.
int mf_set_thread_count(int n);
int mf_thread_count();  // effective count actually used (>= 1)

// Run `body(lo, hi)` over the index range [begin, end) split into contiguous
// sub-ranges across the SAME persistent worker pool the element apply uses (so no
// second pool is spawned and the P-core pin of handoff 132 governs both).
// `min_per_thread` is the granularity floor: fewer than that many indices per
// worker and the range runs serially, since a dispatch must carry enough work to
// amortise the wakeup.
//
// DETERMINISM IS THE CALLER'S: the split is by contiguous range, so a body whose
// per-range result does not depend on WHICH ranges its neighbours got — e.g. one
// that writes only its own output slice, or that accumulates per-range partials a
// caller then reduces in ascending range order — produces the same answer for any
// thread count. Krylov recycling (recycle.cpp) uses exactly that discipline.
void mf_parallel_ranges(int begin, int end, int min_per_thread,
                        const std::function<void(int, int)>& body);

// Galerkin block cache toggle (handoff 090; public face:
// fea_set_matfree_galerkin_block_cache). Opt-in, default OFF. Read by the
// matrix-free multigrid's coarse-operator build in multigrid.cpp; it changes only
// HOW the purely geometric block W^T Ke W is obtained (compute-once-per-colour vs
// recompute-per-element), never its value, so A1 stays bit-identical.
bool mf_set_galerkin_block_cache(bool enable);
bool mf_galerkin_block_cache_enabled();

// Mixed-precision V-cycle toggle (handoff 092; public face:
// fea_set_matfree_mixed_precision). Opt-in, DEFAULT OFF. Read by the matrix-free
// multigrid solve in multigrid.cpp: when ON the V-cycle PRECONDITIONER runs in
// FP32 (fine apply, Jacobi smoother, restriction, prolongation) while the OUTER CG
// stays FP64 (residual, dot products, x/r/p, the convergence test) and the coarse
// direct solve stays FP64. The FP64 path is byte-unchanged when OFF.
bool mf_set_mixed_precision(bool enable);
bool mf_mixed_precision_enabled();

// Matrix-free CUBIC LATTICE routing toggle (handoff 2026-08-01-multiscale-
// production-wiring; public face: fea_set_matfree_cubic_lattice). Opt-in,
// LIBRARY DEFAULT OFF. Read by fea_solve_cg_lattice (assembly.cpp): when ON the
// lattice-aware solve routes to the matrix-free cubic path (multigrid + GenEO +
// recycling capable, fea_solve_cg_lattice_matfree) instead of assembling; when
// OFF (the default) the assembled Jacobi-CG path runs byte-for-byte unchanged.
// The kernel itself (MfCubElem tables on MatfreeReduced) is independent of this
// toggle — callers of fea_solve_cg_lattice_matfree get it regardless; the toggle
// only decides the ROUTE taken by the pre-existing entry point.
bool mf_set_cubic_lattice(bool enable);
bool mf_cubic_lattice_enabled();

// y = K x over the FULL global stiffness, element-by-element, COLOUR by COLOUR in
// fixed order; each colour's elements are apply'd (optionally across threads, no
// races). `x` and `y` are full ndof vectors; `y` is overwritten (zeroed) then
// accumulated. No assembled K: only the reference Ke and the local 24-DOF
// gather/scatter. `color_offsets` (size kNumColors+1) must match `elems`.
void mf_apply_full(const std::vector<MfElem>& elems,
                   const std::vector<int>& color_offsets, const Hex8Stiffness& Ke,
                   const std::vector<double>& x, std::vector<double>& y);

// Single-precision twin of mf_apply_full (mixed-precision V-cycle, handoff 092).
// Same 8-colour fixed-order, race-free threading, so it is deterministic and
// bit-identical across thread counts; only the arithmetic width is FP32.
void mf_apply_full_f32(const std::vector<MfElem>& elems,
                       const std::vector<int>& color_offsets,
                       const Hex8Stiffness& Ke, const std::vector<float>& x,
                       std::vector<float>& y);

// CUBIC pass of the composite apply: y += sum over cubic elements of
// (a*K_A + b*K_B + c*K_C) x_e — NOT zeroed, call after mf_apply_full. The
// COMBINED-BLOCK kernel shape PR 252 measured at 2.4-2.7x the scalar apply
// (UNDER the 3x flop ratio): per element the three L1-resident reference blocks
// are fused into ONE column-major element block (576 mul-adds), then the
// standard single-block AXPY sweep runs — gather/scatter and the y-write
// traffic are shared with the scalar kernel's shape, and one 24-double
// accumulator never spills the NEON register file (the 3-accumulator variant
// measured 3.3-3.8x from exactly those spills). Colour-by-colour in fixed order
// on the shared worker pool, so the composite apply stays bit-identical for any
// thread count (same argument as mf_apply_full; the iso pass completes before
// the cubic pass starts, so the per-node accumulation order is fixed).
void mf_apply_cubic_add(const std::vector<MfCubElem>& elems,
                        const std::vector<int>& color_offsets,
                        const Hex8Stiffness& KA, const Hex8Stiffness& KB,
                        const Hex8Stiffness& KC, const std::vector<double>& x,
                        std::vector<double>& y);

// The reduced, void-gated system in matrix-free form. `kept_global[kg]` is the
// global DOF of surviving free DOF kg; `apply_kgg` realises y_g = K_gg x_g by
// scatter -> full apply -> gather, reusing full-length scratch across iterations.
// This is exactly K restricted to the kept DOFs (fixed and void DOFs carry a zero
// in the scattered vector and are never read back), so it equals the assembled
// reduced operator DOF-for-DOF.
struct MatfreeReduced {
  std::vector<MfElem> elems;
  std::vector<int> color_offsets;   // kNumColors+1 delimiters into elems
  Hex8Stiffness Ke;
  // CUBIC (latticed) element table + the three reference blocks (multiscale
  // production wiring). Empty/unbuilt on every scalar path — has_cubic == false
  // keeps apply_kgg_raw byte-for-byte the pre-cubic apply.
  std::vector<MfCubElem> cub_elems;
  std::vector<int> cub_color_offsets;  // kNumColors+1 delimiters into cub_elems
  Hex8Stiffness KA, KB, KC;            // built only when a lattice build ran
  bool has_cubic = false;
  int ndof = 0;
  int ng = 0;                       // surviving free-DOF count
  std::vector<int> kept_global;     // kg -> global DOF
  std::vector<double> up;           // full field seeded with prescribed values
  std::vector<double> rg;           // ng reduced RHS
  std::vector<double> invdiag;      // ng Jacobi inverse diagonal (matrix-free)
  // Reused full-length scratch for the matvec.
  mutable std::vector<double> xfull, yfull;
  // Reused full-length FP32 scratch for the mixed-precision matvec, sized lazily
  // on first use so the FP64-only path never allocates it (handoff 092).
  mutable std::vector<float> xfull_f, yfull_f;

  void apply_kgg(const std::vector<double>& xg, std::vector<double>& yg) const;
  // Raw-pointer core of apply_kgg: yg[0..ng) = K_gg xg[0..ng). `xg` and `yg` must
  // each point at ng contiguous doubles (yg is fully overwritten). Lets a caller
  // holding contiguous storage (e.g. an Eigen vector's .data()) drive the matvec
  // with NO marshalling copies — the multigrid fine matvec relies on this to reuse
  // the caller's buffers across CG/V-cycle iterations. Same arithmetic (and thus
  // same result, bit-for-bit) as the std::vector overload.
  void apply_kgg_raw(const double* xg, double* yg) const;
  // FP32 core of the reduced matvec: yg[0..ng) = K_gg xg[0..ng), driven off
  // contiguous float storage (handoff 092). Same operator, single precision.
  // The FP32 kernel carries NO cubic pass: it throws std::logic_error when
  // has_cubic (the mixed-precision V-cycle is guarded off on cubic systems in
  // solve_mgcg_matfree — see the guard there — so this is a tripwire, not a
  // reachable path).
  void apply_kgg_raw_f32(const float* xg, float* yg) const;
};

// Build the matrix-free reduced system. Mirrors assemble_reduced + the M3.1 gate
// (void_dof_survivors) but WITHOUT assembling a sparse matrix. On a void-gate
// rejection it sets `*info` (converged=false, 0 iterations) and throws, matching
// solve_reduced_cg. `who` names the caller in thrown messages.
// `active_mask` (active-domain phase 1) is forwarded verbatim to mf_build_elems;
// null keeps the pre-feature build byte-for-byte.
//
// `lattice` (multiscale production wiring), when non-null and present(), selects
// the COMPOSITE isotropic-or-cubic build: a solid voxel with mask[e] != 0
// contributes a cubic element (its scalar modulus is never read — matching
// fea_solve_cg_lattice's contract, where analyze.cpp passes 0 there); every
// other solid voxel contributes the isotropic graded element exactly as today.
// The void-DOF gate, the Jacobi diagonal and the K*up apply all run over BOTH
// element lists. Null (the default) is the pre-cubic build byte-for-byte.
MatfreeReduced mf_build_reduced(const VoxelGrid& grid, double youngs_modulus,
                                double poisson,
                                const std::vector<DirichletBC>& bcs,
                                const std::vector<NodalLoad>& loads,
                                const std::vector<double>* elem_youngs,
                                const char* who, CgInfo* info,
                                const std::vector<char>* active_mask = nullptr,
                                const MfLatticeArrays* lattice = nullptr);

// What Krylov recycling (handoff 133) did to ONE solve: the number of recycle
// columns that actually preconditioned it, and the operator applies charged to
// building E = U^T A U. Both 0 when recycling is off or no basis existed yet.
// A solve that runs MG-CG and then falls back to Jacobi-CG pays setup twice, so
// the caller ACCUMULATES setup_matvecs across the attempts rather than
// overwriting — the reported figure is the honest total charged to the solve.
struct RecycleReport {
  int dim = 0;
  int setup_matvecs = 0;
};

// ---------------------------------------------------------------------------
// EXTERNAL ADDITIVE PRECONDITIONER HOOK (matrix-free GenEO two-level, handoff
// 2026-07-29 phase 2). OPT-IN, DEFAULT NULL => byte-identical.
//
// The hook is a SECOND SPD additive correction the Jacobi-CG loop applies right
// after (and independently of) the base Jacobi preconditioner and the Krylov
// recycling correction:  z <- D^-1 r + [recycle] + hook(m, ctx, r, .).  It exists
// so an EXTERNAL provider (a measurement harness that links Eigen — the matrix-free
// library stays Eigen-free) can inject the two-level GenEO additive-Schwarz
// preconditioner M2^-1 = R_0^T A_0^-1 R_0 + sum_i R_i^T A_i^-1 R_i without the
// eigensolve / decomposition machinery entering the production library. Because
// every SPD additive term keeps the compound preconditioner SPD, the hook can only
// change the ITERATION COUNT, never the converged field or the stopping test — the
// exact-fallback contract is untouched. With no hook installed the branch is never
// entered and mf_cg_solve is byte-for-byte the pre-hook path (the tripwire constant
// kMatfreeExternalPrecondDefaultOff in topopt/fea.hpp documents the default-off
// invariant). The hook lives on the Jacobi-CG regime ONLY (the stagnation
// fallback), so a healthy multigrid solve never invokes it.
//
// The hook receives the reduced system `m` (operator apply_kgg, invdiag, kept_global,
// ng) plus a `MfSolveContext` giving the grid and per-voxel moduli it needs to build
// the coarse basis / subdomain decomposition. It ADDS its correction into `z`.
struct MfSolveContext {
  const VoxelGrid* grid = nullptr;
  // Per-voxel modulus vector (graded path), or null for the uniform path in which
  // case `youngs_modulus` is the single modulus. `poisson` is nu.
  const std::vector<double>* elem_youngs = nullptr;
  double youngs_modulus = 0.0;
  double poisson = 0.0;
  // Per-voxel lattice arrays of the composite cubic operator (all-null on every
  // scalar path). GenEO reads these BOTH to assemble its local subdomain
  // operators from the true composite blocks AND in its moduli fingerprint: two
  // designs sharing the same scalar field but different cubic tensors are
  // DIFFERENT operators, and a held basis's coarse operator must refresh — a
  // fingerprint blind to these fields would silently reuse a stale coarse
  // operator (the phase-2 §P6 divergence).
  MfLatticeArrays lattice;
};
using MfPrecondHook = std::function<void(const MatfreeReduced& m,
                                         const MfSolveContext& ctx, const double* r,
                                         double* z)>;
// Install (or clear, with a default-constructed hook) the process-global external
// additive preconditioner. Returns the previous hook. Thread-global, like the other
// matrix-free toggles; intended to be set once around a solve/run and cleared after.
MfPrecondHook mf_set_precond_hook(MfPrecondHook hook);
bool mf_precond_hook_installed();

// Matrix-free Jacobi-preconditioned CG on the reduced system `m`, replicating
// Eigen's ConjugateGradient<..., DiagonalPreconditioner> algorithm and relative-
// residual criterion (sqrt(||r||^2/||rhs||^2) <= tolerance). `x` is seeded (warm
// start or zero) and holds the solution on the kept DOFs on return. This is the
// EXACT matrix-free solve; the multigrid path uses it as its exact fallback.
//
// When Krylov recycling is enabled the SPD additive coarse correction wraps the
// Jacobi preconditioner (see topopt/fea.hpp and recycle.hpp); `rec` receives the
// per-solve diagnostics. With recycling off this function is byte-unchanged.
//
// `ctx` (default null) carries the grid + moduli the external preconditioner hook
// needs; it is consulted ONLY when a hook is installed (mf_set_precond_hook). With
// no hook installed `ctx` is never read, so the solve is byte-identical whether or
// not a context is supplied.
// Per-phase wall timing of ONE matrix-free Jacobi-CG solve, in milliseconds
// (task 2026-08-02-iteration-phase-timing). Optional out-param: null (the
// default) skips every clock read, so an untimed caller is byte-for-byte the
// pre-timing path. The split exists because `iters_out` is not a cost — the
// GenEO coarse-operator refresh runs N_t operator applies BEFORE the recurrence
// starts and never moves the iteration counter.
struct MfCgTimes {
  double geneo_setup_ms = 0.0;  // geneo_solve_begin + any in-solve trigger build
  double geneo_apply_ms = 0.0;  // the coarse correction, summed over iterations
  double recycle_ms = 0.0;      // recycle session setup + per-iteration augment
  double cg_ms = 0.0;           // the recurrence itself (matvecs + vector ops)
};

void mf_cg_solve(const MatfreeReduced& m, double tolerance, int max_iterations,
                 std::vector<double>& x, int& iters_out, double& error_out,
                 bool& converged_out, RecycleReport* rec = nullptr,
                 const MfSolveContext* ctx = nullptr,
                 MfCgTimes* times = nullptr);

// ---------------------------------------------------------------------------
// MULTIGRID COMPONENT TUNING (task: multigrid-component-sweep) — a HARNESS-ONLY
// override surface for the V-cycle's shipped recipe. PARAMETERISED, NOT
// RE-TUNED: every field below defaults to the constant production has always
// run, so an unset process is byte-for-byte the pre-task solver. The tripwire
// in tests/unit/test_mg_tuning.cpp asserts each effective default against the
// shipped LITERAL, so neither a stray override left installed by a probe nor a
// drifting constant can change what production runs without failing a test.
//
// The recipe these override (multigrid.cpp, unchanged):
//   omega 0.6 damped SCALAR Jacobi, 1 pre + 1 post sweep, V-cycle only, no
//   extra coarse-level smoothing, hierarchy depth set by the DOF cap.
//
// WHY these knobs. A 2025 SMO study (doi 10.1007/s00158-025-04102-y) reports
// iteration counts exploding when a topology-optimisation multigrid goes from
// two grids to four, and names extra coarse-level smoothing or a W-cycle as the
// fix; Peetz & Elbanna (SMO 63:835-853) use weighted POINT-BLOCK Jacobi (one
// 3x3 nodal block per node, weight 0.5) rather than the scalar diagonal this
// codebase smooths with. Each is a hypothesis about why this project's
// high-contrast design-box fields stagnate; each needs to be MEASURED here, on
// a fixture that actually stagnates, before anything is proposed.
//
// SYMMETRY IS PRESERVED BY CONSTRUCTION for every combination. The cycle stays
// a valid CG preconditioner as long as (a) the smoother is A-self-adjoint —
// both the scalar diagonal and the symmetric 3x3 nodal-block inverse are — and
// (b) pre and post sweep counts are equal at every level. `coarse_extra_smooth`
// adds to BOTH, and the gamma-cycle's error propagator S^k T^gamma S^k is
// A-self-adjoint whenever T = I - P B P^T A is (a repeated factor commutes with
// itself). CG's existing pAp<=0 breakdown guard remains the backstop.
enum class MgSmoother {
  ScalarJacobi = 0,      // x <- x + omega*Dinv.*(b - A x)  (SHIPPED)
  PointBlockJacobi = 1,  // per-node 3x3 block inverse (Peetz & Elbanna)
};

struct MgTuning {
  // Smoother weight. 0.6 is the shipped damped-Jacobi omega; Peetz & Elbanna's
  // point-block recipe uses 0.5. ONE field, so sweep E moves one number.
  double omega = 0.6;
  // Pre- and post-smoothing sweeps at the FINE level. Kept equal by the caller;
  // the sweep never sets them apart (unequal counts break V-cycle symmetry).
  int pre_smooth = 1;
  int post_smooth = 1;
  // Extra sweeps added to BOTH pre and post on every level BELOW the finest —
  // the SMO paper's specific fix, distinct from raising the uniform count.
  int coarse_extra_smooth = 0;
  // Coarse-grid correction repetitions per level: 1 = V-cycle, 2 = W-cycle.
  int cycle_gamma = 1;
  // Total hierarchy levels (fine included). 0 = whatever the builder's DOF cap
  // produces, which is what production runs.
  int max_levels = 0;
  // Keep coarsening past the DOF cap until an axis blocks — the DEEPEST
  // hierarchy the builder can express. Off = stop at the first level under the
  // cap, as shipped.
  bool deepest = false;
  // Direct-solve size cap for the coarsest level. Sweeping DOWN to 2 or 3
  // levels leaves a much larger coarsest operator, which the shipped cap would
  // reject outright; raising it is what makes those cells measurable at all.
  int coarse_dof_cap = 6000;  // == kMgCoarseDofCap
  MgSmoother smoother = MgSmoother::ScalarJacobi;
};

// The tuning in force on THIS thread. Thread-local, like the stagnation latch
// and the parity-pad mode, because the driver issues a run's solves on one
// thread. Production never calls the setter, so this always returns the
// defaults above.
const MgTuning& mg_tuning();
void mg_set_tuning(const MgTuning& t);  // tests/harness only
void mg_reset_tuning();                 // restore the shipped recipe

}  // namespace fea_detail
}  // namespace topopt
