#ifndef TOPOPT_COARSEN_HPP
#define TOPOPT_COARSEN_HPP

// The geometric-multigrid COARSENABILITY RULE, in ONE place (handoff:
// multigrid-coarsenability-padding). Two front-ends must agree on it:
//
//   * the SOLVER (src/fea/multigrid.cpp) — build_hierarchy / build_mf_hierarchy
//     coarsen the grid by halving every axis until the coarsest level is small
//     enough to factor directly, and REJECT the hierarchy (falling back to the
//     much slower Jacobi-CG) when they cannot reach that size;
//   * the SEAM (src/voxel/voxelize.cpp) — expand_design_domain pads the solved
//     grid so the solver's coarsening succeeds, by APPENDING void voxels on the
//     high side (handoff 079).
//
// If the seam pads to a rule different from the one the solver enforces, the pad
// silently under-serves the solver and multigrid falls back anyway — the exact
// bug this header exists to prevent (a 128^3 box run fell back to Jacobi-CG on
// every one of 535 iterations because align-8 was assumed sufficient when the
// coarsest level still held ~35k DOFs > the 6000 cap). So the constants and the
// predicate BELOW are the single source of truth; multigrid.cpp derives its
// tuning constants from these, and the seam sizes the pad from this predicate.
//
// THE RULE (why align-8 is not enough at high resolution). Coarsening halves
// each ELEMENT dimension per level and stops at the first axis that is odd or
// would fall below kMgMinCoarseElems. A grid rounded to a multiple of 8 (=2^3)
// guarantees only 3 halvings; the coarsest of those levels has ~N/8^3 elements,
// whose DOF count exceeds kMgCoarseDofCap once N (the total element count) is
// large — i.e. at res ~128 with a design box. The requirement is therefore not
// "each extent is even" but "each extent's 2-adic DIVISIBILITY DEPTH is >= the
// number of MG levels needed to bring the coarsest level under the DOF cap".
// That depth grows with grid size, so the alignment must be COMPUTED, not fixed.
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
inline int round_up_to(int v, int align) {
  if (align <= 1) return v;
  const int rem = v % align;
  return rem ? v + (align - rem) : v;
}

// The alignment expand_design_domain must round each element extent to so the
// multigrid builder can coarsen the grid under the DOF cap. Returns the SMALLEST
// power of two >= `floor_align` for which rounding all three RAW extents
// (rx, ry, rz) to that multiple yields a coarsenable grid (mg_grid_coarsenable).
//
// `floor_align` is the minimum alignment the caller wants regardless (the driver
// passes kDesignBoxCoarsenAlign = 8, preserving the 079 behaviour for the small
// grids that already coarsen at 8; the returned align only GROWS beyond 8 for the
// large grids where 8 was silently insufficient). floor_align <= 1 disables
// rounding entirely (returns floor_align) — the byte-identical legacy path.
inline int required_coarsen_align(int rx, int ry, int rz, int floor_align) {
  if (floor_align <= 1) return floor_align;  // legacy: no rounding
  // Start at the smallest power of two >= floor_align.
  int align = 1;
  while (align < floor_align) align <<= 1;
  // Grow the alignment until the padded grid is coarsenable. Each doubling
  // deepens the guaranteed coarsening by one level, so this terminates quickly
  // (the coarsest level shrinks monotonically); the guard bounds it absolutely.
  for (int guard = 0; guard < 24; ++guard) {
    if (mg_grid_coarsenable(round_up_to(rx, align), round_up_to(ry, align),
                            round_up_to(rz, align)))
      return align;
    align <<= 1;
  }
  return align;
}

}  // namespace topopt

#endif  // TOPOPT_COARSEN_HPP
