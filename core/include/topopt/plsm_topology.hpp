// plsm_topology.hpp — ★ THE VOID'S COMPONENT COUNT AND EULER CHARACTERISTIC, AS
// REPORTED DIAGNOSTICS ON EVERY PARAMETRIC RUN.
//
// ★★ THIS SHIPS THE COUNTERS AND NOT THE CONSTRAINT, AND THAT IS A MEASURED
// DECISION RATHER THAN A SCOPE CUT. The `plsm-monotone-no-nucleation` task built
// a topological constraint — the void's component count may never increase,
// repaired by reverting the offending coefficients — and measured it over eight
// arms at matched iteration 60. ★ It bought 1.7% of the internal surface. In the
// same study a change of SEED bought 9.4% and cost nothing, so the constraint
// does not justify a flag on the production path.
//
// ★ THE COUNTERS EARNED THEIR PLACE IN THAT SAME STUDY, AND FOR THE OPPOSITE
// REASON: they cost milliseconds and they MADE EVERY OTHER FINDING LEGIBLE. Two
// examples, both of which reversed a premise that had already been written down:
//
//   * ★ THE VOID'S COMPONENT COUNT FALLS OVER A RUN, IT DOES NOT RISE. In all
//     eight arms it spiked in the first ~6 iterations as the seed dissolved
//     (87 -> 439) and then decayed to 41. The constraint was policing a quantity
//     that was already decreasing. Without the counter, "the level set nucleates
//     holes, so the hole count must be growing" would have stood.
//
//   * ★ AND THE INCREASE THAT DOES OCCUR IS SPLITTING, NOT NUCLEATION. Of the
//     control's largest jump (+425 components), 3 were genuinely new and 422
//     were existing void FRAGMENTING as solid bridged across it. A void split is
//     a solid merge, which is classically legal.
//
// ── ★ AND THE 3D CAVEAT, WHICH IS REPORTED AND NOT HIDDEN ───────────────────
//
// In 3D a hole can be TUNNELLED through material between two pieces of existing
// boundary without any new component ever appearing: the void stays connected
// and its genus rises. A component count alone would call that no change at all.
//
// So this header also computes the EULER CHARACTERISTIC of the void, exactly, as
// an alternating sum over the cubical complex:
//
//     chi = #vertices - #edges + #faces - #cubes
//
// and chi = b0 - b1 + b2 (components - tunnels + cavities). With b0 counted
// directly and b2 counted as the void pockets with no path out, b1 — THE TUNNEL
// COUNT — falls out as b0 + b2 - chi.
//
// ── ★ THE ESCAPE RULE IS THE MANUFACTURING ONE, NOT A SECOND OPINION ────────
//
// `b2` needs a definition of "enclosed", and this repository already has one:
// `lattice_void.hpp`'s enclosed-void rule, which is the standard additive-
// manufacturing constraint. Its two commitments are adopted here verbatim rather
// than re-derived, so a cavity this header counts and a cavity the lattice pass
// REFUSES on are the same object:
//
//   * ★ THE VOID WALK IS 6-CONNECTED, because the SOLID walk (`walk_load_path`)
//     is 26-connected and in 3D digital topology the complementary sets must
//     take complementary adjacencies — or both a solid path and a void path can
//     cross the SAME diagonal. Two voxels meeting only at an edge or a corner
//     share ZERO AREA; nothing drains through a measure-zero contact.
//
//   * ★ THE EXTERIOR IS THE GRID'S SIX BOUNDARY PLANES, reached through the FULL
//     escape network — which includes the `Empty` voxels OUTSIDE the part, since
//     those are exactly where a fluid already is. A pocket is enclosed when the
//     6-connected not-printed set gives it no route to a boundary plane.
//
// ★ THAT SECOND COMMITMENT IS A DELIBERATE DIFFERENCE FROM THE SANDBOX THIS
// HEADER COMES FROM, AND IT IS NAMED HERE. `plsm_topology.hpp` in the Stage A
// sandbox marks a component open when it touches ANY voxel outside its
// `in_region` predicate — which includes FROZEN SOLID. A cavity walled in by the
// anchor pad or a protected face is then counted as drainable, and it is not:
// frozen material is material. The defect is reported separately with its own
// measurement; what ships here does not carry it.

#ifndef TOPOPT_PLSM_TOPOLOGY_HPP_
#define TOPOPT_PLSM_TOPOLOGY_HPP_

#include <algorithm>
#include <cstddef>
#include <vector>

#include "topopt/plsm_kernel.hpp"  // plsm_at

namespace topopt {

struct PlsmVoidTopology {
  // b0 of the void INSIDE THE PART (not-printed, non-Empty), 6-connected.
  long long components = 0;
  // Euler characteristic of that void's cubical complex.
  long long chi = 0;
  // b2 — pockets with no 6-connected route out through the not-printed set.
  long long cavities = 0;
  // b1 = b0 + b2 - chi. ★ If this rises while `components` does not, a hole was
  // tunnelled rather than nucleated, and that is a finding rather than a bug.
  long long tunnels = 0;
  // The trapped material, for the rows R6 asks for.
  long long sealed_voxels = 0;
  double sealed_volume_mm3 = 0.0;
  // The denominator, so a count is never read without the set it counts over.
  long long void_voxels = 0;
};

// Union-find over the voxel lattice. Half a million cells is milliseconds.
struct PlsmDisjointSet {
  std::vector<int> p;
  explicit PlsmDisjointSet(std::size_t n) : p(n) {
    for (std::size_t i = 0; i < n; ++i) p[i] = static_cast<int>(i);
  }
  int find(int a) {
    while (p[static_cast<std::size_t>(a)] != a) {
      p[static_cast<std::size_t>(a)] =
          p[static_cast<std::size_t>(p[static_cast<std::size_t>(a)])];
      a = p[static_cast<std::size_t>(a)];
    }
    return a;
  }
  void join(int a, int b) {
    a = find(a);
    b = find(b);
    if (a != b) p[static_cast<std::size_t>(a)] = b;
  }
};

// `occ` is the analysis occupancy field, `iso` the printed threshold the
// certificate and the export both read (0.5), and `in_part[v]` is
// `tags[v] != VoxelTag::Empty`. Nothing here reads a mask: a keep-out is void
// and frozen solid is printed, which is what both of those already are in `occ`.
//
// Deterministic and READ-ONLY on every input. O(voxel_count).
inline PlsmVoidTopology plsm_void_topology(int nx, int ny, int nz, double h,
                                           const std::vector<double>& occ,
                                           double iso,
                                           const std::vector<char>& in_part) {
  PlsmVoidTopology t;
  const std::size_t n = static_cast<std::size_t>(nx) *
                        static_cast<std::size_t>(ny) *
                        static_cast<std::size_t>(nz);
  if (occ.size() != n || in_part.size() != n) return t;

  // Two sets, and they are NOT the same set. `isvoid` is the void the counters
  // describe — inside the part. `escape` additionally carries the Empty voxels,
  // because that is where the outside already is, and it is what decides whether
  // a pocket can drain.
  std::vector<char> isvoid(n, 0), escape(n, 0);
  for (std::size_t v = 0; v < n; ++v) {
    const bool printed = occ[v] > iso;
    escape[v] = printed ? 0 : 1;
    isvoid[v] = (in_part[v] && !printed) ? 1 : 0;
    if (isvoid[v]) ++t.void_voxels;
  }

  auto at = [&](int i, int j, int k) { return plsm_at(nx, ny, i, j, k); };

  // ── b0, over the void INSIDE the part ─────────────────────────────────────
  PlsmDisjointSet dv(n);
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < nx; ++i) {
        const std::size_t v = at(i, j, k);
        if (!isvoid[v]) continue;
        if (i > 0 && isvoid[at(i - 1, j, k)])
          dv.join(static_cast<int>(v), static_cast<int>(at(i - 1, j, k)));
        if (j > 0 && isvoid[at(i, j - 1, k)])
          dv.join(static_cast<int>(v), static_cast<int>(at(i, j - 1, k)));
        if (k > 0 && isvoid[at(i, j, k - 1)])
          dv.join(static_cast<int>(v), static_cast<int>(at(i, j, k - 1)));
      }

  // ── the escape network, and which of its components reach a boundary plane ─
  PlsmDisjointSet de(n);
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < nx; ++i) {
        const std::size_t v = at(i, j, k);
        if (!escape[v]) continue;
        if (i > 0 && escape[at(i - 1, j, k)])
          de.join(static_cast<int>(v), static_cast<int>(at(i - 1, j, k)));
        if (j > 0 && escape[at(i, j - 1, k)])
          de.join(static_cast<int>(v), static_cast<int>(at(i, j - 1, k)));
        if (k > 0 && escape[at(i, j, k - 1)])
          de.join(static_cast<int>(v), static_cast<int>(at(i, j, k - 1)));
      }
  std::vector<char> reaches(n, 0);
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < nx; ++i) {
        if (i != 0 && j != 0 && k != 0 && i != nx - 1 && j != ny - 1 &&
            k != nz - 1)
          continue;
        const std::size_t v = at(i, j, k);
        if (escape[v]) reaches[static_cast<std::size_t>(de.find(
                           static_cast<int>(v)))] = 1;
      }

  // ── b0 and b2 together, one pass over the void's roots ────────────────────
  std::vector<int> seen(n, 0);
  for (std::size_t v = 0; v < n; ++v) {
    if (!isvoid[v]) continue;
    const int r = dv.find(static_cast<int>(v));
    if (!seen[static_cast<std::size_t>(r)]) {
      seen[static_cast<std::size_t>(r)] = 1;
      ++t.components;
      // A void component lies entirely inside ONE escape component (it is a
      // subset of the escape set and the adjacency is the same), so the root's
      // escape verdict is the whole component's.
      if (!reaches[static_cast<std::size_t>(de.find(static_cast<int>(v)))])
        ++t.cavities;
    }
    if (!reaches[static_cast<std::size_t>(de.find(static_cast<int>(v)))])
      ++t.sealed_voxels;
  }
  t.sealed_volume_mm3 = static_cast<double>(t.sealed_voxels) * h * h * h;

  // ── ★ THE EULER CHARACTERISTIC, EXACTLY, over the cubical complex ─────────
  //
  // Each void voxel is a closed unit cube. A k-cell belongs to the complex iff
  // ANY incident voxel is void, so each cell is counted ONCE by scanning the
  // (nx+1) x (ny+1) x (nz+1) vertex lattice and asking, for each cell anchored
  // there, whether any of the voxels it touches is void. No cell is double
  // counted and none is missed — which an inclusion-exclusion over voxels would
  // get wrong at the boundary.
  auto vox = [&](int i, int j, int k) -> bool {
    if (i < 0 || j < 0 || k < 0 || i >= nx || j >= ny || k >= nz) return false;
    return isvoid[at(i, j, k)] != 0;
  };
  long long nv = 0, ne = 0, nf = 0, nc = 0;
  for (int k = 0; k <= nz; ++k)
    for (int j = 0; j <= ny; ++j)
      for (int i = 0; i <= nx; ++i) {
        bool any = false;
        for (int dk = -1; dk <= 0 && !any; ++dk)
          for (int dj = -1; dj <= 0 && !any; ++dj)
            for (int di = -1; di <= 0 && !any; ++di)
              if (vox(i + di, j + dj, k + dk)) any = true;
        if (any) ++nv;
        if (i < nx) {
          bool a = false;
          for (int dk = -1; dk <= 0 && !a; ++dk)
            for (int dj = -1; dj <= 0 && !a; ++dj)
              if (vox(i, j + dj, k + dk)) a = true;
          if (a) ++ne;
        }
        if (j < ny) {
          bool a = false;
          for (int dk = -1; dk <= 0 && !a; ++dk)
            for (int di = -1; di <= 0 && !a; ++di)
              if (vox(i + di, j, k + dk)) a = true;
          if (a) ++ne;
        }
        if (k < nz) {
          bool a = false;
          for (int dj = -1; dj <= 0 && !a; ++dj)
            for (int di = -1; di <= 0 && !a; ++di)
              if (vox(i + di, j + dj, k)) a = true;
          if (a) ++ne;
        }
        if (i < nx && j < ny && (vox(i, j, k) || vox(i, j, k - 1))) ++nf;
        if (i < nx && k < nz && (vox(i, j, k) || vox(i, j - 1, k))) ++nf;
        if (j < ny && k < nz && (vox(i, j, k) || vox(i - 1, j, k))) ++nf;
        if (i < nx && j < ny && k < nz && vox(i, j, k)) ++nc;
      }
  t.chi = nv - ne + nf - nc;
  t.tunnels = t.components + t.cavities - t.chi;
  return t;
}

}  // namespace topopt

#endif  // TOPOPT_PLSM_TOPOLOGY_HPP_
