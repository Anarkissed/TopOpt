// Warm-start restrict / prolong utilities (handoff 110, Part B). Pure geometry —
// no FEA, no Eigen — so this TU builds and unit-tests on any toolchain (it lives
// under src/simp with the driver but has no Eigen dependency of its own).

#include "topopt/warm_start.hpp"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <stdexcept>
#include <unordered_set>
#include <vector>

namespace topopt {

namespace {

int coarse_dim(int n) { return std::max(1, (n + 1) / 2); }

// Verify `coarse` is the 2x coarsening of `fine` (dims / spacing), as the
// restrict/prolong operators assume. Cheap and catches a mismatched pair early.
void check_pair(const VoxelGrid& fine, const VoxelGrid& coarse) {
  if (coarse.nx != coarse_dim(fine.nx) || coarse.ny != coarse_dim(fine.ny) ||
      coarse.nz != coarse_dim(fine.nz))
    throw std::invalid_argument(
        "warm_start: coarse grid is not the 2x coarsening of fine");
}

// Decompose a node index n (== fea_node_index(grid, a, b, c)) back into (a,b,c).
void node_coords(const VoxelGrid& grid, int n, int& a, int& b, int& c) {
  const int nx = grid.nx + 1;  // nodes per axis = voxels + 1
  const int ny = grid.ny + 1;
  a = n % nx;
  const int t = n / nx;
  b = t % ny;
  c = t / ny;
}

// Tag priority for coarsening: Load and Fixture (BC skin) must survive, then any
// solid, else Empty. Higher = wins.
int tag_priority(VoxelTag t) {
  switch (t) {
    case VoxelTag::Load: return 4;
    case VoxelTag::Fixture: return 3;
    case VoxelTag::Empty: return 0;
    default: return 1;  // Interior / Surface / UserTagged: solid
  }
}

}  // namespace

VoxelGrid coarsen_grid(const VoxelGrid& fine) {
  VoxelGrid c;
  c.nx = coarse_dim(fine.nx);
  c.ny = coarse_dim(fine.ny);
  c.nz = coarse_dim(fine.nz);
  c.spacing = fine.spacing * 2.0;
  c.origin = fine.origin;
  c.tags.assign(static_cast<std::size_t>(c.nx) * c.ny * c.nz, VoxelTag::Empty);
  for (int K = 0; K < c.nz; ++K)
    for (int J = 0; J < c.ny; ++J)
      for (int I = 0; I < c.nx; ++I) {
        VoxelTag best = VoxelTag::Empty;
        int best_pri = 0;
        for (int dk = 0; dk < 2; ++dk)
          for (int dj = 0; dj < 2; ++dj)
            for (int di = 0; di < 2; ++di) {
              const int fi = 2 * I + di, fj = 2 * J + dj, fk = 2 * K + dk;
              if (fi >= fine.nx || fj >= fine.ny || fk >= fine.nz) continue;
              const VoxelTag t = fine.tag(fi, fj, fk);
              const int p = tag_priority(t);
              if (p > best_pri) { best_pri = p; best = t; }
            }
        c.set_tag(I, J, K, best);
      }
  return c;
}

std::vector<double> restrict_density(const VoxelGrid& fine,
                                     const VoxelGrid& coarse,
                                     const std::vector<double>& fine_density) {
  check_pair(fine, coarse);
  if (fine_density.size() != fine.voxel_count())
    throw std::invalid_argument(
        "restrict_density: fine_density size != fine.voxel_count()");
  std::vector<double> out(coarse.voxel_count(), 0.0);
  for (int K = 0; K < coarse.nz; ++K)
    for (int J = 0; J < coarse.ny; ++J)
      for (int I = 0; I < coarse.nx; ++I) {
        double sum = 0.0;
        int n = 0;
        for (int dk = 0; dk < 2; ++dk)
          for (int dj = 0; dj < 2; ++dj)
            for (int di = 0; di < 2; ++di) {
              const int fi = 2 * I + di, fj = 2 * J + dj, fk = 2 * K + dk;
              if (fi >= fine.nx || fj >= fine.ny || fk >= fine.nz) continue;
              sum += fine_density[fine.index(fi, fj, fk)];
              ++n;
            }
        out[coarse.index(I, J, K)] = n > 0 ? sum / static_cast<double>(n) : 0.0;
      }
  return out;
}

std::vector<double> prolong_density(const VoxelGrid& coarse,
                                    const VoxelGrid& fine,
                                    const std::vector<double>& coarse_density) {
  check_pair(fine, coarse);
  if (coarse_density.size() != coarse.voxel_count())
    throw std::invalid_argument(
        "prolong_density: coarse_density size != coarse.voxel_count()");
  std::vector<double> out(fine.voxel_count(), 0.0);

  // Trilinear sample of the coarse field at the fine voxel centres. Fine index i
  // maps to the continuous coarse coordinate u = (i + 0.5)/2 - 0.5 (same centre
  // convention as resample_field); the 8 surrounding coarse centres are clamped
  // into range at the boundary.
  auto sample_axis = [](int i, int nc, int& lo, int& hi, double& w) {
    const double u = (static_cast<double>(i) + 0.5) * 0.5 - 0.5;
    double fl = std::floor(u);
    w = u - fl;
    lo = static_cast<int>(fl);
    hi = lo + 1;
    if (lo < 0) { lo = 0; hi = 0; w = 0.0; }
    if (hi > nc - 1) { hi = nc - 1; if (lo > nc - 1) lo = nc - 1; }
  };

  for (int k = 0; k < fine.nz; ++k) {
    int k0, k1; double wk;
    sample_axis(k, coarse.nz, k0, k1, wk);
    for (int j = 0; j < fine.ny; ++j) {
      int j0, j1; double wj;
      sample_axis(j, coarse.ny, j0, j1, wj);
      for (int i = 0; i < fine.nx; ++i) {
        int i0, i1; double wi;
        sample_axis(i, coarse.nx, i0, i1, wi);
        const double c000 = coarse_density[coarse.index(i0, j0, k0)];
        const double c100 = coarse_density[coarse.index(i1, j0, k0)];
        const double c010 = coarse_density[coarse.index(i0, j1, k0)];
        const double c110 = coarse_density[coarse.index(i1, j1, k0)];
        const double c001 = coarse_density[coarse.index(i0, j0, k1)];
        const double c101 = coarse_density[coarse.index(i1, j0, k1)];
        const double c011 = coarse_density[coarse.index(i0, j1, k1)];
        const double c111 = coarse_density[coarse.index(i1, j1, k1)];
        const double c00 = c000 * (1 - wi) + c100 * wi;
        const double c10 = c010 * (1 - wi) + c110 * wi;
        const double c01 = c001 * (1 - wi) + c101 * wi;
        const double c11 = c011 * (1 - wi) + c111 * wi;
        const double c0 = c00 * (1 - wj) + c10 * wj;
        const double c1 = c01 * (1 - wj) + c11 * wj;
        out[fine.index(i, j, k)] = c0 * (1 - wk) + c1 * wk;
      }
    }
  }
  return out;
}

std::vector<DirichletBC> coarsen_bcs(const VoxelGrid& fine,
                                     const VoxelGrid& coarse,
                                     const std::vector<DirichletBC>& bcs) {
  check_pair(fine, coarse);
  std::vector<DirichletBC> out;
  out.reserve(bcs.size());
  std::unordered_set<long long> seen;
  for (const DirichletBC& bc : bcs) {
    int a, b, c;
    node_coords(fine, bc.node, a, b, c);
    const int cn = fea_node_index(coarse, a / 2, b / 2, c / 2);
    // Dedup on (coarse node, component). Value is carried from the first
    // occurrence; all these BCs are homogeneous faces, so values agree.
    const long long key = static_cast<long long>(cn) * 4 + bc.component;
    if (!seen.insert(key).second) continue;
    out.push_back({cn, bc.component, bc.value});
  }
  return out;
}

std::vector<NodalLoad> restrict_loads(const VoxelGrid& fine,
                                      const VoxelGrid& coarse,
                                      const std::vector<NodalLoad>& loads) {
  check_pair(fine, coarse);
  // Accumulate force per (coarse node, component), preserving first-seen order
  // so the output is deterministic. `slot_of` maps a (node, component) key to its
  // index in `out`.
  std::vector<NodalLoad> out;
  std::vector<std::pair<long long, std::size_t>> slot_of;
  for (const NodalLoad& nl : loads) {
    int a, b, c;
    node_coords(fine, nl.node, a, b, c);
    const int cn = fea_node_index(coarse, a / 2, b / 2, c / 2);
    const long long key = static_cast<long long>(cn) * 4 + nl.component;
    std::size_t slot = out.size();
    for (const auto& kv : slot_of)
      if (kv.first == key) { slot = kv.second; break; }
    if (slot == out.size()) {
      slot_of.push_back({key, out.size()});
      out.push_back({cn, nl.component, nl.value});
    } else {
      out[slot].value += nl.value;
    }
  }
  return out;
}

DesignMask coarsen_mask(const VoxelGrid& fine, const VoxelGrid& coarse,
                        const DesignMask& mask) {
  check_pair(fine, coarse);
  if (mask.size() != fine.voxel_count())
    throw std::invalid_argument(
        "coarsen_mask: mask size != fine.voxel_count()");
  DesignMask out(coarse.voxel_count(), MaskValue::FrozenVoid);
  for (int K = 0; K < coarse.nz; ++K)
    for (int J = 0; J < coarse.ny; ++J)
      for (int I = 0; I < coarse.nx; ++I) {
        bool any_solid_child = false;
        bool any_frozen_solid = false;
        bool any_active = false;
        for (int dk = 0; dk < 2; ++dk)
          for (int dj = 0; dj < 2; ++dj)
            for (int di = 0; di < 2; ++di) {
              const int fi = 2 * I + di, fj = 2 * J + dj, fk = 2 * K + dk;
              if (fi >= fine.nx || fj >= fine.ny || fk >= fine.nz) continue;
              if (!fine.solid(fi, fj, fk)) continue;
              any_solid_child = true;
              const MaskValue m = mask[fine.index(fi, fj, fk)];
              if (m == MaskValue::FrozenSolid) any_frozen_solid = true;
              else if (m == MaskValue::Active) any_active = true;
            }
        MaskValue v = MaskValue::FrozenVoid;
        if (any_frozen_solid) v = MaskValue::FrozenSolid;
        else if (any_active) v = MaskValue::Active;
        else if (any_solid_child) v = MaskValue::FrozenVoid;  // all children void
        out[coarse.index(I, J, K)] = v;
      }
  return out;
}

}  // namespace topopt
