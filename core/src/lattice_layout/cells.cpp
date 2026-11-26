// Lattice layout, stage C: the cells. See lattice_layout.hpp.
#include "topopt/lattice_layout.hpp"

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <thread>
#include <unordered_map>

#include "topopt/stepped_plan.hpp"  // stepped_size_menu, kSteppedPrintsOpenMaxStrutPerCell
#include "topopt/strut_cell.hpp"    // K8: the type's struts, so a stretch never lays one flatter

namespace topopt::lattice_layout {

long WallMap::bin_of(double width) { return std::lround(width / kBin); }

int WallMap::find(double u, double w, double start, double width) const {
  if (walls.empty()) return -1;
  const long b = bin_of(width), sb = bin_of(start);
  const int i = static_cast<int>(std::floor((u - u0) / kPitch));
  const int j = static_cast<int>(std::floor((w - w0) / kPitch));
  for (int dj = 0; dj <= 1; ++dj)
    for (int di = 0; di <= 1; ++di) {
      const int a = i + di, c = j + dj;
      if (a < 0 || c < 0 || a >= nu || c >= nw) continue;
      for (int k = 0; k < kDeep; ++k) {
        const std::size_t n = (static_cast<std::size_t>(c) * nu + a) * kDeep + k;
        if (wall[n] >= 0 && std::labs(bin[n] - b) <= 1 && std::labs(sbin[n] - sb) <= 1)
          return wall[n];
      }
    }
  return -1;
}

namespace {
// How closely a wall's width is read, with margin: 10 nanometres on a half-width.
constexpr double kReadingSlack = 1e-5;   // mm

// The lattice's column through a point `c` below a flat region's face, from what the
// Domain read there. It starts at the face; or at a Protect skin's inner side (D5, D15);
// or, with a pocket under the face, where the material the point is in begins. It ends at
// the far surface, a skin on it, or the region's depth (C12). The wall the cells divide
// is that column and nothing else (C2): not material beyond a pocket, nor beyond the depth.
void column_of(const Domain::Probe::Room& room, double c, double depth, double* start,
               double* width) {
  const double lo = c - (room.skin_back ? room.back : room.part_back);
  const double hi = std::min(c + (room.skin_on ? room.on : room.part_on), depth);
  *start = room.skin_back || lo > kReadingSlack ? lo : 0.0;
  *width = hi - *start;
}
}  // namespace

Reading read_at(const Domain::Probe& probe, const Frame& frame, const WallMap& walls,
                double a, double b, double c) {
  Reading r;
  Domain::Probe::Room room;
  r.where = probe.where(frame.at(a, b, c), &r.width, walls.flat ? &room : nullptr);
  if (!r.where.lattice()) return r;
  if (walls.flat) {
    column_of(room, c, walls.depth, &r.start, &r.width);
    r.wall = walls.find(a, b, r.start, r.width);
  } else {
    r.width = std::min(r.width, walls.depth);   // C12: never more than the region's depth
  }
  return r;
}

std::shared_ptr<const CellIndex> index_cells(const Layout& layout, double pitch) {
  auto made = std::make_shared<CellIndex>();
  made->pitch = pitch;
  auto slot = [&](double x) { return static_cast<long long>(std::floor(x / pitch)); };
  for (std::size_t ci = 0; ci < layout.cells.size(); ++ci) {
    const Cell& c = layout.cells[ci];
    const Frame& f = layout.frames[static_cast<std::size_t>(c.frame)];
    double mn[3] = {1e300, 1e300, 1e300}, mx[3] = {-1e300, -1e300, -1e300};
    for (int k = 0; k < 8; ++k) {
      const Vec3 v = f.at(c.lo[0] + ((k & 1) ? c.size : 0.0), c.lo[1] + ((k & 2) ? c.size : 0.0),
                          c.lo[2] + ((k & 4) ? c.size : 0.0));
      mn[0] = std::min(mn[0], v.x); mx[0] = std::max(mx[0], v.x);
      mn[1] = std::min(mn[1], v.y); mx[1] = std::max(mx[1], v.y);
      mn[2] = std::min(mn[2], v.z); mx[2] = std::max(mx[2], v.z);
    }
    for (long long x = slot(mn[0]); x <= slot(mx[0]); ++x)
      for (long long y = slot(mn[1]); y <= slot(mx[1]); ++y)
        for (long long z = slot(mn[2]); z <= slot(mx[2]); ++z)
          made->grid[{x, y, z}].push_back(static_cast<std::uint32_t>(ci));
  }
  return made;
}

namespace {
// `p` in the cell's own frame; false when it is outside the cell's cube.
bool in_cube(const Layout& layout, const Cell& cell, const Vec3& p, double q[3]) {
  const Frame& f = layout.frames[static_cast<std::size_t>(cell.frame)];
  const Vec3 rel{p.x - f.origin.x, p.y - f.origin.y, p.z - f.origin.z};
  for (int a = 0; a < 3; ++a) {
    q[a] = rel.x * f.ax[a].x + rel.y * f.ax[a].y + rel.z * f.ax[a].z;
    if (q[a] < cell.lo[a] || q[a] >= cell.lo[a] + cell.size) return false;
  }
  return true;
}
// Is the point lattice of the cell's own region and wall? `other`: it is lattice of ANOTHER region, and not a weave's
// (O1: a weave's lattice is open space, never a cube cell's to take in).
// (Lattice of the cell's own region under another wall, or under none, is neither: a wall too thin for its cell
// is solid by D8 and stays solid, whoever's cube reaches over it.)
bool own(const Layout& layout, const Domain::Probe& probe, const Cell& cell, const double q[3], bool* other) {
  const Frame& f = layout.frames[static_cast<std::size_t>(cell.frame)];
  const WallMap& walls = layout.walls[static_cast<std::size_t>(cell.frame)];
  if (!walls.flat) {
    // No wall to name: only "lattice, and whose" is asked, so no width is measured (the costly part of a reading).
    const Where w = probe.where(f.at(q[0], q[1], q[2]));
    if (other) *other = w.lattice() && w.id != cell.region && !layout.is_weave(w.id);
    return w.lattice() && w.id == cell.region;
  }
  const Reading r = read_at(probe, f, walls, q[0], q[1], q[2]);
  if (other) *other = r.where.lattice() && r.where.id != cell.region && !layout.is_weave(r.where.id);
  return r.where.lattice() && r.where.id == cell.region && r.wall == cell.wall;
}
// D14b: lattice of another region at `p`, inside `cell`'s cube. The cell takes it in when no cell holds it as its
// own and this cell is the first, in layout order, of the cells of other regions whose cube it is in.
bool takes_in(const Layout& layout, const Domain::Probe& probe, std::size_t cell, const Vec3& p) {
  if (!layout.absorb || !layout.index) return false;
  // P8 (f): a cube the thin-piece rule made solid stays solid; no cell of another region takes its lattice in.
  for (std::uint32_t si : layout.thin_solid) {
    double q[3];
    if (in_cube(layout, layout.solid[si], p, q)) return false;
  }
  const CellIndex& ix = *layout.index;
  const auto it = ix.grid.find({static_cast<long long>(std::floor(p.x / ix.pitch)), static_cast<long long>(std::floor(p.y / ix.pitch)),
                                static_cast<long long>(std::floor(p.z / ix.pitch))});
  if (it == ix.grid.end()) return false;
  long first = -1;
  for (std::uint32_t ci : it->second) {   // in cell order
    const Cell& d = layout.cells[ci];
    double q[3];
    if (!in_cube(layout, d, p, q)) continue;
    bool other = false;
    if (own(layout, probe, d, q, &other)) return false;   // its own cell holds it
    if (other && first < 0) first = static_cast<long>(ci);
  }
  return first == static_cast<long>(cell);
}
}  // namespace

bool cell_holds_at(const Layout& layout, const Domain::Probe& probe, std::size_t cell, double a, double b, double c) {
  const Cell& x = layout.cells[cell];
  const double q[3] = {a, b, c};
  bool other = false;
  if (own(layout, probe, x, q, &other)) return true;
  if (!other || !layout.absorb) return false;
  return takes_in(layout, probe, cell, layout.frames[static_cast<std::size_t>(x.frame)].at(a, b, c));
}

bool cell_holds(const Layout& layout, const Domain::Probe& probe, const Cell& cell, const Vec3& p) {
  double q[3];
  if (!in_cube(layout, cell, p, q)) return false;
  bool other = false;
  if (own(layout, probe, cell, q, &other)) return true;
  if (!other || !layout.absorb || layout.cells.empty()) return false;
  // Which cell of the layout this is (callers pass the layout's own cells).
  const Cell* first = layout.cells.data();
  if (&cell < first || &cell >= first + layout.cells.size()) return false;
  return takes_in(layout, probe, static_cast<std::size_t>(&cell - first), p);
}

namespace {

// C24: a size cap on a place of one base cell: no cell whose cube shares volume with the box may be larger than
// `size` (the finest always may).
struct Cap {
  double lo[3], hi[3];
  double size;
};

// One region's pass.
struct Pass {
  const Domain::Probe* probe;
  const CellSpec* spec;
  int region;
  int frame_index;
  Frame frame;
  std::vector<double> sizes;   // the sizes this region may use, largest first
  std::vector<int> divisors;   // Stepped: the fractions of the base whose unit prints open
  // C22: every size this pass can lay, largest first, each once: Default Grade its `sizes`; Stepped the base and every
  // m x base / n for each of its `divisors` n and m = 1 .. n - 1 (what `place` and `pack` can lay); Uniform the base.
  std::vector<double> ladder;
  Layout* out;
  RegionCells* tally;
  const WallMap* walls = nullptr;   // this frame's walls (flat = false where it has none)
  int wall = -1;                    // the wall this pass lays; -1 = what no wall holds
  const Region* band_region = nullptr;   // a flat region with Grade to shape on
  double base_mm = 0.0;             // this lay's own cell (S_base)
  double finest_mm = 0.0;           // the smallest cell its ladder allows (f)
  double floor_mm = 0.0;            // the smallest cell that may stand in this pass at all
  // ★ notes29b: this pass lays a THIN wall (CellSpec::small_in_thin_walls): its one cell, under the open look's floor,
  // never under Layout::thin_floor_cell_mm (floor_mm says so), and nothing else.
  bool thin = false;
  double skin_most = 0.0;           // the deepest Protect skin or cover of the domain
  // D14c: the region's depth (a wall is never read deeper; 1e300 for the whole part), and, under a flat face, the
  // depth whose own cell prints (0 elsewhere: the cell there does not come from the depth).
  double region_depth = 1e300;
  double depth_need = 0.0;
  // C22: the stress field when cell size by stress applies (null otherwise), its reference and response.
  const DemandField* demand = nullptr;
  double ref_mpa = 0.0;
  double response = 1.0;
  // C24: the size caps on the base cell being laid (null: none, the case whenever no size step is asked).
  const std::vector<Cap>* caps = nullptr;

  // What the counted points of a cube read (D14c): the narrowest wall, the narrowest member.
  struct Seen {
    double width = 1e300, narrow = 1e300;
  };
  // Rounded up to a micron: a wall or depth made exactly this lays a cell.
  static float up(double mm) { return static_cast<float>(std::ceil(mm * 1e3 - 1e-6) * 1e-3); }
  static float down(double mm) { return static_cast<float>(std::floor(mm * 1e3 + 1e-6) * 1e-3); }
  // D14c: why a cube holding this pass's lattice got no cell. `need` is the smallest cell tried at that spot;
  // `printable` and `fitting` are place's own tests. In the order of preference: RegionShallow, WallNarrow,
  // TooFewAcross. (Sliver is never the answer here: a cube recorded solid was refused by what its points read, so the
  // wall there is narrower than the cell, or holds too few of them. The cut piece that no cube is recorded for is
  // place's sliver under solid, below.)
  SolidWhy why_solid(double need, const Seen& seen, bool printable, bool fitting) const {
    SolidWhy y;
    if (!printable && depth_need > 0.0 && region_depth < depth_need - kReadingSlack) {
      y.why = NoCell::RegionShallow;
      y.have_mm = down(region_depth);
      y.need_mm = up(depth_need);
      return y;
    }
    if (fitting) return y;   // refused for its size alone (a cell setting under the floor): Other
    if (!walls->flat && region_depth < need - kReadingSlack && seen.width >= region_depth - kReadingSlack) {
      // A region with no face: the wall read is cut at the region's depth, and that is what is too thin.
      y.why = NoCell::RegionShallow;
      y.have_mm = down(region_depth);
      y.need_mm = up(need);
      return y;
    }
    const double thinnest = std::min(seen.width, seen.narrow);
    if (thinnest < need - kReadingSlack) {
      y.why = NoCell::WallNarrow;
      y.have_mm = down(thinnest);
      y.need_mm = up(need);
      return y;
    }
    const int k = std::max(1, spec->min_cells_across);
    if (k > 1 && seen.narrow / k < need - kReadingSlack) {
      y.why = NoCell::TooFewAcross;
      y.have_mm = down(seen.narrow);
      y.need_mm = up(k * need);
      return y;
    }
    return y;
  }

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
  // R16: the highest stress in the axis-aligned box round the cube's eight corners.
  double demand_in(const double lo[3], double s) const {
    Vec3 mn{1e300, 1e300, 1e300}, mx{-1e300, -1e300, -1e300};
    for (int k = 0; k < 8; ++k) {
      const Vec3 v = frame.at(lo[0] + ((k & 1) ? s : 0.0), lo[1] + ((k & 2) ? s : 0.0), lo[2] + ((k & 4) ? s : 0.0));
      mn.x = std::min(mn.x, v.x); mx.x = std::max(mx.x, v.x);
      mn.y = std::min(mn.y, v.y); mx.y = std::max(mx.y, v.y);
      mn.z = std::min(mn.z, v.z); mx.z = std::max(mx.z, v.z);
    }
    return demand->highest_in(mn, mx);
  }
  // C22's next size down: the largest size of the ladder strictly under s (0: none).
  double size_below(double s) const {
    for (double a : ladder)
      if (a < s * (1.0 - 1e-9)) return a;
    return 0.0;
  }
  // C22 (LatticeReview's ruling 2026-11-15: the nearest size): the stress asks for a size S* = S_base - t (S_base - f),
  // and a cell takes the size of its ladder nearest to it: a cell of size s may stand where S* >= (s + s_below) / 2,
  // s_below the ladder's next size down. A tie keeps the larger; the finest, and a size with none below, always may.
  bool stress_allows(const double lo[3], double s) const {
    if (!demand || is_finest(s)) return true;
    const double below = size_below(s);
    if (below <= 0.0) return true;
    const double t = std::pow(std::clamp(demand_in(lo, s) / ref_mpa, 0.0, 1.0), std::clamp(response, 0.25, 4.0));
    const double asked = base_mm - t * (base_mm - finest_mm);
    return asked >= 0.5 * (s + below) - 1e-9 * base_mm;
  }
  // C24: a cell of size s may stand where no cap whose box shares volume with its cube is smaller; the finest always
  // may. A cell held here is divided down its ladder as one the band does not allow.
  bool cap_allows(const double lo[3], double s) const {
    if (!caps || is_finest(s)) return true;
    for (const Cap& c : *caps) {
      bool overlap = true;
      for (int a = 0; a < 3 && overlap; ++a)
        overlap = std::min(lo[a] + s, c.hi[a]) - std::max(lo[a], c.lo[a]) > 1e-6;
      if (overlap && s > c.size * (1.0 + 1e-9)) return false;
    }
    return true;
  }
  // C20: with Let walls cut cells on (one_grid), only the finest cell is ever cut. A larger cell must lie whole in
  // lattice: its 27 points and the 26 a hair inside its faces, edges and corners (0.04 / 0.5 / 0.96, as D14b looks).
  // Lattice of any region counts (a seam between two lattice regions cuts nothing); a wall, pocket, hole, Protect
  // skin, No lattice region or the part's outside does. Held, the cell is split down its ladder as G10 splits it.
  bool whole_in_lattice(const double lo[3], double s) const {
    const double e[2][3] = {{1.0 / 6.0, 0.5, 5.0 / 6.0}, {0.04, 0.5, 0.96}};
    for (int g = 0; g < 2; ++g)
      for (int c = 0; c < 3; ++c)
        for (int b = 0; b < 3; ++b)
          for (int a = 0; a < 3; ++a) {
            if (g == 1 && a == 1 && b == 1 && c == 1) continue;
            if (!probe->where(frame.at(lo[0] + s * e[g][a], lo[1] + s * e[g][b], lo[2] + s * e[g][c])).lattice())
              return false;
          }
    return true;
  }
  // G10: with Grade to shape on, only the finest cell may be cut by the outline. Any
  // larger cell must lie whole inside it (read at its corners, edge middles and centre).
  bool whole_in_outline(const double lo[3], double s) const {
    if (spec->one_grid && !is_finest(s) && !whole_in_lattice(lo, s))   // C20
      return false;
    if (!band_region || is_finest(s)) return true;
    for (int b = 0; b < 3; ++b)
      for (int a = 0; a < 3; ++a)
        if (edge_distance(lo[0] + 0.5 * s * a, lo[1] + 0.5 * s * b, lo[2] + 0.5 * s) < -1e-6)
          return false;
    return true;
  }
  // G11: a cell below the open look's floor exists only inside the band.
  // C14: a cell too small to print does not stand, whatever it fits. (A region whose own
  // depth is under the floor has a base cell that small.)
  bool prints(const double lo[3], double s) const {
    return s >= floor_mm * (1.0 - 1e-9) && fine_allowed(lo, s);
  }
  bool fine_allowed(const double lo[3], double s) const {
    if (s >= out->floor_cell_mm * (1.0 - 1e-9)) return true;
    if (thin) return true;   // ★ notes29b: a thin wall's own cell (floor_mm holds it at the thin floor)
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
  bool sample(double a, double b, double c, double* fit, Seen* seen = nullptr) const {
    if (spec->one_grid) {
      // One grid, cut wherever (CellSpec::one_grid): only "lattice, and whose" is asked. No wall is read, so no cell
      // is refused for being wider than the material it stands in (C2) or for the cells a wall must hold (C3-C5).
      const Where w = probe->where(frame.at(a, b, c));
      if (!w.lattice() || w.id != region) return false;
      *fit = 1e300;
      return true;
    }
    const Reading r = read_at(*probe, frame, *walls, a, b, c);
    if (!r.where.lattice() || r.where.id != region) return false;
    if (walls->flat && r.wall != wall) return false;
    const double width = r.width;
    // C2, C12: never wider than the wall; the wall is the material at this spot along the
    // region's own direction, and never more than the region's depth.
    // C3-C5 (reviewer's ruling 2026-11-11): the cells a wall must hold are counted across
    // the member's NARROWEST width, whichever way that lies. A rib one cell wide across
    // the face and two deep is one across, not two.
    const double narrow = walls->flat ? narrowest(a, b, r) : width;
    *fit = std::min(width, narrow / spec->min_cells_across);
    if (seen) {
      seen->width = std::min(seen->width, width);
      seen->narrow = std::min(seen->narrow, narrow);
    }
    return true;
  }

  // The member's narrowest width, for the lattice's column through (a, b): read ONCE per
  // column, at the column's middle (the point of it farthest from both faces, where a
  // groove or a chamfer on either face cannot pass for a narrow member), and kept for
  // every other point of the column in this base cell. Twice the depth below the surface
  // is a ball that fits, so when the middle is half the column deep nothing through it is
  // narrower and no width is measured at all: the case on any plain wall.
  struct Column { double a, b, start, width, narrow; };
  mutable std::vector<Column> columns;   // of the base cell being laid; emptied per cell
  double narrowest(double a, double b, const Reading& r) const {
    for (std::size_t i = columns.size(); i-- > 0;) {
      const Column& c = columns[i];
      if (c.a == a && c.b == b && std::fabs(c.start - r.start) < 1e-6 &&
          std::fabs(c.width - r.width) < 1e-6)
        return c.narrow;
    }
    const Vec3 mid = frame.at(a, b, r.start + 0.5 * r.width);
    double narrow = r.width;
    // Only whether it is narrower than the column is asked, so the measure may stop early.
    // (Between skins: a skin takes at most its own depth off each end of the ball.)
    if (2.0 * (probe->part().depth(mid) - skin_most) < r.width - kReadingSlack)
      narrow = std::min(r.width, probe->room_through(mid, r.width));
    if (counts_space()) narrow = std::min(narrow, space_across(a, b, r.start + 0.5 * r.width, narrow));   // K5
    columns.push_back({a, b, r.start, r.width, narrow});
    return narrow;
  }

  // K5 (his yes, 2026-11-23: "Structural must refuse lattice strips only one cell wide"). On his stand Structural laid a
  // column of cells about 4 mm wide and 13 mm tall between an anchor hole's 4 mm Protect skin and the start of the end's
  // rounded corner: the member's narrowest width (room_through) is read across the MATERIAL, which is the toe's whole
  // height there, and the skin and the region's own edge narrow the lattice's room, not the material. So with the cells
  // a member must hold counted (no one grid) at Structural's count (three or more across: Aesthetic asks for one or
  // two; core does not know the stage), the member is also read across the LATTICE SPACE itself, in the face's plane:
  // its local width at the column: the width of the largest disc, or square on the face's own axes, of the region's own
  // lattice at the column's middle depth that holds the column (read on the face's map of stretches, kept with the
  // domain, at its 1 mm nodes: to about a millimetre). A strip is as wide as it is across, whichever way it runs; a wide
  // wall is wide everywhere in it, its edges and right-angled corners too. A strip narrower than its cells across is
  // refused as any thin wall is (WallNarrow, TooFewAcross).
  bool counts_space() const {
    return walls && walls->flat && walls->nu > 0 && !spec->one_grid && spec->min_cells_across >= 3;
  }
  bool node_space(long i, long j, double depth) const {
    if (i < 0 || j < 0 || i >= walls->nu || j >= walls->nw) return false;
    for (int k = 0; k < WallMap::kDeep; ++k) {
      const std::size_t n = (static_cast<std::size_t>(j) * walls->nu + static_cast<std::size_t>(i)) * WallMap::kDeep + k;
      if (walls->bin[n] < 0) continue;
      const double top = walls->sbin[n] * WallMap::kBin, end = top + walls->bin[n] * WallMap::kBin;
      if (depth >= top - WallMap::kBin && depth <= end + WallMap::kBin) return true;
    }
    return false;
  }
  // Per node of the map, at one depth (kept per depth, to the map's bin, for this pass): the space's local width, mm.
  mutable std::map<long, std::vector<float>> space_width_;
  const std::vector<float>& space_widths(double depth) const {
    const long key = std::lround(depth / WallMap::kBin);
    const auto it = space_width_.find(key);
    if (it != space_width_.end()) return it->second;
    // The map padded by a node of no space all round; the squared distance (in nodes) from each node to the nearest
    // node of no space (exact: down the columns, then the lower envelope of parabolas along the rows).
    const int W = walls->nu + 2, H = walls->nw + 2;
    std::vector<char> in(static_cast<std::size_t>(W) * H, 0);
    for (int j = 0; j < walls->nw; ++j)
      for (int i = 0; i < walls->nu; ++i) in[static_cast<std::size_t>(j + 1) * W + (i + 1)] = node_space(i, j, depth) ? 1 : 0;
    const double far = 1e18;
    std::vector<double> d2(in.size(), far);
    for (int x = 0; x < W; ++x) {
      double d = far;
      for (int y = 0; y < H; ++y) {
        const std::size_t q = static_cast<std::size_t>(y) * W + x;
        d = !in[q] ? 0.0 : (d >= far ? far : d + 1.0);
        d2[q] = d;
      }
      d = far;
      for (int y = H - 1; y >= 0; --y) {
        const std::size_t q = static_cast<std::size_t>(y) * W + x;
        d = !in[q] ? 0.0 : (d >= far ? far : d + 1.0);
        d2[q] = std::min(d2[q], d);
      }
    }
    std::vector<double> f(static_cast<std::size_t>(W)), zz(static_cast<std::size_t>(W) + 1);
    std::vector<int> v(static_cast<std::size_t>(W));
    for (int y = 0; y < H; ++y) {
      double* row = d2.data() + static_cast<std::size_t>(y) * W;
      int k = -1;
      for (int q = 0; q < W; ++q) {
        f[static_cast<std::size_t>(q)] = row[q] >= far ? far : row[q] * row[q];
        if (f[static_cast<std::size_t>(q)] >= far) continue;
        if (k < 0) { k = 0; v[0] = q; zz[0] = -far; zz[1] = far; continue; }
        double sx = 0.0;
        for (;;) {
          const int pp = v[static_cast<std::size_t>(k)];
          sx = ((f[static_cast<std::size_t>(q)] + 1.0 * q * q) - (f[static_cast<std::size_t>(pp)] + 1.0 * pp * pp)) / (2.0 * q - 2.0 * pp);
          if (sx <= zz[static_cast<std::size_t>(k)] && k > 0) { --k; continue; }
          break;
        }
        ++k;
        v[static_cast<std::size_t>(k)] = q;
        zz[static_cast<std::size_t>(k)] = sx;
        zz[static_cast<std::size_t>(k) + 1] = far;
      }
      if (k < 0) continue;
      int jj = 0;
      for (int q = 0; q < W; ++q) {
        while (zz[static_cast<std::size_t>(jj) + 1] < q) ++jj;
        const int pp = v[static_cast<std::size_t>(jj)];
        row[q] = 1.0 * (q - pp) * (q - pp) + f[static_cast<std::size_t>(pp)];
      }
    }
    // Each node of space is the middle of a disc reaching half a node short of the nearest node of no space; every node
    // that disc holds is at least as wide as it (its width: twice its middle's distance, in mm).
    std::vector<float> width(static_cast<std::size_t>(walls->nu) * walls->nw, 0.0f);
    for (int y = 1; y < H - 1; ++y)
      for (int x = 1; x < W - 1; ++x) {
        const std::size_t q = static_cast<std::size_t>(y) * W + x;
        if (!in[q]) continue;
        const double dist = std::sqrt(d2[q]), r = dist - 0.5;
        const float wq = static_cast<float>(2.0 * dist * WallMap::kPitch);
        const int R = static_cast<int>(std::floor(r));
        for (int dy = -R; dy <= R; ++dy)
          for (int dx = -R; dx <= R; ++dx) {
            if (dx * dx + dy * dy > r * r + 1e-9) continue;
            const int xi = x + dx - 1, yj = y + dy - 1;
            if (xi < 0 || yj < 0 || xi >= walls->nu || yj >= walls->nw) continue;
            float& w = width[static_cast<std::size_t>(yj) * walls->nu + xi];
            w = std::max(w, wq);
          }
      }
    // The same with squares square to the face's own axes (the cells' axes): a disc reads a corner of a wall narrow
    // (no large disc reaches into a right-angled corner), a square does not. A node is as wide as the wider of the two.
    std::vector<int> cheb(in.size(), 0);   // chessboard distance, in nodes, to the nearest node of no space
    for (int y = 0; y < H; ++y)
      for (int x = 0; x < W; ++x) {
        const std::size_t q = static_cast<std::size_t>(y) * W + x;
        if (!in[q]) continue;
        int d = 1 << 20;
        if (x > 0) d = std::min(d, cheb[q - 1] + 1);
        if (y > 0) {
          d = std::min(d, cheb[q - static_cast<std::size_t>(W)] + 1);
          if (x > 0) d = std::min(d, cheb[q - static_cast<std::size_t>(W) - 1] + 1);
          if (x + 1 < W) d = std::min(d, cheb[q - static_cast<std::size_t>(W) + 1] + 1);
        }
        cheb[q] = d;
      }
    for (int y = H - 1; y >= 0; --y)
      for (int x = W - 1; x >= 0; --x) {
        const std::size_t q = static_cast<std::size_t>(y) * W + x;
        if (!in[q]) continue;
        int d = cheb[q];
        if (x + 1 < W) d = std::min(d, cheb[q + 1] + 1);
        if (y + 1 < H) {
          d = std::min(d, cheb[q + static_cast<std::size_t>(W)] + 1);
          if (x + 1 < W) d = std::min(d, cheb[q + static_cast<std::size_t>(W) + 1] + 1);
          if (x > 0) d = std::min(d, cheb[q + static_cast<std::size_t>(W) - 1] + 1);
        }
        cheb[q] = d;
      }
    for (int y = 1; y < H - 1; ++y)
      for (int x = 1; x < W - 1; ++x) {
        const std::size_t q = static_cast<std::size_t>(y) * W + x;
        if (!in[q]) continue;
        const int R = cheb[q] - 1;   // the square of nodes all of space round q
        const float wq = static_cast<float>(2.0 * cheb[q] * WallMap::kPitch);
        for (int dy = -R; dy <= R; ++dy)
          for (int dx = -R; dx <= R; ++dx) {
            const int xi = x + dx - 1, yj = y + dy - 1;
            if (xi < 0 || yj < 0 || xi >= walls->nu || yj >= walls->nw) continue;
            float& w = width[static_cast<std::size_t>(yj) * walls->nu + xi];
            w = std::max(w, wq);
          }
      }
    return space_width_.emplace(key, std::move(width)).first->second;
  }
  double space_across(double a, double b, double depth, double limit) const {
    const double P = WallMap::kPitch;
    const long i = std::lround((a - walls->u0) / P), j = std::lround((b - walls->w0) / P);
    if (!node_space(i, j, depth)) return limit;   // the column's middle is off the map: nothing read
    const double across = space_widths(depth)[static_cast<std::size_t>(j) * walls->nu + static_cast<std::size_t>(i)];
    return std::min(limit, across);
  }

  // D14: a strip of this pass's lattice thinner than the spacing of a cube's own sample
  // points slips between them (a ledge under a millimetre wide at the foot of a side
  // wall; the seam between a protected and an unprotected part of a face). The face's
  // map saw it: read again at the map's own nodes inside the cube's footprint.
  bool look_at_nodes(const double lo[3], double s, double* fit, Seen* read = nullptr) const {
    if (!walls->flat || walls->nu == 0) return false;
    const double P = WallMap::kPitch;
    const int i0 = std::max(0, static_cast<int>(std::ceil((lo[0] - walls->u0) / P - 1e-9)));
    const int j0 = std::max(0, static_cast<int>(std::ceil((lo[1] - walls->w0) / P - 1e-9)));
    bool seen = false;
    for (int j = j0; j < walls->nw && walls->w0 + j * P < lo[1] + s; ++j)
      for (int i = i0; i < walls->nu && walls->u0 + i * P < lo[0] + s; ++i)
        for (int k = 0; k < WallMap::kDeep; ++k) {
          const std::size_t n = (static_cast<std::size_t>(j) * walls->nu + i) * WallMap::kDeep + k;
          if (walls->bin[n] < 0 || walls->wall[n] != wall) continue;
          // The part of the cube's depth this stretch runs through (all of it, for a
          // stretch that spans the cube).
          const double top = walls->sbin[n] * WallMap::kBin;
          const double end = top + walls->bin[n] * WallMap::kBin;
          const bool spans = top - WallMap::kBin <= lo[2] && end + WallMap::kBin >= lo[2] + s;
          const double d0 = spans ? lo[2] : std::max(lo[2], top);
          const double d1 = spans ? lo[2] + s : std::min(lo[2] + s, end);
          if (d1 - d0 < 1e-3) continue;
          for (int c = 0; c < 3; ++c) {
            double f = 0.0;
            const double at = spans ? lo[2] + s * (1 + 2 * c) / 6.0 : d0 + (d1 - d0) * (1 + 2 * c) / 6.0;
            if (!sample(walls->u0 + i * P, walls->w0 + j * P, at, &f, read)) continue;
            seen = true;
            *fit = std::min(*fit, f);
          }
        }
    return seen;
  }

  // K2: a cube's lattice read on a finer grid than its own points: 5 x 5 x 5 points a tenth of the cube in from its
  // faces and a fifth apart (a wedge a fifth of the cube deep is seen). How many are its lattice.
  int finer_look(const double lo[3], double s, double* fit, Seen* seen) const {
    int found = 0;
    for (int c = 0; c < 5; ++c)
      for (int b = 0; b < 5; ++b)
        for (int a = 0; a < 5; ++a) {
          double f = 0.0;
          if (!sample(lo[0] + s * (0.1 + 0.2 * a), lo[1] + s * (0.1 + 0.2 * b), lo[2] + s * (0.1 + 0.2 * c), &f, seen)) continue;
          ++found;
          *fit = std::min(*fit, f);
        }
    return found;
  }

  void emit(const double lo[3], double s, bool cut, bool as_cell, const SolidWhy& why = SolidWhy{}) {
    Cell cell;
    cell.region = region;
    cell.frame = frame_index;
    cell.lo[0] = lo[0]; cell.lo[1] = lo[1]; cell.lo[2] = lo[2];
    cell.size = s;
    cell.cut = cut;
    cell.wall = wall;
    cell.own = base_mm;
    if (as_cell) {
      cell.band = band_t(lo, s);
      cell.finest = is_finest(s);
      out->cells.push_back(cell);
      ++tally->cells;
    } else {
      // D8, D14: lattice was asked for, and no allowed cell fits the wall here. Solid.
      out->solid.push_back(cell);
      out->solid_why.push_back(why);   // D14c
      ++tally->solid;
    }
  }

  // A cube of the frame: emit it as a cell, split it, or record it as solid.
  void place(const double lo[3], double s, bool top = true) {
    // 27 points: the centre and a 3 x 3 x 3 grid a third of the cell apart.
    int inside = 0;
    double fits = 1e300;   // the largest cell every counted point's wall allows
    Seen seen;             // what they read (D14c)
    for (int c = 0; c < 3; ++c)
      for (int b = 0; b < 3; ++b)
        for (int a = 0; a < 3; ++a) {
          double fit = 0.0;
          if (!sample(lo[0] + s * (1 + 2 * a) / 6.0, lo[1] + s * (1 + 2 * b) / 6.0,
                      lo[2] + s * (1 + 2 * c) / 6.0, &fit, &seen))
            continue;
          ++inside;
          fits = std::min(fits, fit);
        }
    // D14b: a cube the part's surface cuts so thinly that none of the 27 points is lattice. Look again a hair inside
    // its faces, edges and corners; lattice found there is a sliver of this pass. It is a cut cell when the rest of
    // the cube is AIR (the sliver faces the open surface: the lattice runs out to the surface), and nothing when
    // the cube also holds solid (a sliver under solid must not be opened: it would be a slot nothing can print over).
    if (inside == 0 && spec->absorb_slivers && !walls->flat) {
      int found = 0;
      bool air = false, solid_too = false;
      const double e[3] = {0.04, 0.5, 0.96};
      for (int c = 0; c < 3; ++c)
        for (int b = 0; b < 3; ++b)
          for (int a = 0; a < 3; ++a) {
            if (a == 1 && b == 1 && c == 1) continue;
            const double q[3] = {lo[0] + s * e[a], lo[1] + s * e[b], lo[2] + s * e[c]};
            // Asked cheaply first (no width); the width is read only for a cube that turns out to be a sliver.
            const Where w = probe->where(frame.at(q[0], q[1], q[2]));
            if (w.lattice() && w.id == region) ++found;
            else if (w.why == Why::Outside) air = true;
            else if (w.why != Why::Lattice) solid_too = true;
          }
      if (found > 0 && air && !solid_too) {
        int counted = 0;
        for (int c = 0; c < 3; ++c)
          for (int b = 0; b < 3; ++b)
            for (int a = 0; a < 3; ++a) {
              if (a == 1 && b == 1 && c == 1) continue;
              double fit = 0.0;
              if (!sample(lo[0] + s * e[a], lo[1] + s * e[b], lo[2] + s * e[c], &fit, &seen)) continue;
              ++counted;
              fits = std::min(fits, fit);
            }
        inside = counted;
      }
    }
    // K2 (his 11-23 notes, on his stand's 45 degree sides: "Look at the lack of crisp straight lines at the edges of the
    // lattice. This was with cut cells = on."): with Let walls cut cells on, a cube none of whose points is its lattice
    // is looked at again closely (finer_look) whatever stands beside it, solid included. Before, a cube the side cut
    // so that only a corner wedge of it was lattice, with a rim or a skin beside it, was passed over (the sliver under
    // solid of D14b) and that wedge stood solid: steps of a cube along the slope. Now it is a cut cube, divided down to
    // its finest cells, which the side cuts. (A cut piece thinner than its strut against solid is still made solid,
    // P8 f.)
    if (inside == 0 && spec->one_grid) inside = finer_look(lo, s, &fits, &seen);
    // Nothing of this pass here; or a sliver under solid (D14b), which no cube is recorded for, so it has no reason of
    // its own (D14c): SolidAt::why answers Other there.
    if (inside == 0 && !look_at_nodes(lo, s, &fits, &seen)) return;
    const bool cut = inside < 27;   // D3: a whole cell, cut by the edge
    // A width is read to about a micron (PartMeasure::reach), so a cell that fits its
    // wall exactly must not be refused over the last digits of the reading.
    const bool fitting = s <= fits + kReadingSlack;
    // Too large this close to the outline, or cut by it (G1-G3, G10), or for the stress inside it (C22), or for a
    // size step to a neighbour (C24).
    const bool held = !band_allows(lo, s) || !whole_in_outline(lo, s) || !stress_allows(lo, s) || !cap_allows(lo, s);
    const bool printable = prints(lo, s);
    if (fitting && !held && printable) {
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
    // (Unless it is too small to print: C8, C14.)
    if (fitting && printable) {
      emit(lo, s, cut, true);
      return;
    }
    // D14c: the smallest cell tried here is this one, or, when Stepped found no unit that fits, its finest unit.
    const double tried = spec->algorithm == Algorithm::Stepped && top ? std::min(s, finest_mm) : s;
    emit(lo, s, cut, false, why_solid(tried, seen, printable, fitting));
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
    std::vector<SolidWhy> bare_why;          // why, per bare unit (D14c)
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
      std::vector<Seen> seen(N);                  // D14c: what each unit's points read
      for (int k = 0; k < n; ++k)
        for (int j = 0; j < n; ++j)
          for (int i = 0; i < n; ++i) {
            const std::size_t u = (static_cast<std::size_t>(k) * n + j) * n + i;
            for (int c = 0; c < 2; ++c)
              for (int b = 0; b < 2; ++b)
                for (int a = 0; a < 2; ++a) {
                  double f = 0.0;
                  if (!sample(lo[0] + t * (i + 0.25 + 0.5 * a), lo[1] + t * (j + 0.25 + 0.5 * b),
                              lo[2] + t * (k + 0.25 + 0.5 * c), &f, &seen[u]))
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
                              lo[2] + t * (k + 0.04 + 0.92 * c), &f, &seen[u]))
                    continue;
                  in[u] = 1;
                  fit[u] = f;
                }
            const double at[3] = {lo[0] + t * i, lo[1] + t * j, lo[2] + t * k};
            if (!in[u] && look_at_nodes(at, t, &fit[u], &seen[u])) in[u] = 1;
            if (!in[u] && spec->one_grid && finer_look(at, t, &fit[u], &seen[u]) > 0) in[u] = 1;   // K2
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
              if (band_region) {
                deep = edge_distance(lo[0] + (i + 0.5 * m) * t, lo[1] + (j + 0.5 * m) * t,
                                     lo[2] + (k + 0.5 * m) * t);
                deep = std::round(deep * 1e6) / 1e6;
              } else if (demand) {
                const double at[3] = {lo[0] + i * t, lo[1] + j * t, lo[2] + k * t};
                deep = demand_in(at, size);   // C22: the stress in the spot's cube
              }
              spots.push_back({deep, {i, j, k}});
            }
        // In a band the larger cells take the places farthest from the outline, so the
        // smaller ones are left toward it (G1). With cell size by stress and no band, the
        // quietest places first (C22). Elsewhere, the order they are read in.
        if (band_region)
          std::stable_sort(spots.begin(), spots.end(),
                           [](const auto& x, const auto& y) { return x.first > y.first; });
        else if (demand)
          std::stable_sort(spots.begin(), spots.end(),
                           [](const auto& x, const auto& y) { return x.first < y.first; });
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
          if (!band_allows(at, size) || !whole_in_outline(at, size) || !fine_allowed(at, size) ||
              !stress_allows(at, size) || !cap_allows(at, size))
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
            if (in[u] && !taken[u]) {
              p.bare.push_back({i, j, k});
              // D14c: a unit of an admitted fraction prints; one whose wall holds it was kept empty by the band.
              p.bare_why.push_back(why_solid(t, seen[u], true, t <= fit[u] + kReadingSlack));
            }
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
    for (std::size_t q = 0; q < best.bare.size(); ++q) {
      const auto& u = best.bare[q];
      const double at[3] = {lo[0] + u[0] * t, lo[1] + u[1] * t, lo[2] + u[2] * t};
      emit(at, t, true, false, best.bare_why[q]);
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


// What is read under one flat region's face and kept with the domain: it depends on the
// part, the region and the Protect skins, never on a cell size, so every layout of the
// same domain (a cell-size or band slider being dragged) reuses it.
struct FaceReadings {
  WallMap map;   // nodes and their stretches (bin, sbin); `wall` and `walls` left empty
  struct Stretch {
    std::vector<std::size_t> entries;   // its (node, stretch) places in the map
    double start = 0.0, width = 0.0;    // exact, read at its first node
    double lo[2] = {0, 0}, hi[2] = {0, 0};   // its extent on the face: the nodes' own ...
    bool edged = false;                 // ... or, once set, its true edges, searched for
  };
  // The true edges are searched for the first time a layout needs them (a stretch that
  // could be a wall at that layout's cell size), then kept like the rest.
  mutable std::vector<Stretch> stretches;
  mutable std::mutex edging;
};

// The lattice's columns under a flat region's face at (u, w): where each starts below the
// face and how wide it is. Read just under the face, or just behind a Protect skin on it
// (D5); then, through a pocket, just inside the next material; and so on down to the
// region's depth. Returns how many (at most kDeep).
int face_columns(const Domain::Probe& pr, const Region& r, const Frame& f, double u, double w,
                 double* start, double* width) {
  const double depth = r.prism.depth, under = std::min(0.02, 0.25 * depth);
  const int deep = WallMap::kDeep;
  int n = 0;
  double z = under;
  for (int hop = 0; hop < 4 * deep && n < deep && z < depth; ++hop) {
    double wall = 0.0;
    Domain::Probe::Room room;
    const Vec3 at = f.at(u, w, z);
    const Where h = pr.where(at, &wall, &room);
    if (h.lattice() && h.id == r.id) {
      column_of(room, z, depth, &start[n], &width[n]);
      z = start[n] + width[n] + under;
      ++n;
    } else if (h.why == Why::ProtectSkin || h.why == Why::Cover) {
      // Straight in through the skin, by its own gap: such a step cannot pass its inner side.
      for (int it = 0; it < 200 && z < depth; ++it) {
        const double gap = pr.skin_gap(f.at(u, w, z));
        if (gap > 0.0) break;
        z += std::max(-gap, 1e-3);
      }
      z += under;
    } else if (h.why == Why::Outside) {
      // Air (a pocket, or a step down beside the face): straight on to the next surface.
      const double t = pr.part().reach_by_line(at, f.ax[2]);
      if (t < 0.0) break;
      z += t + under;
    } else {
      break;   // kept clear, another region's, too thin: nothing of this region's below
    }
  }
  return n;
}

// Of the columns at (u, w), the one that is the stretch of these bins.
bool face_column_of(const Domain::Probe& pr, const Region& r, const Frame& f, long want,
                    long want_start, double u, double w, double* start_out, double* width_out) {
  double start[WallMap::kDeep], width[WallMap::kDeep];
  const int n = face_columns(pr, r, f, u, w, start, width);
  for (int k = 0; k < n; ++k)
    if (std::labs(WallMap::bin_of(width[k]) - want) <= 1 &&
        std::labs(WallMap::bin_of(start[k]) - want_start) <= 1) {
      if (start_out) *start_out = start[k];
      if (width_out) *width_out = width[k];
      return true;
    }
  return false;
}

std::shared_ptr<const FaceReadings> read_face(const Domain& domain, const Region& r,
                                              const Frame& f, const double lo[3],
                                              const double hi[3], int thread_count) {
  const ClearanceGeometry& g = r.prism;
  const Domain::Probe probe = domain.probe();
  auto made = std::make_shared<FaceReadings>();
  FaceReadings& out = *made;
  WallMap& map = out.map;
  map.flat = true;
  map.depth = g.depth;
  map.u0 = lo[0]; map.w0 = lo[1];
  map.nu = static_cast<int>(std::ceil((hi[0] - lo[0]) / WallMap::kPitch)) + 1;
  map.nw = static_cast<int>(std::ceil((hi[1] - lo[1]) / WallMap::kPitch)) + 1;
  const int deep = WallMap::kDeep;
  map.bin.assign(static_cast<std::size_t>(map.nu) * map.nw * deep, -1);
  map.sbin.assign(map.bin.size(), 0);
  map.wall.assign(map.bin.size(), -1);
  auto node_u = [&](std::size_t e) { return map.u0 + ((e / deep) % map.nu) * WallMap::kPitch; };
  auto node_w = [&](std::size_t e) { return map.w0 + ((e / deep) / map.nu) * WallMap::kPitch; };
  // Each row of nodes on its own: shared between threads, the result the same for any number.
  {
    std::atomic<int> next{0};
    auto rows = [&](const Domain::Probe& pr) {
      for (int j = next.fetch_add(1); j < map.nw && !domain.stop_asked(); j = next.fetch_add(1))
        for (int i = 0; i < map.nu; ++i) {
          double start[WallMap::kDeep], width[WallMap::kDeep];
          const int n = face_columns(pr, r, f, map.u0 + i * WallMap::kPitch,
                                     map.w0 + j * WallMap::kPitch, start, width);
          for (int k = 0; k < n; ++k) {
            const std::size_t e = (static_cast<std::size_t>(j) * map.nu + i) * deep + k;
            map.bin[e] = WallMap::bin_of(width[k]);
            map.sbin[e] = WallMap::bin_of(start[k]);
          }
        }
    };
    std::vector<std::thread> pool;
    for (int t = 1; t < std::min(thread_count, map.nw); ++t)
      pool.emplace_back([&]() { rows(domain.probe()); });
    rows(probe);
    for (std::thread& t : pool) t.join();
  }
  domain.check_stop();   // rows left unread: nothing of this reading is kept
  std::vector<int> mark(map.bin.size(), 0);
  std::vector<std::size_t> stack;
  for (std::size_t n0 = 0; n0 < map.bin.size(); ++n0) {
    if (map.bin[n0] < 0 || mark[n0]) continue;
    // One stretch: neighbours that start at the same depth and are the same width.
    FaceReadings::Stretch st;
    stack.assign(1, n0);
    mark[n0] = 1;
    while (!stack.empty()) {
      const std::size_t n = stack.back();
      stack.pop_back();
      st.entries.push_back(n);
      const int i = static_cast<int>((n / deep) % map.nu), j = static_cast<int>((n / deep) / map.nu);
      const int nb[4][2] = {{i - 1, j}, {i + 1, j}, {i, j - 1}, {i, j + 1}};
      for (const auto& q : nb) {
        if (q[0] < 0 || q[1] < 0 || q[0] >= map.nu || q[1] >= map.nw) continue;
        for (int k = 0; k < deep; ++k) {
          const std::size_t m = (static_cast<std::size_t>(q[1]) * map.nu + q[0]) * deep + k;
          if (mark[m] || map.bin[m] != map.bin[n0] || map.sbin[m] != map.sbin[n0]) continue;
          mark[m] = 1;
          stack.push_back(m);
        }
      }
    }
    // The exact width, not the bin's: read it again at the stretch's first node ...
    {
      double start = 0.0, width = 0.0;
      face_column_of(probe, r, f, map.bin[n0], map.sbin[n0], node_u(n0), node_w(n0), &start, &width);
      // ... to the precision it is read at: a 12 mm wall is 12, not 11.9999995.
      st.start = std::round(start * 1e5) / 1e5;
      st.width = std::round((start + width) * 1e5) / 1e5 - st.start;
    }
    st.lo[0] = st.lo[1] = 1e300;
    st.hi[0] = st.hi[1] = -1e300;
    for (std::size_t n : st.entries) {
      const double u = node_u(n), w = node_w(n);
      st.lo[0] = std::min(st.lo[0], u); st.hi[0] = std::max(st.hi[0], u);
      st.lo[1] = std::min(st.lo[1], w); st.hi[1] = std::max(st.hi[1], w);
    }
    out.stretches.push_back(std::move(st));
  }
  return made;
}

// The map's nodes stop short of a stretch's true edge by up to one step. Find the edge
// itself, outward from the outermost nodes, so the cells are centred on the real stretch
// (and a symmetric one gets a symmetric layout, exactly). Once per stretch, then kept.
void find_edges(const FaceReadings& kept, std::size_t which, const Domain& domain,
                const Domain::Probe& probe, std::vector<std::unique_ptr<Domain::Probe>>& spare,
                const Region& r, const Frame& f) {
  std::lock_guard<std::mutex> lock(kept.edging);
  FaceReadings::Stretch& st = kept.stretches[which];
  if (st.edged) return;
  const WallMap& map = kept.map;
  const int deep = WallMap::kDeep;
  const long want = map.bin[st.entries.front()], want_start = map.sbin[st.entries.front()];
  // Each outermost node, each way it is outermost: one search, on its own. Shared between
  // threads; the edge is the farthest any of them found, the same for any number.
  struct Search { double at[2]; int axis, side; double found = 0.0; };
  std::vector<Search> searches;
  for (std::size_t n : st.entries) {
    const double at[2] = {map.u0 + ((n / deep) % map.nu) * WallMap::kPitch,
                          map.w0 + ((n / deep) / map.nu) * WallMap::kPitch};
    for (int axis = 0; axis < 2; ++axis)
      for (int side = 0; side < 2; ++side) {
        const double extreme = side ? st.hi[axis] : st.lo[axis];
        if (std::fabs(at[axis] - extreme) > 1e-9) continue;
        searches.push_back({{at[0], at[1]}, axis, side});
      }
  }
  std::atomic<std::size_t> next{0};
  auto work = [&](int who) {
    if (who > 0 && !spare[static_cast<std::size_t>(who)])
      spare[static_cast<std::size_t>(who)] = std::make_unique<Domain::Probe>(domain.probe());
    const Domain::Probe& mine = who > 0 ? *spare[static_cast<std::size_t>(who)] : probe;
    for (std::size_t i = next.fetch_add(1); i < searches.size() && !domain.stop_asked(); i = next.fetch_add(1)) {
      Search& q = searches[i];
      double in = q.at[q.axis], outside = q.at[q.axis] + (q.side ? WallMap::kPitch : -WallMap::kPitch);
      for (int it = 0; it < 50; ++it) {
        const double m = 0.5 * (in + outside);
        const bool yes = q.axis == 0 ? face_column_of(mine, r, f, want, want_start, m, q.at[1], nullptr, nullptr)
                                     : face_column_of(mine, r, f, want, want_start, q.at[0], m, nullptr, nullptr);
        if (yes) in = m; else outside = m;
      }
      q.found = std::round(0.5 * (in + outside) * 1e7) / 1e7;
    }
  };
  {
    const int nt = static_cast<int>(std::min<std::size_t>(spare.size(), std::max<std::size_t>(1, searches.size() / 4)));
    std::vector<std::thread> pool;
    for (int t = 1; t < nt; ++t) pool.emplace_back(work, t);
    work(0);
    for (std::thread& t : pool) t.join();
  }
  domain.check_stop();   // searches left unrun: the kept stretch is not written (it stays un-edged)
  double edge[2][2] = {{st.lo[0], st.hi[0]}, {st.lo[1], st.hi[1]}};
  for (const Search& q : searches)
    edge[q.axis][q.side] = q.side ? std::max(edge[q.axis][q.side], q.found) : std::min(edge[q.axis][q.side], q.found);
  st.lo[0] = edge[0][0]; st.hi[0] = edge[0][1];
  st.lo[1] = edge[1][0]; st.hi[1] = edge[1][1];
  st.edged = true;
}

}  // namespace

bool stress_sizes_cells(const CellSpec& spec) {
  return spec.by_stress && spec.demand && !spec.demand->empty() && spec.reference_mpa > 0.0 &&
         !(spec.cell_mm > 0.0) && spec.algorithm != Algorithm::Uniform;
}

CellSpec region_cells(const CellSpec& part, const AreaOwn& own) {
  CellSpec c = part;
  if (own.algorithm) c.algorithm = *own.algorithm;
  if (own.cell_mm) c.cell_mm = *own.cell_mm;
  if (own.cell_max_mm) c.cell_max_mm = *own.cell_max_mm;
  if (own.cell_min_mm) c.cell_min_mm = *own.cell_min_mm;
  if (own.min_cells_across) c.min_cells_across = *own.min_cells_across;
  if (own.grade_to_shape) c.grade_to_shape = *own.grade_to_shape;
  if (own.band_mm) c.band_mm = *own.band_mm;
  if (own.band_cell_mm) c.band_cell_mm = *own.band_cell_mm;
  if (own.cells_by_stress) c.by_stress = *own.cells_by_stress;
  if (own.response) c.response = *own.response;
  if (own.reference_mpa && *own.reference_mpa > 0.0) c.reference_mpa = *own.reference_mpa;
  if (own.max_step) c.max_step = *own.max_step;
  return c;
}

// K5 (his yes, 2026-11-23): "no lattice patch of fewer cells than the rule's minimum across, in any direction" (the
// Structural count, three or more across; core does not know the stage). A patch is the cells of one region and frame
// joined face to face (sharing part of a face); along each of its frame's three axes it must reach `k` times its
// largest cell (its extent, a cut cell counted as its whole cube). One that does not is solid, every cell of it, as a
// thin wall is (TooFewAcross: the patch's extent that way against `k` of its cells).
namespace {
template <class K>
void drop_small_patches(Layout& out, const K& k_of) {
  const std::size_t n = out.cells.size();
  if (n == 0) return;
  bool any = false;
  for (const Cell& c : out.cells) any = any || k_of(c.region) >= 3;
  if (!any) return;
  std::vector<std::size_t> up(n);
  for (std::size_t i = 0; i < n; ++i) up[i] = i;
  const auto find = [&](std::size_t i) {
    while (up[i] != i) { up[i] = up[up[i]]; i = up[i]; }
    return i;
  };
  // Cells filed by their low corner on a grid of the largest cell: two that share a face lie in neighbouring buckets.
  double big = 0.0;
  for (const Cell& c : out.cells) big = std::max(big, c.size);
  std::map<std::array<long long, 4>, std::vector<std::size_t>> grid;
  const auto key = [&](const Cell& c, int dx, int dy, int dz) {
    return std::array<long long, 4>{c.frame, static_cast<long long>(std::floor(c.lo[0] / big)) + dx,
                                    static_cast<long long>(std::floor(c.lo[1] / big)) + dy,
                                    static_cast<long long>(std::floor(c.lo[2] / big)) + dz};
  };
  for (std::size_t i = 0; i < n; ++i)
    if (k_of(out.cells[i].region) >= 3) grid[key(out.cells[i], 0, 0, 0)].push_back(i);
  const double tol = 1e-6 * std::max(1.0, big);
  for (std::size_t i = 0; i < n; ++i) {
    const Cell& a = out.cells[i];
    if (k_of(a.region) < 3) continue;
    for (int dz = -1; dz <= 1; ++dz)
      for (int dy = -1; dy <= 1; ++dy)
        for (int dx = -1; dx <= 1; ++dx) {
          const auto it = grid.find(key(a, dx, dy, dz));
          if (it == grid.end()) continue;
          for (std::size_t j : it->second) {
            if (j <= i) continue;
            const Cell& b = out.cells[j];
            if (b.region != a.region) continue;
            int touch = 0, overlap = 0;
            for (int ax = 0; ax < 3; ++ax) {
              const double lo = std::max(a.lo[ax], b.lo[ax]), hi = std::min(a.lo[ax] + a.size, b.lo[ax] + b.size);
              if (hi - lo > tol) ++overlap;
              else if (std::fabs(hi - lo) <= tol) ++touch;
            }
            if (overlap == 2 && touch == 1) up[find(j)] = find(i);
          }
        }
  }
  struct Extent { double lo[3] = {1e300, 1e300, 1e300}, hi[3] = {-1e300, -1e300, -1e300}, big = 0.0; };
  std::map<std::size_t, Extent> patch;
  for (std::size_t i = 0; i < n; ++i) {
    const Cell& c = out.cells[i];
    if (k_of(c.region) < 3) continue;
    Extent& e = patch[find(i)];
    for (int ax = 0; ax < 3; ++ax) {
      e.lo[ax] = std::min(e.lo[ax], c.lo[ax]);
      e.hi[ax] = std::max(e.hi[ax], c.lo[ax] + c.size);
    }
    e.big = std::max(e.big, c.size);
  }
  std::vector<Cell> kept;
  kept.reserve(n);
  for (std::size_t i = 0; i < n; ++i) {
    const Cell& c = out.cells[i];
    const int k = k_of(c.region);
    if (k < 3) { kept.push_back(c); continue; }
    const Extent& e = patch[find(i)];
    double least = 1e300;
    for (int ax = 0; ax < 3; ++ax) least = std::min(least, e.hi[ax] - e.lo[ax]);
    if (least >= k * e.big - 1e-6 * k * e.big) { kept.push_back(c); continue; }
    out.solid.push_back(c);
    SolidWhy why;
    why.why = NoCell::TooFewAcross;
    why.have_mm = static_cast<float>(std::floor(least * 1e3 + 1e-6) * 1e-3);
    why.need_mm = static_cast<float>(std::ceil(k * e.big * 1e3 - 1e-6) * 1e-3);
    out.solid_why.push_back(why);
    ++out.small_patch_cells;
    for (RegionCells& r : out.regions)
      if (r.frame == c.frame && r.region == c.region) {
        if (r.cells > 0) --r.cells;
        ++r.solid;
        break;
      }
  }
  out.cells.swap(kept);
}
}  // namespace

// K7, K8 (CellSpec::cell_search, stretch_edges): where a region's lattice ends on a face SQUARE to one of its frame's
// axes. Read along lines parallel to each axis over the region's box (its frame's coordinates), about a 64th of the
// box apart (never under 1 mm): every end of a run of the region's own lattice, found to 1e-8 mm (a stretched row
// ends on it). An end is square where the lines beside it, one each way on both other axes, end within kSquareMM of
// it: the face there is flat and square to the axis (a slope a few degrees off square is not). It depends on the
// part, the region and the skins only, never on a cell size: read once and kept with the domain.
namespace {
struct SquareEnds {
  struct End {
    int axis = 0;
    int side = 0;           // +1: the lattice lies below `at` along the axis; -1: above it
    double at = 0.0;        // along the axis, mm
    double p[2] = {0, 0};   // the line, on the other two axes (in axis order)
    double area = 0.0;      // the face it stands for, mm^2
  };
  std::vector<End> ends;
  double ms = 0.0;          // how long the reading took
};
constexpr double kSquareMM = 0.05;
constexpr double kStretchInset = 0.02;   // K8: mm a stretched row stops short of the face it stands on
constexpr int kKeptSquareEnds = -1000000;   // Domain::kept key: this less the region (FaceReadings use the id)

void other_axes(int a, int* o0, int* o1) {
  *o0 = a == 0 ? 1 : 0;
  *o1 = a == 2 ? 1 : 2;
}

std::shared_ptr<const SquareEnds> read_square_ends(const Domain& domain, int region, const Frame& f, const double lo[3],
                                                   const double hi[3], int threads) {
  const auto t0 = std::chrono::steady_clock::now();
  auto out = std::make_shared<SquareEnds>();
  double ext = 0.0;
  for (int a = 0; a < 3; ++a) ext = std::max(ext, hi[a] - lo[a]);
  const double pitch = std::max(1.0, ext / 64.0);
  const double step = std::min(0.5, 0.5 * pitch);
  struct Line { int axis, i, j; double p[2]; };
  std::vector<Line> lines;
  int count[3][2];
  double area[3];
  for (int a = 0; a < 3; ++a) {
    int o0, o1;
    other_axes(a, &o0, &o1);
    const double s0 = hi[o0] - lo[o0], s1 = hi[o1] - lo[o1];
    count[a][0] = std::max(1, static_cast<int>(std::ceil(s0 / pitch - 1e-9)));
    count[a][1] = std::max(1, static_cast<int>(std::ceil(s1 / pitch - 1e-9)));
    area[a] = (s0 / count[a][0]) * (s1 / count[a][1]);
    for (int j = 0; j < count[a][1]; ++j)
      for (int i = 0; i < count[a][0]; ++i)
        lines.push_back({a, i, j, {lo[o0] + (i + 0.5) * s0 / count[a][0], lo[o1] + (j + 0.5) * s1 / count[a][1]}});
  }
  struct Found { double at; int side; };
  std::vector<std::vector<Found>> found(lines.size());
  const int thread_count =
      threads > 0 ? threads : std::max(1, static_cast<int>(std::thread::hardware_concurrency()));
  std::atomic<std::size_t> next{0};
  auto work = [&]() {
    const Domain::Probe probe = domain.probe();
    for (std::size_t li = next.fetch_add(1); li < lines.size() && !domain.stop_asked(); li = next.fetch_add(1)) {
      const Line& L = lines[li];
      int o0, o1;
      other_axes(L.axis, &o0, &o1);
      auto own = [&](double t) {
        double q[3];
        q[L.axis] = t;
        q[o0] = L.p[0];
        q[o1] = L.p[1];
        const Where w = probe.where(f.at(q[0], q[1], q[2]));
        return w.lattice() && w.id == region;
      };
      const double from = lo[L.axis] - 0.25, to = hi[L.axis] + 0.25;
      const int n = std::max(2, static_cast<int>(std::ceil((to - from) / step)));
      double tp = from;
      bool was = own(tp);
      for (int k = 1; k <= n; ++k) {
        const double t = from + (to - from) * k / n;
        const bool is = own(t);
        if (is != was) {
          double a = tp, b = t;   // own(a) == was, own(b) == is: to a few hundred-millionths of a millimetre, so a row
                                  // stretched on to the face (K8) ends on it
          for (int r = 0; r < 26; ++r) {
            const double m = 0.5 * (a + b);
            if (own(m) == was) a = m; else b = m;
          }
          found[li].push_back({0.5 * (a + b), was ? +1 : -1});
        }
        tp = t;
        was = is;
      }
    }
  };
  {
    const int nt = static_cast<int>(std::min<std::size_t>(static_cast<std::size_t>(thread_count), lines.size()));
    std::vector<std::thread> pool;
    for (int t = 1; t < nt; ++t) pool.emplace_back(work);
    work();
    for (std::thread& t : pool) t.join();
  }
  domain.check_stop();
  // Line (a, i, j) -> its index, to read the lines beside it.
  std::size_t first[3] = {0, 0, 0};
  for (int a = 1; a < 3; ++a) first[a] = first[a - 1] + static_cast<std::size_t>(count[a - 1][0]) * count[a - 1][1];
  auto line_at = [&](int a, int i, int j) -> const std::vector<Found>* {
    if (i < 0 || j < 0 || i >= count[a][0] || j >= count[a][1]) return nullptr;
    return &found[first[a] + static_cast<std::size_t>(j) * count[a][0] + static_cast<std::size_t>(i)];
  };
  for (std::size_t li = 0; li < lines.size(); ++li) {
    const Line& L = lines[li];
    for (const Found& e : found[li]) {
      auto agrees = [&](int di, int dj) {
        const std::vector<Found>* o = line_at(L.axis, L.i + di, L.j + dj);
        if (!o) return false;
        for (const Found& x : *o)
          if (x.side == e.side && std::fabs(x.at - e.at) <= kSquareMM) return true;
        return false;
      };
      // A box one line across a way has no neighbour that way: read as agreeing.
      const bool way0 = count[L.axis][0] == 1 || agrees(-1, 0) || agrees(1, 0);
      const bool way1 = count[L.axis][1] == 1 || agrees(0, -1) || agrees(0, 1);
      if (!way0 || !way1) continue;
      SquareEnds::End end;
      end.axis = L.axis;
      end.side = e.side;
      end.at = e.at;
      end.p[0] = L.p[0];
      end.p[1] = L.p[1];
      end.area = area[L.axis];
      out->ends.push_back(end);
    }
  }
  out->ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
  return out;
}

// K7: the slivers a grid leaves on the square faces read: its base cells start at `start` (frame coordinates) and its
// finest cell, the only one a face cuts (C20), is `finest`. A face on a grid plane (to 0.02 mm) cuts nothing.
Layout::CellSearch::Tried score_grid(const SquareEnds& se, const double start[3], double base, double finest,
                                     const Frame& f, double bed_z) {
  Layout::CellSearch::Tried t;
  t.base_mm = base;
  t.finest_mm = finest;
  for (const SquareEnds::End& e : se.ends) {
    const double u = (e.at - start[e.axis]) / finest;
    const double frac = u - std::floor(u);
    double share = e.side > 0 ? frac : 1.0 - frac;   // the cut cell's piece inside the lattice, of the cell
    if (share * finest < 0.02 || share * finest > finest - 0.02) share = 1.0;
    if (!(share < kSliverFraction)) continue;
    ++t.slivers;
    t.sliver_mm2 += e.area;
    t.thinnest = std::min(t.thinnest, share);
    double q[3];
    int o0, o1;
    other_axes(e.axis, &o0, &o1);
    q[e.axis] = e.at;
    q[o0] = e.p[0];
    q[o1] = e.p[1];
    // On the bed: the face is the part's lowest plane and the lattice stands on it (lies up the axis from it).
    if (f.at(q[0], q[1], q[2]).z <= bed_z + 0.2 && -e.side * f.ax[e.axis].z > 0.99) {
      ++t.at_bed;
      t.bed_mm2 += e.area;
    }
  }
  return t;
}
// Is `x` a clear gain over `best` (K7)? Less sliver area on the bed; or as much there and at most kSearchGain of its
// sliver area in all; or the same area, both with slivers, and a thicker thinnest. Else the earlier stands.
bool better(const Layout::CellSearch::Tried& x, const Layout::CellSearch::Tried& best) {
  if (x.bed_mm2 < best.bed_mm2 - 1e-9) return true;
  if (x.bed_mm2 > best.bed_mm2 + 1e-9) return false;
  if (x.sliver_mm2 <= kSearchGain * best.sliver_mm2 - 1e-9) return true;
  if (std::fabs(x.sliver_mm2 - best.sliver_mm2) > 1e-9) return false;
  return x.slivers > 0 && best.slivers > 0 && x.thinnest > best.thinnest + 1e-9;
}
std::string mm_words(double v) {
  char b[32];
  std::snprintf(b, sizeof b, "%.3g mm", v);
  return b;
}
}  // namespace

double step_held(const CellSpec& spec) {
  if (!(spec.max_step > 0.0)) return 0.0;
  // A ratio of the larger cell to the smaller is never under 1; Default Grade's sizes are halves, so its smallest step
  // is 2 and a limit under it could only be met by the finest cell everywhere.
  return std::max(spec.max_step, spec.algorithm == Algorithm::DefaultGrade ? 2.0 : 1.0);
}

namespace {
// Auto's largest cell held under the type's own (auto_cell_cap_mm: a level strut's bridge must not reach past the print
// rule's limit). A typed cell, and a type with no cap (the octet among them), are left as they are.
CellSpec held_for_type(CellSpec cs) {
  if (!(cs.cell_mm > 0.0)) cs.cell_max_mm = std::min(cs.cell_max_mm, auto_cell_cap_mm(cs.topology));
  return cs;
}
}  // namespace

Layout lay_cells(const Domain& domain, const CellSpec& asked, int threads, const AreaOwnMap* own) {
  const CellSpec spec = held_for_type(asked);
  Layout out;
  const int thread_count =
      threads > 0 ? threads : std::max(1, static_cast<int>(std::thread::hardware_concurrency()));
  const DomainSpec& ds = domain.spec();
  // R5, C14: the thinnest strut is a number of line widths (two), and the smallest cell is
  // the one that strut leaves open. Core's own open-look rule is asked with that strut.
  const double min_strut = std::max(1.0, ds.min_strut_lines) * ds.bead_mm;
  // Each type's own open look and quilt (throws, naming the type, for one with no cell).
  const LatticeWidthBounds bounds = lattice_width_bounds(spec.topology);
  out.open_look = bounds.open_look;
  out.touch = bounds.touch;
  // C14, R2: the smallest cell is the one the thinnest strut leaves open; with Allow quilt
  // on, the one it draws without closing (the quilt's cell), on any wall that needs it.
  out.floor_cell_mm = min_strut / (spec.allow_quilt ? bounds.touch : bounds.open_look);
  // ★ notes29b: Small cells in thin walls (Allow quilt off only): a thin wall's own cell may go down to the cell in which the
  // thinnest strut stays a printed line short of touching (lattice_quilt_off_cell_mm), never under it.
  out.thin_floor_cell_mm = spec.small_in_thin_walls && !spec.allow_quilt
      ? std::min(out.floor_cell_mm, lattice_quilt_off_cell_mm(spec.topology, min_strut, ds.bead_mm))
      : out.floor_cell_mm;
  out.bead_mm = ds.bead_mm;
  out.min_strut_mm = min_strut;
  out.topology = spec.topology;
  // C23: each Lattice region's own cells (the part's, with its stated values over them). A region not listed, and the
  // whole part, are laid with `spec` itself.
  std::map<int, CellSpec> resolved;
  if (own)
    for (const auto& [id, o] : *own)
      if (id > 0 && o.any()) resolved.emplace(id, held_for_type(region_cells(spec, o)));
  const auto spec_of = [&](int region) -> const CellSpec& {
    const auto it = resolved.find(region);
    return it == resolved.end() ? spec : it->second;
  };
  // A hair above the bound itself, so the floor cell is a size core's own menu admits.
  const auto smallest_of = [&](const CellSpec& cs) { return std::max(out.floor_cell_mm * (1.0 + 1e-9), cs.cell_min_mm); };
  const auto target_of = [](const CellSpec& cs) { return cs.cell_mm > 0.0 ? cs.cell_mm : cs.cell_max_mm; };
  const Domain::Probe probe = domain.probe();
  // A probe serves one thread; each worker makes its own once and keeps it for every lay.
  std::vector<std::unique_ptr<Domain::Probe>> spare(static_cast<std::size_t>(thread_count));
  const PartMeasure& part = domain.measure();
  // (One grid: the cells a wall must hold are not counted anywhere, so not in a region's base cell either.)
  const auto k_min_of = [](const CellSpec& cs) { return cs.one_grid ? 1 : std::max(1, cs.min_cells_across); };

  // C24: one lay kept base cell by base cell, so that a base cell can be laid again with size caps on it. Only made
  // when the region asks for a size step; otherwise every lay goes straight into the layout, as it always has.
  struct Laid {
    Pass pass;
    double base = 0.0, start[3] = {0, 0, 0};
    int count[3] = {0, 0, 0};
    struct Piece { std::vector<Cell> cells, solid; std::vector<SolidWhy> why; };
    std::vector<Piece> pieces;            // per base cell, in the order one thread lays them
    std::vector<std::vector<Cap>> caps;   // per base cell
    void slot(std::size_t i, double q[3]) const {
      const std::size_t a = i % count[0], b = (i / count[0]) % count[1],
                        c = i / (static_cast<std::size_t>(count[0]) * count[1]);
      q[0] = start[0] + a * base; q[1] = start[1] + b * base; q[2] = start[2] + c * base;
    }
  };
  // Lay the base cells `jobs` ({lay, base cell}, sorted) of `lays` again, each with its own caps; shared between
  // threads, each base cell on its own, so the result is the same for any number of threads (D18).
  auto lay_slots = [&](std::vector<Laid>& lays, const std::vector<std::array<std::size_t, 2>>& jobs) {
    const int nt = static_cast<int>(std::min<std::size_t>(static_cast<std::size_t>(thread_count), jobs.size()));
    std::atomic<std::size_t> next{0};
    auto work = [&](int who) {
      if (who > 0 && !spare[static_cast<std::size_t>(who)])
        spare[static_cast<std::size_t>(who)] = std::make_unique<Domain::Probe>(domain.probe());
      const Domain::Probe& mine = who > 0 ? *spare[static_cast<std::size_t>(who)] : probe;
      Layout local;
      local.floor_cell_mm = out.floor_cell_mm;
      RegionCells count_here;
      std::size_t at = static_cast<std::size_t>(-1);
      Pass p;
      for (std::size_t i = next.fetch_add(1); i < jobs.size() && !domain.stop_asked(); i = next.fetch_add(1)) {
        Laid& L = lays[jobs[i][0]];
        const std::size_t k = jobs[i][1];
        if (jobs[i][0] != at) {
          at = jobs[i][0];
          p = L.pass;
          p.probe = &mine;
          p.out = &local;
          p.tally = &count_here;
        }
        p.caps = L.caps[k].empty() ? nullptr : &L.caps[k];
        double q[3];
        L.slot(k, q);
        p.columns.clear();
        p.place(q, L.base);
        L.pieces[k].cells.swap(local.cells);
        L.pieces[k].solid.swap(local.solid);
        L.pieces[k].why.swap(local.solid_why);
        local.cells.clear();
        local.solid.clear();
        local.solid_why.clear();
      }
    };
    std::vector<std::thread> pool;
    for (int t = 1; t < nt; ++t) pool.emplace_back(work, t);
    work(0);
    for (std::thread& t : pool) t.join();
    domain.check_stop();   // base cells left unlaid
  };
  // C24: no cell of these lays (one region, one frame) more than `limit` times the size of a cell it shares any part
  // of a face with. Each round finds every pair that breaks it and caps the LARGER cell's place at `limit` times the
  // smaller (unless the larger is the finest of its ladder: it stands), and every other cell of that base cell at its
  // own size (so nothing there comes out larger), then lays the base cells holding a new or lowered cap again; a
  // capped cell is divided down its own ladder. Then the lays go into the layout, in order.
  // Why it ends: a cap is only ever added, or lowered on its own box, never raised or removed, and a round that adds or
  // lowers none is the last. The boxes are cubes of cells laid in that base cell (places on its ladder's own grid)
  // and the caps are `limit` times a cell size: both finite sets, so only finitely many rounds can add one.
  auto keep_steps = [&](std::vector<Laid>& lays, double limit) {
    const double tol = 1e-6;
    struct Ref { std::size_t lay, slot, idx; };
    for (;;) {
      std::vector<Ref> refs;
      double big_mm = 0.0;
      for (std::size_t li = 0; li < lays.size(); ++li)
        for (std::size_t k = 0; k < lays[li].pieces.size(); ++k)
          for (std::size_t j = 0; j < lays[li].pieces[k].cells.size(); ++j) {
            refs.push_back({li, k, j});
            big_mm = std::max(big_mm, lays[li].pieces[k].cells[j].size);
          }
      if (refs.size() < 2) break;
      const auto cell_of = [&](const Ref& r) -> const Cell& { return lays[r.lay].pieces[r.slot].cells[r.idx]; };
      // The cells sorted by their low corner into a grid of the largest cell's pitch: the low corners of two cells that
      // share a face are at most that far apart, so they lie in the same bucket or in neighbouring ones.
      struct Key {
        long long v[3];
        bool operator==(const Key& o) const { return v[0] == o.v[0] && v[1] == o.v[1] && v[2] == o.v[2]; }
      };
      struct KeyHash {
        std::size_t operator()(const Key& k) const {
          return std::hash<long long>()(k.v[0] * 73856093LL ^ k.v[1] * 19349663LL ^ k.v[2] * 83492791LL);
        }
      };
      const double pitch = big_mm * (1.0 + 1e-6) + 1e-5;
      std::unordered_map<Key, std::vector<std::uint32_t>, KeyHash> grid;
      std::vector<Key> key(refs.size());
      for (std::size_t r = 0; r < refs.size(); ++r) {
        const Cell& c = cell_of(refs[r]);
        for (int a = 0; a < 3; ++a) key[r].v[a] = static_cast<long long>(std::floor(c.lo[a] / pitch));
        grid[key[r]].push_back(static_cast<std::uint32_t>(r));
      }
      // The cap each breaking larger cell gets: `limit` times its smallest neighbour that breaks the rule.
      std::map<std::array<std::size_t, 3>, double> want;
      for (std::size_t i = 0; i < refs.size(); ++i) {
        const Cell& A = cell_of(refs[i]);
        for (int dz = -1; dz <= 1; ++dz)
          for (int dy = -1; dy <= 1; ++dy)
            for (int dx = -1; dx <= 1; ++dx) {
              const auto it = grid.find(Key{{key[i].v[0] + dx, key[i].v[1] + dy, key[i].v[2] + dz}});
              if (it == grid.end()) continue;
              for (std::uint32_t j : it->second) {
                if (j <= i) continue;   // each pair once
                const Cell& B = cell_of(refs[j]);
                const bool a_big = A.size >= B.size;
                const Cell& big = a_big ? A : B;
                const Cell& small = a_big ? B : A;
                if (big.finest || big.size <= limit * small.size * (1.0 + 1e-9)) continue;
                int touch = 0, over = 0;
                for (int a = 0; a < 3; ++a) {
                  if (std::fabs(A.lo[a] + A.size - B.lo[a]) <= tol || std::fabs(B.lo[a] + B.size - A.lo[a]) <= tol)
                    ++touch;
                  else if (std::min(A.lo[a] + A.size, B.lo[a] + B.size) - std::max(A.lo[a], B.lo[a]) > tol)
                    ++over;
                }
                if (touch != 1 || over != 2) continue;   // not a shared face
                const Ref& r = refs[a_big ? i : j];
                const double v = limit * small.size;
                const auto w = want.find({r.lay, r.slot, r.idx});
                if (w == want.end()) want.emplace(std::array<std::size_t, 3>{r.lay, r.slot, r.idx}, v);
                else w->second = std::min(w->second, v);
              }
            }
      }
      // New caps, or lower ones on a box already capped; the base cells that hold one are laid again.
      const auto cap = [&](std::vector<Cap>& caps, const Cell& c, double v) {   // true: new or lowered
        for (Cap& k : caps)
          if (std::fabs(k.lo[0] - c.lo[0]) <= tol && std::fabs(k.lo[1] - c.lo[1]) <= tol &&
              std::fabs(k.lo[2] - c.lo[2]) <= tol && std::fabs(k.hi[0] - (c.lo[0] + c.size)) <= tol) {
            if (!(v < k.size * (1.0 - 1e-9))) return false;
            k.size = v;
            return true;
          }
        caps.push_back({{c.lo[0], c.lo[1], c.lo[2]}, {c.lo[0] + c.size, c.lo[1] + c.size, c.lo[2] + c.size}, v});
        return true;
      };
      std::vector<std::array<std::size_t, 2>> jobs;
      for (const auto& w : want) {
        Laid& L = lays[w.first[0]];
        if (cap(L.caps[w.first[1]], L.pieces[w.first[1]].cells[w.first[2]], w.second) &&
            (jobs.empty() || jobs.back()[0] != w.first[0] || jobs.back()[1] != w.first[1]))
          jobs.push_back({w.first[0], w.first[1]});
      }
      // Laid again, no cell of the base cell may come out larger than the cell that held its place before (a Stepped
      // base cell is packed again and could take another family): every other cell of it is capped at its own size.
      for (const auto& j : jobs) {
        Laid& L = lays[j[0]];
        for (const Cell& c : L.pieces[j[1]].cells)
          cap(L.caps[j[1]], c, c.size);
      }
      if (jobs.empty()) break;
      lay_slots(lays, jobs);
    }
    for (Laid& L : lays)
      for (const Laid::Piece& piece : L.pieces) {
        out.cells.insert(out.cells.end(), piece.cells.begin(), piece.cells.end());
        out.solid.insert(out.solid.end(), piece.solid.begin(), piece.solid.end());
        out.solid_why.insert(out.solid_why.end(), piece.why.begin(), piece.why.end());
        L.pass.tally->cells += piece.cells.size();
        L.pass.tally->solid += piece.solid.size();
      }
  };

  // Lay one pass over the box [lo, hi] of its frame, in slots of `base`. With `keep` (C24) the base cells are kept
  // in it, one by one, and not put in the layout.
  auto lay = [&](Pass& pass, double base, const double lo[3], const double hi[3],
                 bool depth_from_zero, std::vector<Laid>* keep = nullptr) {
    const CellSpec& spec = *pass.spec;   // the pass's own (C23)
    // G11: a band is a size gradient down to the smallest cell allowed (the floor above).
    // A typed smallest cell for the band (Manual) is held at that floor.
    const double band_floor = pass.band_region != nullptr && spec.band_cell_mm > 0.0
        ? std::max(spec.band_cell_mm, out.floor_cell_mm) : out.floor_cell_mm;
    // Core's own menus check the open look; with Allow quilt the floor here stands in for it.
    const bool fine = spec.allow_quilt;
    const double tile_min = std::max(spec.cell_min_mm, band_floor);
    if (spec.algorithm == Algorithm::DefaultGrade)
      // The halving ladder and its printable floor are core's own (ruling A, C7, C14).
      pass.sizes = stepped_size_menu(spec.topology, base, min_strut, tile_min, !fine,
                                     SteppedMenu::Halves);
    else
      pass.sizes = {base};
    pass.divisors.clear();
    if (spec.algorithm == Algorithm::Stepped)
      // Which fractions' units print open is core's own rule (C6a).
      pass.divisors = stepped_admitted_divisors(spec.topology, base, min_strut, tile_min,
                                                !fine, SteppedMenu::AnyStep);
    pass.base_mm = base;
    pass.skin_most = domain.skin_most_mm();
    pass.floor_mm = std::max(spec.cell_min_mm, out.floor_cell_mm);
    if (pass.thin) {
      // ★ notes29b: a thin wall is laid with its own one cell and nothing smaller (no halves, no units): the cell that
      // divides it, held at the thin floor.
      pass.sizes = {base};
      pass.divisors.clear();
      pass.floor_mm = std::max(spec.cell_min_mm, out.thin_floor_cell_mm);
    }
    pass.finest_mm = base;
    for (double a : pass.sizes) pass.finest_mm = std::min(pass.finest_mm, a);
    for (int n : pass.divisors)
      if (n >= 2) pass.finest_mm = std::min(pass.finest_mm, base / n);
    // C22: the pass's ladder, built here once from its own sizes and fractions.
    pass.ladder = pass.sizes;
    for (int n : pass.divisors)
      if (n >= 2)
        for (int m = 1; m < n; ++m) pass.ladder.push_back(m * (base / n));
    std::sort(pass.ladder.begin(), pass.ladder.end(), std::greater<double>());
    pass.ladder.erase(std::unique(pass.ladder.begin(), pass.ladder.end(),
                                  [](double a, double b) { return std::fabs(a - b) <= 1e-9 * std::max(a, b); }),
                      pass.ladder.end());
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
    if (keep) {   // C24: kept base cell by base cell (keep_steps puts them in the layout)
      keep->emplace_back();
      Laid& L = keep->back();
      L.pass = pass;
      L.base = base;
      for (int a = 0; a < 3; ++a) { L.start[a] = start[a]; L.count[a] = count[a]; }
      L.pieces.resize(total);
      L.caps.resize(total);
      std::vector<std::array<std::size_t, 2>> jobs(total);
      for (std::size_t i = 0; i < total; ++i) jobs[i] = {keep->size() - 1, i};
      lay_slots(*keep, jobs);
      return;
    }
    auto slot = [&](std::size_t i, double q[3]) {
      const std::size_t a = i % count[0], b = (i / count[0]) % count[1], c = i / (static_cast<std::size_t>(count[0]) * count[1]);
      q[0] = start[0] + a * base; q[1] = start[1] + b * base; q[2] = start[2] + c * base;
    };
    const int nt = static_cast<int>(std::min<std::size_t>(static_cast<std::size_t>(thread_count), total));
    if (nt <= 1) {
      for (std::size_t i = 0; i < total; ++i) {
        domain.check_stop();
        double q[3];
        slot(i, q);
        pass.columns.clear();
        pass.place(q, base);
      }
      return;
    }
    struct Piece { std::vector<Cell> cells, solid; std::vector<SolidWhy> why; };
    std::vector<Piece> pieces(total);
    std::atomic<std::size_t> next{0};
    auto work = [&](int who) {
      if (who > 0 && !spare[static_cast<std::size_t>(who)])
        spare[static_cast<std::size_t>(who)] = std::make_unique<Domain::Probe>(domain.probe());
      const Domain::Probe& mine = who > 0 ? *spare[static_cast<std::size_t>(who)] : probe;
      Layout local;
      local.floor_cell_mm = out.floor_cell_mm;
      RegionCells count_here;
      Pass p = pass;
      p.probe = &mine;
      p.out = &local;
      p.tally = &count_here;
      for (std::size_t i = next.fetch_add(1); i < total && !domain.stop_asked(); i = next.fetch_add(1)) {
        double q[3];
        slot(i, q);
        p.columns.clear();
        p.place(q, base);
        pieces[i].cells.swap(local.cells);
        pieces[i].solid.swap(local.solid);
        pieces[i].why.swap(local.solid_why);
        local.cells.clear();
        local.solid.clear();
        local.solid_why.clear();
      }
    };
    std::vector<std::thread> pool;
    for (int t = 1; t < nt; ++t) pool.emplace_back(work, t);
    work(0);
    for (std::thread& t : pool) t.join();
    domain.check_stop();   // base cells left unlaid
    for (const Piece& piece : pieces) {
      out.cells.insert(out.cells.end(), piece.cells.begin(), piece.cells.end());
      out.solid.insert(out.solid.end(), piece.solid.begin(), piece.solid.end());
      out.solid_why.insert(out.solid_why.end(), piece.why.begin(), piece.why.end());
      pass.tally->cells += piece.cells.size();
      pass.tally->solid += piece.solid.size();
    }
  };
  // C24: the size-step limit a region's cells keep; 0 = none (also on Uniform, which has nothing to divide).
  const auto step_of = [&](int region) {
    const CellSpec& cs = spec_of(region);
    return cs.algorithm == Algorithm::Uniform ? 0.0 : step_held(cs);
  };
  // A region's frame and its tally; returns the pass to lay with.
  auto open = [&](int region, const Frame& frame, double depth_cap, double base) {
    const CellSpec& spec = spec_of(region);
    Pass pass;
    pass.probe = &probe;
    pass.spec = &spec;
    pass.region = region;
    pass.frame_index = static_cast<int>(out.frames.size());
    pass.frame = frame;
    pass.out = &out;
    pass.region_depth = depth_cap;   // D14c
    if (stress_sizes_cells(spec)) {   // C22
      pass.demand = spec.demand.get();
      pass.ref_mpa = spec.reference_mpa;
      pass.response = spec.response;
    }
    out.frames.push_back(frame);
    out.walls.emplace_back();
    out.walls.back().depth = depth_cap;
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
    const WallMap none = out.walls.back();   // not a flat region: no walls
    pass.walls = &none;
    const double limit = step_of(region);
    if (limit > 0.0) {   // C24
      std::vector<Laid> lays;
      lay(pass, base, lo, hi, depth_from_zero, &lays);
      keep_steps(lays, limit);
      return;
    }
    lay(pass, base, lo, hi, depth_from_zero);
  };
  // C15, C2, C3-C5, C1: the cell that divides a wall of `width` exactly, never wider than
  // it, holding at least the cells it must, otherwise as few and as large as allowed.
  auto divide = [&](const CellSpec& cs, double width, int* layers) {
    *layers = std::max(k_min_of(cs), static_cast<int>(std::ceil(width / target_of(cs) - 1e-9)));
    return width / *layers;
  };
  // K7: the finest cell a lay of `base` uses (the one a face cuts, C20), as `lay` makes its ladder.
  auto finest_of = [&](const CellSpec& cs, double base, bool band) {
    const double band_floor =
        band && cs.band_cell_mm > 0.0 ? std::max(cs.band_cell_mm, out.floor_cell_mm) : out.floor_cell_mm;
    const double tile_min = std::max(cs.cell_min_mm, band_floor);
    double finest = base;
    if (cs.algorithm == Algorithm::DefaultGrade)
      for (double a : stepped_size_menu(cs.topology, base, min_strut, tile_min, !cs.allow_quilt, SteppedMenu::Halves))
        finest = std::min(finest, a);
    if (cs.algorithm == Algorithm::Stepped)
      for (int n :
           stepped_admitted_divisors(cs.topology, base, min_strut, tile_min, !cs.allow_quilt, SteppedMenu::AnyStep))
        if (n >= 2) finest = std::min(finest, base / n);
    return finest;
  };
  // K7, K8: the regions fitted, for the stretch once every region is laid.
  struct Fit {
    int region = 0, frame = 0;
    const CellSpec* spec = nullptr;
    std::shared_ptr<const SquareEnds> ends;
    std::size_t report = 0;   // its entry of out.cell_search
  };
  std::vector<Fit> fits;
  const double bed_z = part.lo().z;
  // K7: the base a region asked for is laid with: `base` (Auto's own) unless the search finds a size leaving fewer
  // slivers. `sizes`: the sizes to try after `base`, largest first. `depth_from_zero`: the grid starts at lo[2] on
  // its third axis (a flat region's face), else centred on every axis (C9), as `lay` places it.
  auto search = [&](int region, const CellSpec& cs, const Frame& frame, const double lo[3], const double hi[3],
                    bool depth_from_zero, bool band, double base, const std::vector<double>& sizes) {
    Layout::CellSearch rep;
    rep.region = region;
    rep.chosen_mm = base;
    if (!cs.cell_search && !cs.stretch_edges) return base;
    const auto t0 = std::chrono::steady_clock::now();
    const std::shared_ptr<const SquareEnds> ends = domain.kept<SquareEnds>(
        kKeptSquareEnds - region, [&]() { return read_square_ends(domain, region, frame, lo, hi, thread_count); });
    for (const SquareEnds::End& e : ends->ends) rep.square_mm2 += e.area;
    auto tried = [&](double b) {
      double start[3];
      int count[3];
      for (int a = 0; a < 3; ++a) centred(lo[a], hi[a], b, &start[a], &count[a]);
      if (depth_from_zero) start[2] = lo[2];
      Layout::CellSearch::Tried t = score_grid(*ends, start, b, finest_of(cs, b, band), frame, bed_z);
      t.grades = t.finest_mm < b * (1.0 - 1e-9);
      return t;
    };
    rep.tried.push_back(tried(base));
    std::size_t best = 0;
    const bool grades = rep.tried.front().grades;
    if (cs.cell_search)
      for (double b : sizes) {
        rep.tried.push_back(tried(b));
        if (grades && !rep.tried.back().grades) continue;   // never a size that loses the grade
        if (better(rep.tried.back(), rep.tried[best])) best = rep.tried.size() - 1;
      }
    rep.chosen_mm = rep.tried[best].base_mm;
    const Layout::CellSearch::Tried& w = rep.tried[best];
    const Layout::CellSearch::Tried& first = rep.tried.front();
    if (!cs.cell_search) rep.why = "not searched (the stretch only)";
    else if (rep.tried.size() == 1) rep.why = "the only size its depth and window allow";
    else if (best == 0 && first.slivers == 0) rep.why = "no sliver at a square face at the size Auto lays";
    else if (best == 0) rep.why = "no size that keeps the grade leaves clearly fewer slivers than the size Auto lays";
    else if (w.slivers == 0)
      rep.why = "no sliver at a square face (the size Auto lays, " + mm_words(first.base_mm) + ", leaves " +
                std::to_string(first.slivers) + ")";
    else
      rep.why = "fewer slivers: " + std::to_string(w.slivers) + " against " + std::to_string(first.slivers) +
                " at the size Auto lays (" + mm_words(first.base_mm) + ")";
    rep.ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count() + ends->ms;
    Fit fit;
    fit.region = region;
    fit.frame = static_cast<int>(out.frames.size());   // the frame the lay opens next
    fit.spec = &cs;
    fit.ends = ends;
    fit.report = out.cell_search.size();
    fits.push_back(fit);
    out.cell_search.push_back(std::move(rep));
    return out.cell_search.back().chosen_mm;
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
  auto world_base = [&](const CellSpec& cs) {
    const double target = target_of(cs);
    if (cs.algorithm != Algorithm::DefaultGrade || cs.cell_mm > 0.0) return target;
    double s = smallest_of(cs);
    while (s * 2.0 <= target * (1.0 + 1e-9)) s *= 2.0;
    return s;
  };

  // K7: the sizes a curved region or the whole part may try after Auto's own (centred on every axis, so any size of
  // its window): seven more down to the smallest that prints. Default Grade keeps C17's base (its halves must land on
  // the floor) and a typed cell is his.
  auto world_sizes = [&](const CellSpec& cs, double base) {
    std::vector<double> sizes;
    if (cs.cell_mm > 0.0 || cs.algorithm == Algorithm::DefaultGrade) return sizes;
    const double top = target_of(cs), bottom = smallest_of(cs);
    for (int j = 1; j <= 7 && top > bottom; ++j) {
      const double s = top - j * (top - bottom) / 7.0;
      if (std::fabs(s - base) > 1e-9) sizes.push_back(s);
    }
    return sizes;
  };
  auto world_fit = [&](int region, const CellSpec& cs) {
    const double base = world_base(cs);
    return search(region, cs, world, wlo, whi, false, false, base, world_sizes(cs, base));
  };

  // Regions are already in id order (D13), the whole part last.
  for (const Region& r : ds.regions) {
    if (r.role != Role::Lattice) continue;
    const CellSpec& spec = spec_of(r.id);   // C23: this region's own
    const double target = target_of(spec), smallest = smallest_of(spec);
    const int k_min = k_min_of(spec);
    if (r.weave) {
      // O1: a weave region is filled by its strands, not by cells. No cell, no solid cube, no tally; only the frame
      // its open space is read in (the part's own axes).
      out.weave.push_back({r.id, static_cast<int>(out.frames.size()), 0.0});
      out.frames.push_back(world);
      out.walls.emplace_back();
      continue;
    }
    if (r.is_shell()) {
      run(r.id, world, r.shell_depth_mm, world_fit(r.id, spec), wlo, whi, false);
      continue;
    }
    const ClearanceGeometry& g = r.prism;
    if (!g.valid || g.kind != ClearanceKind::Face) continue;
    int k = 0;
    const double base = divide(spec, g.depth, &k);
    // D14c: the depth whose own cell prints, when a deeper region would give one (not when the cell asked for is
    // itself under the floor).
    const double floor_here = std::max(spec.cell_min_mm, out.floor_cell_mm);
    const double depth_need = target >= floor_here ? k_min * floor_here : 0.0;
    Frame f;
    f.origin = g.origin;
    f.ax[0] = g.u; f.ax[1] = g.w; f.ax[2] = g.normal;
    const double e = std::max(0.0, r.expand_mm);
    const double lo[3] = {g.u_lo - e, g.w_lo - e, 0.0};
    const double hi[3] = {g.u_hi + e, g.w_hi + e, g.depth};

    if (spec.one_grid) {
      // ONE grid for the whole region, in the face's own frame, the face a cell boundary (C15), laid in one frame as
      // a curved region is: no wall map, no wall its own cells. Whatever is not this region's lattice cuts the cells
      // (D3). Grade to shape reads the region's own outline, as it does wall by wall.
      // K7: Auto's base searched among the sizes that divide the depth, down to the smallest that prints.
      double fitted = base;
      if (spec.cell_search || spec.stretch_edges) {
        std::vector<double> sizes;
        if (!(spec.cell_mm > 0.0))
          for (int kk = k + 1; kk <= k + 24; ++kk) {
            const double b = g.depth / kk;
            if (b < smallest * (1.0 - 1e-9)) break;
            sizes.push_back(b);
          }
        fitted = search(r.id, spec, f, lo, hi, true, spec.grade_to_shape && spec.band_mm > 0.0, base, sizes);
      }
      Pass pass = open(r.id, f, g.depth, fitted);
      pass.depth_need = depth_need;
      pass.tally = &out.regions.back();
      const WallMap none = out.walls.back();   // no walls: a cell's shape is its region's lattice in its cube
      pass.walls = &none;
      if (spec.grade_to_shape && spec.band_mm > 0.0) pass.band_region = &r;
      if (const double limit = step_of(r.id); limit > 0.0) {   // C24
        std::vector<Laid> lays;
        lay(pass, fitted, lo, hi, true, &lays);
        keep_steps(lays, limit);
        continue;
      }
      lay(pass, fitted, lo, hi, true);
      continue;
    }

    if (spec.cell_search || spec.stretch_edges) {   // K7, K8: said, not done
      Layout::CellSearch rep;
      rep.region = r.id;
      rep.chosen_mm = base;
      rep.not_searched = true;
      rep.why = "its walls are laid each with cells of their own (Let walls cut cells off)";
      out.cell_search.push_back(rep);
    }
    // The walls under this face, from the readings kept with the domain: every stretch of
    // material under each node of a coarse map of the face (a wall, a pocket and the wall
    // behind the pocket are two), gathered where they start at one depth and are one width.
    const std::shared_ptr<const FaceReadings> kept = domain.kept<FaceReadings>(
        r.id, [&]() { return read_face(domain, r, f, lo, hi, thread_count); });
    WallMap map = kept->map;
    for (std::size_t which = 0; which < kept->stretches.size(); ++which) {
      WallMap::Wall wall;
      double area = 0.0;
      {
        std::lock_guard<std::mutex> lock(kept->edging);
        const FaceReadings::Stretch& st = kept->stretches[which];
        wall.start = st.start;
        wall.width = st.width;
        area = st.entries.size() * WallMap::kPitch * WallMap::kPitch;
      }
      wall.cell = divide(spec, wall.width, &wall.layers);
      // ★ notes29b, Small cells in thin walls (CellSpec::small_in_thin_walls): a wall the open look's cells cannot divide
      // (its own cell under the smallest one, while the cell asked for is not) is a THIN wall, laid with its own one cell
      // when that is at least the thin floor (the thinnest strut a printed line short of touching). Only such a wall.
      wall.thin = spec.small_in_thin_walls && wall.cell < smallest && target >= smallest &&
                  wall.cell >= std::max(out.thin_floor_cell_mm * (1.0 + 1e-9), spec.cell_min_mm);
      // A wall is a stretch wide enough for its own cells (two by two of them) whose
      // cell prints. Anything else is left to the pass below, cell by cell.
      if ((wall.cell < smallest && !wall.thin) || area < 4.0 * wall.cell * wall.cell) continue;
      find_edges(*kept, which, domain, probe, spare, r, f);
      const FaceReadings::Stretch& st = kept->stretches[which];   // edged: no longer written
      wall.lo[0] = st.lo[0]; wall.lo[1] = st.lo[1];
      wall.hi[0] = st.hi[0]; wall.hi[1] = st.hi[1];
      // Its true extent must hold one of its cells each way as well: a ledge a tenth of
      // a millimetre wide catches a whole row of map nodes and is not a wall. (One, not
      // two: a rib one cell wide along the face is still a wall of its own depth.)
      if (wall.hi[0] - wall.lo[0] < wall.cell - kReadingSlack ||
          wall.hi[1] - wall.lo[1] < wall.cell - kReadingSlack)
        continue;
      for (std::size_t e : st.entries) map.wall[e] = static_cast<int>(map.walls.size());
      map.walls.push_back(wall);
    }

    Pass pass = open(r.id, f, g.depth, base);
    pass.depth_need = depth_need;
    pass.tally = &out.regions.back();
    pass.walls = &map;
    if (spec.grade_to_shape && spec.band_mm > 0.0) pass.band_region = &r;
    // C24: with a size step asked, every lay of the region is kept and the rule is kept across all of them (its walls
    // and what no wall holds share one frame) before any goes into the layout.
    const double limit = step_of(r.id);
    std::vector<Laid> lays;
    std::vector<Laid>* keep = limit > 0.0 ? &lays : nullptr;
    for (std::size_t i = 0; i < map.walls.size(); ++i) {
      const WallMap::Wall& wall = map.walls[i];
      pass.wall = static_cast<int>(i);
      // Centred on the wall's own stretch (C9, per wall).
      const double wlo3[3] = {wall.lo[0], wall.lo[1], wall.start};
      const double whi3[3] = {wall.hi[0], wall.hi[1], wall.start + wall.width};
      pass.thin = wall.thin;   // ★ notes29b
      lay(pass, wall.cell, wlo3, whi3, true, keep);
    }
    pass.thin = false;
    pass.wall = -1;   // what no wall holds: cell by cell from the region's own base
    lay(pass, base, lo, hi, true, keep);
    if (keep) keep_steps(lays, limit);
    out.walls[static_cast<std::size_t>(pass.frame_index)] = std::move(map);
  }
  if (ds.start == Start::AllLattice) run(0, world, 1e300, world_fit(0, spec), wlo, whi, false);
  // K5: no Structural patch of fewer cells than its count across, in any direction.
  drop_small_patches(out, [&](int region) { const CellSpec& cs = spec_of(region); return cs.one_grid ? 1 : cs.min_cells_across; });
  // K8 (CellSpec::stretch_edges): a sliver left against a square face is taken in by the cell beside it, where the
  // face is flat across the whole of that cell: the cell's struts reach on to the face, the sliver lays none.
  auto stretch_rows = [&](const Fit& fit) {
    Layout::CellSearch& rep = out.cell_search[fit.report];
    const Frame& f = out.frames[static_cast<std::size_t>(fit.frame)];
    std::vector<std::uint32_t> mine;
    double big = 0.0;
    for (std::size_t i = 0; i < out.cells.size(); ++i)
      if (out.cells[i].frame == fit.frame && out.cells[i].region == fit.region) {
        mine.push_back(static_cast<std::uint32_t>(i));
        big = std::max(big, out.cells[i].size);
      }
    if (mine.empty() || fit.ends->ends.empty()) return;
    const double pitch = big * (1.0 + 1e-9);
    const auto slot = [&](double x) { return static_cast<long long>(std::floor(x / pitch)); };
    std::map<std::array<long long, 3>, std::vector<std::uint32_t>> grid;
    for (const std::uint32_t ci : mine) {
      const Cell& c = out.cells[ci];
      for (long long x = slot(c.lo[0]); x <= slot(c.lo[0] + c.size); ++x)
        for (long long y = slot(c.lo[1]); y <= slot(c.lo[1] + c.size); ++y)
          for (long long z = slot(c.lo[2]); z <= slot(c.lo[2] + c.size); ++z) grid[{x, y, z}].push_back(ci);
    }
    const auto cell_at = [&](const double q[3]) -> long {   // the first cell, in layout order, whose cube holds q
      const auto it = grid.find({slot(q[0]), slot(q[1]), slot(q[2])});
      if (it == grid.end()) return -1;
      for (const std::uint32_t ci : it->second) {
        const Cell& c = out.cells[ci];
        bool in = !c.absorbed;
        for (int a = 0; a < 3 && in; ++a) in = q[a] >= c.lo[a] && q[a] < c.lo[a] + c.size;
        if (in) return static_cast<long>(ci);
      }
      return -1;
    };
    const auto lattice_at = [&](const double q[3]) {
      const Where w = probe.where(f.at(q[0], q[1], q[2]));
      return w.lattice() && w.id == fit.region;
    };
    const std::vector<StrutCellStrut> struts = cell_struts(fit.spec->topology, f);   // as lay_bars lays them
    const double most = target_of(*fit.spec);   // Max cell
    // Would stretching by `factor` along axis `a` lay any strut flatter (less rise over its length) than the cell does?
    const auto flatter = [&](int a, double factor) {
      for (const StrutCellStrut& s : struts) {
        const double d[3] = {static_cast<double>(s.b.x - s.a.x), static_cast<double>(s.b.y - s.a.y),
                             static_cast<double>(s.b.z - s.a.z)};
        const auto rise = [&](double fa) {
          Vec3 v{0, 0, 0};
          for (int k = 0; k < 3; ++k) {
            const double m = d[k] * (k == a ? fa : 1.0);
            v = Vec3{v.x + f.ax[k].x * m, v.y + f.ax[k].y * m, v.z + f.ax[k].z * m};
          }
          const double l = std::sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
          return l > 0.0 ? std::fabs(v.z) / l : 1.0;
        };
        if (rise(factor) < rise(1.0) - 1e-9) return true;
      }
      return false;
    };
    // The slivers met on a square face, and the cell beside each, face to face: what that cell would reach to.
    struct Ask { int axis = 0, side = 0; double at = 0.0, d = 0.0, plane = 0.0; };
    std::map<std::uint32_t, Ask> asks;   // by the neighbour, in layout order; the first face found
    std::set<std::uint32_t> slivers;
    for (const SquareEnds::End& e : fit.ends->ends) {
      int o0, o1;
      other_axes(e.axis, &o0, &o1);
      const int a = e.axis;
      // Only a face the lattice stands on (the bed, a floor): along the grid's upright axis, the lattice above it. Under
      // a ceiling the row's top struts would lie along the ceiling as bridges, where the cut struts run up into it.
      if (-e.side * f.ax[a].z < 0.99) continue;
      double q[3];
      q[a] = e.at - e.side * 0.02;
      q[o0] = e.p[0];
      q[o1] = e.p[1];
      const long si = cell_at(q);
      if (si < 0) continue;
      const Cell& s = out.cells[static_cast<std::size_t>(si)];
      const double d = e.side > 0 ? e.at - s.lo[a] : s.lo[a] + s.size - e.at;
      if (!(d > 0.02 && d < kSliverFraction * s.size)) continue;   // the face cuts it whole, or not thin
      slivers.insert(static_cast<std::uint32_t>(si));
      const double plane = e.side > 0 ? s.lo[a] : s.lo[a] + s.size;
      double qn[3] = {q[0], q[1], q[2]};
      qn[a] = plane - e.side * 0.02;
      const long ni = cell_at(qn);
      if (ni < 0) continue;
      const Cell& n = out.cells[static_cast<std::size_t>(ni)];
      if (std::fabs((e.side > 0 ? n.lo[a] + n.size : n.lo[a]) - plane) > 1e-6) continue;
      asks.emplace(static_cast<std::uint32_t>(ni), Ask{a, e.side, e.at, d, plane});
    }
    std::set<std::uint32_t> taken;
    for (const auto& [ni, ask] : asks) {
      Cell& n = out.cells[ni];
      const int a = ask.axis;
      int o0, o1;
      other_axes(a, &o0, &o1);
      if (n.absorbed || taken.count(ni) || n.reach_lo[a] > 0.0 || n.reach_hi[a] > 0.0) continue;
      if (n.size + ask.d > most * (1.0 + 1e-9)) continue;        // never past Max cell
      if (flatter(a, (n.size + ask.d) / n.size)) continue;       // never a strut flatter than the cell lays it
      // Every cell starting on the plane over its footprint lies inside the footprint and is the same face's sliver.
      std::vector<std::uint32_t> across;
      bool ok = true;
      for (const std::uint32_t ci : mine) {
        if (ci == ni) continue;
        const Cell& t = out.cells[ci];
        if (std::fabs((ask.side > 0 ? t.lo[a] : t.lo[a] + t.size) - ask.plane) > 1e-6) continue;
        const bool overlaps = t.lo[o0] < n.lo[o0] + n.size - 1e-6 && t.lo[o0] + t.size > n.lo[o0] + 1e-6 &&
                              t.lo[o1] < n.lo[o1] + n.size - 1e-6 && t.lo[o1] + t.size > n.lo[o1] + 1e-6;
        if (!overlaps) continue;
        const bool inside = t.lo[o0] >= n.lo[o0] - 1e-6 && t.lo[o0] + t.size <= n.lo[o0] + n.size + 1e-6 &&
                            t.lo[o1] >= n.lo[o1] - 1e-6 && t.lo[o1] + t.size <= n.lo[o1] + n.size + 1e-6;
        const double dt = ask.side > 0 ? ask.at - t.lo[a] : t.lo[a] + t.size - ask.at;
        if (!inside || t.absorbed || taken.count(ci) || std::fabs(dt - ask.d) > 1e-3 ||
            !(ask.d < kSliverFraction * t.size)) {
          ok = false;
          break;
        }
        across.push_back(ci);
      }
      if (!ok || across.empty()) continue;
      // The face is flat across the whole footprint (4 x 4 places): the region's lattice through the sliver up to
      // the face, and none past it.
      for (int i = 0; i < 4 && ok; ++i)
        for (int j = 0; j < 4 && ok; ++j) {
          double q[3];
          q[o0] = n.lo[o0] + n.size * (i + 0.5) / 4.0;
          q[o1] = n.lo[o1] + n.size * (j + 0.5) / 4.0;
          q[a] = ask.at - ask.side * std::min(0.05, 0.25 * ask.d);
          ok = lattice_at(q);
          q[a] = 0.5 * (ask.plane + ask.at);
          ok = ok && lattice_at(q);
          q[a] = ask.at + ask.side * 0.05;
          ok = ok && !lattice_at(q);
        }
      if (!ok) continue;
      // A hair short of the face (kStretchInset): the row's nodes and bottom struts sit just above it, so the part cuts
      // them flat on it cleanly (centred ON the face, their round sections met the part's own face edge to edge and
      // the file kept a few microns of crumb under the bed).
      (ask.side > 0 ? n.reach_hi[a] : n.reach_lo[a]) = ask.d - kStretchInset;
      n.cut = true;   // its struts are read closely (lay_bars)
      for (const std::uint32_t ci : across) {
        out.cells[ci].absorbed = true;
        taken.insert(ci);
      }
      ++rep.stretched;
      rep.taken_in += across.size();
    }
    for (const std::uint32_t si : slivers)
      if (!out.cells[si].absorbed) ++rep.slivers_left;
  };
  for (const Fit& fit : fits)
    if (fit.spec->stretch_edges) stretch_rows(fit);
  // D14b: cells take in the lattice slivers inside their cubes.
  out.absorb = spec.absorb_slivers;
  if (out.absorb) out.index = index_cells(out);
  return out;
}

}  // namespace topopt::lattice_layout
