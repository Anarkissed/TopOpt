// Lattice layout, stage C: the cells. See lattice_layout.hpp.
#include "topopt/lattice_layout.hpp"

#include <algorithm>
#include <cmath>

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
  Layout* out;
  RegionCells* tally;
  const WallMap* walls = nullptr;   // a flat region's walls, if it has any
  int wall = -1;                    // the wall this pass lays; -1 = what no wall holds

  bool allowed(double s) const {
    for (double a : sizes)
      if (std::fabs(a - s) <= 1e-9 * std::max(a, s)) return true;
    return false;
  }

  // A cube of the frame: emit it as a cell, split it, or record it as solid.
  void place(const double lo[3], double s) {
    // 27 points: the centre and a 3 x 3 x 3 grid a third of the cell apart. A point
    // counts when the layout's one Domain says lattice goes there AND this region owns
    // it (D13: ownership is the Domain's answer at the point, never the order of work).
    int inside = 0;
    double fits = 1e300;   // the largest cell every counted point's wall allows
    for (int c = 0; c < 3; ++c)
      for (int b = 0; b < 3; ++b)
        for (int a = 0; a < 3; ++a) {
          const Vec3 p = frame.at(lo[0] + s * (1 + 2 * a) / 6.0, lo[1] + s * (1 + 2 * b) / 6.0,
                                  lo[2] + s * (1 + 2 * c) / 6.0);
          double width = 0.0;
          const Where w = probe->where(p, &width);
          if (!w.lattice() || w.id != region) continue;
          if (walls) {   // this pass lays one wall (or the rest), and nothing else
            const double a2 = lo[0] + s * (1 + 2 * a) / 6.0, b2 = lo[1] + s * (1 + 2 * b) / 6.0;
            if (walls->find(a2, b2, std::min(width, depth_cap)) != wall) continue;
          }
          ++inside;
          // C2, C3-C5, C12: never wider than the wall over the cells it must hold; the
          // wall is the material at this spot, and never more than the region's depth.
          fits = std::min(fits, std::min(width, depth_cap) / spec->min_cells_across);
        }
    if (inside == 0) return;   // nothing of this region here
    Cell cell;
    cell.region = region;
    cell.frame = frame_index;
    cell.lo[0] = lo[0]; cell.lo[1] = lo[1]; cell.lo[2] = lo[2];
    cell.size = s;
    cell.cut = inside < 27;    // D3: a whole cell, cut by the edge
    // A width is read to about a micron (PartMeasure::reach), so a cell that fits its
    // wall exactly must not be refused over the last digits of the reading.
    if (s <= fits + kReadingSlack) {
      out->cells.push_back(cell);
      ++tally->cells;
      return;
    }
    const double h = 0.5 * s;
    if (spec->algorithm == Algorithm::DefaultGrade && allowed(h)) {   // C7
      for (int c = 0; c < 2; ++c)
        for (int b = 0; b < 2; ++b)
          for (int a = 0; a < 2; ++a) {
            const double q[3] = {lo[0] + a * h, lo[1] + b * h, lo[2] + c * h};
            place(q, h);
          }
      return;
    }
    // D8, D14: lattice was asked for, and no allowed cell fits the wall here. Solid.
    out->solid.push_back(cell);
    ++tally->solid;
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

Layout lay_cells(const Domain& domain, const CellSpec& spec) {
  Layout out;
  const DomainSpec& ds = domain.spec();
  out.floor_cell_mm = ds.bead_mm / kSteppedPrintsOpenMaxStrutPerCell;   // C14
  // A hair above the bound itself, so the floor cell is a size core's own menu admits.
  const double smallest = std::max(out.floor_cell_mm * (1.0 + 1e-9), spec.cell_min_mm);
  const double target = spec.cell_mm > 0.0 ? spec.cell_mm : spec.cell_max_mm;
  const Domain::Probe probe = domain.probe();
  const PartMeasure& part = domain.measure();
  const int k_min = std::max(1, spec.min_cells_across);

  // Lay one pass over the box [lo, hi] of its frame, in slots of `base`.
  auto lay = [&](Pass& pass, double base, const double lo[3], const double hi[3],
                 bool depth_from_zero) {
    if (spec.algorithm == Algorithm::DefaultGrade)
      // The halving ladder and its printable floor are core's own (ruling A, C7, C14).
      pass.sizes = stepped_size_menu(spec.topology, base, ds.bead_mm, spec.cell_min_mm, true,
                                     SteppedMenu::Halves);
    else
      pass.sizes = {base};
    double start[3];
    int count[3];
    for (int a = 0; a < 3; ++a) centred(lo[a], hi[a], base, &start[a], &count[a]);
    if (depth_from_zero) {   // C15: the face is a cell boundary
      start[2] = lo[2];
      count[2] = std::max(1, static_cast<int>(std::llround((hi[2] - lo[2]) / base)));
    }
    for (int c = 0; c < count[2]; ++c)
      for (int b = 0; b < count[1]; ++b)
        for (int a = 0; a < count[0]; ++a) {
          const double q[3] = {start[0] + a * base, start[1] + b * base, start[2] + c * base};
          pass.place(q, base);
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
