// plsm_topology.hpp — ★ THE TOPOLOGICAL CONSTRAINT: THE VOID'S COMPONENT COUNT
// MAY NEVER INCREASE. Plus the Euler characteristic, because in 3D the component
// count alone is a weaker guarantee than it sounds.
//
// ═══ WHY THIS IS NOT THE SPATIAL MASK PR 326 REFUTED ════════════════════════
//
// PR 326 froze coefficients OUTSIDE A BAND around the interface and bought 1.6%
// of the surface. Its own diagnosis was that the mask "can only prevent
// nucleation where there is DEEP SOLID for a hole to open in. In a design this
// finely branched there is almost none… the mask arrives after the structure it
// was meant to prevent." ★ THAT IS A SPATIAL CONSTRAINT AND IT IS GEOMETRIC.
//
// This is a TOPOLOGICAL one. It does not ask where a coefficient sits; it asks
// whether the step CREATED A COMPONENT. It cannot arrive late, because it is
// evaluated every iteration from the first, and it does not care whether deep
// solid exists — only whether the void just gained a piece.
//
// ═══ ★ AND THE 3D CAVEAT, WHICH IS REPORTED AND NOT HIDDEN ══════════════════
//
// In 3D a hole can be TUNNELLED through material between two pieces of existing
// boundary without any new component ever appearing: the void stays connected
// and its genus rises. Component monotonicity would call that legal.
//
// So this header also computes the EULER CHARACTERISTIC of the void, exactly,
// as an alternating sum over the cubical complex:
//
//     chi = #vertices - #edges + #faces - #cubes
//
// and chi = b0 - b1 + b2 (components - tunnels + cavities). With b0 counted
// directly and b2 counted as the enclosed void's complement components, b1 —
// THE TUNNEL COUNT — falls out as b0 + b2 - chi. ★ If b1 rises while b0 does
// not, the constraint is being satisfied and evaded at the same time, and that
// is a finding rather than a bug.

#ifndef TOPOPT_TESTS_HARNESS_PLSM_TOPOLOGY_HPP_
#define TOPOPT_TESTS_HARNESS_PLSM_TOPOLOGY_HPP_

#include <algorithm>
#include <cstddef>
#include <vector>

struct VoidTopology {
  int components = 0;      // b0 of the void, 6-connected
  long long chi = 0;       // Euler characteristic of the void's cubical complex
  int cavities = 0;        // b2: void pockets fully enclosed by solid
  long long tunnels = 0;   // b1 = b0 + b2 - chi
  std::vector<int> label;  // per voxel, 0 = not void, else component id (1-based)
};

// Union-find over the voxel lattice. 468,224 cells is milliseconds.
struct DisjointSet {
  std::vector<int> p;
  explicit DisjointSet(std::size_t n) : p(n) {
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
    a = find(a); b = find(b);
    if (a != b) p[static_cast<std::size_t>(a)] = b;
  }
};

// ★ 6-CONNECTIVITY FOR THE VOID, and that is not arbitrary: PR 305's
// void-escape rule uses 6-connected void precisely because the solid is
// 26-connected, and a set and its complement must not both be counted with the
// generous adjacency or a checkerboard is simultaneously connected and not.
// Using the repository's existing convention keeps this measurement comparable
// with the lattice track's.
//
// `in_region` selects where void is even meaningful — the ACTIVE set. Frozen
// solid is never void and the region outside the CAD is not a hole.
template <typename InRegion>
VoidTopology void_topology(const Dims& d, const std::vector<double>& occ,
                           InRegion in_region, bool want_chi) {
  VoidTopology t;
  const std::size_t n = occ.size();
  t.label.assign(n, 0);
  std::vector<char> isvoid(n, 0);
  for (int k = 0; k < d.nz; ++k)
    for (int j = 0; j < d.ny; ++j)
      for (int i = 0; i < d.nx; ++i) {
        const std::size_t v = d.at(i, j, k);
        isvoid[v] = (in_region(v) && !(occ[v] > 0.5)) ? 1 : 0;
      }

  DisjointSet ds(n);
  for (int k = 0; k < d.nz; ++k)
    for (int j = 0; j < d.ny; ++j)
      for (int i = 0; i < d.nx; ++i) {
        const std::size_t v = d.at(i, j, k);
        if (!isvoid[v]) continue;
        if (i > 0 && isvoid[d.at(i - 1, j, k)])
          ds.join(static_cast<int>(v), static_cast<int>(d.at(i - 1, j, k)));
        if (j > 0 && isvoid[d.at(i, j - 1, k)])
          ds.join(static_cast<int>(v), static_cast<int>(d.at(i, j - 1, k)));
        if (k > 0 && isvoid[d.at(i, j, k - 1)])
          ds.join(static_cast<int>(v), static_cast<int>(d.at(i, j, k - 1)));
      }
  std::vector<int> remap(n, 0);
  int next = 0;
  for (std::size_t v = 0; v < n; ++v) {
    if (!isvoid[v]) continue;
    const int r = ds.find(static_cast<int>(v));
    if (!remap[static_cast<std::size_t>(r)]) remap[static_cast<std::size_t>(r)] = ++next;
    t.label[v] = remap[static_cast<std::size_t>(r)];
  }
  t.components = next;
  if (!want_chi) return t;

  // ── ★ THE EULER CHARACTERISTIC, EXACTLY, over the cubical complex ─────────
  //
  // Each void voxel is a closed unit cube. A k-cell belongs to the complex iff
  // ANY incident voxel is void, so each cell is counted ONCE by scanning the
  // (nx+1)x(ny+1)x(nz+1) vertex lattice and asking, for each cell anchored
  // there, whether any of the voxels it touches is void. No cell is double
  // counted and none is missed, which an inclusion-exclusion over voxels would
  // get wrong at the boundary.
  auto vox = [&](int i, int j, int k) -> bool {
    if (i < 0 || j < 0 || k < 0 || i >= d.nx || j >= d.ny || k >= d.nz) return false;
    return isvoid[d.at(i, j, k)] != 0;
  };
  long long nv = 0, ne = 0, nf = 0, nc = 0;
  for (int k = 0; k <= d.nz; ++k)
    for (int j = 0; j <= d.ny; ++j)
      for (int i = 0; i <= d.nx; ++i) {
        // vertex (i,j,k): touches the 8 voxels with corners at it
        bool any = false;
        for (int dk = -1; dk <= 0 && !any; ++dk)
          for (int dj = -1; dj <= 0 && !any; ++dj)
            for (int di = -1; di <= 0 && !any; ++di)
              if (vox(i + di, j + dj, k + dk)) any = true;
        if (any) ++nv;
        // the three edges leaving it in +x, +y, +z; each touches 4 voxels
        if (i < d.nx) {
          bool a = false;
          for (int dk = -1; dk <= 0 && !a; ++dk)
            for (int dj = -1; dj <= 0 && !a; ++dj)
              if (vox(i, j + dj, k + dk)) a = true;
          if (a) ++ne;
        }
        if (j < d.ny) {
          bool a = false;
          for (int dk = -1; dk <= 0 && !a; ++dk)
            for (int di = -1; di <= 0 && !a; ++di)
              if (vox(i + di, j, k + dk)) a = true;
          if (a) ++ne;
        }
        if (k < d.nz) {
          bool a = false;
          for (int dj = -1; dj <= 0 && !a; ++dj)
            for (int di = -1; di <= 0 && !a; ++di)
              if (vox(i + di, j + dj, k)) a = true;
          if (a) ++ne;
        }
        // the three faces anchored here; each touches 2 voxels
        if (i < d.nx && j < d.ny) {
          if (vox(i, j, k) || vox(i, j, k - 1)) ++nf;
        }
        if (i < d.nx && k < d.nz) {
          if (vox(i, j, k) || vox(i, j - 1, k)) ++nf;
        }
        if (j < d.ny && k < d.nz) {
          if (vox(i, j, k) || vox(i - 1, j, k)) ++nf;
        }
        if (i < d.nx && j < d.ny && k < d.nz && vox(i, j, k)) ++nc;
      }
  t.chi = nv - ne + nf - nc;

  // ── b2: void pockets with no escape. The lattice-boundary-connected void is
  // the "outside"; every other complement-of-solid component inside the part is
  // a cavity. Reusing the component labelling: a component that touches no
  // lattice face and no non-region voxel is enclosed.
  std::vector<char> open(static_cast<std::size_t>(t.components) + 1, 0);
  for (int k = 0; k < d.nz; ++k)
    for (int j = 0; j < d.ny; ++j)
      for (int i = 0; i < d.nx; ++i) {
        const std::size_t v = d.at(i, j, k);
        if (!t.label[v]) continue;
        const bool face = (i == 0 || j == 0 || k == 0 || i == d.nx - 1 ||
                           j == d.ny - 1 || k == d.nz - 1);
        bool touches_out = face;
        if (!touches_out) {
          const int nb[6][3] = {{-1,0,0},{1,0,0},{0,-1,0},{0,1,0},{0,0,-1},{0,0,1}};
          for (auto& o : nb) {
            const std::size_t w = d.at(i + o[0], j + o[1], k + o[2]);
            if (!in_region(w)) { touches_out = true; break; }
          }
        }
        if (touches_out) open[static_cast<std::size_t>(t.label[v])] = 1;
      }
  t.cavities = 0;
  for (int c = 1; c <= t.components; ++c)
    if (!open[static_cast<std::size_t>(c)]) ++t.cavities;
  // b1 = b0 + b2 - chi
  t.tunnels = static_cast<long long>(t.components) + t.cavities - t.chi;
  return t;
}

#endif  // TOPOPT_TESTS_HARNESS_PLSM_TOPOLOGY_HPP_
