// Lattice layout, stage C: the cells. See lattice_layout.hpp.
#include "topopt/lattice_layout.hpp"

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <thread>

#include "topopt/stepped_plan.hpp"  // stepped_size_menu, kSteppedPrintsOpenMaxStrutPerCell

namespace topopt::lattice_layout {
namespace {

// ── THE WALLS UNDER A FLAT REGION (C11, C12, C15; settled 2026-11-10, item 6) ──
// Under one face the material is not one thickness: behind part of it there may be a
// slot, a step, another face. Each stretch where the wall (the smaller of the region's
// depth and the material there) is ONE width is a wall of its own: its cells divide
// THAT width exactly and are centred on THAT stretch. This is a coarse map of the
// face, used only to tell the stretches apart; which wall a point belongs to is then
// decided by the wall's width read at the point itself, so the line between two walls
// is the true step in the part, not the map's grid.
struct WallMap {
  static constexpr double kPitch = 1.0;    // mm between map nodes
  static constexpr double kBin = 0.05;     // mm: widths this close are one width
  double u0 = 0, w0 = 0;
  int nu = 0, nw = 0;
  std::vector<long> bin;     // per node: the wall's width in bins, -1 = no lattice here
  std::vector<int> wall;     // per node: index into `walls`, -1 = not in a wall
  struct Wall {
    double width = 0, cell = 0;
    int layers = 0;
    double lo[2] = {0, 0}, hi[2] = {0, 0};   // its extent on the face
  };
  std::vector<Wall> walls;

  static long bin_of(double width) { return std::lround(width / kBin); }
  // The wall a point at (u, w) with wall width `width` belongs to, or -1.
  int find(double u, double w, double width) const {
    if (walls.empty()) return -1;
    const long b = bin_of(width);
    const int i = static_cast<int>(std::floor((u - u0) / kPitch));
    const int j = static_cast<int>(std::floor((w - w0) / kPitch));
    for (int dj = 0; dj <= 1; ++dj)
      for (int di = 0; di <= 1; ++di) {
        const int a = i + di, c = j + dj;
        if (a < 0 || c < 0 || a >= nu || c >= nw) continue;
        const std::size_t n = static_cast<std::size_t>(c) * nu + a;
        if (wall[n] >= 0 && std::labs(bin[n] - b) <= 1) return wall[n];
      }
    return -1;
  }
};

// How closely a wall's width is read, with margin: 10 nanometres on a half-width.
constexpr double kReadingSlack = 1e-5;   // mm

// One region's pass.
struct Pass {
  const Domain::Probe* probe;
  const CellSpec* spec;
  int region;
  int frame_index;
  Frame frame;
  double depth_cap;            // a prism's or shell's own depth; the wall is never read deeper (C12)
  std::vector<double> sizes;   // the sizes this region may use, largest first
  std::vector<int> divisors;   // Stepped: the fractions of the base whose unit prints open
  Layout* out;
  RegionCells* tally;
  const WallMap* walls = nullptr;   // a flat region's walls, if it has any
  int wall = -1;                    // the wall this pass lays; -1 = what no wall holds
  const Region* band_region = nullptr;   // a flat region with Grade to shape on
  double base_mm = 0.0;             // this lay's own cell (S_base)
  double finest_mm = 0.0;           // the smallest cell its ladder allows (f)

  // 0 at the region's outline, 1 at the band's inner edge and beyond (G2, G5).
  double band_t(const double lo[3], double s) const {
    if (!band_region) return 1.0;
    const double d = region_edge_distance(*band_region, frame.at(lo[0] + 0.5 * s, lo[1] + 0.5 * s, lo[2] + 0.5 * s));
    return std::clamp(d / spec->band_mm, 0.0, 1.0);
  }
  bool is_finest(double s) const { return s <= finest_mm * (1.0 + 1e-9); }
  double edge_distance(double a, double b, double c) const {
    return region_edge_distance(*band_region, frame.at(a, b, c));
  }
  // G1-G3, the preview's centre rule: a cell of size s may stand where its centre is at
  // least band (s - f) / (S_base - f) inside the outline. The region's own cell keeps its
  // centre a whole band in; the finest always may.
  bool band_allows(const double lo[3], double s) const {
    if (!band_region || is_finest(s)) return true;
    const double d = std::max(0.0, edge_distance(lo[0] + 0.5 * s, lo[1] + 0.5 * s, lo[2] + 0.5 * s));
    return d >= spec->band_mm * (s - finest_mm) / (base_mm - finest_mm) - 1e-9;
  }
  // G10: with Grade to shape on, only the finest cell may be cut by the outline. Any
  // larger cell must lie whole inside it (read at its corners, edge middles and centre).
  bool whole_in_outline(const double lo[3], double s) const {
    if (!band_region || is_finest(s)) return true;
    for (int b = 0; b < 3; ++b)
      for (int a = 0; a < 3; ++a)
        if (edge_distance(lo[0] + 0.5 * s * a, lo[1] + 0.5 * s * b, lo[2] + 0.5 * s) < -1e-6)
          return false;
    return true;
  }
  // G11: a cell below the open look's floor exists only inside the band.
  bool fine_allowed(const double lo[3], double s) const {
    if (s >= out->floor_cell_mm * (1.0 - 1e-9)) return true;
    if (!band_region) return false;
    return edge_distance(lo[0] + 0.5 * s, lo[1] + 0.5 * s, lo[2] + 0.5 * s) - 0.5 * s < spec->band_mm;
  }

  bool allowed(double s) const {
    for (double a : sizes)
      if (std::fabs(a - s) <= 1e-9 * std::max(a, s)) return true;
    return false;
  }

  // One point: does lattice of this pass go here, and how big a cell does the wall at
  // this spot allow? A point counts when the layout's one Domain says lattice goes there
  // AND this region owns it (D13: ownership is the Domain's answer at the point, never
  // the order of work) AND, under a flat face, it is in the wall this pass lays.
  bool sample(double a, double b, double c, double* fit) const {
    double width = 0.0;
    const Where w = probe->where(frame.at(a, b, c), &width);
    if (!w.lattice() || w.id != region) return false;
    width = std::min(width, depth_cap);
    if (walls && walls->find(a, b, width) != wall) return false;
    // C2, C12: never wider than the wall; the wall is the material at this spot along the
    // region's own direction, and never more than the region's depth.
    // C3-C5 (reviewer's ruling 2026-11-11): the cells a wall must hold are counted across
    // the member's NARROWEST width, whichever way that lies. A rib one cell wide across
    // the face and two deep is one across, not two. (Twice the depth below the surface is
    // a ball that fits, so nothing through the point is narrower than that.)
    double narrow = width;
    if (walls) {
      const Vec3 p = frame.at(a, b, c);
      if (2.0 * probe->part().depth(p) < width) narrow = std::min(width, probe->part().thickness(p));
    }
    *fit = std::min(width, narrow / spec->min_cells_across);
    return true;
  }

  void emit(const double lo[3], double s, bool cut, bool as_cell) {
    Cell cell;
    cell.region = region;
    cell.frame = frame_index;
    cell.lo[0] = lo[0]; cell.lo[1] = lo[1]; cell.lo[2] = lo[2];
    cell.size = s;
    cell.cut = cut;
    cell.own = base_mm;
    if (as_cell) {
      cell.band = band_t(lo, s);
      cell.finest = is_finest(s);
      out->cells.push_back(cell);
      ++tally->cells;
    } else {
      // D8, D14: lattice was asked for, and no allowed cell fits the wall here. Solid.
      out->solid.push_back(cell);
      ++tally->solid;
    }
  }

  // A cube of the frame: emit it as a cell, split it, or record it as solid.
  void place(const double lo[3], double s, bool top = true) {
    // 27 points: the centre and a 3 x 3 x 3 grid a third of the cell apart.
    int inside = 0;
    double fits = 1e300;   // the largest cell every counted point's wall allows
    for (int c = 0; c < 3; ++c)
      for (int b = 0; b < 3; ++b)
        for (int a = 0; a < 3; ++a) {
          double fit = 0.0;
          if (!sample(lo[0] + s * (1 + 2 * a) / 6.0, lo[1] + s * (1 + 2 * b) / 6.0,
                      lo[2] + s * (1 + 2 * c) / 6.0, &fit))
            continue;
          ++inside;
          fits = std::min(fits, fit);
        }
    if (inside == 0) return;   // nothing of this pass here
    const bool cut = inside < 27;   // D3: a whole cell, cut by the edge
    // A width is read to about a micron (PartMeasure::reach), so a cell that fits its
    // wall exactly must not be refused over the last digits of the reading.
    const bool fitting = s <= fits + kReadingSlack;
    // Too large this close to the outline, or cut by it (G1-G3, G10).
    const bool held = !band_allows(lo, s) || !whole_in_outline(lo, s);
    if (fitting && !held) {
      emit(lo, s, cut, true);
      return;
    }
    const double h = 0.5 * s;
    // C7. Below the open look's floor a cell is divided for the band alone (G11).
    if (spec->algorithm == Algorithm::DefaultGrade && allowed(h) &&
        (held || h >= out->floor_cell_mm * (1.0 - 1e-9))) {
      for (int c = 0; c < 2; ++c)
        for (int b = 0; b < 2; ++b)
          for (int a = 0; a < 2; ++a) {
            const double q[3] = {lo[0] + a * h, lo[1] + b * h, lo[2] + c * h};
            place(q, h, false);
          }
      return;
    }
    if (spec->algorithm == Algorithm::Stepped && top && pack(lo, s, held)) return;
    // G6: a cell that cannot be divided further stands; nothing goes solid for the band.
    emit(lo, s, cut, fitting);
  }

  // ── STEPPED: pack one base cell from one shared unit (C6-C6c, C13) ────────────
  // The base cell S did not fit. For each fraction n whose unit t = S/n prints open,
  // the base cell is n x n x n units; cells of m units (m = n-1 .. 1), each starting on
  // a whole unit, are placed largest first wherever the wall allows them (C1). Of the
  // fractions, the one that covers the most of the lattice here wins, then the one with
  // the fewest cells (C6c). Returns false when no fraction places anything.
  struct Packed {
    int n = 0;
    long covered = 0, asked = 0;   // sample points with lattice asked: in a cell / in all
    std::vector<std::array<int, 4>> cubes;   // i, j, k, m (in units)
    std::vector<std::array<int, 3>> bare;    // units with lattice asked and no cell
    std::vector<unsigned char> cut;          // per cube
  };
  bool pack(const double lo[3], double S, bool held) {
    Packed best;
    for (int n : divisors) {
      if (n < 2) continue;
      const double t = S / n;
      // Each unit read at 8 points (a 2 x 2 x 2 grid half a unit apart).
      const std::size_t N = static_cast<std::size_t>(n) * n * n;
      std::vector<unsigned char> in(N, 0);
      std::vector<double> fit(N, 1e300);
      for (int k = 0; k < n; ++k)
        for (int j = 0; j < n; ++j)
          for (int i = 0; i < n; ++i) {
            const std::size_t u = (static_cast<std::size_t>(k) * n + j) * n + i;
            for (int c = 0; c < 2; ++c)
              for (int b = 0; b < 2; ++b)
                for (int a = 0; a < 2; ++a) {
                  double f = 0.0;
                  if (!sample(lo[0] + t * (i + 0.25 + 0.5 * a), lo[1] + t * (j + 0.25 + 0.5 * b),
                              lo[2] + t * (k + 0.25 + 0.5 * c), &f))
                    continue;
                  ++in[u];
                  fit[u] = std::min(fit[u], f);
                }
            if (in[u]) continue;
            // None of the eight: look again just inside the unit's corners, so a sliver
            // of lattice at its edge is seen, and is a cut cell or listed as solid (D14)
            // rather than left out of the layout.
            for (int c = 0; c < 2 && !in[u]; ++c)
              for (int b = 0; b < 2 && !in[u]; ++b)
                for (int a = 0; a < 2 && !in[u]; ++a) {
                  double f = 0.0;
                  if (!sample(lo[0] + t * (i + 0.04 + 0.92 * a), lo[1] + t * (j + 0.04 + 0.92 * b),
                              lo[2] + t * (k + 0.04 + 0.92 * c), &f))
                    continue;
                  in[u] = 1;
                  fit[u] = f;
                }
          }
      Packed p;
      p.n = n;
      std::vector<unsigned char> taken(N, 0);
      std::vector<std::pair<double, std::array<int, 3>>> spots;
      for (int m = n - 1; m >= 1; --m) {
        const double size = m * t;
        spots.clear();
        for (int k = 0; k + m <= n; ++k)
          for (int j = 0; j + m <= n; ++j)
            for (int i = 0; i + m <= n; ++i) {
              double deep = 0.0;
              if (band_region)
                deep = edge_distance(lo[0] + (i + 0.5 * m) * t, lo[1] + (j + 0.5 * m) * t,
                                     lo[2] + (k + 0.5 * m) * t);
              spots.push_back({std::round(deep * 1e6) / 1e6, {i, j, k}});
            }
        // In a band the larger cells take the places farthest from the outline, so the
        // smaller ones are left toward it (G1). Elsewhere, the order they are read in.
        if (band_region)
          std::stable_sort(spots.begin(), spots.end(),
                           [](const auto& x, const auto& y) { return x.first > y.first; });
        for (const auto& spot : spots) {
          const int i = spot.second[0], j = spot.second[1], k = spot.second[2];
          bool free = true;
          int some = 0, all = 0;
          double f = 1e300;
          for (int c = k; c < k + m && free; ++c)
            for (int b = j; b < j + m && free; ++b)
              for (int a = i; a < i + m; ++a) {
                const std::size_t u = (static_cast<std::size_t>(c) * n + b) * n + a;
                if (taken[u]) { free = false; break; }
                some += in[u];
                all += 8;
                f = std::min(f, fit[u]);
              }
          if (!free || some == 0 || size > f + kReadingSlack) continue;
          const double at[3] = {lo[0] + i * t, lo[1] + j * t, lo[2] + k * t};
          if (!band_allows(at, size) || !whole_in_outline(at, size) || !fine_allowed(at, size))
            continue;
          for (int c = k; c < k + m; ++c)
            for (int b = j; b < j + m; ++b)
              for (int a = i; a < i + m; ++a)
                taken[(static_cast<std::size_t>(c) * n + b) * n + a] = 1;
          p.covered += some;
          p.cubes.push_back({i, j, k, m});
          p.cut.push_back(some < all);
        }
      }
      for (int k = 0; k < n; ++k)
        for (int j = 0; j < n; ++j)
          for (int i = 0; i < n; ++i) {
            const std::size_t u = (static_cast<std::size_t>(k) * n + j) * n + i;
            p.asked += in[u];
            if (in[u] && !taken[u]) p.bare.push_back({i, j, k});
          }
      if (p.cubes.empty()) continue;
      // Most covered, then fewest cells, then the coarser unit (the smaller n).
      // C1 before C6c: "largest cells, fewest cells ... the smallest only where no
      // larger cell fits". A finer unit always hugs an edge a little closer, and would
      // win every time on coverage alone; so coverage within a tenth counts as the same,
      // and the fewer, larger cells are kept. What the larger cells leave at the edge is
      // a sliver, which is solid (C8).
      // Coverage is the share of the lattice asked for here that ends up in a cell.
      const long mine = p.covered * best.asked, theirs = best.covered * p.asked;
      // Inside a Grade to shape band the finest cells are wanted at the outline, so there
      // coverage is compared exactly (G3, G6).
      const bool more = held ? mine > theirs : mine * 100 > theirs * 110;
      const bool same = !more && (held ? mine == theirs : mine * 110 >= theirs * 100);
      if (best.n == 0 || more || (same && p.cubes.size() < best.cubes.size()))
        best = std::move(p);
    }
    if (best.n == 0) return false;
    const double t = S / best.n;
    for (std::size_t q = 0; q < best.cubes.size(); ++q) {
      const auto& c = best.cubes[q];
      const double at[3] = {lo[0] + c[0] * t, lo[1] + c[1] * t, lo[2] + c[2] * t};
      emit(at, c[3] * t, best.cut[q] != 0, true);
    }
    for (const auto& u : best.bare) {
      const double at[3] = {lo[0] + u[0] * t, lo[1] + u[1] * t, lo[2] + u[2] * t};
      emit(at, t, true, false);
    }
    return true;
  }
};

// Slots along one axis covering [lo, hi] with cells of `s`, the leftover shared equally
// between the two ends (C9: a symmetric extent gets a symmetric layout).
void centred(double lo, double hi, double s, double* start, int* count) {
  const double ext = hi - lo;
  *count = std::max(1, static_cast<int>(std::ceil(ext / s - 1e-9)));
  *start = 0.5 * (lo + hi) - 0.5 * *count * s;
}

}  // namespace

Layout lay_cells(const Domain& domain, const CellSpec& spec, int threads) {
  Layout out;
  const int thread_count =
      threads > 0 ? threads : std::max(1, static_cast<int>(std::thread::hardware_concurrency()));
  const DomainSpec& ds = domain.spec();
  out.floor_cell_mm = ds.bead_mm / kSteppedPrintsOpenMaxStrutPerCell;   // C14
  out.bead_mm = ds.bead_mm;
  out.topology = spec.topology;
  // A hair above the bound itself, so the floor cell is a size core's own menu admits.
  const double smallest = std::max(out.floor_cell_mm * (1.0 + 1e-9), spec.cell_min_mm);
  const double target = spec.cell_mm > 0.0 ? spec.cell_mm : spec.cell_max_mm;
  const Domain::Probe probe = domain.probe();
  const PartMeasure& part = domain.measure();
  const int k_min = std::max(1, spec.min_cells_across);

  // Lay one pass over the box [lo, hi] of its frame, in slots of `base`.
  auto lay = [&](Pass& pass, double base, const double lo[3], const double hi[3],
                 bool depth_from_zero) {
    // G11: with "finer cells in the band" on, a band's cells go below the open look's
    // floor, down to the smallest cell one line can draw without closing it (the quilt).
    const bool fine = pass.band_region != nullptr && spec.band_fine_cells;
    const double tile_min =
        fine ? std::max(spec.cell_min_mm, ds.bead_mm / kQuiltStrutPerCell) : spec.cell_min_mm;
    if (spec.algorithm == Algorithm::DefaultGrade)
      // The halving ladder and its printable floor are core's own (ruling A, C7, C14).
      pass.sizes = stepped_size_menu(spec.topology, base, ds.bead_mm, tile_min, !fine,
                                     SteppedMenu::Halves);
    else
      pass.sizes = {base};
    pass.divisors.clear();
    if (spec.algorithm == Algorithm::Stepped)
      // Which fractions' units print open is core's own rule (C6a).
      pass.divisors = stepped_admitted_divisors(spec.topology, base, ds.bead_mm, tile_min,
                                                !fine, SteppedMenu::AnyStep);
    pass.base_mm = base;
    pass.finest_mm = base;
    for (double a : pass.sizes) pass.finest_mm = std::min(pass.finest_mm, a);
    for (int n : pass.divisors)
      if (n >= 2) pass.finest_mm = std::min(pass.finest_mm, base / n);
    double start[3];
    int count[3];
    for (int a = 0; a < 3; ++a) centred(lo[a], hi[a], base, &start[a], &count[a]);
    if (depth_from_zero) {   // C15: the face is a cell boundary
      start[2] = lo[2];
      count[2] = std::max(1, static_cast<int>(std::llround((hi[2] - lo[2]) / base)));
    }
    // Each base cell is laid on its own, so they are shared between threads and put
    // back in the order one thread would have laid them: the layout is the same for any
    // number of threads (D18). A probe serves one thread, so each takes its own.
    const std::size_t total = static_cast<std::size_t>(count[0]) * count[1] * count[2];
    auto slot = [&](std::size_t i, double q[3]) {
      const std::size_t a = i % count[0], b = (i / count[0]) % count[1], c = i / (static_cast<std::size_t>(count[0]) * count[1]);
      q[0] = start[0] + a * base; q[1] = start[1] + b * base; q[2] = start[2] + c * base;
    };
    const int nt = static_cast<int>(std::min<std::size_t>(static_cast<std::size_t>(thread_count), total));
    if (nt <= 1) {
      for (std::size_t i = 0; i < total; ++i) {
        double q[3];
        slot(i, q);
        pass.place(q, base);
      }
      return;
    }
    struct Piece { std::vector<Cell> cells, solid; };
    std::vector<Piece> pieces(total);
    std::atomic<std::size_t> next{0};
    auto work = [&]() {
      const Domain::Probe mine = domain.probe();
      Layout local;
      local.floor_cell_mm = out.floor_cell_mm;
      RegionCells count_here;
      Pass p = pass;
      p.probe = &mine;
      p.out = &local;
      p.tally = &count_here;
      for (std::size_t i = next.fetch_add(1); i < total; i = next.fetch_add(1)) {
        double q[3];
        slot(i, q);
        p.place(q, base);
        pieces[i].cells.swap(local.cells);
        pieces[i].solid.swap(local.solid);
        local.cells.clear();
        local.solid.clear();
      }
    };
    std::vector<std::thread> pool;
    for (int t = 1; t < nt; ++t) pool.emplace_back(work);
    work();
    for (std::thread& t : pool) t.join();
    for (const Piece& piece : pieces) {
      out.cells.insert(out.cells.end(), piece.cells.begin(), piece.cells.end());
      out.solid.insert(out.solid.end(), piece.solid.begin(), piece.solid.end());
      pass.tally->cells += piece.cells.size();
      pass.tally->solid += piece.solid.size();
    }
  };
  // A region's frame and its tally; returns the pass to lay with.
  auto open = [&](int region, const Frame& frame, double depth_cap, double base) {
    Pass pass;
    pass.probe = &probe;
    pass.spec = &spec;
    pass.region = region;
    pass.frame_index = static_cast<int>(out.frames.size());
    pass.frame = frame;
    pass.depth_cap = depth_cap;
    pass.out = &out;
    out.frames.push_back(frame);
    RegionCells tally;
    tally.region = region;
    tally.frame = pass.frame_index;
    tally.base_cell_mm = base;
    out.regions.push_back(tally);
    return pass;
  };
  auto run = [&](int region, const Frame& frame, double depth_cap, double base,
                 const double lo[3], const double hi[3], bool depth_from_zero) {
    Pass pass = open(region, frame, depth_cap, base);
    pass.tally = &out.regions.back();
    lay(pass, base, lo, hi, depth_from_zero);
  };
  // C15, C2, C3-C5, C1: the cell that divides a wall of `width` exactly, never wider than
  // it, holding at least the cells it must, otherwise as few and as large as allowed.
  auto divide = [&](double width, int* layers) {
    *layers = std::max(k_min, static_cast<int>(std::ceil(width / target - 1e-9)));
    return width / *layers;
  };

  // The part's own frame, centred on it (C9). Used by the whole part and by curved regions.
  Frame world;
  world.origin = Vec3{0.5 * (part.lo().x + part.hi().x), 0.5 * (part.lo().y + part.hi().y),
                      0.5 * (part.lo().z + part.hi().z)};
  const double wlo[3] = {part.lo().x - world.origin.x, part.lo().y - world.origin.y,
                         part.lo().z - world.origin.z};
  const double whi[3] = {-wlo[0], -wlo[1], -wlo[2]};
  // The base cell where no wall names it. Auto under Default Grade: the largest size
  // not above the target whose halves land exactly on the smallest cell, so the ladder
  // reaches the floor instead of stopping a fraction above it (C17).
  auto world_base = [&]() {
    if (spec.algorithm != Algorithm::DefaultGrade || spec.cell_mm > 0.0) return target;
    double s = smallest;
    while (s * 2.0 <= target * (1.0 + 1e-9)) s *= 2.0;
    return s;
  };

  // Regions are already in id order (D13), the whole part last.
  for (const Region& r : ds.regions) {
    if (r.role != Role::Lattice) continue;
    if (r.is_shell()) {
      run(r.id, world, r.shell_depth_mm, world_base(), wlo, whi, false);
      continue;
    }
    const ClearanceGeometry& g = r.prism;
    if (!g.valid || g.kind != ClearanceKind::Face) continue;
    int k = 0;
    const double base = divide(g.depth, &k);
    Frame f;
    f.origin = g.origin;
    f.ax[0] = g.u; f.ax[1] = g.w; f.ax[2] = g.normal;
    const double e = std::max(0.0, r.expand_mm);
    const double lo[3] = {g.u_lo - e, g.w_lo - e, 0.0};
    const double hi[3] = {g.u_hi + e, g.w_hi + e, g.depth};

    // The walls under this face: read the wall's width on a coarse map of the face,
    // just under it, and gather the stretches of one width.
    WallMap map;
    map.u0 = lo[0]; map.w0 = lo[1];
    map.nu = static_cast<int>(std::ceil((hi[0] - lo[0]) / WallMap::kPitch)) + 1;
    map.nw = static_cast<int>(std::ceil((hi[1] - lo[1]) / WallMap::kPitch)) + 1;
    map.bin.assign(static_cast<std::size_t>(map.nu) * map.nw, -1);
    map.wall.assign(map.bin.size(), -1);
    const double under = std::min(0.02, 0.25 * g.depth);
    for (int j = 0; j < map.nw; ++j)
      for (int i = 0; i < map.nu; ++i) {
        double width = 0.0;
        const Where w = probe.where(
            f.at(map.u0 + i * WallMap::kPitch, map.w0 + j * WallMap::kPitch, under), &width);
        if (w.lattice() && w.id == r.id)
          map.bin[static_cast<std::size_t>(j) * map.nu + i] = WallMap::bin_of(std::min(width, g.depth));
      }
    std::vector<int> stack;
    for (std::size_t n0 = 0; n0 < map.bin.size(); ++n0) {
      if (map.bin[n0] < 0 || map.wall[n0] != -1) continue;
      // One stretch: neighbours of the same width.
      std::vector<std::size_t> nodes;
      stack.assign(1, static_cast<int>(n0));
      map.wall[n0] = -2;
      while (!stack.empty()) {
        const std::size_t n = static_cast<std::size_t>(stack.back());
        stack.pop_back();
        nodes.push_back(n);
        const int i = static_cast<int>(n % map.nu), j = static_cast<int>(n / map.nu);
        const int nb[4][2] = {{i - 1, j}, {i + 1, j}, {i, j - 1}, {i, j + 1}};
        for (const auto& q : nb) {
          if (q[0] < 0 || q[1] < 0 || q[0] >= map.nu || q[1] >= map.nw) continue;
          const std::size_t m = static_cast<std::size_t>(q[1]) * map.nu + q[0];
          if (map.wall[m] != -1 || map.bin[m] != map.bin[n0]) continue;
          map.wall[m] = -2;
          stack.push_back(static_cast<int>(m));
        }
      }
      WallMap::Wall wall;
      wall.width = map.bin[n0] * WallMap::kBin;
      // The exact width, not the bin's: read it again at the stretch's first node.
      {
        double width = 0.0;
        probe.where(f.at(map.u0 + (n0 % map.nu) * WallMap::kPitch,
                         map.w0 + (n0 / map.nu) * WallMap::kPitch, under), &width);
        // ... to the precision it is read at: a 12 mm wall is 12, not 11.9999995.
        wall.width = std::round(std::min(width, g.depth) * 1e5) / 1e5;
      }
      wall.cell = divide(wall.width, &wall.layers);
      // A wall is a stretch wide enough for its own cells (two by two of them) whose
      // cell prints. Anything else is left to the pass below, cell by cell.
      const double area = nodes.size() * WallMap::kPitch * WallMap::kPitch;
      const bool is_wall = wall.cell >= smallest && area >= 4.0 * wall.cell * wall.cell;
      wall.lo[0] = wall.lo[1] = 1e300;
      wall.hi[0] = wall.hi[1] = -1e300;
      for (std::size_t n : nodes) {
        map.wall[n] = is_wall ? static_cast<int>(map.walls.size()) : -3;
        const double u = map.u0 + (n % map.nu) * WallMap::kPitch, w = map.w0 + (n / map.nu) * WallMap::kPitch;
        wall.lo[0] = std::min(wall.lo[0], u); wall.hi[0] = std::max(wall.hi[0], u);
        wall.lo[1] = std::min(wall.lo[1], w); wall.hi[1] = std::max(wall.hi[1], w);
      }
      if (is_wall) {
        // The map's nodes stop short of the stretch's true edge by up to one step. Find
        // the edge itself, outward from the outermost nodes, so the cells are centred on
        // the real stretch (and a symmetric one gets a symmetric layout, exactly).
        const long want = map.bin[n0];
        auto in_wall = [&](double u, double w) {
          double width = 0.0;
          const Where h = probe.where(f.at(u, w, under), &width);
          return h.lattice() && h.id == r.id &&
                 std::labs(WallMap::bin_of(std::min(width, g.depth)) - want) <= 1;
        };
        double edge[2][2] = {{wall.lo[0], wall.hi[0]}, {wall.lo[1], wall.hi[1]}};
        for (std::size_t n : nodes) {
          const double at[2] = {map.u0 + (n % map.nu) * WallMap::kPitch, map.w0 + (n / map.nu) * WallMap::kPitch};
          for (int axis = 0; axis < 2; ++axis)
            for (int side = 0; side < 2; ++side) {
              const double extreme = side ? wall.hi[axis] : wall.lo[axis];
              if (std::fabs(at[axis] - extreme) > 1e-9) continue;
              double in = at[axis], outside = at[axis] + (side ? WallMap::kPitch : -WallMap::kPitch);
              for (int it = 0; it < 50; ++it) {
                const double m = 0.5 * (in + outside);
                const bool yes = axis == 0 ? in_wall(m, at[1]) : in_wall(at[0], m);
                if (yes) in = m; else outside = m;
              }
              const double found = std::round(0.5 * (in + outside) * 1e7) / 1e7;
              edge[axis][side] = side ? std::max(edge[axis][side], found) : std::min(edge[axis][side], found);
            }
        }
        wall.lo[0] = edge[0][0]; wall.hi[0] = edge[0][1];
        wall.lo[1] = edge[1][0]; wall.hi[1] = edge[1][1];
        // Its true extent must hold one of its cells each way as well: a ledge a tenth
        // of a millimetre wide catches a whole row of map nodes and is not a wall. (One,
        // not two: a rib one cell wide along the face is still a wall of its own depth.)
        if (wall.hi[0] - wall.lo[0] >= wall.cell - kReadingSlack &&
            wall.hi[1] - wall.lo[1] >= wall.cell - kReadingSlack) {
          map.walls.push_back(wall);
        } else {
          for (std::size_t n : nodes) map.wall[n] = -3;
        }
      }
    }
    for (int& w : map.wall)
      if (w < 0) w = -1;

    Pass pass = open(r.id, f, g.depth, base);
    pass.tally = &out.regions.back();
    pass.walls = &map;
    if (spec.grade_to_shape && spec.band_mm > 0.0) pass.band_region = &r;
    for (std::size_t i = 0; i < map.walls.size(); ++i) {
      const WallMap::Wall& wall = map.walls[i];
      pass.wall = static_cast<int>(i);
      // Centred on the wall's own stretch (C9, per wall).
      const double wlo3[3] = {wall.lo[0], wall.lo[1], 0.0};
      const double whi3[3] = {wall.hi[0], wall.hi[1], wall.width};
      lay(pass, wall.cell, wlo3, whi3, true);
    }
    pass.wall = -1;   // what no wall holds: cell by cell from the region's own base
    lay(pass, base, lo, hi, true);
  }
  if (ds.start == Start::AllLattice) run(0, world, 1e300, world_base(), wlo, whi, false);
  return out;
}

}  // namespace topopt::lattice_layout
