#include "topopt/cell_plan.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <stdexcept>

#include "topopt/lattice.hpp"  // lattice_cells_per_member_min, octet_strut_diameter_mm

namespace topopt {

namespace {

constexpr double kInf = std::numeric_limits<double>::infinity();
// A per-base-cell "needs a level coarser than the ladder offers" sentinel.
constexpr int kUnreachable = 1000;

int ipow2(int L) { return 1 << L; }

}  // namespace

const char* cell_size_mode_name(CellSizeMode m) {
  switch (m) {
    case CellSizeMode::Fixed: return "fixed";
    case CellSizeMode::Auto: return "auto";
    case CellSizeMode::Swept: return "swept";
  }
  // A new enum case must be named here before anything can serialize it.
  throw std::logic_error("cell_size_mode_name: unnamed CellSizeMode");
}

bool cell_size_mode_from_name(const char* name, CellSizeMode& out) {
  if (!name) return false;
  if (std::strcmp(name, "fixed") == 0) { out = CellSizeMode::Fixed; return true; }
  if (std::strcmp(name, "auto") == 0) { out = CellSizeMode::Auto; return true; }
  if (std::strcmp(name, "swept") == 0) { out = CellSizeMode::Swept; return true; }
  return false;
}

double CellSizePlan::cell_mm_at_level(int L) const {
  return base_cell_mm * static_cast<double>(ipow2(L));
}

double CellSizePlan::cell_size_at(int i, int j, int k) const {
  if (i < 0 || j < 0 || k < 0 || i >= nx || j >= ny || k >= nz) return 0.0;
  const signed char L = level[index(i, j, k)];
  return L < 0 ? 0.0 : cell_mm_at_level(L);
}

bool CellSizePlan::cell_owner(int i, int j, int k, int& level_out, int& bi, int& bj,
                             int& bk) const {
  if (i < 0 || j < 0 || k < 0 || i >= nx || j >= ny || k >= nz) return false;
  const signed char L = level[index(i, j, k)];
  if (L < 0) return false;
  const int step = ipow2(L);
  level_out = L;
  // The octree block is ALIGNED, so its min corner is the coordinate rounded down
  // to the level's stride. This is what makes the cell recoverable from the
  // per-base-cell array with no side table.
  bi = (i / step) * step;
  bj = (j / step) * step;
  bk = (k / step) * step;
  return true;
}

CellSizePlan plan_cell_sizes(const VoxelGrid& grid,
                             const std::vector<double>& rho,
                             const std::vector<char>& candidate,
                             const std::vector<double>& width,
                             const CellPlanParams& params) {
  const std::size_t n = grid.voxel_count();
  if (rho.size() != n)
    throw std::invalid_argument("plan_cell_sizes: rho.size() != voxel_count");
  if (candidate.size() != n)
    throw std::invalid_argument("plan_cell_sizes: candidate.size() != voxel_count");
  if (width.size() != n)
    throw std::invalid_argument("plan_cell_sizes: width.size() != voxel_count");
  if (params.mode != CellSizeMode::Swept)
    throw std::invalid_argument(
        "plan_cell_sizes: only CellSizeMode::Swept builds a dyadic plan (the Fixed "
        "and Auto paths are one uniform cell and stay in grade_lattice)");
  if (!(params.min_cell_size_mm > 0.0))
    throw std::invalid_argument("plan_cell_sizes: min_cell_size_mm must be > 0");
  if (!(params.max_cell_size_mm >= params.min_cell_size_mm))
    throw std::invalid_argument(
        "plan_cell_sizes: max_cell_size_mm must be >= min_cell_size_mm");
  if (!(params.min_extrudable_width_mm > 0.0))
    throw std::invalid_argument(
        "plan_cell_sizes: min_extrudable_width_mm must be > 0");

  const LatticeTopology topo = params.topology;
  const double n_star = lattice_cells_per_member_min(topo);

  CellSizePlan P;
  P.mode = CellSizeMode::Swept;
  P.origin = grid.origin;
  P.base_cell_mm = params.min_cell_size_mm;
  P.cells_per_member_floor = n_star;
  // The printability floor at the band's LOW end — the same law grading.hpp applies,
  // reported here so run_info records what governed even in swept mode (where the
  // binding floor is per cell, at that cell's own rho, not this one number).
  P.printability_floor_mm = lattice_cell_printability_floor_mm(
      topo, params.min_extrudable_width_mm);

  // The dyadic ladder: levels 0..max_level, cell(L) = S0 * 2^L, capped by the
  // caller's max. floor(log2(max/min)) with a guard against fp landing just under an
  // exact power of two (a 4->8 mm sweep must give exactly one doubling).
  {
    const double ratio = params.max_cell_size_mm / params.min_cell_size_mm;
    int L = 0;
    while (static_cast<double>(ipow2(L + 1)) <= ratio * (1.0 + 1e-9)) ++L;
    P.max_level = L;
  }
  const int Lmax = P.max_level;

  // ── the BASE cell grid ──────────────────────────────────────────────────────────
  const double S0 = P.base_cell_mm;
  P.nx = std::max(1, static_cast<int>(std::ceil(grid.nx * grid.spacing / S0)));
  P.ny = std::max(1, static_cast<int>(std::ceil(grid.ny * grid.spacing / S0)));
  P.nz = std::max(1, static_cast<int>(std::ceil(grid.nz * grid.spacing / S0)));
  const std::size_t ncells =
      static_cast<std::size_t>(P.nx) * P.ny * P.nz;
  P.level.assign(ncells, -1);

  // ── per-base-cell aggregates over the CANDIDATE voxels it holds ─────────────────
  // rho_min binds printability (the thinnest strut in the cell) and width_min binds
  // the cells-per-member ceiling (the thinnest member in the cell). Both are the
  // CONSERVATIVE end, so a guarantee proved on them holds for every voxel in the cell.
  std::vector<double> rho_min(ncells, kInf), width_min(ncells, kInf);
  std::vector<long long> vox(ncells, 0);
  for (int k = 0; k < grid.nz; ++k)
    for (int j = 0; j < grid.ny; ++j)
      for (int i = 0; i < grid.nx; ++i) {
        const std::size_t e = grid.index(i, j, k);
        if (!candidate[e]) continue;
        // The voxel CENTRE decides which base cell owns it — the same convention
        // run_job's graded-cell accumulation uses.
        const double cx = (i + 0.5) * grid.spacing;
        const double cy = (j + 0.5) * grid.spacing;
        const double cz = (k + 0.5) * grid.spacing;
        const int ci = std::min(P.nx - 1, std::max(0, static_cast<int>(std::floor(cx / S0))));
        const int cj = std::min(P.ny - 1, std::max(0, static_cast<int>(std::floor(cy / S0))));
        const int ck = std::min(P.nz - 1, std::max(0, static_cast<int>(std::floor(cz / S0))));
        const std::size_t c = P.index(ci, cj, ck);
        ++vox[c];
        if (rho[e] < rho_min[c]) rho_min[c] = rho[e];
        if (width[e] < width_min[c]) width_min[c] = width[e];
      }

  // ── the two bounds, per base cell ───────────────────────────────────────────────
  //   cap  = the LARGEST level whose cell still spans >= N* cells of the thinnest
  //          member here (the homogenization ceiling). -1 = not even the base cell
  //          fits: this cell can never be latticed (the existing L4 fallback).
  //   need = the SMALLEST level whose strut at the thinnest rho here still prints at
  //          the stated minimum width (the printability floor).
  std::vector<int> cap(ncells, -1), need(ncells, kUnreachable);
  for (std::size_t c = 0; c < ncells; ++c) {
    if (vox[c] == 0) continue;
    for (int L = 0; L <= Lmax; ++L) {
      const double S = P.cell_mm_at_level(L);
      // width_min is +inf where every member exceeds the EDT cap -> always clears.
      if (width_min[c] / S >= n_star) cap[c] = L;
      if (need[c] == kUnreachable &&
          octet_strut_diameter_mm(rho_min[c], S) >= params.min_extrudable_width_mm)
        need[c] = L;
    }
  }

  // ── the OCTREE: top-down, take the coarsest level someone actually NEEDS ────────
  // A block takes level L iff (a) it lies wholly inside the base grid, (b) every base
  // cell in it is a candidate, (c) L is exactly what the block's neediest member
  // requires (max need == L — we never coarsen past what printability asks for), and
  // (d) L still clears the ceiling for the block's thinnest member (L <= min cap).
  // Anything else SPLITS. The recursion bottoms out at a single base cell.
  std::vector<int> stack;  // (bi,bj,bk,L) flattened, fixed order -> deterministic
  auto push = [&stack](int bi, int bj, int bk, int L) {
    stack.push_back(bi); stack.push_back(bj); stack.push_back(bk); stack.push_back(L);
  };
  // Seed with the aligned top-level blocks covering the base grid.
  {
    const int step = ipow2(Lmax);
    for (int bk = 0; bk < P.nz; bk += step)
      for (int bj = 0; bj < P.ny; bj += step)
        for (int bi = 0; bi < P.nx; bi += step) push(bi, bj, bk, Lmax);
  }
  while (!stack.empty()) {
    const int L = stack.back(); stack.pop_back();
    const int bk = stack.back(); stack.pop_back();
    const int bj = stack.back(); stack.pop_back();
    const int bi = stack.back(); stack.pop_back();
    const int step = ipow2(L);

    bool whole_block_in_grid =
        (bi + step <= P.nx) && (bj + step <= P.ny) && (bk + step <= P.nz);
    bool all_candidates = whole_block_in_grid;
    int need_max = 0, cap_min = kUnreachable;
    if (whole_block_in_grid) {
      for (int k = bk; k < bk + step && all_candidates; ++k)
        for (int j = bj; j < bj + step && all_candidates; ++j)
          for (int i = bi; i < bi + step && all_candidates; ++i) {
            const std::size_t c = P.index(i, j, k);
            if (vox[c] == 0) { all_candidates = false; break; }
            need_max = std::max(need_max, need[c]);
            cap_min = std::min(cap_min, cap[c]);
          }
    }
    // Take this level only when it is exactly what the block needs and the ceiling
    // allows it. L == 0 additionally accepts need_max == 0 trivially.
    if (all_candidates && need_max == L && cap_min >= L) {
      for (int k = bk; k < bk + step; ++k)
        for (int j = bj; j < bj + step; ++j)
          for (int i = bi; i < bi + step; ++i)
            P.level[P.index(i, j, k)] = static_cast<signed char>(L);
      continue;
    }
    if (L == 0) {
      // A single base cell that could not take level 0: either it is not a candidate,
      // or its two bounds crossed. Left unlatticed (-1); the accounting pass below
      // separates the two causes.
      continue;
    }
    // SPLIT — fixed child order, so the plan is deterministic.
    const int half = ipow2(L - 1);
    for (int dk = 1; dk >= 0; --dk)
      for (int dj = 1; dj >= 0; --dj)
        for (int di = 1; di >= 0; --di)
          push(bi + di * half, bj + dj * half, bk + dk * half, L - 1);
  }

  // ── 2:1 BALANCE ─────────────────────────────────────────────────────────────────
  // Face-adjacent octree cells may differ by at most one level. Enforced by SPLITTING
  // the coarse side, never by coarsening the fine side: splitting shrinks the cell,
  // which strictly HELPS the cells-per-member ceiling and so can never push a cell out
  // of the certifiable regime. It can break printability (a smaller cell means a
  // thinner strut), and a cell that lands there is dropped to SOLID below — an honest
  // fallback, never a strut under the stated width.
  {
    bool changed = true;
    int guard = 0;
    while (changed && guard++ <= Lmax + 2) {
      changed = false;
      for (int k = 0; k < P.nz; ++k)
        for (int j = 0; j < P.ny; ++j)
          for (int i = 0; i < P.nx; ++i) {
            const std::size_t c = P.index(i, j, k);
            const int L = P.level[c];
            if (L <= 0) continue;
            static const int d[6][3] = {{-1, 0, 0}, {1, 0, 0}, {0, -1, 0},
                                        {0, 1, 0},  {0, 0, -1}, {0, 0, 1}};
            bool split = false;
            for (int f = 0; f < 6 && !split; ++f) {
              const int ni = i + d[f][0], nj = j + d[f][1], nk = k + d[f][2];
              if (ni < 0 || nj < 0 || nk < 0 || ni >= P.nx || nj >= P.ny || nk >= P.nz)
                continue;
              const int NL = P.level[P.index(ni, nj, nk)];
              if (NL >= 0 && NL < L - 1) split = true;
            }
            if (!split) continue;
            // Split the WHOLE octree cell one level (all base cells of its block),
            // so the assignment stays a valid aligned octree.
            const int step = ipow2(L);
            const int obi = (i / step) * step, obj = (j / step) * step,
                      obk = (k / step) * step;
            for (int kk = obk; kk < obk + step; ++kk)
              for (int jj = obj; jj < obj + step; ++jj)
                for (int ii = obi; ii < obi + step; ++ii)
                  P.level[P.index(ii, jj, kk)] = static_cast<signed char>(L - 1);
            ++P.cells_split_by_balance;  // one octree cell became eight
            changed = true;
          }
    }
  }

  // ── post-balance feasibility: drop any cell a split made unprintable ────────────
  // (The ceiling cannot be violated by splitting, so only printability is re-checked.)
  {
    for (int k = 0; k < P.nz; ++k)
      for (int j = 0; j < P.ny; ++j)
        for (int i = 0; i < P.nx; ++i) {
          const std::size_t c = P.index(i, j, k);
          const int L = P.level[c];
          if (L < 0) continue;
          if (need[c] > L) P.level[c] = -1;  // struts would be under the stated width
        }
  }

  // ── accounting + the per-level report (bar R5) ──────────────────────────────────
  P.levels.assign(static_cast<std::size_t>(Lmax) + 1, CellLevelReport{});
  for (int L = 0; L <= Lmax; ++L) {
    P.levels[static_cast<std::size_t>(L)].level = L;
    P.levels[static_cast<std::size_t>(L)].cell_size_mm = P.cell_mm_at_level(L);
    P.levels[static_cast<std::size_t>(L)].min_member_width_mm = kInf;
    P.levels[static_cast<std::size_t>(L)].min_cells_per_member = kInf;
    P.levels[static_cast<std::size_t>(L)].min_strut_diameter_mm = kInf;
  }
  P.min_strut_diameter_mm = kInf;
  P.min_cells_per_member = kInf;

  for (int k = 0; k < P.nz; ++k)
    for (int j = 0; j < P.ny; ++j)
      for (int i = 0; i < P.nx; ++i) {
        const std::size_t c = P.index(i, j, k);
        if (vox[c] == 0) continue;  // not a candidate cell at all
        const int L = P.level[c];
        if (L < 0) {
          // Latticing failed here. Separate the two causes so the receipt can say
          // which limit bound: no printable cell at all vs a printable cell the
          // ceiling forbids.
          if (cap[c] < 0) {
            /* too thin to homogenize even at the base cell — the existing L4 case,
               counted by grade_lattice as a solid fallback, not here. */
          } else {
            ++P.cells_dropped_unprintable;
          }
          continue;
        }
        // Count the OWNING base cell only, so an octree cell counts once.
        int lo, obi, obj, obk;
        P.cell_owner(i, j, k, lo, obi, obj, obk);
        const bool is_owner = (i == obi && j == obj && k == obk);

        const double S = P.cell_mm_at_level(L);
        const double d = octet_strut_diameter_mm(rho_min[c], S);
        const double cpm = width_min[c] / S;
        CellLevelReport& r = P.levels[static_cast<std::size_t>(L)];
        if (is_owner) { ++r.cells; ++P.latticed_cells; if (L > 0) ++P.cells_raised_to_floor; }
        r.voxels += vox[c];
        r.min_member_width_mm = std::min(r.min_member_width_mm, width_min[c]);
        r.min_cells_per_member = std::min(r.min_cells_per_member, cpm);
        r.min_strut_diameter_mm = std::min(r.min_strut_diameter_mm, d);
        r.max_strut_diameter_mm = std::max(r.max_strut_diameter_mm, d);
        if (cpm < n_star) r.out_of_regime = true;
        if (d < params.min_extrudable_width_mm) r.any_strut_below_min = true;
        P.min_strut_diameter_mm = std::min(P.min_strut_diameter_mm, d);
        P.max_strut_diameter_mm = std::max(P.max_strut_diameter_mm, d);
        P.min_cells_per_member = std::min(P.min_cells_per_member, cpm);
      }

  // Drop the levels nothing landed on, so the report lists only real regions.
  {
    std::vector<CellLevelReport> occupied;
    for (const CellLevelReport& r : P.levels)
      if (r.cells > 0) occupied.push_back(r);
    P.levels.swap(occupied);
  }
  for (const CellLevelReport& r : P.levels) {
    if (r.out_of_regime) P.any_out_of_regime = true;
    if (r.any_strut_below_min) P.any_strut_below_min = true;
  }
  if (P.latticed_cells == 0) {
    P.min_strut_diameter_mm = 0.0;
    P.max_strut_diameter_mm = 0.0;
    P.min_cells_per_member = 0.0;
  }

  // ── the invariants this function exists to hold ─────────────────────────────────
  // (a) every latticed cell is printable AND inside the homogenization regime;
  // (b) the assignment is a valid ALIGNED octree — the property that makes coarse
  //     nodes nest in the base grid, which is the whole transition rule (bar R4);
  // (c) face-adjacent cells differ by at most one level.
  for (int k = 0; k < P.nz; ++k)
    for (int j = 0; j < P.ny; ++j)
      for (int i = 0; i < P.nx; ++i) {
        const std::size_t c = P.index(i, j, k);
        const int L = P.level[c];
        if (L < 0) continue;
        const double S = P.cell_mm_at_level(L);
        if (!(width_min[c] / S >= n_star))
          throw std::logic_error(
              "plan_cell_sizes: emitted a cell below the cells-per-member floor");
        if (!(octet_strut_diameter_mm(rho_min[c], S) >=
              params.min_extrudable_width_mm))
          throw std::logic_error(
              "plan_cell_sizes: emitted a cell whose strut is under the stated "
              "minimum extrudable width");
        const int step = ipow2(L);
        const int obi = (i / step) * step, obj = (j / step) * step,
                  obk = (k / step) * step;
        if (obi + step > P.nx || obj + step > P.ny || obk + step > P.nz)
          throw std::logic_error(
              "plan_cell_sizes: octree cell is not wholly inside the base grid");
        for (int kk = obk; kk < obk + step; ++kk)
          for (int jj = obj; jj < obj + step; ++jj)
            for (int ii = obi; ii < obi + step; ++ii)
              if (P.level[P.index(ii, jj, kk)] != L)
                throw std::logic_error(
                    "plan_cell_sizes: level assignment is not an aligned octree");
        static const int d6[6][3] = {{-1, 0, 0}, {1, 0, 0}, {0, -1, 0},
                                     {0, 1, 0},  {0, 0, -1}, {0, 0, 1}};
        for (int f = 0; f < 6; ++f) {
          const int ni = i + d6[f][0], nj = j + d6[f][1], nk = k + d6[f][2];
          if (ni < 0 || nj < 0 || nk < 0 || ni >= P.nx || nj >= P.ny || nk >= P.nz)
            continue;
          const int NL = P.level[P.index(ni, nj, nk)];
          if (NL >= 0 && std::abs(NL - L) > 1)
            throw std::logic_error(
                "plan_cell_sizes: 2:1 balance violated between adjacent cells");
        }
      }

  return P;
}

std::vector<double> cell_size_field(const VoxelGrid& grid,
                                    const CellSizePlan& plan) {
  std::vector<double> out(grid.voxel_count(), 0.0);
  if (plan.base_cell_mm <= 0.0) return out;
  const double S0 = plan.base_cell_mm;
  for (int k = 0; k < grid.nz; ++k)
    for (int j = 0; j < grid.ny; ++j)
      for (int i = 0; i < grid.nx; ++i) {
        const double cx = (i + 0.5) * grid.spacing;
        const double cy = (j + 0.5) * grid.spacing;
        const double cz = (k + 0.5) * grid.spacing;
        const int ci = std::min(plan.nx - 1, std::max(0, static_cast<int>(std::floor(cx / S0))));
        const int cj = std::min(plan.ny - 1, std::max(0, static_cast<int>(std::floor(cy / S0))));
        const int ck = std::min(plan.nz - 1, std::max(0, static_cast<int>(std::floor(cz / S0))));
        out[grid.index(i, j, k)] = plan.cell_size_at(ci, cj, ck);
      }
  return out;
}

}  // namespace topopt
