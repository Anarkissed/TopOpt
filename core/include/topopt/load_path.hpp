#pragma once

// TO rebuild, stage 4: "load paths kept connected" as a check cheap enough to run
// once per optimiser iteration. Header-only.
//
// THE RULE IS THE BELT'S OWN (voxel.hpp `load_path_connected`, voxelize.cpp
// `walk_load_path`), so this check and the after-the-fact refusal never disagree:
//   * printed = tag != Empty AND density > threshold (strictly). Load and Fixture
//     voxels follow the same rule: a carved-away anchor anchors nothing and a
//     carved-away load face is unheld by construction.
//   * joined = 26-connectivity by default (faces, edges and corners: two hex8
//     elements touching at a corner share a node), or 18 / 6 as the strength
//     check's settings may choose.
//   * vacuously connected when the grid has no Load or no Fixture voxel.
//
// Cost: O(voxels), deterministic, single-threaded; two byte arrays and one stack.

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <vector>

#include "topopt/voxel.hpp"

namespace topopt {

struct LoadPathCheck {
  bool connected = true;          // every load group reaches an anchor (and no Load voxel is carved away)
  int load_groups = 0;            // connected components of printed Load voxels
  int unheld_groups = 0;          // of those, how many reach no anchor
  std::size_t unheld_voxels = 0;  // printed voxels in bodies that hold a load but reach no anchor
  std::size_t unprinted_load_voxels = 0;  // Load voxels below the threshold (each makes the design unheld)
  std::size_t thinnest_link_voxels = 0;   // 1, 2 or 3 (see load_path_check); 0 if not computed
};

namespace load_path_detail {

// Mark bits in the second byte array.
constexpr std::uint8_t kHeld = 1, kLoadSeen = 2, kUnheldBody = 4;

struct Walker {
  const VoxelGrid& g;
  const std::vector<std::uint8_t>& p;  // printed bits (bit0: as given; bit1, bit2: eroded once, twice)
  std::vector<std::uint8_t>& m;        // marks
  std::vector<std::size_t>& stack;
  int most_axes;                       // 1: faces, 2: + edges, 3: + corners

  bool printed(std::size_t idx, std::uint8_t bit) const { return (p[idx] & bit) != 0; }

  // Depth-first flood from whatever is on the stack, over voxels with `bit` printed
  // (and, if `load_only`, tagged Load), setting `mark`. Returns voxels newly marked.
  std::size_t flood(std::uint8_t bit, std::uint8_t mark, bool load_only) {
    const int nx = g.nx, ny = g.ny, nz = g.nz;
    const std::size_t sxy = static_cast<std::size_t>(nx) * static_cast<std::size_t>(ny);
    std::size_t count = 0;
    while (!stack.empty()) {
      const std::size_t idx = stack.back();
      stack.pop_back();
      ++count;
      const int i = static_cast<int>(idx % static_cast<std::size_t>(nx));
      const int j = static_cast<int>((idx / static_cast<std::size_t>(nx)) % static_cast<std::size_t>(ny));
      const int k = static_cast<int>(idx / sxy);
      for (int dk = -1; dk <= 1; ++dk) {
        const int nk = k + dk;
        if (nk < 0 || nk >= nz) continue;
        for (int dj = -1; dj <= 1; ++dj) {
          const int nj = j + dj;
          if (nj < 0 || nj >= ny) continue;
          for (int di = -1; di <= 1; ++di) {
            const int axes = (di != 0) + (dj != 0) + (dk != 0);
            if (axes == 0 || axes > most_axes) continue;
            const int ni = i + di;
            if (ni < 0 || ni >= nx) continue;
            const std::size_t n = g.index(ni, nj, nk);
            if ((m[n] & mark) || !printed(n, bit)) continue;
            if (load_only && g.tags[n] != VoxelTag::Load) continue;
            m[n] |= mark;
            stack.push_back(n);
          }
        }
      }
    }
    return count;
  }

  // The check on the printed set `bit`. `out` gets the counts; returns connected.
  bool run(std::uint8_t bit, LoadPathCheck& out) {
    std::fill(m.begin(), m.end(), std::uint8_t{0});
    const std::size_t n = g.voxel_count();
    out.load_groups = 0;
    out.unheld_groups = 0;
    out.unheld_voxels = 0;
    out.unprinted_load_voxels = 0;
    // One flood from every printed anchor voxel marks everything held.
    stack.clear();
    for (std::size_t idx = 0; idx < n; ++idx)
      if (g.tags[idx] == VoxelTag::Fixture && printed(idx, bit)) {
        m[idx] |= kHeld;
        stack.push_back(idx);
      }
    flood(bit, kHeld, false);
    // Each component of printed Load voxels is one load group; an unheld one also
    // floods its body to count the voxels hanging on nothing.
    for (std::size_t idx = 0; idx < n; ++idx) {
      if (g.tags[idx] != VoxelTag::Load) continue;
      if (!printed(idx, bit)) {
        ++out.unprinted_load_voxels;
        continue;
      }
      if (m[idx] & kLoadSeen) continue;
      ++out.load_groups;
      m[idx] |= kLoadSeen;
      stack.assign(1, idx);
      flood(bit, kLoadSeen, true);
      if (m[idx] & kHeld) continue;
      ++out.unheld_groups;
      if (m[idx] & kUnheldBody) continue;  // same body as an earlier unheld group
      m[idx] |= kUnheldBody;
      stack.assign(1, idx);
      out.unheld_voxels += flood(bit, kUnheldBody, false);
    }
    out.connected = out.unheld_groups == 0 && out.unprinted_load_voxels == 0;
    return out.connected;
  }
};

// bit `to` = bit `from` eroded by one voxel: survives if all 6 face neighbours are
// printed (outside the grid counts as not printed); Load and Fixture never erode.
inline void erode(const VoxelGrid& g, std::vector<std::uint8_t>& p, std::uint8_t from,
                  std::uint8_t to) {
  const int nx = g.nx, ny = g.ny, nz = g.nz;
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < nx; ++i) {
        const std::size_t idx = g.index(i, j, k);
        if (!(p[idx] & from)) continue;
        const VoxelTag t = g.tags[idx];
        bool keep = t == VoxelTag::Load || t == VoxelTag::Fixture;
        if (!keep)
          keep = i > 0 && i < nx - 1 && j > 0 && j < ny - 1 && k > 0 && k < nz - 1 &&
                 (p[g.index(i - 1, j, k)] & from) && (p[g.index(i + 1, j, k)] & from) &&
                 (p[g.index(i, j - 1, k)] & from) && (p[g.index(i, j + 1, k)] & from) &&
                 (p[g.index(i, j, k - 1)] & from) && (p[g.index(i, j, k + 1)] & from);
        if (keep) p[idx] |= to;
      }
}

}  // namespace load_path_detail

// Does every loaded region of the printed design reach an anchor?
// `connectivity`: 26 (default, the belt's), 18 or 6.
// `with_thinnest_link` (connected case only): erode the printed set by one voxel
// (Load and Fixture never eroded) and check again: thinnest_link_voxels = 1 if the
// eroded design is disconnected, 2 if it survives one erosion but not two, 3 if it
// survives two. A cheap proxy for the minimum cut, not the cut itself.
// Throws std::invalid_argument on a density of the wrong size or a bad connectivity.
inline LoadPathCheck load_path_check(const VoxelGrid& grid, const std::vector<double>& density,
                                     double printed_threshold = 0.5,
                                     bool with_thinnest_link = false, int connectivity = 26) {
  using namespace load_path_detail;
  if (density.size() != grid.voxel_count())
    throw std::invalid_argument("load_path_check: density size != grid.voxel_count()");
  if (connectivity != 6 && connectivity != 18 && connectivity != 26)
    throw std::invalid_argument("load_path_check: connectivity must be 6, 18 or 26");
  LoadPathCheck out;
  bool any_load = false, any_anchor = false;
  for (const VoxelTag t : grid.tags) {
    any_load = any_load || t == VoxelTag::Load;
    any_anchor = any_anchor || t == VoxelTag::Fixture;
  }
  if (!any_load || !any_anchor) return out;  // vacuous, as the belt

  const std::size_t n = grid.voxel_count();
  std::vector<std::uint8_t> p(n, 0), m(n, 0);
  std::vector<std::size_t> stack;
  for (std::size_t idx = 0; idx < n; ++idx)
    if (grid.tags[idx] != VoxelTag::Empty && density[idx] > printed_threshold) p[idx] = 1;
  Walker w{grid, p, m, stack, connectivity == 26 ? 3 : connectivity == 18 ? 2 : 1};
  if (!w.run(1, out) || !with_thinnest_link) return out;

  LoadPathCheck scratch;
  erode(grid, p, 1, 2);
  if (!w.run(2, scratch)) {
    out.thinnest_link_voxels = 1;
    return out;
  }
  erode(grid, p, 2, 4);
  out.thinnest_link_voxels = w.run(4, scratch) ? 3 : 2;
  return out;
}

}  // namespace topopt
