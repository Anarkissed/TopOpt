#ifndef TOPOPT_COARSEN_HPP
#define TOPOPT_COARSEN_HPP

// The geometric-multigrid COARSENABILITY RULE, in ONE place. It is the single
// source of truth for two things:
//
//   * the SOLVER's tuning constants (src/fea/multigrid.cpp) — build_hierarchy /
//     build_mf_hierarchy coarsen the grid by halving every axis until the coarsest
//     level is small enough to factor directly, and REJECT the hierarchy (falling
//     back to Jacobi-CG) when they cannot reach that size;
//   * the coarsenability PREDICATE mg_grid_coarsenable — "does a grid of these
//     element dims yield a usable hierarchy under the DOF cap?".
//
// THE RULE. Coarsening halves each ELEMENT dimension per level and stops at the
// first axis that is odd or would fall below kMgMinCoarseElems. A grid rounded to
// a multiple of 8 (=2^3) guarantees only 3 halvings; the coarsest of those levels
// has ~N/8^3 elements, whose DOF count exceeds kMgCoarseDofCap once N (the total
// element count) is large. The requirement is that each extent's 2-adic
// DIVISIBILITY DEPTH is >= the number of MG levels needed to bring the coarsest
// level under the DOF cap. This rule is TRUE and the predicate is used by tests
// and diagnostics.
//
// WALK-BACK NOTE (handoff 122/127). PR #151 also USED this rule to ESCALATE the
// design-box pad (a required_coarsen_align that grew the alignment past 8 to force
// coarsenability), on the theory that the production res-128 fallback was a
// coarsenability failure. A real run disproved that premise: escalating its grid
// from a non-coarsenable 232x64x216 to a coarsenable 240x64x224 let multigrid
// BUILD a hierarchy, but it then STAGNATED and fell back anyway — the failure is
// CONVERGENCE STAGNATION on the high-contrast field, which no amount of padding
// fixes (and forcing the build made that job measurably SLOWER). The escalation
// was withdrawn; expand_design_domain now pads to the FIXED floor and the solver
// guards stagnation directly (multigrid.cpp fast-fail + latch). The rule/predicate
// stay here as documentation and a future gate, but they no longer size the pad.
//
// Pure integer arithmetic (no Eigen, no allocation): safe to include from the
// always-built OCCT-free voxel TU and from the Eigen-gated multigrid TU alike.

#include <cstdint>

namespace topopt {

// --- Multigrid coarsenability constants (source of truth) -----------------
// A coarse axis is not coarsened below this many elements.
inline constexpr int kMgMinCoarseElems = 2;
// The coarsest level is solved by a direct factorisation; cap its DOF count so
// that factorisation stays cheap. A hierarchy whose coarsest level exceeds this
// is rejected by the solver (-> Jacobi-CG fallback).
inline constexpr int kMgCoarseDofCap = 6000;
// Fewer usable levels than this is not worth a V-cycle; the solver falls back.
inline constexpr int kMgMinLevels = 2;

// Would the geometric-multigrid builder accept a hierarchy for a grid whose
// ELEMENT dims are (ex, ey, ez)? Mirrors build_hierarchy's coarsening loop
// (halve while every axis is even and stays >= kMgMinCoarseElems), and treats a
// level as small enough when 3 * (coarse node count) — a guaranteed UPPER BOUND
// on the active coarse DOF count, since void/fixed DOFs only shrink it — is
// within kMgCoarseDofCap. Because the bound is an over-estimate, a `true` here
// is conservative: the real solver's coarsest DOF count is <= this, so it too
// will accept. Requires >= kMgMinLevels levels (i.e. at least one halving).
inline bool mg_grid_coarsenable(int ex, int ey, int ez) {
  if (ex < 1 || ey < 1 || ez < 1) return false;
  int nx = ex, ny = ey, nz = ez, levels = 1;
  while (!(nx & 1) && !(ny & 1) && !(nz & 1) && nx / 2 >= kMgMinCoarseElems &&
         ny / 2 >= kMgMinCoarseElems && nz / 2 >= kMgMinCoarseElems) {
    nx /= 2;
    ny /= 2;
    nz /= 2;
    ++levels;
    const std::int64_t nodes = static_cast<std::int64_t>(nx + 1) *
                               static_cast<std::int64_t>(ny + 1) *
                               static_cast<std::int64_t>(nz + 1);
    if (3 * nodes <= kMgCoarseDofCap) return levels >= kMgMinLevels;
  }
  const std::int64_t nodes = static_cast<std::int64_t>(nx + 1) *
                             static_cast<std::int64_t>(ny + 1) *
                             static_cast<std::int64_t>(nz + 1);
  return levels >= kMgMinLevels && 3 * nodes <= kMgCoarseDofCap;
}

// Round `v` up to the next multiple of `align` (align a power of two, >= 1).
// expand_design_domain uses this with the FIXED design-box alignment floor;
// see the walk-back note above for why the alignment is no longer escalated.
inline int round_up_to(int v, int align) {
  if (align <= 1) return v;
  const int rem = v % align;
  return rem ? v + (align - rem) : v;
}

}  // namespace topopt

#endif  // TOPOPT_COARSEN_HPP
