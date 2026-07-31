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
// PARITY PADDING (task: multigrid-odd-axis-cliff). A grid whose FINE extents
// contain a single odd axis (e.g. the real 128x31x118 run) used to fail the
// very first halving, silently costing the whole run its multigrid. The solver
// now pads its INDEX SPACE — never the design grid, the physics, or any
// accounting — to the mg_pad_target below: each axis rounded up to a multiple
// of 2^L, where L is the shallowest depth whose coarsest level fits
// kMgCoarseDofCap counting REAL nodes only. The padded nodes are permanently
// inactive (the same treatment fixed/void DOFs already get), so the operator,
// loads, mass, margins and every exported byte are untouched by construction.
// This does NOT relax the all-axes-even rule: the padded extents halve cleanly.
//
// SCOPE (widened by task multigrid-deep-block-pad): the solver engages the pad
// whenever the UNPADDED build would be REJECTED — an odd fine axis, OR an
// all-even grid that blocks deep AND whose ACTUAL active-DOF count at the
// unpadded walk stop exceeds the cap (e.g. a solid-ish 232x64x216 pads to
// 240x64x224, the very shape the withdrawn PR #151 escalation produced). The
// actual-count condition matters: the builder accepts on real active counts,
// so a bound-rejected grid with a SPARSE active set (a thin part in a large
// Empty design-box expanse) already builds today and is left byte-for-byte
// alone — as is every grid that already coarsens. PR #151's harm finding was
// re-tested before this widening: its own regime (sparse design-box fields)
// turns out to build unpadded today and to CARRY under the 128 budget-300
// raise, while the fields the pad genuinely rescues (dense active sets) are
// exactly where the V-cycle works; the one dense-AND-non-contracting corner
// (adversarial checkerboard contrast) pays kMgLatchThreshold stagnated
// attempts and is then latched off, per 127. See the
// 2026-08-01-multigrid-deep-block-pad handoff for the measurements.

// Pure integer arithmetic (no Eigen, no allocation): safe to include from the
// always-built OCCT-free voxel TU and from the Eigen-gated multigrid TU alike.
// (mg_startup_banner formats into a caller buffer via <cstdio>; still no
// allocation.)

#include <cstddef>
#include <cstdint>
#include <cstdio>

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

// The coarsening PLAN for a grid of element dims (ex,ey,ez): how many levels
// the halving loop achieves, where it stops and why, and whether the solver
// would accept the hierarchy. Same walk as mg_grid_coarsenable (whose boolean
// it must always agree with — asserted by test_coarsen_rule), but it names the
// offending axes so a rejection can be reported LOUDLY at run start instead of
// being discovered in run_info.json six hours later.
struct MgCoarsenPlan {
  int levels = 1;             // hierarchy levels achievable (1 = no coarsening)
  bool accepted = false;      // levels >= kMgMinLevels and bound <= kMgCoarseDofCap
  bool odd_stop = false;      // coarsening stopped at an odd axis (vs min-elems)
  int odd_axis_mask = 0;      // bit0=x, bit1=y, bit2=z odd at the stop level
  int stop_ex = 0, stop_ey = 0, stop_ez = 0;  // element dims where halving stopped
  std::int64_t coarse_dof_bound = 0;          // 3 * nodes at the stop level
};

inline MgCoarsenPlan mg_coarsen_plan(int ex, int ey, int ez) {
  MgCoarsenPlan p;
  if (ex < 1 || ey < 1 || ez < 1) return p;
  auto bound = [](int a, int b, int c) {
    return 3 * static_cast<std::int64_t>(a + 1) * static_cast<std::int64_t>(b + 1) *
           static_cast<std::int64_t>(c + 1);
  };
  int nx = ex, ny = ey, nz = ez;
  while (true) {
    const bool odd = (nx & 1) || (ny & 1) || (nz & 1);
    if (odd || nx / 2 < kMgMinCoarseElems || ny / 2 < kMgMinCoarseElems ||
        nz / 2 < kMgMinCoarseElems) {
      p.odd_stop = odd;
      if (odd)
        p.odd_axis_mask =
            ((nx & 1) ? 1 : 0) | ((ny & 1) ? 2 : 0) | ((nz & 1) ? 4 : 0);
      break;
    }
    nx /= 2;
    ny /= 2;
    nz /= 2;
    ++p.levels;
    if (bound(nx, ny, nz) <= kMgCoarseDofCap) break;
  }
  p.stop_ex = nx;
  p.stop_ey = ny;
  p.stop_ez = nz;
  p.coarse_dof_bound = bound(nx, ny, nz);
  p.accepted = p.levels >= kMgMinLevels && p.coarse_dof_bound <= kMgCoarseDofCap;
  return p;
}

// The depth where the UNPADDED halving walk stops: the number of clean
// halvings before an axis goes odd or would drop below kMgMinCoarseElems.
// 0 = no halving possible (an odd fine axis, or a too-small grid). The
// solver's deep-block pad decision (task: multigrid-deep-block-pad) counts
// the ACTUAL active DOFs at this depth to predict whether the unpadded build
// would succeed — the builder's own acceptance is `actual actives at the walk
// stop <= kMgCoarseDofCap` (actives are monotone non-increasing in depth), so
// grids that build today are left byte-identically alone.
inline int mg_unpadded_stop_depth(int ex, int ey, int ez) {
  if (ex < 1 || ey < 1 || ez < 1) return 0;
  int d = 0;
  while (!(ex & 1) && !(ey & 1) && !(ez & 1) && ex / 2 >= kMgMinCoarseElems &&
         ey / 2 >= kMgMinCoarseElems && ez / 2 >= kMgMinCoarseElems) {
    ex /= 2;
    ey /= 2;
    ez /= 2;
    ++d;
  }
  return d;
}

// The parity-padding TARGET. Finds the shallowest halving depth L >= 1 such
// that a hierarchy on index-space extents padded to multiples of 2^L reaches a
// coarsest level under kMgCoarseDofCap — counting REAL nodes only
// (floor(e/2^L)+1 per axis), because the padded index-space nodes are inactive
// and contribute no DOF. Fills (px,py,pz) = the padded extents and returns L;
// returns 0 when no depth works (an axis too small to keep kMgMinCoarseElems
// coarse elements at the depth the cap requires — e.g. a 2x1x1 grid), in which
// case the caller keeps today's rejection. The padded extents halve cleanly L
// times (px = ceil(ex/2^L) * 2^L with ceil(...) >= kMgMinCoarseElems), so the
// all-axes-even rule is satisfied at every level, never relaxed.
inline int mg_pad_target(int ex, int ey, int ez, int& px, int& py, int& pz) {
  if (ex < 1 || ey < 1 || ez < 1) return 0;
  for (int L = 1; L <= 24; ++L) {
    const int step = 1 << L;
    const int cx = (ex + step - 1) / step;
    const int cy = (ey + step - 1) / step;
    const int cz = (ez + step - 1) / step;
    if (cx < kMgMinCoarseElems || cy < kMgMinCoarseElems ||
        cz < kMgMinCoarseElems)
      return 0;  // deeper only shrinks further: no feasible depth exists
    const std::int64_t real_nodes = static_cast<std::int64_t>((ex >> L) + 1) *
                                    static_cast<std::int64_t>((ey >> L) + 1) *
                                    static_cast<std::int64_t>((ez >> L) + 1);
    if (3 * real_nodes <= kMgCoarseDofCap) {
      px = cx * step;
      py = cy * step;
      pz = cz * step;
      return L;
    }
  }
  return 0;
}

// The RUN-START banner (task: multigrid-odd-axis-cliff, O1/O2; scope widened
// by task multigrid-deep-block-pad). Pure decision + text for what the CLI
// should say about multigrid on this solve grid BEFORE the first solve.
// Returns 0 = say nothing (grid coarsenable as-is), 1 = NOTE (the unpadded
// grid would be rejected — an odd fine axis or a deep block — but the solver's
// index-space pad fixes it; name the block and the padded shape), 2 = WARNING
// (the hierarchy WILL be rejected: name the grid, the offending axes and where
// halving stops, the achievable level count, and the concrete remedy shape).
// `pad_enabled` mirrors the solver's parity-pad mode so the banner reports
// what will actually happen. One honest caveat: the banner is geometric (it
// cannot see the void pattern), so on a deep-blocked grid whose ACTUAL active
// set is sparse enough to fit the DOF cap at the walk stop, the solver builds
// UNPADDED (mg_unpadded_stop_active, multigrid.cpp) — the NOTE's headline
// (multigrid engages) still holds; only the padded-shape detail is moot.
inline int mg_startup_banner(int ex, int ey, int ez, bool pad_enabled, char* buf,
                             std::size_t bufsize) {
  if (bufsize > 0) buf[0] = '\0';
  const MgCoarsenPlan plan = mg_coarsen_plan(ex, ey, ez);
  if (plan.accepted) return 0;
  const bool fine_odd = (ex & 1) || (ey & 1) || (ez & 1);
  int px = 0, py = 0, pz = 0;
  const int padL = mg_pad_target(ex, ey, ez, px, py, pz);
  // Odd axes at the level halving stopped, named with their extents there.
  char axes[64];
  {
    int n = 0;
    const int stop[3] = {plan.stop_ex, plan.stop_ey, plan.stop_ez};
    const char* name[3] = {"x", "y", "z"};
    for (int i = 0; i < 3; ++i)
      if (plan.odd_axis_mask & (1 << i))
        n += std::snprintf(axes + n, sizeof(axes) - static_cast<std::size_t>(n),
                           "%s%s=%d", n ? "," : "", name[i], stop[i]);
    if (n == 0) std::snprintf(axes, sizeof(axes), "none");
  }
  if (padL > 0 && pad_enabled) {
    // The pad rescues BOTH rejection modes (task: multigrid-deep-block-pad):
    // an odd FINE axis, and an all-even grid whose halving blocks deep.
    if (fine_odd)
      std::snprintf(buf, bufsize,
                    "NOTE: solve grid %dx%dx%d has odd axis(es) [%s] - geometric "
                    "multigrid pads its INDEX SPACE to %dx%dx%d (up to %d levels). "
                    "The pad is inactive solver bookkeeping only: the design grid, "
                    "loads, mass and margins are untouched.",
                    ex, ey, ez, axes, px, py, pz, padL + 1);
    else
      std::snprintf(buf, bufsize,
                    "NOTE: solve grid %dx%dx%d blocks multigrid coarsening at "
                    "%dx%dx%d (odd axis(es) [%s]) after %d level(s) - the solver "
                    "pads its INDEX SPACE to %dx%dx%d (up to %d levels). The pad "
                    "is inactive solver bookkeeping only: the design grid, loads, "
                    "mass and margins are untouched.",
                    ex, ey, ez, plan.stop_ex, plan.stop_ey, plan.stop_ez, axes,
                    plan.levels, px, py, pz, padL + 1);
    return 1;
  }
  if (padL > 0)
    std::snprintf(
        buf, bufsize,
        "WARNING: geometric multigrid will REJECT its hierarchy on the "
        "%dx%dx%d solve grid - coarsening stops at %dx%dx%d (odd axis(es) "
        "[%s]) after %d level(s), coarsest ~%lld DOF > cap %d. Every linear "
        "solve will fall back to Jacobi-CG (a large slowdown for the whole "
        "run). Remedy: a %dx%dx%d grid would allow %d levels.",
        ex, ey, ez, plan.stop_ex, plan.stop_ey, plan.stop_ez, axes, plan.levels,
        static_cast<long long>(plan.coarse_dof_bound), kMgCoarseDofCap, px, py,
        pz, padL + 1);
  else
    std::snprintf(
        buf, bufsize,
        "WARNING: geometric multigrid will REJECT its hierarchy on the "
        "%dx%dx%d solve grid - too small to host a %d-level hierarchy under "
        "the coarse-DOF cap. Every linear solve will fall back to Jacobi-CG.",
        ex, ey, ez, kMgMinLevels);
  return 2;
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
